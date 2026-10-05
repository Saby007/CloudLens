resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_prefix]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_prefix]
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.private_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

# Static, Terraform-owned ingress address: its DNS label gives the app a stable
# https://<label>.<region>.cloudapp.azure.com origin before anything is deployed.
resource "azurerm_public_ip" "ingress" {
  name                = "pip-ingress-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.aks_zones
  domain_name_label   = local.ingress_dns_label
  tags                = local.tags

  lifecycle {
    # The cluster's load balancer adds its own k8s-azure-* tags once the ingress controller uses this IP.
    ignore_changes = [tags]
  }
}
