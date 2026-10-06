#!/usr/bin/env bash
#
# install-pi-saia-gwdg.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the pi-saia-gwdg repo)
# Source: pi-saia-gwdg commit e2519d3, packed 2026-10-06T06:16:05Z
#
# Installs the GWDG SAIA setup for pi: provider + models + default model.

set -euo pipefail

AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MODELS_JSON="$AGENT_DIR/models.json"
SETTINGS_JSON="$AGENT_DIR/settings.json"

usage() {
  cat <<'USAGE'
Usage: SAIA_API_KEY="your-key" bash install-pi-saia-gwdg.sh [OPTIONS]

Installs the GWDG SAIA setup for pi:
  - Installs pi (if missing) via the official installer
  - Writes ~/.pi/agent/models.json registering the GWDG SAIA endpoint
  - Writes ~/.pi/agent/settings.json making SAIA the default model

Options:
  -y, --yes           answer yes to prompts (e.g. installing pi)
      --key <value>   SAIA API key (overrides SAIA_API_KEY env)
      --key-file <p>  file containing the SAIA API key
      --extra-keys <k2,k3>      extra SAIA keys for automatic failover
                                (or SAIA_API_KEYS_EXTRA, which keeps them out of ps)
      --extra-keys-file <path>  extra keys from {"keys": [...]} (opencode's
                                saia-gwdg-keys.json) or one key per line
      --keyring                 opt in: route through the local key-rotating proxy
      --no-keyring              talk to SAIA directly with one key (the default)
  -h, --help          show this help

The API key is taken from --key, --key-file or the SAIA_API_KEY environment
variable; if none of them is set, you are prompted for it. The key is persisted
to your shell rc (as SAIA_API_KEY) so pi can resolve it at runtime.
Existing ~/.pi/agent/models.json and settings.json are backed up to .bak-<timestamp>/ first.

With --keyring pi talks to a local proxy (saia-keyring, 127.0.0.1:8788) that swaps
to the next key when the active one is revoked, drained or rate limited.
USAGE
}

# Pull the key out of a previous install so a reinstall does not ask again.
detect_shell_rc() {
  if [[ -n "${SAIA_SHELL_RC:-}" ]]; then
    echo "$SAIA_SHELL_RC"
  elif [[ -n "${ZSH_VERSION:-}" && -f "$HOME/.zshrc" ]]; then
    echo "$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    echo "$HOME/.bashrc"
  elif [[ -f "$HOME/.profile" ]]; then
    echo "$HOME/.profile"
  else
    echo ""
  fi
}

key_from_config() {
  local rc
  rc="$(detect_shell_rc)"
  [[ -n "$rc" && -f "$rc" ]] || return 0
  awk -F= '/^[[:space:]]*export[[:space:]]+SAIA_API_KEY=/{sub(/^[^=]*=/,""); gsub(/[\x27"]/,""); print; exit}' "$rc"
  return 0
}

prompt_for_key() {
  if ! { : </dev/tty; } 2>/dev/null; then   # -r only stats; this actually opens it
    echo "ERROR: No SAIA API key given and no terminal to ask on." >&2
    echo "Set it: SAIA_API_KEY=\"your-key\" bash install-pi-saia-gwdg.sh" >&2
    echo "Get one at https://chat-ai.academiccloud.de/" >&2
    exit 1
  fi
  local key=""
  for _ in 1 2 3; do
    read -rsp "GWDG SAIA API key (input hidden): " key </dev/tty
    echo >&2
    key="${key//[[:space:]]/}"   # paste hygiene; SAIA keys carry no whitespace
    if [[ -n "$key" ]]; then
      export SAIA_API_KEY="$key"
      return
    fi
    echo "Key cannot be empty." >&2
  done
  echo "ERROR: no key entered." >&2
  exit 1
}

ASSUME_YES=0
KEY=""
KEY_FILE=""
KEYRING_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --key|--key-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      if [[ $1 == --key ]]; then KEY="$2"; else KEY_FILE="$2"; fi
      shift 2
      ;;
    --extra-keys|--extra-keys-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      KEYRING_ARGS+=("$1" "$2")
      shift 2
      ;;
    --keyring|--no-keyring) KEYRING_ARGS+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Obtain the API key ───────────────────────────────────────────────
# Reuse a key from a previous install; only ask when there is none to reuse,
# and ask before anything is installed, so an empty-handed user loses nothing.
if [[ -z "$KEY" && -z "$KEY_FILE" && -z "${SAIA_API_KEY:-}" ]]; then
  SAIA_API_KEY="$(key_from_config)"
  if [[ -n "$SAIA_API_KEY" ]]; then
    export SAIA_API_KEY
    echo "Reusing the SAIA key already in your shell rc (pass --key to replace it)."
  else
    prompt_for_key
  fi
