# shellcheck shell=bash
# saia-keyring.sh — automatic SAIA key swap for a harness installer (sourced).
#
# Vendored byte-identical from opencode-saia-gwdg/keyring/ into the src/ of every
# <harness>-saia installer, next to saia_keyring.py. Edit it there and run
# keyring/sync.sh — never edit a vendored copy.
#
# Opt-in only. By default the harness talks to SAIA directly with one key and
# depends on nothing else — an installer must work for anyone, proxy or not.
# With --keyring the harness is pointed at a local proxy (saia_keyring.py on
# http://127.0.0.1:8788/v1) that swaps to the next key when the active one is
# revoked, drained or rate limited — the opencode plugin's key rotation for any
# OpenAI-compatible harness.
#
# The sourcing installer:
#   1. routes its argument loop through keyring_arg for the flags below,
#   2. calls `keyring_setup "$SAIA_KEY"` once the primary key is known,
#   3. writes $SAIA_EFFECTIVE_BASE_URL (not $SAIA_BASE_URL) into the harness config.
#
# Flags:   --keyring (opt in) / --no-keyring (the default), and for --keyring:
#          --extra-keys k2,k3 (or env SAIA_API_KEYS_EXTRA), --extra-keys-file PATH
# Env:     SAIA_KEYRING_PORT (8788), SAIA_KEYRING_SERVICE (auto|systemd|launchd|rc|none),
#          SAIA_KEYRING_HOME, SAIA_KEYRING_CONFIG, SAIA_KEYRING_STATE_DIR, SAIA_KEYRING_BIN_DIR

KEYRING_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYRING_PROD_URL="https://chat-ai.academiccloud.de/v1"
KEYRING_MODE="${KEYRING_MODE:-}"   # on = --keyring, off = --no-keyring, "" = default (direct)
KEYRING_EXTRA_KEYS="${KEYRING_EXTRA_KEYS:-}"
KEYRING_EXTRA_KEYS_FILE="${KEYRING_EXTRA_KEYS_FILE:-}"
KEYRING_HOME="${SAIA_KEYRING_HOME:-$HOME/.local/share/saia-keyring}"
KEYRING_CONFIG="${SAIA_KEYRING_CONFIG:-$HOME/.config/saia-keyring/keyring.json}"
KEYRING_STATE_DIR="${SAIA_KEYRING_STATE_DIR:-$HOME/.cache/saia-keyring}"
KEYRING_BIN_DIR="${SAIA_KEYRING_BIN_DIR:-$HOME/.local/bin}"
KEYRING_ACTIVE=0
SAIA_EFFECTIVE_BASE_URL="${SAIA_BASE_URL:-$KEYRING_PROD_URL}"

# Usage lines for the installer's --help.
keyring_usage() {
  cat <<'EOF'
  --keyring                 Opt in to automatic key swap: run the local saia-keyring
                            proxy (needs python3) and route the harness through it
  --extra-keys <k2,k3>      With --keyring: extra SAIA keys to swap to (or SAIA_API_KEYS_EXTRA)
  --extra-keys-file <path>  With --keyring: extra keys from {"keys": [...]} (opencode's
                            saia-gwdg-keys.json) or one key per line
  --no-keyring              Talk to SAIA directly with one key (the default)
EOF
}

# keyring_arg "$@": consume a keyring flag at $1. Sets KEYRING_SHIFT to the
# number of words used; returns 1 when $1 is not a keyring flag.
keyring_arg() {
  KEYRING_SHIFT=1
  case "$1" in
    --extra-keys)       KEYRING_EXTRA_KEYS="${2:?--extra-keys needs a value}"; KEYRING_SHIFT=2 ;;
    --extra-keys-file)  KEYRING_EXTRA_KEYS_FILE="${2:?--extra-keys-file needs a path}"; KEYRING_SHIFT=2 ;;
    --keyring)          KEYRING_MODE=on ;;
    --no-keyring)       KEYRING_MODE=off ;;
    *)                  return 1 ;;
  esac
}

