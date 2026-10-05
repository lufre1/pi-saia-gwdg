#!/usr/bin/env python3
"""saia-keyring: local key-rotating proxy for GWDG SAIA.

Brings the automatic key swap of plugin/saia-gwdg-plugin.js to every
OpenAI-compatible harness. The harness points its base URL at
http://127.0.0.1:<port>/v1 and keeps sending its usual SAIA key; the proxy
forwards each request upstream on the *active* key and swaps to the next one
when the active key is

  - revoked/expired (401/403): dropped from rotation, re-probed once a day;
  - drained: an x-ratelimit-remaining-{hour,day,month} header at or below the
    floors 5/10/30 parks it until that bucket resets (1 h / 24 h / 30 d);
  - rate limited (429): a minute-level 429 fails over at once when another key
    is usable, else waits ratelimit-reset (<=65 s) once, like the plugin.

Rotation is sticky (the active key serves until it is out, then the next
usable one, wrapping around) and only happens before the first response byte;
a stream that has started is relayed as-is. With no usable key left the proxy
answers locally: 401 when every key is rejected, 429 when they are drained.

Only requests carrying one of the configured keys are served, so other users
on a shared host cannot spend them through the loopback port.

    saia_keyring.py serve   [--config PATH]  run in the foreground
    saia_keyring.py ensure  [--config PATH]  start a detached server unless one answers
    saia_keyring.py status  [--config PATH]  per-key table
    saia_keyring.py version

Config (chmod 600), re-read whenever it changes:
    {"upstream": "https://chat-ai.academiccloud.de/v1", "port": 8788, "keys": ["k1", "k2"]}

Stdlib only, Python 3.8+.
"""

import argparse
import hashlib
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

VERSION = "1.0.0"

DEFAULT_CONFIG = Path(os.environ.get("SAIA_KEYRING_CONFIG")
                      or Path.home() / ".config/saia-keyring/keyring.json")
DEFAULT_STATE_DIR = Path(os.environ.get("SAIA_KEYRING_STATE_DIR")
                         or Path.home() / ".cache/saia-keyring")
DEFAULT_UPSTREAM = "https://chat-ai.academiccloud.de/v1"
DEFAULT_PORT = 8788             # the benchmark gateway holds 8787
LOCAL_PREFIX = "/v1"
HEALTH_PATH = "/_keyring/health"

# --- mirrored from saia-gwdg-plugin.js
FLOORS = {"hour": 5, "day": 10, "month": 30}
RESET_TTL_S = {"hour": 3600, "day": 86400, "month": 30 * 86400}
BUCKETS = ("minute", "hour", "day", "month")
MAX_429_WAIT_S = 65
DEFAULT_429_WAIT_S = 60
# --- keyring-only
DEAD_REPROBE_S = 86400          # a reinstated key comes back on its own
UPSTREAM_TIMEOUT_S = 600        # stall handling stays with the harness
RENEW_HINT = "Get a new one from https://saia.gwdg.de/ and re-run the installer"

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
              "trailer", "trailers", "transfer-encoding", "upgrade"}
STRIP_REQUEST = HOP_BY_HOP | {"host", "authorization", "x-api-key", "api-key", "content-length",
                              "accept-encoding"}
STRIP_RESPONSE = HOP_BY_HOP | {"content-length", "server", "date"}


def now():
    """Wall clock; tests patch this to jump past reset TTLs."""
    return time.time()


def utc_iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(
        timespec="milliseconds").replace("+00:00", "Z")


def log(msg):
    print(f"[saia-keyring {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}",
          file=sys.stderr, flush=True)


def write_json_atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(json.dumps(data, indent=1))
    os.replace(tmp, path)


def openai_error(message, etype, code=None):
    return {"error": {"message": message, "type": etype, "code": code}}


