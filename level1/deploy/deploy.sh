#!/usr/bin/env bash

set -euo pipefail

# ==========================================================
# Paths
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-config.yml}"
VENV_DIR="$SCRIPT_DIR/.venv"

# ==========================================================
# Validate
# ==========================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
    echo "ERROR: Virtual environment not found: $VENV_DIR"
    exit 1
fi

# ==========================================================
# Activate virtual environment
# ==========================================================

source "$VENV_DIR/bin/activate"

# ==========================================================
# Check dependencies
# ==========================================================

command -v python >/dev/null || {
    echo "Python not found."
    exit 1
}

command -v pip >/dev/null || {
    echo "pip not found."
    exit 1
}

command -v vllm >/dev/null || {
    echo "vLLM is not installed."
    echo "Run:"
    echo "pip install vllm"
    exit 1
}

python - <<'PYEOF'
import yaml
PYEOF

# ==========================================================
# Load YAML
# ==========================================================

eval "$(
python - "$CONFIG_FILE" <<'PYEOF'
import yaml
import sys

with open(sys.argv[1], "r") as f:
    cfg = yaml.safe_load(f)

def emit(prefix, obj):
    if obj is None:
        return

    for k, v in obj.items():
        key = prefix + k.upper()

        if isinstance(v, dict):
            emit(key + "_", v)
        else:
            if v is None:
                v = ""
            print(f'{key}="{v}"')

emit("CFG_", cfg)
PYEOF
)"

# ==========================================================
# Environment
# ==========================================================

if [[ -n "${CFG_ENV_CUDA_HOME:-}" ]]; then
    export CUDA_HOME="$CFG_ENV_CUDA_HOME"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib:$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
fi

export VLLM_ATTENTION_BACKEND="${CFG_ENV_VLLM_ATTENTION_BACKEND:-FLASH_ATTN}"
export VLLM_USE_FLASHINFER_SAMPLER="${CFG_ENV_VLLM_USE_FLASHINFER_SAMPLER:-0}"
export FLASHINFER_DISABLE_VERSION_CHECK="${CFG_ENV_FLASHINFER_DISABLE_VERSION_CHECK:-1}"

# ==========================================================
# Diagnostics
# ==========================================================

echo
echo "========================================="
echo "vLLM Deployment"
echo "========================================="
echo "Python : $(which python)"
echo "Pip    : $(which pip)"
echo "vLLM   : $(which vllm)"
echo "CUDA   : ${CUDA_HOME:-Not Set}"
echo "Model  : $CFG_MODEL_NAME"
echo "Host   : $CFG_SERVER_HOST"
echo "Port   : $CFG_SERVER_PORT"
echo "========================================="
echo

nvcc --version || true
nvidia-smi || true

# ==========================================================
# Build command
# ==========================================================

CMD=(
    vllm serve "$CFG_MODEL_NAME"
    --host "$CFG_SERVER_HOST"
    --port "$CFG_SERVER_PORT"
    --gpu-memory-utilization "$CFG_MODEL_GPU_MEMORY_UTILIZATION"
    --max-model-len "$CFG_MODEL_MAX_MODEL_LEN"
    --tensor-parallel-size "$CFG_MODEL_TENSOR_PARALLEL_SIZE"
    --dtype "$CFG_MODEL_DTYPE"
)

if [[ -n "${CFG_MODEL_QUANTIZATION:-}" ]]; then
    CMD+=(--quantization "$CFG_MODEL_QUANTIZATION")
fi

if [[ -n "${CFG_SERVER_API_KEY:-}" ]]; then
    CMD+=(--api-key "$CFG_SERVER_API_KEY")
fi

# ==========================================================
# Launch
# ==========================================================

echo
echo "Launching..."
echo "${CMD[*]}"
echo

mkdir -p logs

exec "${CMD[@]}" 2>&1 | tee -a logs/vllm.log