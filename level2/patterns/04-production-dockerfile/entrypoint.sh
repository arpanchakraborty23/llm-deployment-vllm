#!/bin/bash
# Production entrypoint — auto-login to Hugging Face, then serve

set -euo pipefail

# login to Huggingface
if [ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]; then
    hf auth login --token "$HUGGING_FACE_HUB_TOKEN"
fi

DEFAULT_ARGS=(
    "--gpu-memory-utilization" "0.95" # Max gpu utilization
    "--max-model-len" "8192"  # Max Context window
    "--max-num-seqs" "128"    # Batch Processing
    "--enable-prefix-caching" # Caching
)

if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
    exec vllm serve "Qwen/Qwen3-0.6B" "${DEFAULT_ARGS[@]}" "$@"
else
    exec vllm serve "$@"
fi
