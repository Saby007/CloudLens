output "api_export_role_id" {
  value = azurerm_role_definition.api_export.role_definition_resource_id
}

output "worker_export_role_id" {
  value = azurerm_role_definition.worker_export.role_definition_resource_id
}

output "storage_setup_role_id" {
  value = azurerm_role_definition.storage_setup.role_definition_resource_id
}

output "api_export_assignment_id" {
  value = azurerm_role_assignment.api_export.id
}

output "worker_export_assignment_id" {
  value = azurerm_role_assignment.worker_export.id
}

output "api_storage_setup_assignment_id" {
  value = azurerm_role_assignment.api_storage_setup.id
}

output "api_cost_management_contributor_assignment_id" {
  value = var.enable_api_cost_management_contributor ? azurerm_role_assignment.api_cost_management_contributor[0].id : ""
}

output "api_storage_account_contributor_assignment_id" {
  value = var.enable_api_storage_account_contributor ? azurerm_role_assignment.api_storage_account_contributor[0].id : ""
}
