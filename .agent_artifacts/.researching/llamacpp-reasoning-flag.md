# Research: llama.cpp --reasoning semantics and reasoning_content behavior

**Query**: Research the llama.cpp server flag --reasoning and related OpenAI-compatible response fields like reasoning_content. Determine exactly what on/off does.
**Source**: combined (llama.cpp docs + llama.cpp discussions with code pointers)
**Date**: 2026-06-14
**Completeness/Confidence**: Medium-High

## Summary
llama.cpp separates two concerns: (a) whether reasoning/thinking mode is used in chat generation, and (b) how thought text is parsed/rendered in the API output. The --reasoning flag controls (a), while --reasoning-format controls (b).

So, --reasoning off is not just an output-hiding switch. It is the server-side mode toggle intended to replace per-request template toggles like enable_thinking via chat_template_kwargs. By contrast, reasoning-format none is explicitly output-format behavior (leave thoughts in content rather than extracting into reasoning_content).

For /v1/chat/completions, reasoning traces can appear as reasoning_content (non-streaming: message.reasoning_content; streaming: delta.reasoning_content) when parsing mode/template supports it. If reasoning extraction is disabled (reasoning-format none), thought text stays in content.

## Key Findings
- **[High] --reasoning is a generation-mode toggle, distinct from output parsing**
  - Evidence: llama.cpp server docs list separate flags:
    - "-rea, --reasoning [on|off|auto] | Use reasoning/thinking in the chat ('on', 'off', or 'auto', default: 'auto' (detect from template))"
    - "--reasoning-format FORMAT | controls whether thought tags are allowed and/or extracted from the response..."
  - URL: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

- **[High] off is not merely trace suppression; output suppression/parsing is a different knob**
  - Evidence from docs for output parsing:
    - "--reasoning-format ... none: leaves thoughts unparsed in message.content"
    - "deepseek: puts thoughts in message.reasoning_content"
  - URL: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

- **[Medium-High] --reasoning on/off replaced older per-request enable_thinking flow**
  - Evidence from llama.cpp discussion quoting server warning text:
    - "Setting 'enable_thinking' via --chat-template-kwargs is deprecated. Use --reasoning on / --reasoning off instead."
    - Also notes replacement is startup flag behavior in practice.
  - URL: https://github.com/ggml-org/llama.cpp/discussions/23351

- **[High] Reasoning budget is the effort-like control, not --reasoning itself**
  - Evidence:
    - docs: "--reasoning-budget N | token budget for thinking: -1 for unrestricted, 0 for immediate end, N>0 for token budget"
    - code snippet referenced in llama.cpp discussion (#21445) shows request-level thinking_budget_tokens only applied when CLI budget is unset:
      - "int reasoning_budget = opt.reasoning_budget;"
      - "if (reasoning_budget == -1 && body.contains('thinking_budget_tokens')) { ... }"
      - then propagates to llama params as reasoning_budget_tokens/start_tag/end_tag.
  - URLs:
    - https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
    - https://github.com/ggml-org/llama.cpp/discussions/21445

- **[High] /v1/chat/completions behavior exposes reasoning_content when enabled/parsable**
  - Evidence:
    - docs: server supports "parsing and returning reasoning via the reasoning_content field"
    - API docs include optional response field "reasoning_content"
    - streaming example in discussion shows chunks like: delta.reasoning_content followed by normal content chunks.
  - URLs:
    - https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
    - https://github.com/ggml-org/llama.cpp/discussions/21445

## Direct Answers To Requested Questions
1) Does off disable internal reasoning, or only suppress reasoning trace output?
- Best-supported reading: it disables reasoning/thinking mode for chat generation (prompt/template behavior), not merely output trace rendering.
- Rationale: docs separate --reasoning (use thinking in chat) from --reasoning-format (how traces are parsed/exposed).

2) Is it a reasoning effort control knob?
- No. --reasoning is on/off/auto mode selection.
- Effort-like control is --reasoning-budget (and request-side thinking_budget_tokens under conditions), which limits thinking tokens.

3) How does behavior appear in /v1/chat/completions responses?
- When reasoning extraction is active, responses can include reasoning_content:
  - non-streaming: message.reasoning_content (optional)
  - streaming: delta.reasoning_content chunks
- With reasoning-format none, thought text remains in message.content instead of extracted reasoning_content.

## Gaps
- I was not able to reliably retrieve full raw source files from GitHub via the available extraction path in a way that preserves full line-level context, so implementation claims are anchored to official README plus llama.cpp discussion posts that cite concrete source lines and server-emitted warnings.
