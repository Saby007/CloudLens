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

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/networkSecurityGroups/nsg-test"
    }
  }

  mock_resource "azurerm_monitor_data_collection_rule" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Insights/dataCollectionRules/dcr-test"
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

  mock_resource "azurerm_nat_gateway" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/natGateways/nat-test"
    }
  }

  mock_resource "azurerm_network_interface" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/networkInterfaces/nic-test"
    }
  }

  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Compute/virtualMachines/vm-test"
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

mock_provider "random" {}

# The deploy host's subnets are checked by name (Azure requires AzureBastionSubnet).
override_resource {
  target = azurerm_subnet.bastion
  values = {
    id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/AzureBastionSubnet"
  }
}

override_resource {
  target = random_password.deploy_host
  values = {
    result = "Aa1!Bb2#Cc3%Dd4*Ee5-Ff6_"
  }
}

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

  # The runs below that predate the private ingress describe the internet-facing one; the private_* runs override this.
  # The default itself (private) is checked through azd's parameter file in api/tests/test_packaging.py.
  ingress_visibility = "public"

  # Likewise the cluster and registry runs below describe the internet-reachable control plane with a load balancer
  # for outbound traffic; the private_control_plane_* runs override these.
  aks_private_cluster = false
  private_registry    = false
  aks_outbound_type   = "loadBalancer"
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
      azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile[0].managed_outbound_ip_count == 1 &&
      azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile[0].outbound_ports_allocated == 6400 &&
      azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile[0].idle_timeout_in_minutes == 4
    )
    error_message = "Each node needs 6,400 outbound SNAT ports released after 4 idle minutes; AKS's defaults ran out."
  }

  assert {
    condition = (
      startswith(azurerm_network_security_group.aks_nodes.name, "nsg-aks-nodes-") &&
      length(azurerm_network_security_group.aks_nodes.security_rule) == 2 &&
      alltrue([for rule in azurerm_network_security_group.aks_nodes.security_rule : (
        rule.direction == "Inbound" && rule.access == "Allow" && rule.protocol == "Tcp" &&
        rule.source_address_prefix == "Internet" && rule.destination_address_prefix == azurerm_public_ip.ingress[0].ip_address
      )]) &&
      toset([for rule in azurerm_network_security_group.aks_nodes.security_rule : "${rule.name}:${rule.destination_port_range}"]) == toset(["AllowHttpToIngress:80", "AllowHttpsToIngress:443"]) &&
      output.APP_WEB_INGRESS_RESTRICTED == "false" && output.APP_INGRESS_NSG_NAME == azurerm_network_security_group.aks_nodes.name
    )
    error_message = "The node subnet's NSG must let the internet reach only the ingress IP, on HTTP and HTTPS."
  }

  assert {
    condition = (
      length(azurerm_subnet.ingress) == 0 && length(azurerm_subnet.private_link) == 0 && length(azurerm_private_dns_zone.ingress) == 0 &&
      output.APP_INGRESS_VISIBILITY == "public" && output.APP_INGRESS_PRIVATE_IP == "" && output.APP_PRIVATE_LINK_NAME == "" &&
      output.APP_PRIVATE_LINK_ID == "" && output.APP_INGRESS_SUBNET_NAME == ""
    )
    error_message = "A public ingress must create none of the private ingress's subnets, DNS zone or Private Link Service."
  }

  assert {
    condition = (
      startswith(azurerm_network_security_group.private_endpoints.name, "nsg-private-endpoints-") &&
      length(azurerm_network_security_group.private_endpoints.security_rule) == 0 &&
      azurerm_subnet.aks.network_security_group_id_wo_version == 1 &&
      azurerm_subnet.private_endpoints.network_security_group_id_wo_version == 1
    )
    error_message = "Both subnets must get their NSGs from Terraform, and the private endpoint subnet must allow nothing extra."
  }

  assert {
    condition = (
      azurerm_monitor_data_collection_rule_association.container_insights.target_resource_id == azurerm_kubernetes_cluster.main.id &&
      azurerm_monitor_data_collection_rule_association.container_insights.data_collection_rule_id == azurerm_monitor_data_collection_rule.container_insights.id &&
      azurerm_monitor_data_collection_rule.container_insights.destinations[0].log_analytics[0].workspace_resource_id == azurerm_log_analytics_workspace.main.id &&
      toset(azurerm_monitor_data_collection_rule.container_insights.data_flow[0].streams) == toset(["Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory"]) &&
      azurerm_monitor_data_collection_rule.container_insights.data_sources[0].extension[0].extension_name == "ContainerInsights" &&
      jsondecode(azurerm_monitor_data_collection_rule.container_insights.data_sources[0].extension[0].extension_json).dataCollectionSettings.enableContainerLogV2 == true &&
      jsondecode(azurerm_monitor_data_collection_rule.container_insights.data_sources[0].extension[0].extension_json).dataCollectionSettings.namespaceFilteringMode == "Exclude"
    )
    error_message = "Container Insights must send the cluster's container logs, events and pod inventory to the workspace; the agent collects nothing without this rule."
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
    condition     = azurerm_public_ip.ingress[0].sku == "Standard" && azurerm_public_ip.ingress[0].allocation_method == "Static" && startswith(azurerm_public_ip.ingress[0].domain_name_label, "cloudlens-")
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
    condition     = length(azurerm_public_ip.ingress[0].zones) == 0 && length(azurerm_kubernetes_cluster.main.default_node_pool[0].zones) == 0 && length(azurerm_kubernetes_cluster_node_pool.apps.zones) == 0
    error_message = "aks_zones = none must drop zones everywhere."
  }
}

