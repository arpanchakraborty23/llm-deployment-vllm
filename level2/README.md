Perfect. Your learning path makes sense:

* ✅ **Level 1:** Native Linux + `vllm serve` (completed)
* 🔜 **Level 2:** Docker (single container -> optimized)
* **Level 3:** Docker Compose
* **Level 4:** NGINX
* **Level 5:** Multi-GPU
* **Level 6:** Ray Serve
* **Level 7:** Kubernetes

For **Level 2**, don't just learn "Docker". Learn **Docker deployment patterns** from beginner to production.

---

# Level 2 — Docker Deployment (vLLM)

## Stage 1 — Run Official Image

No Dockerfile.

```bash
docker run --gpus all \
    -p 8000:8000 \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    vllm/vllm-openai:latest \
    --model Qwen/Qwen3-0.6B
```

**Why:** Fastest path to run vLLM in Docker. No Dockerfile, no build step, just one command. Proves GPU access from inside a container works.

**Requests it can handle:** ~10–50 concurrent (default conservative settings). With Qwen3-0.6B on a single GPU, expect ~500–1500 tokens/sec.

**Production?** ❌ No. Missing restart policy (container dies → down forever), no health check, logs only in terminal, model download repeats on every container recreate.

Architecture:

```
Host
 │
Docker
 │
vLLM
 │
GPU
```

---

## Stage 2 — Interactive Container

```bash
docker run -it --rm \
    --gpus all \
    vllm/vllm-openai:latest 
```

Inside container:

```bash
ls
pwd
python
nvidia-smi
```

**Why:** Inspect what's inside the vLLM image — filesystem layout, installed packages, Python environment, GPU driver availability. Essential before writing a custom Dockerfile so you know your base.

**Requests it handles:** N/A — not running a server. Pure debugging/inspection.

**Production?** ❌ No. `--rm` deletes container on exit. Learning only.

---

## Stage 3 — Custom Dockerfile

```dockerfile
FROM vllm/vllm-openai:latest

WORKDIR /app

COPY . .

RUN pip install -r requirements.txt

ENTRYPOINT ["vllm", "serve"]
CMD ["Qwen/Qwen3-0.6B", "--host", "0.0.0.0", "--port", "8000"]
```
```
# Build image
docker build -t vllm-docker:latest .

# Run image
docker run --gpus all -p 8000:8000 vllm-docker:latest
```

**Why:** The official image is generic and inflexible. A custom Dockerfile lets you add dependencies, custom code, pin versions, and set your own entrypoint. This is how you make the image your own.

**Requests it handles:** Same as Stage 1 — no tuning flags added yet. Throughput depends entirely on the `vllm serve` arguments passed at runtime or in CMD.

**Production?** ❌ Not by itself. Still missing resource limits, health checks, restart policies. But it is the **foundation** every production image builds on.

Learn: Docker layers, layer caching, COPY vs ADD, RUN instructions, CMD vs ENTRYPOINT.

---

## Stage 4 — Environment Variables

```bash
docker run \
    -e HUGGING_FACE_HUB_TOKEN=xxxxx
```

or use a `.env` file.

**Why:** Hardcoding tokens and secrets in the Dockerfile is insecure — anyone with image access gets your credentials. Env vars keep secrets outside the image, changeable at runtime without rebuilding.

**Requests it handles:** N/A — infra/security concern. No direct impact on throughput.

**Production?** ✅ Yes, mandatory. Always pass tokens at runtime. Combine with `--env-file` or your orchestrator's secret management.

Learn: Secrets management, runtime vs build-time config, `.env` files.

---

## Stage 5 — Named Volumes

```bash
docker volume create hf-cache

docker run ... -v hf-cache:/root/.cache/huggingface ...
```

**Why:** Model weights are 1–10+ GB. Without a named volume, every `docker run` re-downloads the model from Hugging Face. Named volumes persist across container lifecycles — download once, reuse forever.

**Requests it handles:** Indirect benefit — eliminates startup delay from model download (minutes → seconds). Higher availability during restarts.

**Production?** ✅ Yes, must-have for any real deployment. Combine with bind mounts for pre-downloaded models.

```
Container removed
Model still exists
```

---

## Stage 6 — Bind Mount

```bash
docker run ... -v /models:/models ... --model /models/Qwen3-0.6B
```

**Why:** Named volumes are Docker-managed. Bind mounts point to a host directory — useful for shared NAS, pre-downloaded model repositories, or when models live outside Docker's volume management.

**Requests it handles:** Same benefit as Stage 5 — faster startup, no re-download.

**Production?** ✅ Yes. Especially in enterprise where models are stored on shared filesystems or downloaded as a separate deployment step.

