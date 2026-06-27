# Pattern 02: Custom Dockerfile
#
# The official vLLM image is a good base, but you need your own
# Dockerfile to pin versions, add packages, or deploy custom code.
# This is the minimal pattern — every production image builds on this.
#
# Build:  docker build -t my-vllm -f Dockerfile ..
# Run:    docker run --gpus all -p 8000:8000 my-vllm

FROM vllm/vllm-openai:latest

WORKDIR /app

# Copy and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code (if any)
COPY . .

EXPOSE 8000

ENTRYPOINT ["vllm", "serve"]
CMD ["Qwen/Qwen3-0.6B", "--host", "0.0.0.0", "--port", "8000"]