def load_config(path):
    """(upstream, port, keys) from the config file; keys de-duplicated in order."""
    cfg = json.loads(Path(path).read_text())
    keys = [k.strip() for k in cfg.get("keys", []) if isinstance(k, str) and k.strip()]
    return (str(cfg.get("upstream") or DEFAULT_UPSTREAM).rstrip("/"),
            int(cfg.get("port") or DEFAULT_PORT), list(dict.fromkeys(keys)))


# ---------------------------------------------------------------- keys

class KeyState:
    def __init__(self, key, index):
        self.key = key
        # Persisted state is keyed by a hash, never by position: reordering
        # or replacing keys in the config must not move "dead" onto another key.
        self.id = hashlib.sha256(key.encode()).hexdigest()[:12]
        self.relabel(index)
        self.remaining = {b: None for b in BUCKETS}
        self.exhausted = {"hour": 0.0, "day": 0.0, "month": 0.0}  # epoch s, 0 = no
        self.dead_since = 0.0
        self.parked_until = 0.0     # minute-level 429
        self.updated_at = None

    def relabel(self, index):
        self.label = f"key{index + 1}(…{self.key[-4:]})"

    def usable(self, t):
        if self.dead_since:
            if t - self.dead_since < DEAD_REPROBE_S:
                return False
            self.dead_since = 0.0
            log(f"{self.label} rejected {DEAD_REPROBE_S // 3600}h ago — re-probing it")
        if self.parked_until > t:
            return False
        ok = True
        for b in ("hour", "day", "month"):
            rem = self.remaining[b]
            if rem is not None and rem <= FLOORS[b]:
                self.mark_exhausted(b, t)
            if self.exhausted[b]:
                if t - self.exhausted[b] < RESET_TTL_S[b]:
                    ok = False
                else:
                    self.exhausted[b] = 0.0     # TTL passed — the bucket has reset
        return ok

    def mark_exhausted(self, bucket, t):
        self.exhausted[bucket] = t
        # Forget the count: after the TTL the key is retried optimistically and
        # the next response headers tell its real state (plugin semantics).
        self.remaining[bucket] = None
        log(f"{self.label} exhausted ({bucket} bucket)")

    def why_out(self, t):
        if self.dead_since:
            return "rejected (401/403)"
        buckets = [b for b in ("hour", "day", "month")
                   if self.exhausted[b] and t - self.exhausted[b] < RESET_TTL_S[b]]
        if buckets:
            return "+".join(buckets)
        if self.parked_until > t:
            return f"rate limited (retry in {int(self.parked_until - t) + 1}s)"
        return "exhausted"

    def to_state(self):
        return {"label": self.label, "dead_since": self.dead_since,
                "exhausted": dict(self.exhausted), "parked_until": self.parked_until}

    def from_state(self, entry):
        self.dead_since = float(entry.get("dead_since") or 0)
        self.parked_until = float(entry.get("parked_until") or 0)
        for b, v in (entry.get("exhausted") or {}).items():
            if b in self.exhausted:
                self.exhausted[b] = float(v or 0)


