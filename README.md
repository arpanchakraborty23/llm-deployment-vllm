# LLM Deployment with vLLM

This repository is a practical overview of inference engineering for Large Language Model deployment, with vLLM as the serving engine. It is meant to help you understand not only how to start a model server, but also how to reason about throughput, latency, batching, quantization, KV cache memory, and GPU VRAM requirements before deploying a model.

The current codebase is intentionally small. Use this README as the deployment playbook, then expand `level1/` and `docs/` with hands-on examples as the course or project grows.

## What This Guide Covers

- LLM inference engineering fundamentals
- Why vLLM is useful for high-throughput serving
- How model weights, KV cache, activations, and overhead consume GPU VRAM
- How to estimate required VRAM for different model sizes and precisions
- How prompt length, generation length, concurrency, and batch size affect memory
- Deployment options using Python, OpenAI-compatible API serving, and multi-GPU serving
- Production tuning checklist for latency, throughput, reliability, and cost

## Inference Engineering Overview

Training optimizes model weights. Inference engineering optimizes how those weights are served to users.

The main goal is to serve requests with the right balance of:

| Area | What You Optimize | Common Metrics |
| --- | --- | --- |
| Latency | Time until users receive output | Time to first token, end-to-end latency |
| Throughput | Total tokens served per second | Output tokens/sec, requests/sec |
| Cost | GPU hours and memory efficiency | Cost/request, GPU utilization |
| Quality | Model behavior and answer quality | Accuracy, hallucination rate, evaluation score |
| Reliability | Stable serving under load | Error rate, queue time, OOM frequency |

LLM inference has two major phases:

1. **Prefill phase**: The model processes the input prompt and builds the KV cache. This is compute-heavy and depends strongly on prompt length.
2. **Decode phase**: The model generates one token at a time. This is memory-bandwidth-heavy and depends strongly on output length and concurrency.

Good deployment design requires sizing both phases.

## Why vLLM?

vLLM is an inference engine designed for efficient LLM serving. Its biggest advantage is memory-efficient KV cache management through PagedAttention.

| Capability | Why It Matters |
| --- | --- |
| PagedAttention | Reduces KV cache fragmentation and improves memory utilization |
| Continuous batching | Dynamically batches active requests for higher throughput |
| OpenAI-compatible API | Lets clients call your server like an OpenAI chat/completions endpoint |
| Tensor parallelism | Splits large models across multiple GPUs |
| Quantization support | Runs models with lower memory precision when supported |
| Prefix caching | Reuses repeated prompt prefixes for faster and cheaper serving |

vLLM is a strong default when you need high-throughput online serving, especially for chat, assistants, RAG, coding models, batch inference, and internal APIs.

## Core Concepts

### Model Weights

Model weights are the parameters loaded into GPU memory. A 7B parameter model has about 7 billion parameters.

Approximate model weight memory:

```text
weight_memory_gb = parameter_count * bytes_per_parameter / 1e9
```

Common precision sizes:

| Precision | Bytes per Parameter | Approx Weight Memory for 7B | Approx Weight Memory for 13B |
| --- | ---: | ---: | ---: |
| FP32 | 4 bytes | 28 GB | 52 GB |
| FP16/BF16 | 2 bytes | 14 GB | 26 GB |
| INT8 | 1 byte | 7 GB | 13 GB |
| INT4 | 0.5 byte | 3.5 GB | 6.5 GB |

Real deployments need extra memory beyond weights for KV cache, runtime overhead, CUDA graphs, temporary buffers, tokenizer overhead, and fragmentation.

### KV Cache

During generation, each transformer layer stores key and value tensors for every token already processed. This is called the KV cache. It allows the model to avoid recomputing previous tokens.

KV cache grows with:

- Number of layers
- Hidden size
- Number of tokens in context
- Number of concurrent requests
- Precision used for the cache

Approximate KV cache memory per token:

```text
kv_bytes_per_token = 2 * num_layers * hidden_size * bytes_per_cache_element
```

The `2` is for key and value tensors.

For models that use grouped-query attention (GQA) or multi-query attention (MQA), KV cache can be smaller because the model stores fewer KV heads than attention heads:

```text
kv_bytes_per_token =
  2 * num_layers * num_kv_heads * head_dim * bytes_per_cache_element
```

When you do not know `num_kv_heads`, the `hidden_size` formula is a conservative planning estimate.

Approximate total KV cache:

```text
kv_cache_gb = kv_bytes_per_token * total_active_tokens / 1e9
```

Where:

```text
total_active_tokens = concurrency * (average_prompt_tokens + average_generated_tokens)
```

This is why a model can fit for one user but fail under many concurrent users.

### The KV Cache Problem