Learn: Host path mapping, shared model storage, offline deployment without Hugging Face.

---

## Stage 7 — Docker Network

```bash
docker network create llm-network
```

```
Redis
  |
Docker Network
  |
vLLM
  |
FastAPI
```

**Why:** A single container is limited. Production inference stacks need Redis (rate limiting, caching), a custom API gateway, monitoring, etc. Docker networks provide internal DNS so containers find each other by name instead of IP.

**Requests it handles:** Enables multi-service architecture. Without networking, you cannot scale beyond one container. With proper Redis-backed rate limiting, you can handle thousands of requests by distributing load.

**Production?** ✅ Yes, prerequisite for any multi-service production stack. Single-container deployments are toys.

Learn: Internal DNS resolution, service discovery, container-to-container communication.

---

## Stage 8 — Resource Limits

```bash
--memory=32g
--cpus=8
--gpus all
--shm-size=16g
```

**Why:** Without limits, a single container can consume all host memory (OOM kill), starve other containers of CPU, and crash the entire host. vLLM in particular needs large shared memory (`--shm-size`) for tensor parallelism and tokenization.

**Requests it handles:** Stabilizes throughput. With limits, vLLM has predictable resources — no spiky latency from memory pressure. For Qwen3-0.6B, `--memory=8g --shm-size=4g` is enough. Larger models need 32g+.

**Production?** ✅ Yes, mandatory. Never run production containers without resource constraints. Docker's default is unlimited — dangerous.

---

## Stage 9 — Restart Policies

```bash
--restart unless-stopped
```

or:

```
--restart always
```

**Why:** Containers crash — GPU out-of-memory, model loading failure, transient bugs. Without restart policy, the service stays down until someone manually runs `docker start`. `unless-stopped` auto-restarts unless you explicitly stopped it.

**Requests it handles:** Improves uptime and availability. No direct throughput impact, but a down container serves zero requests.

**Production?** ✅ Yes, mandatory. Combine with health checks (Stage 11) so Docker knows when to restart.

---

## Stage 10 — Logging

```bash
docker logs container        # view logs
docker logs -f container     # live tail
docker logs --tail 100       # last 100 lines
```

**Why:** When a container crashes or behaves unexpectedly, logs are your only clue. Docker captures stdout/stderr from the container — but by default, logs grow unbounded and fill the disk.

**Requests it handles:** N/A — observability. But log storms can degrade I/O performance on the host.

**Production?** ✅ Yes, mandatory. Add `--log-opt max-size=10m --log-opt max-file=3` to prevent disk fill. Forward logs to a central system (ELK, Loki) in production.

---

## Stage 11 — Health Check

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1
```

**Why:** Docker knows if the process is alive, but not if it is actually serving requests. A model might load partially and hang, or the API might be unresponsive despite the process running. HEALTHCHECK tells Docker the real status.

**Requests it handles:** Enables auto-recovery from stuck states. With restart policy (Stage 9), unhealthy → restart automatically. Load balancers also use health checks to route traffic only to healthy instances.

**Production?** ✅ Yes, mandatory. Without it, Docker restarts only on process crash, not on application-level failure.

Learn: Healthy vs Unhealthy, restart on unhealthy, integration with load balancers.

---

## Stage 12 — Optimize Dockerfile (Layer Caching)

Bad:

```
COPY .
RUN pip install
```

Good:

```
COPY requirements.txt
RUN pip install
COPY .
```

**Why:** Docker caches each layer. In the bad version, changing any source file invalidates the pip install layer — you reinstall packages on every build. The good version installs dependencies once, then only re-copies source code. Saves 1–5 minutes per rebuild.

**Requests it handles:** N/A — CI/CD build time optimization. No runtime impact.

**Production?** ✅ Yes, CI/CD best practice. Faster deploys = faster fixes in production.

---

## Stage 13 — Multi-stage Build

```dockerfile
FROM vllm/vllm-openai:latest AS builder
RUN pip install build-tools

