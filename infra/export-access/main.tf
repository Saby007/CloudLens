# Optional operator template: least-privilege custom roles that let the API configure, and the processor run,
# native Cost Management exports on the subscription this is applied to, plus setup rights on the export
# destination account. It creates no resources besides role definitions and assignments.
#
#   terraform -chdir=infra/export-access init
#   terraform -chdir=infra/export-access apply \
#     -var storage_resource_group_name=<rg> -var storage_account_name=<account> \
#     -var api_principal_id=<id-api principal> -var worker_principal_id=<id-processor principal>

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

locals {
  subscription_id        = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  storage_account_id     = "${local.subscription_id}/resourceGroups/${var.storage_resource_group_name}/providers/Microsoft.Storage/storageAccounts/${var.storage_account_name}"
  role_definition_prefix = "${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/"
}

resource "azurerm_role_definition" "api_export" {
  role_definition_id = uuidv5("url", "${local.storage_account_id}/cost-assessment-api-export-configurator")
  name               = "Cost Assessment Export Configurator ${var.storage_account_name}"
  scope              = local.subscription_id
  description        = "Read, configure, and run Cost Management exports on the selected subscription. No export deletion or general resource management."

  permissions {
    actions = [
      "Microsoft.Authorization/permissions/read",
      "Microsoft.CostManagement/exports/read",
      "Microsoft.CostManagement/exports/write",
      "Microsoft.CostManagement/exports/action",
      "Microsoft.CostManagement/exports/run/action",
    ]
    not_actions      = []
    data_actions     = []
    not_data_actions = []
  }

  assignable_scopes = [local.subscription_id]
}

resource "azurerm_role_definition" "worker_export" {
  role_definition_id = uuidv5("url", "${local.storage_account_id}/cost-assessment-worker-export-executor")
  name               = "Cost Assessment Export Executor ${var.storage_account_name}"
  scope              = local.subscription_id
  description        = "Read and run Cost Management exports on the selected subscription. No export creation, modification, deletion, or cost queries."

  permissions {
    actions = [
      "Microsoft.Authorization/permissions/read",
      "Microsoft.CostManagement/exports/read",
      "Microsoft.CostManagement/exports/action",
      "Microsoft.CostManagement/exports/run/action",
    ]
    not_actions      = []
    data_actions     = []
    not_data_actions = []
  }

  assignable_scopes = [local.subscription_id]
}

resource "azurerm_role_definition" "storage_setup" {
  role_definition_id = uuidv5("url", "${local.storage_account_id}/cost-assessment-export-storage-setup")
  name               = "Cost Assessment Export Storage Setup ${var.storage_account_name}"
  scope              = local.storage_account_id
  description        = "Export setup for this destination account only: account read/write and role-assignment read/write. No keys, deletion, or data actions."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/read",
      "Microsoft.Authorization/permissions/read",
      "Microsoft.Authorization/roleAssignments/read",
      "Microsoft.Authorization/roleAssignments/write",
    ]
    not_actions      = []
    data_actions     = []
    not_data_actions = []
  }

  assignable_scopes = [local.storage_account_id]
}

resource "azurerm_role_assignment" "api_export" {
  scope                            = local.subscription_id
  role_definition_id               = azurerm_role_definition.api_export.role_definition_resource_id
  principal_id                     = var.api_principal_id
  principal_type                   = "ServicePrincipal"
  description                      = "Operator-approved API export setup access."
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "worker_export" {
  scope                            = local.subscription_id
  role_definition_id               = azurerm_role_definition.worker_export.role_definition_resource_id
  principal_id                     = var.worker_principal_id
  principal_type                   = "ServicePrincipal"
  description                      = "Operator-approved worker export execution access."
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "api_storage_setup" {
  scope                            = local.storage_account_id
  role_definition_id               = azurerm_role_definition.storage_setup.role_definition_resource_id
  principal_id                     = var.api_principal_id
  principal_type                   = "ServicePrincipal"
  description                      = "Operator-approved setup authority on the export destination account only."
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "api_cost_management_contributor" {
  count                            = var.enable_api_cost_management_contributor ? 1 : 0
  scope                            = local.subscription_id
  role_definition_id               = "${local.role_definition_prefix}434105ed-43f6-45c7-a02f-909b2ba83430"
  principal_id                     = var.api_principal_id
  principal_type                   = "ServicePrincipal"
  description                      = "Operator-approved API-only Cost Management compatibility grant."
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "api_storage_account_contributor" {
  count                            = var.enable_api_storage_account_contributor ? 1 : 0
  scope                            = local.storage_account_id
  role_definition_id               = "${local.role_definition_prefix}17d1049b-9a84-46fb-8f53-869881c3d3ab"
  principal_id                     = var.api_principal_id
  principal_type                   = "ServicePrincipal"
  description                      = "Operator-approved API-only compatibility grant at this storage account."
  skip_service_principal_aad_check = true
}