class KeyRing:
    """The plugin's pickKey/keyUsable/markExhausted, shared by all handler
    threads. Remaining counts are not restored on restart (they go stale);
    dead/exhausted/parked stamps are, since they carry their own TTLs."""

    def __init__(self, keys, state_dir):
        self.lock = threading.RLock()
        self.state_file = Path(state_dir) / "keys_state.json"
        self.budget_file = Path(state_dir) / "budget.json"
        self.keys = []
        self.active = 0
        saved = {}
        try:
            saved = json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            pass
        self._saved = saved if isinstance(saved, dict) else {}
        self.set_keys(keys)

    def set_keys(self, keys):
        with self.lock:
            old = {ks.key: ks for ks in self.keys}
            active_key = self.keys[self.active].key if self.keys else None
            fresh = []
            for i, k in enumerate(keys):
                ks = old.get(k)
                if ks is None:
                    ks = KeyState(k, i)
                    if ks.id in self._saved:
                        ks.from_state(self._saved[ks.id])
                ks.relabel(i)
                fresh.append(ks)
            self.keys = fresh
            self.active = next((i for i, ks in enumerate(fresh) if ks.key == active_key), 0)

    def owns(self, key):
        with self.lock:
            return any(ks.key == key for ks in self.keys)

    def pick(self):
        """The active key while it is usable, else the next usable one
        (wrapping around). None when every key is out."""
        with self.lock:
            t = now()
            n = len(self.keys)
            for i in range(n):
                idx = (self.active + i) % n
                if self.keys[idx].usable(t):
                    if idx != self.active:
                        log(f"switching {self.keys[self.active].label} -> {self.keys[idx].label}")
                        self.active = idx
                    return self.keys[idx]
            return None

    def other_usable(self, ks):
        with self.lock:
            t = now()
            return any(o is not ks and o.usable(t) for o in self.keys)

    def observe(self, ks, headers):
        with self.lock:
            seen = False
            for b in BUCKETS:
                v = headers.get(f"x-ratelimit-remaining-{b}")
                if v is None:
                    continue
                try:
                    ks.remaining[b] = int(float(v))
                    seen = True
                except ValueError:
                    pass
            if seen:
                ks.updated_at = now()
            return seen

    def mark_dead(self, ks):
        with self.lock:
            if ks.dead_since:   # concurrent requests (mcode sends 3 per turn) share one 401
                return
            ks.dead_since = now()
        log(f"{ks.label} rejected (401/403) — dropped from rotation. "
            f"The key is revoked or expired; {RENEW_HINT[0].lower() + RENEW_HINT[1:]}.")

    def mark_exhausted(self, ks, bucket):
        with self.lock:
            ks.mark_exhausted(bucket, now())

    def park(self, ks, seconds):
        with self.lock:
            ks.parked_until = now() + seconds
        log(f"429 on {ks.label} — parked {seconds:.0f}s, failing over")

    def all_out(self):
        """(status, message, retry_after) once pick() returned None."""
        with self.lock:
            t = now()
            per = "; ".join(f"{ks.label}: {ks.why_out(t)}" for ks in self.keys)
            n = len(self.keys)
            if n and all(ks.dead_since for ks in self.keys):
                return 401, (f"All {n} SAIA key(s) rejected by SAIA ({per}) — the key(s) are "
                             f"revoked or expired. {RENEW_HINT}."), None
            parked = [ks.parked_until - t for ks in self.keys if ks.parked_until > t]
            retry = int(min(parked)) + 1 if parked else None
            return 429, (f"All {n} SAIA key(s) nearly exhausted ({per}) — aborting instead of "
                         f"retry-spinning. Wait for the buckets to reset."), retry

    def persist(self):
        with self.lock:
            state = {ks.id: ks.to_state() for ks in self.keys}
            t = now()
            active = self.keys[self.active] if self.keys else None
            budget = {
                "updatedAt": utc_iso(t), "source": "saia-keyring", "activeIndex": self.active,
                "remaining": dict(active.remaining) if active else {},
                # the plugin's snapshot format (exhausted stamps in epoch ms)
                "keys": [{"label": ks.label,
                          "updatedAt": utc_iso(ks.updated_at) if ks.updated_at else None,
                          "remaining": dict(ks.remaining),
                          "exhausted": {b: int(v * 1000) for b, v in ks.exhausted.items()},
                          "dead": bool(ks.dead_since)} for ks in self.keys]}
            self._saved.update(state)
            saved = dict(self._saved)
        try:
            write_json_atomic(self.state_file, saved)
            write_json_atomic(self.budget_file, budget)
        except OSError as exc:
            log(f"could not write state: {exc}")

    def describe(self):
        with self.lock:
            t = now()
            return [{"label": ks.label, "active": i == self.active, "usable": ks.usable(t),
                     "dead": bool(ks.dead_since),
                     "out": None if ks.usable(t) else ks.why_out(t),
                     "remaining": dict(ks.remaining),
                     "updatedAt": utc_iso(ks.updated_at) if ks.updated_at else None}
                    for i, ks in enumerate(self.keys)]


# ---------------------------------------------------------------- proxy

