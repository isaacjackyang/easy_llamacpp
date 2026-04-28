# OpenClaw 啟動與 Watchdog Runbook

最後驗證時間：2026-04-28 08:43，Asia/Taipei。  
本文件記錄這台機器目前的 OpenClaw stack 啟動方式，以及本串從接 vision 到修 watchdog 期間踩過的坑。

## 目標狀態

正常狀態下，下面這些服務都要在背景或隱藏視窗中常駐：

| 服務 | 檢查方式 | 目前約定 |
| --- | --- | --- |
| Primary llama.cpp | `http://127.0.0.1:8080/v1/models` | `llama-server.exe`，`--temp 0.35`，`--parallel 2` |
| Vision sidecar | `http://127.0.0.1:8081/v1/models` | `llama-server.exe`，`--mmproj`，`--temp 0.35`，`--parallel 2` |
| TTS | `http://127.0.0.1:8000/health` | Gateway launcher 管理 |
| STT | `http://127.0.0.1:8001/health` | Gateway launcher 管理 |
| OpenClaw Gateway/WebUI | `http://127.0.0.1:29644/health`、`http://127.0.0.1:29644/` | no-console VBS launcher -> hidden PowerShell |
| OpenClaw Node | `node ... openclaw\dist\index.js node run ...` | no-console VBS launcher -> hidden PowerShell |
| Telegram | `openclaw channels status --channel telegram --json` | OpenClaw 只管理 `default`、`worker2`，至少應 running/connected |
| Codex Telegram worker1 | `show_status.cmd` 的 `Codex Telegram worker1` 行 | `worker1` bot token 已從 OpenClaw 移出；目前 bridge/autostart/automation 已暫停 |
| Watchdog | Windows task `\OpenClaw Watchdog` | 每 1 分鐘檢查一次 |

快速確認：

```bat
show_status.cmd
```

最後一次完整 OK 的輸出摘要：

```text
Primary llama.cpp       : OK - http 8080; model=Qwen3.6-27B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf
Vision                  : OK - http 8081; model=Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf
TTS                     : OK - http 8000/health
STT                     : OK - http 8001/health
OpenClaw Gateway/WebUI  : OK - http 29644; health=200; webui=200
Node                    : OK - node host process detected
Telegram default        : OK - running=True; connected=True
Telegram worker2        : OK - running=True; connected=True
Codex Telegram worker1  : OK - mode=paused; process=False; autostart=False; inboxBytes=315; automation=disabled
Watchdog                : OK - state=Enabled; status=Ready; lastResult=0; repeat=0 Hour(s), 1 Minute(s)
```

## 常用入口

從 `F:\Documents\GitHub\easy_llamacpp` 執行：

```bat
start_openclaw.cmd -NoPause
stop_openclaw.cmd
show_status.cmd
start_watchdog.cmd -NoPause
stop_watchdog.cmd -NoPause
stop_watchdog.cmd -ForceEnd -NoPause
start_codex_telegram_worker1.cmd -NoPause
stop_codex_telegram_worker1.cmd -NoPause
```

入口分工：

- `start_openclaw.cmd`：同步 OpenClaw config 與 managed startup assets，移除 `openclaw.stop`，啟用 watchdog，重啟 Gateway/Node/TTS/STT/Vision，最後檢查 Telegram。
- `stop_openclaw.cmd`：轉呼叫 `%USERPROFILE%\.openclaw\stop.cmd`，建立 `openclaw.stop`，停用 watchdog，停止 Gateway、Node、TTS、STT、Vision sidecar 與相關 OpenClaw 進程。
- `start_watchdog.cmd`：只註冊/啟用 `\OpenClaw Watchdog`，並要求它立即跑一次。不直接啟動 primary llama.cpp。
- `stop_watchdog.cmd`：只停用 watchdog，不停止服務。加 `-ForceEnd` 才會要求結束正在跑的 watchdog pass。
- `show_status.cmd`：快速顯示 primary、vision、TTS、STT、Gateway/WebUI、Node、Telegram watchdog cache、Watchdog。
- `show_status.cmd -DeepTelegram`：手動即時深度查 Telegram `running/connected`，會直接問 Gateway `channels.status`，可能較慢。
- `start_codex_telegram_worker1.cmd`：啟用 `worker1` Telegram bot 的 Codex bridge，寫入 HKCU Run 登入自啟，並隱藏啟動 bridge process。
- `stop_codex_telegram_worker1.cmd`：停用 `worker1` Codex bridge 登入自啟，並停止 bridge process。

## Primary llama.cpp 規則

Primary llama.cpp 由 `Start.cmd` / `PS1\Start_LCPP.ps1` 管理。現在有兩個硬約束：

