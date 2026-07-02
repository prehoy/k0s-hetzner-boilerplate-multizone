# Cloudflare Load Balancing — TEMPLATE (currently unused).
#
# Reserved for production, customer-facing services that need health-checked, instant, 2-DC failover.
# Internal/admin UIs use round-robin A records instead (cloudflare.tf local.lb_rr_hosts) — free, and a
# browser just retries the other LB IP. Don't pay for LB on things an admin can tolerate a blip on.
#
# Prereqs (already satisfied on this account): Load Balancing subscription + a token with BOTH
# account "Load Balancing: Monitors and Pools" AND zone "Load Balancers" (+ zone DNS).
#
# To put a prod service (e.g. app.<domain>) behind health-checked failover, uncomment and adjust:
#
# variable "cloudflare_account_id" {
#   type    = string
#   default = "YOUR_CLOUDFLARE_ACCOUNT_ID"
# }
#
# resource "cloudflare_load_balancer_monitor" "ingress" {
#   account_id     = var.cloudflare_account_id
#   type           = "https"
#   method         = "GET"
#   path           = "/"
#   port           = 443
#   expected_codes = "404"          # Traefik 404 on an unmatched host = ingress path alive
#   allow_insecure = true
#   interval       = 60
#   timeout        = 5
#   retries        = 2
#   description    = "k0s ingress (Traefik :443)"
# }
#
# resource "cloudflare_load_balancer_pool" "ingress" {
#   account_id = var.cloudflare_account_id
#   name       = "k0s-ingress"
#   monitor    = cloudflare_load_balancer_monitor.ingress.id
#   origins {
#     name    = "lb-0-fsn1"
#     address = hcloud_primary_ip.lb_ips[0].ip_address
#     enabled = true
#   }
#   origins {
#     name    = "lb-1-nbg1"
#     address = hcloud_primary_ip.lb_ips[1].ip_address
#     enabled = true
#   }
# }
#
# resource "cloudflare_load_balancer" "ingress" {
#   for_each         = toset(["app"])   # <- prod hostnames that need CF LB
#   zone_id          = data.cloudflare_zone.zone.id
#   name             = "${each.key}.${var.domain}"
#   default_pool_ids = [cloudflare_load_balancer_pool.ingress.id]
#   fallback_pool_id = cloudflare_load_balancer_pool.ingress.id
#   proxied          = true
#   steering_policy  = "off"
# }
