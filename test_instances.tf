# Nine gw-to-gw traffic-generator VMs: two per spoke VNet for spoke1-3 (from the
# modules) and three for spoke4 (from the spoke group in hpe_groups.tf, one per
# availability zone to match its three gateways), deployed into the
# non-gateway public subnets (pair 0 is reserved for the Aviatrix spoke
# gateways) so each VM can carry a public IP for SSH without asymmetric
# routing. Cross-spoke traffic between instances still targets private IPs,
# so it transits the Aviatrix spoke/transit gateway mesh.

data "http" "my_ip" {
  url = "https://api.ipify.org"
}

locals {
  # One entry per spoke VNet, whichever way the spoke was built, with what the test VMs need.
  spoke_vnets = merge(
    {
      for k, m in module.mc-spoke : k => {
        cidr           = local.spokes[k].cidr
        resource_group = m.vpc.resource_group
        public_subnets = m.vpc.public_subnets
        vm_slots       = [1, 2] # public subnet pairs 1 and 2; pair 0 holds the gateways
        vm_zonal       = false
      }
    },
    {
      spoke4 = {
        cidr           = local.spoke4_cidr
        resource_group = aviatrix_vpc.spoke4.resource_group
        public_subnets = aviatrix_vpc.spoke4.public_subnets
        vm_slots       = [1, 2, 3] # one VM per availability zone: slot n runs in zone n
        vm_zonal       = true
      }
    },
  )

  test_instance_slots = flatten([
    for spoke_key in sort(keys(local.spoke_vnets)) : [
      for subnet_slot in local.spoke_vnets[spoke_key].vm_slots : {
        key          = "${spoke_key}-${subnet_slot}"
        spoke_key    = spoke_key
        subnet_index = subnet_slot
        zone         = local.spoke_vnets[spoke_key].vm_zonal ? tostring(subnet_slot) : null
      }
    ]
  ])

  # global_index (and so the iperf3 port) follows the order above, so the first six VMs keep 5201-5206.
  test_instance_layout = [for i, inst in local.test_instance_slots : merge(inst, { global_index = i })]

  test_instances = {
    for inst in local.test_instance_layout : inst.key => merge(inst, {
      name           = "${inst.spoke_key}-testvm-${inst.subnet_index}"
      port           = 5201 + inst.global_index
      subnet_id      = local.spoke_vnets[inst.spoke_key].public_subnets[inst.subnet_index].subnet_id
      resource_group = local.spoke_vnets[inst.spoke_key].resource_group
      private_ip     = cidrhost(local.spoke_vnets[inst.spoke_key].public_subnets[inst.subnet_index].cidr, 4)
    })
  }

  test_vm_bandwidth_per_stream_mbps = var.traffic_bandwidth_mbps / var.traffic_parallel_streams

  # Every VM runs one iperf3 server per VM in the mesh (ports 5201...).
  iperf_server_ports = [for i in range(length(local.test_instance_layout)) : 5201 + i]
}

resource "azurerm_network_security_group" "test_vm" {
  for_each            = local.spoke_vnets
  name                = "${each.key}-testvm-nsg"
  location            = var.region
  resource_group_name = each.value.resource_group

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "${chomp(data.http.my_ip.response_body)}/32"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowIperf3Mesh"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "${min(local.iperf_server_ports...)}-${max(local.iperf_server_ports...)}"
    source_address_prefixes    = [for k, v in local.spoke_vnets : v.cidr]
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "test_vm" {
  for_each            = local.test_instances
  name                = "${each.value.name}-pip"
  location            = var.region
  resource_group_name = each.value.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "test_vm" {
  for_each            = local.test_instances
  name                = "${each.value.name}-nic"
  location            = var.region
  resource_group_name = each.value.resource_group

  ip_configuration {
    name                          = "internal"
    subnet_id                     = each.value.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = azurerm_public_ip.test_vm[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "test_vm" {
  for_each                  = local.test_instances
  network_interface_id      = azurerm_network_interface.test_vm[each.key].id
  network_security_group_id = azurerm_network_security_group.test_vm[each.value.spoke_key].id
}

resource "azurerm_linux_virtual_machine" "test_vm" {
  for_each = local.test_instances

  name                = each.value.name
  location            = var.region
  resource_group_name = each.value.resource_group
  size                = var.test_vm_size
  zone                = each.value.zone
  admin_username      = var.test_vm_admin_username
  network_interface_ids = [
    azurerm_network_interface.test_vm[each.key].id,
  ]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.test_vm_admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/templates/test-instance-cloud-init.yaml.tpl", {
    my_port                   = each.value.port
    server_ports              = local.iperf_server_ports
    peer_ips                  = [for k, v in local.test_instances : v.private_ip if k != each.key]
    streams                   = var.traffic_parallel_streams
    bandwidth_per_stream_mbps = local.test_vm_bandwidth_per_stream_mbps
  }))
}

output "test_instance_public_ips" {
  description = "Public IPs of the gw-to-gw test instances, keyed by spoke/subnet slot"
  value       = { for k, v in azurerm_public_ip.test_vm : k => v.ip_address }
}

output "test_instance_private_ips" {
  description = "Private IPs of the gw-to-gw test instances, keyed by spoke/subnet slot"
  value       = { for k, v in local.test_instances : k => v.private_ip }
}