- sampling temperature 預設一律 `--temp 0.35`。
- managed launcher 的 server slot 固定 `--parallel 2`。

`PS1\Start_LCPP.ps1` 會把 trailing args 裡的 `--parallel` / `-np` 移掉，再由 launcher 自己塞入 `--parallel 2`。這是為了避免舊 saved tuning profile、舊 model script、或手動參數又把 slot 帶回 `1`。

確認實際 command line：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'llama-server.exe' } |
  Select-Object ProcessId, CommandLine |
  Format-List
```

目前 primary 應該看到類似：

```text
--parallel 2 --host 127.0.0.1 --fit-target 512 --cache-ram 2048 --temp 0.35
```

## Vision 路線

這台機器的 `llama-cli --help` 沒列出 `--mmproj`，所以 vision 不走 `llama-cli`。依目前 llama.cpp multimodal 支援狀態與模型需求，vision 能力走：

- `llama-server`，作為 OpenAI-compatible vision endpoint。
- 或 `llama-mtmd-cli`，作為互動/測試工具。

OpenClaw runtime 使用獨立 Vision sidecar：

```text
http://127.0.0.1:8081/v1
```

`PS1\OpenClaw\start-llama-cpp-vision.ps1` 會啟動：

```text
Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf
Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-mmproj-f16.gguf
--ctx-size 32768
--parallel 2
--cache-ram 2048
--image-min-tokens 1024
--temp 0.35
```

注意事項：

- HF 模型頁標示 multimodal 並需要 mmproj，所以沒有 mmproj 時不要假裝 vision ready。
- `start-llama-cpp-vision.ps1` 會檢查 8081 是否已是預期 Qwen3VL vision model。
- 如果 8081 已被別的東西占用，而且不是預期 vision model，啟動應該失敗，不應默默沿用。
- 如果 vision server 還在舊 `--temp` 或舊 slot，managed launcher 會重啟它。

## OpenClaw 啟動流程

完整流程如下：

1. `start_openclaw.cmd -NoPause` 呼叫 `PS1\Start_OpenClaw.ps1`。
2. `Start_OpenClaw.ps1` 先 dot-source `PS1\OpenClawSupport.ps1`。
3. `Sync-OpenClawManagedStartupAssets` 把 repo 內的 managed assets 同步到 `%USERPROFILE%\.openclaw\scripts\`。
4. 同步內容包含 sidecar-aware gateway script、vision startup script、hidden Gateway launcher、hidden Node launcher、Control UI session patch、workspace `TOOLS.md`。
5. `gateway.cmd` 被改成只啟動 hidden Gateway launcher，不直接在可見 cmd 裡跑 gateway。
6. `node.cmd` 被補上 Telegram IPv4 env，並改成啟動 hidden Node launcher。
7. `openclaw.json` 會清掉 deprecated config、停用重型 startup plugins、保留 Telegram token/config，並同步目前 primary llama.cpp 模型。
8. 如果 8080 上已有 primary llama.cpp，OpenClaw provider 會同步到正在跑的模型。同步只改 config/session，不再使用 `Update_OpenClaw_Status.ps1 -RestartOpenClaw` 巢狀重啟。
9. 如果 `%USERPROFILE%\.openclaw\scripts\restart-openclaw-gateway.ps1` 存在，restart 會由 `Start_OpenClaw.ps1` 單一路徑 dispatch managed restart script，然後由外層 health checks 收斂。
10. Managed restart 先停止舊 Gateway/Node，重置 logs，再啟動 Gateway。外層不要用 `Start-Process -Wait` 等這個 script，因為 Gateway/Node hidden launcher 是長駐 descendants，會讓等待永遠不結束。
11. Gateway launcher 先啟動 TTS/STT，等待 `8000/health` 與 `8001/health`。
12. Gateway launcher 確保 Vision sidecar ready，等待 `8081/v1/models`。
13. Gateway launcher 啟動 `node ...\openclaw\dist\index.js gateway run --port 29644`。
14. Gateway ready 後，再啟動 `node ...\openclaw\dist\index.js node run --host 127.0.0.1 --port 29644`。
15. Telegram channel 會在 Gateway ready 後開始 provider/polling；OpenClaw 只接 `default` 與 `worker2`。
16. `start_openclaw.cmd` 最後會要求 watchdog 立即跑一次，這時 watchdog 可能短暫顯示 `Running`，下一輪應回到 `Ready`。

2026-04-28 實測：`start_openclaw.cmd -NoPause` 在完整重啟、等待 Gateway/Node/TTS/STT/Vision/Telegram 後可正常回 `0`；後續 `show_status.cmd -NoPause -DeepTelegram` 顯示 `default`、`worker2` 都 `running=True; connected=True`。

## Codex Telegram worker1 bridge

2026-04-28 起，`worker1` Telegram bot 不再屬於 OpenClaw。`openclaw.json` 已移除：

- `channels.telegram.accounts.worker1`
- `bindings[]` 中 `channel=telegram`、`accountId=worker1` 的 binding

worker1 token 仍保留在：

```text
%USERPROFILE%\.openclaw\credentials\telegram-worker1-token.txt
```

目前狀態：已暫停。

- HKCU Run `CodexTelegramWorker1Bridge` 已移除。
- `codex-telegram-worker1-bridge.mjs` / runner PowerShell process 已停止。
- Codex heartbeat automation `codex-telegram-worker1-inbox` 已不存在或停用。
- `inbox.jsonl` 保留，不會刪資料。

需要恢復時：

1. `start_codex_telegram_worker1.cmd -NoPause` 會建立 HKCU Run 登入自啟：

```text
CodexTelegramWorker1Bridge
```

2. 它隱藏啟動：

```text
PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.ps1
```

3. bridge 用 Node 長輪詢 Telegram `getUpdates`，只接受 allowlist 使用者 `878295395`，把新訊息排到：

```text
F:\Documents\GitHub\easy_llamacpp\.codex-telegram-worker1\inbox.jsonl
```

4. 若要讓 Codex 自動回覆，還需要重新建立 Codex thread heartbeat automation：

```text
codex-telegram-worker1-inbox
```

它會讀 inbox，對未處理訊息用 Codex 回覆，並透過：

```text
PS1\CodexTelegramWorker1\Send-CodexTelegramWorker1Reply.ps1
```

把答案送回原 Telegram chat。

注意：這不是 OpenClaw agent，也不走本機 llama.cpp。`codex.exe` 在這台機器的 WindowsApps 路徑會從背景 shell 回 `Access is denied`，所以目前不能用 `codex exec` 做純本機 CLI bridge；若未來要自動回覆，路線是 Telegram bridge + Codex thread heartbeat。heartbeat 會消耗 Codex 帳戶額度，不建議每分鐘長期開著。

## Watchdog 運作

Watchdog 是 Windows 工作排程：

```text
\OpenClaw Watchdog
```

目前任務命令：

```text
wscript.exe %USERPROFILE%\.openclaw\scripts\watch-openclaw-stack-hidden.vbs
```

不要把 watchdog task 改回直接跑 `powershell.exe` 或 `.cmd`。在 Windows 上 `-WindowStyle Hidden` 仍可能先閃出 console，再隱藏或縮到工作列；`wscript.exe` 是 GUI 子系統入口，不會建立 cmd/PowerShell console，才適合每分鐘 watchdog。

核心邏輯：

- 每 1 分鐘檢查一次。
- 看到 `%USERPROFILE%\.openclaw\openclaw.stop` 就直接退出，不會自動拉起服務。
- 使用 mutex `Local\OpenClawStackWatchdog`，避免上一輪重啟還沒完成時又疊一輪。
- 每分鐘檢查 Primary llama.cpp、TTS、STT、Vision、Gateway、Node。
- 每 1 分鐘確認 Telegram `running/connected`，使用 `%USERPROFILE%\.openclaw\scripts\probe-openclaw-telegram-status.mjs` 直接問 Gateway `channels.status`，不走 OpenClaw CLI。helper 內部 gateway timeout 是 30 秒，watchdog process timeout 是 60 秒，避免 Gateway/WebUI 短暫忙碌時只回空 stdout。
- 全部通過就移除 restart marker 與 failure state，然後退出。
- Gateway 先試 HTTP health/root；如果 HTTP 慢回應但 TCP port 已開且 Gateway process 存在，也視為 alive，避免 Gateway/WebUI 忙碌時被誤殺。
- 核心服務需要連續 2 次失敗才重啟。
- Telegram probe 會記錄 `running/connected`，但只有 provider 明確 `running=False` 且連續 2 次失敗才重啟。`connected=False`、Gateway 忙碌、probe timeout 或 Telegram API/網路暫時失敗，只會更新 cache/log/status，不會直接重啟整套 OpenClaw。
- 失敗計數存在 `%USERPROFILE%\.openclaw\logs\openclaw-watchdog-state.json`。
- Telegram probe cache 存在 `%USERPROFILE%\.openclaw\logs\openclaw-watchdog-telegram-state.json`。
- restart 會寫入 `%USERPROFILE%\.openclaw\logs\openclaw-watchdog.log`。

為什麼要連續失敗才重啟：Gateway startup 曾經因 plugin runtime deps install、channel startup、Telegram provider warmup 耗時超過 2 分鐘。單次 timeout 直接重啟會形成「剛快好又被殺掉」的循環。Telegram 另外拆成 provider health 與 API connectivity：provider 掉了要修，外部 Telegram API 抖動則要回報但不要殺 OpenClaw。

### Watchdog 與長駐服務父子關係

踩過一個重要坑：如果 watchdog 直接 `Start-Process` 生出長駐 Gateway/Node，Windows 工作排程會把 watchdog 顯示成一直 `Running`，因為子孫進程還活著。

同類坑也發生在 `start_openclaw.cmd`：如果外層 starter 用 `Start-Process -Wait` 或同步 stdout/stderr pipe 等 `restart-openclaw-gateway.ps1`，而 restart script 又生出長駐 hidden Gateway/Node launcher，外層會卡住。現在 starter 只 dispatch restart pass，後續由 `Wait-OpenClawGatewayReady`、TTS/STT/Vision health、Node process detection 來判斷是否成功。

目前修法：

- `restart-openclaw-gateway.ps1` 優先透過 `schtasks /Run /TN "\OpenClaw Gateway"` 啟動 Gateway。
- Node 同理透過 `schtasks /Run /TN "\OpenClaw Node"` 啟動。
- `/Run` 回 `0` 還不夠，script 必須在短時間內看到 hidden launcher 或實際 Gateway/Node process。這串踩過一次 `schtasks /Run` 回成功，但沒有留下 child process，導致 watchdog 空等 Gateway ready，看起來像 watchdog 自己死掉。
- 如果 task 不存在、`/Run` 失敗、或 `/Run` 成功但沒有預期 child process，才 fallback 到 detached hidden PowerShell。

這樣 watchdog pass 可以回到 `Ready`，下一分鐘仍能正常檢查。

### 防止閃出 CMD 視窗

2026-04-28 追加修正：使用電腦時仍會看到類似 cmd/PowerShell 的視窗短暫跳出又縮到工作列。主因是 Windows Task Scheduler / HKCU Run 啟動 console 子系統程式時，即使參數有 `-WindowStyle Hidden`，console 仍可能先被建立。

現在固定使用 no-console VBS wrapper：

```text
%USERPROFILE%\.openclaw\scripts\watch-openclaw-stack-hidden.vbs
%USERPROFILE%\.openclaw\scripts\start-openclaw-gateway-hidden.vbs
%USERPROFILE%\.openclaw\scripts\start-openclaw-node-hidden.vbs
F:\Documents\GitHub\easy_llamacpp\PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.vbs
```

實際原理：

- 排程或 Run key 先跑 `wscript.exe`。
- `.vbs` 用 `WScript.Shell.Run command, 0, ...` 啟動 PowerShell。
- `0` 代表 hidden window，且 `wscript.exe` 本身不會建立 console。

目前已成功套用：

```text
\OpenClaw Watchdog -> C:\WINDOWS\System32\wscript.exe C:\Users\JackYang\.openclaw\scripts\watch-openclaw-stack-hidden.vbs
HKCU Run CodexTelegramWorker1Bridge -> C:\WINDOWS\System32\wscript.exe F:\Documents\GitHub\easy_llamacpp\PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.vbs
```

`\OpenClaw Gateway` / `\OpenClaw Node` 舊 task action 目前仍是 `gateway.cmd` / `node.cmd`，因為系統拒絕直接改它們的 action；但它們沒有週期觸發，正常 managed restart 會走 hidden launcher。若未來手動 `/Run` 這兩個舊 task 仍可能看到短暫 cmd，請改用 `start_openclaw.cmd -NoPause` 或 VBS launcher。

### Telegram status probe

Telegram deep readiness 如果走 `openclaw channels status --channel telegram --json`，曾經 timeout 後留下 orphan `node.exe`，也會觸發 agentmemory/markitdown 之類工具 process，造成後續 status/watchdog 堆疊與 C 槽寫入。

目前修法：

- watchdog 每分鐘 pass 做核心快檢，並以輕量 helper 查 Telegram channel 狀態。
- Telegram probe 使用 `probe-openclaw-telegram-status.mjs` 直接 import OpenClaw gateway call module，呼叫 `channels.status`，不走 CLI command bootstrap。
- `show_status.cmd` 預設讀 watchdog Telegram cache，所以會顯示最近一次 `connected=True/False` 與 probe age。
- `show_status.cmd -DeepTelegram` 會即時跑同一個輕量 helper，helper timeout 同樣放寬到 30 秒，外層最多等 45 秒。
- deep probe 前後會清掉過期的 `channels status --channel telegram` process；timeout 時會殺整棵 process tree。
- watchdog 只在 Telegram provider 明確 `running=False` 且連續 2 次失敗時重啟。`connected=False` 或 probe timeout 代表 Telegram API/網路或 Gateway 忙碌，會留下 cache/log 讓 `show_status.cmd` 看見，但不應重啟整套。

## Telegram 規則

Telegram 這串踩過三類問題：

1. Config 被同步流程關掉或 token 沒被視為 configured。
2. Windows/Node DNS family 選擇造成 Telegram 連線不穩。
3. Native command menu registration 或 command catalog 掃描拖住 startup。
4. `browser.enabled=true` 會讓 Gateway 啟動時 stage/install browser runtime deps，短時間內造成 HTTP/WS busy、Telegram probe timeout，看起來像 Telegram 掛掉。

目前固定策略：

```bat
set "OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY=1"
set "OPENCLAW_TELEGRAM_DNS_RESULT_ORDER=ipv4first"
set "OPENCLAW_TELEGRAM_FORCE_IPV4=1"
set "OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS=1"
```

Gateway launcher 也會在每次啟動前把 `browser.enabled` 壓回 `false`，並清掉 heavy plugin/MCP 殘留。這是為了防止 Telegram 或 WebUI 觸發的 config 變更讓 browser plugin 在下次重啟時重新安裝 `playwright-core`、MCP SDK 等 runtime deps。

`openclaw.json` 裡只放 schema 接受的 network keys：

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

不要把 `forceIpv4` 寫進 `openclaw.json`，OpenClaw schema 會視為 additional property，可能直接 `Config invalid`。

檢查 Telegram：

```powershell
openclaw channels status --channel telegram --json
```

正常條件：

- `enabled=true`
- `configured=true`
- `running=true`
- `connected=true`

`show_status.cmd` 會把 OpenClaw Telegram `default`、`worker2` 分開列出，並另外顯示 `Codex Telegram worker1` bridge。預設快速模式讀 watchdog cache，例如：

```text
Telegram default : OK - running=True; connected=True; watchdog telegram probe 2m ago
```

若要立刻查真實 Telegram API connected 狀態，跑：

```bat
show_status.cmd -DeepTelegram
```

這個 deep probe 可能較慢。watchdog 會每分鐘執行，但只把 provider `running=False` 當成可重啟故障；單純 `connected=False` 會顯示給人看，不會自動殺掉整套服務。

## 常見症狀與判斷

### `start.cmd` 卡在 `==> Starting OpenClaw gateway`

這不一定代表死掉。Gateway 從啟動到 ready 可能會做幾件慢事：

- TTS/STT health 等待。
- Vision model warmup。
- OpenClaw config loading。
- plugin runtime deps staging/install。
- Telegram channel startup。

這串實測過一次 Gateway ready 花了約 `135.3s`。因此 managed readiness timeout 不能只設 60 秒。

看 log：

```powershell
Get-Content "$env:USERPROFILE\.openclaw\logs\gateway.stdout.log" -Tail 120
Get-Content "$env:USERPROFILE\.openclaw\logs\gateway.stderr.log" -Tail 120
```

看到這行才表示 Gateway 真正 ready：

```text
[gateway] ready
```

### `show_status.cmd` 說 Gateway DOWN，但 WebUI 明明開著

這通常是 Gateway HTTP handler 被 WebUI/control-ui 的長輪詢暫時佔住，尤其 `models.list`、`usage.cost`、`sessions.usage` 或 `channels.status` 在跑的時候，`/health` 可能短暫 timeout。

目前 `show_status.cmd` 與 watchdog 都不只看 HTTP。若 `127.0.0.1:29644` TCP port 有 listen，且 Gateway process 存在，會顯示 Gateway alive/busy，而不是直接判死：

```text
OpenClaw Gateway/WebUI : OK - tcp=listening; process=detected; http=busy
```

如果 WebUI 可操作但 status 偶爾出現 busy，先看下一分鐘 watchdog 是否仍 `Last Result: 0`，不要立刻重啟整組。

### start watchdog 後 C 槽大量寫入

這串後來確認不是 watchdog 自己在每分鐘安裝東西。Watchdog 本身只做 health check、少量 state/log 寫入；真正造成 C 槽看起來頻繁讀寫的來源通常是 Gateway/WebUI、Node、Telegram session，或被 Gateway 啟動的重型 MCP/plugin。

這次實際抓到的來源：

- WebUI / control-ui 開著時，會透過 Gateway WS 輪詢 `models.list`、`models.authStatus`、`usage.cost`、`sessions.usage`、`cron.*`、`logs.tail`、`node.list`、`channels.status`。
- 這些輪詢會更新 `%USERPROFILE%\.openclaw\logs`、`devices`、`nodes`、`telegram`、`node.json`、`openclaw.json.last-good`。
- `openclaw.json` 裡如果還留著 `mcp.servers.agentmemory` 或 `mcp.servers.markitdown`，Gateway 會拉起 `agentmemory` / `markitdown_mcp`，讀寫量會明顯增加。
- `openclaw.json` 裡如果 `browser.enabled=true`，Gateway 啟動時會 stage/install browser runtime deps，例如 `@modelcontextprotocol/sdk`、`playwright-core`，寫到 `%USERPROFILE%\.openclaw\plugin-runtime-deps`、`node_modules` 等 C 槽路徑，期間 Telegram status probe 也可能 timeout。
- 舊流程也踩過一般 plugin runtime deps staging/install，症狀同樣是 C 槽大量讀寫與 Gateway/WebUI 忙碌。

目前修法：

- Gateway hidden launcher 已設定 `OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS=1`。
- Node hidden launcher 也必須設定 `OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS=1`，否則 watchdog 只要重啟 Node，就可能又觸發 plugin runtime deps install。
- `node.cmd` 同步邏輯會保留這些 env，避免下次 `start_openclaw.cmd` 重新同步時被洗掉。
- 另外固定 `OPENCLAW_SKIP_PLUGIN_SERVICES=1`、`OPENCLAW_SKIP_STARTUP_MODEL_PREWARM=1`、`OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS=1`，降低啟動時不必要的 plugin service 與 native command side effect。
- `Start_OpenClaw.ps1` 會停用 heavy startup plugins，並移除 `mcp.servers.agentmemory`、`mcp.servers.markitdown` 與相關 `plugins.load.paths`。
- `run-openclaw-gateway-with-media.ps1` 也會在每次 Gateway 啟動前 sanitize config：把 `browser.enabled` 寫回 `false`，並清掉 heavy plugin/MCP 殘留。這點很重要，因為 watchdog 的 Gateway restart 不一定會先跑完整 `Start_OpenClaw.ps1`。

判斷方式：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'agentmemory|markitdown|channels\s+status|probe-openclaw|watch-openclaw' } |
  Select-Object ProcessId, ParentProcessId, Name, CommandLine |
  Format-List
```

