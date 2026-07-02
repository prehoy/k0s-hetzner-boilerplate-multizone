terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4"
    }
  }
}


provider "hcloud" {
  token = var.hcloud_token
}
#managers 3-49, workers  50-100, db 100-149, backoffice 150, nfs  200-209, loadbalancer 210

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  # Spread nodes across 3 EU datacenters. All are in the eu-central network zone, so the private
  # 10.0.0.0/16 network spans them and inter-DC private traffic is free. A full-DC outage then loses
  # only one of each quorum member (managers/db/workers), keeping etcd + Patroni + the workload up.
  locations = ["fsn1", "nbg1", "hel1"]
}

#NETWORK
resource "hcloud_network" "mainNet" {
  name     = "mainNet"
  ip_range = "10.0.0.0/16"

}

#SUBNET
# network_zone eu-central spans fsn1/nbg1/hel1, so servers in any of those locations attach to this
# one subnet and talk over private IPs. The zone must match the locations the cluster-autoscaler
# creates nodes in (it attaches at create time, which enforces the zone check).
resource "hcloud_network_subnet" "mainSubNet" {
  network_id   = hcloud_network.mainNet.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.0.0/24"
}

# Dedicated subnet for Cluster-Autoscaler nodes (cas-pool). Hetzner assigns the lowest free IP in a
# subnet, which would collide with the static reservations in 10.0.0.0/24 (managers .3-.5, workers
# .50-.52, db .100-.102, nfs .200-.201, lb .210-.211, nat .150). CAS is pinned to 10.0.1.0/24 via
# subnetIPRange in HCLOUD_CLUSTER_CONFIG so autoscaled nodes only ever get 10.0.1.x. Same eu-central
# zone as mainSubNet so the CAS provider's create-time network attach is accepted. Calico autodetection
# is cidr=10.0.0.0/16 so it covers both subnets.
resource "hcloud_network_subnet" "casSubNet" {
  network_id   = hcloud_network.mainNet.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}


resource "hcloud_primary_ip" "nat_ip" {
  name          = "nat-ip"
  location      = "hel1" # backoffice box sits in the 3rd DC (also the DRBD quorum tiebreaker)
  type          = "ipv4"
  assignee_type = "server"
  auto_delete   = false
  labels = {
    "role" = "NAT"
  }
}

#BACKOFFICE
resource "hcloud_server" "backoffice_nat" {
  name        = "backoffice-nat"
  location    = "hel1"
  image       = var.os_type
  server_type = "cpx22"
  labels = {
    "role" = "NAT"
  }
  public_net {
    ipv6_enabled = true
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.nat_ip.id
  }
  network {
    ip         = "10.0.0.150"
    network_id = hcloud_network.mainNet.id
  }
  user_data = file("./node_setup/nat.yml")
  ssh_keys  = [hcloud_ssh_key.admin.id]
}

resource "hcloud_network_route" "nat_gateway" {
  network_id = hcloud_network.mainNet.id
  # Steady-state egress gateway = lb-0 (the keepalived master of the HA LB pair), NOT the backoffice
  # (removes the egress SPOF). On keepalived failover, /etc/keepalived/failover.sh swaps this route to
  # the new master via the Cloud API, so ignore_changes keeps `terraform apply` from reverting a live
  # failover. See staging/ansible/INFRASTRUCTURE.md "NAT Gateway (HA — on the LB pair)".
  gateway     = "10.0.0.210"
  destination = "0.0.0.0/0"

  lifecycle {
    ignore_changes = [gateway]
  }
}


# NFS HA PAIR (nfs-0 10.0.0.200 / nfs-1 10.0.0.201).
# DRBD (protocol C) synchronously replicates a dedicated nfs-drbd volume between the pair; keepalived
# owns failover. The service VIP 10.0.0.199 is a Hetzner *alias IP* moved between nodes via the Cloud
# API on keepalived master transition (`/etc/keepalived/nfs-failover.sh`) — a plain VRRP virtual_-
# ipaddress is NOT delivered on Hetzner's SDN; the alias must be registered through the API.
# alias_ips is seeded on nfs-0 here and then owned by keepalived at runtime, so ignore_changes keeps
# `terraform apply` from reverting a live failover. See prod/ansible/playbooks/nfs/nfs_ha/ and
# docs/RUNBOOK-nfs-ha.md.
resource "hcloud_server" "nfs" {
  count       = 2
  name        = "nfs-${count.index}"
  location    = element(["fsn1", "nbg1"], count.index) # DRBD sync replication is latency-sensitive → keep the pair in the two German DCs
  image       = var.os_type
  server_type = "cpx22"
  labels = {
    "role" = "nfs"
  }
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }
  user_data = file("./node_setup/private_only.yml")
  ssh_keys  = [hcloud_ssh_key.admin.id]
  network {
    ip         = "10.0.0.${count.index + 200}"
    network_id = hcloud_network.mainNet.id
    alias_ips  = count.index == 0 ? ["10.0.0.199"] : []
  }

  lifecycle {
    ignore_changes = [network] # keepalived moves the 10.0.0.199 alias IP between the pair
  }
}

