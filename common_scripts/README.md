# Common scripts

Shared helper scripts for talking to any Letta stack in this repo (e.g.
[../letta-local-qwen3](../letta-local-qwen3), [../letta-openai](../letta-openai)).
Both stacks expose the same Letta API shape, so these scripts are not tied
to either one.

Run a script from inside the stack directory you want to target, so it
picks up that stack's `.env`:

    cd letta-local-qwen3   # or letta-openai
    ../common_scripts/list-agents.sh
    ../common_scripts/send-message.sh "your message"

Both scripts read `LETTA_URL` and `LETTA_SERVER_PASSWORD` from `.env` in
the current directory by default; set `ENV_FILE` to point elsewhere.

## list-agents.sh

Lists every registered agent's name and ID.

    ./list-agents.sh

## send-message.sh

Sends a message to the first registered agent through the
application-facing endpoint (`POST /v1/agents/{AGENT_ID}/messages`) and
prints the JSON response.

    ./send-message.sh ["your message"]

Omit the message argument to send a canned test message.
