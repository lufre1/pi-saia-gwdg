#!/usr/bin/env bash
#
# test-install.sh — smoke-test the pi-saia-gwdg installer.
#
# Runs src/add-saia-pi.sh against a throwaway HOME / PI_CODING_AGENT_DIR /
# SAIA_SHELL_RC so it never touches ~/.pi/agent or the real shell rc, and never
# installs pi (pi is assumed present). Verifies the generated models.json and
# settings.json, that the key is persisted to the fake shell rc, and that the
# fake SAIA endpoint answers. Then checks the automatic key swap: with two keys,
# the first one revoked, pi is pointed at the local saia-keyring proxy and a
# request through it fails over to the second key. The proxy is started with
# SAIA_KEYRING_SERVICE=none, so no systemd unit or real shell rc is touched.
#
#   bash test/test-install.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORK="$(mktemp -d)"
export HOME="$WORK/home"
export PI_CODING_AGENT_DIR="$WORK/agent"
export SAIA_SHELL_RC="$WORK/rc"
export SAIA_KEYRING_SERVICE=none
mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"
touch "$SAIA_SHELL_RC"

cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null || true
  if [[ -n "${KR_PORT:-}" ]]; then
    curl -s "http://127.0.0.1:$KR_PORT/_keyring/health" \
      | python3 -c 'import json,os,sys; os.kill(json.load(sys.stdin)["pid"], 15)' 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Start the fake SAIA ──────────────────────────────────────────────
FAKE_DEAD_KEYS=dead-key SEEN_FILE="$WORK/seen" python3 ./fake-saia.py >"$WORK/port" 2>"$WORK/fake.log" &
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

# ── SAIA_BASE_URL override (used by the benchmark's local gateway) ─────
OV="$WORK/override"; mkdir -p "$OV/home"
HOME="$OV/home" PI_CODING_AGENT_DIR="$OV/agent" SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" \
  SAIA_API_KEY=dummy bash ../src/add-saia-pi.sh >"$WORK/override.log" 2>&1 \
  || fail "installer failed with SAIA_BASE_URL set"
grep -q "\"baseUrl\": \"http://127.0.0.1:$PORT/v1\"" "$OV/agent/models.json" \
  || fail "SAIA_BASE_URL not written to models.json"
echo "PASS: SAIA_BASE_URL override"

# ── Automatic key swap: two keys, the first one revoked ───────────────
KR="$WORK/keyring"; mkdir -p "$KR/home"
KR_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
HOME="$KR/home" PI_CODING_AGENT_DIR="$KR/agent" SAIA_SHELL_RC="$KR/rc" SAIA_KEYRING_PORT="$KR_PORT" \
  SAIA_BASE_URL="http://127.0.0.1:$PORT/v1" SAIA_API_KEY=dead-key \
  bash ../src/add-saia-pi.sh --keyring --extra-keys good-key >"$WORK/keyring.log" 2>&1 \
  || { cat "$WORK/keyring.log" >&2; fail "installer failed with --keyring"; }
grep -q "\"baseUrl\": \"http://127.0.0.1:$KR_PORT/v1\"" "$KR/agent/models.json" \
  || { cat "$WORK/keyring.log" >&2; fail "models.json not pointed at the keyring proxy"; }
KR_CFG="$KR/home/.config/saia-keyring/keyring.json"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$KR_CFG")" == 0o600 ]] \
  || fail "keyring.json is not chmod 600"
: >"$WORK/seen"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer dead-key" \
  "http://127.0.0.1:$KR_PORT/v1/models")"
[[ "$CODE" == 200 ]] || fail "request through the keyring proxy returned $CODE"
[[ "$(paste -sd, "$WORK/seen")" == "dead-key,good-key" ]] \
  || fail "proxy did not fail over from the revoked key (saw: $(paste -sd, "$WORK/seen"))"
echo "PASS: automatic key swap (revoked key -> next key through the local proxy)"
