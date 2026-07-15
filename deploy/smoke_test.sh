#!/usr/bin/env bash
#
# smoke_test.sh — invoke the deployed AgentCore Runtime once (A2A / JSON-RPC)
# and verify it is serving: HTTP 200 + a well-formed A2A `result`.
#
# The agent007 runtime speaks the A2A protocol, so we send a proper
# `message/send` request (not a bare {"prompt": ...}).
#
# Reads AGENT_RUNTIME_ARN from deploy_output.env (written by update_runtime.sh)
# or from the environment. Optional SMOKE_MODEL overrides the model; when empty
# the agent uses its own default model.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
SMOKE_MODEL="${SMOKE_MODEL:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${AGENT_RUNTIME_ARN:-}" && -f "${REPO_ROOT}/deploy_output.env" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/deploy_output.env"
fi
[[ -n "${AGENT_RUNTIME_ARN:-}" ]] || { echo "[smoke] AGENT_RUNTIME_ARN not set" >&2; exit 1; }

# AgentCore requires a session id of at least 33 characters.
SESSION="agent007-smoke-$(date +%s)-$$-padpadpadpadpadpad"

if [[ -n "${SMOKE_MODEL}" ]]; then
  MODEL_FIELD="\"model\": \"${SMOKE_MODEL}\","
  echo "[smoke] using model: ${SMOKE_MODEL}"
else
  MODEL_FIELD=""
  echo "[smoke] using the agent's default model"
fi

PAYLOAD="$(mktemp)"; OUT="$(mktemp)"
cat > "${PAYLOAD}" <<JSON
{
  "jsonrpc": "2.0",
  "id": "smoke-1",
  "method": "message/send",
  "params": {
    "id": "smoke-task-1",
    "metadata": { ${MODEL_FIELD} "instruction": "You are a health check. Reply with exactly: pong" },
    "message": {
      "role": "user",
      "messageId": "smoke-msg-1",
      "parts": [ { "kind": "text", "text": "Reply with the single word: pong" } ]
    }
  }
}
JSON

echo "[smoke] Invoking ${AGENT_RUNTIME_ARN}"
HTTP_CODE="$(aws bedrock-agentcore invoke-agent-runtime \
  --region "${AWS_REGION}" \
  --agent-runtime-arn "${AGENT_RUNTIME_ARN}" \
  --runtime-session-id "${SESSION}" \
  --content-type "application/json" \
  --payload "fileb://${PAYLOAD}" \
  --query 'statusCode' --output text "${OUT}" 2>/dev/null || echo "ERR")"

echo "[smoke] statusCode=${HTTP_CODE}"

# Parse the A2A response: confirm it is well-formed and report the task state.
STATE="$(python3 -c "import json,sys; d=json.load(open('${OUT}')); print(d.get('result',{}).get('status',{}).get('state','NO_RESULT'))" 2>/dev/null || echo PARSE_ERR)"
TEXT="$(python3 -c "import json,sys; d=json.load(open('${OUT}')); p=d.get('result',{}).get('status',{}).get('message',{}).get('parts',[{}]); print((p[0] if p else {}).get('text',''))" 2>/dev/null | head -c 300)"

echo "[smoke] task state = ${STATE}"
echo "[smoke] agent said  = ${TEXT}"

rm -f "${PAYLOAD}" "${OUT}"

# Liveness gate: the runtime must return 200 with a parseable A2A result.
# (A model/config error still proves the runtime is serving; we surface it but
#  do not fail the deploy on it unless SMOKE_STRICT=true.)
if [[ "${HTTP_CODE}" != "200" || "${STATE}" == "NO_RESULT" || "${STATE}" == "PARSE_ERR" ]]; then
  echo "[smoke] ❌ Runtime did not serve a valid A2A response." >&2
  exit 1
fi

if [[ "${STATE}" == "failed" ]]; then
  if [[ "${SMOKE_STRICT:-false}" == "true" ]]; then
    echo "[smoke] ❌ Task failed (SMOKE_STRICT=true): ${TEXT}" >&2
    exit 1
  fi
  echo "[smoke] ⚠️  Runtime is serving, but the task failed (likely model/config, not deploy): ${TEXT}"
  echo "[smoke] ✅ Liveness OK (HTTP 200 + valid A2A response)."
  exit 0
fi

echo "[smoke] ✅ Runtime healthy (state=${STATE})."
