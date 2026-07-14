# LiteLLM CLI Commands — Complete Reference

LiteLLM is an AI gateway that provides a single OpenAI-compatible API for 100+ LLM providers. This document covers every CLI command, what it does, and how it works.

## Installation

```powershell
uv tool install 'litellm[proxy]'
pip install 'litellm[proxy]'
docker pull ghcr.io/berriai/litellm:latest
```

## Server Configuration

### `--host`

**What it does:** Binds the proxy to a specific network interface.

**How it works:** Passed to uvicorn as the `host` parameter. Controls which IP addresses the server listens on.

| Value | Effect |
|-------|--------|
| `0.0.0.0` | All interfaces (default) |
| `127.0.0.1` | Localhost only |

```bash
litellm --host 127.0.0.1
```

**Env:** `HOST`

---

### `--port`

**What it does:** Sets the TCP port.

**Default:** `4000`

```bash
litellm --port 8080
```

**Env:** `PORT`

---

### `--num_workers`

**What it does:** Number of worker processes for parallel request handling.

**How it works:** Spawns multiple uvicorn/gunicorn workers. Each runs a copy of the app. If one crashes, others keep serving. Higher values improve throughput on multi-core machines.

**Default:** Number of logical CPUs, or `4`

```bash
litellm --num_workers 4
```

**Env:** `NUM_WORKERS`

---

### `--config` / `-c`

**What it does:** Loads models and settings from a YAML file.

**How it works:** On startup, LiteLLM reads `model_list` from the YAML and registers each model. The `model_name` field is the user-facing alias; `litellm_params` contains the provider, API key, and base URL. Incoming requests are matched by the `model` field in the request body to `model_name` in the config.

```bash
litellm --config /app/config.yaml
```

---

### `--log_config`

**What it does:** Path to a uvicorn logging configuration file.

```bash
litellm --log_config path/to/log_config.conf
```

---

### `--keepalive_timeout`

**What it does:** Seconds uvicorn keeps idle HTTP connections open.

**How it works:** Maps to uvicorn's `timeout_keep_alive`. Closes connections that send no data within the window.

```bash
litellm --keepalive_timeout 30
```

**Env:** `KEEPALIVE_TIMEOUT`

---

### `--max_requests_before_restart`

**What it does:** Restarts a worker after N requests.

**How it works:** Mitigates Python memory growth over time. Each worker counts requests and exits at the limit; the main process spawns a replacement.

```bash
litellm --max_requests_before_restart 10000
```

**Env:** `MAX_REQUESTS_BEFORE_RESTART`

---

### `--max_requests_before_restart_jitter`

**What it does:** Random jitter so workers don't restart simultaneously.

```bash
litellm --max_requests_before_restart 10000 --max_requests_before_restart_jitter 1000
```

**Env:** `MAX_REQUESTS_BEFORE_RESTART_JITTER`

---

## Server Backend Options

### `--run_gunicorn`

**What it does:** Uses gunicorn instead of uvicorn.

**Why:** Gunicorn has better process management for production — pre-fork model, graceful shutdown, worker timeouts.

**Type:** Flag

```bash
litellm --run_gunicorn
```

---

### `--run_hypercorn`

**What it does:** Uses hypercorn instead of uvicorn (supports HTTP/2).

**Type:** Flag

```bash
litellm --run_hypercorn
```

---

### `--run_granian`

**What it does:** Uses Granian (Rust-backed ASGI server). **Beta.**

**Why:** Moves HTTP handling into Rust. ~10–20 RPS improvement over uvicorn in LiteLLM load tests. Better stability under sustained load.

**Limitations:**
- `--max_requests_before_restart` not supported
- `--ciphers` not applied
- `--keepalive_timeout` and `--log_config` ignored

```bash
litellm --config config.yaml --run_granian --num_workers 4
```

---

### `--skip_server_startup`

**What it does:** Runs setup/db migrations without starting the server.

**Type:** Flag

```bash
litellm --skip_server_startup
```

---

## SSL/TLS

### `--ssl_keyfile_path`

