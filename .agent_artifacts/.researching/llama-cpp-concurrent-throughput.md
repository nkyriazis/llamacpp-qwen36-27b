# Research: llama.cpp Server Parameters for Concurrent Throughput

**Query**: Optimal llama.cpp server parameters for maximizing throughput/batching with multiple concurrent clients
**Source**: Context7 (ggml-org/llama.cpp repository docs, server README, dev docs, batched-bench, multi-gpu, build docs)
**Date**: 2026-06-19
**Completeness/Confidence**: High

## Summary

The llama.cpp server uses a slot-based architecture with continuous batching (enabled by default). The `--parallel` (`-np`) flag controls the number of server slots (concurrent request handles), NOT the batch size directly. Each slot manages a sequence, and slots are batched together into a single shared batch for `llama_decode` calls. For a 27B model serving multiple subagents, the key optimization levers are: parallel slots, context size (which directly affects KV cache memory per slot), batch/ubatch sizes, cache quantization, and threading configuration.

## Key Findings

### 1. `--parallel` (`-np`) — The Primary Concurrency Knob

- **What it controls**: Number of server slots. Each slot = one concurrent request/sequence. Default is -1 (auto).
- **How batching works**: The server context manages a single shared batch across all slots. Slots are batched together only if they have compatible configurations (same LoRA adapter, etc.). `llama_decode` fires when the batch is full or all slots are processed.
- **Impact**: More slots = more concurrent requests, but each slot reserves KV cache space (`ctx_size / parallel` effective context per slot). Total KV cache = `ctx_size * parallel`.
- **Finding [High]**: `--parallel 3` with `--ctx-size 262144` means the KV cache must hold 262144 * 3 = ~786K tokens total. This is the single largest memory consumer. If subagents typically use shorter contexts, you're wasting massive KV cache capacity.

### 2. `--ctx-size` (`-c`) — Context Size and Batch Efficiency

- **Impact on batching**: Larger context = more KV cache per slot = fewer slots fit in VRAM = less batching potential.
- **Finding [High]**: `--ctx-size 262144` (256K) is extremely large. For a 27B Q4 model, the KV cache alone with q4_0 quantization at 256K context * 3 parallel is enormous. If subagents don't need 256K context per request, this is the biggest bottleneck.
- **Recommendation**: Reduce to the maximum context subagents actually need. 32K-64K is often sufficient for agent tasks. This frees VRAM for more parallel slots.

### 3. `--batch` (`-b`) and `--ubatch` (`-ub`) — Physical vs Logical Batch

- **`--batch`**: Physical batch size — max tokens processed in a single `llama_decode` call. Default is typically 2048.
- **`--ubatch`**: Logical/unbatched batch size — max tokens per sequence in a batch. Controls how many prompt tokens can be processed per slot before yielding.
- **Finding [High]**: For concurrent completions with short prompts, default batch sizes are fine. For long prompt processing (prefill), increase `--batch` to handle more tokens per decode call. The batched-bench tool shows `-b 2048 -ub 512` as a common pattern.
- **Recommendation**: Consider `--batch 4096` if subagents send long prompts. Keep `--ubatch` at default or match to typical prompt length.

### 4. `--cont-batching` — Continuous Batching (Enabled by Default)

- **What it does**: Allows new requests to be inserted into the batch while other sequences are still generating. This is the key mechanism for high-throughput concurrent serving.
- **Finding [High]**: Already enabled by default in modern llama.cpp. No action needed, but verify it's not disabled.
- **How it works**: Slots yield until the next update if they have remaining prompt tokens. This means prompt processing and token generation happen interleaved across slots.

### 5. `--flash-attn` — Flash Attention and Batching

- **Impact**: Reduces memory usage for attention computation, especially beneficial with large batch sizes and long contexts.
- **Finding [High]**: Already enabled (`--flash-attn on`). This is correct for batching — flash attention is more memory-efficient for the attention operation when processing multiple sequences.
- **Note**: With KV cache quantization (q4_0), ensure the build was compiled with `GGML_CUDA_FA_ALL_QUANTS=ON` for full compatibility. The Docker build should handle this.

### 6. KV Cache Quantization (`--cache-type-k q4_0`, `--cache-type-v q4_0`)

- **What it does**: Quantizes the KV cache from f16 to q4_0, reducing memory by ~4x.
- **Finding [High]**: This is excellent for concurrent throughput. q4_0 KV cache uses ~1/4 the memory of f16, allowing more parallel slots or larger context. The tradeoff is minimal quality loss.
- **Recommendation**: Keep q4_0. Consider q8_0 if quality is critical, but q4_0 is the sweet spot for throughput.
- **Memory math**: For Qwen3.6-27B with 256K context, 3 parallel, q4_0 KV cache: roughly 27B params * 0.5 bytes (Q4) + KV cache overhead. The KV cache is the dominant factor at 256K context.