class AllKeysOut(Exception):
    pass


class Keyring:
    def __init__(self, config_path, state_dir):
        self.config_path = Path(config_path)
        self.state_dir = Path(state_dir)
        self.cfg_lock = threading.Lock()
        self.cfg_mtime = None
        upstream, self.port, keys = load_config(self.config_path)
        if not keys:
            raise SystemExit(f"no keys in {self.config_path}")
        self.cfg_mtime = self.config_path.stat().st_mtime_ns
        self.set_upstream(upstream)
        self.ring = KeyRing(keys, self.state_dir)
        log(f"{len(keys)} key(s) in rotation, upstream {upstream}, v{VERSION}")

    def set_upstream(self, upstream):
        self.upstream_url = upstream
        self.upstream = urlsplit(upstream)

    def reload_if_changed(self):
        """Pick up a reinstall's new keys without a restart."""
        try:
            mtime = self.config_path.stat().st_mtime_ns
        except OSError:
            return
        if mtime == self.cfg_mtime:
            return
        with self.cfg_lock:
            if mtime == self.cfg_mtime:
                return
            try:
                upstream, _port, keys = load_config(self.config_path)
            except (OSError, ValueError) as exc:
                log(f"config reload failed, keeping the old one: {exc}")
                self.cfg_mtime = mtime
                return
            self.cfg_mtime = mtime
            self.set_upstream(upstream)
            self.ring.set_keys(keys)
            log(f"config reloaded: {len(keys)} key(s), upstream {upstream}")

    def connect(self):
        u = self.upstream
        if u.scheme == "https":
            return http.client.HTTPSConnection(u.hostname, u.port or 443,
                                               timeout=UPSTREAM_TIMEOUT_S,
                                               context=ssl.create_default_context())
        return http.client.HTTPConnection(u.hostname, u.port or 80, timeout=UPSTREAM_TIMEOUT_S)

    def attempt(self, ks, method, path, headers, body):
        conn = self.connect()
        h = dict(headers)
        h["Authorization"] = f"Bearer {ks.key}"
        try:
            conn.request(method, (self.upstream.path or "") + path, body=body, headers=h)
            return conn, conn.getresponse()
        except BaseException:
            conn.close()
            raise

    def exchange(self, method, path, headers, body):
        """The plugin's rotation ladder, until a response worth relaying.
        Returns (conn, resp, ks); raises AllKeysOut or OSError/HTTPException."""
        waited_429 = False
        for _ in range(4 * max(len(self.ring.keys), 1) + 2):
            ks = self.ring.pick()
            if ks is None:
                raise AllKeysOut()
            conn, resp = self.attempt(ks, method, path, headers, body)
            lower = {k.lower(): v for k, v in resp.getheaders()}
            if self.ring.observe(ks, lower):
                self.ring.persist()
            if resp.status in (401, 403):
                resp.read()
                conn.close()
                self.ring.mark_dead(ks)
                self.ring.persist()
                continue
            if resp.status == 429:
                resp.read()
                conn.close()
                drained = [b for b in ("hour", "day", "month")
                           if ks.remaining[b] is not None and ks.remaining[b] <= FLOORS[b]]
                if drained:                      # a real quota, not a burst
                    for b in drained:
                        self.ring.mark_exhausted(ks, b)
                    self.ring.persist()
                    continue
                try:
                    wait = float(lower["ratelimit-reset"])
                except (KeyError, ValueError):
                    wait = DEFAULT_429_WAIT_S
                wait = min(max(wait, 1.0), MAX_429_WAIT_S)
                if self.ring.other_usable(ks):
                    self.ring.park(ks, wait)
                    self.ring.persist()
                    continue
                if not waited_429:               # single usable key: wait once, retry
                    waited_429 = True
                    log(f"429 on {ks.label} — waiting {wait:.0f}s before one retry")
                    time.sleep(wait)
                    continue
                self.ring.mark_exhausted(ks, "hour")
                self.ring.persist()
                continue
            return conn, resp, ks
        raise AllKeysOut()