fi

# ── Unpack the bundled source files ──────────────────────────────────
# Into a temp dir, not next to the installer: this file is meant to be copied
# to a fresh machine on its own, and it must not litter (or overwrite) a repo
# checkout it happens to be run from.
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
mkdir -p "$EXTRACT_DIR/src"

# ── Packed source files ────────────────────────────────────────────
cat >"$EXTRACT_DIR/src/add-saia-pi.sh" <<'__PSG_EOF__'
#!/usr/bin/env bash
set -euo pipefail

# Base URL override for tests and local gateways (default: production SAIA).
SAIA_BASE_URL="${SAIA_BASE_URL:-https://chat-ai.academiccloud.de/v1}"

# add-saia-pi.sh — Add GWDG SAIA provider to Pi
#
# Reads SAIA API key from environment variable SAIA_API_KEY or --key/--key-file.
# Installs Pi if missing (via the official installer), then writes
# ~/.pi/agent/models.json registering the GWDG SAIA OpenAI-compatible endpoint
# and ~/.pi/agent/settings.json making SAIA the default model.
#
# The key is referenced in models.json as "$SAIA_API_KEY" (Pi env interpolation)
# and persisted to the user's shell rc so Pi can resolve it at runtime. The raw
# key is never written into models.json.
#
# With --keyring (opt-in) and extra keys (SAIA_API_KEYS_EXTRA / --extra-keys /
# --extra-keys-file) pi is pointed at the local saia-keyring proxy instead,
# which swaps to the next key when the active one is revoked, drained or rate
# limited (saia-keyring.sh).
#
# Usage:
#   SAIA_API_KEY="your-key" ./add-saia-pi.sh
#   ./add-saia-pi.sh --key "your-key"
#   ./add-saia-pi.sh --key-file ~/.local/share/opencode/auth.json
#   SAIA_API_KEYS_EXTRA="key2,key3" ./add-saia-pi.sh --key "your-key" --keyring

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"
# shellcheck source=saia-keyring.sh
source "${SCRIPT_DIR}/saia-keyring.sh"

# ── Parse arguments ──────────────────────────────────────────────────
ASSUME_YES=0
KEY=""
KEY_FILE=""
SAIA_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      KEY="$2"
      shift 2
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    --extra-keys|--extra-keys-file|--keyring|--no-keyring)
      keyring_arg "$@"
      shift "$KEYRING_SHIFT"
      ;;
    -h|--help)
      echo "Usage: SAIA_API_KEY=... ./add-saia-pi.sh [--key <key> | --key-file <path>]"
      echo ""
      echo "Options:"
      echo "  --key <value>       SAIA API key (overrides SAIA_API_KEY env)"
      echo "  --key-file <path>   File containing the SAIA API key"
      echo "  -y, --yes           Install the agent without asking (for non-TTY runs)"
      keyring_usage
      echo "  -h, --help          Show this help"
      echo ""
      echo "The API key is taken from:"
      echo "  1. --key <value> argument (if provided)"
      echo "  2. SAIA_API_KEY environment variable (if set)"
      echo "  3. --key-file <path> (reads first line)"
      echo "  4. the key stored by a previous install, if any"
      echo "  5. an interactive prompt, if none of the above is set"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Pull the key out of a previous install so a reinstall does not ask again.
# The key is persisted as `export SAIA_API_KEY=...` in the shell rc.
key_from_config() {
  local rc
  rc="$(detect_shell_rc)"
  [[ -n "$rc" && -f "$rc" ]] || return 0
  awk -F= '/^[[:space:]]*export[[:space:]]+SAIA_API_KEY=/{sub(/^[^=]*=/,""); gsub(/[\x27"]/,""); print; exit}' "$rc"
  return 0
}

detect_shell_rc() {
  if [[ -n "${SAIA_SHELL_RC:-}" ]]; then
    echo "$SAIA_SHELL_RC"
  elif [[ -n "${ZSH_VERSION:-}" && -f "$HOME/.zshrc" ]]; then
    echo "$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    echo "$HOME/.bashrc"
  elif [[ -f "$HOME/.profile" ]]; then
    echo "$HOME/.profile"
  else
    echo ""
  fi
}

prompt_for_key() {
  if ! { : </dev/tty; } 2>/dev/null; then   # -r only stats; this actually opens it
    echo "ERROR: No SAIA API key given and no terminal to ask on." >&2
    echo "Set it: SAIA_API_KEY=\"your-key\" ./add-saia-pi.sh" >&2
    echo "Get one at https://chat-ai.academiccloud.de/" >&2
    exit 1
  fi
  local key=""
  for _ in 1 2 3; do
    read -rsp "GWDG SAIA API key (input hidden): " key </dev/tty
    echo >&2
    key="${key//[[:space:]]/}"   # paste hygiene; SAIA keys carry no whitespace
    if [[ -n "$key" ]]; then
      export SAIA_API_KEY="$key"
      return
    fi
    echo "Key cannot be empty." >&2
  done
  echo "ERROR: no key entered." >&2
  exit 1
}