KV cache is necessary for fast generation, but it creates one of the hardest memory problems in LLM serving. Every active request has a different prompt length, generation length, and stopping point. If the server reserves memory too aggressively, GPU memory is wasted. If it reserves too little, requests fail or must wait in a queue.

The main problems are:

- **Memory grows with every active token**: more users, longer prompts, and longer outputs all increase KV memory.
- **Request lengths are unpredictable**: one user may generate 20 tokens while another generates 2000.
- **Traditional allocation causes fragmentation**: free memory can exist on the GPU but not in contiguous chunks that are useful.
- **Static batching wastes memory**: shorter requests occupy space planned for longer requests.
- **Long-context models amplify the problem**: a 32K or 128K context window can make KV cache larger than the model weights under load.

This is why KV cache management is often the real bottleneck in production LLM serving.

### Why Common Methods Struggle

| Method | How It Works | Why It Fails or Struggles |
| --- | --- | --- |
| Static max-length allocation | Reserve memory for the maximum sequence length for every request | Wastes large amounts of VRAM when most requests are shorter than the max length |
| Static batching | Group requests into fixed batches | Fast for uniform workloads, but inefficient when prompt and output lengths vary |
| Naive dynamic allocation | Allocate KV memory as each request grows | Can create memory fragmentation and unstable performance over time |
| Request padding | Pad shorter requests to match longer ones in the batch | Burns compute and memory on padding tokens that carry no useful information |
| Smaller batch size | Reduce concurrent requests to avoid OOM | Improves stability but lowers throughput and increases serving cost |
| Weight quantization only | Store model weights in INT8/INT4 | Reduces model memory, but KV cache can still dominate VRAM during long-context or high-concurrency serving |
| CPU offload | Move some memory or computation to CPU | Saves GPU memory, but often adds latency because CPU-GPU transfer is slow compared with GPU memory access |

### How PagedAttention Solves It

PagedAttention treats KV cache memory more like virtual memory in an operating system. Instead of requiring each request to own one large contiguous KV cache block, vLLM splits KV cache into smaller fixed-size blocks and maps logical token positions to physical memory blocks.

This gives vLLM several advantages:

- **Non-contiguous memory allocation**: a request can use free blocks wherever they exist on the GPU.
- **Less fragmentation**: memory is reused at block granularity instead of sequence granularity.
- **Better batching**: vLLM can keep more requests active at the same time.
- **Higher throughput**: continuous batching plus efficient KV allocation improves token/sec under load.
- **Cleaner memory reuse**: when a request finishes, its KV blocks can be returned and reused quickly.

Comparison:

| Area | Traditional KV Cache Allocation | vLLM PagedAttention |
| --- | --- | --- |
| Memory layout | Large contiguous memory per request | Small fixed-size KV blocks |
| Fragmentation | High with variable-length requests | Much lower because blocks are reused |
| Handling short requests | Often wastes memory reserved for max length | Allocates only the blocks needed |
| Handling long requests | Can block or fail if contiguous memory is unavailable | Grows by adding more blocks |
| Batch efficiency | Sensitive to padding and length mismatch | Better for mixed request lengths |
| Concurrency | Lower when context length is large | Higher because memory is packed more efficiently |
| Production impact | More OOM risk and lower GPU utilization | More stable memory use and better throughput |

Simple mental model:

```text
Traditional KV cache:
request A -> [one large reserved block..............]
request B -> [one large reserved block..............]
request C -> [one large reserved block..............]

PagedAttention:
request A -> block 1 -> block 7 -> block 9
request B -> block 2
request C -> block 3 -> block 4 -> block 8 -> block 12
```

The result is not that KV cache disappears. The result is that GPU memory is used more efficiently, so the same GPU can usually serve more concurrent requests before hitting the memory limit.

### Activations and Runtime Overhead

Inference also needs temporary memory for activations, attention workspaces, CUDA kernels, graph capture, communication buffers, and framework overhead.

A practical estimate:

```text
runtime_overhead = 10% to 25% of model weight memory
```

For production sizing, keep at least 10% to 20% free GPU memory after weights and KV cache. Running at the absolute memory limit causes unstable latency and out-of-memory errors.

## How to Calculate GPU VRAM Needed

Use this practical formula:

```text
required_vram_gb =
  model_weight_gb
  + kv_cache_gb
  + runtime_overhead_gb
  + safety_margin_gb
```

### Step 1: Calculate Model Weight Memory

```text
model_weight_gb = parameters_in_billions * bytes_per_parameter
```

Because `1B parameters * 1 byte = about 1 GB`, the shortcut is simple:

| Model Size | FP16/BF16 | INT8 | INT4 |
| --- | ---: | ---: | ---: |
| 7B | 14 GB | 7 GB | 3.5 GB |
| 13B | 26 GB | 13 GB | 6.5 GB |
| 34B | 68 GB | 34 GB | 17 GB |
| 70B | 140 GB | 70 GB | 35 GB |

