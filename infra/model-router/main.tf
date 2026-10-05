# Optional operator template: adds the approved Model Router deployment to an existing Foundry account
# (for example ai-<token> from the ai profile) without touching the account itself.
#
#   terraform -chdir=infra/model-router init
#   terraform -chdir=infra/model-router apply -var resource_group_name=<rg> -var account_name=<ai-account>

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

variable "resource_group_name" {
  description = "Resource group that holds the Foundry account."
  type        = string
}

variable "account_name" {
  description = "Existing Foundry (AIServices) account name."
  type        = string

  validation {
    condition     = length(var.account_name) >= 2 && length(var.account_name) <= 64
    error_message = "account_name must be 2-64 characters."
  }
}

resource "azurerm_cognitive_deployment" "model_router" {
  name                   = "model-router"
  cognitive_account_id   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.CognitiveServices/accounts/${var.account_name}"
  version_upgrade_option = "NoAutoUpgrade"

  model {
    format  = "OpenAI"
    name    = "model-router"
    version = "2025-11-18"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 20
  }
}

output "deployment_name" {
  value = azurerm_cognitive_deployment.model_router.name
}

output "deployment_id" {
  value = azurerm_cognitive_deployment.model_router.id
}
