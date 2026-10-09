resource "azurerm_log_analytics_workspace" "main" {
  name                         = "law-${local.resource_token}"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  local_authentication_enabled = false
  tags                         = local.tags
}

# Private endpoints need Premium. With dedicated data endpoints the image layers also arrive over the private
# endpoint instead of from public storage. A private registry cannot be reached by ACR Tasks (az acr build, azd's
# remote build), so its images are built on the deploy host.
resource "azurerm_container_registry" "main" {
  name                          = "acr${local.resource_token}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = var.private_registry ? "Premium" : "Basic"
  admin_enabled                 = false
  public_network_access_enabled = !var.private_registry
  data_endpoint_enabled         = var.private_registry
  tags                          = local.tags
}

resource "azurerm_private_dns_zone" "acr" {
  count               = var.private_registry ? 1 : 0
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  count                = var.private_registry ? 1 : 0
  name                 = "link-${local.resource_token}"
  private_dns_zone_id  = azurerm_private_dns_zone.acr[0].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  count               = var.private_registry ? 1 : 0
  name                = "pe-acr-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "registry"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.acr]
}

# Whoever runs the deployment pushes the images, so they need AcrPush; a public registry's cloud-side builds ran as them
# and needed none.
resource "azurerm_role_assignment" "deployer_acr_push" {
  for_each           = local.cluster_admin_principals
  scope              = azurerm_container_registry.main.id
  role_definition_id = "${local.role_definition_prefix}${local.role_ids.acr_push}"
  principal_id       = each.value
}