如果只看到正在查詢的 PowerShell 自己，沒有 `agentmemory` / `markitdown_mcp` / orphan `channels status`，代表重型 MCP 已清掉。剩下的 `.openclaw` 寫入多半是 Gateway/WebUI/Node/Telegram 的正常 state/log 更新；WebUI 開著時會更明顯。

如果未來手動刪掉 `%USERPROFILE%\.openclaw\plugin-runtime-deps`，這些 skip env 會讓服務不要在 watchdog pass 裡自動補裝；需要補依賴時應手動、一次性處理，不要放在每分鐘 watchdog 流程裡。

### Gateway/WebUI 開了，但 terminal 視窗沒消失

早期 `start.cmd` 直接跑 foreground launcher，畫面看起來卡住。現在流程改成：

- `start_openclaw.cmd` 用 `-WindowStyle Hidden` 呼叫 PowerShell。
- `gateway.cmd` 啟動 hidden Gateway launcher。
- `node.cmd` 啟動 hidden Node launcher。
- 成功時 `start_openclaw.cmd -NoPause` 會回 `0` 並結束；實際 summary/connected 狀態用 `show_status.cmd -NoPause -DeepTelegram` 查。

如果還有可見視窗，優先檢查是否由舊 `gateway.cmd` / `node.cmd` 或舊 task 跑出來。

