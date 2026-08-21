#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-.env}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-10}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-120}"
AGENT_PAGE_SIZE="${AGENT_PAGE_SIZE:-200}"
MCP_TOOL_WAIT_SECONDS="${MCP_TOOL_WAIT_SECONDS:-120}"
MCP_TOOL_POLL_SECONDS="${MCP_TOOL_POLL_SECONDS:-5}"
LETTA_CLEANUP_SCOPE="${LETTA_CLEANUP_SCOPE:-matching}"
MCP_REMOTE_COMMAND="${MCP_REMOTE_COMMAND:-/usr/local/bin/letta-mcp-remote}"
MCP_REMOTE_TRANSPORT="${MCP_REMOTE_TRANSPORT:-http-only}"

WORK_DIR=""

log() {
  printf '%s\n' "$*"
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Required command '$1' was not found in PATH."
}

require_env() {
  local name="$1"
  local value="${!name-}"

  [[ -n "${value//[[:space:]]/}" ]] ||
    die "Required environment variable '$name' is not set or is empty."
}

require_positive_integer() {
  local name="$1"
  local value="${!name}"

  [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
    die "$name must be a positive integer."
}

letta_request() {
  local method="$1"
  local url="$2"
  local request_body="${3-}"
  local response_file
  local http_status

  response_file="$(mktemp "${WORK_DIR}/response.XXXXXX")"

  local curl_arguments=(
    --silent
    --show-error
    --connect-timeout "$CONNECT_TIMEOUT_SECONDS"
    --max-time "$REQUEST_TIMEOUT_SECONDS"
    --output "$response_file"
    --write-out '%{http_code}'
    --request "$method"
    --header "Authorization: Bearer ${LETTA_SERVER_PASSWORD}"
    --header 'Accept: application/json'
  )

  if [[ -n "$request_body" ]]; then
    curl_arguments+=(
      --header 'Content-Type: application/json'
      --data "$request_body"
    )
  fi

  if ! http_status="$(curl "${curl_arguments[@]}" "$url")"; then
    rm -f "$response_file"
    error "Could not complete ${method} request to ${url}."
    return 1
  fi

  if [[ ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    error "Letta API request failed."
    error "Method: ${method}"
    error "URL: ${url}"
    error "HTTP status: ${http_status}"

    if [[ -s "$response_file" ]]; then
      printf '%s\n' 'Response body:' >&2
      jq . "$response_file" >&2 2>/dev/null || cat "$response_file" >&2
    fi

    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

list_all_agents() {
  local after=""
  local page_number=1
  local page_json
  local page_count
  local last_agent_id
  local all_agents='[]'
  local url

  while true; do
    url="${LETTA_URL}/v1/agents/?limit=${AGENT_PAGE_SIZE}"

    if [[ -n "$after" ]]; then
      url+="&after=${after}"
    fi

    page_json="$(letta_request GET "$url")" || return 1

    printf '%s\n' "$page_json" |
      jq -e 'type == "array"' >/dev/null || {
        error "Unexpected response from the agents endpoint on page ${page_number}."
        return 1
      }

    page_count="$(printf '%s\n' "$page_json" | jq 'length')"

    if [[ "$page_count" -eq 0 ]]; then
      break
    fi

    all_agents="$({
      printf '%s\n' "$all_agents"
      printf '%s\n' "$page_json"
    } | jq -s '.[0] + .[1]')"

    if [[ "$page_count" -lt "$AGENT_PAGE_SIZE" ]]; then
      break
    fi

    last_agent_id="$(printf '%s\n' "$page_json" | jq -r '.[-1].id // empty')"
    [[ -n "$last_agent_id" ]] || {
      error "Cannot continue agent pagination because the last agent has no ID."
      return 1
    }

    [[ "$last_agent_id" != "$after" ]] || {
      error "Agent pagination did not advance beyond '$last_agent_id'."
      return 1
    }

    after="$last_agent_id"
    page_number=$((page_number + 1))
  done

  printf '%s\n' "$all_agents"
}

# ---------------------------------------------------------------------------
# Local checks and environment loading
# ---------------------------------------------------------------------------

require_command curl
require_command jq

[[ -f "$ENV_FILE" ]] || die "Environment file '$ENV_FILE' does not exist."
[[ -r "$ENV_FILE" ]] || die "Environment file '$ENV_FILE' is not readable."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_env OPEN_AI_API_KEY
require_env LETTA_URL
require_env LETTA_SERVER_PASSWORD
require_env LETTA_MODEL
require_env LETTA_EMBEDDING_HANDLE
require_env LETTA_CONTEXT_WINDOW_LIMIT
require_env LETTA_AGENT_NAME
require_env LETTA_AGENT_TIMEZONE
require_env MCP_SERVER_NAME
require_env BUSINESS_MCP_URL
require_env MCP_REMOTE_HOME
require_env MCP_DISABLE_STDIO

[[ "$LETTA_URL" =~ ^https?://[^[:space:]]+$ ]] ||
  die "LETTA_URL must be an absolute HTTP or HTTPS URL."

[[ "$BUSINESS_MCP_URL" =~ ^https?://[^[:space:]]+$ ]] ||
  die "BUSINESS_MCP_URL must be an absolute HTTP or HTTPS URL."

[[ "$LETTA_MODEL" == openai/* ]] ||
  die "LETTA_MODEL must be an OpenAI Letta handle such as openai/gpt-4o-mini."

[[ "$LETTA_EMBEDDING_HANDLE" == openai/* ]] ||
  die "LETTA_EMBEDDING_HANDLE must be an OpenAI Letta handle such as openai/text-embedding-3-small."

[[ "$MCP_REMOTE_HOME" == /* ]] ||
  die "MCP_REMOTE_HOME must be an absolute container path."

[[ "$MCP_REMOTE_COMMAND" == /* ]] ||
  die "MCP_REMOTE_COMMAND must be an absolute path inside the Letta container."

case "${MCP_DISABLE_STDIO,,}" in
  false|0|no)
    ;;
  *)
    die "MCP_DISABLE_STDIO must be false for the stdio mcp-remote bridge."
    ;;
esac

case "$LETTA_CLEANUP_SCOPE" in
  matching|all)
    ;;
  *)
    die "LETTA_CLEANUP_SCOPE must be either 'matching' or 'all'."
    ;;
esac

require_positive_integer CONNECT_TIMEOUT_SECONDS
require_positive_integer REQUEST_TIMEOUT_SECONDS
require_positive_integer AGENT_PAGE_SIZE
require_positive_integer MCP_TOOL_WAIT_SECONDS
require_positive_integer MCP_TOOL_POLL_SECONDS
require_positive_integer LETTA_CONTEXT_WINDOW_LIMIT

(( AGENT_PAGE_SIZE <= 200 )) ||
  die "AGENT_PAGE_SIZE cannot exceed 200."

(( LETTA_CONTEXT_WINDOW_LIMIT >= 50000 )) ||
  die "LETTA_CONTEXT_WINDOW_LIMIT must be at least 50000 for this deployment."

LETTA_URL="${LETTA_URL%/}"
WORK_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Validate the OpenAI-backed model handles before deleting anything
# ---------------------------------------------------------------------------

log "Validating Letta connection and OpenAI model handles..."

LLM_MODELS_JSON="$(letta_request GET "${LETTA_URL}/v1/models/")" ||
  die "Unable to retrieve Letta LLM models."

printf '%s\n' "$LLM_MODELS_JSON" |
  jq -e 'type == "array"' >/dev/null ||
  die "Unexpected response from /v1/models/: expected a JSON array."

if ! printf '%s\n' "$LLM_MODELS_JSON" |
  jq -e --arg model "$LETTA_MODEL" 'any(.[]; .handle == $model)' >/dev/null; then
  error "Letta does not advertise LLM handle '${LETTA_MODEL}'."
  error "This usually means OPENAI_API_KEY was not accepted by the Letta container."
  printf '%s\n' 'Available OpenAI LLM handles:' >&2
  printf '%s\n' "$LLM_MODELS_JSON" |
    jq -r '.[] | select((.handle // "") | startswith("openai/")) | .handle' >&2
  exit 1
fi

EMBEDDING_MODELS_JSON="$(letta_request GET "${LETTA_URL}/v1/models/embedding")" ||
  die "Unable to retrieve Letta embedding models."

printf '%s\n' "$EMBEDDING_MODELS_JSON" |
  jq -e 'type == "array"' >/dev/null ||
  die "Unexpected response from /v1/models/embedding: expected a JSON array."

if ! printf '%s\n' "$EMBEDDING_MODELS_JSON" |
  jq -e --arg embedding "$LETTA_EMBEDDING_HANDLE" \
    'any(.[]; .handle == $embedding)' >/dev/null; then
  error "Letta does not advertise embedding handle '${LETTA_EMBEDDING_HANDLE}'."
  printf '%s\n' 'Available OpenAI embedding handles:' >&2
  printf '%s\n' "$EMBEDDING_MODELS_JSON" |
    jq -r '.[] | select((.handle // "") | startswith("openai/")) | .handle' >&2
  exit 1
fi

log "OpenAI model handles are available through Letta."

# ---------------------------------------------------------------------------
# Discover and delete existing agents
# ---------------------------------------------------------------------------

log "Checking existing agents..."
ALL_AGENTS_JSON="$(list_all_agents)" || die "Unable to list registered agents."

if [[ "$LETTA_CLEANUP_SCOPE" == "all" ]]; then
  mapfile -t AGENT_IDS_TO_DELETE < <(
    printf '%s\n' "$ALL_AGENTS_JSON" | jq -r '.[].id // empty'
  )
else
  mapfile -t AGENT_IDS_TO_DELETE < <(
    printf '%s\n' "$ALL_AGENTS_JSON" |
      jq -r --arg name "$LETTA_AGENT_NAME" \
        '.[] | select(.name == $name) | .id // empty'
  )
fi

if [[ "${#AGENT_IDS_TO_DELETE[@]}" -eq 0 ]]; then
  log "No agents matched the cleanup scope."
else
  for agent_id in "${AGENT_IDS_TO_DELETE[@]}"; do
    log "Deleting agent ${agent_id}..."
    letta_request DELETE "${LETTA_URL}/v1/agents/${agent_id}" >/dev/null ||
      die "Failed to delete agent '${agent_id}'."
  done
  log "Deleted ${#AGENT_IDS_TO_DELETE[@]} agent(s)."
fi

# ---------------------------------------------------------------------------
# Discover and delete existing MCP servers
# ---------------------------------------------------------------------------

log "Checking existing MCP servers..."
ALL_MCP_SERVERS_JSON="$(letta_request GET "${LETTA_URL}/v1/mcp-servers/")" ||
  die "Unable to list registered MCP servers."

printf '%s\n' "$ALL_MCP_SERVERS_JSON" |
  jq -e 'type == "array"' >/dev/null ||
  die "Unexpected response from /v1/mcp-servers/: expected a JSON array."

if [[ "$LETTA_CLEANUP_SCOPE" == "all" ]]; then
  mapfile -t MCP_SERVER_IDS_TO_DELETE < <(
    printf '%s\n' "$ALL_MCP_SERVERS_JSON" | jq -r '.[].id // empty'
  )
else
  mapfile -t MCP_SERVER_IDS_TO_DELETE < <(
    printf '%s\n' "$ALL_MCP_SERVERS_JSON" |
      jq -r --arg name "$MCP_SERVER_NAME" \
        '.[] | select(.server_name == $name) | .id // empty'
  )
fi

if [[ "${#MCP_SERVER_IDS_TO_DELETE[@]}" -eq 0 ]]; then
  log "No MCP servers matched the cleanup scope."
else
  for mcp_server_id in "${MCP_SERVER_IDS_TO_DELETE[@]}"; do
    log "Deleting MCP server ${mcp_server_id}..."
    letta_request DELETE "${LETTA_URL}/v1/mcp-servers/${mcp_server_id}" >/dev/null ||
      die "Failed to delete MCP server '${mcp_server_id}'."
  done
  log "Deleted ${#MCP_SERVER_IDS_TO_DELETE[@]} MCP server(s)."
fi

# ---------------------------------------------------------------------------
# Create the MCP stdio bridge
# ---------------------------------------------------------------------------

log "Creating MCP server '${MCP_SERVER_NAME}'..."

MCP_SERVER_PAYLOAD="$(
  jq -n \
    --arg server_name "$MCP_SERVER_NAME" \
    --arg command "$MCP_REMOTE_COMMAND" \
    --arg server_url "$BUSINESS_MCP_URL" \
    --arg transport "$MCP_REMOTE_TRANSPORT" \
    --arg remote_home "$MCP_REMOTE_HOME" \
    '{
      server_name: $server_name,
      config: {
        mcp_server_type: "stdio",
        command: $command,
        args: [
          $server_url,
          "--transport",
          $transport,
          "--allow-http",
          "--silent"
        ],
        env: {
          HOME: $remote_home,
          MCP_REMOTE_HOME: $remote_home
        }
      }
    }'
)"

MCP_SERVER_JSON="$(
  letta_request POST "${LETTA_URL}/v1/mcp-servers/" "$MCP_SERVER_PAYLOAD"
)" || die "Failed to create MCP server '${MCP_SERVER_NAME}'."

MCP_SERVER_ID="$(printf '%s\n' "$MCP_SERVER_JSON" | jq -er '.id')" ||
  die "MCP server creation response did not contain an ID."

log "Created MCP server ${MCP_SERVER_ID}."

# ---------------------------------------------------------------------------
# Wait for the MCP tools to become available
# ---------------------------------------------------------------------------

log "Waiting for MCP tools..."
MCP_TOOLS_JSON='[]'
TOOL_COUNT=0
WAITED_SECONDS=0

while (( WAITED_SECONDS <= MCP_TOOL_WAIT_SECONDS )); do
  MCP_TOOLS_JSON="$(
    letta_request GET "${LETTA_URL}/v1/mcp-servers/${MCP_SERVER_ID}/tools"
  )" || die "Unable to retrieve tools for MCP server '${MCP_SERVER_ID}'."

  printf '%s\n' "$MCP_TOOLS_JSON" |
    jq -e '
      type == "array"
      and all(.[];
        (.id | type == "string")
        and (.id | length > 0)
      )
    ' >/dev/null ||
    die "MCP tools response was not a valid array of tools."

  TOOL_COUNT="$(printf '%s\n' "$MCP_TOOLS_JSON" | jq 'length')"

  if (( TOOL_COUNT > 0 )); then
    break
  fi

  if (( WAITED_SECONDS == MCP_TOOL_WAIT_SECONDS )); then
    break
  fi

  sleep "$MCP_TOOL_POLL_SECONDS"
  WAITED_SECONDS=$((WAITED_SECONDS + MCP_TOOL_POLL_SECONDS))
done

(( TOOL_COUNT > 0 )) ||
  die "MCP server '${MCP_SERVER_NAME}' exposed no tools after ${MCP_TOOL_WAIT_SECONDS} seconds."

TOOL_IDS_JSON="$(printf '%s\n' "$MCP_TOOLS_JSON" | jq -c '[.[].id]')"
log "Loaded ${TOOL_COUNT} MCP tool(s)."

# ---------------------------------------------------------------------------
# Create the OpenAI-backed Letta agent
# ---------------------------------------------------------------------------

log "Creating agent '${LETTA_AGENT_NAME}'..."

AGENT_PAYLOAD="$(
  jq -n \
    --arg name "$LETTA_AGENT_NAME" \
    --arg model "$LETTA_MODEL" \
    --arg embedding "$LETTA_EMBEDDING_HANDLE" \
    --arg timezone "$LETTA_AGENT_TIMEZONE" \
    --argjson context_window_limit "$LETTA_CONTEXT_WINDOW_LIMIT" \
    --argjson tool_ids "$TOOL_IDS_JSON" \
    '{
      name: $name,
      agent_type: "letta_v1_agent",
      model: $model,
      context_window_limit: $context_window_limit,
      embedding: $embedding,
      timezone: $timezone,
      system: "
You are a business operations agent.

Use an available MCP tool when external information is required.

Never claim that an external action succeeded unless the tool response
explicitly confirms success.

Prefer read-only operations.

Do not create, update, send or delete external data unless the user
explicitly asks you to do so.

Give a clear final answer that can be stored in a business application
conversation.
      ",
      memory_blocks: [
        {
          label: "persona",
          value: "A careful business operations assistant."
        },
        {
          label: "human",
          value: "Requests arrive from an external business application."
        }
      ],
      include_base_tools: true,
      include_base_tool_rules: true,
      tool_ids: $tool_ids
    }'
)"

AGENT_JSON="$(
  letta_request POST "${LETTA_URL}/v1/agents/" "$AGENT_PAYLOAD"
)" || die "Failed to create agent '${LETTA_AGENT_NAME}'."

AGENT_ID="$(printf '%s\n' "$AGENT_JSON" | jq -er '.id')" ||
  die "Agent creation response did not contain an ID."

# ---------------------------------------------------------------------------
# Final deployment summary
# ---------------------------------------------------------------------------

printf '\n============================================================\n'
printf 'Letta OpenAI deployment completed successfully\n'
printf '============================================================\n\n'

printf 'MCP server\n'
printf '  Name: %s\n' "$MCP_SERVER_NAME"
printf '  ID:   %s\n' "$MCP_SERVER_ID"
printf '  Tool IDs:\n'
printf '%s\n' "$TOOL_IDS_JSON" |
  jq -r '.[] | "    - " + .'

printf '\nAgent\n'
printf '  ID: %s\n' "$AGENT_ID"
printf '  Configuration:\n'
printf '%s\n' "$AGENT_JSON" |
  jq '{
    id,
    name,
    agent_type,
    model,
    context_window_limit,
    model_settings,
    embedding,
    timezone
  }'

printf '\nSave this for your existing client:\n'
printf '  AGENT_ID=%s\n' "$AGENT_ID"
