# Public ingress HA via Cloudflare Load Balancing

The final piece of the multi-DC design: **DC-fault-tolerant public ingress**.

## Why

The LB pair is split — **lb-0 in `fsn1`, lb-1 in `nbg1`**. The internal k8s API VIP `10.0.0.240` is a
*subnet alias IP*, so keepalived moves it across DCs via the hcloud API → **the cluster API already
survives a full-DC outage.** But the **public ingress floating IP is location-bound** (Hetzner floating
IPs can only attach to servers in one location), so public ingress alone would be pinned to `fsn1`.

**Cloudflare Load Balancing** solves the public half: it health-checks *both* LB public IPs and routes
inbound traffic to whichever DC is healthy. Lose `fsn1`, and public traffic flows through `nbg1`.

Until this is set up, public ingress runs on the interim floating IP (`fsn1`); the cluster itself is
already DC-fault-tolerant.

## Prerequisites (account setup — one-time)

1. **Enable Load Balancing** on the Cloudflare account: Dashboard → Traffic → Load Balancing →
   subscribe (~$5/mo base).
2. **API token scopes** — extend the existing DNS token, or issue a new one, with:
   - Account → **Load Balancing: Monitors and Pools → Edit**
   - Zone → **Load Balancers → Edit**
   - Zone → **DNS → Edit** (already present)

   Put it in `terraform/secrets.auto.tfvars` as `cloudflare_api_token`.
3. Account ID: `YOUR_CLOUDFLARE_ACCOUNT_ID` (used below as `var.cloudflare_account_id`).

## Terraform — add `terraform/cloudflare-lb.tf`

```hcl
variable "cloudflare_account_id" {
  type    = string
  default = "YOUR_CLOUDFLARE_ACCOUNT_ID"
}

# Health check on Traefik (:443). Traefik answers 404 for an unmatched host, which still proves the
# whole ingress path (haproxy -> Traefik -> cluster) is alive — a plain TCP check can't tell that.
resource "cloudflare_load_balancer_monitor" "ingress" {
  account_id     = var.cloudflare_account_id
  type           = "https"
  method         = "GET"
  path           = "/"
  port           = 443
  expected_codes = "404"   # Traefik "no route for host" = ingress serving
  allow_insecure = true    # skip CF->origin cert validation (origin uses cluster/LE certs)
  interval       = 60
  timeout        = 5
  retries        = 2
  description    = "k0s ingress (Traefik :443)"
}

resource "cloudflare_load_balancer_pool" "ingress" {
  account_id = var.cloudflare_account_id
  name       = "k0s-ingress"
  monitor    = cloudflare_load_balancer_monitor.ingress.id
  origins {
    name    = "lb-0-fsn1"
    address = hcloud_primary_ip.lb_ips[0].ip_address
    enabled = true
  }
  origins {
    name    = "lb-1-nbg1"
    address = hcloud_primary_ip.lb_ips[1].ip_address
    enabled = true
  }
}

# One Cloudflare LB per public, cluster-served host. steering "off" = active-active across healthy
# origins (unhealthy ones auto-removed). proxied = clients hit Cloudflare's edge.
locals {
  cf_lb_hosts = ["argocd", "grafana", "ci", "status.bo"]
}

resource "cloudflare_load_balancer" "ingress" {
  for_each         = toset(local.cf_lb_hosts)
  zone_id          = data.cloudflare_zone.zone.id
  name             = "${each.key}.${var.domain}"
  default_pool_ids = [cloudflare_load_balancer_pool.ingress.id]
  fallback_pool_id = cloudflare_load_balancer_pool.ingress.id
  proxied          = true
  steering_policy  = "off"
}
```

## Cut over from the floating IP

1. In `terraform/cloudflare.tf`, **remove the four cluster-served hosts** from `local.dns_records`
   (`argocd`, `grafana`, `ci`, `status.bo`) — they're now Cloudflare LBs, not A records. Leave the
   backoffice `*.bo` / `status` records (single node, no LB). `local.lb_ip` becomes unused → delete it.
2. In `terraform/main.tf`, **delete `resource "hcloud_floating_ip" "lb_main"`** (public path is CF now).
3. `cd terraform && terraform apply` — creates the monitor + pool + 4 load balancers, destroys the 4
   old A records + the floating IP. **Your other DNS records are untouched.**
4. (Optional) In `ansible/playbooks/loadbalancer/templates/failover.sh.j2`, drop the floating-IP claim
   step — the LBs keep the API-VIP + NAT-route failover; the public IP is no longer keepalived-managed.
   Then re-run the `loadbalancer` playbook.

## Verify

```bash
curl -sI https://argocd.k0s.<domain> | head -1          # served via Cloudflare edge -> cluster
```
- Cloudflare dashboard → Load Balancing → pool `k0s-ingress`: **both origins healthy**.
- Failure test: stop haproxy on lb-0 (or take fsn1 down) → the pool marks `lb-0-fsn1` unhealthy and
  traffic continues through `lb-1-nbg1`.

## Notes

- The **internal API VIP `10.0.0.240` is unaffected** — it already fails over cross-DC via keepalived.
- `steering_policy = "off"` is round-robin across healthy origins. For latency-aware routing use
  `"dynamic_latency"`, or split into per-DC pools with a `geo` policy.
- CF LB billing is per-hostname + per-DNS-query; 4 hostnames is well within the base tier.