### Step 2: Calculate KV Cache Memory

Formula:

```text
kv_cache_gb =
  2 * num_layers * hidden_size * bytes_per_cache_element * total_active_tokens / 1e9
```

For GQA/MQA models, use this more precise formula:

```text
kv_cache_gb =
  2 * num_layers * num_kv_heads * head_dim * bytes_per_cache_element * total_active_tokens / 1e9
```

Example architecture values:

| Model Family Example | Layers | Hidden Size |
| --- | ---: | ---: |
| Llama-style 7B | 32 | 4096 |
| Llama-style 13B | 40 | 5120 |
| Llama-style 70B | 80 | 8192 |

For FP16/BF16 KV cache:

```text
bytes_per_cache_element = 2
```

For FP8 KV cache, when supported:

```text
bytes_per_cache_element = 1
```

### Step 3: Estimate Active Tokens

```text
active_tokens = concurrent_requests * (average_prompt_tokens + average_output_tokens)
```

Example:

```text
concurrent_requests = 16
average_prompt_tokens = 1000
average_output_tokens = 500

active_tokens = 16 * (1000 + 500) = 24000 tokens
```

### Step 4: Add Overhead and Margin

Use:

```text
runtime_overhead_gb = model_weight_gb * 0.15
safety_margin_gb = total_gpu_vram * 0.10
```

For planning before selecting a GPU, you can approximate:

```text
safety_margin_gb = (model_weight_gb + kv_cache_gb) * 0.15
```

## Worked VRAM Examples

### Example 1: 7B Model, FP16, 16 Concurrent Requests

Assumptions:

```text
model = 7B
precision = FP16
layers = 32
hidden_size = 4096
concurrency = 16
average_prompt_tokens = 1000
average_output_tokens = 500
kv_precision = FP16
```

Weights:

```text
7B * 2 bytes = 14 GB
```

Active tokens:

```text
16 * (1000 + 500) = 24000
```

KV cache:

```text
2 * 32 * 4096 * 2 * 24000 / 1e9 = 12.58 GB
```

Overhead:

```text
14 GB * 0.15 = 2.1 GB
```

Estimated requirement:

```text
14 + 12.58 + 2.1 + margin = about 31 to 34 GB
```

Recommendation: use at least a 40 GB GPU for comfortable serving, or reduce concurrency/context/output length for a 24 GB GPU.

### Example 2: 7B Model, INT4 Weights, Same Traffic

Weights:

```text
7B * 0.5 bytes = 3.5 GB
```

KV cache stays FP16 unless configured otherwise:

```text
12.58 GB
```

Overhead:

```text
3.5 GB * 0.15 = 0.53 GB
```

Estimated requirement:

```text
3.5 + 12.58 + 0.53 + margin = about 19 to 22 GB
```

Recommendation: a 24 GB GPU can work, but KV cache now dominates memory. Quantizing weights helps, but long context and concurrency still require VRAM.

### Example 3: 70B Model, FP16

Weights:

```text
70B * 2 bytes = 140 GB
```

A single 80 GB GPU cannot hold the FP16 weights. You need tensor parallelism across multiple GPUs.

Example:

```text
4 x 80 GB GPUs = 320 GB total VRAM
```

This can hold the weights plus KV cache and overhead, depending on context length and concurrency. In vLLM you would use tensor parallel serving, for example:

```bash
vllm serve meta-llama/Llama-3.1-70B-Instruct --tensor-parallel-size 4
```

## Quick VRAM Planning Rules

- If the model weights alone exceed GPU VRAM, use quantization or multi-GPU tensor parallelism.
- If the model fits for one request but fails under load, reduce `max_model_len`, concurrency, or output length.
- Quantization reduces weight memory, not always KV cache memory.
- Long context serving is usually KV-cache-limited.
- High throughput requires enough memory for continuous batching.
- Keep 10% to 20% GPU memory free for stable production behavior.
- Test with realistic prompts and output lengths; toy prompts under-estimate memory.

## Deployment Paths

### 1. Python Inference

Use this when experimenting locally or writing batch scripts.

```python
from vllm import LLM, SamplingParams

llm = LLM(model="Qwen/Qwen2.5-7B-Instruct")
sampling_params = SamplingParams(
    temperature=0.7,
    top_p=0.9,
    max_tokens=256,
)

prompts = [
    "Explain KV cache in simple terms.",
    "Give me a deployment checklist for a 7B model.",
]

outputs = llm.generate(prompts, sampling_params)

for output in outputs:
    print(output.prompt)
    print(output.outputs[0].text)
```

### 2. OpenAI-Compatible API Server

Use this when deploying an application backend.

