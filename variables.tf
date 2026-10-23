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