# Keys travel through the environment, never argv: other users can read argv
# from ps on a shared host, but not another user's /proc/<pid>/environ.
_keyring_collect() {
  KR_PRIMARY="$1" KR_EXTRA="${KEYRING_EXTRA_KEYS:-${SAIA_API_KEYS_EXTRA:-}}" \
  KR_EXTRA_FILE="$KEYRING_EXTRA_KEYS_FILE" KR_CONFIG="$KEYRING_CONFIG" python3 - <<'PY'
import json, os, sys

def from_file(path):
    try:
        text = open(os.path.expanduser(path)).read()
    except OSError as exc:
        sys.exit(f"ERROR: cannot read extra keys file {path}: {exc.strerror}")
    try:
        data = json.loads(text)
    except ValueError:
        return [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
    if isinstance(data, dict):
        data = data.get("keys", [])
    return [k.strip() for k in data if isinstance(k, str) and k.strip()]

extra = [k.strip() for k in os.environ["KR_EXTRA"].split(",") if k.strip()]
if os.environ["KR_EXTRA_FILE"]:
    extra += from_file(os.environ["KR_EXTRA_FILE"])
source = "given"
if not extra:  # nothing new: keep the extras a previous install stored
    source = "kept"
    try:
        extra = [k for k in json.load(open(os.environ["KR_CONFIG"])).get("keys", [])[1:]
                 if isinstance(k, str) and k]
    except (OSError, ValueError, AttributeError):
        extra = []
keys = list(dict.fromkeys(k for k in [os.environ["KR_PRIMARY"].strip()] + extra if k))
print(json.dumps({"source": source if extra else "none", "keys": keys}))
PY
}

_keyring_field() {  # _keyring_field <json> <field>
  KR_JSON="$1" python3 -c 'import json,os,sys; v=json.loads(os.environ["KR_JSON"])[sys.argv[1]]; print(len(v) if isinstance(v, list) else v)' "$2"
}

_keyring_write_config() {  # keys JSON in KR_KEYS_JSON
  KR_UPSTREAM="${SAIA_BASE_URL:-$KEYRING_PROD_URL}" KR_PORT="$1" KR_CONFIG="$KEYRING_CONFIG" python3 - <<'PY'
import json, os, time
cfg = os.environ["KR_CONFIG"]
keys = json.loads(os.environ["KR_KEYS_JSON"])["keys"]
data = {"upstream": os.environ["KR_UPSTREAM"], "port": int(os.environ["KR_PORT"]), "keys": keys}
os.umask(0o077)
os.makedirs(os.path.dirname(cfg), exist_ok=True)
try:
    old = json.load(open(cfg))
except (OSError, ValueError):
    old = None
if old == data:
    raise SystemExit(0)
if old and old.get("keys") != keys:  # keys are precious: never drop a set silently
    bak = f"{cfg}.bak-{time.strftime('%Y%m%d%H%M%S')}"
    with open(bak, "w") as f:
        json.dump(old, f, indent=1)
    os.chmod(bak, 0o600)
    print(f"Backed up the previous key list to {bak}")
tmp = f"{cfg}.tmp-{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(data, f, indent=1)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, cfg)
PY
}

_keyring_config_port() {
  KR_CONFIG="$KEYRING_CONFIG" python3 -c '
import json, os
try:
    print(int(json.load(open(os.environ["KR_CONFIG"])).get("port") or 8788))
except (OSError, ValueError, AttributeError):
    print(8788)'
}

_keyring_health() {  # prints "<version> <pid>" of the proxy on port $1, or fails
  python3 - "$1" <<'PY'
import json, sys, urllib.request
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/_keyring/health", timeout=1) as r:
        h = json.loads(r.read())
except Exception:
    sys.exit(1)
if h.get("service") != "saia-keyring":
    sys.exit(1)
print(h.get("version"), h.get("pid"))
PY
}

_keyring_wait_healthy() {  # up to ~5 s
  local i
  for i in $(seq 1 50); do
    _keyring_health "$1" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# Copy saia_keyring.py into KEYRING_HOME unless a newer version is installed.
# Sets KEYRING_FILE_CHANGED=1 when the installed copy changed.
_keyring_install_file() {
  local src="$KEYRING_SRC_DIR/saia_keyring.py" dest="$KEYRING_HOME/saia_keyring.py" ours theirs
  KEYRING_FILE_CHANGED=0
  mkdir -p "$KEYRING_HOME" "$KEYRING_BIN_DIR"
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$KEYRING_PY" "$dest" >"$KEYRING_BIN_DIR/saia-keyring"
  chmod 755 "$KEYRING_BIN_DIR/saia-keyring"
  if [[ -f "$dest" ]]; then
    cmp -s "$src" "$dest" && return 0
    ours="$(python3 "$src" version)"
    theirs="$(python3 "$dest" version 2>/dev/null || echo 0)"
    if [[ "$(printf '%s\n%s\n' "$ours" "$theirs" | sort -V | tail -n 1)" != "$ours" ]]; then
      echo "Keeping the newer saia-keyring v$theirs already installed (this installer has v$ours)"
      return 0
    fi
  fi
  cp "$src" "$dest.tmp.$$"
  chmod 755 "$dest.tmp.$$"
  mv -f "$dest.tmp.$$" "$dest"
  KEYRING_FILE_CHANGED=1
}

_keyring_rc_file() {
  if [[ -n "${SAIA_SHELL_RC:-}" ]]; then echo "$SAIA_SHELL_RC"
  elif [[ "${SHELL:-}" == */zsh && -f "$HOME/.zshrc" ]]; then echo "$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then echo "$HOME/.bashrc"
  elif [[ -f "$HOME/.profile" ]]; then echo "$HOME/.profile"
  else echo "$HOME/.profile"
  fi
}

_keyring_service_mode() {
  local mode="${SAIA_KEYRING_SERVICE:-auto}"
  if [[ "$mode" == auto ]]; then
    if [[ "$(uname -s)" == Darwin ]] && command -v launchctl >/dev/null 2>&1; then mode=launchd
    elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then mode=systemd
    else mode=rc
    fi
  fi
  echo "$mode"
}

_keyring_start() {  # $1 = port; starts or restarts the proxy, by service mode
  local port="$1" mode dest="$KEYRING_HOME/saia_keyring.py" running pid restart="$KEYRING_FILE_CHANGED"
  local args=(serve --config "$KEYRING_CONFIG" --state-dir "$KEYRING_STATE_DIR")
  mode="$(_keyring_service_mode)"
  mkdir -p "$KEYRING_STATE_DIR"
  # A proxy left running from an older install (or by `ensure`) would keep the
  # port and serve stale code — stop it when the installed file changed.
  if running="$(_keyring_health "$port" 2>/dev/null)" && [[ "$restart" == 1 ]]; then
    pid="${running#* }"
    [[ "$mode" == systemd ]] && systemctl --user stop saia-keyring.service >/dev/null 2>&1 || true
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do _keyring_health "$port" >/dev/null 2>&1 || break; sleep 0.1; done
  fi
  case "$mode" in
    systemd)
      local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" unit
      unit="$unit_dir/saia-keyring.service"
      mkdir -p "$unit_dir"
      local new
      new="$(printf '%s\n' \
        "[Unit]" \
        "Description=saia-keyring: GWDG SAIA key-rotating proxy (127.0.0.1:$port)" \
        "StartLimitIntervalSec=60" \
        "StartLimitBurst=5" \
        "" \
        "[Service]" \
        "ExecStart=\"$KEYRING_PY\" \"$dest\" serve --config \"$KEYRING_CONFIG\" --state-dir \"$KEYRING_STATE_DIR\"" \
        "Restart=on-failure" \
        "RestartSec=5" \
        "StandardOutput=append:$KEYRING_STATE_DIR/proxy.log" \
        "StandardError=append:$KEYRING_STATE_DIR/proxy.log" \
        "" \
        "[Install]" \
        "WantedBy=default.target")"
      if [[ ! -f "$unit" || "$(cat "$unit")" != "$new" ]]; then
        printf '%s\n' "$new" >"$unit"
        restart=1
      fi
      systemctl --user daemon-reload
      systemctl --user enable saia-keyring.service >/dev/null 2>&1 || true
      if [[ "$restart" == 1 ]]; then
        systemctl --user restart saia-keyring.service
      else
        systemctl --user start saia-keyring.service
      fi
      if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" == no ]]; then
        echo "Note: the proxy runs while you are logged in. To keep it up after logout"
        echo "      (cron, nohup), run once: loginctl enable-linger $(id -un)"
      fi
      ;;
    launchd)
      local plist="$HOME/Library/LaunchAgents/de.gwdg.saia-keyring.plist" new a
      mkdir -p "$(dirname "$plist")"
      new="$(
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
          '<plist version="1.0"><dict>' \
          '  <key>Label</key><string>de.gwdg.saia-keyring</string>' \
          '  <key>ProgramArguments</key><array>'
        for a in "$KEYRING_PY" "$dest" "${args[@]}"; do printf '    <string>%s</string>\n' "$a"; done
        printf '%s\n' '  </array>' \
          '  <key>RunAtLoad</key><true/>' \
          '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>' \
          "  <key>StandardOutPath</key><string>$KEYRING_STATE_DIR/proxy.log</string>" \
          "  <key>StandardErrorPath</key><string>$KEYRING_STATE_DIR/proxy.log</string>" \
          '</dict></plist>'
      )"
      if [[ ! -f "$plist" || "$(cat "$plist")" != "$new" ]]; then
        printf '%s\n' "$new" >"$plist"
        restart=1
      fi
      if [[ "$restart" == 1 ]] || ! launchctl print "gui/$(id -u)/de.gwdg.saia-keyring" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/de.gwdg.saia-keyring" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$plist"
      fi
      ;;
    rc)
      local rc block
      rc="$(_keyring_rc_file)"
      block="( \"$KEYRING_PY\" \"$dest\" ensure --config \"$KEYRING_CONFIG\" --state-dir \"$KEYRING_STATE_DIR\" >/dev/null 2>&1 & )"
      touch "$rc"
      KR_RC="$rc" KR_BLOCK="$block" python3 - <<'PY'
