#!/bin/bash
set -e

eval "$(jq -r '@sh "PARAM_NAME=\(.param_name) FALLBACK_AMI=\(.fallback_ami)"')"

AMI_ID=$(aws ssm get-parameter --name "$PARAM_NAME" --query 'Parameter.Value' --output text 2>/dev/null || echo "$FALLBACK_AMI")

jq -n --arg ami_id "$AMI_ID" '{"ami_id":$ami_id}'