# ── Obtain API key ───────────────────────────────────────────────────
if [[ -n "$KEY" ]]; then
  SAIA_KEY="$KEY"
elif [[ -n "${SAIA_API_KEY:-}" ]]; then
  SAIA_KEY="$SAIA_API_KEY"
elif [[ -n "$KEY_FILE" ]]; then
  if [[ ! -f "$KEY_FILE" ]]; then
    echo "ERROR: Key file not found: $KEY_FILE" >&2
    exit 1
  fi
  # Try to read as JSON (opencode auth.json format)
  if command -v python3 &>/dev/null; then
    SAIA_KEY=$(python3 -c "import json; d=json.load(open('$KEY_FILE')); print(d.get('saia-gwdg',{}).get('key',''))" 2>/dev/null || echo "")
  fi
  # Fallback: read first line
  if [[ -z "$SAIA_KEY" ]]; then
    SAIA_KEY=$(head -n 1 "$KEY_FILE" 2>/dev/null || echo "")
  fi
else
  SAIA_KEY="$(key_from_config)"
  if [[ -n "$SAIA_KEY" ]]; then
    echo "Reusing the SAIA key already in your shell rc (pass --key to replace it)."
  else
    prompt_for_key
    SAIA_KEY="$SAIA_API_KEY"
  fi
fi

if [[ -z "$SAIA_KEY" ]]; then
  echo "ERROR: SAIA_API_KEY is empty." >&2
  exit 1
fi

# ── Load models ──────────────────────────────────────────────────────
if [[ ! -f "$MODELS_FILE" ]]; then
  echo "ERROR: Models file not found: $MODELS_FILE" >&2
  exit 1
fi

