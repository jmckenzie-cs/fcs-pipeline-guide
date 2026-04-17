# FCS CLI at Scale — 100+ Developer Teams

## Overview

The core problem at scale: you don't want 100 devs each managing their own API keys, and you don't want to create 100 separate API clients. The solution is **centralized credentials distributed via your secrets manager or CI/CD platform**, not per-developer keys.

---

## 1. API Client Strategy

Create **ONE shared API client** (or a small number by team/environment), not one per developer.

Required scopes for image assessment:

| Scope | Permission |
|---|---|
| Cloud Security Tools Download | Read |
| Falcon Container CLI | Read / Write |
| Falcon Container Image | Read / Write |

In the Falcon console: **Support and resources > Resources and tools > API clients and keys > Add new API client**

> **Do not give individual developers the client secret directly.** Store it centrally.

---

## 2. Credential Distribution Patterns

### Option A — CI/CD Platform Secrets (recommended for most teams)

Store credentials as org-level or repo-level secrets in your CI/CD platform. Developers never see the secret — the pipeline injects it at runtime.

```yaml
# GitHub Actions example
env:
  FALCON_CLIENT_ID: ${{ secrets.FALCON_CLIENT_ID }}
  FALCON_CLIENT_SECRET: ${{ secrets.FALCON_CLIENT_SECRET }}
  FALCON_REGION: us-1
```

### Option B — Secrets Manager (AWS, Vault, Azure Key Vault, etc.)

Store the client ID/secret centrally and have your pipeline retrieve it at build time:

```shell
# Example: fetch from AWS Secrets Manager in pipeline
export FALCON_CLIENT_ID=$(aws secretsmanager get-secret-value \
  --secret-id crowdstrike/fcs-cli \
  --query SecretString --output text | jq -r '.client_id')

export FALCON_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id crowdstrike/fcs-cli \
  --query SecretString --output text | jq -r '.client_secret')
```

### Option C — Token Vending Machine (recommended when secret exposure must be zero)

For teams with strict requirements around secret access — where even pipeline-injected secrets are unacceptable — a Token Vending Machine (TVM) Lambda puts an API in front of CrowdStrike OAuth2. Callers receive only a short-lived bearer token; the client secret never leaves the Lambda execution environment.

```
Developer / Pipeline
      |
      | IAM (SSO session or OIDC-assumed role)
      v
Lambda: crowdstrike-fcs-token-vend
      |
      | Lambda execution role only
      v
Secrets Manager: crowdstrike/fcs-cli
      |
      v
CrowdStrike OAuth2  →  short-lived token returned to caller
```

Callers invoke the Lambda with their AWS identity and receive a token they pass to `fcs` via `--falcon-token`:

```shell
# Local developer
TOKEN=$(aws lambda invoke \
  --function-name crowdstrike-fcs-token-vend \
  --payload '{}' --output text --query Payload \
  /dev/stdout | jq -r '.body | fromjson | .token')

fcs scan image myapp:latest --falcon-token "$TOKEN" --falcon-region us-1
```

```yaml
# GitHub Actions — OIDC assumes role, no secrets stored in GitHub
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ vars.FCS_SCAN_ROLE_ARN }}
    aws-region: us-east-1

- id: fcs-token
  run: |
    TOKEN=$(aws lambda invoke --function-name crowdstrike-fcs-token-vend \
      --payload '{}' --output text --query Payload \
      /dev/stdout | jq -r '.body | fromjson | .token')
    echo "::add-mask::$TOKEN"
    echo "token=$TOKEN" >> "$GITHUB_OUTPUT"

- run: |
    fcs scan image myapp:${{ github.sha }} \
      --falcon-token ${{ steps.fcs-token.outputs.token }} \
      --falcon-region us-1 --upload
```

Access control and audit are handled entirely by IAM — each team gets a role with `lambda:InvokeFunction` on the vending function, and every invocation is logged in CloudTrail.

See [`token-vending-lambda/`](token-vending-lambda/README.md) for the full Lambda source, IAM policies, and deployment instructions.

---

### Option D — Environment Variables

The FCS CLI accepts credentials via env vars — no config file needed per developer:

```shell
export FCS_CLIENT_ID="<YOUR_CLIENT_ID>"
export FCS_CLIENT_SECRET="<YOUR_CLIENT_SECRET>"
export FALCON_API_URL="https://api.crowdstrike.com"  # adjust for your region
```

This avoids per-developer configuration files (`~/.crowdstrike/fcs.json`).

---

## 3. Programmatic FCS CLI Download in Pipelines

Don't require devs to manually download the binary. Auto-fetch the latest version at pipeline start.

**Step 1 — Get an OAuth token:**

```shell
FALCON_ACCESS_TOKEN=$(curl --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=${FALCON_CLIENT_ID}" \
  --data-urlencode "client_secret=${FALCON_CLIENT_SECRET}" \
  --url "${FALCON_API_URL}/oauth2/token" | jq -r '.access_token')
```

**Step 2 — Enumerate versions and download:**

```shell
FCS_TARGET_OS=linux
FCS_TARGET_ARCH=amd64

FCS_DOWNLOAD_URL=$(curl --get \
  --header "accept: application/json" \
  --header "Authorization: Bearer ${FALCON_ACCESS_TOKEN}" \
  --url "${FALCON_API_URL}/csdownloads/combined/files-download/v2" \
  --data-urlencode "filter=category:\"fcs\"+os:\"${FCS_TARGET_OS}\"+arch:\"${FCS_TARGET_ARCH}\"" \
  | jq -r '.resources[0].download_info.download_url')

curl --location --output fcs.tar.gz "$FCS_DOWNLOAD_URL"
tar -xvzf fcs.tar.gz && chmod u+x fcs
```