### OpenClaw Node 新視窗可以關嗎

現在不應該再有可見 Node 視窗。若仍跳出可見 Node 視窗，表示不是走 hidden launcher。用這些檢查：

```powershell
schtasks /Query /TN "\OpenClaw Node" /V /FO LIST
Get-Content "$env:USERPROFILE\.openclaw\node.cmd"
```

正常 `node.cmd` 會呼叫：

```text
%OPENCLAW_STATE_DIR%\scripts\start-openclaw-node-hidden.ps1
```

不要手動關子視窗來「停止服務」。要停止整組請用：

```bat
stop_openclaw.cmd
```

### TTS/STT 沒起來

以前只看 Gateway/WebUI 會漏掉 TTS/STT。現在 `show_status.cmd` 會明列：

```text
TTS : OK - http 8000/health
STT : OK - http 8001/health
```

若不 OK，先看：

```powershell
Get-Content "$env:USERPROFILE\.openclaw\logs\tts-server.stdout.log" -Tail 80
Get-Content "$env:USERPROFILE\.openclaw\logs\tts-server.stderr.log" -Tail 80
Get-Content "$env:USERPROFILE\.openclaw\logs\stt-server.stdout.log" -Tail 80
Get-Content "$env:USERPROFILE\.openclaw\logs\stt-server.stderr.log" -Tail 80
```

