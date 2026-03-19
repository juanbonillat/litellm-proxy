"""
Lambda function that proxies requests to LiteLLM.

Retrieves the master key from AWS Secrets Manager at runtime
(never exposed in Terraform or resource definitions).
"""

import json
import os
import boto3
import urllib.request
import urllib.parse
import ssl

secrets_client = boto3.client("secretsmanager")
litellm_backend = os.environ["LITELLM_BACKEND_URL"]
master_key_secret_arn = os.environ["LITELLM_MASTER_KEY_SECRET"]


def get_master_key():
    """Retrieve master key from AWS Secrets Manager at runtime."""
    try:
        response = secrets_client.get_secret_value(SecretId=master_key_secret_arn)
        secret = json.loads(response["SecretString"])
        return secret["master_key"]
    except Exception as e:
        print(f"❌ Error retrieving secret: {e}")
        raise


def handler(event, _context):
    """API Gateway Lambda proxy handler."""

    try:
        # Debug: print event structure
        print(f"[Lambda] Event keys: {list(event.keys())}")
        print(f"[Lambda] requestContext keys: {list(event.get('requestContext', {}).keys())}")

        authorizer = event.get('requestContext', {}).get('authorizer', {})
        print(f"[Lambda] Authorizer claims: {json.dumps(authorizer, indent=2)}")

        # ✅ Only authenticated Okta users reach here (JWT authorizer validates first)
        headers = event.get("headers", {})
        user_email = headers.get("x-okta-email", "unknown")

        # ✅ Retrieve master key at runtime (not in resource definitions)
        master_key = get_master_key()

        # Extract request details - handle both formats
        request_context = event.get("requestContext", {})
        if "http" in request_context:
            method = request_context["http"]["method"]
        else:
            method = request_context.get("method", "GET")

        path = event.get("rawPath", event.get("path", "/"))
        body = event.get("body", "")

        # Build full URL (remove trailing slash from backend URL to avoid double slashes)
        backend_url = litellm_backend.rstrip("/")
        url = f"{backend_url}{path}"
        if event.get("rawQueryString"):
            url += f"?{event['rawQueryString']}"

        # Prepare headers for LiteLLM
        request_headers = {
            "Authorization": f"Bearer {master_key}",  # ✅ Injected at runtime only
            "x-litellm-user": user_email,
            "Content-Type": "application/json",
        }

        print(f"[Lambda] 🚀 Proxying {method} {path} to {litellm_backend}")
        print(f"[Lambda] 👤 User: {user_email}")
        print(f"[Lambda] 🔑 Master key: {master_key[:20]}...")
        print(f"[Lambda] 📝 URL: {url}")
        print(f"[Lambda] 📋 Request headers: {json.dumps(request_headers, indent=2)}")

        # Add forwarded headers (but skip Authorization and host-related ones)
        # We MUST not forward the original Authorization header (contains Okta JWT)
        skip_headers = {"authorization", "host", "connection", "x-forwarded-for", "x-forwarded-proto", "x-amz"}
        for key, value in headers.items():
            if key.lower() not in skip_headers:
                request_headers[key] = value

        print(f"[Lambda] Headers after filtering: {list(request_headers.keys())}")

        # Forward to LiteLLM
        req = urllib.request.Request(
            url,
            data=body.encode() if body else None,
            headers=request_headers,
            method=method,
        )

        # Skip SSL certificate verification for self-signed certs (ALB uses self-signed)
        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE

        try:
            with urllib.request.urlopen(req, context=ssl_context) as response:
                response_body = response.read().decode()
                return {
                    "statusCode": response.status,
                    "headers": dict(response.headers),
                    "body": response_body,
                    "isBase64Encoded": False,
                }
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else ""
            return {
                "statusCode": e.code,
                "headers": dict(e.headers) if e.headers else {},
                "body": error_body,
                "isBase64Encoded": False,
            }

    except Exception as e:
        print(f"❌ Error in Lambda handler: {e}")
        import traceback
        traceback.print_exc()
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)}),
            "isBase64Encoded": False,
        }
