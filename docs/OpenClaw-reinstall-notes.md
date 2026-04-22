# OpenClaw 重裝修補筆記

這份文件記錄本機 OpenClaw 修補點。OpenClaw 透過 npm 重新安裝或更新後，
安裝目錄裡的 bundle 可能會被覆蓋；照這裡可以把修補補回來。

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

檢查目前 log 是否又出現兩個回歸：

```powershell
Get-ChildItem "$env:USERPROFILE\.openclaw\logs" -File |
  Select-String -Pattern 'workspace bootstrap file|truncating|UND_ERR_SOCKET|fetch fallback|Config invalid'
```

乾淨重啟後預期：

- 沒有新的 `workspace bootstrap file ... truncating`
- 沒有新的 Telegram `UND_ERR_SOCKET` fallback loop
- 沒有 `Config invalid ... channels.telegram.network`

