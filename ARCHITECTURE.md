# LiteLLM Okta Proxy - Architecture

## Overview

A secure API Gateway proxy that enforces Okta JWT authentication and injects LiteLLM master keys at runtime, ensuring keys are never exposed in configuration or logs.

## Request Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Client Application                                          │
│ (with Okta JWT in Authorization header)                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ Authorization: Bearer eyJra...
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ API Gateway v2 (HTTP)                                       │
│ • Route: ANY /{proxy+}                                      │
│ • Auto-deploys changes                                      │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ Okta JWT Authorizer                                         │
│ • Validates token signature (Okta JWKS)                    │
│ • Checks issuer (sub.oktapreview.com)          │
│ • Checks audience (api://default)                          │
│ • Extracts claims (sub, email, etc.)                       │
│                                                             │
│ ✅ If valid: continue to Lambda                            │
│ ❌ If invalid: return 401 Unauthorized                     │
└──────────────────────┬──────────────────────────────────────┘
                       │ (only authenticated requests proceed)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ Lambda Function (litellm-okta-proxy)                        │
│                                                             │
│ 1. Retrieve master key from AWS Secrets Manager             │
│    • Key never stored in Terraform or code                  │
│    • Fetched at runtime only                                │
│                                                             │
│ 2. Strip Okta JWT from Authorization header                 │
│    • Remove client's original token                         │
│                                                             │
│ 3. Inject LiteLLM master key                                │
│    • Set Authorization: Bearer sk-...                       │
│    • Set x-litellm-user (from Okta sub claim)              │
│                                                             │
│ 4. Forward to LiteLLM backend                               │
│    • With HTTPS (SSL cert verification disabled)            │
│    • With injected master key                               │
└──────────────────────┬──────────────────────────────────────┘
                       │ Authorization: Bearer sk-...
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ LiteLLM Backend (Private ALB)                               │
│ • Validates master key                                      │
│ • Processes OpenAI-compatible API requests                  │
│ • Returns model listings, chat completions, etc.            │
└──────────────────────┬──────────────────────────────────────┘
                       │ Response (JSON)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ API Gateway Response                                        │
│ • Status code, headers, body from Lambda                    │
│ • Returned to client                                        │
└─────────────────────────────────────────────────────────────┘
```

## Security Layers

### Layer 1: AWS Secrets Manager
- Master key stored encrypted at rest
- Access controlled via IAM policy (Lambda role only)
- Audit trail via CloudTrail

### Layer 2: Runtime Injection
- Key retrieved only when request is processed
- Not stored in Lambda memory between requests
- Never logged or exposed in API Gateway

### Layer 3: HTTPS Transport
- All traffic to LiteLLM over HTTPS
- End-to-end encryption in transit

## Components

| Component | Type | Purpose |
|-----------|------|---------|
| API Gateway v2 | AWS | HTTP endpoint, JWT validation, routing |
| Okta JWT Authorizer | AWS | Token signature verification |
| Lambda Function | AWS | Key injection, request proxying |
| AWS Secrets Manager | AWS | Encrypted master key storage |
| LiteLLM Backend | ECS | OpenAI-compatible LLM proxy |

## Authentication Flow

1. **Client** sends request with Okta JWT
2. **API Gateway Authorizer** validates JWT against Okta's JWKS
3. **Okta validation checks:**
   - Signature is valid (signed by Okta)
   - Issuer matches configuration
   - Audience matches configuration
   - Token is not expired
4. **Lambda** only runs if authorization passes
5. **Lambda** injects master key (not visible in configuration)

## Key Features

✅ **Zero key exposure**: Master key never in Terraform resources
✅ **Runtime injection**: Key retrieved only when needed
✅ **User tracking**: Okta email injected as x-litellm-user
✅ **Auditable**: All actions logged to CloudWatch
✅ **Scalable**: Serverless architecture with auto-scaling

## Configuration

| Variable | Source | Purpose |
|----------|--------|---------|
| `okta_issuer_url` | terraform.tfvars | Okta OAuth2 issuer |
| `okta_audience` | terraform.tfvars | Expected audience in JWT |
| `litellm_backend_url` | terraform.tfvars | LiteLLM backend URL |
| `litellm_master_key_secret_arn` | terraform.tfvars | Secrets Manager secret ARN |

## Testing

**Endpoint:** `https://xqus7qui05.execute-api.us-east-1.amazonaws.com`

### Test Cases

1. **Without token** → 401 Unauthorized (API Gateway rejects)
2. **Invalid token** → 401 Unauthorized (Okta validation fails)
3. **Expired token** → 401 Unauthorized (JWT exp check fails)
4. **Valid Okta JWT** → 200 OK (request proxied to LiteLLM with master key)