run "private_ingress_has_no_public_address_and_opens_only_inside_the_network" {
  command = apply

  variables {
    ingress_visibility = "private"
  }

  assert {
    condition     = length(azurerm_public_ip.ingress) == 0
    error_message = "A private ingress has no public IP."
  }

  assert {
    condition = (
      length(azurerm_network_security_group.aks_nodes.security_rule) == 1 &&
      one(azurerm_network_security_group.aks_nodes.security_rule).name == "DenyInternetInbound" &&
      one(azurerm_network_security_group.aks_nodes.security_rule).access == "Deny" &&
      one(azurerm_network_security_group.aks_nodes.security_rule).source_address_prefix == "Internet"
    )
    error_message = "A private ingress needs no allow rule, only the explicit deny that also replaces a public environment's old rules."
  }

  assert {
    condition     = output.APP_INGRESS_PUBLIC_IP == "" && output.APP_INGRESS_PUBLIC_IP_NAME == "" && output.APP_INGRESS_AZURE_FQDN == ""
    error_message = "A private ingress reports no public address or name."
  }

  assert {
    condition = (
      azurerm_subnet.ingress[0].name == "ingress" && tolist(azurerm_subnet.ingress[0].address_prefixes) == tolist(["10.42.1.32/27"]) &&
      azurerm_subnet.private_link[0].name == "private-link" && tolist(azurerm_subnet.private_link[0].address_prefixes) == tolist(["10.42.1.64/27"]) &&
      azurerm_subnet.private_link[0].private_link_service_network_policies_enabled == false &&
      azurerm_subnet.ingress[0].network_security_group_id_wo_version == 1 && azurerm_subnet.private_link[0].network_security_group_id_wo_version == 1 &&
      length(azurerm_network_security_group.ingress[0].security_rule) == 0 && length(azurerm_network_security_group.private_link[0].security_rule) == 0
    )
    error_message = "The ingress and Private Link NAT subnets must exist with their own rule-free NSGs, the NAT subnet with Private Link service network policies off."
  }

  assert {
    condition = (
      output.APP_INGRESS_VISIBILITY == "private" && output.APP_INGRESS_PRIVATE_IP == "10.42.1.36" && output.APP_INGRESS_SUBNET_NAME == "ingress" &&
      startswith(output.APP_INGRESS_HOST, "cloudlens-") && endswith(output.APP_INGRESS_HOST, ".internal") &&
      output.APP_WEB_ORIGIN == "https://${output.APP_INGRESS_HOST}" &&
      output.APP_TLS_CLUSTER_ISSUER == "private-ca" && output.APP_WEB_INGRESS_RESTRICTED == "true"
    )
    error_message = "A private ingress must report its private address, a .internal host, the private CA and a restricted ingress."
  }

  assert {
    condition = (
      startswith(output.APP_PRIVATE_LINK_NAME, "pls-cloudlens-") && output.APP_PRIVATE_LINK_SUBNET_NAME == "private-link" &&
      output.APP_PRIVATE_LINK_SUBSCRIPTIONS == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" &&
      output.APP_PRIVATE_LINK_ID == "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-contract-test-aks-nodes/providers/Microsoft.Network/privateLinkServices/${output.APP_PRIVATE_LINK_NAME}"
    )
    error_message = "The Private Link Service lives in the node resource group, named by annotation, visible to the deployment subscription."
  }

  assert {
    condition = (
      azurerm_private_dns_zone.ingress[0].name == output.APP_INGRESS_HOST &&
      azurerm_private_dns_a_record.ingress[0].name == "@" && tolist(azurerm_private_dns_a_record.ingress[0].records) == tolist(["10.42.1.36"]) &&
      azurerm_private_dns_zone_virtual_network_link.ingress[0].registration_enabled == false
    )
    error_message = "The host name must resolve to the internal load balancer address through a private DNS zone named after the host."
  }
}

