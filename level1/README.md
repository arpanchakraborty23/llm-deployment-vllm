If you're focusing **only on vLLM deployment** (no Docker, no Ray, no Kubernetes), you can think of it as progressing from a simple test server to a production-ready inference server.

---

# Phase 0: Create an AWS GPU Instance

Before running vLLM, create a GPU-backed EC2 instance and connect to it.

Recommended starter instance:

```text
g5.xlarge
```

This gives you one NVIDIA A10G GPU with 24 GB VRAM, which is enough for small deployment tests such as 3B and some quantized 7B models.

Basic AWS setup flow:

1. Open the AWS EC2 console.
2. Choose **Launch instance**.
3. Select an Ubuntu Deep Learning AMI or Ubuntu 22.04 with NVIDIA drivers installed later.
4. Choose a GPU instance type such as `g5.xlarge`.
5. Add enough disk space, for example 100 GB or more.
6. Create or select a key pair.
7. In the security group, allow SSH from your IP.
8. For API testing, add an inbound rule for TCP port `8000` from your IP only.
9. Launch the instance.
10. Connect with SSH:

```bash
ssh -i your-key.pem ubuntu@YOUR_EC2_PUBLIC_IP
```

Recommended security group inbound rules:

| Type | Protocol | Port | Source |
| --- | --- | ---: | --- |
| SSH | TCP | 22 | Your public IP only |
| Custom TCP | TCP | 8000 | Your public IP only |

After vLLM is running with `--host 0.0.0.0 --port 8000`, access it from your machine using the instance public IP:

```text
http://YOUR_EC2_PUBLIC_IP:8000
```

The OpenAI-compatible API base URL is:

```text
http://YOUR_EC2_PUBLIC_IP:8000/v1
```

After connecting, verify the GPU before installing or serving models.

### Hugging Face CLI Login for Model Access

Some models require a Hugging Face account, accepted model license, and access token before vLLM can download them.

Create a token from Hugging Face:

```text
Hugging Face profile -> Settings -> Access Tokens -> New token
```

Install the CLI and log in on the EC2 instance:

```bash
pip install -U huggingface_hub
hf auth login
```

Paste your token when prompted. To confirm login:

```bash
hf auth whoami
```

If using gated models such as Llama, open the model page in Hugging Face first, accept the license, then retry the vLLM command.

---
The easiest way is to use NVIDIA's tools.

### 1. Show all GPUs (recommended)

```bash
nvidia-smi
```

Example:

```text
+-----------------------------------------------------------------------------+
| GPU  Name                     Memory-Usage |
|  0   NVIDIA A10G              0MiB / 23028MiB |
|  1   NVIDIA A10G              0MiB / 23028MiB |
+-----------------------------------------------------------------------------+
```

If you see GPU 0 and GPU 1, you have **2 GPUs**.

---

### 2. Count the GPUs

```bash
nvidia-smi -L
```

Example:

```text
GPU 0: NVIDIA A10G (UUID: GPU-xxxx)
GPU 1: NVIDIA A10G (UUID: GPU-yyyy)
GPU 2: NVIDIA A10G (UUID: GPU-zzzz)
GPU 3: NVIDIA A10G (UUID: GPU-aaaa)
```

This machine has **4 GPUs**.

To get just the count:

```bash
nvidia-smi -L | wc -l
```

Example output:

```text
4
```

---

### 3. Check from Python (PyTorch)

```python
import torch

print(torch.cuda.device_count())
```

More details:

```python
import torch

for i in range(torch.cuda.device_count()):
    print(i, torch.cuda.get_device_name(i))
```

Example:

```text
0 NVIDIA A10G
1 NVIDIA A10G
```

---

### 4. Check which GPUs are visible

```bash
echo $CUDA_VISIBLE_DEVICES
```

If it prints:

```text
0,2
```

only GPUs **0** and **2** are visible to your application.

If it prints nothing, all GPUs are typically available (unless restricted by your environment).

---

### 5. Detailed hardware information

```bash
lspci | grep -i nvidia
```

or

