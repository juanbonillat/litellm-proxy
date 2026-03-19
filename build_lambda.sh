#!/bin/bash
# Build the Lambda deployment package

set -e

echo "📦 Building Lambda deployment package..."

# Create temp directory
mkdir -p lambda_build
cd lambda_build

# Install dependencies
pip install -q boto3 httpx -t .

# Copy Lambda function
cp ../index.py .

# Create ZIP file
zip -q -r ../lambda_function.zip .

# Clean up
cd ..
rm -rf lambda_build

echo "✅ lambda_function.zip created successfully"
echo ""
echo "Next steps:"
echo "1. terraform init"
echo "2. terraform plan"
echo "3. terraform apply"
