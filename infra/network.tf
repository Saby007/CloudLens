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

  # The default rules already allow traffic within the VNet, load balancer health probes and all outbound traffic,
  # and deny everything else inbound. A private ingress therefore needs no allow rule here: traffic reaches the
  # internal load balancer from inside the network (or through the Private Link Service's NAT addresses, which are in
  # it) and the internet has no address to send to. The one rule it does carry states that intent, and keeps this
  # set from ever being empty: the provider treats an empty inline rule set as "unchanged", so a rule-less NSG would
  # keep the allow rules of an environment that was public before.
  dynamic "security_rule" {
    for_each = local.private_ingress ? [1] : []
    content {
      name                       = "DenyInternetInbound"
      description                = "Nothing from the internet reaches this subnet; the app is reached through its private address."
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_address_prefix      = "Internet"
      source_port_range          = "*"
      destination_address_prefix = "*"
      destination_port_range     = "*"
    }
  }

  # The rules below exist only for a public ingress.
  dynamic "security_rule" {
    for_each = local.public_ingress ? [1] : []
    content {
      name                       = "AllowHttpToIngress"
      description                = "HTTP for Let's Encrypt's HTTP-01 challenge and the redirect to HTTPS, to the ingress IP only."
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = "Internet"
      source_port_range          = "*"
      destination_address_prefix = one(azurerm_public_ip.ingress[*].ip_address)
      destination_port_range     = "80"
    }
  }

  # HTTPS reaches the app. An allow-list (APP_WEB_ALLOWED_IP_RANGES) limits it to those addresses. Without one it is
  # open to the internet, except in the Dev-only operator mode, which has no sign-in: there it stays closed and
  # kubectl port-forward is the way in. scripts/allow-my-ip.ps1 updates this rule's sources in place.
  dynamic "security_rule" {
    for_each = local.public_ingress && (length(local.web_allowed_ip_ranges) > 0 || var.auth_mode != "operator") ? [1] : []
    content {
      name                       = "AllowHttpsToIngress"
      description                = "HTTPS for users, to the ingress IP only."
      priority                   = 210
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = length(local.web_allowed_ip_ranges) > 0 ? null : "Internet"
      source_address_prefixes    = length(local.web_allowed_ip_ranges) > 0 ? local.web_allowed_ip_ranges : null
      source_port_range          = "*"
      destination_address_prefix = one(azurerm_public_ip.ingress[*].ip_address)
      destination_port_range     = "443"
    }
  }
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-private-endpoints-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# The private ingress's two subnets carry no rules of their own; the NSGs only keep Azure Policy from attaching one
# of its own (see the comment above subnet_nsg_version).
resource "azurerm_network_security_group" "ingress" {
  count               = local.private_ingress ? 1 : 0
  name                = "nsg-ingress-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "private_link" {
  count               = local.private_link_service_enabled ? 1 : 0
  name                = "nsg-private-link-${local.resource_token}"
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

# Private ingress: the internal load balancer's address lives here (AKS creates the load balancer in its node
# resource group and the app-routing controller binds it to this subnet and address; see infra/k8s/cluster-bootstrap.yaml).
resource "azurerm_subnet" "ingress" {
  count                = local.private_ingress ? 1 : 0
  name                 = "ingress"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.ingress_subnet_prefix]

  network_security_group_id_wo         = azurerm_network_security_group.ingress[0].id
  network_security_group_id_wo_version = local.subnet_nsg_version
}

# The Private Link Service takes its NAT addresses from this subnet; Azure refuses to create one in a subnet whose
# Private Link service network policies are on, which is the default.
resource "azurerm_subnet" "private_link" {
  count                                         = local.private_link_service_enabled ? 1 : 0
  name                                          = "private-link"
  resource_group_name                           = azurerm_resource_group.main.name
  virtual_network_name                          = azurerm_virtual_network.main.name
  address_prefixes                              = [var.private_link_subnet_prefix]
  private_link_service_network_policies_enabled = false

  network_security_group_id_wo         = azurerm_network_security_group.private_link[0].id
  network_security_group_id_wo_version = local.subnet_nsg_version
}

# Public ingress only: a static, Terraform-owned address whose DNS label gives the app a stable
# https://<label>.<region>.cloudapp.azure.com origin before anything is deployed.
resource "azurerm_public_ip" "ingress" {
  count               = local.public_ingress ? 1 : 0
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

# Environments created before the ingress could be private hold this address without an index.
moved {
  from = azurerm_public_ip.ingress
  to   = azurerm_public_ip.ingress[0]
}

# Private ingress: the app's host name resolves to the internal load balancer inside this network. The zone is named
# after the host itself, so it answers only for that name and hides nothing else in a parent domain. Networks that
# reach the app through a private endpoint need their own record for the host (scripts/deploy-test-jumpbox.ps1 and the
# README show how); a network that is peered or connected can link to this zone or forward the name here.
resource "azurerm_private_dns_zone" "ingress" {
  count               = local.private_ingress ? 1 : 0
  name                = local.ingress_host
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "ingress" {
  count                = local.private_ingress ? 1 : 0
  name                 = "link-${local.resource_token}"
  private_dns_zone_id  = azurerm_private_dns_zone.ingress[0].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_a_record" "ingress" {
  count               = local.private_ingress ? 1 : 0
  name                = "@"
  private_dns_zone_id = azurerm_private_dns_zone.ingress[0].id
  ttl                 = 300
  records             = [local.ingress_private_ip]
  tags                = local.tags
}
