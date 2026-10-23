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
  version = "8.0.0"

  for_each    = local.transits
  cloud       = "Azure"
  account     = var.account
  region      = var.region
  name        = "${each.key}-vnet"
  gw_name     = "${each.key}-gw"
  cidr        = each.value
  insane_mode = true
}

module "mc-spoke" {
  source  = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version = "8.0.0"

  for_each    = local.spokes
  cloud       = "Azure"
  account     = var.account
  region      = var.region
  name        = "${each.key}-vnet"
  gw_name     = "${each.key}-gw"
  cidr        = each.value.cidr
  transit_gw  = module.mc-transit[each.value.transit].transit_gateway.gw_name
  insane_mode = true
}

# Full mesh peering across all three transits
module "mc-transit-peering" {
  source  = "terraform-aviatrix-modules/mc-transit-peering/aviatrix"
  version = "1.0.9"

  transit_gateways = [for t in module.mc-transit : t.transit_gateway.gw_name]
}

