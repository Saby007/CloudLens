# Offline contract tests: mocked providers, so no Azure credentials or resources are involved.
# Run with `terraform init -backend=false` then `terraform test` from infra/.
# azurerm still validates argument values against mocks, so every referenced ID below is a well-formed ARM ID.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      object_id       = "22222222-2222-2222-2222-222222222222"
      client_id       = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/virtualNetworks/vnet-test"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/aks-nodes"
    }
  }

  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/publicIPAddresses/pip-ingress-test"
      fqdn       = "cloudlens-test.centralindia.cloudapp.azure.com"
      ip_address = "20.0.0.10"
    }
  }

  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
    }
  }

  mock_resource "azurerm_container_registry" {
    defaults = {
      id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ContainerRegistry/registries/acrtest"
      login_server = "acrtest.azurecr.io"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"
      principal_id = "66666666-6666-6666-6666-666666666666"
      client_id    = "77777777-7777-7777-7777-777777777777"
      tenant_id    = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id              = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ContainerService/managedClusters/aks-test"
      oidc_issuer_url = "https://oidc.example.test/issuer/"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Storage/storageAccounts/sttest"
      primary_blob_endpoint = "https://sttest.blob.core.windows.net/"
    }
  }

  mock_resource "azurerm_storage_container" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Storage/storageAccounts/sttest/blobServices/default/containers/cost-exports"
    }
  }

  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_resource_id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/providers/Microsoft.Authorization/roleDefinitions/88888888-8888-8888-8888-888888888888"
    }
  }

  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/privateDnsZones/privatelink.example"
    }
  }

  mock_resource "azurerm_cognitive_account" {
    defaults = {
      id       = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.CognitiveServices/accounts/ai-test"
      endpoint = "https://ai-test.cognitiveservices.azure.com/"
    }
  }

  mock_resource "azurerm_cognitive_account_project" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.CognitiveServices/accounts/ai-test/projects/cost-agent-project"
    }
  }
}

mock_provider "time" {}

