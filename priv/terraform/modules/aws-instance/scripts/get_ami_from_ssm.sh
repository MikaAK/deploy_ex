#!/bin/bash
set -e

# Read JSON input from Terraform external data source
INPUT=$(cat)

# Parse JSON input without jq using grep and sed
PARAM_NAME=$(echo "$INPUT" | grep -o '"param_name":"[^"]*"' | sed 's/"param_name":"\([^"]*\)"/\1/')
FALLBACK_AMI=$(echo "$INPUT" | grep -o '"fallback_ami":"[^"]*"' | sed 's/"fallback_ami":"\([^"]*\)"/\1/')

# Get AMI from SSM or use fallback
AMI_ID=$(aws ssm get-parameter --name "$PARAM_NAME" --query 'Parameter.Value' --output text 2>/dev/null || echo "$FALLBACK_AMI")

# Output JSON without jq
printf '{"ami_id":"%s"}\n' "$AMI_ID"
