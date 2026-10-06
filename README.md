# pi-saia-gwdg

GWDG SAIA provider for **Pi**

This repo provides an installer that configures [Pi](https://pi.dev/) to use the [GWDG SAIA](https://chat-ai.academiccloud.de/) OpenAI-compatible API, giving you access to 14 ready models including Qwen, DeepSeek, GLM, and more.

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-pi-saia-gwdg.sh --yes
```

No key in the environment? Run `bash install-pi-saia-gwdg.sh --yes` and it asks for one
(or pass `--key <value>` / `--key-file <path>`). Reinstalls reuse the key already in
your shell rc, so you only ever type it once.

This one-shot installer:
- Installs Pi (if missing) via the official installer (`curl -fsSL https://pi.dev/install.sh | sh`)
- Writes `~/.pi/agent/models.json` registering the GWDG SAIA endpoint with 14 ready models
- Writes `~/.pi/agent/settings.json` making SAIA the default model, so Pi runs with **no OpenAI account**
- Persists the key as `SAIA_API_KEY` in your shell rc (Pi resolves it via env interpolation)
- Optional, with `--keyring`: routes Pi through a local
  key-rotating proxy that swaps keys automatically when one is revoked, drained or
  rate limited (see `SETUP.md` → *Multiple keys*)
- Works on macOS, Linux, and WSL

Or see `SETUP.md` for detailed instructions and troubleshooting.

## What's included

| File | Purpose |
|------|---------|
| `install-pi-saia-gwdg.sh` | Self-contained installer (generated; never edit directly) |
| `build.sh` | Regenerates the installer from source files |
| `src/add-saia-pi.sh` | Live source script (portable key sourcing) |
| `src/models.txt` | List of 14 ready SAIA models |
| `src/saia_keyring.py`, `src/saia-keyring.sh` | Key-rotating proxy and its install logic, vendored from `opencode-extras/keyring/` (never edit here) |
| `test/fake-saia.py` | Fake SAIA endpoint for the smoke test (not packed) |
| `test/test-install.sh` | Smoke test that verifies the config is written (not packed) |

## Architecture

```
SAIA_API_KEY → install-pi-saia-gwdg.sh → [pi install] → src/add-saia-pi.sh ─┬─ ~/.pi/agent/models.json
                                                                             └─ ~/.pi/agent/settings.json
                                                                                          │
                                                                                          ▼
                                                              https://chat-ai.academiccloud.de/v1
```

## Maintaining

After changing `src/add-saia-pi.sh` or `src/models.txt`, regenerate the installer
(the keyring files are synced in by `opencode-extras/keyring/sync.sh`, which also rebuilds):

```bash
./build.sh
```

## License

MIT
