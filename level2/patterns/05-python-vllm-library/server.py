"""
Pattern 09: Use vLLM as a Python library, not just `vllm serve` CLI.

`vllm serve` is a convenience wrapper. In production, you often need
to control the engine programmatically — custom pre/post-processing,
dynamic batching policies, metrics export, multi-model routing, etc.

This server uses AsyncLLMEngine directly. Every CLI flag from Level 1
is available as a Python argument. Docker is just the deployment layer.
"""

import argparse
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from vllm import AsyncLLMEngine, AsyncEngineArgs, SamplingParams


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--model", type=str, required=True)
    p.add_argument("--dtype", type=str, default="auto")
    p.add_argument("--tensor-parallel-size", type=int, default=1)
    p.add_argument("--pipeline-parallel-size", type=int, default=1)
    p.add_argument("--gpu-memory-utilization", type=float, default=0.90)
    p.add_argument("--max-model-len", type=int, default=8192)
    p.add_argument("--max-num-seqs", type=int, default=256)
    p.add_argument("--kv-cache-dtype", type=str, default="auto")
    p.add_argument("--enable-prefix-caching", action="store_true")
    p.add_argument("--enable-chunked-prefill", action="store_true")
    p.add_argument("--quantization", type=str, default=None)
    p.add_argument("--swap-space", type=int, default=4)
    p.add_argument("--cpu-offload-gb", type=int, default=0)
    p.add_argument("--host", type=str, default="0.0.0.0")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--api-key", type=str, default=None)
    return p.parse_args()


args = parse_args()
metrics = {"requests": 0, "tokens": 0, "errors": 0, "start": time.time()}

app = FastAPI(title="vLLM Python Library Server")


class GenerateRequest(BaseModel):
    prompt: str
    max_tokens: int = 256
    temperature: float = 0.7
    top_p: float = 0.9
    stop: list[str] | None = None
    stream: bool = False


class GenerateResponse(BaseModel):
    text: str
    tokens_used: int
    finish_reason: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    engine_args = AsyncEngineArgs(
        model=args.model,
        dtype=args.dtype,
        tensor_parallel_size=args.tensor_parallel_size,
        pipeline_parallel_size=args.pipeline_parallel_size,
        gpu_memory_utilization=args.gpu_memory_utilization,
        max_model_len=args.max_model_len,
        max_num_seqs=args.max_num_seqs,
        kv_cache_dtype=args.kv_cache_dtype,
        enable_prefix_caching=args.enable_prefix_caching,
        enable_chunked_prefill=args.enable_chunked_prefill,
        quantization=args.quantization,
        swap_space=args.swap_space,
        cpu_offload_gb=args.cpu_offload_gb,
        trust_remote_code=True,
    )
    app.state.engine = AsyncLLMEngine.from_args(engine_args)
    app.state.api_key = args.api_key
    yield


@app.middleware("http")
async def auth(request: Request, call_next):
    if app.state.api_key:
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth.split(" ")[1] != app.state.api_key:
            return JSONResponse(status_code=401, content={"error": "Unauthorized"})
    return await call_next(request)


@app.post("/v1/generate")
async def generate(req: GenerateRequest):
    try:
        sampling = SamplingParams(
            temperature=req.temperature,
            top_p=req.top_p,
            max_tokens=req.max_tokens,
            stop=req.stop,
        )
        result = await app.state.engine.generate(req.prompt, sampling)
        metrics["requests"] += 1
        metrics["tokens"] += len(result.outputs[0].token_ids)
        return GenerateResponse(
            text=result.outputs[0].text,
            tokens_used=len(result.outputs[0].token_ids),
            finish_reason=result.outputs[0].finish_reason,
        )
    except Exception as e:
        metrics["errors"] += 1
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/v1/models")
async def list_models():
    config = await app.state.engine.get_model_config()
    return {"data": [{"id": config.model, "object": "model"}]}


@app.get("/health")
async def health():
    return {"status": "healthy", "model": args.model}


@app.get("/metrics")
async def get_metrics():
    uptime = time.time() - metrics["start"]
    return {
        "model": args.model,
        "uptime_seconds": round(uptime),
        "requests_total": metrics["requests"],
        "tokens_generated": metrics["tokens"],
        "tokens_per_second": round(metrics["tokens"] / max(uptime, 1), 2),
        "errors": metrics["errors"],
        "config": {
            "dtype": args.dtype,
            "tensor_parallel_size": args.tensor_parallel_size,
            "max_model_len": args.max_model_len,
            "gpu_memory_utilization": args.gpu_memory_utilization,
            "quantization": args.quantization,
            "enable_prefix_caching": args.enable_prefix_caching,
        },
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host=args.host, port=args.port)
