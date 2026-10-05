variable "storage_resource_group_name" {
  description = "Existing resource group containing the export destination storage account."
  type        = string
}

variable "storage_account_name" {
  description = "Existing export destination storage account (st<token> in the deployment resource group)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase letters or digits."
  }
}

variable "api_principal_id" {
  description = "Principal ID of the API managed identity (id-api-*)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.api_principal_id))
    error_message = "api_principal_id must be a GUID."
  }
}

variable "worker_principal_id" {
  description = "Principal ID of the processor managed identity (id-processor-*)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.worker_principal_id))
    error_message = "worker_principal_id must be a GUID."
  }
}

variable "enable_api_cost_management_contributor" {
  description = "Explicit operator approval for broader built-in Cost Management Contributor access for the API only."
  type        = bool
  default     = false
}

variable "enable_api_storage_account_contributor" {
  description = "Explicit operator approval for built-in Storage Account Contributor access for the API at the destination account only."
  type        = bool
  default     = false
}
