# Level 2 — LLM Deployment with Docker

You know how to run `vllm serve` natively (Level 1). Now package it in Docker.

**Goal:** Learn 7 deployment patterns — from "just run the official image" to "full production stack with Redis + custom Python server + multi-GPU."

Each pattern solves a real LLM deployment problem and lives in `patterns/XX-name/`. Docker is the vehicle, not the focus.

---

## Pattern 01 — Basic Docker Run

**Problem:** You ran `vllm serve` natively. Now run it in a container.

**Directory:** `patterns/01-basic-docker-run/` (empty — just run the command)

```bash
docker run --gpus all \
    -p 8000:8000 \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    vllm/vllm-openai:latest \
    --model Qwen/Qwen3-0.6B
```

**What you learn:** GPU passthrough (`--gpus all`), port mapping (`-p 8000:8000`), volume mount for model cache, container lifecycle.

**Explanation:** The vLLM image is ~8 GB (includes CUDA, PyTorch, transformers). First run pulls it, then downloads the model weights (~1.2 GB for Qwen3-0.6B). The volume mount `~/.cache/huggingface:/root/.cache/huggingface` ensures the model is cached on the host — without it, every `docker run` re-downloads the weights. The model loads into GPU memory on startup (cold start: 10–30 seconds for 0.6B, minutes for larger models). Requests queue up in the vLLM scheduler — it batches them automatically up to `--max-num-seqs` (default 256). With default settings on a single GPU, expect ~500–1500 tokens/sec for Qwen3-0.6B. The container runs in the foreground — closing the terminal kills it.

**Production?** ❌ No — missing restart policy, health checks, resource limits.

---

## Pattern 02 — Custom Dockerfile

**Problem:** The official image is generic. You need pinned versions, extra packages, or custom code.

**Directory:** `patterns/02-custom-dockerfile/`

```bash
cd patterns/02-custom-dockerfile
docker build -t my-vllm .
docker run --gpus all -p 8000:8000 my-vllm
```

Files provided:
- `Dockerfile` — minimal custom image
- `Dockerfile.multistage` — multi-stage variant (separates build deps from runtime)
- `requirements.txt` — pinned dependency versions

**What you learn:** Dockerfile structure, `FROM` / `COPY` / `RUN` / `ENTRYPOINT` / `CMD`, pip dependencies, image rebuilding.

**Explanation:** The official image includes vLLM but not necessarily the exact version you want. By creating your own Dockerfile, you pin `vllm==0.6.3` so your deployment is reproducible. The `ENTRYPOINT` vs `CMD` distinction matters: `ENTRYPOINT` is the executable (`vllm serve`), `CMD` provides default arguments. Users can override `CMD` at runtime: `docker run ... my-vllm --model meta-llama/Llama-3.1-8B`. The `Dockerfile.multistage` variant splits the build into two stages: a builder stage that installs pip packages, and a runtime stage that copies only the installed packages — reducing image size by excluding pip caches and build artifacts. Build time depends on pip install; the official image already has most dependencies, so this is usually fast (30–60 seconds).

**Production?** ❌ Not alone — foundation for production, but missing health checks, limits, persistence.

---

## Pattern 03 — Environment Variables & Volumes

**Problem:** Tokens hardcoded in images are insecure. Models re-download on every container restart.

**Directory:** `patterns/03-env-and-volumes/`

```bash
# Named volume — persists HF cache across container lifecycles
docker volume create hf-cache

# Pass token securely at runtime
docker run --gpus all -p 8000:8000 \
    -v hf-cache:/root/.cache/huggingface \
    -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
    vllm/vllm-openai:latest \
    --model meta-llama/Llama-3.2-3B-Instruct

# Bind mount — use local model files (no download)
docker run --gpus all -p 8000:8000 \
    -v /models:/models \
    vllm/vllm-openai:latest \
    --model /models/Qwen3-0.6B
```

**What you learn:** `-e` for secrets, `--env-file` for config files, named volumes for persistence, bind mounts for local models.

