# Every output lands in the azd environment. The Kubernetes manifests (api/manifests, web/manifests),
# scripts/aks-bootstrap.ps1 and the deployment helpers read these names, so rename them together.

output "AZURE_LOCATION" {
  value = var.location
}

output "AZURE_TENANT_ID" {
  value = data.azurerm_client_config.current.tenant_id
}

output "AZURE_RESOURCE_GROUP" {
  value = azurerm_resource_group.main.name
}

output "FOUNDRY_LOCATION" {
  value = var.foundry_location
}

output "APP_PROFILE" {
  value = var.profile
}

output "APP_PROVISIONED_PROFILE" {
  value = var.profile
}

output "AZURE_CONTAINER_REGISTRY_NAME" {
  value = azurerm_container_registry.main.name
}

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  value = azurerm_container_registry.main.login_server
}

output "AZURE_AKS_CLUSTER_NAME" {
  value = azurerm_kubernetes_cluster.main.name
}

output "AZURE_AKS_NAMESPACE" {
  value = local.namespace
}

output "AZURE_AKS_OIDC_ISSUER_URL" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "AZURE_API_IDENTITY_CLIENT_ID" {
  value = azurerm_user_assigned_identity.api.client_id
}

output "AZURE_API_IDENTITY_PRINCIPAL_ID" {
  value = azurerm_user_assigned_identity.api.principal_id
}

output "AZURE_PROCESSOR_IDENTITY_CLIENT_ID" {
  value = local.data_enabled ? azurerm_user_assigned_identity.processor[0].client_id : ""
}

output "AZURE_PROCESSOR_IDENTITY_PRINCIPAL_ID" {
  value = local.data_enabled ? azurerm_user_assigned_identity.processor[0].principal_id : ""
}

output "MEGHKOSHA_OBO_MANAGED_IDENTITY_CLIENT_ID" {
  value = azurerm_user_assigned_identity.obo.client_id
}

output "MEGHKOSHA_OBO_MANAGED_IDENTITY_RESOURCE_ID" {
  value = azurerm_user_assigned_identity.obo.id
}

output "MEGHKOSHA_OBO_MANAGED_IDENTITY_PRINCIPAL_ID" {
  value = azurerm_user_assigned_identity.obo.principal_id
}

output "APP_INGRESS_HOST" {
  value = var.custom_domain != "" ? lower(var.custom_domain) : azurerm_public_ip.ingress.fqdn
}

output "APP_WEB_ORIGIN" {
  value = "https://${var.custom_domain != "" ? lower(var.custom_domain) : azurerm_public_ip.ingress.fqdn}"
}

output "APP_INGRESS_AZURE_FQDN" {
  value = azurerm_public_ip.ingress.fqdn
}

output "APP_INGRESS_CLASS" {
  value = local.ingress_class
}

output "APP_INGRESS_PUBLIC_IP" {
  value = azurerm_public_ip.ingress.ip_address
}

output "APP_INGRESS_PUBLIC_IP_NAME" {
  value = azurerm_public_ip.ingress.name
}

output "APP_INGRESS_NSG_NAME" {
  value = azurerm_network_security_group.aks_nodes.name
}

# "true" once HTTPS is limited to APP_WEB_ALLOWED_IP_RANGES. Operator mode opens the public URL only then: the value
# reaches the manifests after Terraform has applied the rule, so a plain azd deploy cannot open it early.
output "APP_WEB_INGRESS_RESTRICTED" {
  value = tostring(length(local.web_allowed_ip_ranges) > 0)
}

output "APP_TLS_CLUSTER_ISSUER" {
  value = var.tls_cluster_issuer
}

output "APP_PROCESSOR_DEPLOYED" {
  value = tostring(local.processor_deployed)
}

output "APP_PROCESSOR_CRON" {
  value = var.processor_schedule
}

output "APP_SCHEDULER_ENABLED" {
  value = tostring(local.processor_deployed)
}

output "MEGHKOSHA_AI_ENABLED" {
  value = tostring(local.ai_runtime_enabled)
}

output "FOUNDRY_CHAT_ENABLED" {
  value = tostring(local.chat_enabled)
}

output "AI_PROJECT_ENDPOINT" {
  value = local.ai_enabled ? "https://${azurerm_cognitive_account.ai[0].name}.services.ai.azure.com/api/projects/${var.foundry_project_name}" : ""
}

output "AI_SERVICES_ENDPOINT" {
  value = local.ai_enabled ? azurerm_cognitive_account.ai[0].endpoint : ""
}

output "AGENT_NAME" {
  value = var.agent_name
}

output "MODEL_ROUTER_DEPLOYMENT_NAME" {
  value = var.model_router_deployment_name
}

output "COST_EXPORT_STORAGE_URL" {
  value = local.data_enabled ? azurerm_storage_account.exports[0].primary_blob_endpoint : ""
}

output "COST_EXPORT_STORAGE_RESOURCE_ID" {
  value = local.data_enabled ? azurerm_storage_account.exports[0].id : ""
}

output "COST_EXPORT_NAME" {
  value = local.export_name
}

output "COST_EXPORT_DAILY_NAME" {
  value = local.daily_export_name
}

output "FOCUS_EXPORT_PARALLEL_MONTHS" {
  value = tostring(var.export_parallel_months)
}

output "APP_DEPLOYMENT_STATE" {
  value = {
    profile                       = var.profile
    hosting                       = "aks"
    dataInfrastructureDeployed    = local.data_enabled
    processorDeployed             = local.processor_deployed
    aiInfrastructureDeployed      = local.ai_enabled
    aiRuntimeEnabled              = local.ai_runtime_enabled
    chatRuntimeEnabled            = local.chat_enabled
    nativeExportIngressException  = local.data_enabled && var.allow_native_export_trusted_services
    apiServerAuthorizedRangesUsed = length(local.aks_api_authorized_ip_ranges) > 0
    liveValidationRequired        = true
  }
}
