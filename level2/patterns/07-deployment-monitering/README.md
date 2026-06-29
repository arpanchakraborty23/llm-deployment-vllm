# Pattern 07 — Deployment Monitoring (Prometheus + Grafana)

**Problem:** You deployed vLLM with Docker Compose (Pattern 06). Users chat with the model through Open WebUI. But you're flying blind — you have no idea how the system is performing. Is the GPU memory full? Are requests timing out? Is token throughput dropping? When something breaks, you have no data to debug.

**Solution:** Add observability — collect metrics from vLLM, store them in a time-series database, and visualize them on a dashboard.

**Directory:** `patterns/07-deployment-monitering/`

```bash
cd patterns/07-deployment-monitering
docker compose up -d
```

---

## How It Works

```
┌──────────┐   HTTP /metrics    ┌───────────┐   PromQL queries    ┌──────────┐
│   vLLM   │ ──────────────────►│ Prometheus │ ◄───────────────────│  Grafana │
│  :8000   │   scrape every 15s │   :9090    │                     │  :3001   │
└──────────┘                    └───────────┘                     └──────────┘
```

The data flow is one-directional:

1. **vLLM** exposes a `/metrics` endpoint with hundreds of Prometheus-formatted metrics — requests, tokens, latencies, GPU cache, scheduler state, and more. This is built into vLLM; you don't need to add any code.

2. **Prometheus** scrapes that endpoint every 15 seconds and stores the metric values as time-series data on disk. It acts as the single source of truth for historical performance data.

3. **Grafana** queries Prometheus using PromQL (Prometheus Query Language) and renders the data as interactive graphs and gauges on a dashboard. The dashboard is pre-configured and auto-imported on startup — you don't need to click around to set it up.

---

## Services

| Service | Container Name | Host Port | Purpose |
|---------|---------------|-----------|---------|
| **vLLM** | `llm-vllm` | `:8000` | Inference engine with built-in `/metrics` |
| **Open WebUI** | `openweb-ui` | `:3000` | Chat interface (same as Pattern 06) |
| **Prometheus** | `llm-prometheus` | `:9090` | Time-series database, scrapes and stores metrics |
| **Grafana** | `llm-grafana` | `:3001` | Dashboard UI, queries Prometheus and visualizes |

**Why ports 3001 instead of 3000?** Open WebUI already uses port 3000. Grafana's default is also 3000, so we map it to 3001 to avoid conflict. You access Grafana at `http://localhost:3001`.

---

## What Each File Does

### `compose.yml` — Service Definitions

Extends Pattern 06 with two new services:

**Prometheus** (`prom/prometheus:latest`):
- Mounts `prometheus/prometheus.yml` as a read-only config file at `/etc/prometheus/prometheus.yml` — this tells Prometheus where to scrape
- Uses `prometheus-data` volume to persist metric data across restarts (30-day retention)
- Depends on vLLM's health check — Prometheus starts scraping only after the model is loaded
- Starts with `--storage.tsdb.retention.time=30d` to keep 30 days of history

**Grafana** (`grafana/grafana:latest`):
- Mounts `grafana/datasources/` to `/etc/grafana/provisioning/datasources/` — auto-configures the Prometheus data source so Grafana knows where to find metrics
- Mounts `grafana/dashboards/` to `/etc/grafana/provisioning/dashboards/` — auto-imports the LLM dashboard on startup
- Uses `grafana-data` volume to persist dashboards, users, and settings
- Sets default credentials via environment variables (`admin / admin`)
- Depends on Prometheus being started (not healthy — Grafana works even if Prometheus has no data yet)

### `prometheus/prometheus.yml` — Scrape Configuration

```yaml
scrape_configs:
  - job_name: vllm
    static_configs:
      - targets: ["vllm:8000"]
    metrics_path: /metrics
```

Defines two scrape jobs:
- **vLLM**: Prometheus scrapes `http://vllm:8000/metrics` every 15 seconds. Docker DNS resolves `vllm` to the vLLM container's internal IP.
- **Prometheus itself**: Scrapes `localhost:9090/metrics` for Prometheus's own health (used for debugging Prometheus itself).

