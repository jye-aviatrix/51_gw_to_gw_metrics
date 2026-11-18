# transit4 / spoke4: HPE (insane mode) gateways built with the gateway group resources
# (aviatrix_transit_group + aviatrix_transit_instance, aviatrix_spoke_group + aviatrix_spoke_instance)
# instead of the mc-transit / mc-spoke modules. Each group has three instances that are all equal
# members of the group (there is no separate "HA" gateway, so no -hagw suffix). The instances sit in
# availability zones az-1..az-3.
#
# transit4 is peered with transit1-3, spoke4 is attached to transit4, and the spoke4 test VMs join
# the same iperf3 mesh as the other spokes (three VMs, one per availability zone) (see test_instances.tf).

locals {
  # /23 VNets leave room for three /26 gateway subnets carved from the top of the range, the same way
  # the modules carve theirs (the lower addresses hold the subnets Aviatrix creates with the VNet).
  transit4_cidr = "10.0.4.0/23"
  spoke4_cidr   = "172.16.4.0/23"

  # Insane mode gateways need a /26 each. Index 5, 6 and 7 of the eight /26 blocks in a /23.
  transit4_instances = {
    gw1 = { zone = "az-1", subnet = cidrsubnet(local.transit4_cidr, 3, 6) }
    gw2 = { zone = "az-2", subnet = cidrsubnet(local.transit4_cidr, 3, 7) }
    gw3 = { zone = "az-3", subnet = cidrsubnet(local.transit4_cidr, 3, 5) }
  }

  spoke4_instances = {
    gw1 = { zone = "az-1", subnet = cidrsubnet(local.spoke4_cidr, 3, 6) }
    gw2 = { zone = "az-2", subnet = cidrsubnet(local.spoke4_cidr, 3, 7) }
    gw3 = { zone = "az-3", subnet = cidrsubnet(local.spoke4_cidr, 3, 5) }
  }

  azure_cloud_type = 8
  gw_size          = "Standard_D2s_v5"
}

# ---------------------------------------------------------------- transit4

resource "aviatrix_vpc" "transit4" {
  cloud_type           = local.azure_cloud_type
  account_name         = var.account
  region               = var.region
  name                 = "transit4-vnet"
  cidr                 = local.transit4_cidr
  aviatrix_transit_vpc = false # the legacy transit VPC flag is only supported on AWS and Alibaba
  aviatrix_firenet_vpc = false
}

resource "aviatrix_transit_group" "transit4" {
  group_name          = "transit4"
  cloud_type          = local.azure_cloud_type
  gw_type             = "TRANSIT"
  account_name        = var.account
  vpc_id              = aviatrix_vpc.transit4.vpc_id
  vpc_region          = var.region
  group_instance_size = local.gw_size

  enable_connected_transit = true
}

resource "aviatrix_transit_instance" "transit4" {
  for_each = local.transit4_instances

  group_uuid  = aviatrix_transit_group.transit4.group_uuid
  gw_name     = "transit4-${each.key}"
  gw_size     = local.gw_size
  insane_mode = true # HPE
  subnet      = each.value.subnet
  zone        = each.value.zone
}

# Full mesh: transit4 to each of the three module-built transits.
#
# Peerings and attachments are made by the name of the group's first gateway (transit4-gw1), the way the
# modules do it with their primary gateway. The controller applies them to the whole group. The group
# name itself ("transit4") cannot be used: provider 10.0.20 looks it up as a gateway and fails with
# "failed to get gateway transit4: ErrNotFound".
resource "aviatrix_transit_gateway_peering" "transit4" {
  for_each = module.mc-transit

  transit_gateway_name1  = aviatrix_transit_instance.transit4["gw1"].gw_name
  transit_gateway_name2  = each.value.transit_gateway.gw_name
  enable_max_performance = true # HPE

  depends_on = [aviatrix_transit_instance.transit4]
}

# ---------------------------------------------------------------- spoke4

resource "aviatrix_vpc" "spoke4" {
  cloud_type           = local.azure_cloud_type
  account_name         = var.account
  region               = var.region
  name                 = "spoke4-vnet"
  cidr                 = local.spoke4_cidr
  aviatrix_transit_vpc = false
  aviatrix_firenet_vpc = false

  # Same layout as the module-built spokes, with one more pair: pair 0 is reserved for gateways, pairs
  # 1 to 3 host the three gw-to-gw test VMs (one per availability zone).
  num_of_subnet_pairs = 4
  subnet_size         = 28
}

resource "aviatrix_spoke_group" "spoke4" {
  group_name          = "spoke4"
  cloud_type          = local.azure_cloud_type
  gw_type             = "SPOKE"
  account_name        = var.account
  vpc_id              = aviatrix_vpc.spoke4.vpc_id
  vpc_region          = var.region
  group_instance_size = local.gw_size
}

resource "aviatrix_spoke_instance" "spoke4" {
  for_each = local.spoke4_instances

  group_uuid  = aviatrix_spoke_group.spoke4.group_uuid
  gw_name     = "spoke4-${each.key}"
  gw_size     = local.gw_size
  insane_mode = true # HPE
  subnet      = each.value.subnet
  zone        = each.value.zone
}

resource "aviatrix_spoke_transit_attachment" "spoke4" {
  spoke_gw_name          = aviatrix_spoke_instance.spoke4["gw1"].gw_name
  transit_gw_name        = aviatrix_transit_instance.transit4["gw1"].gw_name
  enable_max_performance = true # HPE

  depends_on = [aviatrix_spoke_instance.spoke4, aviatrix_transit_instance.transit4]
}