Gateway launcher 會先啟動 TTS/STT，再等 health。若它們還在 warming up，Gateway 不應該永久卡死，watchdog 會下一輪再看。

### OpenClaw 開一段時間自己死掉

這串的原因不是單一 bug，而是幾個條件連在一起：

- Gateway startup 有時會因 plugin runtime deps install 或 Telegram startup 變慢。
- Watchdog 以前單次 health timeout 就重啟。
- 重啟又殺掉正在 warming up 的 Gateway/Node。
- Watchdog 直接生出長駐子進程時，排程狀態會卡在 `Running`。
- `gateway.cmd` 改成只啟動 hidden VBS launcher 後，舊 detection 只找 `run-openclaw-gateway-with-media.ps1` 字串，會誤以為不是 managed media，導致 starter 只等 60 秒。

目前修法：

- Watchdog 每 1 分鐘跑，但需要連續失敗才重啟。
- Gateway/Node 用自己的 Windows task 啟動，watchdog 不持有長駐子進程。
- `openclaw.stop` 存在時 watchdog 不會拉服務。
- Gateway ready timeout 放寬，Telegram 不再作為立即硬失敗。
- `Start_OpenClaw.ps1` 會把 `gateway.cmd -> start-openclaw-gateway-hidden.vbs` 視為 managed media 路徑，因此使用 480 秒 warmup timeout。
- 2026-04-27 20:52 修正：舊 watchdog 會把 `Telegram connected probe returned empty output`、probe timeout 或 Telegram API/網路錯誤累積成 Telegram failure，2 次後重啟整套；如果剛好 Gateway/Node 還在 warmup，就會變成每分鐘自我重啟。現在只有 Telegram provider `running=False` 才會累積 restart failure，`connected=False` 只更新狀態。

