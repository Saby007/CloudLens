# Offline contract tests with a mocked provider; nothing is created in Azure.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      object_id       = "22222222-2222-2222-2222-222222222222"
      client_id       = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_resource_id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/providers/Microsoft.Authorization/roleDefinitions/88888888-8888-8888-8888-888888888888"
    }
  }
}

variables {
  storage_resource_group_name = "rg-app-test"
  storage_account_name        = "stexample"
  api_principal_id            = "a1a1a1a1-0000-0000-0000-000000000001"
  worker_principal_id         = "a1a1a1a1-0000-0000-0000-000000000003"
}

run "custom_roles_are_least_privilege_and_compatibility_grants_stay_off" {
  command = apply

  assert {
    condition = toset(azurerm_role_definition.api_export.permissions[0].actions) == toset([
      "Microsoft.Authorization/permissions/read",
      "Microsoft.CostManagement/exports/read",
      "Microsoft.CostManagement/exports/write",
      "Microsoft.CostManagement/exports/action",
      "Microsoft.CostManagement/exports/run/action",
    ]) && tolist(azurerm_role_definition.api_export.assignable_scopes) == tolist(["/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"])
    error_message = "The API export role must only read, configure and run exports on the subscription."
  }

  assert {
    condition = toset(azurerm_role_definition.worker_export.permissions[0].actions) == toset([
      "Microsoft.Authorization/permissions/read",
      "Microsoft.CostManagement/exports/read",
      "Microsoft.CostManagement/exports/action",
      "Microsoft.CostManagement/exports/run/action",
    ])
    error_message = "The worker export role must not create or modify exports."
  }

  assert {
    condition = (
      tolist(azurerm_role_definition.storage_setup.assignable_scopes) == tolist(["/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test/providers/Microsoft.Storage/storageAccounts/stexample"]) &&
      contains(azurerm_role_definition.storage_setup.permissions[0].actions, "Microsoft.Authorization/roleAssignments/write") &&
      alltrue([for role in [azurerm_role_definition.api_export, azurerm_role_definition.worker_export, azurerm_role_definition.storage_setup] : length(role.permissions[0].data_actions) == 0 && length(role.permissions[0].not_actions) == 0])
    )
    error_message = "Storage setup must be limited to the destination account and no role may carry data actions."
  }

  assert {
    condition = (
      azurerm_role_assignment.api_export.principal_id == var.api_principal_id &&
      azurerm_role_assignment.worker_export.principal_id == var.worker_principal_id &&
      azurerm_role_assignment.api_storage_setup.scope == azurerm_role_definition.storage_setup.scope &&
      length(azurerm_role_assignment.api_cost_management_contributor) == 0 &&
      length(azurerm_role_assignment.api_storage_account_contributor) == 0 &&
      alltrue([for assignment in [azurerm_role_assignment.api_export, azurerm_role_assignment.worker_export, azurerm_role_assignment.api_storage_setup] : assignment.principal_type == "ServicePrincipal"])
    )
    error_message = "Only the three narrow grants exist unless the compatibility grants are explicitly approved."
  }

  assert {
    condition     = azurerm_role_definition.api_export.role_definition_id == uuidv5("url", "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test/providers/Microsoft.Storage/storageAccounts/stexample/cost-assessment-api-export-configurator")
    error_message = "Role definition IDs must be deterministic so reapplying never duplicates a role."
  }
}

run "compatibility_grants_are_opt_in" {
  command = apply

  variables {
    enable_api_cost_management_contributor = true
    enable_api_storage_account_contributor = true
  }

  assert {
    condition = (
      endswith(azurerm_role_assignment.api_cost_management_contributor[0].role_definition_id, "434105ed-43f6-45c7-a02f-909b2ba83430") &&
      azurerm_role_assignment.api_cost_management_contributor[0].scope == "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      endswith(azurerm_role_assignment.api_storage_account_contributor[0].role_definition_id, "17d1049b-9a84-46fb-8f53-869881c3d3ab") &&
      endswith(azurerm_role_assignment.api_storage_account_contributor[0].scope, "/storageAccounts/stexample") &&
      azurerm_role_assignment.api_storage_account_contributor[0].principal_id == var.api_principal_id
    )
    error_message = "Approved compatibility grants go to the API identity only, at their documented scopes."
  }
}