```bash
lshw -C display
```

---

## The three commands you'll use most often

```bash
nvidia-smi
```

```bash
nvidia-smi -L
```

```bash
nvidia-smi -L | wc -l
```

These are the standard commands to check GPU availability and count on Linux servers.
----

# Phase 0: Download Model from Hugging Face

If you want to download a model first before running the server (useful for caching or offline use), you can use the Hugging Face `huggingface-cli` or Python.

### Option 1: Using huggingface-cli

```bash
huggingface-cli download Qwen/Qwen3-0.6B
```

### Option 2: Using Python

```python
from huggingface_hub import snapshot_download

snapshot_download(repo_id="Qwen/Qwen3-0.6B")
```

By default, models are saved to `~/.cache/huggingface/`. To download to a custom directory:

```bash
huggingface-cli download Qwen/Qwen3-0.6B --local-dir /path/to/model
```

Or in Python:

```python
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="Qwen/Qwen3-0.6B",
    local_dir="/path/to/model"
)
```

To serve from a local directory instead of a Hugging Face repo ID:

```bash
vllm serve /path/to/model
```

---

# Phase 1: Basic Local Server

Install:

```bash
pip install vllm
```

Start a model:

```bash
vllm serve Qwen/Qwen3-0.6B
```

Default endpoint:

```text
http://localhost:8000
```

This is only for testing.

---

# Phase 2: Expose to Network

```bash
vllm serve Qwen/Qwen3-0.6B \
    --host 0.0.0.0 \
    --port 8000
```

Now other machines on the network can access it.

---

# Phase 3: Specify GPU

Single GPU

```bash
CUDA_VISIBLE_DEVICES=0 \
vllm serve Qwen/Qwen3-0.6B
```

GPU 1

```bash
CUDA_VISIBLE_DEVICES=1 \
vllm serve Qwen/Qwen3-0.6B
```

Multiple GPUs

```bash
CUDA_VISIBLE_DEVICES=0,1
```

---

# Phase 4: Choose Data Type

FP16

```bash
vllm serve model \
    --dtype float16
```

BF16

```bash
vllm serve model \
    --dtype bfloat16
```

FP32

```bash
vllm serve model \
    --dtype float32
```

---

# Phase 5: Tensor Parallelism

Use multiple GPUs for one model.

```bash
vllm serve model \
    --tensor-parallel-size 2
```

Four GPUs

```bash
--tensor-parallel-size 4
```

---

# Phase 6: Quantized Models

AWQ

```bash
vllm serve model \
    --quantization awq
```

GPTQ

```bash
vllm serve model \
    --quantization gptq
```

FP8

```bash
vllm serve model \
    --quantization fp8
```

---

# Phase 7: Maximum Context Length

```bash
vllm serve model \
    --max-model-len 32768
```

or

```bash
--max-model-len 8192
```

Choose based on your model and available GPU memory.

---

# Phase 8: GPU Memory Utilization

Default is conservative.

Increase usage:

```bash
vllm serve model \
    --gpu-memory-utilization 0.95
```

Examples:

```text
0.80
0.90
0.95
0.98
```

Higher values increase KV cache capacity but leave less room for unexpected memory spikes.

---

# Phase 9: Control Concurrency

Limit concurrent sequences:

```bash
vllm serve model \
    --max-num-seqs 64
```

Examples

```text
16
32
64
128
256
```

This directly affects throughput and memory usage.

---

# Phase 10: Control Batch Tokens

```bash
vllm serve model \
    --max-num-batched-tokens 8192
```

Examples

```text
4096
8192
16384
32768
```

Larger values generally improve throughput but require more GPU memory.

---

# Phase 11: KV Cache Memory

Specify KV cache type:

```bash
vllm serve model \
    --kv-cache-dtype fp8
```

or

```bash
--kv-cache-dtype auto
```

Using FP8 KV cache can significantly reduce memory usage on supported hardware.

---

# Phase 12: CPU Offloading

If GPU memory is limited:

```bash
vllm serve model \
    --cpu-offload-gb 20
```