### 7. Threading Parameters

- **`--threads` (`-t`)**: Number of threads for general computation.
- **`--threads-batch`**: Threads for batch processing (prompt + generation).
- **Finding [Medium]**: With full GPU offload (`--ngl 999`), CPU threads matter less for the main inference but still handle tokenization, sampling, and response formatting. The server context runs on a single dedicated thread — heavy post-processing blocks all sequences.
- **Recommendation**: Set `--threads` to number of physical CPU cores (not hyperthreads). Set `--threads-batch` similarly. Don't oversaturate — start with physical cores and benchmark.

### 8. `--kv-cache-max-kb` / `--kv-cache-max-count`

- These are not standard llama.cpp server flags. The KV cache size is determined by `--ctx-size * --parallel`. There's no separate max-kb/max-count flag in the current server.
- **Finding [High]**: Control KV cache through `--ctx-size` and `--parallel` directly.

### 9. Sampling Parameters (`--temp`, `--top-p`, `--min-p`, `--sampler`)

- **Impact on throughput**: Minimal. Sampling happens per-token per-slot and is CPU-bound. The bottleneck is `llama_decode` (GPU-bound with full offload).
- **Finding [Low]**: `--min-p 0.05` is fine. These don't affect batching or throughput materially.

### 10. Prompt Caching and KV Cache Reuse

- **How it works**: The server reuses KV cache entries for repeated prompt prefixes. The `/completion` endpoint has `cache_prompt` (default true).
- **Finding [High]**: If subagents share a common system prompt, prompt caching will significantly speed up repeated requests. The KV cache automatically handles prefix matching.
- **Recommendation**: Ensure subagents use consistent system prompts to maximize cache hits.

## Specific Recommendations for Your Setup

### Current Configuration Analysis

| Parameter | Current | Assessment |
|-----------|---------|------------|
| `--parallel 3` | 3 slots | Low for "multiple subagents". Increase if you have 4+ concurrent agents. |
| `--ctx-size 262144` | 256K | Likely excessive. Each slot reserves 256K tokens of KV cache. |
| `--cache-type-k/v q4_0` | q4_0 | Good. Keeps KV cache lean. |
| `--flash-attn on` | on | Good. Essential for batching. |
| `--ngl 999` | full offload | Good. Maximizes GPU utilization. |
| `--mlock` | on | Fine, prevents model from swapping. |
| `--jinja` | on | Good for chat templates. |
| `--batch` | default (2048) | Consider increasing for long prompts. |
| `--threads` | default | Set explicitly to physical core count. |
| `--threads-batch` | default | Set explicitly. |

### Recommended Changes

```yaml
# Priority 1: Reduce context size (biggest impact)
# If subagents need max 32K context:
- --ctx-size
- "32768"  # Was 262144 — frees ~8x KV cache per slot

# Priority 2: Increase parallel slots (now that KV cache is smaller)
- --parallel
- "8"  # Was 3 — handle more concurrent subagents

# Priority 3: Increase batch size for long prompt processing
- --batch
- "4096"  # Was default 2048

# Priority 4: Set threading explicitly
- --threads
- "8"  # Adjust to your physical CPU core count
- --threads-batch
- "8"  # Same as threads

# Keep these (already good):
- --cache-type-k q4_0
- --cache-type-v q4_0
- --flash-attn on
- --ngl 999
- --mlock
- --jinja
- --min-p 0.05
- --reasoning off
```

### Memory Tradeoff Calculation

With Qwen3.6-27B Q4_K_M (~14-15 GB model weights):

| Config | KV Cache (approx) | Total VRAM | Max Parallel @ 256K | Max Parallel @ 32K |
|--------|-------------------|------------|---------------------|-------------------|
| 256K ctx, q4_0 KV | ~1.5 GB/slot | ~19-20 GB | 3 slots | — |
| 32K ctx, q4_0 KV | ~0.2 GB/slot | ~15 GB base | — | 15+ slots |
| 64K ctx, q4_0 KV | ~0.4 GB/slot | ~16 GB base | — | 8-10 slots |

Reducing context from 256K to 32K frees ~1.3 GB per slot, enabling 5x more concurrent slots within the same VRAM budget.

## Gaps

- Exact VRAM available on the target GPU is unknown — this determines the hard ceiling for `parallel * ctx_size`.
- The actual prompt/response lengths of subagent requests would inform optimal `--batch` and `--ubatch` sizing.
- Whether the Docker build includes `GGML_CUDA_FA_ALL_QUANTS=ON` is unknown — this affects flash attention + q4_0 KV cache compatibility.
- No data on whether subagents share system prompts (affects prompt caching efficiency).
