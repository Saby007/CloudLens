# Container Insights needs both a private ingestion endpoint and configuration access; closing the workspace alone
# would silently stop the monitoring agent. The Blob zone is shared with the export account, not duplicated.
locals {
  monitor_private_zones = var.aks_private_cluster ? toset([
    "privatelink.monitor.azure.com",
    "privatelink.oms.opinsights.azure.com",
    "privatelink.ods.opinsights.azure.com",
    "privatelink.agentsvc.azure-automation.net",
  ]) : toset([])
}

resource "azurerm_monitor_private_link_scope" "main" {
  count                 = var.aks_private_cluster ? 1 : 0
  name                  = "ampls-${local.resource_token}"
  resource_group_name   = azurerm_resource_group.main.name
  ingestion_access_mode = "PrivateOnly"
  query_access_mode     = "PrivateOnly"
  tags                  = local.tags
}

resource "azurerm_monitor_data_collection_endpoint" "private" {
  count                         = var.aks_private_cluster ? 1 : 0
  name                          = "dce-${local.resource_token}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  kind                          = "Linux"
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_monitor_private_link_scoped_service" "workspace" {
  count               = var.aks_private_cluster ? 1 : 0
  name                = "workspace"
  resource_group_name = azurerm_resource_group.main.name
  scope_name          = azurerm_monitor_private_link_scope.main[0].name
  linked_resource_id  = azurerm_log_analytics_workspace.main.id
}

resource "azurerm_monitor_private_link_scoped_service" "endpoint" {
  count               = var.aks_private_cluster ? 1 : 0
  name                = "collection-endpoint"
  resource_group_name = azurerm_resource_group.main.name
  scope_name          = azurerm_monitor_private_link_scope.main[0].name
  linked_resource_id  = azurerm_monitor_data_collection_endpoint.private[0].id
}

resource "azurerm_private_dns_zone" "monitor" {
  for_each            = local.monitor_private_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "monitor" {
  for_each             = local.monitor_private_zones
  name                 = "link-${local.resource_token}"
  private_dns_zone_id  = azurerm_private_dns_zone.monitor[each.value].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_endpoint" "monitor" {
  count               = var.aks_private_cluster ? 1 : 0
  name                = "pe-monitor-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "monitor"
    private_connection_resource_id = azurerm_monitor_private_link_scope.main[0].id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = concat(
      [for zone in sort(tolist(local.monitor_private_zones)) : azurerm_private_dns_zone.monitor[zone].id],
      [azurerm_private_dns_zone.blob[0].id],
    )
  }

  depends_on = [
    azurerm_monitor_private_link_scoped_service.workspace,
    azurerm_monitor_private_link_scoped_service.endpoint,
    azurerm_private_dns_zone_virtual_network_link.monitor,
    azurerm_private_dns_zone_virtual_network_link.blob,
  ]
}

resource "azurerm_monitor_data_collection_rule_association" "private_endpoint" {
  count                       = var.aks_private_cluster ? 1 : 0
  target_resource_id          = azurerm_kubernetes_cluster.main.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.private[0].id
  description                 = "Private configuration access for the Container Insights agent."

  depends_on = [azurerm_private_endpoint.monitor]
}
