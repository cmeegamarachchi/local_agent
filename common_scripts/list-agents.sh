#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-.env}"
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-10}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-600}"
AGENT_PAGE_SIZE="${AGENT_PAGE_SIZE:-200}"

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

letta_request() {
  local method="$1"
  local url="$2"
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
      jq -e 'type == "array"' >/dev/null ||
      die "Unexpected response from the agents endpoint."

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

    after="$last_agent_id"
  done

  printf '%s\n' "$all_agents"
}

require_command curl
require_command jq

[[ -f "$ENV_FILE" ]] || die "Environment file '$ENV_FILE' does not exist."
[[ -r "$ENV_FILE" ]] || die "Environment file '$ENV_FILE' is not readable."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_env LETTA_URL
require_env LETTA_SERVER_PASSWORD

LETTA_URL="${LETTA_URL%/}"
WORK_DIR="$(mktemp -d)"

ALL_AGENTS_JSON="$(list_all_agents)" || die "Unable to list registered agents."

printf '%s\n' "$ALL_AGENTS_JSON" |
  jq -r '
    ["NAME", "ID"],
    (sort_by(.name)[] | [.name, .id])
    | @tsv
  ' | column -t -s $'\t'
