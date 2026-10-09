variable "environment_name" {
  description = "azd environment name of the CloudLens deployment under test; names everything here and tags it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,40}$", var.environment_name))
    error_message = "environment_name must be 1-41 lowercase letters, digits or hyphens."
  }
}

variable "location" {
  description = "Azure region of the jump box, Bastion and private endpoint. Use the application's region unless you are testing another one: private endpoints to a Private Link Service work across regions, at a small latency cost."
  type        = string
  default     = "centralindia"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be an Azure location code such as centralindia."
  }
}

variable "resource_group_name" {
  description = "Resource group to create. Defaults to rg-<environment_name>-jumpbox, separate from the application's."
  type        = string
  default     = ""
}

variable "private_link_service_id" {
  description = "Resource ID of the app's Private Link Service (azd env get-value APP_PRIVATE_LINK_ID)."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft.Network/privateLinkServices/[^/]+$", var.private_link_service_id))
    error_message = "private_link_service_id must be the resource ID of a Private Link Service."
  }
}

variable "app_host" {
  description = "The host name the app is served on (azd env get-value APP_INGRESS_HOST). A private DNS zone of this name points it at the private endpoint."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.app_host))
    error_message = "app_host must be a lowercase host name such as cloudlens.contoso.com."
  }
}

variable "ca_certificate_pem" {
  description = "PEM certificate of the CA that signed the app's certificate, installed on the VM as a trusted root. Empty skips it (a certificate from a public or enterprise CA the VM already trusts)."
  type        = string
  default     = ""

  validation {
    condition     = var.ca_certificate_pem == "" || (strcontains(var.ca_certificate_pem, "-----BEGIN CERTIFICATE-----") && !strcontains(var.ca_certificate_pem, "PRIVATE KEY"))
    error_message = "ca_certificate_pem must be a PEM certificate, and never a private key."
  }
}

variable "manual_connection" {
  description = "Request the private endpoint connection manually, for a Private Link Service whose subscription is not on its auto-approval list. The connection then waits for approval on the service."
  type        = bool
  default     = false
}

variable "vnet_address_prefix" {
  description = "Address space of the jump box's virtual network, a /24: Bastion, the VM and the private endpoint take one subnet each. It needs no relation to the application's network."
  type        = string
  default     = "10.50.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.vnet_address_prefix)) && tonumber(split("/", var.vnet_address_prefix)[1]) == 24
    error_message = "vnet_address_prefix must be an IPv4 /24."
  }
}

variable "bastion_sku" {
  description = "Basic is the cheapest SKU with a portal browser session. Standard adds native client and file transfer."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard"], var.bastion_sku)
    error_message = "bastion_sku must be Basic or Standard."
  }
}

variable "vm_size" {
  description = "Size of the Windows jump box. Two vCPUs and 8 GB are comfortable for a browser."
  type        = string
  default     = "Standard_B2ms"
}

variable "admin_username" {
  description = "Local administrator of the VM; the password is generated and kept in the Terraform state."
  type        = string
  default     = "cloudlensadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,19}$", var.admin_username)) && !contains(["administrator", "admin", "user", "guest"], var.admin_username)
    error_message = "admin_username must be 3-20 lowercase letters and digits, starting with a letter, and not a reserved name."
  }
}

variable "auto_shutdown_enabled" {
  description = "Deallocate the VM every day, so a forgotten jump box stops costing compute. Bastion keeps billing until it is destroyed."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "UTC time (HHmm) of the daily shutdown."
  type        = string
  default     = "1800"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "auto_shutdown_time must use HHmm, for example 1800."
  }
}