> Tokens are short-lived — generate fresh per pipeline run. Do not cache or distribute them.

### Supported Platforms

| Operating System | Architecture | Platform Name | File Name |
|---|---|---|---|
| macOS | Apple Silicon | darwin-arm64 | fcs_2.2.0_Darwin_arm64.tar.gz |
| macOS | Intel-based | darwin-amd64 | fcs_2.2.0_Darwin_x86_64.tar.gz |
| Linux | aarch64 | linux-arm64 | fcs_2.2.0_Linux_arm64.tar.gz |
| Linux | x86_64 | linux-amd64 | fcs_2.2.0_Linux_x86_64.tar.gz |
| Windows | aarch64 | windows-arm64 | fcs_2.2.0_Windows_arm64.zip |
| Windows | x86_64 | windows-amd64 | fcs_2.2.0_Windows_x86_64.zip |

---

## 4. Container-Based Approach (Best for Scale)

For maximum consistency across 100 teams, run FCS CLI **as a container** rather than a binary. No install or update management per developer.

```shell
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  registry.crowdstrike.com/fcs/us-1/release/cs-fcs:2.2.0 scan image myapp:latest \
  --client-id $FALCON_CLIENT_ID \
  --client-secret $FALCON_CLIENT_SECRET \
  --falcon-region us-1
```

Credentials come from env vars — no per-developer config files needed. You control the version tag centrally.

### Scan for upload only (faster, no local output)

```shell
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  registry.crowdstrike.com/fcs/us-1/release/cs-fcs:2.2.0 scan image myapp:latest \
  --scan-only \
  --upload \
  --client-id $FALCON_CLIENT_ID \
  --client-secret $FALCON_CLIENT_SECRET \
  --falcon-region us-1
```

### CrowdStrike Registry URLs by Region

| CrowdStrike Cloud | Registry URL | Region Code |
|---|---|---|
| US-1 | registry.crowdstrike.com | us-1 |
| US-2 | registry.crowdstrike.com | us-2 |
| EU-1 | registry.crowdstrike.com | eu-1 |
| US-GOV-1 | registry.laggar.gcw.crowdstrike.com | gov-1 |
| US-GOV-2 | registry.us-gov-2.crowdstrike.mil | gov-2 |

---

## 5. Multi-Team Configuration Profiles

If you need different API keys per environment (dev vs prod) or per business unit, use FCS CLI profiles:

```shell
# Create named profiles
fcs configure --profile team-a
fcs configure --profile team-b

# Use a specific profile at scan time
fcs scan image myapp:latest --profile team-a
```

This lets you map teams to separate API clients with appropriate scopes, without managing individual keys.

---

## 6. Pipeline Integration — Exit Code Handling

Build go/no-go gates using FCS CLI exit codes:

| Exit Code | Meaning | Recommended Action |
|---|---|---|
| `0` | Passed policy | Allow deployment |
| `1` | Failed policy — block | Fail the build |
| `2` | Failed policy — alert | Send notification, optionally fail |
| `201` | Invalid input | Check scan command syntax |
| `202` | Authentication error | Check client ID, secret, and region |
| `203` | Scan processing error | Investigate scan logs |
| `204` | Error downloading report | Check connectivity |
| `205` | Error preparing report | Check scan output |
| `206` | Error generating SBOM | Check image format |
| `207` | Scan errors detected | Review report file |

```shell
fcs scan image myapp:latest
EXIT_CODE=$?

if [ $EXIT_CODE -eq 1 ]; then
  echo "Image blocked by policy — failing build"
  exit 1
elif [ $EXIT_CODE -eq 2 ]; then
  echo "Image flagged — alert sent to Falcon console"
  # optionally fail or warn
fi
```

---

## 7. API Base URLs by Region

| Cloud | API Base URL |
|---|---|
| US-1 | https://api.crowdstrike.com |
| US-2 | https://api.us-2.crowdstrike.com |
| EU-1 | https://api.eu-1.crowdstrike.com |
| US-GOV-1 | https://api.laggar.gcw.crowdstrike.com |
| US-GOV-2 | https://api.us-gov-2.crowdstrike.mil |

**Upload servers (firewall allowlist):**

| Region | Upload Server |
|---|---|
| US-1 | https://container-upload.us-1.crowdstrike.com |
| US-2 | https://container-upload.us-2.crowdstrike.com |
| EU-1 | https://container-upload.eu-1.crowdstrike.com |
| US-GOV-1 | https://container-upload.laggar.gcw.crowdstrike.com |
| US-GOV-2 | https://container-upload.us-gov-2.crowdstrike.mil |

---

## Recommended Architecture at Scale

```
Secrets Manager / Token Vending Lambda
         |
         v
  1 Shared API Client (scoped to image assessment)
         |
         v
  Short-lived bearer token distributed per-run via IAM
         |
         v
  Shared Pipeline Template (used across all teams)
  ├── Auto-downloads FCS CLI binary or pulls container image
  ├── Fetches token from vending Lambda (no secret exposure)
  ├── Runs fcs scan image <IMAGE> --falcon-token <TOKEN>
  ├── Checks exit code for go/no-go gate
  └── Uploads results to Falcon console (--upload flag)
         |
         v
  Falcon Console — centralized view of all scan results
```

Developers never handle credentials directly. They trigger the pipeline; security runs automatically.

---

## GitHub Action (Official)

CrowdStrike provides an official GitHub Action in the GitHub Marketplace:
`CrowdStrike/fcs-action`

Use this as a reference implementation for other CI/CD platforms (GitLab, Jenkins, Bitbucket Pipelines, Azure DevOps, etc.).
