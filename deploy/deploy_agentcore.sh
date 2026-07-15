#!/usr/bin/env bash
#
# deploy_agentcore.sh — build the agent007 container, push it to ECR, and
# create-or-update the Bedrock AgentCore Runtime, then wait until it is READY.
#
# It is idempotent: if the runtime already exists it is updated in place,
# otherwise it is created. Safe to run from Jenkins or locally (needs AWS creds
# with admin / bedrock-agentcore + ecr permissions in the current environment).
#
# All settings are overridable via environment variables so the Jenkinsfile can
# inject them; the defaults below come from .bedrock_agentcore.yaml.
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via env)
# ----------------------------------------------------------------------------
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-813923511679}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-bedrock-agentcore-agent007}"
AGENT_RUNTIME_NAME="${AGENT_RUNTIME_NAME:-agent007}"
EXECUTION_ROLE_ARN="${EXECUTION_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonBedrockAgentCoreSDKRuntime-us-east-1-084228a16d}"
PLATFORM="${PLATFORM:-linux/arm64}"            # AgentCore Runtime requires arm64
SERVER_PROTOCOL="${SERVER_PROTOCOL:-A2A}"      # A2A | HTTP
NETWORK_MODE="${NETWORK_MODE:-PUBLIC}"
# Immutable image tag — defaults to short git SHA, else a timestamped fallback.
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%Y%m%d%H%M%S)")}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
IMAGE_URI_LATEST="${ECR_REGISTRY}/${ECR_REPO}:latest"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[deploy][error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws    >/dev/null || fail "aws CLI not found"
command -v docker >/dev/null || fail "docker not found"

log "Account=${AWS_ACCOUNT_ID} Region=${AWS_REGION} Repo=${ECR_REPO} Tag=${IMAGE_TAG}"
aws sts get-caller-identity --query Arn --output text \
  || fail "No usable AWS credentials in this environment"

# ----------------------------------------------------------------------------
# 1. Ensure the ECR repository exists
# ----------------------------------------------------------------------------
log "Ensuring ECR repository '${ECR_REPO}' exists…"
aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository \
       --repository-name "${ECR_REPO}" \
       --image-scanning-configuration scanOnPush=true \
       --region "${AWS_REGION}" >/dev/null

# ----------------------------------------------------------------------------
# 2. Log in to ECR
# ----------------------------------------------------------------------------
log "Logging in to ECR ${ECR_REGISTRY}…"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ----------------------------------------------------------------------------
# 3. Build (arm64) and push
#    A buildx builder is required for cross-arch builds on an amd64 Jenkins node.
# ----------------------------------------------------------------------------
log "Building ${PLATFORM} image and pushing ${IMAGE_URI}…"
docker buildx inspect agentcore-builder >/dev/null 2>&1 \
  || docker buildx create --name agentcore-builder --use --bootstrap >/dev/null
docker buildx use agentcore-builder

docker buildx build \
  --platform "${PLATFORM}" \
  --tag "${IMAGE_URI}" \
  --tag "${IMAGE_URI_LATEST}" \
  --push \
  "${REPO_ROOT}"

log "Pushed ${IMAGE_URI}"

# ----------------------------------------------------------------------------
# 4. Create-or-update the AgentCore Runtime
# ----------------------------------------------------------------------------
ARTIFACT_JSON="$(printf '{"containerConfiguration":{"containerUri":"%s"}}' "${IMAGE_URI}")"
NETWORK_JSON="$(printf '{"networkMode":"%s"}' "${NETWORK_MODE}")"
PROTOCOL_JSON="$(printf '{"serverProtocol":"%s"}' "${SERVER_PROTOCOL}")"

log "Looking up existing runtime named '${AGENT_RUNTIME_NAME}'…"
RUNTIME_ID="$(aws bedrock-agentcore-control list-agent-runtimes \
  --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_RUNTIME_NAME}'].agentRuntimeId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [[ -n "${RUNTIME_ID}" && "${RUNTIME_ID}" != "None" ]]; then
  log "Updating existing runtime ${RUNTIME_ID}…"
  aws bedrock-agentcore-control update-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-id "${RUNTIME_ID}" \
    --agent-runtime-artifact "${ARTIFACT_JSON}" \
    --role-arn "${EXECUTION_ROLE_ARN}" \
    --network-configuration "${NETWORK_JSON}" \
    --protocol-configuration "${PROTOCOL_JSON}" >/dev/null
else
  log "No existing runtime — creating '${AGENT_RUNTIME_NAME}'…"
  RUNTIME_ID="$(aws bedrock-agentcore-control create-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-name "${AGENT_RUNTIME_NAME}" \
    --agent-runtime-artifact "${ARTIFACT_JSON}" \
    --role-arn "${EXECUTION_ROLE_ARN}" \
    --network-configuration "${NETWORK_JSON}" \
    --protocol-configuration "${PROTOCOL_JSON}" \
    --query 'agentRuntimeId' --output text)"
fi

# ----------------------------------------------------------------------------
# 5. Wait for the runtime to reach a terminal state
# ----------------------------------------------------------------------------
log "Waiting for runtime ${RUNTIME_ID} to become READY…"
DEADLINE=$(( $(date +%s) + 600 ))   # 10 minute timeout
while true; do
  STATUS="$(aws bedrock-agentcore-control get-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-id "${RUNTIME_ID}" \
    --query 'status' --output text)"
  case "${STATUS}" in
    READY)
      break ;;
    CREATE_FAILED|UPDATE_FAILED|DELETE_FAILED)
      fail "Runtime entered failed state: ${STATUS}" ;;
  esac
  if (( $(date +%s) > DEADLINE )); then
    fail "Timed out waiting for READY (last status: ${STATUS})"
  fi
  log "  status=${STATUS} … retrying in 10s"
  sleep 10
done

RUNTIME_ARN="$(aws bedrock-agentcore-control get-agent-runtime \
  --region "${AWS_REGION}" --agent-runtime-id "${RUNTIME_ID}" \
  --query 'agentRuntimeArn' --output text)"

log "✅ Deployed. Runtime is READY."
log "   id  = ${RUNTIME_ID}"
log "   arn = ${RUNTIME_ARN}"
log "   img = ${IMAGE_URI}"

# Emit machine-readable outputs for the Jenkinsfile to archive.
{
  echo "AGENT_RUNTIME_ID=${RUNTIME_ID}"
  echo "AGENT_RUNTIME_ARN=${RUNTIME_ARN}"
  echo "IMAGE_URI=${IMAGE_URI}"
} > "${REPO_ROOT}/deploy_output.env"
