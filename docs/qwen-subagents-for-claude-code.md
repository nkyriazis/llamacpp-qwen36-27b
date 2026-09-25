# What worked for Qwen subagents in Claude Code

Setup is Claude Code on Opus as the main session, delegating coding work to subagents running Qwen3.8-27B locally in llama.cpp, on one RTX 5090 (32 GB). It works with a normal Claude subscription. Opus hands out the tasks and checks the results, and Qwen does the edits and runs the tests.

## Tested with (September 2026)

| component | version |
|---|---|
| Claude Code | 2.1.282, Opus 5.5 as the main model |
| llama.cpp | b11179 (commit `cd74ef6`), built for CUDA 13.2 and sm_120a, in Docker |
| model | Qwen3.8-27B, Unsloth `UD-Q4_K_XL` GGUF with its embedded MTP head, plus `mmproj-F16` |
| GPU and driver | RTX 5090 32 GB, NVIDIA driver 595.91 |

## The recipe

1. **llama.cpp with its built-in Anthropic API** (`/v1/messages`). No translation proxy, and the model's stock chat template with `--jinja`.
2. **Server settings** that fit in 32 GB with room for the desktop.
   ```
   Qwen3.8-27B-UD-Q4_K_XL.gguf + mmproj-F16.gguf (vision)
   -c 262144 -ctk q8_0 -ctv q4_0 -fa on -ub 512 --cache-ram 32768
   --parallel 1 --kv-unified
   --spec-type draft-mtp --spec-draft-n-max 3
   --reasoning on --reasoning-effort medium
   ```
   That's the model's full native context. It only fits with the V half of the cache at q4_0 (K stays q8_0), and recall held at 242K tokens with three planted facts. MTP (the model's built-in multi-token prediction) doubles decode speed to 120–165 tok/s. For parallel subagents use `--parallel 3` instead. They then share the context, but each keeps its own cache.
3. **A small router as `ANTHROPIC_BASE_URL`.** Claude Code sends everything to one endpoint, so the router sends requests for the local model name to llama.cpp and passes everything else to Anthropic untouched (so the subscription login keeps working). We wrote our own, about 200 lines of standard-library Python running as a second Docker service next to llama.cpp, so one `docker compose up` starts both. Off-the-shelf routers (claude-code-router, LiteLLM) weren't tested. On the local route it does two rewrites.
   - It merges the system messages Claude Code puts mid-conversation into the adjacent user message. Without this every request fails with HTTP 500.
   - It drops the `x-anthropic-billing-header` line from the system prompt. It changes every session, so without this each new subagent re-processes its whole prompt, about 6 s, instead of reusing the cache.
4. **One custom agent, passed with `claude --agents`.** Its `model` is the local alias and its tools are limited to `Read, Edit, Write, Bash`. The tool limit cut its starting prompt from 14K to 2.8K tokens.
5. **Make both sides agree on the context window.** Set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to context ÷ slots (262K with one slot). Claude Code then compacts before the limit, keeping 32K spare for the reply. It only applies to model names Claude Code doesn't know, so Opus is unaffected. The router also rewrites llama.cpp's context-overflow error into Anthropic's `prompt is too long`. Without that, a subagent that overflows just dies. With it, Claude Code compacts and carries on.
6. **For serial use**, run one slot and say "one at a time" in the agent's description. Opus followed that without any hard limit.

## Results

| test | outcome |
|---|---|
| Opus delegates one task | Qwen did it and Opus checked it. Each Qwen request after the first was 84–96% from cache. |
| three tasks in parallel | Three workers ran at once, each kept its cache (80–99%), and 19 tests pass. |
| three tasks, one slot | Opus ran them one after another. 24 tests pass. |
| three agents on 1 slot vs 3 slots | 222 s vs 63 s. Prompt tokens re-processed fell from 96% to 10%. |
| new subagent start | 1.4 s instead of 7 s once the billing line is dropped |
| one worker reading ~265K tokens through a 64K test window | without the error rewrite it died on the first overflow. With it, it recovered from 13 overflows and finished |

## What didn't work

- **`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`** doesn't stop the mid-conversation system messages.
- **`CLAUDE_CODE_ATTRIBUTION_HEADER=0`** does remove the billing line, but globally, so it also strips it from your Opus traffic. It's fine for a local-only setup.
- **One slot for parallel subagents.** On this hybrid model llama.cpp throws away the other agent's cache instead of saving it.
- **`--cache-reuse` and `--checkpoint-min-step`** have no effect on this model.
- **`-ub 1024` with 3 slots** crashed with CUDA out-of-memory once the desktop grew. Measure VRAM after a real request, not at idle.

## Staying version-independent

Claude Code and llama.cpp both change weekly, so the setup avoids depending on either one's details wherever it can.

- **The fixes live in the router, not in the server or in Claude Code settings.** They act on the structure of the request, so the router merges any system message found mid-conversation and drops any line starting with `x-anthropic-billing-header:`, whatever version string it carries. If Claude Code stops sending either one, the rewrite does nothing.
- **Stock chat template.** An earlier version patched Qwen's template to accept the mid-conversation messages. That worked, but it meant re-patching for every model. With the router doing the merge, the model's own template works unchanged, so switching models shouldn't need template work (only 3.8 has been tested this way).
- **Nothing hardcoded about the model.** The launcher reads the model name, slot count and context size from llama.cpp's `/props` at startup, and builds the agent definition and context setting from them.
- **Only documented Claude Code settings** (`ANTHROPIC_BASE_URL`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `--agents`). Guides still quote options that no longer exist, such as `DISABLE_NON_ESSENTIAL_MODEL_CALLS`.
- **llama.cpp pinned by commit.** An update script rebuilds, runs health, coherence, speed and cache checks, and rolls back to the previous commit if any fail. This build had just dropped `--mlock` and `--no-mmap` in favour of `--load-mode`, which is exactly the kind of change it catches.

Three things can still break on an upgrade, and couldn't be designed away.
- **Checkpoint placement.** Reuse on this hybrid model depends on llama.cpp saving checkpoints at user-message starts. If that logic changes, cross-session reuse can silently disappear.
- **New per-session values early in the prompt.** Claude Code could add something new that varies per session, like the billing line did.
- **Server flags.** Renamed or removed options, like the `--mlock` change above.

The cache check below catches the first two, so re-run it after every upgrade of Claude Code, llama.cpp or the model.

## How to know it's working

Follow-up requests should show `cache_read_input_tokens` above 90%. Check once that a small edit early in the system prompt shows up as a full miss, so you know the hits are real.
