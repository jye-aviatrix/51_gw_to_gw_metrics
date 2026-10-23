# Configure Azure provider (credentials from ARM_* environment variables)
provider "azurerm" {
  features {}
}

# Configure Aviatrix provider
provider "aviatrix" {
  controller_ip           = var.controller_ip
  username                = var.controller_username
  password                = var.controller_password
  skip_version_validation = false
  verify_ssl_certificate  = false
}

