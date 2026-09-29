#!/usr/bin/env bash
#
# build.sh — pack the live SAIA config into install-pi-saia-gwdg.sh
#
# Reads the current src/add-saia-pi.sh and src/models.txt and
# emits a single self-contained installer that can be copied to other devices.
# Rerun this after ANY change to those files, and commit both.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="install-pi-saia-gwdg.sh"
MANIFEST=(
  src/add-saia-pi.sh
  src/models.txt
)

# ── Sanity checks ────────────────────────────────────────────────────
for f in "${MANIFEST[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
  if grep -qF "__PSG_EOF__" "$f"; then
    echo "ERROR: delimiter '__PSG_EOF__' occurs in $f — pick a different delimiter" >&2
    exit 1
  fi
  if [[ -n "$(tail -c 1 "$f")" ]]; then
    echo "ERROR: $f lacks a trailing newline (heredoc packing would add one)" >&2
    exit 1
  fi
done

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
git diff --quiet HEAD -- "${MANIFEST[@]}" 2>/dev/null || DIRTY="-dirty"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_OUT="$(mktemp "$OUT.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

# ── Header (interpolates the stamp) ──────────────────────────────────
cat >"$TMP_OUT" <<PSG_GEN_HEADER
#!/usr/bin/env bash
#
# install-pi-saia-gwdg.sh — GENERATED FILE, DO NOT EDIT.
# Regenerate with: ./build.sh  (in the pi-saia-gwdg repo)
# Source: pi-saia-gwdg commit $COMMIT$DIRTY, packed $STAMP
#
# Installs the GWDG SAIA setup for pi: provider + models + default model.

PSG_GEN_HEADER

# ── Static installer body ────────────────────────────────────────────
cat >>"$TMP_OUT" <<'PSG_GEN_BODY'
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
PSG_GEN_BODY

# ── Append the packed source files ───────────────────────────────────
echo "" >>"$TMP_OUT"
echo "# ── Packed source files ────────────────────────────────────────────" >>"$TMP_OUT"

for f in "${MANIFEST[@]}"; do
  echo "cat >\"\$EXTRACT_DIR/$f\" <<'__PSG_EOF__'" >>"$TMP_OUT"
  cat "$f" >>"$TMP_OUT"
  echo "__PSG_EOF__" >>"$TMP_OUT"
  echo "" >>"$TMP_OUT"
done

# ── Static installer tail: run what we just unpacked ──────────────────
cat >>"$TMP_OUT" <<'PSG_GEN_TAIL'
chmod +x "$EXTRACT_DIR/src/add-saia-pi.sh"
CHILD_ARGS=()
if [[ -n "$KEY" ]]; then CHILD_ARGS+=(--key "$KEY"); fi
if [[ -n "$KEY_FILE" ]]; then CHILD_ARGS+=(--key-file "$KEY_FILE"); fi
# ${a[@]+"${a[@]}"}: bash 3.2 (stock macOS) calls an empty array unbound under set -u
"$EXTRACT_DIR/src/add-saia-pi.sh" ${CHILD_ARGS[@]+"${CHILD_ARGS[@]}"}
PSG_GEN_TAIL

# ── Finalize ─────────────────────────────────────────────────────────
mv "$TMP_OUT" "$OUT"
chmod +x "$OUT"

echo "Generated: $OUT"
echo "Commit: $COMMIT$DIRTY"
echo "Timestamp: $STAMP"
