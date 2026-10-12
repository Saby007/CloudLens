# Offline contract tests for the private endpoint test jump box: mocked providers, no Azure credentials or resources.
# Run with `terraform init -backend=false` then `terraform test` from infra/test-jumpbox/.

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
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/virtualNetworks/vnet-test"
    }
  }


  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/networkSecurityGroups/nsg-test"
    }
  }

  mock_resource "azurerm_public_ip" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/publicIPAddresses/pip-test"
    }
  }

  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/privateDnsZones/cloudlens.contoso.com"
    }
  }

  mock_resource "azurerm_network_interface" {
    defaults = {
      id                 = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/networkInterfaces/nic-test"
      private_ip_address = "10.50.0.68"
    }
  }

  mock_resource "azurerm_private_endpoint" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/privateEndpoints/pe-test"
    }
  }

  mock_resource "azurerm_windows_virtual_machine" {
    defaults = {
      id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Compute/virtualMachines/vm-test"
    }
  }
}

mock_provider "random" {}

override_resource {
  target = azurerm_subnet.bastion
  values = {
    id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/AzureBastionSubnet"
  }
}

override_resource {
  target = azurerm_subnet.vm
  values = {
    id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/vm"
  }
}

override_resource {
  target = azurerm_subnet.endpoint
  values = {
    id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-jumpbox/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/private-endpoints"
  }
}

override_resource {
  target = random_password.admin
  values = {
    result = "Aa1-Bb2_Cc3=Dd4+Ee5!Ff6"
  }
}


variables {
  environment_name        = "app-test"
  location                = "centralindia"
  app_host                = "cloudlens.contoso.com"
  private_link_service_id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test-aks-nodes/providers/Microsoft.Network/privateLinkServices/pls-cloudlens-test"
}

run "the_jump_box_reaches_the_app_only_through_a_private_endpoint_and_bastion" {
  command = apply

  assert {
    condition = (
      azurerm_resource_group.main.name == "rg-app-test-jumpbox" &&
      tolist(azurerm_virtual_network.main.address_space) == tolist(["10.50.0.0/24"]) &&
      tolist(azurerm_subnet.bastion.address_prefixes) == tolist(["10.50.0.0/26"]) && azurerm_subnet.bastion.name == "AzureBastionSubnet" &&
      tolist(azurerm_subnet.vm.address_prefixes) == tolist(["10.50.0.64/27"]) &&
      tolist(azurerm_subnet.endpoint.address_prefixes) == tolist(["10.50.0.96/27"]) &&
      azurerm_subnet.endpoint.private_endpoint_network_policies == "Disabled"
    )
    error_message = "The /24 must split into a /26 Bastion subnet and /27 VM and private endpoint subnets, in a resource group of its own."
  }

  assert {
    condition = (
      azurerm_private_endpoint.app.private_service_connection[0].private_connection_resource_id == var.private_link_service_id &&
      azurerm_private_endpoint.app.private_service_connection[0].is_manual_connection == false &&
      azurerm_private_dns_zone.app.name == "cloudlens.contoso.com" &&
      azurerm_private_dns_a_record.app.name == "@" &&
      tolist(azurerm_private_dns_a_record.app.records) == tolist([azurerm_private_endpoint.app.private_service_connection[0].private_ip_address]) &&
      azurerm_private_dns_zone_virtual_network_link.app.registration_enabled == false &&
      output.private_endpoint_ip == azurerm_private_endpoint.app.private_service_connection[0].private_ip_address && output.app_url == "https://cloudlens.contoso.com"
    )
    error_message = "The app's host name must resolve to the private endpoint, which connects to the Private Link Service."
  }

  assert {
    condition = (
      azurerm_bastion_host.main.sku == "Basic" && azurerm_public_ip.bastion.sku == "Standard" &&
      azurerm_windows_virtual_machine.jumpbox.size == "Standard_B2ms" &&
      azurerm_windows_virtual_machine.jumpbox.admin_username == "cloudlensadmin" &&
      azurerm_windows_virtual_machine.jumpbox.source_image_reference[0].sku == "2022-datacenter-azure-edition" &&
      azurerm_windows_virtual_machine.jumpbox.patch_mode == "AutomaticByPlatform" &&
      length(azurerm_network_interface.vm.ip_configuration) == 1 && azurerm_network_interface.vm.ip_configuration[0].public_ip_address_id == null
    )
    error_message = "The VM must have no public address; only Bastion is reachable from the internet."
  }

  assert {
    condition = (
      length(azurerm_virtual_machine_extension.trust_ca) == 0 && output.trusts_private_ca == false &&
      length(azurerm_dev_test_global_vm_shutdown_schedule.jumpbox) == 1 &&
      azurerm_dev_test_global_vm_shutdown_schedule.jumpbox[0].daily_recurrence_time == "1800" &&
      azurerm_dev_test_global_vm_shutdown_schedule.jumpbox[0].notification_settings[0].enabled == false
    )
    error_message = "Without a CA certificate none is installed, and the VM shuts itself down every day."
  }

  assert {
    condition = (
      length(azurerm_network_security_group.vm.security_rule) == 1 &&
      one(azurerm_network_security_group.vm.security_rule).source_address_prefix == "10.50.0.0/26" &&
      one(azurerm_network_security_group.vm.security_rule).destination_port_range == "3389" &&
      toset([for rule in azurerm_network_security_group.bastion.security_rule : rule.name]) == toset([
        "AllowHttpsInbound", "AllowGatewayManagerInbound", "AllowAzureLoadBalancerInbound", "AllowBastionHostCommunication",
        "AllowSshRdpOutbound", "AllowAzureCloudOutbound", "AllowBastionCommunication", "AllowHttpOutbound",
      ])
    )
    error_message = "The VM takes RDP from the Bastion subnet only, and Bastion's subnet carries every rule Azure Bastion requires."
  }

  assert {
    condition     = output.admin_username == "cloudlensadmin" && nonsensitive(output.admin_password) == "Aa1-Bb2_Cc3=Dd4+Ee5!Ff6"
    error_message = "The generated administrator password must be exposed only as a sensitive output."
  }
}

