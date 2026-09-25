#!/usr/bin/env python3
"""Measure decode/prefill speed and speculative acceptance against a running llama-server."""
import json, sys, time, urllib.request

URL = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
PROMPTS = {
    "code": "Write a complete, well-commented Python implementation of an LRU cache with TTL expiry, "
            "thread safety, and a small pytest test suite.",
    "prose": "Explain, in about 500 words, how a hybrid linear/full-attention transformer reduces KV-cache "
             "memory, and what trade-offs it makes.",
    "json": "Produce a JSON array of 25 objects describing fictional cities, each with name, country, "
            "population, founded_year and a one-sentence description.",
}
LONG = ("The quick brown fox jumps over the lazy dog. " * 3000) + "\nSummarize the text above in one sentence."

def run(prompt, n_predict):
    body = json.dumps({"messages": [{"role": "user", "content": prompt}], "max_tokens": n_predict,
                       "seed": 42, "cache_prompt": False, "chat_template_kwargs": {"enable_thinking": False}}).encode()
    req = urllib.request.Request(URL + "/v1/chat/completions", body, {"Content-Type": "application/json"})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=900))
    tm = r.get("timings", {})
    return tm, time.time() - t

for name, p in list(PROMPTS.items()) + [("prefill-33k", LONG)]:
    tm, wall = run(p, 64 if name.startswith("prefill") else 768)
    acc = ""
    if tm.get("draft_n"):
        acc = f" draft_accept={tm.get('draft_n_accepted', 0) / tm['draft_n']:.2f}"
    print(f"{name:12s} prompt={tm.get('prompt_n')}t pp={tm.get('prompt_per_second', 0):8.1f} t/s  "
          f"gen={tm.get('predicted_n')}t tg={tm.get('predicted_per_second', 0):6.1f} t/s{acc}  wall={wall:.1f}s",
          flush=True)
