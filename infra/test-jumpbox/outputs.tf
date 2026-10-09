output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "bastion_name" {
  value = azurerm_bastion_host.main.name
}

output "vm_name" {
  value = azurerm_windows_virtual_machine.jumpbox.name
}

output "vm_id" {
  value = azurerm_windows_virtual_machine.jumpbox.id
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

# The private endpoint's address in the jump box's network, which the private DNS zone returns for the app's host.
output "private_endpoint_ip" {
  value = azurerm_private_endpoint.app.private_service_connection[0].private_ip_address
}

output "private_endpoint_id" {
  value = azurerm_private_endpoint.app.id
}

output "app_url" {
  value = "https://${var.app_host}"
}

output "trusts_private_ca" {
  value = local.trust_ca
}