**Explanation:** The Hugging Face cache is at `~/.cache/huggingface`. For gated models (Llama, Mistral), vLLM reads `HUGGING_FACE_HUB_TOKEN` from the environment to authenticate. Without it, model loading fails with a 401 error. A named volume (`docker volume create hf-cache`) persists the cache even when containers are removed — `docker rm` the container, create a new one, and the weights are already there. Startup drops from minutes to seconds. A bind mount (`-v /models:/models`) is useful when models are downloaded as a separate step (CI/CD pipeline, shared NAS, air-gapped environments). With bind mounts, the container uses the model directly from the host filesystem — no Hugging Face access needed at runtime. The `.env` file template shows the standard environment variables: `HUGGING_FACE_HUB_TOKEN`, `VLLM_MODEL`, `VLLM_GPU_MEMORY_UTILIZATION`, `VLLM_MAX_MODEL_LEN`.

**Production?** ✅ Mandatory — never hardcode tokens, never re-download models.

---

## Pattern 04 — Production Dockerfile

**Problem:** Naive Dockerfiles are slow to rebuild and produce bloated images.

**Directory:** `patterns/04-production-dockerfile/`

```bash
cd patterns/04-production-dockerfile
docker build -t vllm-prod .
docker run --gpus all -d -p 8000:8000 --restart unless-stopped \
    --shm-size=16g -v hf-cache:/root/.cache/huggingface \
    vllm-prod --model Qwen/Qwen3-0.6B
```

Files provided:
- `Dockerfile` — multi-stage, HEALTHCHECK, non-root user
- `entrypoint.sh` — auto Hugging Face login + sensible defaults
- `requirements.txt` — production dependency

**Optimizations (in order of importance):**

```
# 1. Layer caching — install deps BEFORE copying code
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .

# 2. Multi-stage — build tools in builder, only artifacts in runtime
FROM vllm/vllm-openai:latest AS builder
...
FROM vllm/vllm-openai:latest AS runtime
COPY --from=builder /usr/local/lib/... /usr/local/lib/...

# 3. HEALTHCHECK — Docker knows if API is truly ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1

# 4. Non-root user — security best practice
RUN useradd -m -u 1000 vllm && chown -R vllm:vllm /app
USER vllm
```

**Explanation:** Layer caching is the highest-impact optimization for development speed. Without it, changing one line of code triggers a full `pip install` — 3–5 minutes of waiting. With layer caching, `pip install` runs only when `requirements.txt` changes (rare). `COPY . .` (your code) is the last layer and takes 1–2 seconds. Multi-stage builds reduce the final image size. The builder stage compiles/installs everything; the runtime stage copies only the installed Python packages. This removes build-time artifacts (cmake cache, .o files, pip cache) from the final image — saving 500 MB to 2 GB. The `HEALTHCHECK` polls `/health` every 30 seconds. When vLLM finishes loading the model, it starts responding to `/health` with `200 OK`. If loading fails or the API hangs, Docker marks it `unhealthy` and (with `--restart unless-stopped`) restarts it automatically. Without this, Docker only restarts on process crash, not on application-level failure. The `start-period=60s` gives the model time to load before health checks begin — prevents false positives during cold start. The non-root user prevents container breakout attacks: if an attacker exploits vLLM, they get `uid 1000` permissions, not root.

**The `entrypoint.sh`** script provides auto-login to Hugging Face (reads `HUGGING_FACE_HUB_TOKEN` from the environment) and sets sensible vLLM defaults (`--gpu-memory-utilization 0.95`, `--max-model-len 8192`, `--max-num-seqs 128`, `--enable-prefix-caching`) while still allowing all flags to be overridden at runtime.

**Production?** ✅ Yes — this is the minimal production image.

---

## Pattern 05 — Python vLLM Library (Programmatic Server)

**Problem:** `vllm serve` is a CLI wrapper. In production, you need programmatic control — custom endpoints, metrics, dynamic scheduling, multi-model routing.

**Directory:** `patterns/05-python-vllm-library/`