### Watchdog 沒作用或一直 down

先看 task：

```powershell
schtasks /Query /TN "\OpenClaw Watchdog" /V /FO LIST
```

重點欄位：

- `Scheduled Task State: Enabled`
- `Status: Ready` 或短暫 `Running`
- `Last Result: 0`
- `Repeat: Every: 0 Hour(s), 1 Minute(s)`

如果 `Status: Running` 很久不回 Ready，檢查是否仍有 watchdog 直接持有的長駐子進程：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'watch-openclaw|start-openclaw-gateway-hidden|start-openclaw-node-hidden' } |
  Select-Object ProcessId, ParentProcessId, Name, CommandLine |
  Format-List
```

如果 `openclaw.stop` 存在，watchdog 會故意不做事：

```powershell
Test-Path "$env:USERPROFILE\.openclaw\openclaw.stop"
```

移除 stop marker 的正常方式是：

```bat
start_openclaw.cmd -NoPause
```

### `openclaw gateway probe --host ...` 報 unknown option

`openclaw gateway probe` 不接受 `--host`。直接用：

```powershell
openclaw gateway probe
```

這台機器上 HTTP root 或 `openclaw status` 曾經 timeout。排查 readiness 時優先看：

- `show_status.cmd`
- `gateway.stdout.log` 裡的 `[gateway] ready`
- `http://127.0.0.1:29644/health`
- `openclaw gateway probe`

