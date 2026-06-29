# Level 2 — LLM Deployment with Docker

You know how to run `vllm serve` natively (Level 1). Now package it in Docker.

**Goal:** Learn 7 deployment patterns — from "just run the official image" to "multi-service stack with observability."

Each pattern solves a real LLM deployment problem and lives in `patterns/XX-name/`. Docker is the vehicle, not the focus.

---

## What We Built — The Journey

Over 7 patterns, we took a raw `vllm serve` command and built a production-ready LLM inference platform with observability.

```
Native vLLM          → Pattern 01:        → Pattern 02:        → Pattern 03:
vllm serve Qwen3     Basic Docker Run     Custom Dockerfile    Env & Volumes
(runs on host)        (containerize it)    (pin deps)           (tokens + cache)

                          → Pattern 04:        → Pattern 05:        → Pattern 06:
                          Production DF        Python vLLM Lib      Docker Compose
                          (healthcheck,        (programmatic        (vLLM + Open WebUI)
                           multi-stage)         control + metrics)

                              → Pattern 07:
                              Prometheus + Grafana
                              (observability stack)
```

Here is what each layer contributed:

| Layer | What It Added | Why It Matters |
|-------|--------------|----------------|
| **Pattern 01** | `docker run` with GPU passthrough | The foundation — you can't deploy without containerizing |
| **Pattern 02** | Custom `Dockerfile` with pinned versions | Reproducible builds — no surprise version changes |
| **Pattern 03** | Named volumes + environment variables | Secrets never hardcoded, models not re-downloaded |
| **Pattern 04** | Multi-stage, HEALTHCHECK, non-root user | Production-grade image — self-healing, secure, lean |
| **Pattern 05** | `AsyncLLMEngine` + custom FastAPI server | Programmatic control — custom metrics, auth, scheduling |
| **Pattern 06** | Docker Compose — vLLM + Open WebUI | Multi-service orchestration — chat UI + inference |
| **Pattern 07** | Prometheus + Grafana | Observability — dashboards for throughput, latency, GPU |

The final stack (Pattern 07) is a 4-container system: **vLLM** serves the model, **Open WebUI** provides the chat interface, **Prometheus** scrapes metrics every 15 seconds, and **Grafana** renders real-time dashboards. This is the same architectural pattern used by production inference platforms — just simplified for learning.

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

**Problem:** Production inference needs more than just vLLM — you need a chat UI for users, shared networking, and health orchestration.

**Directory:** `patterns/06-docker-compose-stack/`

```bash
cd patterns/06-docker-compose-stack
docker compose up -d
```

Services defined in `docker-compose.yml`:

| Service | Purpose |
|---------|---------|
| **vLLM** | Inference engine serving OpenAI-compatible API |
| **Open WebUI** | ChatGPT-style chat interface for users |

**What you learn:** Service discovery (internal DNS), health dependencies (`depends_on` + `condition`), Docker networks, compose file structure, GPU reservations via `deploy.resources`, multi-service volumes.

**Explanation:** Docker Compose replaces running separate `docker run` commands and wiring them together manually. vLLM loads the model and exposes an OpenAI-compatible API on port 8000. Open WebUI connects to `http://vllm:8000/v1` — Docker's internal DNS resolves the hostname `vllm` automatically. The `depends_on` with `condition: service_healthy` ensures Open WebUI waits for vLLM to finish loading the model before starting. Without this, Open WebUI starts immediately and shows connection errors until the model is ready (could be minutes for large models). The `shm_size: 16g` flag is critical for vLLM — it allocates shared memory for tokenizer parallelism and tensor parallelism communication. Insufficient `--shm-size` causes cryptic crashes during model loading. The `deploy.resources.reservations.devices` section reserves NVIDIA GPUs — this is the Compose-native equivalent of `--gpus all`. The `hf-cache` named volume persists model weights across container restarts. The `open-webui` named volume persists chat history and user accounts. Both services are on the `llm-net` bridge network, providing DNS-based service discovery. Open WebUI also handles RAG (document upload, search) and supports markdown rendering, code highlighting, and image generation if configured. This pattern is the culmination of everything learned in patterns 01–05: custom Dockerfile, env vars, volumes, HEALTHCHECK, resource management — all composed together.

**Production?** ✅ Yes — single-host production starts here.

---

## Pattern 07 — Deployment Monitoring (Prometheus + Grafana)

**Problem:** You have a multi-service stack (Pattern 06), but you're flying blind. No visibility into request throughput, token generation speed, GPU memory pressure, or latency. When something breaks, you have zero historical data to debug.

**Directory:** `patterns/07-deployment-monitering/`

```bash
cd patterns/07-deployment-monitering
docker compose up -d
```

Services defined in `compose.yml`:

