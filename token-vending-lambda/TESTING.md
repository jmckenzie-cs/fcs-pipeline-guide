# Token Vending Lambda — Test Deployment Guide

Step-by-step instructions for deploying and validating the token vending Lambda in AWS using a dedicated test IAM user.

---

## Prerequisites

- AWS CLI installed and configured with an identity that has IAM and Lambda admin permissions
- `jq` installed
- CrowdStrike API client credentials (client ID and secret) — see the [API client scopes required](README.md#1-store-credentials-in-secrets-manager)
- This repo checked out locally

All commands below assume you are running from the **root of the repo** (`fcs-pipeline-guide/`). Run this first:

```shell
cd path/to/fcs-pipeline-guide
```

If running from **AWS CloudShell**, clone the repo first:

```shell
git clone https://github.com/jmckenzie-cs/fcs-cli-enterprise-setup.git
cd fcs-cli-enterprise-setup
```

CloudShell has the AWS CLI, Python, and `jq` pre-installed — no additional setup needed.

---

## Step 1 — Get your AWS account ID

Capture it into a variable so you can use it directly in later commands without manual substitution:

```shell
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo $ACCOUNT_ID
```

---

## Step 2 — Create the Lambda execution role

This role is assumed by the Lambda function itself to read from Secrets Manager.

**Create the trust policy:**

```shell
cat > /tmp/lambda-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

**Create the role:**

```shell
aws iam create-role \
  --role-name crowdstrike-fcs-token-vend-role \
  --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
  --region us-east-1
```

**Attach the execution policy from the repo:**

```shell
sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" \
  token-vending-lambda/iam/execution-role-policy.json > /tmp/execution-role-policy.json

aws iam put-role-policy \
  --role-name crowdstrike-fcs-token-vend-role \
  --policy-name fcs-token-vend-execution \
  --policy-document file:///tmp/execution-role-policy.json
```

---

## Step 3 — Create the test IAM user

This user represents a developer or pipeline that can invoke the Lambda but has no access to Secrets Manager.

**Create the user:**

```shell
aws iam create-user --user-name fcs-token-vend-tester
```

**Attach the caller policy:**

```shell
sed "s/ACCOUNT_ID/$ACCOUNT_ID/g" \
  token-vending-lambda/iam/caller-role-policy.json > /tmp/caller-policy.json

aws iam put-user-policy \
  --user-name fcs-token-vend-tester \
  --policy-name fcs-token-vend-caller \
  --policy-document file:///tmp/caller-policy.json
```

**Create access keys:**

```shell
aws iam create-access-key --user-name fcs-token-vend-tester
```

Save the `AccessKeyId` and `SecretAccessKey` — the secret is only shown once.

**Configure a named AWS CLI profile for the test user:**

```shell
aws configure --profile fcs-tester
# Enter: AccessKeyId, SecretAccessKey, us-east-1, json
```

---

## Step 4 — Store the secret in Secrets Manager

Replace the placeholder values with your actual CrowdStrike credentials:

```shell
aws secretsmanager create-secret \
  --name crowdstrike/fcs-cli \
  --region us-east-1 \
  --secret-string '{"client_id":"<YOUR_CLIENT_ID>","client_secret":"<YOUR_CLIENT_SECRET>"}'
```

Confirm it stored correctly:

```shell
aws secretsmanager get-secret-value \
  --secret-id crowdstrike/fcs-cli \
  --region us-east-1 \
  --query SecretString \
  --output text
# Expected: {"client_id":"...","client_secret":"..."}
```

---

## Step 5 — Package the Lambda

Run from the root of the repo:

```shell
cd token-vending-lambda/lambda
zip handler.zip handler.py
```

---

## Step 6 — Deploy the Lambda

```shell
aws lambda create-function \
  --function-name crowdstrike-fcs-token-vend \
  --runtime python3.12 \
  --handler handler.handler \
  --role arn:aws:iam::${ACCOUNT_ID}:role/crowdstrike-fcs-token-vend-role \
  --zip-file fileb://handler.zip \
  --environment "Variables={SECRET_ID=crowdstrike/fcs-cli,FALCON_API_URL=https://api.crowdstrike.com}" \
  --region us-east-1
```

Confirm it's active:

```shell
aws lambda get-function \
  --function-name crowdstrike-fcs-token-vend \
  --region us-east-1 \
  --query 'Configuration.State' \
  --output text
# Expected: Active
```

---

## Step 7 — Test

**Invoke as your admin identity** to confirm the Lambda works end-to-end:

```shell
aws lambda invoke \
  --function-name crowdstrike-fcs-token-vend \
  --region us-east-1 \
  --payload '{}' \
  --output text \
  --query Payload \
  /dev/stdout
# Expected: {"statusCode": 200, "body": "{\"token\": \"eyJ...\", \"expires_in\": 1799}"}
```

**Invoke as the test user** to confirm the caller policy works correctly:

```shell
aws --profile fcs-tester lambda invoke \
  --function-name crowdstrike-fcs-token-vend \
  --region us-east-1 \
  --payload '{}' \
  --output text \
  --query Payload \
  /dev/stdout
# Expected: same token response
```

**Confirm the test user cannot access the secret directly:**

```shell
aws --profile fcs-tester secretsmanager get-secret-value \
  --secret-id crowdstrike/fcs-cli \
  --region us-east-1
# Expected: AccessDeniedException
```

All three checks passing confirms the access boundary is working — the test user can get a token but cannot touch the underlying secret.

---

## Step 8 — Run a scan with the token

Use `fcs-scan-local.sh` with the test user profile to do an end-to-end scan:

```shell
AWS_PROFILE=fcs-tester ./token-vending-lambda/scripts/fcs-scan-local.sh <image>:<tag>
```
