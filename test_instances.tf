# Six gw-to-gw traffic-generator VMs: two per spoke VNet, deployed into the
# non-gateway public subnets (pair 0 is reserved for the Aviatrix spoke
# gateways) so each VM can carry a public IP for SSH without asymmetric
# routing. Cross-spoke traffic between instances still targets private IPs,
# so it transits the Aviatrix spoke/transit gateway mesh.

data "http" "my_ip" {
  url = "https://api.ipify.org"
}

locals {
  test_instance_layout = flatten([
    for spoke_idx, spoke_key in sort(keys(local.spokes)) : [
      for subnet_slot in [1, 2] : {
        key          = "${spoke_key}-${subnet_slot}"
        spoke_key    = spoke_key
        subnet_index = subnet_slot
        global_index = spoke_idx * 2 + (subnet_slot - 1)
      }
    ]
  ])

  test_instances = {
    for inst in local.test_instance_layout : inst.key => merge(inst, {
      name           = "${inst.spoke_key}-testvm-${inst.subnet_index}"
      port           = 5201 + inst.global_index
      subnet_id      = module.mc-spoke[inst.spoke_key].vpc.public_subnets[inst.subnet_index].subnet_id
      resource_group = module.mc-spoke[inst.spoke_key].vpc.resource_group
      private_ip     = cidrhost(module.mc-spoke[inst.spoke_key].vpc.public_subnets[inst.subnet_index].cidr, 4)
    })
  }

  test_vm_bandwidth_per_stream_mbps = var.traffic_bandwidth_mbps / var.traffic_parallel_streams
}

resource "azurerm_network_security_group" "test_vm" {
  for_each            = local.spokes
  name                = "${each.key}-testvm-nsg"
  location            = var.region
  resource_group_name = module.mc-spoke[each.key].vpc.resource_group

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
    destination_port_range     = "5201-5206"
    source_address_prefixes    = [for k, v in local.spokes : v.cidr]
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
    server_ports              = [for i in range(6) : 5201 + i]
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
