# OpenClaw 重裝修補筆記

這份文件記錄本機 OpenClaw 修補點。OpenClaw 透過 npm 重新安裝或更新後，
安裝目錄裡的 bundle 可能會被覆蓋；照這裡可以把修補補回來。

日常啟動流程、watchdog 運作、狀態檢查與本機踩坑紀錄請看
[`OpenClaw-startup-watchdog-runbook.md`](OpenClaw-startup-watchdog-runbook.md)。

## 快速恢復

在 `easy_llamacpp` 專案根目錄執行：

```powershell
.\start_openclaw.cmd
```

如果 llama.cpp 已經在跑，而且要順便同步 OpenClaw 模型狀態：

```powershell
.\update_openclaw_sataus.cmd -RestartOpenClaw
```

這兩個入口會呼叫 `PS1\OpenClawSupport.ps1`，並把 managed startup assets
同步回 `C:\Users\<user>\.openclaw`。

## Repo 會自動恢復的項目

同步流程會恢復這些檔案與設定：

- `C:\Users\<user>\.openclaw\gateway.cmd`
  - 改走 `scripts\run-openclaw-gateway-with-media.ps1`。
  - 先啟動 TTS/STT sidecars，再啟動 OpenClaw gateway。
  - 不再自動先啟動 `agentmemory.cmd`，避免 gateway startup 被 agent memory/background hooks 拖住。
  - gateway stdout/stderr 會寫到 `C:\Users\<user>\.openclaw\logs\gateway.stdout.log`
    與 `gateway.stderr.log`，方便排查卡在啟動中或 sidecar warming up。
  - 加入 Telegram 網路環境變數：

```bat
set "OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY=1"
set "OPENCLAW_TELEGRAM_DNS_RESULT_ORDER=ipv4first"
set "OPENCLAW_TELEGRAM_FORCE_IPV4=1"
```

- `C:\Users\<user>\.openclaw\node.cmd`
  - 保留原本 token/config 行。
  - 插入同一組 Telegram 網路環境變數。

- `C:\Users\<user>\.openclaw\workspace*\TOOLS.md`
  - 用 `PS1\OpenClaw\TOOLS.md` 的精簡模板覆蓋過肥 bootstrap。
  - 這個檔案要維持低於 OpenClaw 的 `12000` 字元注入限制。

- `C:\Users\<user>\.openclaw\openclaw.json`
  - 安全啟動會暫停 `agentmemory`、`browser`、`openclaw-web-search`、`voice-call`
    與 internal hooks。這些項目曾造成 gateway 長時間停在 startup，
    先關掉可讓 `openclaw gateway probe` 正常 RPC；需要時再逐一打開測試。
  - Telegram 若已有 token/config，安全啟動會保持 `channels.telegram.enabled=true`、
    `plugins.allow` 包含 `telegram`、`plugins.entries.telegram.enabled=true`，並使用
    IPv4 優先設定，避免因重裝後同步流程把 Telegram 關掉。
  - 目前主 `llama-server` 如果是用 `--mmproj` 啟動，`llama-cpp-vision` provider
    會指向 `http://127.0.0.1:8080/v1`，並把 `agents.defaults.imageModel.primary`
    與 `tools.media.image.models[0]` 指到目前模型。
  - 如果改用獨立 `start_vision.cmd` sidecar，vision endpoint 才使用
    `http://127.0.0.1:8081/v1`。
  - Telegram config 只保留 OpenClaw schema 接受的 key：

```json
{
  "channels": {
    "telegram": {
      "network": {
        "autoSelectFamily": false,
        "dnsResultOrder": "ipv4first"
      }
    }
  }
}
```

不要把 `forceIpv4` 寫進 `openclaw.json`。目前 OpenClaw config schema 會把它
當成 additional property，然後直接報 `Config invalid`。

## npm bundle 手動 patch

repo launcher 會輸出 `OPENCLAW_TELEGRAM_FORCE_IPV4=1`，但某些 OpenClaw bundle
不會讀這個環境變數。若重裝後又看到下面這種 Telegram fallback loop，就補這段：

```text
[telegram] fetch fallback: enabling sticky IPv4-only dispatcher (codes=UND_ERR_SOCKET)
```

先找出 Telegram transport bundle：

```powershell
$dist = Join-Path $env:APPDATA 'npm\node_modules\openclaw\dist'
Get-ChildItem -Path $dist -File -Filter '*.js' |
  Select-String -Pattern 'function resolveTelegramTransport|OPENCLAW_TELEGRAM_DNS_RESULT_ORDER' |
  Select-Object -ExpandProperty Path -Unique
```

目前這台機器補過的是：

```text
C:\Users\JackYang\AppData\Roaming\npm\node_modules\openclaw\dist\audit-membership-runtime-DkPoSwQR.js
```

