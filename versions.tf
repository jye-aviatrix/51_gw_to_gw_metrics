terraform {
  required_version = ">= 1.0"

  required_providers {
    aviatrix = {
      source = "AviatrixSystems/aviatrix"
      # No 8.1.40 provider is published; 8.1.30 is the newest release not ahead of an 8.1.40 controller.
      version = "8.1.30"
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