The `scrape_interval: 15s` means every 15 seconds Prometheus walks through every target and pulls all metric values. A 15-second interval is standard for infrastructure monitoring — fast enough to catch spikes, slow enough to avoid excessive storage. You can lower to `5s` for high-frequency debugging or raise to `60s` to reduce storage costs.

### `grafana/datasources/datasource.yml` — Data Source Auto-Provisioning

```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
```

This file tells Grafana: "When you start, create a Prometheus data source pointing at `http://prometheus:9090` and make it the default." Without this, you'd have to manually add the Prometheus data source in the Grafana UI after every container restart. The `isDefault: true` flag means any dashboard that needs a data source automatically uses this one — no manual assignment needed.

### `grafana/dashboards/dashboard.yml` — Dashboard Provider

```yaml
providers:
  - name: LLM Metrics
    folder: LLM
    type: file
    options:
      path: /etc/grafana/dashboards
```

This is the dashboard provider config. It tells Grafana: "Watch the directory `/etc/grafana/dashboards` for JSON dashboard files and import them automatically." The `folder: LLM` setting organizes the dashboard under a dedicated folder in Grafana's sidebar. The `disableDeletion: true` prevents accidental deletion of the auto-imported dashboard.

### `grafana/dashboards/llm-metrics.json` — The Dashboard

A Grafana dashboard is a JSON document that describes panels, their positions, queries, and visual settings. This dashboard has 6 panels:

#### Row 1: System Overview (top row)

| Panel | Type | Query | What It Shows |
|-------|------|-------|---------------|
| **Request Rate** | Time series | `rate(vllm:num_requests_total[1m])` | How many requests per second the system is handling. Spikes = load, flatline = idle. |
| **Token Throughput** | Time series | `rate(vllm:prompt_tokens_total[1m])` and `rate(vllm:generation_tokens_total[1m])` | How many tokens are consumed per second, split into prompt (input) and generation (output) tokens. Generation tokens/sec is the key measure of inference throughput. |
| **Active & Waiting** | Time series | `vllm:num_requests_running` and `vllm:num_requests_waiting` | Currently active requests vs. requests queued in the scheduler. When waiting exceeds running, you need more GPU capacity or better batching. |

#### Row 2: Resource & Latency (bottom row)

| Panel | Type | Query | What It Shows |
|-------|------|-------|---------------|
| **GPU Cache Usage** | Gauge | `vllm:gpu_cache_usage_perc` | Percentage of GPU KV-cache used. Green < 70%, yellow 70–90%, red > 90%. Near 100% means the model is at maximum context capacity — older requests get evicted. |
| **Time to First Token (P90)** | Time series | `histogram_quantile(0.9, rate(vllm:time_to_first_token_seconds_bucket[5m]))` | P90 time-to-first-token — the time from receiving a request to generating the first token. High TTFT indicates prompt processing bottlenecks. |
| **E2E Latency (P50/P95/P99)** | Time series | `histogram_quantile(0.5/0.95/0.99, rate(vllm:e2e_request_latency_seconds_bucket[5m]))` | End-to-end request latency at the 50th, 95th, and 99th percentiles. The gap between P50 and P99 shows tail latency — if P99 is much higher than P50, some requests are getting stuck. |

**What's PromQL?** The queries use PromQL (Prometheus Query Language). `rate(counter[1m])` calculates the per-second rate of a counter over a 1-minute window. `histogram_quantile(0.95, ...)` calculates the 95th percentile from histogram buckets. You can edit these queries directly in Grafana to create custom panels.

---

## What Is Prometheus?

Prometheus is a time-series database. Unlike a traditional SQL database that stores rows and columns, Prometheus stores `(timestamp, value)` pairs identified by metric names and labels.

**Why not just use logs?** Logs tell you about individual events ("request 123 failed with error X"). Metrics tell you about system behavior over time ("error rate increased from 0.1% to 5% at 14:30"). You need both, but metrics are better for:
- **Alerting**: "GPU cache > 90% for 5 minutes" → page the on-call engineer
- **Capacity planning**: "Token throughput has grown 20% per week" → add GPUs before users notice
- **Debugging**: "Latency spiked at the same time as request rate" → correlation, not guesswork

