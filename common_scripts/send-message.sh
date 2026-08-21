#!/usr/bin/env bash

set -euo pipefail

# Load environment variables.
ENV_FILE="${ENV_FILE:-.env}"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Validate required environment variables.
: "${LETTA_URL:?LETTA_URL is not set}"
: "${LETTA_SERVER_PASSWORD:?LETTA_SERVER_PASSWORD is not set}"

MESSAGE="${1:-Can you tell me about movements for tag with Tag031 covering the last three days in current data-set?}"

# Auto-detect the first agent.
AGENT_ID="$(
  curl -sS --fail-with-body \
    -H "Authorization: Bearer ${LETTA_SERVER_PASSWORD}" \
    "${LETTA_URL}/v1/agents/?limit=1" |
    jq -r '.[0].id // empty'
)"
[[ -n "$AGENT_ID" ]] || { echo "No agents found on ${LETTA_URL}" >&2; exit 1; }

echo "Sending message to agent ${AGENT_ID}..."

# Send the message.
curl -sS --fail-with-body \
  -X POST \
  -H "Authorization: Bearer ${LETTA_SERVER_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${LETTA_URL}/v1/agents/${AGENT_ID}/messages" \
  -d "$(jq -n --arg content "$MESSAGE" '{messages: [{role: "user", content: $content}]}')" |
  jq .
