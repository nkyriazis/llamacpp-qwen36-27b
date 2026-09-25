# Research: --batch vs --ubatch in llama.cpp

**Query**: Difference between --batch (n_batch) and --ubatch (n_ubatch) in llama.cpp server
**Source**: llama.cpp official docs (ggml-org/llama.cpp GitHub repo)
**Date**: 2026-06-19
**Completeness/Confidence**: High

## Summary

`--batch` (`-b`, `n_batch`) is the **logical batch size** — a software-level window that controls how many tokens can be queued for prompt processing before calling the GPU. Default: **2048**.

`--ubatch` (`-ub`, `n_ubatch`) is the **physical batch size** — the hard limit on how many tokens are actually sent to the GPU in a single forward pass. Default: **512**.

The physical batch size is the real hardware constraint. The logical batch size is a scheduling buffer. For single-GPU setups, `n_batch` mainly matters for multi-GPU pipeline parallelism; `n_ubatch` is the parameter that directly affects performance and VRAM.

## Key Findings

- **[High] --batch (n_batch) = Logical batch size**
  - Controls the maximum number of tokens that can be accumulated in the batch buffer before triggering a forward pass
  - Default: **2048**
  - Primarily impacts multi-GPU pipeline parallelism (determines chunk size sent through the pipeline)
  - On a single GPU, increasing beyond n_ubatch has minimal effect
  - Described as: "can improve prompt processing performance when using multiple GPUs with pipeline parallelism if increased above the physical batch size"

- **[High] --ubatch (n_ubatch) = Physical batch size**
  - Controls the maximum number of tokens processed in a single GPU forward pass
  - Default: **512**
  - Directly impacts prompt processing throughput and VRAM consumption
  - Described as: "determines the maximum number of tokens processed at once, impacting performance during prompt processing at the cost of higher memory usage"
  - This is the actual GPU kernel batch dimension

- **[High] Interaction rule**
  - From SPEED-Bench docs: "when increasing the logical batch size (`-ub`), also raise the physical batch size (`-b`) to at least the same value"
  - Note: The SPEED-Bench README uses `-b` for physical and `-ub` for logical in its terminology, which is INVERTED from the completion README. The actual source code convention is: `-b` = n_batch (logical), `-ub` = n_ubatch (physical)
  - Constraint: `n_ubatch <= n_batch` must hold (physical cannot exceed logical)
  - The server manages a single shared batch across all slots; `llama_decode` is the main computational bottleneck

- **[High] VRAM implications**
  - Increasing `n_ubatch` increases VRAM usage proportionally — the GPU needs workspace buffers sized for the batch
  - The KV cache VRAM is determined by context size (`-c`) x parallel slots (`--parallel`), not by batch/ubatch directly
  - Working memory for forward passes scales with `n_ubatch` — larger values mean more temporary GPU memory during prompt processing
  - For a 27B model, VRAM is already heavily consumed by model weights; increasing n_ubatch too aggressively can cause OOM

- **[High] Concurrent request handling**
  - Continuous batching (`--cont-batching`) is enabled by default in the server
  - `--parallel` controls the number of concurrent request slots (default: -1 for auto)
  - Context size per slot = total context (`-c`) / parallel slots
  - Example: `-c 16384 -np 4` gives 4 concurrent requests with 4096 context each
  - `n_ubatch` affects how efficiently multiple requests are batched together during prompt processing
  - Larger `n_ubatch` = more tokens processed per GPU call = better throughput for concurrent requests with long prompts

- **[High] Defaults**
  - `--batch` / `-b` / `n_batch`: **2048**
  - `--ubatch-size` / `-ub` / `n_ubatch`: **512**

## Recommended Values for 27B Model on Single GPU (NVIDIA CUDA)

| Scenario | n_batch | n_ubatch | Rationale |
|----------|---------|----------|-----------|
| Default (safe) | 2048 | 512 | Works everywhere, conservative VRAM |
| Single request, long prompts | 2048 | 1024-2048 | Better prefill throughput, moderate VRAM cost |
| Concurrent requests | 2048 | 1024-2048 | More tokens batched per forward pass |
| VRAM-constrained | 2048 | 256-512 | Minimize working memory, accept slower prefill |

**Key principle for single GPU:** `n_batch` stays at default (2048). Tune `n_ubatch` based on available VRAM headroom and prompt length. Start at 1024, increase if VRAM allows, decrease if OOM.

## Details

### From tools/completion/README.md
> The physical batch size (`--ubatch-size` or `-ub N`) determines the maximum number of tokens processed at once, impacting performance during prompt processing at the cost of higher memory usage. The default is 512. The logical batch size (`--batch-size` or `-b N`) can improve prompt processing performance when using multiple GPUs with pipeline parallelism if increased above the physical batch size. The default is 2048.

### From tools/server/README.md
> The server supports continuous batching (`--cont-batching`), which is enabled by default, for improved throughput. The number of server slots, or parallel requests, can be configured with `--parallel` (default: -1 for auto).

### From tools/server/README-dev.md
> The server context manages a single shared batch across all slots. Slots are batched together only if they have compatible configurations, such as using the same LoRA adapter. The `llama_decode` operation, performed when the batch is full or all slots are processed, is the main computational bottleneck.

### Benchmark examples from batched-bench
```bash
# Typical benchmark config: -b 2048 -ub 512
./llama-batched-bench -m model.gguf -c 2048 -b 2048 -ub 512 -npp 128,256,512 -ntg 128,256

# Matching batch sizes: -b 512 -ub 512
./llama-batched-bench -m model.gguf -c 16384 -b 512 -ub 512 -ngl 99
```

## Gaps
- Exact VRAM formula for working memory as a function of n_ubatch x model size not documented in README
- Optimal n_ubatch for 27B specifically would need empirical benchmarking with `llama-bench` or `llama-batched-bench`
- Interaction with flash attention (`--flash-attn`) and its effect on batch size sensitivity not covered in docs
