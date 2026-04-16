# FCS CLI — Secrets Manager Distribution and Programmatic Download

## 1. Centralizing API Client Credentials with a Secrets Manager

Create **one shared API client** in the Falcon console and store its credentials in your secrets manager — not in individual developer environments or config files.

Required scopes:

| Scope | Permission |
|---|---|
| Cloud Security Tools Download | Read |
| Falcon Container CLI | Read / Write |
| Falcon Container Image | Read / Write |

In the Falcon console: **Support and resources > Resources and tools > API clients and keys > Add new API client**

> **Do not give individual developers the client secret directly.** Store it centrally and inject it at runtime.

### AWS Secrets Manager

```shell
export AWS_REGION="us-east-1"
export FALCON_API_URL="https://api.crowdstrike.com"  # see API Base URLs by Region below

export FALCON_CLIENT_ID=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id crowdstrike/fcs-cli \
  --query SecretString --output text | jq -r '.client_id')

export FALCON_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id crowdstrike/fcs-cli \
  --query SecretString --output text | jq -r '.client_secret')
```

### HashiCorp Vault

```shell
export FALCON_CLIENT_ID=$(vault kv get -field=client_id secret/crowdstrike/fcs-cli)
export FALCON_CLIENT_SECRET=$(vault kv get -field=client_secret secret/crowdstrike/fcs-cli)
```

### Azure Key Vault

```shell
export FALCON_CLIENT_ID=$(az keyvault secret show \
  --vault-name <YOUR_VAULT> --name fcs-client-id --query value -o tsv)

export FALCON_CLIENT_SECRET=$(az keyvault secret show \
  --vault-name <YOUR_VAULT> --name fcs-client-secret --query value -o tsv)
```

Once exported, the FCS CLI picks them up via environment variables — no per-developer config files needed.

---

## 2. Programmatic FCS CLI Download

Rather than requiring developers to manually install the binary, fetch it automatically as part of your pipeline or local setup script.

### Step 1 — Get an OAuth token

```shell
FALCON_ACCESS_TOKEN=$(curl --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${FALCON_CLIENT_ID}" \
  --data-urlencode "client_secret=${FALCON_CLIENT_SECRET}" \
  --url "${FALCON_API_URL}/oauth2/token" | jq -r '.access_token')
```

> Tokens are short-lived — generate a fresh one per run. Do not cache or distribute them.

### Step 2 — Enumerate available versions and download

```shell
FCS_TARGET_OS=linux    # darwin | linux | windows
FCS_TARGET_ARCH=amd64  # amd64 | arm64

FCS_DOWNLOAD_URL=$(curl --get \
  --header "accept: application/json" \
  --header "Authorization: Bearer ${FALCON_ACCESS_TOKEN}" \
  --url "${FALCON_API_URL}/csdownloads/combined/files-download/v2" \
  --data-urlencode "filter=category:\"fcs\"+os:\"${FCS_TARGET_OS}\"+arch:\"${FCS_TARGET_ARCH}\"" \
  | jq -r '.resources[0].download_info.download_url')

curl --location --output fcs.tar.gz "$FCS_DOWNLOAD_URL"
tar -xvzf fcs.tar.gz && chmod u+x fcs
```

### API Base URLs by Region

| Cloud | API Base URL |
|---|---|
| US-1 | https://api.crowdstrike.com |
| US-2 | https://api.us-2.crowdstrike.com |
| EU-1 | https://api.eu-1.crowdstrike.com |
| US-GOV-1 | https://api.laggar.gcw.crowdstrike.com |
| US-GOV-2 | https://api.us-gov-2.crowdstrike.mil |

### Supported Platforms

| Operating System | Architecture | Platform Name |
|---|---|---|
| macOS | Apple Silicon | darwin-arm64 |
| macOS | Intel-based | darwin-amd64 |
| Linux | aarch64 | linux-arm64 |
| Linux | x86_64 | linux-amd64 |
| Windows | aarch64 | windows-arm64 |
| Windows | x86_64 | windows-amd64 |