# Dedicated DRBD backing volume per NFS node (replicated block device — NOT a shared volume).
# Left raw/unformatted: DRBD writes its own metadata and the filesystem lives on /dev/drbd0.
# One-time bring-up (create-md, first sync, mkfs, data restore) is in docs/RUNBOOK-nfs-ha.md.
resource "hcloud_volume" "nfs_drbd" {
  count = 2
  name  = "nfs-drbd-${count.index}"
  # 50 -> 250 GiB (2026-06-21): the 50 GiB volume hit 87% at only 7 days of HyperDX otel_logs
  # (~4 GiB/day). 30-day log retention needs ~120 GiB for logs + other NFS data; 250 leaves headroom.
  # Hetzner online-grows the block volume on apply, but DRBD + the ext4 filesystem must then be grown
  # by hand (online, no downtime) — see docs/RUNBOOK-spof-mitigations.md §5. Grow ONLY; never shrink.
  size      = 250
  server_id = hcloud_server.nfs[count.index].id
  automount = false
  format    = ""
}

# MANAGEMENT NODES
resource "hcloud_server" "managers" {
  count       = 3
  location    = local.locations[count.index] # one controller per DC → etcd quorum survives a full-DC outage
  name        = "k0s-manager-${count.index}"
  image       = var.os_type
  server_type = "cpx22"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = file("./node_setup/private_only.yml")
  network {
    ip         = "10.0.0.${count.index + 3}"
    network_id = hcloud_network.mainNet.id
  }
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }

  labels = {
    "role" = "manager"
    "role" = "lb"
  }
}


resource "hcloud_primary_ip" "lb_ips" {
  count         = 2
  assignee_type = "server"
  type          = "ipv4"
  location      = element(["fsn1", "nbg1"], count.index) # split across DCs (matches each LB's location)
  name          = "lb-ip-${count.index}"
  auto_delete   = true
  labels = {
    "role" = "lb"
  }
}

resource "hcloud_server" "lbs" {
  count       = 2
  location    = element(["fsn1", "nbg1"], count.index) # lb-0 fsn1, lb-1 nbg1 → internal API VIP (10.0.0.240) fails over across DCs
  name        = "lb-${count.index}"
  image       = var.os_type
  server_type = "cpx22"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  network {
    ip         = "10.0.0.${count.index + 210}"
    network_id = hcloud_network.mainNet.id
    # Control-plane HA alias VIP seeded on lb-0; then owned by keepalived (moves on failover via the
    # Cloud API), so ignore drift. https://10.0.0.240:6443 -> 3 apiservers. See RUNBOOK-control-plane-lb.md.
    alias_ips = count.index == 0 ? ["10.0.0.240"] : []
  }
  public_net {
    ipv6_enabled = false
    # ipv4_enabled = false
    ipv4 = hcloud_primary_ip.lb_ips[count.index].id
  }

  labels = {
    "role" = "lb"
  }

  lifecycle {
    ignore_changes = [network] # keepalived moves the 10.0.0.240 alias between the lb pair
  }
}

# (No floating IP: with the LB pair split across DCs a single floating IP can't fail over, so public
# ingress is round-robin A records across both LB public IPs — see terraform/cloudflare.tf. The
# internal API VIP 10.0.0.240 is a subnet alias IP moved by keepalived.)



# WORKER NODES — one per DC; cluster-autoscaler (CAS, min-0) adds elastic burst on top.
resource "hcloud_server" "workers" {
  count       = 3
  location    = local.locations[count.index] # spread across the 3 EU DCs
  name        = "k0s-worker-${count.index}"
  image       = var.os_type
  server_type = "cpx32"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = file("./node_setup/private_only.yml")
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }

  network {
    ip         = "10.0.0.${count.index + 50}"
    network_id = hcloud_network.mainNet.id
  }
  labels = {
    "role" = "worker"
  }
}

# DB HOSTS
# 0 is master, 1 is replica, 2 is replica
resource "hcloud_server" "database_servers" {
  count       = 3
  location    = local.locations[count.index] # one Patroni node per DC → DB survives a full-DC outage
  name        = "database-server-${count.index}"
  image       = var.os_type
  server_type = "cpx32"
  ssh_keys    = [hcloud_ssh_key.admin.id]
  user_data   = file("./node_setup/private_only.yml")
  public_net {
    ipv6_enabled = false
    ipv4_enabled = false
  }

  network {
    ip         = "10.0.0.${count.index + 100}"
    network_id = hcloud_network.mainNet.id
  }
  labels = {
    "role" = "database"
  }
}
