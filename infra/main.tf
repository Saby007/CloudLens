terraform {
  # 1.11 introduced write-only arguments, which the subnets use for their NSGs (network.tf).
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "azurerm" {
  features {
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    resource_group {
      # Azure Policy can add resources to this group outside Terraform (for example a default NSG for a new subnet); azd down must still remove it.
      prevent_deletion_if_contains_resources = false
    }
    storage {
      # The export account is private and key-less, so every storage change goes through Azure Resource Manager.
      data_plane_available = false
    }
  }

  storage_use_azuread = true

  # azurerm 5.x registers nothing by default. Microsoft.CostManagementExports lets Cost Management write the
  # native FOCUS exports into this deployment's storage account.
  resource_providers_to_register = [
    "Microsoft.CognitiveServices",
    "Microsoft.Compute",
    "Microsoft.ContainerRegistry",
    "Microsoft.ContainerService",
    "Microsoft.CostManagementExports",
    "Microsoft.Insights",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.OperationalInsights",
    "Microsoft.OperationsManagement",
    "Microsoft.PolicyInsights",
    "Microsoft.Storage",
  ]
}

data "azurerm_client_config" "current" {}

locals {
  tags = {
    "azd-env-name" = var.environment_name
    "app-name"     = "cost-assessment"
  }

  data_enabled       = contains(["data", "ai"], var.profile)
  ai_enabled         = var.profile == "ai"
  processor_deployed = local.data_enabled && var.enable_processor
  ai_runtime_enabled = local.ai_enabled && var.enable_ai_runtime
  chat_enabled       = local.ai_enabled && var.enable_chat_runtime && var.model_router_deployment_name != ""

  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "rg-${var.environment_name}"
  resource_token      = substr(sha1(join("|", [data.azurerm_client_config.current.subscription_id, var.environment_name, local.resource_group_name])), 0, 13)

  # Must match k8s.namespace in azure.yaml: workload identity trusts service accounts in this namespace only.
  namespace         = "cloudlens"
  export_name       = "focus-closed-month-${local.resource_token}"
  daily_export_name = "focus-daily-${local.resource_token}"
  containers = {
    exports = "cost-exports"
    reports = "report-snapshots"
    control = "control-state"
  }

  aks_zones                    = lower(trimspace(var.aks_zones)) == "none" ? [] : compact([for zone in split(",", var.aks_zones) : trimspace(zone)])
  aks_api_authorized_ip_ranges = compact([for range in split(",", var.aks_api_authorized_ip_ranges) : trimspace(range)])
  web_allowed_ip_ranges        = compact([for range in split(",", var.web_allowed_ip_ranges) : trimspace(range)])
  ingress_dns_label            = var.ingress_dns_label != "" ? var.ingress_dns_label : "cloudlens-${local.resource_token}"
  ingress_class                = "cloudlens-nginx"

  # Private (the default): an internal load balancer on a private IP, no public address at all. Public keeps the
  # internet-facing static IP. Only a private ingress can be reached solely through a private endpoint.
  private_ingress = var.ingress_visibility == "private"
  public_ingress  = !local.private_ingress
  tls_issuer      = var.tls_cluster_issuer != "" ? var.tls_cluster_issuer : (local.private_ingress ? "private-ca" : "letsencrypt")

  # Without a custom domain a private ingress is named <label>.internal; .internal is reserved for private use.
  # Azure reserves the first four addresses of a subnet, so the fifth is the first the load balancer can take.
  ingress_host       = var.custom_domain != "" ? lower(var.custom_domain) : (local.private_ingress ? "${local.ingress_dns_label}.internal" : one(azurerm_public_ip.ingress[*].fqdn))
  ingress_private_ip = local.private_ingress ? cidrhost(var.ingress_subnet_prefix, 4) : ""

  private_link_service_enabled = local.private_ingress && var.private_link_enabled
  private_link_name            = "pls-cloudlens-${local.resource_token}"
  private_link_subscriptions = distinct(concat(
    [lower(data.azurerm_client_config.current.subscription_id)],
    [for id in compact([for item in split(",", var.private_link_allowed_subscriptions) : trimspace(item)]) : lower(id)],
  ))

  role_definition_prefix = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/"
  role_ids = {
    acr_pull                    = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
    aks_rbac_cluster_admin      = "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"
    azure_ai_user               = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
    blob_data_contributor       = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
    blob_data_reader            = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
    cognitive_openai_user       = "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
    managed_identity_operator   = "f1a07417-d97a-45cb-824c-7a7467783830"
    network_contributor         = "4d97b98b-1d4f-4787-a291-c67834d212e7"
    storage_account_contributor = "17d1049b-9a84-46fb-8f53-869881c3d3ab"
  }
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}
