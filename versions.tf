terraform {
  required_version = ">= 1.0"

  required_providers {
    aviatrix = {
      source = "AviatrixSystems/aviatrix"
      # Group resources (aviatrix_transit_group, aviatrix_transit_instance, aviatrix_spoke_group,
      # aviatrix_spoke_instance) need provider 9.x or later. The controller is 10.0.21; provider 10.1.x
      # looks up gateway groups with an API this controller does not have and fails even for existing
      # gateways, so stay on the 10.0 line (and on the 9.x modules, which accept it).
      version = "10.0.20"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.10.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.0"
    }
  }
}