# Distinct principals, so the assertions can tell which identity each grant went to.
override_resource {
  target = azurerm_user_assigned_identity.api
  values = {
    id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-api-test"
    principal_id = "a1a1a1a1-0000-0000-0000-000000000001"
    client_id    = "c1c1c1c1-0000-0000-0000-000000000001"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.obo
  values = {
    id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obo-test"
    principal_id = "a1a1a1a1-0000-0000-0000-000000000002"
    client_id    = "c1c1c1c1-0000-0000-0000-000000000002"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.processor
  values = {
    id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-processor-test"
    principal_id = "a1a1a1a1-0000-0000-0000-000000000003"
    client_id    = "c1c1c1c1-0000-0000-0000-000000000003"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.aks
  values = {
    id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-test"
    principal_id = "a1a1a1a1-0000-0000-0000-000000000004"
    client_id    = "c1c1c1c1-0000-0000-0000-000000000004"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.kubelet
  values = {
    id           = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-kubelet-test"
    principal_id = "a1a1a1a1-0000-0000-0000-000000000005"
    client_id    = "c1c1c1c1-0000-0000-0000-000000000005"
  }
}

variables {
  environment_name = "app-contract-test"
}

run "core_profile_provisions_only_the_hardened_foundation" {
  command = apply

  assert {
    condition     = length(azurerm_storage_account.exports) == 0 && length(azurerm_cognitive_account.ai) == 0 && length(azurerm_user_assigned_identity.processor) == 0
    error_message = "The core profile must not provision storage, Foundry or the processor identity."
  }

  assert {
    condition     = azurerm_resource_group.main.name == "rg-app-contract-test" && azurerm_resource_group.main.tags["azd-env-name"] == "app-contract-test" && azurerm_resource_group.main.tags["app-name"] == "cost-assessment"
    error_message = "The resource group must keep the azd and app tags bootstrap-identity.ps1 relies on."
  }

  assert {
    condition     = azurerm_user_assigned_identity.obo.tags["azd-env-name"] == "app-contract-test" && azurerm_user_assigned_identity.obo.tags["app-name"] == "cost-assessment"
    error_message = "bootstrap-identity.ps1 only trusts an OBO identity carrying the environment and app tags."
  }

  assert {
    condition = alltrue([
      azurerm_kubernetes_cluster.main.local_account_disabled,
      azurerm_kubernetes_cluster.main.oidc_issuer_enabled,
      azurerm_kubernetes_cluster.main.workload_identity_enabled,
      azurerm_kubernetes_cluster.main.azure_active_directory_role_based_access_control[0].azure_rbac_enabled,
    ])
    error_message = "The cluster must use Entra ID with Azure RBAC, workload identity and no local accounts."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.main.network_profile[0].network_plugin == "azure" &&
      azurerm_kubernetes_cluster.main.network_profile[0].network_plugin_mode == "overlay" &&
      azurerm_kubernetes_cluster.main.network_profile[0].network_data_plane == "cilium" &&
      azurerm_kubernetes_cluster.main.network_profile[0].network_policy == "cilium" &&
      azurerm_kubernetes_cluster.main.network_profile[0].dns_service_ip == "10.0.0.10"
    )
    error_message = "The cluster must use Azure CNI Overlay with the Cilium data plane and network policy."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.main.sku_tier == "Standard" &&
      azurerm_kubernetes_cluster.main.automatic_upgrade_channel == "stable" &&
      azurerm_kubernetes_cluster.main.node_os_upgrade_channel == "NodeImage" &&
      azurerm_kubernetes_cluster.main.maintenance_window_auto_upgrade[0].day_of_week == "Sunday" &&
      azurerm_kubernetes_cluster.main.node_provisioning_profile[0].mode == "Manual"
    )
    error_message = "The cluster must default to the Standard tier with scheduled automatic upgrades."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.web_app_routing[0].default_nginx_controller == "None" && length(azurerm_kubernetes_cluster.main.web_app_routing[0].dns_zone_ids) == 0
    error_message = "App routing must be on without its default public controller; the bootstrap hook owns the controller."
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.main.default_node_pool[0].only_critical_addons_enabled &&
      azurerm_kubernetes_cluster.main.default_node_pool[0].os_sku == "AzureLinux" &&
      azurerm_kubernetes_cluster.main.default_node_pool[0].os_disk_type == "Ephemeral" &&
      azurerm_kubernetes_cluster.main.default_node_pool[0].min_count == 2 &&
      toset(azurerm_kubernetes_cluster.main.default_node_pool[0].zones) == toset(["1", "2", "3"])
    )
    error_message = "The system pool must be dedicated, zone-spread Azure Linux with ephemeral OS disks."
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.apps.mode == "User" && azurerm_kubernetes_cluster_node_pool.apps.min_count == 2 && azurerm_kubernetes_cluster_node_pool.apps.os_sku == "AzureLinux"
    error_message = "Applications must run on a separate autoscaled user pool."
  }

  assert {
    condition     = azurerm_container_registry.main.admin_enabled == false && azurerm_log_analytics_workspace.main.local_authentication_enabled == false
    error_message = "The registry admin user and workspace shared keys must stay disabled."
  }

  assert {
    condition = (
      azurerm_role_assignment.kubelet_acr_pull.principal_id == azurerm_user_assigned_identity.kubelet.principal_id &&
      azurerm_kubernetes_cluster.main.kubelet_identity[0].user_assigned_identity_id == azurerm_user_assigned_identity.kubelet.id &&
      endswith(azurerm_role_assignment.kubelet_acr_pull.role_definition_id, "7f951dda-4ed3-4680-a7ca-43fe172d538d") &&
      azurerm_role_assignment.aks_kubelet_operator.principal_id == azurerm_user_assigned_identity.aks.principal_id &&
      endswith(azurerm_role_assignment.aks_kubelet_operator.role_definition_id, "f1a07417-d97a-45cb-824c-7a7467783830")
    )
    error_message = "Only the kubelet identity pulls images (AcrPull), and the control plane may assign it to the nodes."
  }

  assert {
    condition     = azurerm_role_assignment.aks_network.scope == azurerm_resource_group.main.id && endswith(azurerm_role_assignment.aks_network.role_definition_id, "4d97b98b-1d4f-4787-a291-c67834d212e7")
    error_message = "The control-plane identity needs Network Contributor on the resource group for the subnet and static ingress IP."
  }

  assert {
    condition     = keys(azurerm_role_assignment.cluster_admin) == ["22222222-2222-2222-2222-222222222222"]
    error_message = "The deploying principal must be the only cluster admin when azd's principal is the same."
  }

  assert {
    condition = (
      toset(keys(azurerm_federated_identity_credential.workload)) == toset(["api", "obo"]) &&
      azurerm_federated_identity_credential.workload["api"].subject == "system:serviceaccount:cloudlens:api" &&
      azurerm_federated_identity_credential.workload["obo"].subject == "system:serviceaccount:cloudlens:api" &&
      azurerm_federated_identity_credential.workload["api"].issuer == "https://oidc.example.test/issuer/" &&
      tolist(azurerm_federated_identity_credential.workload["api"].audience) == tolist(["api://AzureADTokenExchange"])
    )
    error_message = "The API service account must federate to both the API and OBO identities, and nothing else in core."
  }

  assert {
    condition     = azurerm_public_ip.ingress.sku == "Standard" && azurerm_public_ip.ingress.allocation_method == "Static" && startswith(azurerm_public_ip.ingress.domain_name_label, "cloudlens-")
    error_message = "The ingress must use a static Standard IP with a cloudlens- DNS label."
  }

  assert {
    condition = (
      output.APP_WEB_ORIGIN == "https://cloudlens-test.centralindia.cloudapp.azure.com" &&
      output.APP_INGRESS_HOST == "cloudlens-test.centralindia.cloudapp.azure.com" &&
      output.APP_INGRESS_CLASS == "cloudlens-nginx" &&
      output.APP_TLS_CLUSTER_ISSUER == "letsencrypt" &&
      output.AZURE_AKS_NAMESPACE == "cloudlens"
    )
    error_message = "The ingress outputs must describe the Azure-provided HTTPS origin."
  }

  assert {
    condition = (
      output.APP_PROCESSOR_DEPLOYED == "false" && output.APP_SCHEDULER_ENABLED == "false" &&
      output.MEGHKOSHA_AI_ENABLED == "false" && output.FOUNDRY_CHAT_ENABLED == "false" &&
      output.COST_EXPORT_STORAGE_URL == "" && output.AZURE_PROCESSOR_IDENTITY_CLIENT_ID == "" &&
      output.AI_PROJECT_ENDPOINT == "" && output.FOCUS_EXPORT_PARALLEL_MONTHS == "1"
    )
    error_message = "The core profile must leave the processor, AI and export settings off."
  }

  assert {
    condition     = startswith(output.COST_EXPORT_NAME, "focus-closed-month-") && startswith(output.COST_EXPORT_DAILY_NAME, "focus-daily-") && length(output.COST_EXPORT_NAME) == length("focus-closed-month-") + 13
    error_message = "Export names must carry the 13-character resource token."
  }
}

run "data_profile_adds_private_keyless_export_storage_and_the_processor" {
  command = apply

  variables {
    profile          = "data"
    enable_processor = true
  }

  assert {
    condition = (
      azurerm_storage_account.exports[0].shared_access_key_enabled == false &&
      azurerm_storage_account.exports[0].is_hns_enabled == false &&
      azurerm_storage_account.exports[0].allow_nested_items_to_be_public == false &&
      azurerm_storage_account.exports[0].infrastructure_encryption_enabled &&
      azurerm_storage_account.exports[0].public_network_access == "Disabled" &&
      azurerm_storage_account.exports[0].network_rules[0].default_action == "Deny" &&
      contains(azurerm_storage_account.exports[0].network_rules[0].bypass, "None")
    )
    error_message = "Export storage must be private, key-less blob storage unless the trusted-services exception is approved."
  }

  assert {
    condition     = toset(values(azurerm_storage_container.data)[*].name) == toset(["cost-exports", "report-snapshots", "control-state"])
    error_message = "The three app containers must exist."
  }

  assert {
    condition = (
      azurerm_storage_management_policy.exports[0].rule[0].name == "focus-daily-snapshots" &&
      contains(azurerm_storage_management_policy.exports[0].rule[0].filters[0].prefix_match, "cost-exports/focus-daily/") &&
      azurerm_storage_management_policy.exports[0].rule[0].actions[0].base_blob[0].delete_after_days_since_modification_greater_than == 60 &&
      azurerm_storage_management_policy.exports[0].rule[1].name == "focus-closed-months" &&
      contains(azurerm_storage_management_policy.exports[0].rule[1].filters[0].prefix_match, "cost-exports/focus/") &&
      azurerm_storage_management_policy.exports[0].rule[1].actions[0].base_blob[0].delete_after_days_since_modification_greater_than == 214
    )
    error_message = "Daily snapshots must expire after 60 days and closed months after 214."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.containers) == 7 &&
      endswith(azurerm_role_assignment.containers["api-reader-exports"].role_definition_id, "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1") &&
      endswith(azurerm_role_assignment.containers["api-writer-control"].role_definition_id, "ba92f5b4-2d11-453d-a403-e96b0029c9fe") &&
      azurerm_role_assignment.containers["processor-writer-exports"].principal_id == azurerm_user_assigned_identity.processor[0].principal_id &&
      alltrue([for assignment in values(azurerm_role_assignment.containers) : assignment.principal_type == "ServicePrincipal"])
    )
    error_message = "Container data roles must be scoped per container to the API and processor identities."
  }

  assert {
    condition = toset(azurerm_role_definition.storage_setup[0].permissions[0].actions) == toset([
      "Microsoft.Storage/storageAccounts/read",
      "Microsoft.Storage/storageAccounts/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/read",
      "Microsoft.Authorization/permissions/read",
      "Microsoft.Authorization/roleAssignments/read",
      "Microsoft.Authorization/roleAssignments/write",
    ]) && length(azurerm_role_definition.storage_setup[0].permissions[0].data_actions) == 0 && tolist(azurerm_role_definition.storage_setup[0].assignable_scopes) == tolist([azurerm_storage_account.exports[0].id])
    error_message = "The export storage setup role must stay limited to this account and carry no data actions."
  }

  assert {
    condition     = endswith(azurerm_role_assignment.api_storage_account_contributor[0].role_definition_id, "17d1049b-9a84-46fb-8f53-869881c3d3ab") && azurerm_role_assignment.api_storage_account_contributor[0].scope == azurerm_storage_account.exports[0].id
    error_message = "The API needs Storage Account Contributor on its own export account only."
  }

  assert {
    condition     = tolist(azurerm_private_endpoint.blob[0].private_service_connection[0].subresource_names) == tolist(["blob"]) && azurerm_private_dns_zone.blob[0].name == "privatelink.blob.core.windows.net"
    error_message = "Blob access must go through the private endpoint."
  }

  assert {
    condition     = azurerm_federated_identity_credential.workload["processor"].subject == "system:serviceaccount:cloudlens:processor"
    error_message = "The processor service account must federate to the processor identity."
  }

  assert {
    condition = (
      output.APP_PROCESSOR_DEPLOYED == "true" && output.APP_SCHEDULER_ENABLED == "true" &&
      output.APP_PROCESSOR_CRON == "*/5 * * * *" &&
      output.COST_EXPORT_STORAGE_URL == "https://sttest.blob.core.windows.net/" &&
      output.COST_EXPORT_STORAGE_RESOURCE_ID == azurerm_storage_account.exports[0].id &&
      output.AZURE_PROCESSOR_IDENTITY_CLIENT_ID == azurerm_user_assigned_identity.processor[0].client_id
    )
    error_message = "The data profile outputs must enable the scheduler and point at the export storage."
  }
}

