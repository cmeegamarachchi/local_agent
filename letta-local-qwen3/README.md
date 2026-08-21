# Local Qwen 3.5 + Ollama + Letta

Compatibility-first replacement for the existing OpenAI-backed Letta 0.16.8
deployment.

See also [../letta-openai](../letta-openai) — an independent Letta
deployment backed by hosted OpenAI models instead of local Ollama, runnable
alongside this stack.

## Architecture

Existing application
-> Letta API :8283
-> Qwen3.5-9B through Ollama
-> local nomic-embed-text embeddings
-> existing MCP bridge / tools

Ollama also exposes an OpenAI-compatible API at:
http://127.0.0.1:11434/v1

The existing application-facing Letta endpoint remains:
POST /v1/agents/{AGENT_ID}/messages

## Recommended model

Chat:
qwen3.5:9b-q4_K_M

Embedding:
nomic-embed-text:latest

Configured physical context:
65,536 tokens

Letta agent context limit:
65,536 tokens

This is intended to allow roughly 50K of useful working context while retaining
space for Letta memory/system content, MCP schemas, and response generation.

## 1. Verify Windows / Docker GPU passthrough

Run in PowerShell:

    nvidia-smi
    docker run --rm --gpus all ubuntu nvidia-smi

Confirm the GPU is visible and reports approximately 16 GB VRAM.

Docker Desktop must be using the WSL2 backend / Linux containers.

## 2. Configure

Copy:

    .env.example -> .env

At minimum update:

    LETTA_SERVER_PASSWORD
    LETTA_BIND_ADDRESS / LETTA_URL if accessed over the LAN
    BUSINESS_MCP_URL
    LETTA_ACCEPTABLE_ORIGINS
    # this needs to be external path as in host like /q/projects/app-solve/llm
    EXTERNAL_LLM_ROOT

Do NOT add OPENAI_API_KEY or OPENAI_BASE_URL to this stack.

## 3. Start

From PowerShell or WSL:

    docker compose up -d --build

The model-init service pulls the chat and embedding models on first startup.

Inspect:

    docker compose ps
    docker compose logs --tail=200 ollama
    docker compose logs --tail=200 letta

## 4. Verify GPU loading

After making one model request:

    docker exec ollama ollama ps

The chat model should report 100% GPU if it fits completely in VRAM.

## 5. Test the raw OpenAI-compatible provider

PowerShell:

    $body = @{
      model = "qwen3.5:9b-q4_K_M"
      messages = @(
        @{ role = "user"; content = "Reply with exactly: LOCAL_LLM_OK" }
      )
    } | ConvertTo-Json -Depth 6

    Invoke-RestMethod `
      -Uri "http://127.0.0.1:11434/v1/chat/completions" `
      -Method Post `
      -ContentType "application/json" `
      -Body $body

For OpenAI SDK clients use:

    base_url = "http://127.0.0.1:11434/v1/"
    api_key  = "ollama"   # syntactically required by some clients; ignored locally

### 5.1 to eveluate speed

Note stream mode is set to false

```bash
curl -s http://host.docker.internal:11434/api/generate \
  -d '{
    "model": "qwen3.5:9b-q4_K_M",
    "prompt": "Write a detailed technical explanation of how transformer-based language models perform inference.",
    "stream": false
  }' |
jq -r '
  "Prompt: \(.prompt_eval_count) tokens @ \((.prompt_eval_count / (.prompt_eval_duration / 1e9)) | floor) tok/s
Output: \(.eval_count) tokens @ \((.eval_count / (.eval_duration / 1e9)) * 100 | round / 100) tok/s
Total:  \((.total_duration / 1e9) * 100 | round / 100) sec"
'
```

## 6. Bootstrap the Letta agent and MCP tools

The bootstrap script uses bash, curl, and jq. On Windows, run it from WSL2:

    sudo apt-get update
    sudo apt-get install -y curl jq

Then:

    chmod +x rebuild-letta-agent-stack.sh
    ./rebuild-letta-agent-stack.sh

Save the AGENT_ID printed at the end.

## 7. Validate through the unchanged Letta interface

In WSL, from the `letta-local-qwen3` directory:

    ../common_scripts/send-message.sh "Can you tell me about movements for tag with Tag031 from 2026-JUL-19 to 2026-JUL-21"

This posts to `/v1/agents/{AGENT_ID}/messages`, the same application-facing
endpoint as the prior OpenAI-backed stack, and prints the JSON response. It
reads `LETTA_URL` and `LETTA_SERVER_PASSWORD` from `.env` in the current
directory and always sends to the first agent returned by the Letta API.
Omit the message argument to send a canned test message. See
[../common_scripts](../common_scripts) for details.

## Listing agents

To list all registered agent names alongside their IDs:

    ../common_scripts/list-agents.sh

See [../common_scripts](../common_scripts) for details.

## Tuning notes

### If VRAM is tight

First keep the 9B chat model and change:

    OLLAMA_MAX_LOADED_MODELS=1

This unloads/reloads the embedding model as needed.

If the 9B model itself cannot remain fully on GPU at 64K context, change both:

    OLLAMA_CHAT_MODEL=qwen3.5:4b-q4_K_M
    LETTA_MODEL=ollama/qwen3.5:4b-q4_K_M

Do not reduce OLLAMA_CONTEXT_LENGTH below 65536 if ~50K application context is
a hard requirement.

### Concurrency

Keep:

    OLLAMA_NUM_PARALLEL=1

A long-context model consumes substantially more memory when several requests
are processed in parallel. Let Ollama queue requests instead.

### Raw Ollama API security

The local Ollama HTTP API does not authenticate local requests. Keep
OLLAMA_BIND_ADDRESS=127.0.0.1 unless direct LAN access is required. If it must
be exposed, place an authenticated TLS reverse proxy in front of it.

Letta itself remains protected by LETTA_SERVER_PASSWORD.

## Common issues

Following error appears when initializing agent for the second time with `./rebuild-letta-agent-stack.sh `  

```bash
Validating Letta connection and Ollama model handles...
curl: (52) Empty reply from server
ERROR: Could not complete GET request to http://host.docker.internal:8283/v1/models/.
ERROR: Unable to retrieve Letta LLM models.
```

Make sure the agent stack is down

`docker compose down`

and rebuild from scratch

`docker compose build --no-cache && docker compose up -d`

using docker desktop, make sure letta server is running at expected port