run "private_ingress_serves_a_custom_domain_and_other_subscriptions" {
  command = apply

  variables {
    ingress_visibility                 = "private"
    custom_domain                      = "CloudLens.Contoso.com"
    tls_cluster_issuer                 = "byo"
    private_link_allowed_subscriptions = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb, AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    ingress_subnet_prefix              = "10.42.1.96/28"
    private_link_subnet_prefix         = "10.42.1.112/28"
  }

  assert {
    condition = (
      output.APP_INGRESS_HOST == "cloudlens.contoso.com" && output.APP_WEB_ORIGIN == "https://cloudlens.contoso.com" &&
      azurerm_private_dns_zone.ingress[0].name == "cloudlens.contoso.com" && output.APP_TLS_CLUSTER_ISSUER == "byo" &&
      output.APP_INGRESS_PRIVATE_IP == "10.42.1.100"
    )
    error_message = "A custom domain must name the host and its private DNS zone, and the address must follow a moved ingress subnet."
  }

  assert {
    condition     = output.APP_PRIVATE_LINK_SUBSCRIPTIONS == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    error_message = "The deployment subscription and each allowed subscription must appear once, lowercase, deployment first."
  }
}

run "private_link_can_be_switched_off_leaving_only_the_private_address" {
  command = apply

  variables {
    ingress_visibility   = "private"
    private_link_enabled = false
  }

  assert {
    condition = (
      length(azurerm_subnet.private_link) == 0 && length(azurerm_network_security_group.private_link) == 0 &&
      output.APP_PRIVATE_LINK_NAME == "" && output.APP_PRIVATE_LINK_ID == "" && output.APP_PRIVATE_LINK_SUBNET_NAME == "" &&
      output.APP_PRIVATE_LINK_SUBSCRIPTIONS == "" && length(azurerm_subnet.ingress) == 1 && output.APP_INGRESS_PRIVATE_IP == "10.42.1.36"
    )
    error_message = "Without the Private Link Service only the internal address remains."
  }
}

run "a_private_ingress_refuses_settings_that_only_work_in_public" {
  command = plan

  variables {
    ingress_visibility    = "private"
    tls_cluster_issuer    = "letsencrypt"
    web_allowed_ip_ranges = "203.0.113.7"
  }

  expect_failures = [var.tls_cluster_issuer, var.web_allowed_ip_ranges]
}

run "private_ingress_settings_must_be_exact" {
  command = plan

  variables {
    ingress_visibility                 = "Private"
    ingress_subnet_prefix              = "10.42.1.32/29"
    private_link_subnet_prefix         = "not-a-block"
    private_link_allowed_subscriptions = "not-a-subscription"
  }

  expect_failures = [
    var.ingress_visibility,
    var.ingress_subnet_prefix,
    var.private_link_subnet_prefix,
    var.private_link_allowed_subscriptions,
  ]
}

run "the_public_ingress_keeps_letsencrypt_and_a_private_one_cannot_use_it" {
  command = plan

  variables {
    ingress_visibility = "public"
    tls_cluster_issuer = "private-ca"
  }

  assert {
    condition     = output.APP_TLS_CLUSTER_ISSUER == "private-ca"
    error_message = "A public ingress may still choose the private CA or bring its own certificate."
  }
}