run "processor_stays_off_until_explicitly_enabled" {
  command = apply

  variables {
    profile = "data"
  }

  assert {
    condition     = output.APP_PROCESSOR_DEPLOYED == "false" && output.APP_SCHEDULER_ENABLED == "false" && length(azurerm_user_assigned_identity.processor) == 1
    error_message = "The processor identity exists with the data profile, but the CronJob stays suspended until enabled."
  }
}

run "trusted_services_exception_opens_only_the_azure_services_bypass" {
  command = apply

  variables {
    profile                              = "data"
    allow_native_export_trusted_services = true
  }

  assert {
    condition = (
      azurerm_storage_account.exports[0].public_network_access == "Enabled" &&
      azurerm_storage_account.exports[0].network_rules[0].default_action == "Deny" &&
      azurerm_storage_account.exports[0].network_rules[0].bypass == toset(["AzureServices"]) &&
      length(azurerm_storage_account.exports[0].network_rules[0].ip_rules) == 0
    )
    error_message = "The approved exception must only add the trusted Azure services bypass."
  }
}

run "ai_profile_adds_a_private_foundry_account_with_model_router_chat" {
  command = apply

  variables {
    profile = "ai"
    model_deployments = [{
      name         = "model-router"
      modelFormat  = "OpenAI"
      modelName    = "model-router"
      modelVersion = "2025-11-18"
      sku          = "GlobalStandard"
      capacity     = 20
    }]
    enable_chat_runtime          = true
    model_router_deployment_name = "model-router"
    principal_id                 = "99999999-9999-9999-9999-999999999999"
  }

  assert {
    condition = (
      azurerm_cognitive_account.ai[0].kind == "AIServices" &&
      azurerm_cognitive_account.ai[0].location == "eastus2" &&
      azurerm_cognitive_account.ai[0].local_auth_enabled == false &&
      azurerm_cognitive_account.ai[0].public_network_access_enabled == false &&
      azurerm_cognitive_account.ai[0].project_management_enabled &&
      azurerm_cognitive_account.ai[0].network_acls[0].default_action == "Deny"
    )
    error_message = "The Foundry account must be private and key-less."
  }

  assert {
    condition     = azurerm_cognitive_account_project.ai[0].name == "cost-agent-project" && azurerm_private_endpoint.ai[0].location == "centralindia" && length(azurerm_private_endpoint.ai[0].private_dns_zone_group[0].private_dns_zone_ids) == 3
    error_message = "The project and its private endpoint (in the cluster region) must exist."
  }

  assert {
    condition = (
      azurerm_cognitive_deployment.models["model-router"].version_upgrade_option == "NoAutoUpgrade" &&
      azurerm_cognitive_deployment.models["model-router"].sku[0].name == "GlobalStandard" &&
      azurerm_cognitive_deployment.models["model-router"].sku[0].capacity == 20 &&
      azurerm_cognitive_deployment.models["model-router"].model[0].version == "2025-11-18"
    )
    error_message = "The approved Model Router deployment must be pinned."
  }

  assert {
    condition     = endswith(azurerm_role_assignment.api_foundry_user[0].role_definition_id, "53ca6127-db72-4b80-b1b0-d745d6d5456d") && endswith(azurerm_role_assignment.api_model_caller[0].role_definition_id, "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd")
    error_message = "The API identity needs Azure AI User on the project and OpenAI User on the account."
  }

  assert {
    condition = (
      output.FOUNDRY_CHAT_ENABLED == "true" && output.MEGHKOSHA_AI_ENABLED == "false" &&
      output.AI_PROJECT_ENDPOINT == "https://${azurerm_cognitive_account.ai[0].name}.services.ai.azure.com/api/projects/cost-agent-project" &&
      output.AI_SERVICES_ENDPOINT == "https://ai-test.cognitiveservices.azure.com/"
    )
    error_message = "Chat runs on the Model Router while the hosted-agent narrator stays off."
  }

  assert {
    condition     = toset(keys(azurerm_role_assignment.cluster_admin)) == toset(["22222222-2222-2222-2222-222222222222", "99999999-9999-9999-9999-999999999999"])
    error_message = "Both azd's principal and the Terraform caller need cluster-admin to apply the manifests."
  }
}

