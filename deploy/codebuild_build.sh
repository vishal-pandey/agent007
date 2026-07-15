#!/usr/bin/env bash
#
# codebuild_build.sh — package the repo, hand it to AWS CodeBuild to build a
# native arm64 image and push it to ECR, and block until the build finishes.
#
# This runs on the Jenkins node (cluster9). It does NO docker work locally —
# all building happens in CodeBuild — so it is safe on a shared/production box.
#
# Requires: aws CLI, git, zip. AWS auth via the Jenkins node's instance role.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-813923511679}"
ECR_REPO="${ECR_REPO:-bedrock-agentcore-agent007}"
CODEBUILD_PROJECT="${CODEBUILD_PROJECT:-bedrock-agentcore-agent007-builder}"
SOURCE_BUCKET="${SOURCE_BUCKET:-bedrock-agentcore-codebuild-sources-813923511679-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%Y%m%d%H%M%S)")}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
SRC_KEY="jenkins/agent007-${IMAGE_TAG}-$(date +%s).zip"

log()  { printf '\033[1;34m[codebuild]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[codebuild][error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || fail "aws CLI not found"
command -v git >/dev/null || fail "git not found"

# ----------------------------------------------------------------------------
# 1. Package the committed source (buildspec.yml + Dockerfile + agent007/ …)
# ----------------------------------------------------------------------------
ZIP="$(mktemp -u /tmp/agent007-src-XXXXXX.zip)"
log "Packaging source at ${IMAGE_TAG}…"
git -C "${REPO_ROOT}" archive --format=zip -o "${ZIP}" HEAD

# ----------------------------------------------------------------------------
# 2. Upload to the CodeBuild source bucket
# ----------------------------------------------------------------------------
log "Uploading source to s3://${SOURCE_BUCKET}/${SRC_KEY}"
aws s3 cp "${ZIP}" "s3://${SOURCE_BUCKET}/${SRC_KEY}" --region "${AWS_REGION}" >/dev/null
rm -f "${ZIP}"

# ----------------------------------------------------------------------------
# 3. Start the build (override source + buildspec + env, non-destructively)
# ----------------------------------------------------------------------------
log "Starting CodeBuild project ${CODEBUILD_PROJECT}…"
BUILD_ID="$(aws codebuild start-build \
  --region "${AWS_REGION}" \
  --project-name "${CODEBUILD_PROJECT}" \
  --source-type-override S3 \
  --source-location-override "${SOURCE_BUCKET}/${SRC_KEY}" \
  --buildspec-override "$(cat "${REPO_ROOT}/buildspec.yml")" \
  --environment-variables-override \
      "name=AWS_ACCOUNT_ID,value=${AWS_ACCOUNT_ID},type=PLAINTEXT" \
      "name=ECR_REPO,value=${ECR_REPO},type=PLAINTEXT" \
      "name=IMAGE_TAG,value=${IMAGE_TAG},type=PLAINTEXT" \
  --query 'build.id' --output text)"
log "Build id: ${BUILD_ID}"

# ----------------------------------------------------------------------------
# 4. Poll until the build reaches a terminal state
# ----------------------------------------------------------------------------
log "Waiting for build to finish (streaming phase changes)…"
LAST_PHASE=""
while true; do
  read -r STATUS PHASE < <(aws codebuild batch-get-builds \
    --region "${AWS_REGION}" --ids "${BUILD_ID}" \
    --query 'builds[0].[buildStatus,currentPhase]' --output text)
  if [[ "${PHASE}" != "${LAST_PHASE}" ]]; then
    log "  phase=${PHASE} status=${STATUS}"
    LAST_PHASE="${PHASE}"
  fi
  case "${STATUS}" in
    SUCCEEDED) break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      LOG_URL="$(aws codebuild batch-get-builds --region "${AWS_REGION}" --ids "${BUILD_ID}" \
        --query 'builds[0].logs.deepLink' --output text)"
      fail "Build ${STATUS}. Logs: ${LOG_URL}" ;;
  esac
  sleep 10
done

log "✅ Build SUCCEEDED — pushed ${IMAGE_URI}"

# Emit the image URI for the deploy step.
echo "IMAGE_URI=${IMAGE_URI}" > "${REPO_ROOT}/build_output.env"
echo "IMAGE_TAG=${IMAGE_TAG}" >> "${REPO_ROOT}/build_output.env"