OpenClaw bundle 檔名有 hash，更新後檔名可能不同。請 patch 含有
`function resolveTelegramTransport` 的檔案。

補法如下：

1. 在 Telegram env constants 附近加入：

```js
const TELEGRAM_FORCE_IPV4_ENV = "OPENCLAW_TELEGRAM_FORCE_IPV4";
```

2. 在 `resolveTelegramTransport` 裡，`dnsResultOrder` 算出來後加入：

```js
const forceIpv4 = isTruthyEnvValue(process$1.env[TELEGRAM_FORCE_IPV4_ENV]) || options?.network?.forceIpv4 === true;
```

3. 在 default dispatcher policy 裡，把：

```js
forceIpv4: false,
```

改成：

```js
forceIpv4,
```

補完後檢查 JS 語法：

```powershell
node --check "C:\Users\JackYang\AppData\Roaming\npm\node_modules\openclaw\dist\<patched-file>.js"
```

最後重啟 OpenClaw：

```powershell
.\stop_all.cmd
.\start_openclaw.cmd
```

## Qwen3.6 FP8 轉 GGUF 注意

`Qwen/Qwen3.6-27B-FP8` 這類 repo 的 safetensors shard 不是
`model-*.safetensors`，而是 `layers-*.safetensors`、`outside.safetensors`
與 `mtp.safetensors`，但仍使用 `model.safetensors.index.json` 作為 weight map。
如果重裝或更新 llama.cpp 後 converter 又乾跑出 `n_tensors = 0`，需要檢查
`convert_hf_to_gguf.py` 的 `index_tensors()`：

- 若 `model.safetensors.index.json` 存在，即使沒有 `model*.safetensors`，
  也要把它視為 safetensors repo，讓 converter 讀 weight map 裡列出的 shard。
- `Qwen3_5ForConditionalGeneration` 的文字權重在 `model.language_model.*`；
  轉文字主模型時要略過 `model.visual.*`，並把 `model.language_model.`
  轉成 mapper 認得的 `model.`。

本機目前轉出的檔案：

```text
E:\LLM Model\Qwen3.6-27B-FP8-Q8_0.gguf
E:\LLM Model\mmproj-Qwen3.6-27B-FP8-f16.gguf
```

驗證過的載入方式：

```powershell
.\bin\llama-server.exe --host 127.0.0.1 --port 8099 `
  -m "E:\LLM Model\Qwen3.6-27B-FP8-Q8_0.gguf" `
  --mmproj "E:\LLM Model\mmproj-Qwen3.6-27B-FP8-f16.gguf" `
  --jinja -c 2048 -ngl 0 --no-warmup --no-webui
```

`/v1/models` 應回報 `completion` 與 `multimodal` capabilities。

## 驗證

確認 bootstrap 沒有過肥：

```powershell
Get-ChildItem "$env:USERPROFILE\.openclaw\workspace*\TOOLS.md" |
  ForEach-Object {
    $text = Get-Content -LiteralPath $_.FullName -Raw
    [pscustomobject]@{ Path = $_.FullName; Chars = $text.Length; Bytes = $_.Length }
  }
```

確認服務狀態：

```powershell
.\PS1\Start_LCPP.ps1 -Status -NoPause
```

有對應 `mmproj*.gguf` 的模型應該看到 `Mmproj : ... --mmproj` 與
`Vision : enabled on primary server`。例如目前 27B 使用：

```text
E:\LLM Model\mmproj-Qwen3.6-27B-Uncensored-HauhauCS-Aggressive-f16.gguf
```

確認 OpenClaw gateway RPC：

```powershell
openclaw gateway probe
```

預期看到 `Reachable: yes`，並且 local loopback websocket 顯示 `Connect: ok` 與 `RPC: ok`。
這台機器上 `openclaw status` 與 `Invoke-WebRequest http://127.0.0.1:29644/` 可能 timeout，
即使 gateway RPC 已正常；排查 readiness 時優先相信 `start_openclaw.cmd`、
`openclaw gateway probe` 與 `C:\Users\<user>\.openclaw\logs\gateway.stdout.log`。

檢查目前 log 是否又出現兩個回歸：

```powershell
Get-ChildItem "$env:USERPROFILE\.openclaw\logs" -File |
  Select-String -Pattern 'workspace bootstrap file|truncating|UND_ERR_SOCKET|fetch fallback|Config invalid'
```

乾淨重啟後預期：

- 沒有新的 `workspace bootstrap file ... truncating`
- Telegram 可載入，但不應持續出現新的 `UND_ERR_SOCKET` fallback loop
- 沒有 `Config invalid ... channels.telegram.network`
- `openclaw gateway probe` 回報 `Reachable: yes` / `RPC: ok`