run "invalid_settings_are_rejected_before_any_change" {
  command = plan

  variables {
    profile                           = "unknown"
    aks_zones                         = "1,4"
    aks_system_vm_size                = "Standard_D2s_v5"
    ingress_dns_label                 = "1-starts-with-a-digit"
    aks_outbound_ports_per_node       = 2004
    aks_outbound_idle_timeout_minutes = 3
  }

  expect_failures = [
    var.profile,
    var.aks_zones,
    var.aks_system_vm_size,
    var.ingress_dns_label,
    var.aks_outbound_ports_per_node,
    var.aks_outbound_idle_timeout_minutes,
  ]
}

run "operator_mode_without_an_allow_list_closes_https_to_the_internet" {
  command = apply

  variables {
    auth_mode = "operator"
  }

  assert {
    condition = (
      length(azurerm_network_security_group.aks_nodes.security_rule) == 1 &&
      one(azurerm_network_security_group.aks_nodes.security_rule).name == "AllowHttpToIngress" &&
      one(azurerm_network_security_group.aks_nodes.security_rule).destination_port_range == "80" &&
      output.APP_WEB_INGRESS_RESTRICTED == "false"
    )
    error_message = "Operator mode has no sign-in, so without an allow-list HTTPS must stay closed; HTTP remains for Let's Encrypt."
  }
}

run "an_allow_list_limits_https_to_exactly_the_listed_ranges" {
  command = apply

  variables {
    auth_mode             = "operator"
    web_allowed_ip_ranges = "203.0.113.7, 198.51.100.0/24"
  }

  assert {
    condition = (
      length(azurerm_network_security_group.aks_nodes.security_rule) == 2 &&
      toset(one([for rule in azurerm_network_security_group.aks_nodes.security_rule : rule if rule.name == "AllowHttpsToIngress"]).source_address_prefixes) == toset(["203.0.113.7", "198.51.100.0/24"]) &&
      one([for rule in azurerm_network_security_group.aks_nodes.security_rule : rule if rule.name == "AllowHttpsToIngress"]).destination_port_range == "443" &&
      one([for rule in azurerm_network_security_group.aks_nodes.security_rule : rule if rule.name == "AllowHttpToIngress"]).source_address_prefix == "Internet" &&
      output.APP_WEB_INGRESS_RESTRICTED == "true"
    )
    error_message = "An allow-list must limit HTTPS to exactly the listed ranges and report the ingress as restricted."
  }
}

run "allow_lists_and_auth_modes_must_be_exact" {
  command = plan

  variables {
    auth_mode             = "Operator"
    web_allowed_ip_ranges = "203.0.113.7, 0.0.0.0/0"
  }

  expect_failures = [var.auth_mode, var.web_allowed_ip_ranges]
}

run "allow_list_ranges_must_start_at_their_network_address" {
  command = plan

  variables {
    web_allowed_ip_ranges = "198.51.100.7/24"
  }

  expect_failures = [var.web_allowed_ip_ranges]
}

run "outbound_ports_must_cover_every_node_including_upgrade_surge" {
  command = plan

  # 3 + 1 system and 6 + 1 application nodes at 6,400 ports each need 70,400 ports; one IP has 64,000.
  variables {
    aks_user_max_nodes = 6
  }

  expect_failures = [azurerm_kubernetes_cluster.main]
}