run "the_private_ca_is_installed_as_a_trusted_root_and_the_endpoint_can_wait_for_approval" {
  command = apply

  variables {
    ca_certificate_pem    = "-----BEGIN CERTIFICATE-----\nMIIBsample\n-----END CERTIFICATE-----\n"
    manual_connection     = true
    auto_shutdown_enabled = false
    bastion_sku           = "Standard"
    vnet_address_prefix   = "10.60.0.0/24"
  }

  assert {
    condition = (
      length(azurerm_virtual_machine_extension.trust_ca) == 1 && output.trusts_private_ca == true &&
      azurerm_virtual_machine_extension.trust_ca[0].type == "CustomScriptExtension" &&
      strcontains(nonsensitive(azurerm_virtual_machine_extension.trust_ca[0].protected_settings), "Cert:\\\\LocalMachine\\\\Root") &&
      strcontains(nonsensitive(azurerm_virtual_machine_extension.trust_ca[0].protected_settings), base64encode("-----BEGIN CERTIFICATE-----\nMIIBsample\n-----END CERTIFICATE-----\n"))
    )
    error_message = "A CA certificate must be installed into the machine's trusted roots, passed as protected, base64-encoded settings."
  }

  assert {
    condition = (
      azurerm_private_endpoint.app.private_service_connection[0].is_manual_connection == true &&
      length(azurerm_dev_test_global_vm_shutdown_schedule.jumpbox) == 0 && azurerm_bastion_host.main.sku == "Standard" &&
      tolist(azurerm_subnet.bastion.address_prefixes) == tolist(["10.60.0.0/26"])
    )
    error_message = "Manual connections, no auto-shutdown, a Standard Bastion and another address space must all be honored."
  }
}

run "settings_must_be_exact_and_a_private_key_is_never_accepted" {
  command = plan

  variables {
    environment_name        = "App_Test"
    app_host                = "Not A Host"
    private_link_service_id = "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet"
    ca_certificate_pem      = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"
    vnet_address_prefix     = "10.50.0.0/23"
    bastion_sku             = "Developer"
    admin_username          = "Administrator"
    auto_shutdown_time      = "2500"
  }

  expect_failures = [
    var.environment_name,
    var.app_host,
    var.private_link_service_id,
    var.ca_certificate_pem,
    var.vnet_address_prefix,
    var.bastion_sku,
    var.admin_username,
    var.auto_shutdown_time,
  ]
}

run "the_deployer_signs_in_with_entra_and_more_people_can_be_added" {
  command = apply

  variables {
    entra_login_principal_ids = ["44444444-4444-4444-4444-444444444444", "22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition = (
      azurerm_windows_virtual_machine.jumpbox.identity[0].type == "SystemAssigned" &&
      azurerm_virtual_machine_extension.entra_login[0].publisher == "Microsoft.Azure.ActiveDirectory" &&
      azurerm_virtual_machine_extension.entra_login[0].type == "AADLoginForWindows" &&
      output.entra_login_enabled == true &&
      azurerm_bastion_host.main.sku == "Basic"
    )
    error_message = "Entra sign-in needs the VM's own identity and the AADLoginForWindows extension; the Basic Bastion supports it in the portal."
  }

  assert {
    condition = (
      toset(keys(azurerm_role_assignment.entra_login)) == toset(["22222222-2222-2222-2222-222222222222", "44444444-4444-4444-4444-444444444444"]) &&
      alltrue([for assignment in azurerm_role_assignment.entra_login : assignment.role_definition_name == "Virtual Machine Administrator Login"])
    )
    error_message = "The deployer and each extra principal get the Virtual Machine Administrator Login role once, on the VM."
  }
}

run "entra_sign_in_can_be_switched_off_leaving_only_the_local_password" {
  command = apply

  variables {
    entra_login_enabled = false
  }

  assert {
    condition = (
      length(azurerm_virtual_machine_extension.entra_login) == 0 &&
      length(azurerm_role_assignment.entra_login) == 0 &&
      length(azurerm_windows_virtual_machine.jumpbox.identity) == 0 &&
      output.entra_login_enabled == false
    )
    error_message = "Without Entra sign-in there is no identity, extension or role."
  }
}

run "entra_login_principals_must_be_object_ids" {
  command = plan

  variables {
    entra_login_principal_ids = ["alice@contoso.com"]
  }

  expect_failures = [var.entra_login_principal_ids]
}