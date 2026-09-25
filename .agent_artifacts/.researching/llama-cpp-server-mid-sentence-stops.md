# Research: llama.cpp Server Mid-Sentence Completion Stops

**Query**: What server-side conditions cause llama.cpp to stop generating mid-sentence?
**Source**: context7 (llama.cpp docs), tavily (GitHub issues, server README, man pages)
**Date**: 2026-06-14
**Completeness/Confidence**: High

## Summary

llama.cpp server has four distinct stop conditions tracked via `stop_type` in the response: `none`, `eos`, `limit`, and `word`. The most common cause of mid-sentence stops is the model generating an EOS (end-of-stream) token — this is baked into the model's GGUF metadata and cannot be disabled without `--ignore-eos`. The `--stop` flag has no default (empty array). Chat templates and model presets can inject implicit stop tokens from GGUF metadata. Context exhaustion (hitting `n_ctx`) triggers a context shift that can also cause abrupt stops.

## Key Findings

### 1. Server-Side Stop Conditions (`stop_type`)

**[High] Four stop_type values exist in the server API response:**

From `tools/server/README.md`:

| `stop_type` | Meaning |
|---|---|
| `none` | Generating (not stopped) |
| `eos` | Stopped because it encountered the EOS token |
| `limit` | Stopped because `n_predict` tokens were generated before stop words or EOS |
| `word` | Stopped due to encountering a stopping word from the `stop` JSON array |

Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

### 2. EOS Token — The #1 Cause of Mid-Sentence Stops

**[High] The EOS token is embedded in the GGUF model metadata. When the model generates this token, the server stops immediately — even mid-sentence.**

From Discussion #460 ("Chat mode inference stops mid-sentence"):

> "This is still happening. I'm using the server, and in the browser console it tells you the reason for stopping, and when I'm getting incomplete sentences or incomplete code I asked for, the debug console says the reason for stopping was **eos**."

Source: https://github.com/ggml-org/llama.cpp/discussions/460

From Issue #988 ("Stops talking mid sentence"):

> "I am using the vicuna model with the DAN prompt, it works well but it sometimes stops mid sentence for example it would say: 'example senten' then stop talking why does this happen?"

Source: https://github.com/ggml-org/llama.cpp/issues/988

**The EOS token is read from GGUF metadata** (`tokenizer.ggml.eos_token_id`). Different models have different EOS tokens:
- Llama 3: `<|end_of_text|>` (token 128001) and `<|eot_id|>` (token 128009)
- Qwen: `<|endoftext|>` / `<|im_end|>`
- Mistral: `</s>`

From llama-cpp-python Issue #1360:

> "Llama 3 family of models use multiple stop tokens: token ID 128001 which is '<|end_of_text|>' and token ID 128009 which is '<|eot_id|>'. The former works as expected, stopping generation, but the latter does not stop generation."

Source: https://github.com/abetlen/llama-cpp-python/issues/1360

### 3. `--ignore-eos` Flag

**[High] `--ignore-eos` disables the EOS token check. This implies `--logit-bias EOS-inf`.**

From the Debian man page (`llama-server(1)`):

> `--ignore-eos` — ignore end of stream token and continue generating (implies `--logit-bias EOS-inf`)

Source: https://manpages.debian.org/unstable/llama.cpp-tools/llama-server.1.en.html

**Warning**: Without EOS, the model may generate infinite garbage. Use with `--n_predict` to cap length.

### 4. `--stop` Flag — Default is Empty

**[High] The `--stop` flag (CLI) and `stop` parameter (API) default to an empty array. No implicit stop sequences are added by the server itself.**

From `tools/server/README.md`:

> `stop`: Specify a JSON array of stopping strings. These words will not be included in the completion, so make sure to add them to the prompt for the next iteration. **Default: `[]`**

Source: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

The response also includes `stopping_word`: "The stopping word encountered which stopped the generation (or '' if not stopped due to a stopping word)."

