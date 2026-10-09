terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  # azurerm 5.x registers nothing by default; the VM, Bastion and private endpoint need these.
  resource_providers_to_register = [
    "Microsoft.Compute",
    "Microsoft.DevTestLab",
    "Microsoft.Network",
  ]
}

locals {
  tags = {
    "azd-env-name" = var.environment_name
    "app-name"     = "cost-assessment"
    "purpose"      = "private-endpoint-test-jumpbox"
  }

  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "rg-${var.environment_name}-jumpbox"

  # One /24 split three ways: Bastion's subnet must be /26 or larger.
  bastion_subnet_prefix  = cidrsubnet(var.vnet_address_prefix, 2, 0)
  vm_subnet_prefix       = cidrsubnet(var.vnet_address_prefix, 3, 2)
  endpoint_subnet_prefix = cidrsubnet(var.vnet_address_prefix, 3, 3)

  trust_ca = var.ca_certificate_pem != ""
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-jumpbox-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_prefix]
  tags                = local.tags
}

# Azure Bastion needs every one of these rules once an NSG is attached to its subnet:
# https://learn.microsoft.com/azure/bastion/bastion-nsg
resource "azurerm_network_security_group" "bastion" {
  name                = "nsg-bastion-${var.environment_name}"
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

# The VM takes RDP from Bastion only. It has no public address and nothing else reaches it.
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "AllowRdpFromBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.bastion_subnet_prefix
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "3389"
  }
}

resource "azurerm_network_security_group" "endpoint" {
  name                = "nsg-endpoint-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.bastion_subnet_prefix]

  network_security_group_id_wo         = azurerm_network_security_group.bastion.id
  network_security_group_id_wo_version = 1
}

resource "azurerm_subnet" "vm" {
  name                 = "vm"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.vm_subnet_prefix]

  network_security_group_id_wo         = azurerm_network_security_group.vm.id
  network_security_group_id_wo_version = 1
}

resource "azurerm_subnet" "endpoint" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [local.endpoint_subnet_prefix]
  private_endpoint_network_policies = "Disabled"

  network_security_group_id_wo         = azurerm_network_security_group.endpoint.id
  network_security_group_id_wo_version = 1
}

resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${var.environment_name}"
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

resource "azurerm_bastion_host" "main" {
  name                = "bas-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = var.bastion_sku
  tags                = local.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# The private endpoint to the app's Private Link Service: the same path a customer's network uses. It connects without
# approval when this subscription is on the service's auto-approval list (APP_PRIVATE_LINK_ALLOWED_SUBSCRIPTIONS and
# the deployment subscription are); otherwise the connection waits until someone approves it on the service.
resource "azurerm_private_endpoint" "app" {
  name                = "pe-cloudlens-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.endpoint.id
  tags                = local.tags

  private_service_connection {
    name                           = "cloudlens"
    private_connection_resource_id = var.private_link_service_id
    is_manual_connection           = var.manual_connection
    request_message                = var.manual_connection ? "CloudLens test jump box" : null
  }
}

# The app's host name resolves to the private endpoint inside this network only. The zone is named after the host.
resource "azurerm_private_dns_zone" "app" {
  name                = var.app_host
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "app" {
  name                 = "link-${var.environment_name}"
  private_dns_zone_id  = azurerm_private_dns_zone.app.id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_dns_a_record" "app" {
  name                = "@"
  private_dns_zone_id = azurerm_private_dns_zone.app.id
  ttl                 = 300
  records             = [azurerm_private_endpoint.app.private_service_connection[0].private_ip_address]
  tags                = local.tags
}

resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-jumpbox-${var.environment_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Windows Server ships Microsoft Edge, which is all the test needs: open the app's URL in the browser on this VM.
resource "azurerm_windows_virtual_machine" "jumpbox" {
  name                  = "vm-jumpbox-${var.environment_name}"
  computer_name         = "cl-jumpbox"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = random_password.admin.result
  network_interface_ids = [azurerm_network_interface.vm.id]
  patch_mode            = "AutomaticByPlatform"
  tags                  = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

# Installs the cluster's private CA as a trusted root, so the browser accepts the app's certificate. The CA certificate
# is public, but it travels in the protected settings to keep it out of the deployment's plain output.
resource "azurerm_virtual_machine_extension" "trust_ca" {
  count                = local.trust_ca ? 1 : 0
  name                 = "trust-cloudlens-ca"
  virtual_machine_id   = azurerm_windows_virtual_machine.jumpbox.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  protected_settings = jsonencode({
    commandToExecute = "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$pem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64encode(var.ca_certificate_pem)}')); $path = Join-Path $env:TEMP 'cloudlens-ca.crt'; Set-Content -Path $path -Value $pem -Encoding ascii; Import-Certificate -FilePath $path -CertStoreLocation Cert:\\LocalMachine\\Root | Out-Null\""
  })
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "jumpbox" {
  count                 = var.auto_shutdown_enabled ? 1 : 0
  location              = azurerm_resource_group.main.location
  virtual_machine_id    = azurerm_windows_virtual_machine.jumpbox.id
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = "UTC"
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
