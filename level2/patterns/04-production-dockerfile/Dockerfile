# Pattern 04: Production-grade Dockerfile
#
# Combines three essential optimizations:
#   1. Layer caching: copy requirements FIRST, install, THEN copy code
#   2. Multi-stage: builder (for compilation) -> runtime (lightweight)
#   3. HEALTHCHECK: Docker knows when the API is truly ready
#
# Without these:
#   - Every code change reinstalls all pip packages (3-5 min wasted)
#   - Image includes build tools not needed at runtime (1+ GB extra)
#   - Docker restarts on process crash, not API unresponsiveness
#
# Build: docker build -t vllm-prod -f Dockerfile ..
# Run:   docker run --gpus all -d -p 8000:8000 --restart unless-stopped \
#          --shm-size=16g -v hf-cache:/root/.cache/huggingface \
#          vllm-prod --model Qwen/Qwen3-0.6B

FROM vllm/vllm-openai:latest AS builder

WORKDIR /app

# Layer cache: install deps before copying code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM vllm/vllm-openai:latest

WORKDIR /app

# Copy only runtime artifacts from builder
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages

# Copy entrypoint and application code
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Health check — polls /health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1

# Non-root user (security best practice)
RUN useradd -m -u 1000 vllm && chown -R vllm:vllm /app
USER vllm

EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]
CMD ["--host", "0.0.0.0", "--port", "8000"]
