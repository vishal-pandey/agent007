#!/usr/bin/env bash
#
# update_runtime.sh — point the Bedrock AgentCore Runtime at a (already-pushed)
# ECR image and wait until it is READY. Create-or-update by runtime name.
#
# Input: IMAGE_URI (from build_output.env produced by codebuild_build.sh, or env).
# Requires: aws CLI + credentials with bedrock-agentcore + iam:PassRole.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-813923511679}"
AGENT_RUNTIME_NAME="${AGENT_RUNTIME_NAME:-agent007}"
EXECUTION_ROLE_ARN="${EXECUTION_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonBedrockAgentCoreSDKRuntime-us-east-1-084228a16d}"
SERVER_PROTOCOL="${SERVER_PROTOCOL:-A2A}"
NETWORK_MODE="${NETWORK_MODE:-PUBLIC}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load IMAGE_URI from the build step unless already provided.
if [[ -z "${IMAGE_URI:-}" && -f "${REPO_ROOT}/build_output.env" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/build_output.env"
fi

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[deploy][error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${IMAGE_URI:-}" ]] || fail "IMAGE_URI not set (run codebuild_build.sh first)"
command -v aws >/dev/null || fail "aws CLI not found"

ARTIFACT_JSON="$(printf '{"containerConfiguration":{"containerUri":"%s"}}' "${IMAGE_URI}")"
NETWORK_JSON="$(printf '{"networkMode":"%s"}' "${NETWORK_MODE}")"
PROTOCOL_JSON="$(printf '{"serverProtocol":"%s"}' "${SERVER_PROTOCOL}")"

log "Looking up runtime named '${AGENT_RUNTIME_NAME}'…"
RUNTIME_ID="$(aws bedrock-agentcore-control list-agent-runtimes \
  --region "${AWS_REGION}" \
  --query "agentRuntimes[?agentRuntimeName=='${AGENT_RUNTIME_NAME}'].agentRuntimeId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [[ -n "${RUNTIME_ID}" && "${RUNTIME_ID}" != "None" ]]; then
  log "Updating runtime ${RUNTIME_ID} -> ${IMAGE_URI}"
  aws bedrock-agentcore-control update-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-id "${RUNTIME_ID}" \
    --agent-runtime-artifact "${ARTIFACT_JSON}" \
    --role-arn "${EXECUTION_ROLE_ARN}" \
    --network-configuration "${NETWORK_JSON}" \
    --protocol-configuration "${PROTOCOL_JSON}" >/dev/null
else
  log "Creating runtime '${AGENT_RUNTIME_NAME}' -> ${IMAGE_URI}"
  RUNTIME_ID="$(aws bedrock-agentcore-control create-agent-runtime \
    --region "${AWS_REGION}" \
    --agent-runtime-name "${AGENT_RUNTIME_NAME}" \
    --agent-runtime-artifact "${ARTIFACT_JSON}" \
    --role-arn "${EXECUTION_ROLE_ARN}" \
    --network-configuration "${NETWORK_JSON}" \
    --protocol-configuration "${PROTOCOL_JSON}" \
    --query 'agentRuntimeId' --output text)"
fi

log "Waiting for runtime ${RUNTIME_ID} to become READY…"
DEADLINE=$(( $(date +%s) + 600 ))
while true; do
  STATUS="$(aws bedrock-agentcore-control get-agent-runtime \
    --region "${AWS_REGION}" --agent-runtime-id "${RUNTIME_ID}" \
    --query 'status' --output text)"
  case "${STATUS}" in
    READY) break ;;
    CREATE_FAILED|UPDATE_FAILED|DELETE_FAILED) fail "Runtime entered failed state: ${STATUS}" ;;
  esac
  (( $(date +%s) > DEADLINE )) && fail "Timed out waiting for READY (last: ${STATUS})"
  log "  status=${STATUS} … retry in 10s"
  sleep 10
done

RUNTIME_ARN="$(aws bedrock-agentcore-control get-agent-runtime \
  --region "${AWS_REGION}" --agent-runtime-id "${RUNTIME_ID}" \
  --query 'agentRuntimeArn' --output text)"

log "✅ Runtime READY"
log "   id  = ${RUNTIME_ID}"
log "   arn = ${RUNTIME_ARN}"
log "   img = ${IMAGE_URI}"

{
  echo "AGENT_RUNTIME_ID=${RUNTIME_ID}"
  echo "AGENT_RUNTIME_ARN=${RUNTIME_ARN}"
  echo "IMAGE_URI=${IMAGE_URI}"
} > "${REPO_ROOT}/deploy_output.env"