def make_handler(kr):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = f"saia-keyring/{VERSION}"

        def log_message(self, fmt, *args):
            pass

        def send_json(self, status, obj, headers=None):
            body = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def read_body(self):
            if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
                parts = []
                while True:
                    size = int(self.rfile.readline().split(b";", 1)[0].strip() or b"0", 16)
                    if size == 0:
                        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                            pass             # trailers
                        return b"".join(parts)
                    parts.append(self.rfile.read(size))
                    self.rfile.readline()
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n else None

        def client_key(self):
            auth = self.headers.get("Authorization") or ""
            if auth.lower().startswith("bearer "):
                return auth[7:].strip()
            return (self.headers.get("x-api-key") or self.headers.get("api-key") or "").strip()

        def health(self):
            self.send_json(200, {"service": "saia-keyring", "version": VERSION,
                                 "upstream": kr.upstream_url, "pid": os.getpid(),
                                 "keys": kr.ring.describe()})

        def proxy(self, method):
            try:
                self.handle_proxy(method)
            except (BrokenPipeError, ConnectionResetError):
                # the harness hung up first (its own timeout, Ctrl-C) — nothing to answer
                self.close_connection = True

        def handle_proxy(self, method):
            kr.reload_if_changed()
            path = self.path
            if path.split("?", 1)[0] == HEALTH_PATH and method == "GET":
                return self.health()
            body = self.read_body()
            if not (path == LOCAL_PREFIX or path.startswith(LOCAL_PREFIX + "/")
                    or path.startswith(LOCAL_PREFIX + "?")):
                return self.send_json(404, openai_error(
                    f"saia-keyring only proxies {LOCAL_PREFIX}/*, got {path}",
                    "invalid_request_error"))
            if not kr.ring.owns(self.client_key()):
                return self.send_json(401, openai_error(
                    f"saia-keyring: this API key is not in {kr.config_path} — re-run the "
                    "SAIA installer to register it", "authentication_error", "unknown_key"))
            headers = {k: v for k, v in self.headers.items() if k.lower() not in STRIP_REQUEST}
            headers["Accept-Encoding"] = "identity"
            if body is not None:
                headers["Content-Length"] = str(len(body))
            try:
                conn, resp, ks = kr.exchange(method, path[len(LOCAL_PREFIX):], headers, body)
            except AllKeysOut:
                status, message, retry = kr.ring.all_out()
                log(message)
                code = "invalid_api_key" if status == 401 else "rate_limit_exceeded"
                etype = "authentication_error" if status == 401 else "rate_limit_error"
                return self.send_json(status, openai_error(message, etype, code),
                                      {"Retry-After": str(retry)} if retry else None)
            except (OSError, http.client.HTTPException) as exc:
                timeout = isinstance(exc, (socket.timeout, TimeoutError))
                self.close_connection = True
                return self.send_json(504 if timeout else 502, openai_error(
                    f"saia-keyring: upstream {kr.upstream_url} "
                    f"{'timed out' if timeout else 'unreachable'}: {exc}", "server_error"))
            try:
                self.relay(method, conn, resp, ks)
            finally:
                conn.close()

        def relay(self, method, conn, resp, ks):
            """Byte relay — SSE passes through unbuffered."""
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in STRIP_RESPONSE:
                    self.send_header(k, v)
            self.send_header("x-saia-keyring-key", ks.label.replace("…", "..."))  # latin-1 only
            length = resp.getheader("Content-Length")
            no_body = method == "HEAD" or resp.status in (204, 304) or 100 <= resp.status < 200
            chunked = not no_body and (length is None or resp.getheader("Transfer-Encoding"))
            if no_body:
                self.send_header("Content-Length", "0")
            elif chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", length)
            self.end_headers()
            if no_body:
                return
            try:
                while True:
                    data = resp.read1(65536)
                    if not data:
                        break
                    if chunked:
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                    else:
                        self.wfile.write(data)
                    self.wfile.flush()
                if chunked:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
            except (OSError, http.client.HTTPException):
                # client went away, or upstream cut the stream: drop the
                # downstream connection so the harness sees a truncated body
                self.close_connection = True

        def do_GET(self):
            self.proxy("GET")

        def do_POST(self):
            self.proxy("POST")

        def do_PUT(self):
            self.proxy("PUT")

        def do_PATCH(self):
            self.proxy("PATCH")

        def do_DELETE(self):
            self.proxy("DELETE")

        def do_HEAD(self):
            self.proxy("HEAD")

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(config_path, state_dir, port=None):
    kr = Keyring(config_path, state_dir)
    srv = Server(("127.0.0.1", kr.port if port is None else port), make_handler(kr))
    return kr, srv


