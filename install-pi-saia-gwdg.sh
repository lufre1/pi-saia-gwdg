#!/usr/bin/env bash
#
# install-pi-saia-gwdg.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the pi-saia-gwdg repo)
# Source: pi-saia-gwdg commit a5586e1-dirty, packed 2026-10-05T10:01:23Z
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
  -h, --help          show this help

The API key is taken from --key, --key-file or the SAIA_API_KEY environment
variable; if none of them is set, you are prompted for it. The key is persisted
to your shell rc (as SAIA_API_KEY) so pi can resolve it at runtime.
Existing ~/.pi/agent/models.json and settings.json are backed up to .bak-<timestamp>/ first.
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --key|--key-file)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
      if [[ $1 == --key ]]; then KEY="$2"; else KEY_FILE="$2"; fi
      shift 2
      ;;
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
# Usage:
#   SAIA_API_KEY="your-key" ./add-saia-pi.sh
#   ./add-saia-pi.sh --key "your-key"
#   ./add-saia-pi.sh --key-file ~/.local/share/opencode/auth.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"

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
    -h|--help)
      echo "Usage: SAIA_API_KEY=... ./add-saia-pi.sh [--key <key> | --key-file <path>]"
      echo ""
      echo "Options:"
      echo "  --key <value>       SAIA API key (overrides SAIA_API_KEY env)"
      echo "  --key-file <path>   File containing the SAIA API key"
      echo "  -y, --yes           Install the agent without asking (for non-TTY runs)"
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
  echo "      \"baseUrl\": \"$SAIA_BASE_URL\","
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
echo "  Base URL: $SAIA_BASE_URL"
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

chmod +x "$EXTRACT_DIR/src/add-saia-pi.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
if [[ $ASSUME_YES -eq 1 ]]; then CHILD_ARGS+=(--yes); fi
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-pi.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}
