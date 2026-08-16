#!/bin/sh
# Start the token server with the OpenAI key pulled from the machine's
# credential store at runtime — the key is never written into this repo.
set -e
cd "$(dirname "$0")"
KEY=$(grep '^OPENAI_API_KEY=' "$HOME/.clawd-credentials/credentials.md" | head -1 \
      | sed -E 's/^OPENAI_API_KEY="//; s/(\\n)?"$//')
[ -n "$KEY" ] || { echo "no OPENAI_API_KEY found in credential store" >&2; exit 1; }
OPENAI_API_KEY="$KEY" exec python3 serve.py
