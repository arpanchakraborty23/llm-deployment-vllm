# vLLM Deployment

A lightweight and configurable deployment template for serving Large Language Models (LLMs) using **vLLM** with a YAML-based configuration file.

---

## Features

* YAML-based configuration
* Automatic virtual environment activation
* CUDA environment configuration
* Supports Hugging Face models
* Optional API key authentication
* Supports quantized models (AWQ, GPTQ, FP8)
* Configurable GPU memory utilization
* Tensor parallel support
* Production-ready deployment script

---

## Project Structure

```text
vllm-deployment/
├── .venv/
├── config.yml
├── deploy.sh
├── README.md
└── logs/
```

---

## Requirements

* Ubuntu 22.04+
* Python 3.12+
* NVIDIA GPU
* CUDA Toolkit
* NVIDIA Driver
* Git

---

## Installation

### Clone the repository

```bash
git clone <repository-url>
cd vllm-deployment
```

### Create a virtual environment

```bash
python3 -m venv .venv
source .venv/bin/activate
```

### Upgrade pip

```bash
pip install --upgrade pip
```

### Install dependencies

```bash
pip install vllm pyyaml
```

---

## Configuration

Edit `config.yml`.

Example:

```yaml
model:
  name: "Qwen/Qwen3-0.6B"
  dtype: "auto"
  gpu_memory_utilization: 0.9
  max_model_len: 8192
  tensor_parallel_size: 1
  quantization: null

server:
  host: "0.0.0.0"
  port: 8000
  api_key: "your-api-key"

env:
  CUDA_HOME: "/path/to/cuda"
  VLLM_ATTENTION_BACKEND: "FLASH_ATTN"
  VLLM_USE_FLASHINFER_SAMPLER: "0"
  FLASHINFER_DISABLE_VERSION_CHECK: "1"
```

---

## Start the Server

```bash
chmod +x deploy.sh

./deploy.sh config.yml
```

Example output:

```text
=========================================
vLLM Deployment
=========================================
Python : /home/ubuntu/vllm-deployment/.venv/bin/python
vLLM   : /home/ubuntu/vllm-deployment/.venv/bin/vllm
CUDA   : /path/to/cuda
Model  : Qwen/Qwen3-0.6B
Port   : 8000
=========================================

Launching...
```

---

## Verify the Server

### Health Check

```bash
curl http://localhost:8000/health
```

### List Models

```bash
curl http://localhost:8000/v1/models \
-H "Authorization: Bearer your-api-key"
```

### Chat Completion

```bash
curl http://localhost:8000/v1/chat/completions \
-H "Content-Type: application/json" \
-H "Authorization: Bearer your-api-key" \
-d '{
    "model":"Qwen/Qwen3-0.6B",
    "messages":[
        {
            "role":"user",
            "content":"Hello!"
        }
    ]
}'
```

---

## Configuration Reference

| Parameter                            | Description                                     |
| ------------------------------------ | ----------------------------------------------- |
| model.name                           | Hugging Face model name or local path           |
| model.dtype                          | Model precision (auto, float16, bfloat16, etc.) |
| model.gpu_memory_utilization         | Fraction of GPU memory to allocate              |
| model.max_model_len                  | Maximum context length                          |
| model.tensor_parallel_size           | Number of GPUs for tensor parallelism           |
| model.quantization                   | Quantization method                             |
| server.host                          | Server bind address                             |
| server.port                          | API port                                        |
| server.api_key                       | API authentication key                          |
| env.CUDA_HOME                        | CUDA installation path                          |
| env.VLLM_ATTENTION_BACKEND           | Attention backend                               |
| env.VLLM_USE_FLASHINFER_SAMPLER      | FlashInfer sampler toggle                       |
| env.FLASHINFER_DISABLE_VERSION_CHECK | Disable FlashInfer version check                |

---

## Supported Models

Examples:

* Qwen/Qwen3-0.6B
* Qwen/Qwen3-4B
* meta-llama/Llama-3.2-3B-Instruct
* mistralai/Mistral-7B-Instruct
* google/gemma-3-4b-it

---

## Common Issues

### `vllm: command not found`

Activate the virtual environment:

```bash
source .venv/bin/activate
```

or install vLLM:

```bash
pip install vllm
```

---

### `SyntaxError` when reading `config.yml`

Ensure `deploy.sh` parses the YAML using:

```bash
python - "$CONFIG_FILE"
```

instead of:

```bash
python "$CONFIG_FILE"
```

---

### CUDA not found

Verify:

```bash
nvcc --version
nvidia-smi
```

---

### Out of GPU Memory

Reduce:

```yaml
gpu_memory_utilization: 0.8
```

or

```yaml
max_model_len: 4096
```

or use a smaller model.

---

## Logs

If logging is enabled, logs are stored in:

```text
logs/vllm.log
```

---

## License

MIT License.