Path to SSL private key.

```bash
litellm --ssl_keyfile_path /path/to/key.pem --ssl_certfile_path /path/to/cert.pem
```

**Env:** `SSL_KEYFILE_PATH`

---

### `--ssl_certfile_path`

Path to SSL certificate.

```bash
litellm --ssl_certfile_path /path/to/cert.pem --ssl_keyfile_path /path/to/key.pem
```

**Env:** `SSL_CERTFILE_PATH`

---

### `--ciphers`

Allowed TLS cipher suites (only with `--run_hypercorn`).

```bash
litellm --run_hypercorn --ssl_keyfile_path key.pem --ssl_certfile_path cert.pem --ciphers "ECDHE+AESGCM"
```

---

## Model Configuration

### `--model` / `-m`

**What it does:** Specifies the model (provider + model name).

**How it works:** The prefix before `/` determines the provider:

| Prefix | Provider |
|--------|----------|
| `openai/` | OpenAI |
| `azure/` | Azure OpenAI |
| `anthropic/` | Anthropic |
| `vertex_ai/` | Google Vertex AI |
| `bedrock/` | AWS Bedrock |
| `vllm/` | vLLM |
| `ollama/` | Ollama |
| `huggingface/` | HuggingFace TGI |
| `together_ai/` | Together AI |
| `replicate/` | Replicate |
| `openai/` + `api_base` | Any OpenAI-compatible endpoint |

```bash
litellm --model gpt-4o-mini
litellm --model claude-sonnet-4-20250514
litellm --model vertex_ai/gemini-2.0-flash-001
litellm --model bedrock/anthropic.claude-v2
litellm --model azure/gpt-4o-deployment
litellm --model vllm/Qwen/Qwen3-0.6B
litellm --model ollama/llama3.2
litellm --model openai/my-model --api_base http://localhost:8000/v1
```

---

### `--alias`

**What it does:** Friendly name for a complex model identifier.

```bash
litellm --model huggingface/codellama/CodeLlama-7b-Instruct-hf --alias codellama
```

---

### `--api_base`

**What it does:** Overrides the provider's default API base URL.

**Required for:** vLLM, Ollama, TGI, custom endpoints.

```bash
litellm --model vllm/Qwen3-0.6B --api_base http://localhost:8000/v1
```

---

### `--api_version`

API version for Azure OpenAI. **Default:** `2024-07-01-preview`

```bash
litellm --model azure/gpt-deployment --api_version 2023-08-01 --api_base https://your-base.openai.azure.com
```

---

### `--headers`

Custom HTTP headers for provider API calls (JSON string).

```bash
litellm --model my-model --headers '{"Authorization": "Bearer custom-token"}'
```

---

### `--add_key`

Add an API key to the model config.

```bash
litellm --add_key my-api-key
```

---

### `--save`

Persists CLI-specified model config to disk.

**Type:** Flag

```bash
litellm --model gpt-4o-mini --save
```

---

## Model Parameters

| Flag | Type | Default | Purpose |
|------|------|---------|---------|
| `--temperature` | float | — | Response randomness (0.0–2.0) |
| `--max_tokens` | int | — | Max output token count |
| `--request_timeout` | int | — | Timeout in seconds |
| `--max_budget` | float | — | Max spend budget in USD |
| `--drop_params` | flag | — | Drop unsupported provider params |
| `--add_function_to_prompt` | flag | — | Serialize functions as prompt text |

```bash
litellm --temperature 0.7 --max_tokens 2048 --request_timeout 300 --max_budget 100.0
```

---

## Database

### `--iam_token_db_auth`

IAM token auth for AWS RDS (instead of password).

**Requires env:** `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_NAME`

**Type:** Flag

```bash
litellm --iam_token_db_auth
```

---

### `--use_prisma_db_push`

Uses `prisma db push` (direct sync) instead of `prisma migrate` (versioned files).

**Type:** Flag

```bash
litellm --use_prisma_db_push
```

---

## Debugging

