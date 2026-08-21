# local_agent
Local llm agent stack

## Agent stacks

- [letta-local-qwen3](letta-local-qwen3) — Letta backed by a local Qwen3.5 model served through Ollama.
- [letta-openai](letta-openai) — Letta backed by hosted OpenAI chat/embedding models. Independent deployment (own container, port, Postgres volume); can run alongside letta-local-qwen3.

Each directory is a self-contained Docker Compose stack with its own `.env` and bootstrap script — see each stack's README for setup instructions.

[common_scripts](common_scripts) holds helper scripts (listing agents, sending a test message) shared across all stacks.

## Development container

Open the repository in a Dev Container to use the included Ubuntu 24.04-based setup with Docker Compose support and the recommended VS Code extensions.
