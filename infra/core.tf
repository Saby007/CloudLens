resource "azurerm_log_analytics_workspace" "main" {
  name                         = "law-${local.resource_token}"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_container_registry" "main" {
  name                          = "acr${local.resource_token}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = "Basic"
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = local.tags
}
