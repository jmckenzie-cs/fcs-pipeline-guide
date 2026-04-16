#!/usr/bin/env bash
set -euo pipefail

export FALCON_CLIENT_ID=$(aws secretsmanager get-secret-value \
  --secret-id crowdstrike/fcs-cli \
  --query SecretString --output text | jq -r '.client_id')

export FALCON_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id crowdstrike/fcs-cli \
  --query SecretString --output text | jq -r '.client_secret')