run "custom_domain_and_zoneless_regions" {
  command = apply

  variables {
    custom_domain      = "CloudLens.Contoso.com"
    aks_zones          = "none"
    aks_sku_tier       = "Free"
    tls_cluster_issuer = "letsencrypt-staging"
  }

  assert {
    condition     = output.APP_INGRESS_HOST == "cloudlens.contoso.com" && output.APP_WEB_ORIGIN == "https://cloudlens.contoso.com" && output.APP_TLS_CLUSTER_ISSUER == "letsencrypt-staging"
    error_message = "A custom domain must replace the Azure-provided host name."
  }

  assert {
    condition     = length(azurerm_public_ip.ingress.zones) == 0 && length(azurerm_kubernetes_cluster.main.default_node_pool[0].zones) == 0 && length(azurerm_kubernetes_cluster_node_pool.apps.zones) == 0
    error_message = "aks_zones = none must drop zones everywhere."
  }
}

run "invalid_settings_are_rejected_before_any_change" {
  command = plan

  variables {
    profile            = "unknown"
    aks_zones          = "1,4"
    aks_system_vm_size = "Standard_D2s_v5"
    ingress_dns_label  = "1-starts-with-a-digit"
  }

  expect_failures = [
    var.profile,
    var.aks_zones,
    var.aks_system_vm_size,
    var.ingress_dns_label,
  ]
}

run "lowering_the_provisioned_profile_is_refused" {
  command = plan

  variables {
    profile             = "data"
    provisioned_profile = "ai"
  }

  expect_failures = [var.provisioned_profile]
}

run "keeping_or_raising_the_provisioned_profile_is_allowed" {
  command = plan

  variables {
    profile             = "ai"
    provisioned_profile = "data"
  }

  assert {
    condition     = output.APP_PROFILE == "ai"
    error_message = "Raising the profile must be allowed."
  }
}
