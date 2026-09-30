# GWDG SAIA Provider Setup for Pi

## Summary

This installer configures Pi to use the GWDG SAIA provider with all 14 ready models.

## Prerequisites

- **SAIA API key** (from GWDG SAIA) — the installer reuses the key from a previous
  install, and prompts for it only when there is none
- **Pi** will be installed automatically if missing (via the official installer)

## Quick start

```bash
SAIA_API_KEY="your-key" bash install-pi-saia-gwdg.sh --yes
```

This one-shot installer:
- Installs Pi (if missing) via the official installer
- Writes `~/.pi/agent/models.json` registering the GWDG SAIA endpoint with 14 ready models
- Writes `~/.pi/agent/settings.json` making SAIA the default model
- Persists the key as `SAIA_API_KEY` in your shell rc
- Works on macOS, Linux, and WSL

## Detailed installation

### 1. Obtain your SAIA API key

Your key is stored in `~/.local/share/opencode/auth.json` (if you use opencode with SAIA), or you can generate a new one at the GWDG SAIA portal.

### 2. Run the installer

```bash
# Option A: via environment variable (recommended)
SAIA_API_KEY="your-key" bash install-pi-saia-gwdg.sh --yes

# Option B: via --key argument
bash install-pi-saia-gwdg.sh --key "your-key" --yes

# Option C: via --key-file (reads from a file)
bash install-pi-saia-gwdg.sh --key-file ~/.local/share/opencode/auth.json --yes

# Option D: pass nothing — reuses the key from a previous install,
# or asks for it (input hidden) if this is the first one
bash install-pi-saia-gwdg.sh --yes
```

The `--yes` flag enables non-interactive mode and auto-installs Pi if missing. Without it, the installer will prompt before installing Pi.

The installer will:
- Verify Pi is installed (installing it via `curl -fsSL https://pi.dev/install.sh | sh` if missing)
- Back up your existing `~/.pi/agent/models.json` and `settings.json` to `.bak-<timestamp>/`
- Write `~/.pi/agent/models.json` with the GWDG SAIA base URL and 14 models
- Write `~/.pi/agent/settings.json` making SAIA the default model
- Persist the key as `SAIA_API_KEY` in your shell rc (idempotent)

### 3. Verify installation

```bash
pi --list-models gwdg-saia
```

You should see all 14 SAIA models listed under the `gwdg-saia` provider.

### 4. Test the provider

```bash
pi --print "Reply with exactly: OK"
```

Expected output: `OK`.

## Usage

### Start a session with a SAIA model

```bash
# Use the default SAIA model
pi

# Or start with a specific model
pi --model gwdg-saia/qwen3-coder-next
```

### Available models

All 14 ready SAIA models:

- apertus-70b-instruct-2509
- devstral-2-123b-instruct-2512
- qwen3.8-27b
- deepseek-v4-flash-0731
- glm-5.3-flash
- qwen3-coder-next
- qwen3-omni-30b-a3b-instruct
- mistral-medium-3.5-128b
- qwen3.5-397b-a17b
- gemma-4-31b-it
- qwen3.6-35b-a3b
- meta-llama-3.1-8b-instruct
- openai-gpt-oss-120b
- qwen3-30b-a3b-instruct-2507

## Config schema

The provider is stored in `~/.pi/agent/models.json`:

```json
{
  "providers": {
    "gwdg-saia": {
      "baseUrl": "https://chat-ai.academiccloud.de/v1",
      "api": "openai-completions",
      "apiKey": "$SAIA_API_KEY",
      "models": [
        { "id": "deepseek-v4-flash-0731" }
      ]
    }
  }
}
```

The default model is set in `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "gwdg-saia",
  "defaultModel": "deepseek-v4-flash-0731"
}
```

**Note**: the raw API key is **not** stored in `models.json`. It is referenced as
`$SAIA_API_KEY` (Pi env interpolation) and persisted to your shell rc
(`~/.bashrc`, `~/.zshrc`, or `~/.profile`) as `export SAIA_API_KEY='...'`.

## Troubleshooting

### Models not appearing in `/model`

Pi only shows models whose provider credentials resolve. Ensure `SAIA_API_KEY` is
set in the shell that starts `pi` (the installer persists it to your shell rc, so
open a new terminal or `source ~/.bashrc`). Verify with:

```bash
pi --list-models gwdg-saia
```

### qwen3-omni-30b-a3b-instruct returns a 400 error

This omni (multimodal) model does not accept Pi's default tool-calling format.
Use it with tools disabled:

```bash
pi --model gwdg-saia/qwen3-omni-30b-a3b-instruct --no-tools
```

### API key errors

- Ensure `SAIA_API_KEY` is set correctly (no quotes in the env var value); with no
  key set at all, the installer asks for one, and fails only if there is no terminal
  to ask on (CI, cron) — set the env var there
- Verify the key is valid at the GWDG SAIA portal
- Check rate limits: 30 req/min, 200/hour, 1000/day, 3000/month per key

### pi not found

The installer automatically installs Pi via the official installer if missing:

```bash
curl -fsSL https://pi.dev/install.sh | sh
```

This installs to `~/.pi/agent/bin/pi` with a symlink at `~/bin/pi`. If it is not on
your PATH, add `~/bin` to it.

## Advanced: Regenerate the installer

If you modify `src/add-saia-pi.sh` or `src/models.txt`, regenerate the installer:

```bash
./build.sh
```

This creates a new `install-pi-saia-gwdg.sh` with the changes embedded.

## License

MIT
