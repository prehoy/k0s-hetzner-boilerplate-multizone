# Cloudflare DNS-as-code for the cluster zone (var.domain) — one explicit A record per service.
# NO wildcards. Add a line per service you expose; an existing record must be `terraform import`ed
# before terraform manages it (else a duplicate A record is created):
#   terraform import 'cloudflare_record.rec["grafana"]' <zone_id>/<record_id>

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = ""
}

data "cloudflare_zone" "zone" {
  name = var.domain
}

locals {
  bo_ip         = hcloud_primary_ip.nat_ip.ip_address # backoffice box public IP (Docker Swarm mgmt stack)
  lb_public_ips = [for ip in hcloud_primary_ip.lb_ips : ip.ip_address] # [lb-0 fsn1, lb-1 nbg1]

  # Single-origin A records (one target IP).
  dns_records = {
    # Backoffice mgmt stack (Docker Swarm box, single node)
    "swarmpit.bo"  = local.bo_ip # Swarmpit UI
    "databasus.bo" = local.bo_ip # DB backup manager
    "vpn.bo"       = local.bo_ip # WireGuard admin portal
    "traefik.bo"   = local.bo_ip # backoffice Traefik
    "status"       = local.bo_ip # public status page (backoffice gatus watches the cluster)
  }

  # Cluster-served hosts as ROUND-ROBIN A records across BOTH LB public IPs (fsn1 + nbg1): free,
  # 2-DC reachable, a browser retries the other LB IP if one is down. CF Load Balancing
  # (health-checked instant failover) is reserved for prod services — see cloudflare-lb.tf.
  lb_rr_hosts = ["argocd", "grafana", "ci", "status.bo"]
}

resource "cloudflare_record" "rec" {
  for_each = local.dns_records
  zone_id  = data.cloudflare_zone.zone.id
  name     = each.key
  type     = "A"
  content  = each.value
  proxied  = false
  ttl      = 60
  comment  = "terraform: ${var.domain} DNS-as-code"
}

# Two A records per host (one per LB IP) = DNS round-robin across both DCs.
resource "cloudflare_record" "lb_rr" {
  for_each = { for p in setproduct(local.lb_rr_hosts, local.lb_public_ips) : "${p[0]}@${p[1]}" => { host = p[0], ip = p[1] } }
  zone_id  = data.cloudflare_zone.zone.id
  name     = each.value.host
  type     = "A"
  content  = each.value.ip
  proxied  = false
  ttl      = 60
  comment  = "terraform: round-robin both LB IPs (cluster ingress)"
}
