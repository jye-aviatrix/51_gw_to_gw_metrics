variable "aviatrix_controller_ip" {
  description = "Aviatrix Controller public IP or FQDN"
  type        = string
}

variable "aviatrix_username" {
  description = "Aviatrix Controller username"
  type        = string
}

variable "aviatrix_password" {
  description = "Aviatrix Controller password"
  type        = string
  sensitive   = true
}

variable "aviatrix_skip_version_validation" {
  description = "Skip provider/controller version check (needed when provider version != controller version)"
  type        = bool
  default     = true
}
