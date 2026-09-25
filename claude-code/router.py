#!/usr/bin/env python3
"""Model-name router for Claude Code: local models behind an Anthropic-hosted main session.

Claude Code sends every request (main session, subagents, side calls) to ANTHROPIC_BASE_URL.
Requests whose JSON body has a `model` matching LOCAL_MODEL_RE go to the local llama.cpp server;
everything else goes to api.anthropic.com byte-for-byte (headers included, so subscription/OAuth
and API-key auth keep working).

Local requests are normalised so that they work with any model's stock chat template and keep
llama.cpp's prompt cache reusable. Both rewrites are pure functions of the request, so a
conversation's requests still extend each other exactly:
  1. Mid-conversation system messages (role "system"/"developer" inside `messages`, which Claude
     Code sends) are folded into the neighbouring user turn as <system-reminder> text. Most chat
     templates reject a system message that is not first.
  2. Lines starting with "x-anthropic-billing-header:" are removed from the system prompt. They
     carry a per-session value that sits early in the rendered prompt and would stop llama.cpp from
     reusing the cached prefix across sessions (i.e. for every new subagent).

Env:
  ROUTER_PORT      listen port on 127.0.0.1                      (default 8098)
  LOCAL_UPSTREAM   llama.cpp base URL                             (default http://127.0.0.1:8080)
  REMOTE_UPSTREAM  Anthropic base URL                             (default https://api.anthropic.com)
  LOCAL_MODEL_RE   regex on body.model selecting the local route  (default ^qwen)
  ROUTER_LOG       JSONL file for per-request metadata (route, model, status, token usage and a
                   conversation hash for local calls); never headers or content. Unset = no log.
"""
import hashlib, http.client, http.server, json, os, re, threading, time, urllib.parse

PORT = int(os.environ.get("ROUTER_PORT", "8098"))
LOCAL = urllib.parse.urlsplit(os.environ.get("LOCAL_UPSTREAM", "http://127.0.0.1:8080"))
REMOTE = urllib.parse.urlsplit(os.environ.get("REMOTE_UPSTREAM", "https://api.anthropic.com"))
LOCAL_RE = re.compile(os.environ.get("LOCAL_MODEL_RE", "^qwen"))
LOG = os.environ.get("ROUTER_LOG")
BILLING_LINE = re.compile(r"^x-anthropic-billing-header:.*(?:\n|$)", re.M)
HOP = {"host", "connection", "keep-alive", "transfer-encoding", "content-length", "accept-encoding", "proxy-connection"}
AUTH = {"authorization", "x-api-key"}
log_lock = threading.Lock()


def as_blocks(content):
    return [{"type": "text", "text": content}] if isinstance(content, str) else list(content or [])


def strip_billing(system):
    if isinstance(system, str):
        return BILLING_LINE.sub("", system)
    if isinstance(system, list):
        out = []
        for block in system:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                text = BILLING_LINE.sub("", block["text"])
                if not text.strip():
                    continue
                block = {**block, "text": text}
            out.append(block)
        return out
    return system


def fold_system_messages(messages):
    """Fold role=system/developer messages into the previous user turn (or the next one)."""
    out, pending = [], []
    for msg in messages:
        if msg.get("role") in ("system", "developer"):
            texts = [b.get("text", "") for b in as_blocks(msg.get("content")) if b.get("type") == "text"]
            reminder = {"type": "text", "text": "<system-reminder>\n" + "\n\n".join(texts) + "\n</system-reminder>"}
            if out and out[-1].get("role") == "user":
                out[-1] = {**out[-1], "content": as_blocks(out[-1].get("content")) + [reminder]}
            else:
                pending.append(reminder)
            continue
        if pending and msg.get("role") == "user":
            msg = {**msg, "content": pending + as_blocks(msg.get("content"))}
            pending = []
        elif pending:
            out.append({"role": "user", "content": pending})
            pending = []
        out.append(msg)
    if pending:
        out.append({"role": "user", "content": pending})
    return out


def rewrite_local(body):
    try:
        req = json.loads(body)
    except ValueError:
        return body, None, None
    if not isinstance(req, dict):
        return body, None, None
    if "system" in req:
        req["system"] = strip_billing(req["system"])
    if isinstance(req.get("messages"), list):
        req["messages"] = fold_system_messages(req["messages"])
    messages = req.get("messages") or []
    # conversation id for the log: hash of the first message (no content is logged)
    conv = hashlib.sha1(json.dumps(messages[:1], sort_keys=True).encode()).hexdigest()[:10] if messages else None
    return json.dumps(req, ensure_ascii=False).encode(), len(messages), conv


def connect(u):
    cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    return cls(u.hostname, u.port, timeout=3600)


class Router(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle_any(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else b""
        model = None
        if body and self.headers.get("content-type", "").startswith("application/json"):
            try:
                model = json.loads(body).get("model")
            except (ValueError, AttributeError):
                pass
        local = bool(model and LOCAL_RE.search(model))
        up = LOCAL if local else REMOTE
        n_messages = conv = None
        if local:
            body, n_messages, conv = rewrite_local(body)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP and not (local and k.lower() in AUTH)}
        headers["Host"] = up.netloc
        t0 = time.time()
        try:
            conn = connect(up)
            conn.request(self.command, (up.path.rstrip("/") + self.path) or "/", body, headers)
            resp = conn.getresponse()
        except OSError as e:
            self.send_error(502, f"upstream {up.netloc}: {e}")
            return
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        captured = bytearray()
        try:
            while chunk := resp.read1(65536):
                if local and LOG:
                    captured += chunk
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
        if LOG:
            rec = {"t": round(t0, 3), "dur": round(time.time() - t0, 2), "route": "local" if local else "remote",
                   "method": self.command, "path": self.path.split("?")[0], "model": model,
                   "status": resp.status, "messages": n_messages, "conv": conv}
            for m in re.finditer(rb'"usage":(\{[^}]*\})', captured):
                try:
                    rec.setdefault("usage", {}).update(json.loads(m.group(1)))
                except ValueError:
                    pass
            with log_lock, open(LOG, "a") as f:
                f.write(json.dumps(rec) + "\n")

    do_GET = do_POST = do_HEAD = do_PUT = do_DELETE = do_PATCH = handle_any


if __name__ == "__main__":
    print(f"router on 127.0.0.1:{PORT}: model~/{LOCAL_RE.pattern}/ -> {LOCAL.geturl()}, else -> {REMOTE.geturl()}", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Router).serve_forever()