```bash
cd patterns/05-python-vllm-library
docker build -t vllm-python-lib .
docker run --gpus all -p 8000:8000 \
    --shm-size=16g \
    -v hf-cache:/root/.cache/huggingface \
    -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
    vllm-python-lib \
    --model Qwen/Qwen3-0.6B \
    --dtype bfloat16 \
    --enable-prefix-caching \
    --api-key my-secret-key
```

Files provided:
- `server.py` — FastAPI server using `AsyncLLMEngine` directly
- `Dockerfile` — production-ready image with HEALTHCHECK

**What you learn:** `AsyncLLMEngine`, `AsyncEngineArgs`, `SamplingParams`, serving vLLM via FastAPI, custom metrics, API key auth, programmatic control vs CLI.

**Custom endpoints exposed by `server.py`:**

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/generate` | Custom generation with full `SamplingParams` |
| `GET /v1/models` | List loaded model config |
| `GET /health` | Health check for Docker / load balancers |
| `GET /metrics` | Real-time throughput, tokens/sec, errors |

**Explanation:** `vllm serve` starts an HTTP server with fixed OpenAI-compatible endpoints. That's fine for basic use, but in production you often need more: logging every request to a database, applying custom prompt templates per user, rate limiting per API key, streaming metrics to Prometheus, or switching between models at runtime without restarting. By using `AsyncLLMEngine` directly, you control the full request lifecycle. The `AsyncEngineArgs` class accepts every parameter that `vllm serve` accepts as CLI flags — but as Python objects. This means you can change config programmatically based on environment, load models dynamically, or A/B test different quantization formats. The `SamplingParams` class controls generation: temperature, top_p, top_k, stop sequences, frequency penalty, etc. You can create different `SamplingParams` per request or per user tier. The `/metrics` endpoint exposes real-time tokens/sec — essential for capacity planning and cost tracking. The API key middleware (`--api-key`) adds authentication without modifying vLLM's internals. This pattern represents the architectural shift from "using vLLM" to "building on vLLM" — the same approach used by production inference platforms.

**Production?** ✅ Yes — this is how production inference services are built.

---

## Pattern 06 — Docker Compose (Multi-Service Stack)

**Problem:** Production inference needs more than vLLM — Redis for rate limiting, a monitoring sidecar, etc.

**Directory:** `patterns/06-docker-compose-stack/`

```bash
cd patterns/06-docker-compose-stack
docker compose up -d
```

Services defined in `docker-compose.yml`:

| Service | Purpose |
|---------|---------|
| **Redis** | Rate-limit tracking, token bucket, shared counters |
| **vLLM** | Inference engine with health dependency on Redis |

**What you learn:** Service discovery (internal DNS), health dependencies (`depends_on` + `condition`), Docker networks, compose file structure, GPU reservations via `deploy.resources`.

**Explanation:** In production, Redis serves as a shared counter for rate limiting — tracking requests per user/IP across multiple vLLM replicas. vLLM connects to Redis via its hostname `redis` (Docker's internal DNS resolves service names automatically). The `depends_on` with `condition: service_healthy` ensures vLLM waits for Redis to be ready before starting. Without this, vLLM might crash on startup if Redis isn't available. The `shm_size: 16g` flag is critical for vLLM — it allocates shared memory for tokenizer parallelism and tensor parallelism communication. Insufficient `--shm-size` causes cryptic crashes during model loading. The `deploy.resources.reservations.devices` section reserves NVIDIA GPUs — this is the Compose-native equivalent of `--gpus all`. The `hf-cache` named volume persists model weights across container restarts. The `redis-data` volume persists Redis state. Both services are on the `llm-net` bridge network, providing DNS-based service discovery. With Compose, you can add more services later: Prometheus for metrics, Grafana for dashboards, NGINX for load balancing, all on the same `llm-net` network.

**Production?** ✅ Yes — single-host production starts here.

---

## Pattern 10 — Full Production Stack

**Problem:** You need everything — custom server + Redis + multi-GPU + production Dockerfile + env config + resource limits + health checks + logging.

**Directory:** `patterns/10-full-production-stack/`

```bash
cd patterns/10-full-production-stack
docker compose up -d
```

**Stack components:**

| Component | Based On | Purpose |
|-----------|----------|---------|
| `Dockerfile` | Patterns 02, 04 | Multi-stage, layer caching, HEALTHCHECK, non-root user |
| `server.py` | Pattern 05 | Custom vLLM library server |
| `entrypoint.sh` | Pattern 04 | Auto HF login, sensible defaults |
| `.env` | Pattern 03 | Token, model, config |
| `docker-compose.yml` | Patterns 06, 05 | Redis + vLLM, resource limits, GPU reservation, logging |

**Explanation:** This is the final destination. Every decision here has a reason. The `docker-compose.yml` sets `shm_size: 16g` because vLLM crashes without it. It sets `restart: unless-stopped` because GPU OOM or transient errors will crash the container. It uses `env_file: .env` instead of hardcoded values because the Hugging Face token is a secret. The `Dockerfile` uses multi-stage build so the final image doesn't contain build tools. It has `HEALTHCHECK` so Docker knows when to restart. The `deploy.resources` section reserves GPUs so other containers can't steal them. The logging driver with rotation (`max-size: 10m`, `max-file: 3`) prevents the disk from filling up with logs. Redis is on the same network for rate limiting across replicas. The `command` section passes vLLM flags with production-oriented defaults: `--enable-prefix-caching` for shared prompt prefixes, `--kv-cache-dtype` for memory efficiency, `--max-num-seqs 128` for high concurrency. The `server.py` is a thin launcher that delegates to `vllm serve` — in production you can replace it with the full programmatic server from Pattern 05.

Everything composes because each pattern was designed to work independently and together. You can scale this horizontally by adding more `vllm` services behind a load balancer or move to Kubernetes for multi-host orchestration.

**Dependency graph between patterns:**

```
01 (basic run) → 02 (custom Dockerfile) → 03 (env/volumes)
                                                     ↓