### `no enabled configured telegram accounts`

這通常代表 status probe 看到的 config 還沒完成載入、Telegram 被同步流程關掉、或 tokenFile 缺失。

檢查：

```powershell
Select-String "$env:USERPROFILE\.openclaw\openclaw.json" -Pattern 'telegram|tokenFile|enabled'
openclaw channels status --channel telegram --json
```

正常 `openclaw.json` 要有 Telegram channel enabled，且每個 account 的 token/tokenFile 要存在。同步流程會盡量保留既有 token/config，不應清掉。

## 啟動後驗證清單

1. `show_status.cmd` 全綠。
2. Watchdog task `Last Result: 0`，下一輪後 `Status: Ready`。
3. primary command line 有 `--parallel 2` 與 `--temp 0.35`。
4. vision command line 有 `--parallel 2`、`--temp 0.35`、`--mmproj`。
5. Gateway log 有 `[gateway] ready`。
6. Node process 存在：`dist\index.js node run --host 127.0.0.1 --port 29644`。
7. Telegram `default`、`worker2` 都 `running=True; connected=True`。
8. `Codex Telegram worker1` 顯示 `mode=paused; process=False; autostart=False`，除非你手動重新啟用 Codex bridge。

一次看主要進程：

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.CommandLine -match 'llama-server.exe|dist\\index.js gateway|dist\\index.js node run|tts_server|stt_server'
  } |
  Select-Object ProcessId, ParentProcessId, Name, CommandLine |
  Format-List
