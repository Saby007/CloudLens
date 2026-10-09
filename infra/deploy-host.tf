# The deploy host. A private cluster's API server and a private registry cannot be reached from the internet, so
# whoever deploys needs a machine inside the virtual network. This is a small Linux VM with no public address, reached
# through Azure Bastion, with the tools installed (infra/deploy-host-cloud-init.yaml). scripts/prepare-deploy-host.ps1
# puts this environment's settings on it; scripts/deploy-on-host.ps1 then runs the deployment there.

locals {
  deploy_host_admin = "cloudlensadmin"
}

# Azure Bastion needs every one of these rules once an NSG is attached to its subnet:
# https://learn.microsoft.com/azure/bastion/bastion-nsg
resource "azurerm_network_security_group" "bastion" {
  count               = local.deploy_host_enabled ? 1 : 0
  name                = "nsg-bastion-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "443"
  }

  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "GatewayManager"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "443"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 140
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "443"
  }

  security_rule {
    name                       = "AllowBastionHostCommunication"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    source_port_range          = "*"
    destination_address_prefix = "VirtualNetwork"
    destination_port_ranges    = ["8080", "5701"]
  }

  security_rule {
    name                       = "AllowSshRdpOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "VirtualNetwork"
    destination_port_ranges    = ["22", "3389"]
  }

  security_rule {
    name                       = "AllowAzureCloudOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "AzureCloud"
    destination_port_range     = "443"
  }

  security_rule {
    name                       = "AllowBastionCommunication"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    source_port_range          = "*"
    destination_address_prefix = "VirtualNetwork"
    destination_port_ranges    = ["8080", "5701"]
  }

  security_rule {
    name                       = "AllowHttpOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "Internet"
    destination_port_range     = "80"
  }
}

# The VM takes SSH from Bastion only; it has no public address and nothing else reaches it.
resource "azurerm_network_security_group" "deploy_host" {
  count               = local.deploy_host_enabled ? 1 : 0
  name                = "nsg-deploy-host-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "AllowSshFromBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.bastion_subnet_prefix
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "22"
  }
}

resource "azurerm_subnet" "bastion" {
  count                = local.deploy_host_enabled ? 1 : 0
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.bastion_subnet_prefix]

  network_security_group_id_wo         = azurerm_network_security_group.bastion[0].id
  network_security_group_id_wo_version = local.subnet_nsg_version
}

resource "azurerm_subnet" "deploy_host" {
  count                = local.deploy_host_enabled ? 1 : 0
  name                 = "deploy-host"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.deploy_host_subnet_prefix]

  network_security_group_id_wo         = azurerm_network_security_group.deploy_host[0].id
  network_security_group_id_wo_version = local.subnet_nsg_version
}

resource "azurerm_subnet_nat_gateway_association" "deploy_host" {
  count          = local.deploy_host_enabled ? 1 : 0
  subnet_id      = azurerm_subnet.deploy_host[0].id
  nat_gateway_id = azurerm_nat_gateway.main[0].id

  depends_on = [azurerm_nat_gateway_public_ip_association.main]
}

# Bastion's own address is how administrators reach the portal-side session; it accepts no connection to the app.
resource "azurerm_public_ip" "bastion" {
  count               = local.deploy_host_enabled ? 1 : 0
  name                = "pip-bastion-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags, ip_tags]
  }
}

resource "azurerm_bastion_host" "deploy_host" {
  count               = local.deploy_host_enabled ? 1 : 0
  name                = "bas-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Basic"
  tags                = local.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

resource "random_password" "deploy_host" {
  count            = local.deploy_host_enabled ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "deploy_host" {
  count               = local.deploy_host_enabled ? 1 : 0
  name                = "nic-deploy-host-${local.resource_token}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.deploy_host[0].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "deploy_host" {
  count                           = local.deploy_host_enabled ? 1 : 0
  name                            = "vm-deploy-${substr(local.resource_token, 0, 8)}"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = var.deploy_host_vm_size
  admin_username                  = local.deploy_host_admin
  admin_password                  = random_password.deploy_host[0].result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.deploy_host[0].id]
  custom_data                     = base64encode(file("${path.module}/deploy-host-cloud-init.yaml"))
  tags                            = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # The tools install through the NAT gateway, so the gateway must exist first.
  depends_on = [azurerm_subnet_nat_gateway_association.deploy_host]
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "deploy_host" {
  count                 = local.deploy_host_enabled && var.deploy_host_shutdown_time != "" ? 1 : 0
  location              = azurerm_resource_group.main.location
  virtual_machine_id    = azurerm_linux_virtual_machine.deploy_host[0].id
  enabled               = true
  daily_recurrence_time = var.deploy_host_shutdown_time
  timezone              = "UTC"
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
