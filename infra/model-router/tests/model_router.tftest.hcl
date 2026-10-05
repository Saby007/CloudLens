# Offline contract test with a mocked provider; nothing is created in Azure.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      object_id       = "22222222-2222-2222-2222-222222222222"
      client_id       = "33333333-3333-3333-3333-333333333333"
    }
  }
}

variables {
  resource_group_name = "rg-app-test"
  account_name        = "ai-example"
}

run "only_the_pinned_model_router_child_is_managed" {
  command = apply

  assert {
    condition = (
      azurerm_cognitive_deployment.model_router.name == "model-router" &&
      azurerm_cognitive_deployment.model_router.cognitive_account_id == "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-app-test/providers/Microsoft.CognitiveServices/accounts/ai-example" &&
      azurerm_cognitive_deployment.model_router.model[0].format == "OpenAI" &&
      azurerm_cognitive_deployment.model_router.model[0].name == "model-router" &&
      azurerm_cognitive_deployment.model_router.model[0].version == "2025-11-18" &&
      azurerm_cognitive_deployment.model_router.sku[0].name == "GlobalStandard" &&
      azurerm_cognitive_deployment.model_router.sku[0].capacity == 20 &&
      azurerm_cognitive_deployment.model_router.version_upgrade_option == "NoAutoUpgrade"
    )
    error_message = "The Model Router deployment must stay pinned to the approved version, SKU and capacity."
  }
}
