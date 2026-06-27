# Pattern 09: Python vLLM Library Server
#
# Unlike patterns 01-08 that rely on `vllm serve` CLI,
# this image runs a Python script using vLLM as a library.
# All engine parameters are set in Python code via AsyncEngineArgs.
# Docker is only for deployment — the intelligence is in the code.
#
# Build:
#   docker build -t vllm-python-lib -f Dockerfile ..
#
# Run (basic):
#   docker run --gpus all -p 8000:8000 vllm-python-lib
#
# Run (tuned):
#   docker run --gpus all -p 8000:8000 \
#     --shm-size=16g \
#     -v hf-cache:/root/.cache/huggingface \
#     -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
#     vllm-python-lib \
#     --model Qwen/Qwen3-0.6B \
#     --dtype bfloat16 \
#     --gpu-memory-utilization 0.95 \
#     --max-model-len 8192 \
#     --enable-prefix-caching \
#     --api-key my-secret-key
#
# Test:
#   curl http://localhost:8000/health
#   curl http://localhost:8000/metrics
#   curl http://localhost:8000/v1/models

FROM vllm/vllm-openai:latest

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn pydantic

COPY server.py .

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1

EXPOSE 8000

ENTRYPOINT ["python", "server.py"]
CMD ["--model", "Qwen/Qwen3-0.6B"]
