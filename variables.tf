variable "region" {
  description = "Azure region for all gateways and VNets"
  type        = string
}

variable "account" {
  description = "Aviatrix access account name for Azure"
  type        = string
}

variable "controller_ip" {
  description = "Aviatrix Controller IP or FQDN"
  type        = string
}

variable "controller_username" {
  description = "Aviatrix Controller username"
  type        = string
}

variable "controller_password" {
  description = "Aviatrix Controller password"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into the test instances"
  type        = string
  default     = "~/.ssh/az-key-pair.pub"
}

variable "test_vm_admin_username" {
  description = "Admin username for the test instances"
  type        = string
  default     = "azureuser"
}

variable "test_vm_size" {
  description = "Azure VM size for the test instances"
  type        = string
  default     = "Standard_B1s"
}

variable "traffic_bandwidth_mbps" {
  description = "Total continuous bandwidth (Mbps) each test instance generates towards every other test instance"
  type        = number
  default     = 5
}

variable "traffic_parallel_streams" {
  description = "Number of parallel iperf3 flows used to generate traffic towards each peer"
  type        = number
  default     = 5
}