| Service | Port | Purpose |
|---------|------|---------|
| **vLLM** | `:8000` | Inference engine with built-in `/metrics` endpoint |
| **Open WebUI** | `:3000` | ChatGPT-style chat interface for users |
| **Prometheus** | `:9090` | Time-series database — scrapes vLLM metrics every 15 seconds |
| **Grafana** | `:3001` | Dashboard UI — auto-configured with LLM metrics dashboard |

**What you learn:** Prometheus scrape config, Grafana provisioning, PromQL queries (rate, histogram_quantile), observability patterns, metric types (counter, gauge, histogram), the USE method (Utilization, Saturation, Errors) applied to LLM inference.

**Files provided in `patterns/07-deployment-monitering/`:**

| File | Purpose |
|------|---------|
| `compose.yml` | Multi-service stack with vLLM, Open WebUI, Prometheus, Grafana |
| `prometheus/prometheus.yml` | Scrape config — targets vLLM at `:8000/metrics` every 15s |
| `grafana/datasources/datasource.yml` | Auto-provisions Prometheus as Grafana data source |
| `grafana/dashboards/dashboard.yml` | Auto-imports dashboards from JSON files on startup |
| `grafana/dashboards/llm-metrics.json` | 6-panel dashboard: request rate, token throughput, active/waiting requests, GPU cache usage, TTFT P90, E2E latency P50/P95/P99 |

**Explanation:** Pattern 06 solved the problem of running multiple services together, but a deployed LLM is still a black box. You don't know if the GPU is near capacity, if latency is degrading, or if throughput is dropping. Pattern 07 solves this by adding the standard observability stack — Prometheus + Grafana — on top of the existing vLLM + Open WebUI setup.

The key insight is that **vLLM already exposes Prometheus metrics** at `/metrics` on port 8000. You don't need to instrument your code or add a metrics library. The `/metrics` endpoint outputs hundreds of metrics covering request counts, token throughput (split into prompt and generation), latency histograms (time-to-first-token and end-to-end), GPU KV-cache usage, and scheduler state.

**Prometheus** (`prom/prometheus:latest`) is configured via `prometheus.yml` to scrape `http://vllm:8000/metrics` every 15 seconds. The config file is bind-mounted as read-only so Prometheus picks it up immediately. Metric data is stored in the `prometheus-data` named volume with 30-day retention. Prometheus waits for vLLM's health check to pass before scraping — no empty metrics during model loading.

**Grafana** (`grafana/grafana:latest`) auto-configures itself using provisioning files. The `datasources/datasource.yml` creates a Prometheus data source pointing at `http://prometheus:9090`. The `dashboards/` directory contains a JSON dashboard (`llm-metrics.json`) that Grafana imports automatically on startup. The dashboard has 6 panels across two rows:

- **Row 1 (overview):** Request rate (req/s), token throughput split by prompt/generation, active vs waiting request count
- **Row 2 (resource + latency):** GPU cache usage gauge with color thresholds, P90 time-to-first-token, and E2E latency at P50/P95/P99

Default Grafana login is `admin / admin`. The port is mapped to `:3001` to avoid conflicting with Open WebUI on `:3000`.

**Production?** ✅ Yes — this is the standard observability stack for LLM deployments. In production you would additionally add Loki (logs), Alertmanager (alerts), and Tempo (tracing).

---

## Quick Reference

| # | Pattern | Directory | What LLM Problem It Solves |
|---|---------|-----------|---------------------------|
| 01 | Basic Docker Run | `01-basic-docker-run/` | Containerize `vllm serve` |
| 02 | Custom Dockerfile | `02-custom-dockerfile/` | Pin versions, add custom code |
| 03 | Env & Volumes | `03-env-and-volumes/` | Secure tokens, cache models, local files |
| 04 | Production Dockerfile | `04-production-dockerfile/` | Fast rebuilds, small images, auto-recovery |
| 05 | Python vLLM Library | `05-python-vllm-library/` | Programmatic control, custom endpoints |
| 06 | Docker Compose | `06-docker-compose-stack/` | Multi-service stack (vLLM + Open WebUI) |
| 07 | Deployment Monitoring | `07-deployment-monitering/` | Observability with Prometheus + Grafana |

---

## How These Patterns Build on Each Other

```
01 (basic docker run)
 ↓
02 (custom Dockerfile)
 ↓
03 (env vars & volumes)
 ↓
04 (production Dockerfile)
 ↓
05 (python vLLM library)
 ↓
06 (docker compose stack)
 ↓
07 (deployment monitoring)
```

Each pattern introduces one new concept and builds on the previous. Pattern 06 combines everything — custom Dockerfile, env vars, volumes, HEALTHCHECK, resource management, and a chat UI — all composed together. Pattern 07 adds observability on top of the stack so you can see what's happening inside the black box. Skip what you know, but the numbered order is the recommended learning path.

---

### Test the API (any pattern)

```bash
curl http://localhost:8000/health
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```