MODELS=()
while IFS= read -r model || [[ -n "$model" ]]; do
  [[ -z "$model" || "$model" =~ ^# ]] && continue
  MODELS+=("$model")
done < "$MODELS_FILE"

if [[ ${#MODELS[@]} -eq 0 ]]; then
  echo "ERROR: No models found in $MODELS_FILE" >&2
  exit 1
fi

# ── Check/install Pi ─────────────────────────────────────────────────
PI_BIN="$HOME/.pi/agent/bin/pi"
if ! command -v pi &>/dev/null; then
  if [[ -x "$PI_BIN" ]]; then
    export PATH="$HOME/.pi/agent/bin:$PATH"
  elif [[ $ASSUME_YES -eq 1 ]]; then
    :  # --yes: install without asking
  elif [[ -t 0 ]]; then
    read -r -p "pi not found — install it via the official installer? [y/N] " reply
    if [[ $reply != [yY]* ]]; then
      echo "Aborted." >&2
      exit 1
    fi
  else
    echo "ERROR: pi not found and not in TTY mode — use --yes to auto-install" >&2
    exit 1
  fi

  if ! command -v pi &>/dev/null; then
    if ! command -v curl &>/dev/null; then
      echo "ERROR: curl is required to install pi" >&2
      exit 1
    fi

    echo "Downloading and installing pi..."
    if ! curl -fsSL https://pi.dev/install.sh | sh; then
      echo "ERROR: pi installation failed" >&2
      exit 1
    fi

    export PATH="$HOME/.pi/agent/bin:$PATH"

    if ! command -v pi &>/dev/null; then
      echo "ERROR: pi installation completed but not found in PATH" >&2
      exit 1
    fi

    echo "pi installed successfully"
  fi
fi

# ── Persist the key to the shell rc ──────────────────────────────────
# Pi resolves "$SAIA_API_KEY" from the process environment, so the key must be
# present when `pi` runs. Persist it (idempotently) to the detected shell rc.
RC="$(detect_shell_rc)"
if [[ -n "$RC" ]]; then
  touch "$RC"
  if grep -qE '^[[:space:]]*export[[:space:]]+SAIA_API_KEY=' "$RC"; then
    sed -i.bak "s|^[[:space:]]*export[[:space:]]\+SAIA_API_KEY=.*|export SAIA_API_KEY='$SAIA_KEY'|" "$RC"
    rm -f "$RC.bak"
  else
    printf '\n# GWDG SAIA API key (added by pi-saia-gwdg)\nexport SAIA_API_KEY=%s\n' "'$SAIA_KEY'" >> "$RC"
  fi
  echo "Persisted SAIA_API_KEY to $RC"
else
  echo "WARNING: no shell rc detected — export SAIA_API_KEY yourself before running pi." >&2
fi

# ── Automatic key swap (--keyring) ───────────────────────────────────
# Sets SAIA_EFFECTIVE_BASE_URL: the local proxy when it is up, else SAIA itself.
keyring_setup "$SAIA_KEY"

# ── Write ~/.pi/agent/models.json ────────────────────────────────────
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MODELS_JSON="$AGENT_DIR/models.json"
DEFAULT_MODEL="${SAIA_DEFAULT_MODEL:-deepseek-v4-flash-0731}"

mkdir -p "$AGENT_DIR"
if [[ -f "$MODELS_JSON" ]]; then
  BACKUP_DIR="$MODELS_JSON.bak-$(date +%Y%m%d%H%M%S)"
  cp "$MODELS_JSON" "$BACKUP_DIR"
  echo "Backed up existing $MODELS_JSON to $BACKUP_DIR"
fi

# Build the models array as JSON.
MODELS_JSON_ARRAY=""
for m in "${MODELS[@]}"; do
  MODELS_JSON_ARRAY="$MODELS_JSON_ARRAY    { \"id\": \"$m\" },\n"
done
MODELS_JSON_ARRAY="${MODELS_JSON_ARRAY%,*\n}"

{
  echo "{"
  echo "  \"providers\": {"
  echo "    \"gwdg-saia\": {"
  echo "      \"baseUrl\": \"$SAIA_EFFECTIVE_BASE_URL\","
  echo "      \"api\": \"openai-completions\","
  echo "      \"apiKey\": \"\$SAIA_API_KEY\","
  echo "      \"models\": ["
  printf "$MODELS_JSON_ARRAY"
  echo "      ]"
  echo "    }"
  echo "  }"
  echo "}"
} > "$MODELS_JSON"
chmod 600 "$MODELS_JSON"

# ── Write ~/.pi/agent/settings.json (default model) ─────────────────
SETTINGS_JSON="$AGENT_DIR/settings.json"
if [[ -f "$SETTINGS_JSON" ]]; then
  BACKUP_DIR="$SETTINGS_JSON.bak-$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS_JSON" "$BACKUP_DIR"
  echo "Backed up existing $SETTINGS_JSON to $BACKUP_DIR"
fi

{
  echo "{"
  echo "  \"defaultProvider\": \"gwdg-saia\","
  # Bare model id: pi resolves getModel(defaultProvider, defaultModel), a
  # "provider/id" value never matches and pi falls back to the first model.
  echo "  \"defaultModel\": \"$DEFAULT_MODEL\""
  echo "}"
} > "$SETTINGS_JSON"
chmod 600 "$SETTINGS_JSON"

echo ""
echo "✓ GWDG SAIA provider configured for pi!"
echo "  Agent dir: $AGENT_DIR"
echo "  Base URL: $SAIA_EFFECTIVE_BASE_URL"
echo "  Default model: gwdg-saia/$DEFAULT_MODEL"
echo "  Models: ${#MODELS[@]} ready SAIA models"
echo ""
echo "Usage: pi                              # SAIA is the default model"
echo "       pi --model gwdg-saia/<model>    # pick another SAIA model"
echo "       pi --list-models gwdg-saia      # list the SAIA models"
__PSG_EOF__

cat >"$EXTRACT_DIR/src/models.txt" <<'__PSG_EOF__'
apertus-70b-instruct-2509
devstral-2-123b-instruct-2512
qwen3.8-27b
deepseek-v4-flash-0731
glm-5.3-flash
qwen3-coder-next
qwen3-omni-30b-a3b-instruct
mistral-medium-3.5-128b
qwen3.5-397b-a17b
gemma-4-31b-it
qwen3.6-35b-a3b
meta-llama-3.1-8b-instruct
openai-gpt-oss-120b
qwen3-30b-a3b-instruct-2507
__PSG_EOF__

cat >"$EXTRACT_DIR/src/saia-keyring.sh" <<'__PSG_EOF__'
# shellcheck shell=bash
# saia-keyring.sh — automatic SAIA key swap for a harness installer (sourced).
#
# Vendored byte-identical from opencode-extras/keyring/ into the src/ of every
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
__PSG_EOF__

cat >"$EXTRACT_DIR/src/saia_keyring.py" <<'__PSG_EOF__'
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
__PSG_EOF__

chmod +x "$EXTRACT_DIR/src/add-saia-pi.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
if [[ $ASSUME_YES -eq 1 ]]; then CHILD_ARGS+=(--yes); fi
CHILD_ARGS+=(${KEYRING_ARGS[@]+"${KEYRING_ARGS[@]}"})
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-pi.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}
