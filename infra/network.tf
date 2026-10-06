resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_prefix]
  tags                = local.tags
}

# Some tenants' Azure Policy attaches its own NSG to any subnet without one, and that NSG's default rules
# deny the internet traffic the ingress needs. So the subnets get their NSGs from Terraform in the same request
# that creates them, or, on an environment where a policy already attached one, the next time they're updated.
# The NSG ID is write-only: the provider applies it only when subnet_nsg_version changes.
locals {
  subnet_nsg_version = 1
}

resource "azurerm_network_security_group" "aks_nodes" {
  name                = "nsg-aks-nodes-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  # The default rules already allow traffic within the VNet, load balancer health probes and all outbound traffic.
  security_rule {
    name                       = "AllowWebToIngress"
    description                = "HTTPS for users and HTTP for Let's Encrypt's HTTP-01 challenge, to the ingress IP only."
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = azurerm_public_ip.ingress.ip_address
    destination_port_ranges    = ["80", "443"]
  }
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-private-endpoints-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_prefix]

  network_security_group_id_wo         = azurerm_network_security_group.aks_nodes.id
  network_security_group_id_wo_version = local.subnet_nsg_version
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.private_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Disabled"

  network_security_group_id_wo         = azurerm_network_security_group.private_endpoints.id
  network_security_group_id_wo_version = local.subnet_nsg_version
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
    # The cluster's load balancer adds its own k8s-azure-* tags once the ingress controller uses this IP, and in
    # some tenants Azure Policy adds IP tags (FirstPartyUsage). A changed IP tag would force a new IP address.
    ignore_changes = [tags, ip_tags]
  }
}
