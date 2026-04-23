# TOOLS

This workspace is managed by `easy_llamacpp`. Keep this bootstrap file short so
OpenClaw can inject it without truncation.

## Start And Stop

- Start the launcher: `Start.cmd`
- Start OpenClaw only: `start_openclaw.cmd`
- Stop everything managed by this workspace: `stop_all.cmd`
- Stop llama.cpp only: `stop_llamacpp.cmd`
- Stop OpenClaw only: `stop_opencalw.cmd`
- Start vision sidecar only: `start_vision.cmd`
- Stop vision sidecar only: `stop_vision.cmd`
- Refresh OpenClaw status/config after a model switch:
  `update_openclaw_sataus.cmd -RestartOpenClaw`

## llama.cpp

- The managed server binary lives at `F:\Documents\GitHub\easy_llamacpp\bin\llama-server.exe`.
- The launcher tracks the active server through
  `F:\Documents\GitHub\easy_llamacpp\logs\llama-server.pid`.
- Check server status from the project root:
  `powershell -ExecutionPolicy Bypass -File .\PS1\Start_LCPP.ps1 -Status -NoPause`
- API health checks:
  `Invoke-RestMethod http://127.0.0.1:8080/health`
  `Invoke-RestMethod http://127.0.0.1:8080/v1/models`

## OpenClaw

- OpenClaw root: `C:\Users\JackYang\.openclaw`
- Main workspace: `C:\Users\JackYang\.openclaw\workspace`
- Worker workspaces:
  `C:\Users\JackYang\.openclaw\workspace-worker1`
  `C:\Users\JackYang\.openclaw\workspace-worker2`
- Gateway URL: `http://127.0.0.1:29644/`
- Gateway health: `openclaw gateway probe`; trust `Connect: ok` and `RPC: ok`.
- `openclaw status` or the HTTP root page may time out even when gateway RPC is healthy.
- OpenClaw config: `C:\Users\JackYang\.openclaw\openclaw.json`
- Managed gateway script:
  `C:\Users\JackYang\.openclaw\scripts\run-openclaw-gateway-with-media.ps1`
- Safe startup disables `agentmemory`, `browser`, `openclaw-web-search`,
  `voice-call`, and internal hooks; re-enable them one at a time. Telegram stays
  enabled when token/config exists and uses IPv4-preferred transport settings.
- Reinstall notes:
  `F:\Documents\GitHub\easy_llamacpp\docs\OpenClaw-reinstall-notes.md`

## Voice Sidecars

The managed gateway starts TTS and STT sidecars before OpenClaw.

- TTS health: `Invoke-RestMethod http://127.0.0.1:8000/health`
- STT health: `Invoke-RestMethod http://127.0.0.1:8001/health`
- TTS default endpoint: `http://127.0.0.1:8000/`
- STT transcribe endpoint: `http://127.0.0.1:8001/transcribe`
- TTS env: `C:\Users\JackYang\Miniconda3\envs\qwen3-tts-fa2-test`
- STT env: `C:\Users\JackYang\Miniconda3\envs\qwen3-asr`

## Vision Sidecar

- Normal model startup auto-detects a matching `mmproj*.gguf` and launches the
  primary `llama-server` with `--mmproj`; check `Start_LCPP.ps1 -Status`.
- Start a separate sidecar only when needed: `start_vision.cmd`
- Stop: `stop_vision.cmd`
- Default URL: `http://127.0.0.1:8081/v1/chat/completions`
- PID/logs:
  `F:\Documents\GitHub\easy_llamacpp\logs\vision-server.pid`
  `F:\Documents\GitHub\easy_llamacpp\logs\vision-server.stdout.log`
  `F:\Documents\GitHub\easy_llamacpp\logs\vision-server.stderr.log`
- Override with `LCPP_VISION_MODEL_PATH`, `LCPP_VISION_MMPROJ_PATH`, or
  `LCPP_VISION_PORT`.

## Telegram

Telegram is configured in OpenClaw with an allowlist and IPv4-preferred network
settings. The managed `gateway.cmd` also exports:

- `OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY=1`
- `OPENCLAW_TELEGRAM_DNS_RESULT_ORDER=ipv4first`
- `OPENCLAW_TELEGRAM_FORCE_IPV4=1`

If Telegram stops responding, restart OpenClaw after checking the gateway log:

```powershell
Get-Content C:\Users\JackYang\.openclaw\logs\gateway.stderr.log -Tail 80
.\update_openclaw_sataus.cmd -RestartOpenClaw
```

## Notes

- Keep large reference material out of this file. Put detailed docs in
  `README.md` or project-specific markdown files and link to them.
- Do not paste long session summaries or historical logs here; they inflate the
  OpenClaw bootstrap context.
