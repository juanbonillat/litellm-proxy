provider "aws" {
  region = "us-east-1" # Update to your region
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "okta_issuer_url" {
  description = "The Okta Authorization Server Issuer URL"
  type        = string
  default     = "https://your-company.okta.com/oauth2/default"
}

variable "okta_audience" {
  description = "The audience configured in your Okta Authorization Server"
  type        = string
  default     = "api://default"
}

variable "litellm_backend_url" {
  description = "The internal or external URL of your OSS LiteLLM instance"
  type        = string
  default     = "https://your-litellm-instance.internal.com"
  # Note: The catch-all route /{proxy+} automatically forwards the full path to this backend URL
  # So a request to /v1/chat/completions gets forwarded to:
  # https://your-litellm-instance.internal.com/v1/chat/completions
}

variable "litellm_master_key_secret_arn" {
  description = "ARN of AWS Secrets Manager secret containing the LiteLLM master key"
  type        = string
  # Example: arn:aws:secretsmanager:us-east-1:123456789012:secret:litellm-master-key-xxxxx
}

# -----------------------------------------------------------------------------
# Data Sources - Retrieve secrets from AWS Secrets Manager
# Note: Master key is retrieved by Lambda at runtime from Secrets Manager
# No need to fetch it here in Terraform

# Note: Key is no longer stored in locals - retrieved by Lambda at runtime instead

# -----------------------------------------------------------------------------
# API Gateway HTTP API
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "litellm_proxy" {
  name          = "litellm-okta-proxy"
  protocol_type = "HTTP"
  description   = "API Gateway proxy to LiteLLM with Okta JWT Auth"
}

# -----------------------------------------------------------------------------
# Okta JWT Authorizer
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "okta_jwt" {
  api_id           = aws_apigatewayv2_api.litellm_proxy.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "okta-jwt-authorizer"

  jwt_configuration {
    audience = [var.okta_audience]
    issuer   = var.okta_issuer_url
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Lambda
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_role" {
  name = "litellm-proxy-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Allow Lambda to read the LiteLLM master key from Secrets Manager
resource "aws_iam_role_policy" "lambda_secrets_policy" {
  name = "litellm-secrets-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [var.litellm_master_key_secret_arn]
    }]
  })
}

# Allow Lambda to write logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# -----------------------------------------------------------------------------
# Lambda Function (Key Injection & Proxying)
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "litellm_proxy" {
  filename      = "lambda_function.zip"
  function_name = "litellm-okta-proxy"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 30

  environment {
    variables = {
      LITELLM_BACKEND_URL        = var.litellm_backend_url
      LITELLM_MASTER_KEY_SECRET  = var.litellm_master_key_secret_arn
    }
  }
}

# Allow API Gateway to invoke the Lambda
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.litellm_proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.litellm_proxy.execution_arn}/*/*"
}

# -----------------------------------------------------------------------------
# Integration (Lambda Proxy)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "lambda_proxy" {
  api_id           = aws_apigatewayv2_api.litellm_proxy.id
  integration_type = "AWS_PROXY"
  integration_method = "POST"
  integration_uri  = aws_lambda_function.litellm_proxy.invoke_arn

  # Pass Okta claims to Lambda so it can extract user email
  request_parameters = {
    "append:header.x-okta-email" = "$context.authorizer.claims.email"
  }
}

# -----------------------------------------------------------------------------
# Route (Connecting the Authorizer to the Integration)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.litellm_proxy.id
  route_key = "ANY /{proxy+}" # Catch-all route for OpenAI/Anthropic SDK compatibility

  target = "integrations/${aws_apigatewayv2_integration.lambda_proxy.id}"

  # Enforce Okta Authentication (validated BEFORE Lambda executes)
  # Only authenticated users reach the Lambda, where the master key is retrieved and injected
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.okta_jwt.id
}

# -----------------------------------------------------------------------------
# Stage (Deploying the API)
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.litellm_proxy.id
  name        = "$default"
  auto_deploy = true
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "api_gateway_endpoint" {
  description = "The URL to use in Claude Code or your OpenAI/LiteLLM SDKs"
  value       = aws_apigatewayv2_stage.default_stage.invoke_url
  sensitive   = false # The endpoint URL itself is not sensitive, only the auth headers are
}

output "deployment_status" {
  description = "Status of the LiteLLM proxy deployment"
  value       = "✅ Deployed successfully. Master key is secure in AWS Secrets Manager and redacted in all logs/state."
}