02 + 03 → 04 (production Dockerfile) → 06 (Docker Compose)
02 + 03 → 05 (Python library) → 10 (full stack)
04 + 05 + 06 + 03 → 10 (full stack)
```

**Production?** ✅ Yes — single-host production stack with all best practices.

---

## Quick Reference

| # | Pattern | Directory | What LLM Problem It Solves |
|---|---------|-----------|---------------------------|
| 01 | Basic Docker Run | `01-basic-docker-run/` | Containerize `vllm serve` |
| 02 | Custom Dockerfile | `02-custom-dockerfile/` | Pin versions, add custom code |
| 03 | Env & Volumes | `03-env-and-volumes/` | Secure tokens, cache models, local files |
| 04 | Production Dockerfile | `04-production-dockerfile/` | Fast rebuilds, small images, auto-recovery |
| 05 | Python vLLM Library | `05-python-vllm-library/` | Programmatic control, custom endpoints |
| 06 | Docker Compose | `06-docker-compose-stack/` | Multi-service stack (vLLM + Redis) |
| 10 | Full Production Stack | `10-full-production-stack/` | End-to-end production deployment |

---

## How These Patterns Build on Each Other

```
01 (basic docker run)
 ↓
02 (custom Dockerfile) ─────────────────────────────┐
 ↓                                                   │
03 (env vars & volumes)  ────────────────────────┐   │
 ↓                                                │   │
04 (production Dockerfile) ───┐                   │   │
 ↓                             │                   │   │
05 (python vLLM library) ──┐  │                   │   │
 ↓                          │  │                   │   │
06 (docker compose stack) ──┤  │                   │   │
 ↓                          │  │                   │   │
10 (full production stack) ◄──┴───┴───────────────────┘
```

Each pattern introduces one new concept. Pattern 10 combines them all. You can skip patterns you already know, but the numbered order is the recommended learning path.

---

### Test the API (any pattern)

```bash
curl http://localhost:8000/health
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```