```bash
vllm serve Qwen/Qwen2.5-7B-Instruct --host 0.0.0.0 --port 8000
```

Then call it with an OpenAI-compatible client:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="EMPTY",
)

response = client.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct",
    messages=[
        {"role": "user", "content": "What is continuous batching?"}
    ],
    temperature=0.7,
    max_tokens=256,
)

print(response.choices[0].message.content)
```

Important checks:

- All GPUs should have enough combined VRAM for weights, KV cache, and overhead.
- GPUs should be connected with fast interconnect where possible.
- Tensor parallelism improves capacity, but communication overhead can affect latency.

## Important vLLM Serving Parameters

| Parameter | Purpose |
| --- | --- |
| `--model` | Model name or local model path |
| `--host` / `--port` | Network binding for the API server |
| `--tensor-parallel-size` | Number of GPUs used to split the model |
| `--gpu-memory-utilization` | Fraction of GPU memory vLLM may use |
| `--max-model-len` | Maximum context length allowed |
| `--max-num-seqs` | Maximum number of active sequences |
| `--quantization` | Quantization backend when using supported models |
| `--enable-prefix-caching` | Reuse repeated prefixes across requests |

Example memory-conscious startup:

```bash
vllm serve Qwen/Qwen2.5-7B-Instruct ^
  --gpu-memory-utilization 0.85 ^
  --max-model-len 8192 ^
  --max-num-seqs 32 ^
  --enable-prefix-caching
```

PowerShell uses the backtick for line continuation:

```powershell
vllm serve Qwen/Qwen2.5-7B-Instruct `
  --gpu-memory-utilization 0.85 `
  --max-model-len 8192 `
  --max-num-seqs 32 `
  --enable-prefix-caching
```

## Optimization Techniques

### Continuous Batching

Traditional batching waits to collect a fixed batch. Continuous batching adds and removes requests dynamically as tokens are generated. This improves GPU utilization for mixed-length requests.

Use it when:

- Requests arrive continuously
- Prompt and output lengths vary
- You care about throughput under concurrent load

### Prefix Caching

Prefix caching helps when many requests share the same system prompt, RAG template, tool schema, or conversation prefix.

Good use cases:

- Chatbots with fixed system prompts
- RAG applications with repeated instructions
- Agent frameworks with repeated tool definitions

### Quantization

Quantization lowers model weight precision to reduce memory and sometimes improve speed.

| Method | Memory Benefit | Typical Use |
| --- | --- | --- |
| FP16/BF16 | Baseline serving precision | Best quality and broad support |
| INT8 | Medium memory reduction | Balanced quality and memory |
| INT4/AWQ/GPTQ | Large memory reduction | Fit larger models on smaller GPUs |
| FP8 | Lower memory and faster kernels where supported | Newer GPUs and supported models |

Always evaluate answer quality after quantization.

### Speculative Decoding

Speculative decoding uses a smaller draft model to propose tokens and a larger model to verify them. It can improve decoding speed when configured well, but it adds complexity and memory use.

Use it after you have a stable baseline.

## Production Checklist

Before deploying to users:

- Define expected prompt length, output length, and concurrency.
- Calculate VRAM using realistic active token assumptions.
- Set `max_model_len` deliberately instead of leaving it unnecessarily high.
- Load test with real prompts, not only short examples.
- Track time to first token, tokens/sec, queue time, GPU utilization, and OOM events.
- Add request timeouts and maximum output limits.
- Keep model, tokenizer, and prompt template versions fixed.
- Evaluate quality after quantization or serving parameter changes.
- Use health checks for the API server.
- Log model name, sampling parameters, prompt length, output length, and latency.
- Monitor GPU memory continuously in production.

## Repository Structure

```text
llm-deployment-vllm/
|-- docs/                 # Add deeper notes and deployment references here
|-- level1/               # Add beginner hands-on examples here
|-- main.py               # Minimal Python entry point
|-- pyproject.toml        # Python project metadata and dependencies
|-- uv.lock               # Locked dependency versions
|-- llm_deployment_repo_guide.pdf
`-- README.md
```

## Suggested Learning Roadmap

1. Run a small model locally with Python inference.
2. Serve the same model using the vLLM OpenAI-compatible API.
3. Measure latency and throughput with different `max_tokens` values.
4. Increase prompt length and observe KV cache memory growth.
5. Test quantized weights and compare quality.
6. Try multi-GPU tensor parallel serving for larger models.
7. Add monitoring, logging, and load testing before production.

## References

- vLLM documentation: https://docs.vllm.ai
- vLLM GitHub: https://github.com/vllm-project/vllm
- PagedAttention paper: https://arxiv.org/abs/2309.06180
- Hugging Face model hub: https://huggingface.co/models

## License

Apache License 2.0. See the project license file when added.