```

## 重要檔案

Repo 內：

```text
start_openclaw.cmd
stop_openclaw.cmd
show_status.cmd
start_watchdog.cmd
stop_watchdog.cmd
PS1\Start_OpenClaw.ps1
PS1\Update_OpenClaw_Status.ps1
PS1\OpenClawSupport.ps1
PS1\OpenClaw\run-openclaw-gateway-with-media.ps1
PS1\OpenClaw\start-llama-cpp-vision.ps1
PS1\OpenClaw\start-openclaw-gateway-hidden.ps1
PS1\OpenClaw\start-openclaw-node-hidden.ps1
PS1\OpenClaw\start-openclaw-gateway-hidden.vbs
PS1\OpenClaw\start-openclaw-node-hidden.vbs
PS1\OpenClaw\restart-openclaw-gateway.ps1
PS1\OpenClaw\watch-openclaw-stack.ps1
PS1\OpenClaw\watch-openclaw-stack-hidden.vbs
PS1\OpenClaw\probe-openclaw-telegram-status.mjs
PS1\Show_OpenClaw_Status.ps1
PS1\Start_OpenClaw_Watchdog.ps1
PS1\Stop_OpenClaw_Watchdog.ps1
PS1\Start_Codex_Telegram_Worker1.ps1
PS1\Stop_Codex_Telegram_Worker1.ps1
PS1\CodexTelegramWorker1\codex-telegram-worker1-bridge.mjs
PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.ps1
PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.vbs
PS1\CodexTelegramWorker1\Send-CodexTelegramWorker1Reply.ps1
start_codex_telegram_worker1.cmd
stop_codex_telegram_worker1.cmd
```

Runtime 內：

```text
%USERPROFILE%\.openclaw\start.cmd
%USERPROFILE%\.openclaw\stop.cmd
%USERPROFILE%\.openclaw\gateway.cmd
%USERPROFILE%\.openclaw\node.cmd
%USERPROFILE%\.openclaw\openclaw.json
%USERPROFILE%\.openclaw\scripts\run-openclaw-gateway-with-media.ps1
%USERPROFILE%\.openclaw\scripts\start-llama-cpp-vision.ps1
%USERPROFILE%\.openclaw\scripts\start-openclaw-gateway-hidden.ps1
%USERPROFILE%\.openclaw\scripts\start-openclaw-node-hidden.ps1
%USERPROFILE%\.openclaw\scripts\restart-openclaw-gateway.ps1
%USERPROFILE%\.openclaw\scripts\watch-openclaw-stack.ps1
```

Logs：

```text
%USERPROFILE%\.openclaw\logs\gateway.stdout.log
%USERPROFILE%\.openclaw\logs\gateway.stderr.log
%USERPROFILE%\.openclaw\logs\gateway-launcher.*.stdout.log
%USERPROFILE%\.openclaw\logs\gateway-launcher.*.stderr.log
%USERPROFILE%\.openclaw\logs\node-host.stdout.log
%USERPROFILE%\.openclaw\logs\node-host.stderr.log
%USERPROFILE%\.openclaw\logs\tts-server.stdout.log
%USERPROFILE%\.openclaw\logs\tts-server.stderr.log
%USERPROFILE%\.openclaw\logs\stt-server.stdout.log
%USERPROFILE%\.openclaw\logs\stt-server.stderr.log
%USERPROFILE%\.openclaw\logs\llama-vision-server.stdout.log
%USERPROFILE%\.openclaw\logs\llama-vision-server.stderr.log
%USERPROFILE%\.openclaw\logs\openclaw-watchdog.log
%USERPROFILE%\.openclaw\logs\openclaw-watchdog-state.json
F:\Documents\GitHub\easy_llamacpp\logs\llama-server.stdout.log
F:\Documents\GitHub\easy_llamacpp\logs\llama-server.stderr.log
```

## 回歸檢查

修啟動流程後，至少跑：

```bat
stop_openclaw.cmd
start_openclaw.cmd -NoPause
show_status.cmd
```

再等 1 至 2 分鐘：

```bat
show_status.cmd
```

預期 watchdog 回到 `Ready`，`Last Result` 是 `0`。如果剛跑完 `start_openclaw.cmd` 後看到 watchdog `Running` / `267009`，先等下一分鐘，不要立刻判失敗。

最後確認 slot 與 temp：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'llama-server.exe' } |
  Select-Object ProcessId, CommandLine |
  Format-List
```

兩個 llama-server 都應該是 `--parallel 2`，且都有 `--temp 0.35`。