Prometheus uses a pull model — it scrapes targets, targets don't push to it. This makes it self-discovering and avoids overwhelming the target during failures.

## What Is Grafana?

Grafana is a visualization layer. It connects to data sources (Prometheus, but also PostgreSQL, Loki, CloudWatch, etc.) and renders dashboards. It handles:
- **Querying**: Translates dashboard interactions into data source queries
- **Rendering**: Time-series graphs, gauges, tables, heatmaps, stat panels
- **Alerting**: Can send notifications to Slack, PagerDuty, email when metrics cross thresholds
- **Multi-tenancy**: Different teams see different dashboards

Grafana is not a data store — it is a visualization engine. Data lives in Prometheus (or whatever data source you connect). Grafana just asks for it and draws it.

---

## Key Concepts

| Concept | Definition |
|---------|-----------|
| **Scrape** | Prometheus fetches `/metrics` from a target at a regular interval |
| **Metric** | A named time-series with labels, e.g. `vllm:num_requests_running{model="Qwen3-0.6B"}` |
| **Label** | Key-value pairs that identify dimensions of a metric (model name, GPU ID, etc.) |
| **Counter** | A metric that only increases (e.g. total tokens served) — use `rate()` to see per-second velocity |
| **Gauge** | A metric that goes up and down (e.g. GPU cache usage) — read directly |
| **Histogram** | A metric that samples observations into configurable buckets (e.g. latency in `<=0.1s`, `<=0.5s`, `<=1s`) — use `histogram_quantile()` for percentiles |
| **PromQL** | Prometheus Query Language — the expression language used to query and aggregate metrics |
| **Provisioning** | Grafana's auto-configuration system — dashboards and data sources defined as files, not clicked in the UI |

---

## How vLLM Metrics Work

vLLM exposes metrics through the Prometheus Python client library. When you hit `GET /metrics`, vLLM returns a text response like:

```
# HELP vllm:num_requests_running Number of requests currently running
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running{model="Qwen3-0.6B"} 3

# HELP vllm:generation_tokens_total Count of generation tokens processed
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total{model="Qwen3-0.6B"} 15420
```

Prometheus parses this text format and stores the values. The key insight: **vLLM does this automatically** — there is no configuration needed on the vLLM side. The `/metrics` endpoint is built into the OpenAI-compatible server. You only need to point Prometheus at it.

---

## Quick Reference

| Command | Description |
|---------|-------------|
| `docker compose up -d` | Start all 4 services |
| `docker compose down` | Stop all services (keeps volumes) |
| `docker compose down -v` | Stop and delete all data (metrics, chat history, model cache) |
| `docker compose logs -f vllm` | Stream vLLM logs |
| `docker compose logs -f prometheus` | Stream Prometheus logs |
| `open http://localhost:3001` | Open Grafana dashboard (admin / admin) |
| `open http://localhost:9090/targets` | Check if Prometheus is successfully scraping vLLM |
| `open http://localhost:8000/metrics` | View raw vLLM metrics directly |

### Check that Prometheus is scraping

Visit `http://localhost:9090/targets` — you should see both `vllm` (port 8000) and `prometheus` (port 9090) listed as "UP".

### Test the API

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```

After sending a few requests, refresh the Grafana dashboard at `http://localhost:3001` — you'll see the metrics start populating.

### Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Prometheus shows "DOWN" for vLLM target | vLLM hasn't finished loading the model | Wait for model load (check `docker compose logs vllm`) |
| Grafana dashboard shows "No data" | No requests have been sent to vLLM yet | Send a test request (see above) |
| Grafana won't load at :3001 | Port conflict with another service | Check `netstat -ano` for what's using port 3001 |
| Prometheus data grows too large | 30-day retention uses disk space | Reduce retention in `compose.yml`: `--storage.tsdb.retention.time=7d` |

---

**Production?** ✅ Yes — this is the standard observability stack for LLM deployments. In production you would add:
- **Loki** for log aggregation (Grafana's log system)
- **Alertmanager** for paging on-call engineers via Slack/PagerDuty
- **Tempo** for distributed tracing across multiple services
- **Persistent alerting rules** for auto-remediation (e.g., restart vLLM on OOM)
