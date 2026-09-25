# llamacpp-qwen36-27b

Standalone llama.cpp stack for Qwen 27B models (default: **Qwen3.8-27B**, with Qwen3.6-27B kept as a fallback), tuned for a single RTX 5090 (32 GB) and agentic coding with long sessions.

This folder is intended to run independently, without any reference to another repository folder.

## Contents

- docker-compose.yml: server flags; every tunable is read from `.env`
- llama-cpp.Dockerfile: CUDA 13.2, sm_120a, llama.cpp pinned by commit (`LLAMA_CPP_REF`)
- .env.example: the tuned configuration, with the measurements behind it
- models/Qwen3.8-27B/: `Qwen3.8-27B-UD-Q4_K_XL.gguf`, `mmproj-F16.gguf` (plus optional UD-Q5_K_XL / UD-Q6_K)
- models/Qwen3.6-27B/: `Qwen3.6-27B-Q4_K_M.gguf`, `mmproj-F16.gguf`
- claude-code/: run Claude Code with local Qwen subagents; the router runs as the `claude-router` service, and `claude-code/claude-qwen` is the launcher. See claude-code/README.md
- scripts/up, scripts/down, scripts/verify-self-contained, scripts/verify-runtime, scripts/bench, scripts/update-llamacpp

## Prerequisites

- Docker Engine
- NVIDIA driver (CUDA 13.2+) and NVIDIA Container Toolkit

## Models

Not auto-downloaded. From https://huggingface.co/unsloth/Qwen3.8-27B-GGUF:

```
cd models/Qwen3.8-27B
curl -LO https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_XL.gguf
curl -LO https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-F16.gguf
```

The MTP (multi-token prediction) head is embedded in the GGUF, so no separate draft model is needed.

## Run / verify / stop

1. `./scripts/up` (copies `.env.example` to `.env` if missing, then builds and starts llama.cpp and the Claude Code router)
2. `./scripts/verify-self-contained` and `./scripts/verify-runtime`
3. `./scripts/bench`: decode/prefill speed and MTP acceptance
4. `./scripts/down`

The OpenAI-compatible API is at `http://localhost:8080/v1`, and the served model name is `LLAMA_ALIAS` (default `qwen3.8-27b`).

## Updating llama.cpp

`./scripts/update-llamacpp` moves to the latest llama.cpp release (or pass `master`, a tag or a commit). It rebuilds, runs `verify-runtime` (health, model alias, a coherence check), confirms that MTP initialised, and runs `bench`. If any step fails it rolls back to the previous commit. On success it updates `LLAMA_CPP_REF` in `.env` and `.env.example`. Compare the bench output with the table below before committing.

## Tuning notes (measured 2026-09-25, RTX 5090, llama.cpp 1ab7e5a / b11177; re-verified on cd74ef6)

| Setup | VRAM | Decode (short ctx) | Notes |
|---|---|---|---|
| UD-Q4_K_XL, 262K ctx, K q8_0 / V q4_0, 1 slot, MTP n=3 (**default**) | 27.9 GB llama.cpp, 30.6 GB total at a 242K prompt | 120–158 tok/s | 3/3 planted facts recalled at 242K, 74 tok/s decode there |
| UD-Q4_K_XL, 200K ctx, q8_0 KV (previous default) | 30.2 GB idle / 30.3 GB at 203K prompt | 118–146 tok/s | vision on GPU (0.9 s/image), 64 tok/s decode at 203K depth |
| same without MTP | | ~70 tok/s | |
| UD-Q5_K_XL, 200K, vision on CPU, ub 512 | 31.2 GB at 162K prompt | 101–136 tok/s | vision 16 s/image, ~1.4 GB slack |
| UD-Q6_K, 128K, vision on GPU | 30.8 GB idle | 100–131 tok/s | cannot reach 200K with q8_0 KV |

- KV cache costs about 47 KiB/token at q8_0 (only 16 of the 64 layers use full attention). The full native 262K context fits only with the V half at q4_0 (K stays q8_0); 262K at q8_0/q8_0 crash-loops with CUDA OOM. Recall was checked at 242K tokens (3 facts at 10/50/90% depth, all verbatim).
- MTP `n-max` sweep: 2 is weaker on code, 4–5 are weaker on prose, so 3 is the best overall.
- 1 slot by default, so one conversation gets the whole context. `LLAMA_PARALLEL=3` lets parallel agents keep their own caches (single-stream speed unchanged) but they share the pool, and each slot costs ~0.5 GB. ubatch is 512 (−0.5 GB for −2% prefill). Budget the desktop at ≤ 2.5 GB: with ubatch 1024 and a ~3 GB desktop, the server hit CUDA OOM on its first decode.
- `LLAMA_CACHE_RAM` (32 GB host RAM) keeps prompt states for several long sessions, so switching between them doesn't re-prefill.
- Desktop VRAM use (~2.2 GB here) directly limits context. Running headless frees room for about 224K.
- Thinking is on, with `reasoning_effort=medium`. The template's own default is `xhigh`, which never loops but spends 10–24K tokens thinking on open-ended coding prompts (3 of 3 runs hit a 24K cap on one of them). With medium, 27 of 27 loop-prone test prompts finish on their own with 1–4K tokens of thinking. Override per request with `"chat_template_kwargs": {"reasoning_effort": "low"|"xhigh"}`. `LLAMA_REASONING_BUDGET` (16K) is a safety cap that closes thinking and forces an answer.
- The server has no API key and listens on all interfaces. Put it behind a firewall or add `--api-key` if the machine is reachable.
