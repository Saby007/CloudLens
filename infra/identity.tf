resource "azurerm_user_assigned_identity" "api" {
  name                = "id-api-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# The API's second identity: it only signs the client assertion for the user's on-behalf-of exchange.
resource "azurerm_user_assigned_identity" "obo" {
  name                = "id-obo-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "processor" {
  count               = local.data_enabled ? 1 : 0
  name                = "id-processor-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Cluster control-plane identity. User-assigned so its network grant exists before the cluster is created.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Node (kubelet) identity: pulls the app images from the registry. Owned here so AcrPull is granted before any node starts.
resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-kubelet-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Joins nodes to the subnet and attaches the Terraform-owned ingress IP to the cluster load balancer;
# AKS documents resource-group scope for a static IP outside the node resource group.
resource "azurerm_role_assignment" "aks_network" {
  scope                            = azurerm_resource_group.main.id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids.network_contributor}"
  principal_id                     = azurerm_user_assigned_identity.aks.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# AKS requires the control plane to be able to assign the custom kubelet identity to the nodes.
resource "azurerm_role_assignment" "aks_kubelet_operator" {
  scope                            = azurerm_user_assigned_identity.kubelet.id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids.managed_identity_operator}"
  principal_id                     = azurerm_user_assigned_identity.aks.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.main.id
  role_definition_id               = "${local.role_definition_prefix}${local.role_ids.acr_pull}"
  principal_id                     = azurerm_user_assigned_identity.kubelet.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "time_sleep" "aks_identity_propagation" {
  create_duration = "60s"

  triggers = {
    network  = azurerm_role_assignment.aks_network.id
    operator = azurerm_role_assignment.aks_kubelet_operator.id
    acr_pull = azurerm_role_assignment.kubelet_acr_pull.id
  }
}

# Workload identity: pods exchange their service account token for these identities, so no secrets are stored.
locals {
  workload_identities = merge(
    {
      api = { identity_id = azurerm_user_assigned_identity.api.id, service_account = "api" }
      obo = { identity_id = azurerm_user_assigned_identity.obo.id, service_account = "api" }
    },
    local.data_enabled ? {
      processor = { identity_id = azurerm_user_assigned_identity.processor[0].id, service_account = "processor" }
    } : {}
  )
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each                  = local.workload_identities
  name                      = "aks-${local.namespace}-${each.value.service_account}"
  user_assigned_identity_id = each.value.identity_id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.namespace}:${each.value.service_account}"
}
