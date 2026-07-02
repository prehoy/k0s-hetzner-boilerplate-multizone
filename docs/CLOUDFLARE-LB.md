# Public ingress: round-robin by default, Cloudflare LB for prod

## The default (already wired, free)

Public ingress uses **round-robin A records across both LB public IPs** (fsn1 + nbg1) —
`terraform/cloudflare.tf`, `local.lb_rr_hosts`. It's free, reaches both DCs, and a browser retries the
other LB IP if one is down. Good enough for internal/admin UIs (argocd, grafana, ci, status.bo).

The internal k8s API VIP `10.0.0.240` is separate — a subnet alias IP keepalived moves across DCs via
the hcloud API, so the cluster API is already DC-fault-tolerant regardless.

## When to reach for Cloudflare Load Balancing

For **production, customer-facing services** that need *health-checked, instant* failover (not
DNS/browser-retry): CF LB health-checks both LB IPs and routes only to the healthy DC. It costs money
(per hostname + DNS queries), so reserve it for services that justify it — don't pay for it on tools an
admin can tolerate a brief blip on.

## Prerequisites (one-time)

1. **Enable Load Balancing** on the Cloudflare account: Dashboard → Traffic → Load Balancing (~$5/mo).
2. **API token** with all three (same token): Account → **Load Balancing: Monitors and Pools → Edit**,
   Zone → **Load Balancers → Edit**, Zone → **DNS → Edit**. (Some accounts are "account-scoped" and the
   account "Monitors and Pools" already covers the LB objects — verify with
   `GET /accounts/<id>/load_balancers`.) Put it in `terraform/secrets.auto.tfvars`.
3. Set `var.cloudflare_account_id` (in `cloudflare-lb.tf`).

## Put a prod service behind CF LB

`terraform/cloudflare-lb.tf` ships as a ready, commented template (monitor + pool over both LB IPs + a
`cloudflare_load_balancer` per hostname). To use it:

1. **Uncomment** `cloudflare-lb.tf` and set the hostnames, e.g. `for_each = toset(["app"])`.
2. In `terraform/cloudflare.tf`, **remove those hostnames from `local.lb_rr_hosts`** — a name can't be
   both a round-robin A record and a load balancer.
3. `cd terraform && terraform apply` — creates the monitor + pool + the LB(s), removes the matching A
   records. Other DNS records are untouched.

## Verify

```bash
curl -sI https://app.<domain> | head -1     # served via Cloudflare edge -> cluster
```
- Cloudflare dashboard → Load Balancing → pool `k0s-ingress`: **both origins healthy**.
- Failure test: stop haproxy on lb-0 (or take fsn1 down) → the pool marks `lb-0-fsn1` unhealthy and
  traffic continues through `lb-1-nbg1`.

## Notes

- The health check hits Traefik on `:443`; Traefik answers `404` for an unmatched host, which proves
  the whole ingress path (haproxy → Traefik → cluster) is alive — a plain TCP check can't.
- `steering_policy = "off"` = active-active across healthy origins. For latency routing use
  `"dynamic_latency"`, or per-DC pools with a `geo` policy.
