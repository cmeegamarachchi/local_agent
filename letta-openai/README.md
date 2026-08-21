# OpenAI + Letta

Hosted-OpenAI counterpart to the [letta-local-qwen3](../letta-local-qwen3)
stack. Runs its own independent Letta server (own container, own Postgres
volume, own port) so both stacks can be deployed side by side, each managing
its own agent.

## Architecture

Existing application
-> Letta API :8284
-> OpenAI chat + embedding models over the network
-> existing MCP bridge / tools

Unlike letta-local-qwen3 there is no Ollama container: Letta talks to
OpenAI's hosted API directly, authenticated with the API key in `.env`.

The application-facing Letta endpoint is:
POST /v1/agents/{AGENT_ID}/messages

## Recommended model

Chat:
gpt-4o-mini

Embedding:
text-embedding-3-small

Configured context:
128,000 tokens

Letta agent context limit:
128,000 tokens

Both are configurable via `LETTA_MODEL` / `LETTA_EMBEDDING_HANDLE` /
`LETTA_CONTEXT_WINDOW_LIMIT` in `.env` — any OpenAI chat/embedding model
Letta supports can be used by changing the handle.

## 1. Configure

Copy:

    env.example -> .env

At minimum update:

    OPEN_AI_API_KEY
    LETTA_SERVER_PASSWORD
    LETTA_BIND_ADDRESS / LETTA_URL if accessed over the LAN
    BUSINESS_MCP_URL
    LETTA_ACCEPTABLE_ORIGINS
    # this needs to be an external path as in host like /q/projects/app-solve/llm
    EXTERNAL_LLM_ROOT

`OPEN_AI_API_KEY` is required. `rebuild-letta-agent-stack.sh` validates it is
set before it deletes or creates anything, and the build fails fast if it is
missing. Never commit a real key — `.env` is gitignored; only `env.example`
is tracked.

## 2. Start

    docker compose up -d --build

Inspect:

    docker compose ps
    docker compose logs --tail=200 letta

## 3. Bootstrap the Letta agent and MCP tools

The bootstrap script uses bash, curl, and jq. On Windows, run it from WSL2:

    sudo apt-get update
    sudo apt-get install -y curl jq

Then:

    chmod +x rebuild-letta-agent-stack.sh
    ./rebuild-letta-agent-stack.sh

Save the AGENT_ID printed at the end.

The script validates that `OPEN_AI_API_KEY` was accepted by the Letta
container (i.e. Letta advertises `openai/*` handles through `/v1/models/`)
before deleting or creating any agent or MCP server.

## 4. Validate through the unchanged Letta interface

From the `letta-openai` directory:

    ../common_scripts/send-message.sh "Can you tell me about movements for tag with Tag031 from 2026-JUL-19 to 2026-JUL-21"

This posts to `/v1/agents/{AGENT_ID}/messages`, the same application-facing
endpoint shape as the letta-local-qwen3 stack, and prints the JSON
response. It reads `LETTA_URL` and `LETTA_SERVER_PASSWORD` from `.env` in
the current directory and always sends to the first agent returned by the
Letta API. Omit the message argument to send a canned test message. See
[../common_scripts](../common_scripts) for details.

To list all registered agent names alongside their IDs:

    ../common_scripts/list-agents.sh

## Running alongside letta-local-qwen3

This stack is a separate deployment, not a second agent bolted onto the
qwen3 Letta server:

- Different `COMPOSE_PROJECT_NAME` (`letta-openai` vs `letta-local`)
- Different container name and port (`letta-openai` on 8284 vs `letta` on
  8283)
- Different Postgres/MCP data directories under `EXTERNAL_LLM_ROOT`
  (`letta-openai-postgres-data` / `letta-openai-mcp-data`)
- Different `LETTA_SERVER_PASSWORD` and agent name (`openai-agent`)

Both can run at the same time with `docker compose up -d` in each directory,
each exposing its own agent independently.

## Notes

### API key handling

`OPEN_AI_API_KEY` in `.env` is mapped to the `OPENAI_API_KEY` container
environment variable in [compose.yml](compose.yml) — that is the name
Letta's OpenAI provider integration looks for to auto-register `openai/*`
model handles.

### Cost and rate limits

Every request goes to OpenAI's hosted API and is billed per the account tied
to `OPEN_AI_API_KEY`. Watch usage/rate limits if this agent sees production
traffic.

## Common issues

### Letta url is incorrect

Following error appears when initializing agent for the second time with
`./rebuild-letta-agent-stack.sh`:

```bash
Validating Letta connection and OpenAI model handles...
curl: (52) Empty reply from server
ERROR: Could not complete GET request to http://127.0.0.1:8284/v1/models/.
ERROR: Unable to retrieve Letta LLM models.
```

Make sure the stack is down

`docker compose down`

and rebuild from scratch

`docker compose build --no-cache && docker compose up -d`

If the stack is running locally, make sure the url is pointing to something like `http://host.docker.internal:8284`. Value for port is the "Port" part in the Ports section   


If `LETTA_MODEL` / `LETTA_EMBEDDING_HANDLE` handles are not advertised by
`/v1/models/`, double check `OPEN_AI_API_KEY` in `.env` is a valid key with
access to that model, then `docker compose restart letta`.
