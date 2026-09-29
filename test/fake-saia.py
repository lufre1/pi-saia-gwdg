#!/usr/bin/env python3
"""Fake SAIA endpoint: fails the first N chat completions with 503, then succeeds.

Exists so the retry settings written by the installer can be proven to fire
without waiting for a real SAIA outage. Prints the bound port on stdout, writes
the running request count to $COUNT_FILE after every chat request.

  FAKE_FAIL_COUNT   how many 503s to serve before succeeding (default 3)
  COUNT_FILE        path to write the chat-request count to (default ./count)
  REPLY             the canned assistant reply (default OK-FAKE-RESUME)
"""
import http.server, json, os, sys, threading

FAIL_COUNT = int(os.environ.get("FAKE_FAIL_COUNT", "3"))
COUNT_FILE = os.environ.get("COUNT_FILE", "count")
REPLY = os.environ.get("REPLY", "OK-FAKE-RESUME")

lock = threading.Lock()
calls = 0


def chunk(delta, finish=None):
    return "data: " + json.dumps({
        "id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0,
        "model": "fake-model",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }) + "\n\n"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("fake-saia: " + fmt % a + "\n")

    def send(self, code, body, ctype="application/json"):
        body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self.send(200, json.dumps({"object": "list", "data": [
                {"id": "fake-model", "object": "model", "owned_by": "fake"}]}))
        else:
            self.send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.send(404, json.dumps({"error": "not found"}))

        global calls
        with lock:
            calls += 1
            n = calls
        with open(COUNT_FILE, "w") as f:
            f.write(str(n))
        self.log_message("chat request #%d (fail_count=%d)", n, FAIL_COUNT)

        if n <= FAIL_COUNT:
            return self.send(503, json.dumps(
                {"error": {"message": "Service Unavailable", "type": "server_error"}}))

        # Stream, because that is the path a real outage interrupts.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for part in (chunk({"role": "assistant", "content": REPLY}),
                     chunk({}, "stop"), "data: [DONE]\n\n"):
            raw = part.encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
