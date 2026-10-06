resource "azurerm_storage_account" "exports" {
  count                             = local.data_enabled ? 1 : 0
  name                              = "st${local.resource_token}"
  location                          = azurerm_resource_group.main.location
  resource_group_name               = azurerm_resource_group.main.name
  account_kind                      = "StorageV2"
  account_tier                      = "Standard"
  account_replication_type          = var.storage_sku == "Standard_ZRS" ? "ZRS" : "LRS"
  is_hns_enabled                    = false
  https_traffic_only_enabled        = true
  min_tls_version                   = "TLS1_2"
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  cross_tenant_replication_enabled  = false
  default_to_oauth_authentication   = true
  infrastructure_encryption_enabled = true
  public_network_access             = var.allow_native_export_trusted_services ? "Enabled" : "Disabled"
  tags                              = local.tags

  network_rules {
    default_action             = "Deny"
    bypass                     = var.allow_native_export_trusted_services ? ["AzureServices"] : ["None"]
    ip_rules                   = []
    virtual_network_subnet_ids = []
  }

  blob_properties {
    versioning_enabled  = false
    change_feed_enabled = false
  }

  lifecycle {
    # Defender for Storage adds its malware scanner as a resource access rule; removing it would stop scanning.
    ignore_changes = [network_rules[0].private_link_access]
  }
}

resource "azurerm_storage_container" "data" {
  for_each              = local.data_enabled ? local.containers : {}
  name                  = each.value
  storage_account_id    = azurerm_storage_account.exports[0].id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "exports" {
  count              = local.data_enabled ? 1 : 0
  storage_account_id = azurerm_storage_account.exports[0].id

  rule {
    name    = "focus-daily-snapshots"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["cost-exports/focus-daily/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.daily_export_retention_days
      }
    }
  }

  rule {
    name    = "focus-closed-months"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["cost-exports/focus/"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.closed_month_retention_days
      }
    }
  }

  depends_on = [azurerm_storage_container.data]
}

locals {
  # /api/report writes snapshots under the API's own identity, so it needs more than read on report-snapshots.
  container_role_assignments = local.data_enabled ? {
    "api-reader-exports"       = { container = "exports", principal = "api", role = "blob_data_reader" }
    "api-reader-reports"       = { container = "reports", principal = "api", role = "blob_data_reader" }
    "api-writer-control"       = { container = "control", principal = "api", role = "blob_data_contributor" }
    "api-writer-reports"       = { container = "reports", principal = "api", role = "blob_data_contributor" }
    "processor-writer-exports" = { container = "exports", principal = "processor", role = "blob_data_contributor" }
    "processor-writer-reports" = { container = "reports", principal = "processor", role = "blob_data_contributor" }
    "processor-writer-control" = { container = "control", principal = "processor", role = "blob_data_contributor" }
  } : {}
}

resource "azurerm_role_assignment" "containers" {
  for_each                         = local.container_role_assignments
  scope                            = azurerm_storage_container.data[each.value.container].id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids[each.value.role]}"
  principal_id                     = each.value.principal == "api" ? azurerm_user_assigned_identity.api.principal_id : azurerm_user_assigned_identity.processor[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Creating a native FOCUS export grants the export's own identity Storage Blob Data Contributor on the
# destination container, but only when the caller (the API identity) can write role assignments on this
# account. The custom role is scoped to this app's own storage account, never customer resources.
resource "azurerm_role_definition" "storage_setup" {
  count       = local.data_enabled ? 1 : 0
  name        = "Cost Assessment Export Storage Setup ${local.resource_token}"
  scope       = azurerm_storage_account.exports[0].id
  description = "Lets the API identity complete the native FOCUS export destination role assignment on this account only. No keys, deletion or data actions."

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

  assignable_scopes = [azurerm_storage_account.exports[0].id]
}

resource "azurerm_role_assignment" "api_storage_setup" {
  count                            = local.data_enabled ? 1 : 0
  scope                            = azurerm_storage_account.exports[0].id
  role_definition_id               = azurerm_role_definition.storage_setup[0].role_definition_resource_id
  principal_id                     = azurerm_user_assigned_identity.api.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Export creation also validates the destination account's management-plane configuration (network rules,
# blob service properties) in the same request; the narrow custom role alone is not enough for that.
resource "azurerm_role_assignment" "api_storage_account_contributor" {
  count                            = local.data_enabled ? 1 : 0
  scope                            = azurerm_storage_account.exports[0].id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids.storage_account_contributor}"
  principal_id                     = azurerm_user_assigned_identity.api.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_private_dns_zone" "blob" {
  count               = local.data_enabled ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count                = local.data_enabled ? 1 : 0
  name                 = "link-${local.resource_token}"
  private_dns_zone_id  = azurerm_private_dns_zone.blob[0].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_endpoint" "blob" {
  count               = local.data_enabled ? 1 : 0
  name                = "pe-blob-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.exports[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob[0].id]
  }
}