### 5. Chat Template / Jinja — Can Add Implicit Stops

**[Med] When using `--jinja`, the chat template from GGUF metadata is applied. Some templates include stop tokens that the server checks.**

From llama-cpp-agent docs:

> "List of stop sequences to finish completion generation. **The official stop sequences of the model get added automatically.**"

This means when using chat completion endpoints with `--jinja`, the server may read stop tokens from the GGUF `tokenizer.ggml.stop_tokens` array and add them automatically. This is NOT the same as `--stop` — it comes from the model file itself.

### 6. Context Exhaustion & Context Shift

**[High] When context fills up (`n_ctx` reached), llama.cpp performs a "context shift" by default — it keeps `--keep` tokens from the prompt and discards the oldest tokens. This can cause mid-sentence stops if generation hits the context wall.**

From Qwen docs on llama.cpp:

> "When the context is full but the generation doesn't end, the first `--keep` tokens (default 0, -1 means all) from the initial prompt is kept, and the first half of the rest is discarded. Then, the model continues to generate based on the new context tokens. You can set `--no-context-shift` to prevent this rotating behavior and the generation will stop once `-c` is reached."

Source: https://qwen.readthedocs.io/en/latest/run_locally/llama.cpp.html

From Issue #9390 ("server: ability to disable context shift"):

> "If disabled: `n_predict = n_ctx - n_tokens_prompt`. Note: the behavior above is the same as official OAI API."

Source: https://github.com/ggml-org/llama.cpp/issues/9390

### 7. `--n_predict` / `-n` — Generation Length Limit

**[High] `--n_predict` (alias `-n`) controls max tokens to generate. Default is `-1` (infinite until EOS/stop). Set to `-2` for "until context full".**

When `n_predict` is reached, `stop_type` = `limit`. This is a clean stop but can cut mid-sentence if the value is too low.

### 8. Mid-Token Truncation Bug (Qwen3.5)

**[Med] Issue #21248 reports silent mid-token truncation with Qwen3.5-35B-A3B on Vulkan multi-GPU:**

> "The model response is abruptly truncated in the middle of a token — specifically at a backtick character (`). The truncation is silent: no error message is shown, the server returns the partial response as if it were complete, and the stop reason does not indicate a limit was hit."

Source: https://github.com/ggml-org/llama.cpp/issues/21248

This appears to be a backend-specific bug (Vulkan multi-GPU), not a general server behavior.

### 9. Reasoning Budget Mid-Sentence Cutoff

**[Med] Issue #20632 addresses graceful termination of reasoning budgets:**

> "Raw truncation of the thinking trace measurably reduces answer quality compared to graceful termination."

Feature request for `--reasoning-budget-message` to inject `</think>` before hard cutoff. Relevant for models with thinking tags (Qwen, DeepSeek R1).

Source: https://github.com/ggml-org/llama.cpp/issues/20632

## Gaps

- The exact code path for how `--model-preset` adds stop tokens is not fully documented in the README. The server source (`server.cpp`) would need to be inspected for the precise merging of GGUF stop tokens with user-provided `--stop`.
- Whether the chat completions endpoint (`/v1/chat/completions`) auto-injects stop tokens differently from the completions endpoint (`/v1/completions`) needs source-level verification.

## Practical Checklist for Debugging Mid-Sentence Stops

1. **Check `stop_type` in the response** — if it's `eos`, the model generated its end token. This is the most common cause.
2. **Add `--ignore-eos`** to test if EOS is the culprit. If responses continue (possibly into garbage), EOS was the stop.
3. **Check `n_predict`** — if `stop_type` is `limit`, increase the token budget.
4. **Check context size** — if responses stop at predictable lengths, you may be hitting `n_ctx`. Increase with `-c`.
5. **Inspect GGUF metadata** — the model file may embed stop tokens that the server auto-applies with `--jinja`.
6. **Check for backend bugs** — Vulkan multi-GPU has known truncation issues (#21248).
