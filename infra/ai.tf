resource "azurerm_cognitive_account" "ai" {
  count                         = local.ai_enabled ? 1 : 0
  name                          = "ai-${local.resource_token}"
  location                      = var.foundry_location
  resource_group_name           = azurerm_resource_group.main.name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "ai-${local.resource_token}"
  project_management_enabled    = true
  local_auth_enabled            = false
  public_network_access_enabled = false
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }

  network_acls {
    default_action = "Deny"
  }
}

resource "azurerm_cognitive_account_project" "ai" {
  count                = local.ai_enabled ? 1 : 0
  name                 = var.foundry_project_name
  cognitive_account_id = azurerm_cognitive_account.ai[0].id
  location             = var.foundry_location
  display_name         = "Cost Assessment AI"
  description          = "Scoped cost evidence narration; agent initialization is a separate approved stage."
  tags                 = local.tags

  identity {
    type = "SystemAssigned"
  }
}

locals {
  ai_private_zones = local.ai_enabled ? toset([
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
  ]) : toset([])
}

resource "azurerm_private_dns_zone" "ai" {
  for_each            = local.ai_private_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "ai" {
  for_each             = local.ai_private_zones
  name                 = "link-${local.resource_token}"
  private_dns_zone_id  = azurerm_private_dns_zone.ai[each.value].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

# Account-level operations run one at a time (project, then endpoint, then models): a Foundry account
# rejects a second change while the previous one is still settling.
resource "azurerm_private_endpoint" "ai" {
  count               = local.ai_enabled ? 1 : 0
  name                = "pe-ai-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "account"
    private_connection_resource_id = azurerm_cognitive_account.ai[0].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [for zone in sort(tolist(local.ai_private_zones)) : azurerm_private_dns_zone.ai[zone].id]
  }

  depends_on = [azurerm_cognitive_account_project.ai]
}

resource "azurerm_cognitive_deployment" "models" {
  for_each               = local.ai_enabled ? { for model in var.model_deployments : model.name => model } : {}
  name                   = each.key
  cognitive_account_id   = azurerm_cognitive_account.ai[0].id
  version_upgrade_option = "NoAutoUpgrade"

  model {
    format  = each.value.modelFormat
    name    = each.value.modelName
    version = each.value.modelVersion
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }

  depends_on = [azurerm_private_endpoint.ai]
}

resource "azurerm_role_assignment" "api_foundry_user" {
  count                            = local.ai_enabled ? 1 : 0
  scope                            = azurerm_cognitive_account_project.ai[0].id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids.azure_ai_user}"
  principal_id                     = azurerm_user_assigned_identity.api.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "api_model_caller" {
  count                            = local.ai_enabled ? 1 : 0
  scope                            = azurerm_cognitive_account.ai[0].id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids.cognitive_openai_user}"
  principal_id                     = azurerm_user_assigned_identity.api.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
