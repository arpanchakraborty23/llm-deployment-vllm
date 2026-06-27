# Pattern 10: Full Production Stack Dockerfile
#
# Multi-stage build with layer caching, health check,
# non-root user, and the custom Python vLLM server.

FROM vllm/vllm-openai:latest AS builder

WORKDIR /app

COPY server.py .
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM vllm/vllm-openai:latest

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY server.py .
COPY entrypoint.sh .

RUN chmod +x entrypoint.sh && \
    useradd -m -u 1000 vllm && \
    chown -R vllm:vllm /app

USER vllm

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1

EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]