import os, re
rc, block = os.environ["KR_RC"], os.environ["KR_BLOCK"]
text = open(rc).read()
new = f"# >>> saia-keyring (starts the SAIA key-rotating proxy) >>>\n{block}\n# <<< saia-keyring <<<\n"
pat = re.compile(r"# >>> saia-keyring.*?# <<< saia-keyring <<<\n", re.S)
text = pat.sub(lambda m: new, text) if pat.search(text) else text.rstrip("\n") + "\n\n" + new
open(rc, "w").write(text)
PY
      echo "No systemd/launchd user session: $rc now starts the proxy for every new shell"
      "$KEYRING_PY" "$dest" ensure --config "$KEYRING_CONFIG" --state-dir "$KEYRING_STATE_DIR" || true
      ;;
    none)
      "$KEYRING_PY" "$dest" ensure --config "$KEYRING_CONFIG" --state-dir "$KEYRING_STATE_DIR" || true
      ;;
    *)
      echo "WARNING: unknown SAIA_KEYRING_SERVICE=$mode" >&2
      return 1
      ;;
  esac
}

# keyring_setup <primary key>: decide, install, start; sets SAIA_EFFECTIVE_BASE_URL.
keyring_setup() {
  local primary="$1" collected n source port
  SAIA_EFFECTIVE_BASE_URL="${SAIA_BASE_URL:-$KEYRING_PROD_URL}"
  KEYRING_ACTIVE=0
  if [[ "$KEYRING_MODE" != on ]]; then
    # The default: SAIA directly, one key, nothing else to rely on. Behind a
    # test or benchmark gateway (SAIA_BASE_URL override) stay completely silent.
    [[ "$KEYRING_MODE" == off || "${SAIA_EFFECTIVE_BASE_URL%/}" != "$KEYRING_PROD_URL" ]] && return 0
    local oc="$HOME/.local/share/opencode/saia-gwdg-keys.json"
    if [[ -n "$KEYRING_EXTRA_KEYS$KEYRING_EXTRA_KEYS_FILE${SAIA_API_KEYS_EXTRA:-}" ]]; then
      echo "Note: extra SAIA keys not used — automatic key swap is opt-in (add --keyring)."
    elif [[ -f "$oc" ]]; then
      echo "Tip: opencode has extra SAIA keys in $oc — re-run with"
      echo "     --keyring --extra-keys-file $oc  to swap keys automatically (optional local proxy)."
    fi
    return 0
  fi
  KEYRING_PY="$(command -v python3 || true)"
  if [[ -z "$KEYRING_PY" ]]; then
    echo "WARNING: python3 not found — --keyring ignored, talking to SAIA directly with the primary key." >&2
    return 0
  fi
  collected="$(_keyring_collect "$primary")"
  n="$(_keyring_field "$collected" keys)"
  source="$(_keyring_field "$collected" source)"
  if (( n < 2 )); then
    echo "Note: --keyring with a single SAIA key — the proxy runs but has no key to swap to (add --extra-keys)."
  fi
  port="${SAIA_KEYRING_PORT:-$(_keyring_config_port)}"
  KR_KEYS_JSON="$collected" _keyring_write_config "$port"
  _keyring_install_file
  if ! _keyring_start "$port" || ! _keyring_wait_healthy "$port"; then
    echo "WARNING: saia-keyring did not answer on 127.0.0.1:$port (log: $KEYRING_STATE_DIR/proxy.log)." >&2
    echo "         Configuring the harness for SAIA directly, with the primary key only." >&2
    return 0
  fi
  KEYRING_ACTIVE=1
  SAIA_EFFECTIVE_BASE_URL="http://127.0.0.1:$port/v1"
  echo "Automatic key swap on: $n SAIA keys ($([[ $source == kept ]] && echo "extras kept from $KEYRING_CONFIG" || echo "stored in $KEYRING_CONFIG"))"
  echo "  proxy http://127.0.0.1:$port/v1 -> ${SAIA_BASE_URL:-$KEYRING_PROD_URL}   (status: saia-keyring status)"
}