# ---------------------------------------------------------------- CLI

def fetch_health(port, timeout=2.0):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{HEALTH_PATH}",
                                    timeout=timeout) as resp:
            data = json.loads(resp.read())
            return data if data.get("service") == "saia-keyring" else None
    except (OSError, ValueError, urllib.error.URLError):
        return None


def config_port(config_path):
    try:
        return load_config(config_path)[1]
    except (OSError, ValueError):
        return DEFAULT_PORT


def cmd_serve(args):
    try:
        port = load_config(args.config)[1]
    except (OSError, ValueError) as exc:
        log(f"cannot read {args.config}: {exc}")
        return 1
    try:
        kr, srv = make_server(args.config, args.state_dir)
    except OSError as exc:
        running = fetch_health(port)
        if running:
            # e.g. `ensure` already started one: exit cleanly so a service
            # manager with Restart=on-failure does not loop
            log(f"already running on 127.0.0.1:{port} (pid {running.get('pid')}, "
                f"v{running.get('version')})")
            return 0
        log(f"cannot listen on 127.0.0.1:{port}: {exc}")
        return 1
    log(f"listening on http://127.0.0.1:{srv.server_address[1]}{LOCAL_PREFIX}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def cmd_ensure(args):
    port = config_port(args.config)
    if fetch_health(port):
        return 0
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    with open(state_dir / "proxy.log", "ab") as logf:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve",
                          "--config", str(args.config), "--state-dir", str(state_dir)],
                         stdin=subprocess.DEVNULL, stdout=logf, stderr=logf,
                         start_new_session=True, close_fds=True)
    deadline = time.time() + 5
    while time.time() < deadline:
        if fetch_health(port, timeout=0.5):
            return 0
        time.sleep(0.1)
    print(f"saia-keyring did not come up on 127.0.0.1:{port} — see {state_dir / 'proxy.log'}",
          file=sys.stderr)
    return 1


def cmd_status(args):
    port = config_port(args.config)
    h = fetch_health(port)
    if not h:
        print(f"saia-keyring is not running on 127.0.0.1:{port} "
              f"(start it: {os.path.abspath(__file__)} ensure)")
        return 1
    print(f"saia-keyring v{h['version']} on http://127.0.0.1:{port}{LOCAL_PREFIX} "
          f"-> {h['upstream']}")
    dead = []
    for k in h["keys"]:
        rem = k["remaining"]
        counts = "/".join("?" if rem.get(b) is None else str(rem[b]) for b in BUCKETS)
        state = "ACTIVE" if k["active"] and k["usable"] else ("ok" if k["usable"] else k["out"])
        print(f"  {k['label']:<18} {state:<28} left min/hour/day/month: {counts}")
        if k["dead"]:
            dead.append(k["label"])
    if dead:
        print(f"\n{', '.join(dead)} rejected by SAIA (revoked or expired). {RENEW_HINT}.")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="saia-keyring", description=__doc__.split("\n\n")[0])
    p.add_argument("command", choices=["serve", "ensure", "status", "version"])
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    p.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    args = p.parse_args(argv)
    if args.command == "version":
        print(VERSION)
        return 0
    return {"serve": cmd_serve, "ensure": cmd_ensure, "status": cmd_status}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
