resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "cloudlens-${local.resource_token}"
  node_resource_group = substr("${local.resource_group_name}-aks-nodes", 0, 80)
  sku_tier            = var.aks_sku_tier
  kubernetes_version  = var.aks_kubernetes_version != "" ? var.aks_kubernetes_version : null
  tags                = local.tags

  automatic_upgrade_channel    = "stable"
  node_os_upgrade_channel      = "NodeImage"
  oidc_issuer_enabled          = true
  workload_identity_enabled    = true
  local_account_disabled       = true
  azure_policy_enabled         = true
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 168

  default_node_pool {
    name                         = "system"
    vm_size                      = var.aks_system_vm_size
    auto_scaling_enabled         = true
    min_count                    = var.aks_system_min_nodes
    max_count                    = var.aks_system_max_nodes
    only_critical_addons_enabled = true
    os_sku                       = "AzureLinux"
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = 64
    vnet_subnet_id               = azurerm_subnet.aks.id
    zones                        = local.aks_zones
    temporary_name_for_rotation  = "systemtmp"

    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  # The cluster autoscaler sizes the node pools below; node auto-provisioning stays off.
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.aks_pod_cidr
    service_cidr        = var.aks_service_cidr
    dns_service_ip      = cidrhost(var.aks_service_cidr, 10)
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"

    # Every outbound connection holds a SNAT port. AKS's default of 1,024 ports per node, each held for
    # 30 minutes after its connection goes idle, ran out on the node hosting the app's pods.
    load_balancer_profile {
      managed_outbound_ip_count = var.aks_outbound_ip_count
      outbound_ports_allocated  = var.aks_outbound_ports_per_node
      idle_timeout_in_minutes   = var.aks_outbound_idle_timeout_minutes
    }
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed NGINX. The default controller is off: scripts/aks-bootstrap.ps1 creates one bound to the static ingress IP.
  web_app_routing {
    dns_zone_ids             = []
    default_nginx_controller = "None"
  }

  dynamic "api_server_access_profile" {
    for_each = length(local.aks_api_authorized_ip_ranges) > 0 ? [1] : []

    content {
      authorized_ip_ranges = local.aks_api_authorized_ip_ranges
    }
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.aks_maintenance_day
    start_time  = var.aks_maintenance_start_time
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = var.aks_maintenance_day
    start_time  = var.aks_maintenance_start_time
    utc_offset  = "+00:00"
  }

  lifecycle {
    # Defender for Containers enables its own profile on the cluster (through Azure Policy in many tenants);
    # Terraform doesn't configure it, so it must not switch it off.
    ignore_changes = [default_node_pool[0].node_count, microsoft_defender]

    # Each pool upgrades with a 10% surge, so its largest size plus that surge must also get its ports.
    precondition {
      condition     = (var.aks_system_max_nodes + ceil(var.aks_system_max_nodes * 0.1) + var.aks_user_max_nodes + ceil(var.aks_user_max_nodes * 0.1)) * var.aks_outbound_ports_per_node <= 64000 * var.aks_outbound_ip_count
      error_message = "The node pools at their maximum size, plus one upgrade surge node per pool, need more SNAT ports than the outbound IPs provide (64,000 each). Lower APP_AKS_OUTBOUND_PORTS, raise APP_AKS_OUTBOUND_IPS, or lower the pools' maximum node counts."
    }
  }

  depends_on = [time_sleep.aks_identity_propagation]
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                        = "apps"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.main.id
  mode                        = "User"
  vm_size                     = var.aks_user_vm_size
  auto_scaling_enabled        = true
  min_count                   = var.aks_user_min_nodes
  max_count                   = var.aks_user_max_nodes
  os_sku                      = "AzureLinux"
  os_disk_type                = "Ephemeral"
  os_disk_size_gb             = 64
  vnet_subnet_id              = azurerm_subnet.aks.id
  zones                       = local.aks_zones
  temporary_name_for_rotation = "appstmp"
  node_labels                 = { "cloudlens.io/pool" = "apps" }
  tags                        = local.tags

  upgrade_settings {
    max_surge                     = "10%"
    drain_timeout_in_minutes      = 30
    node_soak_duration_in_minutes = 0
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Local accounts are disabled, so the operator applies manifests through Entra ID and Azure RBAC.
locals {
  cluster_admin_principals = toset(compact([var.principal_id, data.azurerm_client_config.current.object_id]))
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each           = local.cluster_admin_principals
  scope              = azurerm_kubernetes_cluster.main.id
  role_definition_id = "${local.role_definition_prefix}${local.role_ids.aks_rbac_cluster_admin}"
  principal_id       = each.value
}

# Azure RBAC for Kubernetes takes a few minutes to reach the API server. Holding the provision open here
# keeps the postprovision hook and azd's first kubectl call from racing it.
resource "time_sleep" "cluster_admin_propagation" {
  create_duration = "120s"

  triggers = {
    role_assignments = join(",", sort([for assignment in azurerm_role_assignment.cluster_admin : assignment.id]))
  }
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "to-workspace"
  target_resource_id             = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "kube-audit-admin"
  }

  enabled_log {
    category = "guard"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Container Insights. With managed identity authentication the monitoring agent sends nothing until a data
# collection rule is associated with the cluster, and AKS only creates one when monitoring is enabled from the
# CLI or the portal. These are the streams of Microsoft's default "Logs and Events" preset; the system
# namespaces are left out, as in its cost-optimized preset.
locals {
  container_insights_streams = ["Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory"]
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = "MSCI-${azurerm_log_analytics_workspace.main.location}-${azurerm_kubernetes_cluster.main.name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_log_analytics_workspace.main.location
  description         = "Container Insights logs and events for the CloudLens cluster."
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = azurerm_log_analytics_workspace.main.id
    }
  }

  data_flow {
    streams      = local.container_insights_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = local.container_insights_streams
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Exclude"
          namespaces             = ["kube-system", "gatekeeper-system", "azure-arc"]
          enableContainerLogV2   = true
        }
      })
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.main.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Container Insights collection for this cluster. Deleting it stops the cluster's log collection."
}
