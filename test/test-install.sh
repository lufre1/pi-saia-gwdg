#!/usr/bin/env bash
#
# test-install.sh — smoke-test the pi-saia-gwdg installer.
#
# Runs src/add-saia-pi.sh against a throwaway HOME / PI_CODING_AGENT_DIR /
# SAIA_SHELL_RC so it never touches ~/.pi/agent or the real shell rc, and never
# installs pi (pi is assumed present). Verifies the generated models.json and
# settings.json, that the key is persisted to the fake shell rc, and that the
# fake SAIA endpoint answers.
#
#   bash test/test-install.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORK="$(mktemp -d)"
export HOME="$WORK/home"
export PI_CODING_AGENT_DIR="$WORK/agent"
export SAIA_SHELL_RC="$WORK/rc"
mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"
touch "$SAIA_SHELL_RC"

cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Start the fake SAIA ──────────────────────────────────────────────
python3 ./fake-saia.py >"$WORK/port" 2>"$WORK/fake.log" &
FAKE_PID=$!
for _ in $(seq 40); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
[[ -n "$PORT" ]] || { echo "FAIL: fake-saia did not start" >&2; cat "$WORK/fake.log" >&2; exit 1; }
echo "fake-saia on port $PORT"

# ── Run the installer source against the fake ────────────────────────
SAIA_API_KEY=dummy bash ../src/add-saia-pi.sh >"$WORK/install.log" 2>&1 || {
  echo "FAIL: add-saia-pi.sh exited non-zero" >&2
  cat "$WORK/install.log" >&2
  exit 1
}

fail() { echo "FAIL: $1" >&2; echo "--- install.log ---" >&2; cat "$WORK/install.log" >&2; exit 1; }

MODELS_JSON="$PI_CODING_AGENT_DIR/models.json"
SETTINGS_JSON="$PI_CODING_AGENT_DIR/settings.json"

[[ -f "$MODELS_JSON" ]] || fail "models.json not written"
grep -q '"baseUrl": "https://chat-ai.academiccloud.de/v1"' "$MODELS_JSON" \
  || fail "base URL missing"
grep -q '"api": "openai-completions"' "$MODELS_JSON" \
  || fail "api type missing"
grep -q '"apiKey": "\$SAIA_API_KEY"' "$MODELS_JSON" \
  || fail "env-interpolated apiKey missing"
grep -q '"id": "deepseek-v4-flash-0731"' "$MODELS_JSON" \
  || fail "default model not in models list"
grep -q '"id": "qwen3-coder-next"' "$MODELS_JSON" \
  || fail "model list not written"

[[ -f "$SETTINGS_JSON" ]] || fail "settings.json not written"
grep -q '"defaultProvider": "gwdg-saia"' "$SETTINGS_JSON" \
  || fail "defaultProvider missing"
grep -q '"defaultModel": "deepseek-v4-flash-0731"' "$SETTINGS_JSON" \
  || fail "defaultModel missing"

grep -q "export SAIA_API_KEY='dummy'" "$SAIA_SHELL_RC" \
  || fail "key not persisted to shell rc"

# ── Verify the fake endpoint answers (models list) ───────────────────
MODELS_JSON_OUT="$(curl -s -H "Authorization: Bearer dummy" "http://127.0.0.1:$PORT/v1/models")"
echo "$MODELS_JSON_OUT" | grep -q "fake-model" || fail "fake endpoint did not list models"

echo "PASS: models.json + settings.json written, key persisted, fake endpoint answered"
