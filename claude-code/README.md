# Claude Code with local Qwen subagents

Your main Claude Code session stays on Anthropic (Opus). Subagents run on the model this stack serves. Nothing is installed into `~/.claude` or into your projects: the launcher only sets environment variables for its own process and passes the agent definitions with `--agents`.

The router is a small custom proxy (`router.py`, standard-library Python, about 200 lines). It runs as the `claude-router` service of this stack (`python:3.13-slim`, about 30 MB of RAM), listens on `127.0.0.1:8098` only, and starts and stops with the stack. Its request log (metadata only) is `claude-code/.state/router.jsonl`, which is git-ignored.

```
claude (main session, Opus) ──► router :8098 ──┬─ model == served alias ─► llama.cpp :8080 (/v1/messages)
         └─ qwen-worker subagents ─────────────┘   auth stripped, request normalised (see below)
                                               └─ everything else ──────► api.anthropic.com, untouched
```

## Use

**For your own traffic only.** The router passes your own Claude Code requests to Anthropic unchanged, using `ANTHROPIC_BASE_URL` the way [Anthropic's LLM gateway docs](https://code.claude.com/docs/en/llm-gateway) describe. Don't use it to route anyone else's credentials, and check [Anthropic's terms](https://code.claude.com/docs/en/legal-and-compliance) for your plan.

```
./scripts/up                               # llama.cpp and the claude-router service
claude-code/claude-qwen                    # hybrid: normal login, plus the qwen-worker subagent
claude-code/claude-qwen --local            # everything on the local model (no Anthropic traffic)
claude-code/cache-report                   # prompt-cache health of the local traffic so far
claude-code/cache-selftest                 # controlled cache checks against the server (also run by update-llamacpp)
```

Ask the main session to delegate, e.g. "use qwen-worker to add tests for X". To keep a separate Claude Code profile, set `CLAUDE_CONFIG_DIR=/some/dir` before running the launcher.

### Before you start

- **Run it from your project.** The launcher works from any directory, so `cd` into the project and run it by full path, or symlink it onto your PATH (`ln -s "$PWD/claude-code/claude-qwen" ~/.local/bin/claude-qwen`). Plain `claude` is unaffected.
- **Only `qwen-worker` is local.** Built-in agents (Explore, general-purpose) and the main session stay on Anthropic. Ask for the worker by name.
- **One worker at a time on the default 1 slot.** Parallel or background workers evict each other's cache and run about 3× slower (finding 4). Opus follows the worker's description. `CLAUDE_QWEN_STRICT_SERIAL=1` makes it a hard cap, for all subagents.
- **Keep other GPU apps closed.** The server uses about 30.2 of 32.6 GB of VRAM at 262K. Games, Steam or other CUDA work can crash it with out-of-memory.
- **Workers act with your session's permissions.** They run Bash and edit files, without asking if you use bypass permissions. Work in a git repo, commit before delegating, and review the diff.
- **Have Opus verify the result.** Ask it to run the tests or read the diff instead of trusting the worker's report. After a compaction, a worker once lost track and stopped early (see the context-window section).
- **After upgrading Claude Code, run `cache-selftest`.** A new version can add a per-session value that silently breaks caching. Check `cache-report` now and then. `scripts/update-llamacpp` already runs the self-test for llama.cpp updates.
- **After a reboot**, both services restart with Docker (`restart: unless-stopped`). If the launcher says it can't reach them, run `./scripts/up`.

### Parallel or serial

There is one setting, `LLAMA_PARALLEL` in `.env`. The launcher reads the running server's `/props` (slot count, context size, model alias), so the Claude side always matches the server.

| `LLAMA_PARALLEL` | server | Claude Code side |
|---|---|---|
| `1` (default) | 1 slot, the full 262K context | worker description says one at a time; assumed window 262K. `CLAUDE_QWEN_STRICT_SERIAL=1` also sets `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=1`, which is a hard cap but applies to *all* subagents, including Anthropic-hosted ones. Claude Code has no per-agent concurrency setting. |
| `3` | 3 slots sharing one 262K KV pool, ~1 GB more VRAM | worker description says up to 3 in parallel; assumed window 87K (262K / 3) |

Serial mode matters because with one slot, llama.cpp can't keep two conversations cached on this hybrid model. Parallel workers would evict each other's state on every turn (finding 4).

## What is version-dependent, and where it's handled

All Claude Code-specific handling is in `router.py` and works on the API structure, not on version strings. The server runs the model's stock chat template, and model names and limits come from the server.

- **Mid-conversation system messages.** Claude Code sends system messages inside `messages`. The router folds them into the neighbouring user turn as `<system-reminder>` text, which any chat template accepts.
- **Attribution/billing line.** The router removes any `x-anthropic-billing-header:` line from the system prompt of local requests, whatever its format.
- **Auth.** The router strips auth on the local route and passes everything through untouched on the remote route.
- **Model name, slot count, context.** The launcher reads all three from `/props` at start. The router routes `LLAMA_ALIAS` from the same `.env`. If the two ever disagree, the launcher refuses to start and tells you to run `./scripts/up`.
- **Env vars.** The launcher only uses documented ones: `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (only affects models Claude Code doesn't recognize), `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (opt-in), and the `ANTHROPIC_*MODEL*` variables plus `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` in `--local` mode.
- **Regressions.** A Claude Code or llama.cpp upgrade can still add something that breaks caching. Two tools catch it:
  - `cache-report` checks your real traffic: follow-up requests should be >90% from cache, and it lists any that weren't.
  - `cache-selftest` checks the server and router with a synthetic Claude Code-shaped request. `scripts/update-llamacpp` runs it and rolls back on failure.

## Real subscription runs (Opus 5.5 main session, isolated `CLAUDE_CONFIG_DIR` login)

| run | server | what happened |
|---|---|---|
| one delegation | 3 slots | 3 Opus requests (all 200) and 6 Qwen requests; after the first, each Qwen request was 84–96% from cache. Opus checked the work itself, and the tests pass. |
| three tasks | 3 slots | Opus launched 3 workers at once. They interleaved (`ABCAABBCC`), each follow-up was 80–99% from cache, and 19 tests pass. |
| three tasks | 1 slot | Opus ran the workers one after another (`AAABBBBBCCCCCC`) from the description alone, without the hard cap: "those agents can only run one at a time". 24 tests pass. |

## Context windows: how Claude Code and Qwen agree

Claude Code doesn't know Qwen's window, and llama.cpp enforces its own. Two mechanisms keep a subagent from dying mid-task.

1. **Proactive compaction.** The launcher sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the server's context ÷ slots. Claude Code then compacts before each request once the conversation is near window − 32K (it keeps room for a full-size reply) − a small buffer. That's about 225K on the 262K default.
2. **Reactive compaction.** If a request still overflows, llama.cpp rejects it with its own `exceed_context_size_error`. Claude Code doesn't recognize that error, so the router rewrites it into Anthropic's `prompt is too long: N tokens > M maximum`. Claude Code answers that by compacting and retrying. `cache-selftest` checks the rewrite.

Tested with the server at a 64K window, and one worker told to read 12 files (~265K tokens):

| run | Claude Code told | router rewrite | result |
|---|---|---|---|
| A | 200K | no | the worker died on its first overflow (`request (96,527 tokens) exceeds the available context size`), and the orchestrator gave up |
| B | 64K (the truth) | no | it compacted at 34K and continued. A first worker still died, because one step of parallel reads jumped from 3K to 96K |
| C | 200K | yes | Claude Code recognized the error and retried, but a brand-new worker with one oversized step has nothing to compact |
| D | 200K | yes | one worker read all 12 files through 13 overflows, each recovered by compaction |

What compaction can't fix is a single step larger than the whole window. The worker's instructions therefore say to read big files in pieces, not to batch large reads, and not to echo file contents. In D the worker also once hit the 32K output cap by echoing file contents. After one compaction it also lost track and stopped early, until the orchestrator nudged it. So compaction on Qwen keeps the mechanics working, but how well its summaries preserve the task is a quality question.

## How cache numbers were verified

Three independent signals, which must agree:
- `cache_read_input_tokens` / `input_tokens` in llama.cpp's API response;
- the server log's `prompt eval time = … / N tokens` for the same task;
- wall-clock prompt time.

In every run where I matched them, N equalled the reported new tokens exactly, and prompt time scaled with new tokens only (about 2–3K tok/s). A negative control is included: a one-character edit early in the system prompt must show as a full miss, and does (0 cached, 17,827 evaluated, 6.3 s, "forcing full prompt re-processing" in the log). `cache-selftest` runs these cases.

## Findings

Measured 2026-09-25 with Claude Code 2.1.282 and llama.cpp cd74ef6. The runs used a sandbox (`CLAUDE_CONFIG_DIR` in a scratch dir, `env -i`, a throwaway git repo) and a logging proxy. Cache numbers come from llama.cpp's `cache_read_input_tokens` and trace logs.

**1. Out of the box, every request fails.**
- **What Claude Code sends.** Two kinds of system messages inside `messages`: a `# Environment` block after the first user turn, and a `<total_tokens>` note after every tool result.
- **Why it fails.** Qwen's template raises `System message must be at the beginning`, so llama.cpp returns HTTP 500 and Claude Code retries for about 3 minutes.
- **No setting we found turns it off.** `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` doesn't stop these messages.
- **The fix.** The router folds these messages into user turns. The result is still append-only, so a conversation's requests keep extending each other exactly.

**2. Within one session, the prefix cache works.**
- Each request extends the previous one; 98–99.7% of prompt tokens come from cache.
- Thinking blocks are sent back and re-rendered.
- Each turn re-processes only the new tool results plus a few tokens at the turn boundary.

**3. Across sessions (every subagent spawn), nothing is reused unless the billing line is removed.**
- **The cause.**
  - The line's `cc_version` suffix differs per session (e.g. `2.1.282.2d9` vs `.7eb`).
  - Qwen's template renders the tools first and the system text after them, which puts that per-session value just before the first user message.
  - On a hybrid (DeltaNet) model, llama.cpp can only resume from saved checkpoints at or before the point where two prompts diverge. It saves them at user-message starts and just before the end of the prompt, both after that point.
  - So each new session re-prefilled everything: about 14K tokens for a subagent and 18K for a main session, around 6 s.
- **The effect of removing it.** New sessions restore the checkpoint at the first user message and process about 2.2K tokens instead of 17.8K (1.4 s instead of 7 s).
- **Why the router, not `CLAUDE_CODE_ATTRIBUTION_HEADER=0`.** That env var would also strip the line from Anthropic traffic, where it's used to attribute usage to Claude Code.

**4. Parallel subagents need parallel slots.**

With one slot, llama.cpp picks the slot by longest common prefix. When a hybrid model has no usable checkpoint, it then *discards* the other conversation's state instead of saving it to the host-RAM cache.

| 3 concurrent agents, same task | wall time | prompt tokens re-processed | requests re-prefilling >5K tokens |
|---|---|---|---|
| `--parallel 1` | 222 s | 96% | 28 of 32 |
| `--parallel 3 --kv-unified` | 63 s | 9.7% | 3 (the cold starts) |

- **Single stream:** three slots don't change single-stream speed, with MTP included (162–168 tok/s on code).
- **VRAM:** three slots add about 0.8 GB (31.2 GB peak with a 203K-token prompt). Four don't fit.
- **Serial runs:** with one slot and the serial setup, two delegated tasks ran strictly one after the other. This was with Qwen as the orchestrator, and both with and without the hard cap.

**5. Restricting the subagent's tools matters more than any server flag.**
- The default subagent inherits every tool: 19 in the sandbox, plus all MCP tools in a real setup. That's a 14K-token prompt before the brief.
- With `tools: Read, Edit, Write, Bash`, it's 2.8K, and Qwen still completed the test tasks.

**6. Only subagent traffic reaches the local model.** Main-session, compaction and auxiliary calls (titles, summaries) use Anthropic model names, so they stay on Anthropic. The Claude Code gateway hint headers confirmed this during testing.

**7. Server flags that don't help here.**
- `--cache-reuse` is disabled for hybrid models, and also whenever vision is loaded.
- `--checkpoint-min-step` only spaces checkpoints; it doesn't add any during prefill. They are placed at user-message starts and at n−(4+ubatch) and n−4, per `server-context.cpp`.
- The default 32 checkpoints per slot is enough. Each is about 210 MB of host RAM.

**8. Env var notes.**
- `DISABLE_NON_ESSENTIAL_MODEL_CALLS`, still quoted in guides, isn't in the current Claude Code docs, so we don't rely on it.
- A subagent's `model:` accepts any string behind a custom base URL, and `--agents` accepts `model` and `tools`.

## Not verified yet

- **Interactive (TUI) mode.** All runs used `claude -p`. Interactive mode's side calls go to Anthropic in hybrid mode.
- **Long subagent sessions at the real 262K window.** Compaction was tested at 64K (above), and the mechanism is the same, but it hasn't run end to end at 262K. A full shared KV pool with `LLAMA_PARALLEL` > 1 is also untested.
- **Subscription terms.** The Claude Code gateway docs describe using subscription login through a gateway set as `ANTHROPIC_BASE_URL`, and the router is a local passthrough for your own traffic. The docs don't explicitly cover this case.
