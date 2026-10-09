# Outbound traffic. A NAT gateway gives the cluster (and the deploy host) one static public address to reach the
# internet with, and nothing the internet can connect to: no inbound rule, no public load balancer. The cluster's
# standard load balancer then carries only the internal ingress.
resource "azurerm_public_ip" "nat" {
  count               = local.nat_gateway_enabled ? 1 : 0
  name                = "pip-nat-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    # Azure Policy can add IP tags in some tenants; a changed tag would force a new address.
    ignore_changes = [tags, ip_tags]
  }
}

resource "azurerm_nat_gateway" "main" {
  count                   = local.nat_gateway_enabled ? 1 : 0
  name                    = "nat-${local.resource_token}"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.aks_outbound_idle_timeout_minutes
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count                = local.nat_gateway_enabled ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.main[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# AKS requires the gateway on the node subnet before it creates a cluster that uses it for outbound traffic.
resource "azurerm_subnet_nat_gateway_association" "aks" {
  count          = local.aks_nat_gateway_outbound ? 1 : 0
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id

  depends_on = [azurerm_nat_gateway_public_ip_association.main]
}
