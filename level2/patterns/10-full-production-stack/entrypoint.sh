#!/bin/bash
set -euo pipefail
if [ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]; then
    huggingface-cli login --token "$HUGGING_FACE_HUB_TOKEN"
fi
exec python server.py "$@"