| Flag | Env Variable | What It Shows |
|------|-------------|---------------|
| `--debug` | `DEBUG=True` | Request/response details, routing decisions |
| `--detailed_debug` | `DETAILED_DEBUG=True` | Full tracing — config loading, model matching, provider selection, timing |
| `--local` | — | Local development mode (relaxed CORS, etc.) |

```bash
litellm --detailed_debug
# or
$env:DETAILED_DEBUG = "True"
litellm
```

---

## Testing & Health

### `--test`

Sends a test chat completion to verify the proxy works.

**Type:** Flag

```bash
litellm --model gpt-4o-mini
litellm --test
```

---

### `--test_async`

Tests async queue endpoints (`/queue/requests`, `/queue/response`). Used with `--use_queue`.

**Type:** Flag

---

### `--num_requests`

Number of test requests for `--test_async`. **Default:** `10`

```bash
litellm --test_async --num_requests 100
```

---

### `--health`

Runs health check against all models in config.yaml. Reports pass/fail per model.

**Type:** Flag

```bash
litellm --health
```

---

## Other

| Flag | Purpose |
|------|---------|
| `--version` / `-v` | Print version and exit |
| `--telemetry False` | Disable anonymous usage telemetry |
| `--use_queue` | Enable Celery workers for async requests |

---

## Interactive Setup

### `--setup`

**What it does:** Launches an interactive wizard that walks you through provider selection, API key entry, and config generation. No manual YAML editing.

```bash
litellm --setup
```

---

## Proxy Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/chat/completions` | POST | Chat completions |
| `/completions` | POST | Text completions |
| `/embeddings` | POST | Text embeddings |
| `/models` | GET | List available models |
| `/health` | GET | Health check |
| `/key/generate` | POST | Create virtual API key |
| `/key/list` | GET | List virtual keys |
| `/team/new` | POST | Create team |
| `/spend/logs` | GET | View spend logs |
| `/ui` | GET | Admin dashboard |
| `/` | GET | Swagger API docs |

---

## Docker Run Patterns

### Standalone (no DB)

```powershell
docker run -d -p 4000:4000 `
  -v ${PWD}/config.yaml:/app/config.yaml `
  -e OPENAI_API_KEY=sk-xxx `
  -e LITELLM_MASTER_KEY=sk-1234 `
  ghcr.io/berriai/litellm:latest `
  --config /app/config.yaml --detailed_debug
```

### With Postgres (virtual keys + UI auth)

```powershell
docker run -d -p 4000:4000 `
  -v ${PWD}/config.yaml:/app/config.yaml `
  -e LITELLM_MASTER_KEY=sk-1234 `
  -e LITELLM_SALT_KEY=sk-salt `
  -e DATABASE_URL=postgresql://user:pass@host:5432/litellm `
  -e OPENAI_API_KEY=sk-xxx `
  ghcr.io/berriai/litellm-database:latest `
  --config /app/config.yaml
```

---

## How Routing Works

```
Client sends:                    LiteLLM looks up:
POST /chat/completions           model_list:
  model: "gpt-4o"      ──────▶    - model_name: "gpt-4o"  ✓
  messages: [...]                    litellm_params:
                                     model: openai/gpt-4o
                                     api_key: sk-xxx
                                           │
                                           ▼
                              Provider API:
                              POST https://api.openai.com/v1/chat/completions
                                model: gpt-4o
                                messages: [...]
```

1. Client sends `model: "gpt-4o"` in request body
2. LiteLLM matches `model_name` in `model_list`
3. Extracts `litellm_params` — full model string, API key, base URL
4. Routes to the appropriate provider
5. Returns provider response in OpenAI format

---

## Virtual Keys

```bash
# Generate a key with 10 RPM and $50 budget
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer sk-1234" \
  -H "Content-Type: application/json" \
  -d '{"rpm_limit": 10, "max_budget": 50.0}'

# Response: {"key": "sk-abc123...", ...}
```

Virtual keys enable:
- Per-key rate limits (RPM/TPM)
- Budget caps
- Model access restrictions
- Independent spend tracking