This allows part of the model to reside in CPU RAM.

---

# Phase 13: Swap Space

Increase CPU swap used by vLLM:

```bash
vllm serve model \
    --swap-space 16
```

Value is in GB.

---

# Phase 14: Prefix Caching

Enable prompt prefix reuse:

```bash
vllm serve model \
    --enable-prefix-caching
```

Useful when many requests share the same system prompt or document prefix.

---

# Phase 15: Chunked Prefill

```bash
vllm serve model \
    --enable-chunked-prefill
```

Improves handling of very long prompts by breaking prefill into chunks.

---

# Phase 16: Trust Remote Code

Some models require custom code:

```bash
vllm serve model \
    --trust-remote-code
```

Only enable this for models from sources you trust.

---

# Phase 17: API Key Protection

```bash
vllm serve model \
    --api-key my-secret-key
```

Clients must include:

```http
Authorization: Bearer my-secret-key
```

---

# Phase 18: Load a Local Model

```bash
vllm serve /models/llama-3
```

Instead of downloading from Hugging Face each time.

---

# Phase 19: Production Command

Example for a single GPU production deployment:

```bash
CUDA_VISIBLE_DEVICES=0 \
vllm serve /models/Llama-3.1-8B-Instruct \
    --host 0.0.0.0 \
    --port 8000 \
    --dtype bfloat16 \
    --gpu-memory-utilization 0.95 \
    --max-model-len 8192 \
    --max-num-seqs 64 \
    --max-num-batched-tokens 8192 \
    --enable-prefix-caching \
    --enable-chunked-prefill \
    --api-key YOUR_API_KEY
```

---

# Phase 20: Multi-GPU Production

```bash
CUDA_VISIBLE_DEVICES=0,1,2,3 \
vllm serve /models/Llama-3.1-70B-Instruct \
    --host 0.0.0.0 \
    --port 8000 \
    --tensor-parallel-size 4 \
    --dtype bfloat16 \
    --gpu-memory-utilization 0.95 \
    --max-model-len 8192 \
    --enable-prefix-caching \
    --enable-chunked-prefill \
    --api-key YOUR_API_KEY
```

---

## A practical learning order

1. `vllm serve`
2. `--host`, `--port`
3. `CUDA_VISIBLE_DEVICES`
4. `--dtype`
5. `--tensor-parallel-size`
6. `--gpu-memory-utilization`
7. `--max-model-len`
8. `--max-num-seqs`
9. `--max-num-batched-tokens`
10. `--enable-prefix-caching`
11. `--enable-chunked-prefill`
12. `--kv-cache-dtype`
13. `--quantization`
14. `--cpu-offload-gb`
15. `--api-key`

These are the flags you'll encounter most often when deploying vLLM in real production environments before moving on to orchestration with Ray, Docker, or Kubernetes.

---

## Deployment Tests in `exp.ipynb`

Use `exp.ipynb` as the execution notebook for this phase guide. Each phase above has a matching deployment test cell:

| Phase | Deployment test in `exp.ipynb` |
| --- | --- |
| Phase 0 | AWS GPU instance and SSH setup checklist |
| Phase 1 | Basic local `vllm serve` startup test |
| Phase 2 | Network binding test with `--host 0.0.0.0` |
| Phase 3 | `CUDA_VISIBLE_DEVICES` GPU selection test |
| Phase 4 | dtype comparison test |
| Phase 5 | tensor parallel launch test |
| Phase 6 | quantized model launch test |
| Phase 7 | max context length test |
| Phase 8 | GPU memory utilization test |
| Phase 9 | concurrency limit test |
| Phase 10 | batched token limit test |
| Phase 11 | KV cache dtype test |
| Phase 12 | CPU offload test |
| Phase 13 | swap-space test |
| Phase 14 | prefix caching test |
| Phase 15 | chunked prefill test |
| Phase 16 | trust remote code test |
| Phase 17 | API key protection test |
| Phase 18 | local model path test |
| Phase 19 | single-GPU production command test |
| Phase 20 | multi-GPU production command test |