FROM vllm/vllm-openai:latest AS runtime
COPY --from=builder /install /install
```

**Why:** Build tools (compilers, dev headers) are not needed at runtime. Multi-stage lets you build in one stage and copy only artifacts to the final stage. Result: smaller image, fewer vulnerabilities, faster pull times.

**Requests it handles:** N/A — image optimization. But smaller images = faster scaling in orchestrated environments.

**Production?** ✅ Yes, for custom images. Reduces attack surface and deployment time.

Learn: Builder → Runtime separation, COPY --from, image size reduction.

---

## Stage 14 — Image Size Optimization

Learn:

- Slim base images
- Remove apt cache (`rm -rf /var/lib/apt/lists/*`)
- Remove pip cache (`pip install --no-cache-dir`)
- Use `.dockerignore` to exclude unnecessary files

**Why:** Every unnecessary MB in an image slows down `docker pull` on production nodes. For a 10-node cluster, 1 GB extra = 10 GB wasted bandwidth and 30+ seconds slower rollouts.

**Requests it handles:** N/A — deployment speed optimization.

**Production?** ✅ Yes, especially in orchestrated environments where images are pulled frequently.

---

## Stage 15 — Production Run Command

```bash
docker run \
--gpus all \
-d \
-p 8000:8000 \
--restart unless-stopped \
--shm-size=16g \
-v hf-cache:/root/.cache/huggingface \
-e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
vllm/vllm-openai:latest \
--model Qwen/Qwen3-0.6B \
--gpu-memory-utilization 0.95 \
--max-model-len 8192
```

**Why:** Combines everything from stages 4, 5, 8, 9 into a single production-ready command. Detached (`-d`), auto-restarts, persistent cache, resource configured, API-tuned.

**Requests it handles:** ~50–100 concurrent. With Qwen3-0.6B and tuned settings, expect ~1000–3000 tokens/sec depending on GPU. Good for small-scale production, dev/QA, or single-user apps.

**Production?** ✅ Yes, for single-container deployments. This is the minimal viable production command. For multi-service or high-availability, move to Docker Compose (Level 3) or Kubernetes (Level 7).

---

## Stage 16 — Image Management

```bash
docker build -t my-vllm .
docker images
docker rmi IMAGE_ID
docker tag my-vllm my-registry/my-vllm:latest
docker push my-registry/my-vllm
```

**Why:** Running from local build does not scale to teams. Images must be versioned, tagged, pushed to a registry, and pulled on production hosts. This is the CI/CD pipeline — build once, deploy everywhere.

**Requests it handles:** N/A — DevOps/CI. No runtime throughput impact.

**Production?** ✅ Yes, mandatory for team workflows. Single-developer projects can skip the registry.

---

## Stage 17 — Container Management

```bash
docker run
docker stop
docker start
docker restart
docker rm
docker exec -it
```

**Why:** Containers are ephemeral. You need to stop misbehaving containers, restart after config changes, exec in for debugging, and clean up unused ones. These are the everyday commands.

**Requests it handles:** N/A — operations. No throughput impact.

**Production?** ✅ Yes, indispensable. Every production engineer uses these daily.

---

## Stage 18 — Debugging

```bash
docker inspect
docker stats
docker top
docker exec -it container bash
```

**Why:** When things go wrong in production, you need to inspect container config, check resource usage in real-time, see running processes, and explore the filesystem. These are your debugging toolkit.

**Requests it handles:** N/A — debugging/monitoring. No direct throughput impact.

**Production?** ✅ Yes, essential. Every production incident starts with these commands.

---

## Stage 19 — Performance Tuning

Learn:

- GPU reservation (`--gpus all` vs specific devices)
- Huge shared memory (`--shm-size`)
- Persistent Hugging Face cache
- Local model mounts (avoid re-download)
- CPU pinning (`--cpuset-cpus`)
- Container log rotation (`--log-opt`)
- Proper restart policies

**Why:** Default Docker and vLLM settings are conservative. Tuning can double your throughput. CPU pinning reduces context-switching latency. Log rotation prevents disk-full crashes. Each tuning parameter improves either performance or reliability.

**Requests it handles:** Up to 2x improvement vs default settings. With all tuning applied, Qwen3-0.6B on one GPU can handle ~100–200 concurrent requests at 2000–4000 tokens/sec.

**Production?** ✅ Yes. Tuning separates a toy deployment from a production-grade one.

---

## Stage 20 — Production Pattern

```
                 Docker Host

        +--------------------------+
        |                          |
        |     vLLM Container        |
        |                          |
        |   HuggingFace Cache       |
        |                          |
        +--------------------------+
                   |
           NVIDIA Container Runtime
                   |
               Tesla T4 / A10G
```

**Requests it handles:** ~100–200 concurrent, 2000–4000 tokens/sec (Qwen3-0.6B on single GPU). This is the ceiling for single-container Docker deployment without orchestration.

**Production?** ✅ Yes for low-to-medium traffic. For higher scale, add load balancing (Level 4: NGINX), multi-GPU (Level 5), Ray Serve (Level 6), or Kubernetes (Level 7).

---

## Skills Summary

| Stage | Skill | Problem Solved | Production Ready |
|-------|-------|---------------|:----------------:|
| 1 | Docker basics | First container with GPU | ❌ |
| 2 | Interactive containers | Inspect image internals | ❌ |
| 3 | Dockerfile creation | Reproducible custom images | ❌ |
| 4 | Environment variables | Secrets management | ✅ |
| 5 | Persistent volumes | Model download once | ✅ |
| 6 | Local model mounting | Offline/enterprise models | ✅ |
| 7 | Docker networking | Multi-service communication | ✅ |
| 8 | Resource management | Prevent OOM / host crash | ✅ |
| 9 | Restart policies | Auto-recovery after crash | ✅ |
| 10 | Logging | Debug production issues | ✅ |
| 11 | Health checks | Detect stuck/unhealthy state | ✅ |
| 12 | Layer caching | Faster CI/CD builds | ✅ |
| 13 | Multi-stage builds | Smaller, more secure images | ✅ |
| 14 | Image optimization | Faster deploy, less disk | ✅ |
| 15 | Production deployment | Single-container prod | ✅ |
| 16 | Image lifecycle | Team CI/CD workflow | ✅ |
| 17 | Container lifecycle | Daily operations | ✅ |
| 18 | Debugging/monitoring | Incident response | ✅ |
| 19 | Performance tuning | Maximize throughput | ✅ |
| 20 | Production-ready pattern | End-to-end deployment | ✅ |

---

## Practice Files in `patterns/`

Each subdirectory contains the files you need to build and run. Type every command yourself.

| # | Directory | README Stage | File(s) | Commands to type |
|---|-----------|-------------|---------|-----------------|
| 01 | `patterns/01-official-image/` | Stage 1 | *(none -- use official image)* | `docker run --gpus all -p 8000:8000 -v ~/.cache/huggingface:/root/.cache/huggingface vllm/vllm-openai:latest --model Qwen/Qwen3-0.6B` |
| 02 | `patterns/02-custom-dockerfile/` | Stage 3 | `Dockerfile`, `requirements.txt` | `docker build -t my-vllm patterns/02-custom-dockerfile`<br>`docker run --gpus all -p 8000:8000 my-vllm --model Qwen/Qwen3-0.6B` |
| 03 | `patterns/03-optimized-build/` | Stage 12 | `Dockerfile`, `requirements.txt` | Same as 02, but notice the `COPY` order in the Dockerfile |
| 04 | `patterns/04-multi-stage/` | Stage 13 | `Dockerfile`, `requirements-builder.txt`, `server.py` | `docker build -t my-vllm:multistage patterns/04-multi-stage`<br>`docker run --gpus all -p 8000:8000 my-vllm:multistage --model Qwen/Qwen3-0.6B` |
| 05 | `patterns/05-production/` | Stage 11+15 | `Dockerfile`, `entrypoint.sh` | `docker build -t my-vllm:prod patterns/05-production`<br>`docker run --gpus all -d -p 8000:8000 --restart unless-stopped --shm-size=16g -v hf-cache:/root/.cache/huggingface -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN my-vllm:prod --model Qwen/Qwen3-0.6B --gpu-memory-utilization 0.95 --max-model-len 8192` |
| 06 | `patterns/06-custom-server/` | Stage 3+7 | `Dockerfile`, `server.py`, `requirements.txt` | `docker build -t my-vllm:custom patterns/06-custom-server`<br>`docker run --gpus all -p 8000:8000 my-vllm:custom --model Qwen/Qwen3-0.6B`<br>`curl http://localhost:8000/metrics` |
| 07 | `patterns/07-bind-mount/` | Stage 6 | *(empty -- just a dir)* | `huggingface-cli download Qwen/Qwen3-0.6B --local-dir /models/Qwen3-0.6B`<br>`docker run --gpus all -p 8000:8000 -v /models:/models vllm/vllm-openai:latest --model /models/Qwen3-0.6B` |
| 08 | `patterns/08-networked/` | Stage 7 | `docker-compose.yml` | `cd patterns/08-networked`<br>`docker compose up -d`<br>`docker compose logs -f` |
| 09 | `patterns/09-resource-limited/` | Stage 8+9 | *(empty -- just a dir)* | `docker run --gpus all -d -p 8000:8000 --name vllm-limited --restart unless-stopped --cpus="8" --memory="32g" --shm-size="16g" --log-opt max-size="10m" -v hf-cache:/root/.cache/huggingface -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN vllm/vllm-openai:latest --model Qwen/Qwen3-0.6B --gpu-memory-utilization 0.95 --max-model-len 8192 --max-num-seqs 64` |

### Test the API

```powershell
curl http://localhost:8000/health
curl http://localhost:8000/v1/models
Invoke-RestMethod -Uri http://localhost:8000/v1/chat/completions `
  -Method Post `
  -Body '{"model":"","messages":[{"role":"user","content":"hello"}],"max_tokens":10}' `
  -ContentType "application/json"
```

```bash
curl http://localhost:8000/health
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```
