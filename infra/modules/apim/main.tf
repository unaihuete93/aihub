locals {
  logger_name = "openai-appi-logger"
  backend_url = "${var.openai_service_endpoint}openai"
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

resource "azapi_resource" "apim" {
  type      = "Microsoft.ApiManagement/service@2023-05-01-preview"
  name      = var.apim_name
  parent_id = data.azurerm_resource_group.rg.id
  location  = var.location
  identity {
    type = "SystemAssigned"
  }
  schema_validation_enabled = false # requiered for now
  body = jsonencode({
    sku = {
      name     = "StandardV2"
      capacity = 1
    }
    properties = {
      publisherEmail        = var.publisher_email
      publisherName         = var.publisher_name
      apiVersionConstraint  = {}
      developerPortalStatus = "Disabled"
    }
  })
  response_export_values = [
    "identity.principalId",
    "properties.gatewayUrl"
  ]
}

resource "azurerm_api_management_backend" "openai" {
  name                = "openai-api"
  resource_group_name = var.resource_group_name
  api_management_name = azapi_resource.apim.name
  protocol            = "http"
  url                 = local.backend_url
  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

resource "azurerm_api_management_logger" "appi_logger" {
  name                = local.logger_name
  api_management_name = azapi_resource.apim.name
  resource_group_name = var.resource_group_name
  resource_id         = var.appi_resource_id

  application_insights {
    instrumentation_key = var.appi_instrumentation_key
  }
}

// https://learn.microsoft.com/en-us/semantic-kernel/deploy/use-ai-apis-with-api-management#setup-azure-api-management-instance-with-azure-openai-api
resource "azurerm_api_management_api" "openai" {
  name                  = "openai-api"
  resource_group_name   = var.resource_group_name
  api_management_name   = azapi_resource.apim.name
  revision              = "1"
  display_name          = "Azure Open AI API"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = false
  service_url           = local.backend_url

  import {
    content_format = "openapi-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/preview/2023-10-01-preview/inference.json"
  }
}

resource "azurerm_api_management_named_value" "tenant_id" {
  name                = "tenant-id"
  resource_group_name = var.resource_group_name
  api_management_name = azapi_resource.apim.name
  display_name        = "TENANT_ID"
  value               = var.tenant_id
}

resource "azurerm_api_management_api_policy" "policy" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = var.resource_group_name

  xml_content = <<XML
    <policies>
        <inbound>
            <base />
            <validate-jwt header-name="Authorization" failed-validation-httpcode="403" failed-validation-error-message="Forbidden">
                <openid-config url="https://login.microsoftonline.com/{{TENANT_ID}}/v2.0/.well-known/openid-configuration" />
                <issuers>
                    <issuer>https://sts.windows.net/{{TENANT_ID}}/</issuer>
                </issuers>
                <required-claims>
                    <claim name="aud">
                        <value>https://cognitiveservices.azure.com</value>
                    </claim>
                </required-claims>
            </validate-jwt>

            <set-backend-service backend-id="openai-api" />
        </inbound>
        <backend>
          <base />
        </backend>
        <outbound>
            <base />
        </outbound>
        <on-error>
          <base />
        </on-error>
    </policies>
    XML
  depends_on  = [azurerm_api_management_backend.openai]
}

# https://github.com/aavetis/azure-openai-logger/blob/main/README.md
# KQL Query to extract OpenAI data from Application Insights
# requests
# | where operation_Name == "openai-api;rev=1 - Completions_Create" or operation_Name == "openai-api;rev=1 - ChatCompletions_Create"
# | extend Prompt = parse_json(tostring(parse_json(tostring(parse_json(tostring(customDimensions.["Request-Body"])).messages[-1].content))))
# | extend Generation = parse_json(tostring(parse_json(tostring(parse_json(tostring(customDimensions.["Response-Body"])).choices))[0].message)).content
# | extend promptTokens = parse_json(tostring(parse_json(tostring(customDimensions.["Response-Body"])).usage)).prompt_tokens
# | extend completionTokens = parse_json(tostring(parse_json(tostring(customDimensions.["Response-Body"])).usage)).completion_tokens
# | extend totalTokens = parse_json(tostring(parse_json(tostring(customDimensions.["Response-Body"])).usage)).total_tokens
# | project timestamp, Prompt, Generation, promptTokens, completionTokens, totalTokens, round(duration,2), operation_Name
resource "azurerm_api_management_diagnostic" "diagnostics" {
  identifier               = "applicationinsights"
  resource_group_name      = var.resource_group_name
  api_management_name      = azapi_resource.apim.name
  api_management_logger_id = azurerm_api_management_logger.appi_logger.id

  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = false
  verbosity                 = "information"
  http_correlation_protocol = "W3C"

  frontend_request {
    body_bytes     = 8192
    headers_to_log = []
    data_masking {
      query_params {
        mode  = "Hide"
        value = "*"
      }
    }
  }

  frontend_response {
    body_bytes     = 8192
    headers_to_log = []
  }

  backend_request {
    body_bytes     = 8192
    headers_to_log = []
    data_masking {
      query_params {
        mode  = "Hide"
        value = "*"
      }
    }
  }

  backend_response {
    body_bytes     = 8192
    headers_to_log = []
  }
}