run "another_outbound_ip_makes_room_for_larger_pools" {
  command = plan

  variables {
    aks_user_max_nodes    = 6
    aks_outbound_ip_count = 2
  }

  assert {
    condition     = azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile[0].managed_outbound_ip_count == 2
    error_message = "A second outbound IP must double the SNAT ports available to the nodes."
  }
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

run "private_control_plane_has_no_public_api_server_registry_or_inbound_path" {
  command = apply

  variables {
    ingress_visibility  = "private"
    aks_private_cluster = true
    private_registry    = true
    aks_outbound_type   = "natGateway"
  }

  assert {
    condition = alltrue([
      azurerm_kubernetes_cluster.main.private_cluster_enabled,
      !azurerm_kubernetes_cluster.main.private_cluster_public_fqdn_enabled,
      azurerm_kubernetes_cluster.main.private_dns_zone_id == "System",
      length(azurerm_kubernetes_cluster.main.api_server_access_profile) == 0,
    ])
    error_message = "The API server must be private, with no public FQDN and no authorized-range list to maintain."
  }

  assert {
    condition = alltrue([
      azurerm_kubernetes_cluster.main.network_profile[0].outbound_type == "userAssignedNATGateway",
      length(azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile) == 0,
      length(azurerm_subnet_nat_gateway_association.aks) == 1,
      length(azurerm_public_ip.ingress) == 0,
    ])
    error_message = "Outbound traffic must leave through the NAT gateway on the node subnet, with no ingress IP and no load-balancer SNAT profile."
  }

  assert {
    condition = alltrue([
      azurerm_container_registry.main.sku == "Premium",
      !azurerm_container_registry.main.public_network_access_enabled,
      azurerm_container_registry.main.data_endpoint_enabled,
      !azurerm_container_registry.main.admin_enabled,
    ])
    error_message = "The registry must be Premium with no public access and dedicated data endpoints, so layers also arrive over the private endpoint."
  }

  assert {
    condition = alltrue([
      length(azurerm_private_endpoint.acr) == 1,
      azurerm_private_dns_zone.acr[0].name == "privatelink.azurecr.io",
      length(azurerm_private_dns_zone_virtual_network_link.acr) == 1,
    ])
    error_message = "The registry needs a private endpoint, the privatelink.azurecr.io zone and a link from the virtual network."
  }

  assert {
    condition     = length(azurerm_role_assignment.deployer_acr_push) >= 1 && alltrue([for assignment in azurerm_role_assignment.deployer_acr_push : endswith(assignment.role_definition_id, "8311e382-0749-4cb8-b61a-304f252e45ec")])
    error_message = "The deployer pushes the images from the deploy host, so they need AcrPush on the registry."
  }

  assert {
    condition = alltrue([
      length(azurerm_nat_gateway.main) == 1,
      length(azurerm_nat_gateway_public_ip_association.main) == 1,
      length(azurerm_subnet_nat_gateway_association.deploy_host) == 1,
    ])
    error_message = "One NAT gateway serves the nodes and the deploy host."
  }

  assert {
    condition = alltrue([
      length(azurerm_linux_virtual_machine.deploy_host) == 1,
      length(azurerm_bastion_host.deploy_host) == 1,
      azurerm_subnet.bastion[0].name == "AzureBastionSubnet",
      azurerm_subnet.bastion[0].address_prefixes[0] == "10.42.1.128/26",
      azurerm_subnet.deploy_host[0].address_prefixes[0] == "10.42.1.96/27",
      azurerm_linux_virtual_machine.deploy_host[0].size == "Standard_D4s_v5",
      azurerm_linux_virtual_machine.deploy_host[0].admin_username == "cloudlensadmin",
      azurerm_linux_virtual_machine.deploy_host[0].source_image_reference[0].publisher == "Canonical",
      length(azurerm_dev_test_global_vm_shutdown_schedule.deploy_host) == 1,
    ])
    error_message = "A private control plane needs the deploy host and its Bastion in subnets of the virtual network."
  }

  assert {
    condition = alltrue([
      azurerm_network_interface.deploy_host[0].ip_configuration[0].public_ip_address_id == null,
      length(azurerm_public_ip.bastion) == 1,
      length(azurerm_public_ip.nat) == 1,
      one([for rule in azurerm_network_security_group.deploy_host[0].security_rule : rule.source_address_prefix]) == "10.42.1.128/26",
      one([for rule in azurerm_network_security_group.deploy_host[0].security_rule : rule.destination_port_range]) == "22",
    ])
    error_message = "The deploy host has no public address and takes SSH from Bastion's subnet only; the only public addresses are Bastion's and the NAT gateway's."
  }

  assert {
    condition = alltrue([
      output.APP_AKS_PRIVATE_CLUSTER == "true",
      output.APP_PRIVATE_REGISTRY == "true",
      output.APP_AKS_OUTBOUND_TYPE == "natGateway",
      output.APP_DEPLOY_HOST_ADMIN_USERNAME == "cloudlensadmin",
      output.APP_DEPLOY_HOST_NAME != "",
      output.APP_DEPLOY_HOST_ID != "",
      output.APP_NAT_GATEWAY_IP != "",
      output.APP_DEPLOYMENT_STATE.aksPrivateCluster,
      output.APP_DEPLOYMENT_STATE.privateRegistry,
      output.APP_DEPLOYMENT_STATE.deployHostEnabled,
    ])
    error_message = "The hook and the deploy scripts read these outputs to know the control plane is private and where the deploy host is."
  }
}

run "the_public_control_plane_keeps_its_basic_registry_and_load_balancer_outbound" {
  command = apply

  assert {
    condition = alltrue([
      !azurerm_kubernetes_cluster.main.private_cluster_enabled,
      azurerm_kubernetes_cluster.main.network_profile[0].outbound_type == "loadBalancer",
      length(azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile) == 1,
      azurerm_container_registry.main.sku == "Basic",
      azurerm_container_registry.main.public_network_access_enabled,
      !azurerm_container_registry.main.data_endpoint_enabled,
    ])
    error_message = "A public control plane keeps the public API server, the Basic registry and the load balancer's outbound IPs."
  }

  assert {
    condition = alltrue([
      length(azurerm_private_endpoint.acr) == 0,
      length(azurerm_nat_gateway.main) == 0,
      length(azurerm_linux_virtual_machine.deploy_host) == 0,
      length(azurerm_bastion_host.deploy_host) == 0,
      output.APP_AKS_PRIVATE_CLUSTER == "false",
      output.APP_DEPLOY_HOST_ID == "",
      output.APP_NAT_GATEWAY_IP == "",
    ])
    error_message = "Nothing private-only may be created for a public control plane."
  }
}

run "the_deploy_host_is_optional_for_teams_that_deploy_from_a_connected_network" {
  command = apply

  variables {
    aks_private_cluster = true
    private_registry    = true
    aks_outbound_type   = "natGateway"
    deploy_host_enabled = false
  }

  assert {
    condition = alltrue([
      length(azurerm_linux_virtual_machine.deploy_host) == 0,
      length(azurerm_bastion_host.deploy_host) == 0,
      length(azurerm_public_ip.bastion) == 0,
      length(azurerm_nat_gateway.main) == 1,
      length(azurerm_subnet_nat_gateway_association.deploy_host) == 0,
      azurerm_kubernetes_cluster.main.private_cluster_enabled,
    ])
    error_message = "Without the deploy host there is no VM or Bastion, but the cluster stays private and keeps the NAT gateway."
  }
}

run "a_load_balancer_for_outbound_still_gives_the_deploy_host_a_nat_gateway" {
  command = apply

  variables {
    aks_private_cluster = true
    aks_outbound_type   = "loadBalancer"
  }

  assert {
    condition = alltrue([
      azurerm_kubernetes_cluster.main.network_profile[0].outbound_type == "loadBalancer",
      length(azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile) == 1,
      length(azurerm_subnet_nat_gateway_association.aks) == 0,
      length(azurerm_subnet_nat_gateway_association.deploy_host) == 1,
    ])
    error_message = "The deploy host's subnet has no default outbound access, so it needs the NAT gateway even when the nodes use the load balancer."
  }
}

run "only_the_registry_private_still_needs_the_deploy_host_to_push_images" {
  command = plan

  variables {
    aks_private_cluster = false
    private_registry    = true
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.deploy_host) == 1 && !azurerm_kubernetes_cluster.main.private_cluster_enabled
    error_message = "A private registry cannot be built into from the cloud, so the deploy host is created even when the API server is public."
  }
}

run "a_private_cluster_has_no_public_api_server_to_authorize" {
  command = plan

  variables {
    aks_private_cluster          = true
    aks_api_authorized_ip_ranges = "203.0.113.7/32"
  }

  expect_failures = [var.aks_private_cluster]
}

run "private_control_plane_settings_must_be_exact" {
  command = plan

  variables {
    aks_outbound_type         = "natgateway"
    deploy_host_subnet_prefix = "10.42.1.96/29"
    bastion_subnet_prefix     = "10.42.1.128/27"
    deploy_host_shutdown_time = "6pm"
  }

  expect_failures = [
    var.aks_outbound_type,
    var.deploy_host_subnet_prefix,
    var.bastion_subnet_prefix,
    var.deploy_host_shutdown_time,
  ]
}
