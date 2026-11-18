locals {
  transits = {
    transit1 = "10.0.1.0/24"
    transit2 = "10.0.2.0/24"
    transit3 = "10.0.3.0/24"
  }

  spokes = {
    spoke1 = { cidr = "172.16.1.0/24", transit = "transit1" }
    spoke2 = { cidr = "172.16.2.0/24", transit = "transit2" }
    spoke3 = { cidr = "172.16.3.0/24", transit = "transit3" }
  }
}

module "mc-transit" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "9.0.0"

  for_each      = local.transits
  cloud         = "Azure"
  account       = var.account
  region        = var.region
  name          = "${each.key}-vnet"
  gw_name       = "${each.key}-gw"
  cidr          = each.value
  insane_mode   = true
  instance_size = "Standard_D2s_v5"

  # The 9.x module defaults this to "enable"; keep the value the gateways were built with.
  tunnel_forward_secrecy = "disable"
}

module "mc-spoke" {
  source  = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version = "9.0.0"

  for_each      = local.spokes
  cloud         = "Azure"
  account       = var.account
  region        = var.region
  name          = "${each.key}-vnet"
  gw_name       = "${each.key}-gw"
  cidr          = each.value.cidr
  transit_gw    = module.mc-transit[each.value.transit].transit_gateway.gw_name
  insane_mode   = true
  instance_size = "Standard_D2s_v5"

  # 3 public/private subnet pairs: pair 0 holds the spoke gateways, pairs 1
  # and 2 host the gw-to-gw test instances (see test_instances.tf).
  subnet_pairs = 3

  tunnel_forward_secrecy = "disable"
}

# Full mesh peering across the three module-built transits (transit4 is peered to each of them in hpe_groups.tf)
module "mc-transit-peering" {
  source  = "terraform-aviatrix-modules/mc-transit-peering/aviatrix"
  version = "1.0.9"

  transit_gateways = [for t in module.mc-transit : t.transit_gateway.gw_name]
}

