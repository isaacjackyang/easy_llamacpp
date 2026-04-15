# llama.cpp Launcher / llama.cpp 啟動器

這個資料夾包含 `Start_LCPP.ps1`，也包含較方便雙擊或命令列使用的 `Start.cmd`、`stop_all.cmd`、`stop_opencalw.cmd`、`stop_llamacpp.cmd`、`start_voice_service.cmd`、`stop_voice_service.cmd`、`install.cmd`、`install_latest.cmd`。它們分別用來啟動、全部停止、只停止 OpenClaw、只停止 `llama.cpp`、只啟動 TTS/STT、只停止 TTS/STT、安裝官方 Windows 預編譯版，以及在本機編譯安裝最新版 `llama.cpp` 到 `bin\`，並管理本機的 `llama-server.exe`、模型切換、背景執行與 OpenClaw runtime。  
This folder contains `Start_LCPP.ps1` and also simpler `Start.cmd`, `stop_all.cmd`, `stop_opencalw.cmd`, `stop_llamacpp.cmd`, `start_voice_service.cmd`, `stop_voice_service.cmd`, `install.cmd`, and `install_latest.cmd` wrappers for double-click or command-line use. They are used to start, stop everything, stop OpenClaw only, stop `llama.cpp` only, start TTS/STT only, stop TTS/STT only, install the official Windows prebuilt release, and locally build/install the latest `llama.cpp` into the `bin\` folder, including local `llama-server.exe` management, model switching, background execution, and the OpenClaw runtime.

## 目錄結構 / Folder Layout

建議使用下面這種結構，把你自己的腳本和 `llama.cpp` 二進位分開管理：  
Use the following layout so your own scripts stay separate from the `llama.cpp` binaries:

```text
Start.cmd
install.cmd
install_latest.cmd
stop_all.cmd
stop_opencalw.cmd
stop_llamacpp.cmd
start_voice_service.cmd
stop_voice_service.cmd
README.md
PS1\
  Install_LCPP_Prebuilt.ps1
  Install_LCPP.ps1
  Start_LCPP.ps1
  Start_Voice_Service.ps1
  stop.ps1
  scan_model.ps1
  Install_LCPP_Autostart.ps1
  Remove_LCPP_Autostart.ps1
json\
  model-index.json
  model-tuning.json
  model-switch-times.json
logs\
  llama-server.pid
  llama-server.stdout.log
  llama-server.stderr.log
bin\
  llama-server.exe
  llama-cli.exe
  llama.dll
  ggml*.dll
  cublas*.dll
  cudart*.dll
  ...
```

`Start_LCPP.ps1` 會優先使用 `bin\llama-server.exe`。  
`Start_LCPP.ps1` prefers `bin\llama-server.exe`.

如果 `bin\` 不存在，但根目錄仍有舊版 `llama-server.exe`，腳本也能相容使用。  
If `bin\` does not exist but a legacy `llama-server.exe` is still beside the script, the launcher can still use it for compatibility.

## 安裝官方 Windows 預編譯版 / Install Official Windows Prebuilt

`install.cmd` 與 [`PS1/Install_LCPP_Prebuilt.ps1`](C:/Users/USER/llama%20win%20cuda%2013/PS1/Install_LCPP_Prebuilt.ps1) 會從官方 `ggml-org/llama.cpp` 最新 release 下載 Windows 預編譯版 ZIP，預設安裝 CUDA x64 版本，並把執行檔與 DLL 安裝到 `bin\`。  
`install.cmd` and [`PS1/Install_LCPP_Prebuilt.ps1`](C:/Users/USER/llama%20win%20cuda%2013/PS1/Install_LCPP_Prebuilt.ps1) download the latest official `ggml-org/llama.cpp` Windows release ZIP assets, default to the CUDA x64 package, and install the executables and DLLs into `bin\`.

最簡單的安裝方式：  
The simplest install command:

```bat
.\install.cmd
```

`install.cmd` 現在預設會安裝最新版官方 Windows CUDA 預編譯版。  
`install.cmd` now installs the latest official Windows CUDA prebuilt package by default.

如果 `.cache\llama.cpp-prebuilt\downloads\` 已經有對應這個 latest release 的 ZIP，`install.cmd` 會直接重用，不會重複下載；需要時可加 `-ForceDownload` 強制重抓。  
If `.cache\llama.cpp-prebuilt\downloads\` already contains the ZIP assets for that latest release, `install.cmd` reuses them instead of downloading again; use `-ForceDownload` when you want a fresh download.

常見範例：  
Common examples:

```bat
.\install.cmd -InstallAutostart -TriggerMode Startup
.\install.cmd -ForceDownload
.\PS1\Install_LCPP_Prebuilt.ps1 -Backend CPU
.\PS1\Install_LCPP_Prebuilt.ps1 -Backend Vulkan
.\PS1\Install_LCPP_Prebuilt.ps1 -CudaVersion 12.4
```

## 本機編譯最新版 / Build Latest Locally

`install_latest.cmd` 與 [`PS1/Install_LCPP.ps1`](C:/Users/USER/llama%20win%20cuda%2013/PS1/Install_LCPP.ps1) 會從官方 `ggml-org/llama.cpp` 下載最新版原始碼壓縮包，用 CMake 在本機重新編譯，然後把新的執行檔與 DLL 安裝到 `bin\`。  
`install_latest.cmd` and [`PS1/Install_LCPP.ps1`](C:/Users/USER/llama%20win%20cuda%2013/PS1/Install_LCPP.ps1) download the latest official `ggml-org/llama.cpp` source archive, rebuild it locally with CMake, and then install the fresh executables and DLLs into `bin\`.

建議先準備好以下環境：  
Recommended prerequisites:

- Visual Studio Community / Build Tools（例如 2022、2026 或更新版），並勾選 `Desktop development with C++`
- CMake
- 如果要編譯 CUDA 版，請先安裝 CUDA Toolkit
- 如果要編譯 Vulkan 版，請先安裝 Vulkan SDK 或至少能通過 `vulkaninfo`

最簡單的安裝方式：  
The simplest install command:

```bat
.\install_latest.cmd
```

`install_latest.cmd` 現在固定會編譯最新版官方 release 的 CUDA 版。  
`install_latest.cmd` now always builds the latest official release with the CUDA backend.

如果 `.cache\llama.cpp-install\downloads\` 已經有對應這個 latest release 的原始碼 ZIP，`install_latest.cmd` 會直接重用，不會重複下載；需要時可加 `-ForceDownload` 強制重抓。  
If `.cache\llama.cpp-install\downloads\` already contains the source ZIP for that latest release, `install_latest.cmd` reuses it instead of downloading again; use `-ForceDownload` when you want a fresh download.

常見範例：  
Common examples:

```bat
.\install_latest.cmd -InstallAutostart -TriggerMode Startup
.\install_latest.cmd -ForceDownload
.\PS1\Install_LCPP.ps1 -Backend CPU
.\PS1\Install_LCPP.ps1 -Backend Vulkan
.\PS1\Install_LCPP.ps1 -Source Master -Backend CUDA
```

`Install_LCPP_Autostart.ps1` 仍然只負責安裝 Windows 排程工作，不負責下載或編譯 `llama.cpp`。  
`Install_LCPP_Autostart.ps1` still only manages the Windows scheduled task. It does not download or build `llama.cpp`.

## 內建說明 / Built-in Help

你可以直接在 PowerShell 裡查看腳本內建說明：  
You can view the built-in PowerShell help directly:

```powershell
Get-Help .\PS1\Start_LCPP.ps1 -Detailed
Get-Help .\PS1\Start_LCPP.ps1 -Examples
Get-Help .\PS1\Start_LCPP.ps1 -Full
```

## 互動式啟動器 / Interactive Launcher

現在直接執行下面這條時，預設會先進入互動式選單，而不是立刻啟動 server：  
Running the command below now opens an interactive launcher menu first instead of immediately starting the server:

```powershell
.\PS1\Start_LCPP.ps1
```

也可以直接用 `Start.cmd`，效果相同，對雙擊啟動比較方便：  
You can also use `Start.cmd` for the same launcher flow, which is more convenient for double-click launching:

```bat
.\Start.cmd
```

若只想快速清理舊進程，也可以直接用：  
If you only want to quickly clear old processes, you can also use:

```bat
.\stop_all.cmd
```

若只想關閉 OpenClaw，可用：  
If you only want to stop OpenClaw, use:

```bat
.\stop_opencalw.cmd
```

若只想關閉 `llama.cpp`，可用：  
If you only want to stop `llama.cpp`, use:

```bat
.\stop_llamacpp.cmd
```

若只想啟動語音服務 TTS/STT，可用：  
If you only want to start the TTS/STT voice services, use:

```bat
.\start_voice_service.cmd
```

若只想停止語音服務 TTS/STT，可用：  
If you only want to stop the TTS/STT voice services, use:

```bat
.\stop_voice_service.cmd
```

如果你想直接編譯並安裝最新版官方 `llama.cpp`，也可以用：
If you want to build and install the latest official `llama.cpp` directly, you can also use:

```bat
.\install_latest.cmd
```

如果你只想直接安裝官方 Windows CUDA 預編譯版，請用：
If you only want the official Windows CUDA prebuilt package, use:

```bat
.\install.cmd
```

如果你只想單獨安裝開機自動啟動排程，請直接用：
If you only want to install the Windows autostart scheduled task by itself, use:

```powershell
.\PS1\Install_LCPP_Autostart.ps1 -TriggerMode Startup
```

第一層選單提供這幾個入口：  
The first screen provides these main entry points:

- `Quick Start`
  先選模型，再選 `Background Service` 或 `Open Web UI`。  
  Pick a model, then choose `Background Service` or `Open Web UI`.

- `Tune And Launch`
  先選模型，再進入可用鍵盤操作的參數矩陣畫面。用方向鍵移動，按 `Enter` 或 `Space` 編輯目前格子。矩陣裡包含 `GPU Layers`、`Repeating Layers`，也新增了 `Auto Tune` 開關。開啟後，腳本會在這次啟動真的完整塞進 GPU 且 VRAM 使用率接近目標時，把學到的參數寫進 `model-tuning.json`。  
  Pick a model, then open a keyboard-driven parameter matrix. Use arrow keys to move and press `Enter` or `Space` to edit the current cell. The matrix includes `GPU Layers`, `Repeating Layers`, and an `Auto Tune` toggle. When enabled, the script saves learned parameters to `model-tuning.json` after a launch that fully fits on GPU and lands near the target VRAM usage.

- `Server Status` / `Stop Running Server` / `llama-server Help`
  常用維護動作也保留在主選單。  
  Common maintenance actions remain available from the main menu.

## 模型索引檔 / Model Index File

互動式選單會讀取 [`json/model-index.json`](C:/Users/USER/llama%20win%20cuda%2013/json/model-index.json)。  
The interactive launcher reads [`json/model-index.json`](C:/Users/USER/llama%20win%20cuda%2013/json/model-index.json).

現在 [`PS1/Start_LCPP.ps1`](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1) 每次進入互動式選單前，都會先依腳本裡的 `$ConfiguredModelScanPath` 重掃 `*.gguf` 並刷新 `json/model-index.json`。如果那一行留空，腳本會退回到既有索引推測出的模型資料夾。  
[`PS1/Start_LCPP.ps1`](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1) now rescans `*.gguf` and refreshes `json/model-index.json` before each interactive launch, using the `$ConfiguredModelScanPath` line inside the script. If that line is left blank, it falls back to the model folder inferred from the existing index.

每筆模型可以定義名稱、路徑與能力標記，例如是否支援推理或視覺：  
Each model entry can define a display name, file path, and capability flags such as reasoning or vision:

```json
{
  "default_model_id": "example",
  "models": [
    {
      "id": "example",
      "name": "Example Model",
      "path": "D:\\Models\\example.gguf",
      "capabilities": {
        "chat": true,
        "reasoning": true,
        "vision": false,
        "tools": false,
        "embedding": false,
        "rerank": false
      },
      "notes": "Optional note shown in the menu."
    }
  ]
}
```

能力欄位目前會在選單中顯示成這些標籤：  
The launcher currently displays these capability labels in the menu:

- `Chat`
- `Reasoning`
- `Vision`
- `Tools`
- `Embedding`
- `Rerank`

## `Start_LCPP.ps1` 參數與 `llama.cpp` 參數的關係 / Wrapper Params vs. llama.cpp Params

`Start_LCPP.ps1` 開頭 `param(...)` 裡列出的，是這支包裝腳本自己的參數。  
The parameters listed in the `param(...)` block at the top of `Start_LCPP.ps1` are the wrapper script's own parameters.

這些參數會幫你管理：模型路徑、埠號、背景啟動、狀態檢查、自動開瀏覽器、以及自動切換模型。  
These wrapper parameters manage the model path, port, background start, status checks, browser auto-open, and automatic model switching.

`llama.cpp` 的 `llama-server.exe` 本身還有很多額外參數，現在不用全部手動寫進 `param()` 也能用。  
`llama-server.exe` itself supports many additional parameters, and you do not need to manually declare every one of them in `param()` anymore.

你可以直接把額外的 `llama-server.exe` 參數接在 `Start_LCPP.ps1` 命令後面，腳本會原樣轉交給底層 `llama-server.exe`。  
You can now append extra `llama-server.exe` parameters directly after the `Start_LCPP.ps1` command, and the script will forward them to the underlying `llama-server.exe`.

例如：  
For example:

```powershell
.\PS1\Start_LCPP.ps1 -Background --ctx-size 4096 --metrics
```

```powershell
.\PS1\Start_LCPP.ps1 -Background --ctx-size 8192 --api-key my-secret-key --metrics
```

如果你想看目前這版 `llama-server.exe` 實際支援哪些參數，可以直接用：  
If you want to see the exact parameters supported by the installed `llama-server.exe`, run:

```powershell
.\PS1\Start_LCPP.ps1 -LlamaHelp
```

如果你想跳過互動式選單，直接用命令列參數啟動，請加上 `-BypassMenu`。這個模式特別適合排程、自動啟動或快捷方式。  
If you want to skip the interactive launcher and start directly from command-line parameters, add `-BypassMenu`. This mode is especially useful for scheduled tasks, autostart, or shortcuts.

```powershell
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -NoBrowser -NoPause
```

注意：以下這些仍然建議用腳本自己的參數設定，不要放在後面轉交：  
Note: the following options should still be set through the wrapper script parameters, not the forwarded trailing arguments:

- `--model`
- `--port`
- `--gpu-layers`
- `--threads`
- `--threads-batch`

## 主要參數 / Main Parameters

### `-Port <int>`

用途：設定 `llama-server.exe` 的 HTTP 埠號。預設值是 `8080`。實際上應使用 `1` 到 `65535` 之間、且未被占用的埠。  
Purpose: Sets the HTTP port for `llama-server.exe`. The default is `8080`. In practice, use a free port between `1` and `65535`.

範例 / Example:

```powershell
.\PS1\Start_LCPP.ps1 -Port 8081
```

### `-GpuLayers <string>`

用途：傳給 `--gpu-layers`。允許值只有 `auto`、`all`、或非負整數字串，例如 `0`、`35`、`99`。預設值是 `auto`。當你保留 `auto` 時，wrapper 會讓 `llama.cpp` 依偵測到的 VRAM / RAM 自動 fitting。  
Purpose: Passed to `--gpu-layers`. Allowed values are `auto`, `all`, or a non-negative integer string such as `0`, `35`, or `99`. The default is `auto`. When you keep `auto`, the wrapper lets `llama.cpp` fit itself to the detected VRAM / RAM.

範例 / Examples:

```powershell
.\PS1\Start_LCPP.ps1 -GpuLayers auto
.\PS1\Start_LCPP.ps1 -GpuLayers all
.\PS1\Start_LCPP.ps1 -GpuLayers 99
```

### `-ExtremeMode`

用途：啟用更激進的自動 fitting，優先把 VRAM 往上推。這個模式主要搭配 `-GpuLayers auto` 使用；它會改用更小的 `--fit-target`，並在沒有手動覆寫時把 `--parallel` 壓得更低、把 prompt cache 壓得更小。  
Purpose: Enables a more aggressive auto-fit profile that prioritizes pushing VRAM usage higher. This mode is mainly intended for use with `-GpuLayers auto`; it uses a smaller `--fit-target` and, unless you override them yourself, reduces `--parallel` and prompt cache size.

範例 / Example:

```powershell
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -ExtremeMode
```

### `-AutoTune`

用途：啟用 per-model 的學習模式。當 `-GpuLayers auto` 這次啟動成功、模型完整放進 GPU、而且整體 GPU 使用率接近 95% 時，腳本會把 `GPU Layers`、`--fit-target`、`--cache-ram`、`--parallel` 等結果存到 [`json/model-tuning.json`](C:/Users/USER/llama%20win%20cuda%2013/json/model-tuning.json)。之後同一個模型、同一組顯卡配置、同一組 llama 參數再啟動時，會優先重用那組已學到的設定。  
Purpose: Enables per-model learning. When a `-GpuLayers auto` launch succeeds, fully fits on GPU, and lands near 95% aggregate GPU usage, the script stores the learned `GPU Layers`, `--fit-target`, `--cache-ram`, and `--parallel` values in [`json/model-tuning.json`](C:/Users/USER/llama%20win%20cuda%2013/json/model-tuning.json). Later launches of the same model with the same GPU layout and llama arguments reuse that learned profile first.

範例 / Example:

```powershell
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -AutoTune
```

### Tune And Launch: `Repeating Layers`

用途：在 `Tune And Launch` 畫面中，直接用 repeating layers 思考時比較方便。輸入的數字會自動換算成 `-ngl`，規則是 `ngl = repeating layers + 1`，多出的那 `1` 是 output layer。  
Purpose: In the `Tune And Launch` screen, this field is convenient when you want to think in repeating layers directly. The entered number is converted automatically into `-ngl` using `ngl = repeating layers + 1`, where the extra `1` represents the output layer.

例如：  
For example:

- `Repeating Layers = 0` 會換成 `-ngl 1`  
  `Repeating Layers = 0` becomes `-ngl 1`

- `Repeating Layers = 54` 會換成 `-ngl 55`  
  `Repeating Layers = 54` becomes `-ngl 55`

- `Repeating Layers = auto` 會把 `GPU Layers` 切回 `auto`  
  `Repeating Layers = auto` switches `GPU Layers` back to `auto`

### `-Threads <int>`

用途：傳給 `--threads`。如果設為 `-1`，表示自動，腳本會使用「邏輯核心數減 2」，且最低為 `1`。手動指定時建議使用正整數。  
Purpose: Passed to `--threads`. When set to `-1`, the script uses automatic mode and resolves it to logical CPU count minus 2, with a minimum of `1`. Use a positive integer for manual settings.

範例 / Example:

```powershell
.\PS1\Start_LCPP.ps1 -Threads 12
```

### `-ThreadsBatch <int>`

用途：傳給 `--threads-batch`。如果設為 `-1`，表示自動，腳本會使用邏輯核心數。手動指定時建議使用正整數。  
Purpose: Passed to `--threads-batch`. When set to `-1`, the script uses automatic mode and resolves it to logical CPU count. Use a positive integer for manual settings.

範例 / Example:

```powershell
.\PS1\Start_LCPP.ps1 -ThreadsBatch 16
```

### `-ModelPath <string>`

用途：指定 GGUF 模型路徑。可使用絕對路徑，也可使用相對於 launcher 根目錄的相對路徑。若省略 `-ModelPath`，腳本會改用 `json/model-index.json` 的 `default_model_id`。  
Purpose: Specifies the GGUF model path. You can use either an absolute path or a path relative to the launcher root. If omitted, the launcher uses the `default_model_id` entry from `json/model-index.json`.

範例 / Examples:

```powershell
.\PS1\Start_LCPP.ps1 -ModelPath "C:\Models\example.gguf"
.\PS1\Start_LCPP.ps1 -ModelPath ".\example.gguf"
```

### `-OpenPath <string>`

用途：在 server ready 後自動開啟的網址路徑。預設值是 `/v1/models`。如果沒寫前面的 `/`，腳本會自動補上。  
Purpose: Sets the browser path opened after the server is ready. The default is `/v1/models`. If you omit the leading `/`, the script adds it automatically.

範例 / Examples:

```powershell
.\PS1\Start_LCPP.ps1 -OpenPath /docs
.\PS1\Start_LCPP.ps1 -OpenPath v1/models
```

### `-ReadyTimeoutSec <int>`

用途：等待 server ready 並嘗試開瀏覽器的逾時秒數。預設值是 `180`。建議使用正整數，例如 `60`、`120`、`300`。  
Purpose: Sets the timeout in seconds while waiting for the server to become ready for browser auto-open. The default is `180`. Use a positive integer such as `60`, `120`, or `300`.

範例 / Example:

```powershell
.\PS1\Start_LCPP.ps1 -ReadyTimeoutSec 300
```

### 開關參數 / Switch Parameters

這些參數不用填值，寫上去就代表啟用。  
These parameters do not require a value. Including them enables the option.

`-Background`：背景啟動 `llama-server.exe`，PowerShell 會立刻返回。  
`-Background`: Starts `llama-server.exe` in the background and immediately returns control to PowerShell.

`-Status`：顯示目前追蹤中的 server 狀態、PID、URL、Port、實際模型路徑、runtime 設定、GPU offload 摘要與 log 路徑。  
`-Status`: Shows the tracked server status, PID, URL, port, actual model path, runtime settings, GPU offload summary, and log paths.

`-ShowGpuOffload`：為了相容舊快捷方式而保留，現在會導向 `-Status`。  
`-ShowGpuOffload`: Kept for backward compatibility with older shortcuts and now routes to `-Status`.

`-ExtremeMode`：啟用更激進的自動 fitting 設定，優先提高 VRAM 使用量。  
`-ExtremeMode`: Enables the more aggressive auto-fit profile that prioritizes higher VRAM usage.

`-Stop`：停止目前由這支腳本追蹤的 server。  
`-Stop`: Stops the server currently tracked by this script.

`-LlamaHelp`：顯示底層 `llama-server.exe --help` 的完整說明。  
`-LlamaHelp`: Shows the full `llama-server.exe --help` output from the underlying server binary.

`-NoBrowser`：不要在 server ready 後自動開瀏覽器。  
`-NoBrowser`: Prevents browser auto-open after the server becomes ready.

`-NoPause`：前景模式結束時不要顯示 `Press Enter to exit...`。  
`-NoPause`: Prevents the foreground script from waiting with `Press Enter to exit...`.

## 常用指令 / Common Commands

開啟互動式啟動器：  
Open the interactive launcher:

```powershell
.\PS1\Start_LCPP.ps1
```

跳過選單、在背景啟動並指定模型：  
Skip the menu and start in the background with a specific model:

```powershell
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -ModelPath "C:\Users\USER\Downloads\LLM\Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-v2.gguf"
```

跳過選單並改用其他埠號：  
Skip the menu and use another port:

```powershell
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -Port 8081
```

查看目前狀態：  
Check the current status:

```powershell
.\PS1\Start_LCPP.ps1 -Status
```

相容舊用法，仍可這樣呼叫，但現在會導向完整的 status 畫面：  
Backward-compatible old usage; it now opens the richer status view:

```powershell
.\PS1\Start_LCPP.ps1 -ShowGpuOffload
```

用極限模式重啟背景 server：  
Restart the background server with Extreme Mode:

```powershell
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -NoBrowser -NoPause -ExtremeMode
```

強制清理這個工作資料夾下舊的 `llama-server.exe`、OpenClaw、TTS、STT 進程：  
Force-clean older `llama-server.exe`, OpenClaw, TTS, and STT processes that belong to this workspace:

```powershell
.\PS1\stop.ps1
```

停止目前追蹤中的 server：  
Stop the currently tracked server:

```powershell
.\PS1\Start_LCPP.ps1 -Stop
```

`stop.ps1` 會比 `-Stop` 更激進一些。它不只會處理目前追蹤中的 PID，也會掃描這個工作資料夾對應的 `llama-server.exe` 路徑，並一起停止 OpenClaw、TTS、STT 的殘留進程，適合用在 VRAM / RAM 沒有正常釋放時。  
`stop.ps1` is more aggressive than `-Stop`. It does not only stop the tracked PID, but also scans for `llama-server.exe` processes that belong to this workspace and clears lingering OpenClaw, TTS, and STT processes too. It is useful when VRAM / RAM has not been released cleanly.

查看底層 `llama-server.exe` 全部參數：  
Show all underlying `llama-server.exe` parameters:

```powershell
.\PS1\Start_LCPP.ps1 -LlamaHelp
```

透過腳本轉交額外 `llama-server` 參數：  
Forward extra `llama-server` parameters through the wrapper:

```powershell
.\PS1\Start_LCPP.ps1 -Background --ctx-size 4096 --metrics
```

## 模型切換行為 / Model Switching Behavior

如果目前沒有 tracked server，腳本就直接啟動新的 server。  
If no tracked server is running, the script starts a new one.

每次進入實際啟動流程前，腳本都會先清理這個工作資料夾下舊的 `llama-server.exe` 進程，再啟動新的 server。  
Before each actual launch, the script clears older `llama-server.exe` processes started from this workspace, then starts a fresh server.

如果 `-GpuLayers` 保持 `auto`，腳本還會在啟動時偵測目前可用的 GPU VRAM 與系統 RAM，動態調整 `--fit-target`、`--cache-ram`、`--parallel`，目標是盡量吃滿 VRAM，但減少把壓力打到 pagefile / SSD 的機率。  
If `-GpuLayers` stays at `auto`, the script also detects currently available GPU VRAM and system RAM at launch time and adjusts `--fit-target`, `--cache-ram`, and `--parallel` dynamically, aiming to fill VRAM while reducing the chance of spilling pressure into the pagefile / SSD.

如果再加上 `-ExtremeMode`，這套自動調整會更激進，通常會換成更小的 VRAM 保留空間，並把 slots 與 prompt cache 壓得更低。  
If you also add `-ExtremeMode`, the auto-tuning becomes more aggressive, usually with a smaller VRAM margin and lower slot / prompt-cache overhead.

如果你開啟 `-AutoTune`，而這次載入最終完整塞進 GPU 並落在目標 VRAM 區間，腳本會把這次驗證成功的組合記下來；之後再啟動同一模型時，就會優先套用該 profile。若目前可用 VRAM 比當初學到時更少，腳本會自動退回即時自動 fitting，不會硬套舊設定。  
If you enable `-AutoTune` and a launch fully fits on GPU within the target VRAM window, the script remembers that validated combination and prefers it on later launches of the same model. If current free VRAM is lower than when the profile was learned, the script automatically falls back to live adaptive fitting instead of forcing the old settings.

這表示你可以直接用一條指令切換模型：  
This means you can switch models directly with a single command:

```powershell
.\PS1\Start_LCPP.ps1 -Background -ModelPath "C:\Models\another-model.gguf"
```

## 詳細更新說明 / Detailed Update Guide For New llama.cpp Versions

### 更新原則 / Update Principle

不要只替換 `llama-server.exe`。  
Do not replace only `llama-server.exe`.

`llama.cpp` 更新時，常常會連動以下檔案版本：  
When `llama.cpp` is updated, these files often need to stay in sync:

- `llama-*.exe`
- `ggml*.dll`
- `llama.dll`
- `mtmd.dll`
- `rpc-server.exe`
- CUDA 相關 DLL，例如 `cublas*.dll`、`cudart*.dll`
- OpenMP 或其他隨附 runtime，例如 `libomp140.x86_64.dll`

最穩定的做法是整包更新 `bin\` 內容。  
The safest method is to replace the `bin\` contents as a matching set.

### 建議更新流程 / Recommended Update Workflow

1. 先停止目前正在跑的 server。  
   Stop the currently running server first.

```powershell
.\PS1\Start_LCPP.ps1 -Stop
```

2. 下載新的 `llama.cpp` Windows 版本，最好確認它和你目前的 CUDA 環境相符。  
   Download the new `llama.cpp` Windows build and make sure it matches your CUDA environment.

3. 保留目前整個資料夾當備份，不要立刻刪除。  
   Keep the current folder as a backup and do not delete it immediately.

4. 只替換 [`bin`](C:/Users/USER/llama%20win%20cuda%2013/bin) 裡面的二進位檔與 DLL。  
   Replace only the binaries and DLLs inside [`bin`](C:/Users/USER/llama%20win%20cuda%2013/bin).

5. 不要覆蓋這些你自己的檔案。  
   Do not overwrite these files that belong to your custom setup.

- [Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1)
- [Install_LCPP_Autostart.ps1](C:/Users/USER/llama%20win%20cuda%2013/Install_LCPP_Autostart.ps1)
- [Remove_LCPP_Autostart.ps1](C:/Users/USER/llama%20win%20cuda%2013/Remove_LCPP_Autostart.ps1)
- [README.md](C:/Users/USER/llama%20win%20cuda%2013/README.md)

6. 更新完成後重新啟動並驗證。  
   After the update, start the server again and verify it.

```powershell
.\PS1\Start_LCPP.ps1 -Background -NoBrowser -NoPause
.\PS1\Start_LCPP.ps1 -Status
```

7. 再打開 API 檢查模型列表是否正常。  
   Then open the API endpoint and confirm the model listing is normal.

```text
http://127.0.0.1:8080/v1/models
```

### 更保守的更新法 / Safer Staging Method

如果你想把風險降到最低，可以先把新版解壓到另一個臨時資料夾，再把裡面的二進位複製進目前的 `bin\`。  
If you want the safest path, unpack the new build into a temporary folder first, then copy its binaries into the current `bin\`.

這樣你可以先比對檔案，再決定要不要正式替換。  
This lets you compare files before committing to the replacement.

### 更新後要檢查什麼 / What To Check After Updating

更新完後，至少檢查這幾項：  
After updating, check at least these items:

1. `-Status` 能正常顯示 `Server`、`Model`、`PID`。  
   `-Status` should correctly show `Server`, `Model`, and `PID`.

2. [`/v1/models`](http://127.0.0.1:8080/v1/models) 能正常回傳 JSON。  
   [`/v1/models`](http://127.0.0.1:8080/v1/models) should return JSON normally.

3. 模型能實際載入，不會在啟動後立刻退出。  
   The model should actually load, and the server should not exit immediately after startup.

4. 如果你有開機自動啟動，重新開機或手動執行一次自動啟動任務確認它能正常工作。  
   If you use autostart, reboot or manually run the scheduled task once to confirm it still works.

### 如果更新失敗 / If The Update Fails

先查看這兩個 log：  
Check these two logs first:

- [logs/llama-server.stdout.log](C:/Users/USER/llama%20win%20cuda%2013/logs/llama-server.stdout.log)
- [logs/llama-server.stderr.log](C:/Users/USER/llama%20win%20cuda%2013/logs/llama-server.stderr.log)

也可以直接查看新版 `llama-server.exe` 的參數說明：  
You can also inspect the new `llama-server.exe` options directly:

```powershell
.\bin\llama-server.exe --help
```

有些新版 `llama.cpp` 可能會調整參數名稱、預設值或啟動行為。如果更新後出現錯誤，可能需要同步調整 [PS1/Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1)。  
Some new `llama.cpp` releases may change parameter names, defaults, or startup behavior. If the update breaks startup, [PS1/Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1) may need a matching adjustment.

### 回滾方式 / Rollback Method

如果新版有問題，最簡單的回滾方式是把舊版 `bin\` 備份內容放回來。  
If the new version causes issues, the simplest rollback is to restore your previous `bin\` backup.

回滾流程：  
Rollback steps:

1. 停掉目前 server。  
   Stop the current server.

```powershell
.\PS1\Start_LCPP.ps1 -Stop
```

2. 用舊版備份覆蓋 `bin\`。  
   Replace `bin\` with your previous backup.

3. 重新啟動並驗證。  
   Start again and verify.

```powershell
.\PS1\Start_LCPP.ps1 -Background -NoBrowser -NoPause
.\PS1\Start_LCPP.ps1 -Status
```

## 腳本會產生的檔案 / Files Created By The Script

- `logs/llama-server.pid`：記錄目前追蹤中的 process ID。  
  `logs/llama-server.pid`: Stores the currently tracked process ID.

- `logs/llama-server.stdout.log`：標準輸出 log。  
  `logs/llama-server.stdout.log`: Standard output log.

- `logs/llama-server.stderr.log`：錯誤輸出 log。  
  `logs/llama-server.stderr.log`: Error output log.

- `json/model-index.json`：互動式選單使用的模型索引。  
  `json/model-index.json`: Model index used by the interactive launcher.

- `json/model-tuning.json`：`-AutoTune` 學到的 per-model 調校資料。  
  `json/model-tuning.json`: Per-model tuning data learned by `-AutoTune`.

- `json/model-switch-times.json`：模型切換時間紀錄。  
  `json/model-switch-times.json`: Model switch timing history.

這些檔案會分別放在專案根目錄下的 `logs\` 與 `json\`。  
These files are created under the project's `logs\` and `json\` folders.

第一次執行 `Start.cmd` 或 `.\PS1\Start_LCPP.ps1` 時，腳本就會先初始化這三個 JSON。若當下已能掃到模型，`json/model-index.json` 會直接寫入模型清單；若還沒有可用模型，則會先建立空的初始檔。  
On the first `Start.cmd` or `.\PS1\Start_LCPP.ps1` run, the launcher initializes all three JSON files up front. If models are already discoverable, `json/model-index.json` is populated immediately; otherwise an empty starter file is created first.

## llama.cpp 指令速查表 / llama.cpp Command Quick Reference

以下內容以繁體中文為主，整理目前這台機器最常用的 `llama.cpp` 指令。  
The following section is a Traditional Chinese focused quick reference for the `llama.cpp` commands most relevant to this machine.

目前這台環境的重點：  
Current environment highlights:

- `llama.cpp` 版本：`8281 (0cec84f99)`
- GPU：`NVIDIA GeForce RTX 5070 Ti`
- VRAM：`16 GB`

### 先記住這 4 個主程式 / The 4 Main Executables

- `.\bin\llama-cli.exe`
  用命令列直接聊天、單次問答、測參數。  
  Use it for direct command-line chat, one-shot prompts, and parameter testing.

- `.\bin\llama-server.exe`
  開本機 API 與 Web UI。  
  Use it to launch the local API and Web UI.

- `.\bin\llama-quantize.exe`
  將高精度 GGUF 模型量化成較小版本。  
  Use it to quantize high-precision GGUF models into smaller versions.

- `.\bin\llama-server.exe --help`
  查這一版實際支援的參數。  
  Use it to view the parameters actually supported by this installed version.

### 1. `llama-cli.exe` 常用法 / Common `llama-cli.exe` Usage

最基本載入模型：  
Load a model with the default CLI behavior:

```powershell
.\bin\llama-cli.exe -m "C:\path\model.gguf"
```

聊天模式：  
Conversation mode:

```powershell
.\bin\llama-cli.exe -m "C:\path\model.gguf" -cnv
```

單次問答：  
One-shot prompt:

```powershell
.\bin\llama-cli.exe -m "C:\path\model.gguf" -p "用繁體中文介紹台北" -n 256
```

加上 system prompt：  
Add a system prompt:

```powershell
.\bin\llama-cli.exe -m "C:\path\model.gguf" -cnv -sys "你是專業中文助理"
```

直接從 Hugging Face 下載執行：  
Download and run directly from Hugging Face:

```powershell
.\bin\llama-cli.exe -hf ggml-org/gemma-3-1b-it-GGUF
```

### 2. `llama-cli.exe` 常用參數 / Common `llama-cli.exe` Parameters

- `-m`
  指定本機 GGUF 模型路徑。  
  Specifies a local GGUF model path.

- `-hf <repo[:quant]>`
  從 Hugging Face 下載模型。  
  Downloads a model from Hugging Face.

- `-p`
  指定 prompt。  
  Sets the prompt text.

- `-sys`
  指定 system prompt。  
  Sets the system prompt.

- `-cnv`
  啟用聊天模式。  
  Enables conversation mode.

- `--chat-template NAME`
  指定聊天模板，例如 `chatml`。  
  Sets a chat template, such as `chatml`.

- `-c`
  指定 context size，例如 `4096`、`8192`。  
  Sets the context size, for example `4096` or `8192`.

- `-n`
  指定最多生成幾個 token。`-1` 代表不限。  
  Sets the maximum number of generated tokens. `-1` means unlimited.

- `-t`
  指定 CPU threads 數量。  
  Sets the number of CPU threads.

- `-ngl` 或 `--gpu-layers`
  控制多少層放到 GPU，可用值通常是 `auto`、`all` 或數字。  
  Controls how many layers are offloaded to GPU. Common values are `auto`, `all`, or a number.

- `--temp`
  溫度，常見值 `0.2` 到 `1.0`。  
  Temperature, commonly between `0.2` and `1.0`.

- `--top-k`
  Top-k sampling，常見值如 `40`。  
  Top-k sampling, commonly `40`.

- `--top-p`
  Top-p sampling，常見值如 `0.9`、`0.95`。  
  Top-p sampling, commonly `0.9` or `0.95`.

- `--min-p`
  Min-p sampling。  
  Min-p sampling.

- `--grammar-file`
  用 grammar 限制輸出格式。  
  Uses a grammar file to constrain output.

- `-j` 或 `--json-schema`
  用 JSON Schema 限制輸出格式。  
  Uses JSON Schema to constrain output.

### 3. `llama-server.exe` 常用法 / Common `llama-server.exe` Usage

最基本開本機 API：  
Start the local API server:

```powershell
.\bin\llama-server.exe -m "C:\path\model.gguf" --port 8080 --gpu-layers auto
```

依你目前這台的模型路徑，實際可用：  
For your current machine and model path, you can use:

```powershell
.\bin\llama-server.exe -m "C:\Users\USER\Downloads\LLM\Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-v2.gguf" --port 8080 --gpu-layers auto
```

### 4. `llama-server.exe` 常用參數 / Common `llama-server.exe` Parameters

- `-m`
  模型路徑。  
  Model path.

- `--host`
  綁定的主機位址，預設通常是 `127.0.0.1`。  
  Host address to bind to, commonly `127.0.0.1`.

- `--port`
  服務埠號，例如 `8080`。  
  Service port, such as `8080`.

- `-c`
  Context size。  
  Context size.

- `-np`
  平行 slot 數量。  
  Number of parallel slots.

- `-cb` / `--cont-batching`
  啟用 continuous batching，通常預設就有開。  
  Enables continuous batching, usually on by default.

- `--embedding`
  只提供 embedding 服務。  
  Restricts the server to embedding use.

- `--rerank`
  啟用 reranking endpoint。  
  Enables the reranking endpoint.

- `--api-key`
  設定 API key。  
  Sets an API key.

- `--metrics`
  啟用 metrics endpoint。  
  Enables the metrics endpoint.

- `--webui`
  啟用內建 Web UI。  
  Enables the built-in Web UI.

### 4A. `llama-server.exe` 常用參數中文版對照表 / Chinese Reference Table For Common `llama-server.exe` Options

如果你是透過 [Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1) 啟動，請先記住這件事：  
If you launch through [Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1), remember this first:

- `--model`
- `--port`
- `--gpu-layers`
- `--threads`
- `--threads-batch`

以上這幾個建議用腳本自己的參數設定，不要從後面直傳。  
These should be configured through the wrapper script parameters, not forwarded as trailing arguments.

完整參數仍以這台已安裝版本的實際輸出為準：  
The complete parameter list still comes from the actual installed version on this machine:

```powershell
.\PS1\Start_LCPP.ps1 -LlamaHelp
```

下面這份是常見、實用、最值得記住的中文版對照：  
Below is a practical Traditional Chinese reference for the most useful options.

| 參數 | 類型 | 用途 | 常見值或範例 |
| --- | --- | --- | --- |
| `-m, --model FNAME` | 路徑 | 指定 GGUF 模型路徑 | `-m "C:\Models\a.gguf"` |
| `--host HOST` | 字串 | 指定綁定位址 | `127.0.0.1`, `0.0.0.0` |
| `--port PORT` | 整數 | 指定服務埠號 | `8080`, `8081` |
| `-c, --ctx-size N` | 整數 | 指定 context size | `4096`, `8192` |
| `-n, --predict N` | 整數 | 指定最多生成 token 數 | `256`, `512`, `-1` |
| `-t, --threads N` | 整數 | 指定生成階段 CPU threads | `8`, `12`, `-1` |
| `-tb, --threads-batch N` | 整數 | 指定 batch/prefill CPU threads | `8`, `16`, `-1` |
| `-ngl, --gpu-layers N` | `auto`、`all`、數字 | 控制放進 GPU 的層數 | `auto`, `all`, `35` |
| `-dev, --device <dev1,dev2,..>` | 字串 | 指定要用哪個裝置 | `CUDA0` |
| `-mg, --main-gpu INDEX` | 整數 | 指定主 GPU | `0` |
| `-fa, --flash-attn [on\|off\|auto]` | 列舉 | 控制 Flash Attention | `auto`, `on`, `off` |
| `-fit, --fit [on\|off]` | 列舉 | 自動調整未指定參數以塞進 VRAM | `on`, `off` |
| `-fitc, --fit-ctx N` | 整數 | `--fit` 可調整時的最小 context | `4096` |
| `-ctk, --cache-type-k TYPE` | 列舉 | 設定 KV cache 的 K 型別 | `f16`, `q8_0`, `q4_0` |
| `-ctv, --cache-type-v TYPE` | 列舉 | 設定 KV cache 的 V 型別 | `f16`, `q8_0`, `q4_0` |
| `--mmap`, `--no-mmap` | 開關 | 控制是否 memory-map 模型 | 預設通常開啟 |
| `--mlock` | 開關 | 盡量把模型留在 RAM，不讓系統換出 | 視 RAM 是否足夠 |
| `-np, --parallel N` | 整數 | server slot 數量，可同時處理多請求 | `1`, `2`, `4` |
| `-cb, --cont-batching` | 開關 | 啟用 continuous batching | 預設通常開啟 |
| `--threads-http N` | 整數 | HTTP request 處理執行緒數 | `-1`, `4` |
| `--api-key KEY` | 字串 | 設定 API 金鑰驗證 | `my-secret-key` |
| `--metrics` | 開關 | 啟用 Prometheus metrics endpoint | `--metrics` |
| `--props` | 開關 | 啟用 `POST /props` | 進階用途 |
| `--slots`, `--no-slots` | 開關 | 是否暴露 slots 監控端點 | 預設通常開啟 |
| `--slot-save-path PATH` | 路徑 | 設定 slot KV cache 儲存路徑 | `.\slots` |
| `--path PATH` | 路徑 | 指定靜態檔案目錄 | `.\www` |
| `--api-prefix PREFIX` | 字串 | 幫整個 API 加前綴 | `/llm` |
| `--webui`, `--no-webui` | 開關 | 控制內建 Web UI | 預設通常開啟 |
| `--embedding` | 開關 | 只開 embedding 功能 | `--embedding` |
| `--rerank`, `--reranking` | 開關 | 啟用 rerank endpoint | `--rerank` |
| `--chat-template NAME` | 字串 | 指定聊天模板 | `chatml`, `llama3`, `deepseek` |
| `--reasoning-format FORMAT` | 列舉 | 控制 reasoning/thinking 欄位格式 | `none`, `deepseek`, `deepseek-legacy` |
| `--reasoning-budget N` | 整數 | 控制 thinking 額度 | `-1`, `0` |
| `-to, --timeout N` | 整數 | HTTP 讀寫逾時秒數 | `600` |
| `--list-devices` | 開關 | 列出可用裝置並退出 | `--list-devices` |
| `--version` | 開關 | 顯示版本資訊 | `--version` |
| `-h, --help` | 開關 | 顯示說明 | `--help` |

#### 常見直傳範例 / Common Forwarded Examples

透過腳本把 `ctx-size` 和 metrics 轉交給 `llama-server.exe`：  
Forward `ctx-size` and metrics through the wrapper:

```powershell
.\PS1\Start_LCPP.ps1 -Background --ctx-size 4096 --metrics
```

加上 API key：  
Add an API key:

```powershell
.\PS1\Start_LCPP.ps1 -Background --ctx-size 4096 --api-key my-secret-key --metrics
```

綁到區網位址讓其他裝置可連線：  
Bind to the LAN so other devices can connect:

```powershell
.\PS1\Start_LCPP.ps1 -Background --host 0.0.0.0 --ctx-size 4096 --api-key my-secret-key
```

#### 注意事項 / Notes

- `--host 0.0.0.0` 代表不只本機可以連線，請務必搭配 `--api-key`，並只在可信任網路使用。  
  `--host 0.0.0.0` exposes the server beyond localhost. Use it with `--api-key` and only on trusted networks.

- `--fit on` 對顯存較小的 GPU 很有幫助，但不是萬能；模型太大時仍可能載不動。  
  `--fit on` is helpful for smaller VRAM GPUs, but it cannot make an oversized model fit in every case.

- 如果你只是日常使用，最實用的額外參數通常是 `--ctx-size`、`--metrics`、`--api-key`、`--host`。  
  For everyday usage, the most useful extra forwarded options are usually `--ctx-size`, `--metrics`, `--api-key`, and `--host`.

### 4B. 雙 GPU 搬機設定範本 / Dual GPU Migration Templates

如果之後把這整包搬到另一台雙顯示卡電腦，最常需要調整的是：  
If you move this package to another computer with two GPUs, the most common settings you will need to adjust are:

- `-ModelPath`
- `-GpuLayers`
- `-Threads`
- `-ThreadsBatch`
- `--device`
- `--split-mode`
- `--tensor-split`
- `--ctx-size`
- `--fit`
- `--fit-target`

第一步先確認新電腦能看到哪些裝置：  
First, check which devices are visible on the new computer:

```powershell
.\bin\llama-server.exe --list-devices
```

如果有看到像 `CUDA0`、`CUDA1`，表示這包可以辨識兩張 CUDA 顯卡。  
If you see entries such as `CUDA0` and `CUDA1`, this package can detect both CUDA GPUs.

#### 範本 1：先求穩定的雙 GPU 起始設定 / Template 1: Safe Starting Point For Dual GPU

適合剛搬機時先確認能不能正常啟動。  
Use this first after migration to confirm the server starts cleanly.

```powershell
.\PS1\Start_LCPP.ps1 `
  -Background `
  -ModelPath "D:\Models\your-model.gguf" `
  -GpuLayers auto `
  --device CUDA0,CUDA1 `
  --split-mode layer `
  --ctx-size 4096 `
  --fit on
```

說明：  
Notes:

- `-GpuLayers auto` 先讓程式自動決定 offload 層數。  
  `-GpuLayers auto` lets the program decide the offload depth first.

- `--split-mode layer` 是雙 GPU 最常見的起手式。  
  `--split-mode layer` is the most common dual GPU starting mode.

- `--fit on` 對剛搬到新硬體時很有幫助。  
  `--fit on` is very useful when moving to new hardware.

#### 範本 2：兩張卡顯存接近時 / Template 2: When Both GPUs Have Similar VRAM

適合兩張卡規格接近，例如 `12 GB + 12 GB`。  
Use this when both GPUs are similar, for example `12 GB + 12 GB`.

```powershell
.\PS1\Start_LCPP.ps1 `
  -Background `
  -ModelPath "D:\Models\your-model.gguf" `
  -GpuLayers all `
  --device CUDA0,CUDA1 `
  --split-mode layer `
  --tensor-split 1,1 `
  --ctx-size 8192 `
  --fit on
```

說明：  
Notes:

- `--tensor-split 1,1` 代表大致平均分配。  
  `--tensor-split 1,1` means an approximately even split.

- 如果啟動失敗，可以先退回 `-GpuLayers auto` 或把 `--ctx-size` 降回 `4096`。  
  If startup fails, first fall back to `-GpuLayers auto` or reduce `--ctx-size` back to `4096`.

#### 範本 3：兩張卡顯存不同時 / Template 3: When The GPUs Have Different VRAM Sizes

適合像 `12 GB + 8 GB`、`24 GB + 12 GB` 這種組合。  
Use this for mixed setups such as `12 GB + 8 GB` or `24 GB + 12 GB`.

```powershell
.\PS1\Start_LCPP.ps1 `
  -Background `
  -ModelPath "D:\Models\your-model.gguf" `
  -GpuLayers all `
  --device CUDA0,CUDA1 `
  --split-mode layer `
  --tensor-split 3,2 `
  --ctx-size 8192 `
  --fit on
```

說明：  
Notes:

- `--tensor-split 3,2` 只是示例，意思是依顯存大小做比例分配。  
  `--tensor-split 3,2` is only an example and represents a proportional split based on VRAM size.

- 如果是 `24 GB + 12 GB`，可以先試 `2,1`。  
  For `24 GB + 12 GB`, a good first try is `2,1`.

- 如果是 `16 GB + 8 GB`，可以先試 `2,1`。  
  For `16 GB + 8 GB`, you can also start with `2,1`.

#### 範本 4：要讓區網其他設備連線時 / Template 4: For LAN Access

如果新電腦是要當家中或辦公室共用主機，可用下面這種方式。  
If the new computer will serve as a shared host on your home or office network, use a setup like this.

```powershell
.\PS1\Start_LCPP.ps1 `
  -Background `
  -ModelPath "D:\Models\your-model.gguf" `
  -GpuLayers auto `
  --device CUDA0,CUDA1 `
  --split-mode layer `
  --ctx-size 4096 `
  --fit on `
  --host 0.0.0.0 `
  --api-key your-secret-key `
  --metrics
```

注意：  
Notes:

- 不要把 `0.0.0.0` 裸露在不可信任網路上。  
  Do not expose `0.0.0.0` on untrusted networks.

- 開放區網存取時，建議一定要搭配 `--api-key`。  
  When exposing the server to the LAN, it is strongly recommended to use `--api-key`.

#### 搬機後建議調整順序 / Recommended Tuning Order After Migration

1. 先跑 `.\bin\llama-server.exe --list-devices`
2. 先用 `-GpuLayers auto`
3. 再加上 `--device CUDA0,CUDA1`
4. 再加上 `--split-mode layer`
5. 成功啟動後再提高 `--ctx-size`
6. 最後才微調 `--tensor-split`

1. Run `.\bin\llama-server.exe --list-devices`
2. Start with `-GpuLayers auto`
3. Then add `--device CUDA0,CUDA1`
4. Then add `--split-mode layer`
5. Raise `--ctx-size` only after successful startup
6. Tune `--tensor-split` last

### 5. 用 API 測試 `llama-server` / Testing `llama-server` With The API

查目前載入模型：  
Check the currently loaded model:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/v1/models
```

用 PowerShell 呼叫 chat completions：  
Call chat completions from PowerShell:

```powershell
$body = @{
  model = "Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-v2.gguf"
  messages = @(
    @{ role = "user"; content = "請用繁體中文自我介紹" }
  )
  temperature = 0.7
} | ConvertTo-Json -Depth 6

Invoke-RestMethod `
  -Uri "http://127.0.0.1:8080/v1/chat/completions" `
  -Method Post `
  -ContentType "application/json" `
  -Body $body
```

### 6. `llama-quantize.exe` 常用法 / Common `llama-quantize.exe` Usage

基本語法：  
Basic syntax:

```powershell
.\bin\llama-quantize.exe input-f16.gguf output.gguf Q4_K_M 8
```

範例：  
Example:

```powershell
.\bin\llama-quantize.exe model-f16.gguf model-q4km.gguf Q4_K_M 8
```

常見量化類型：  
Common quantization types:

- `Q4_K_M`
  常見平衡點，速度、大小、品質通常較均衡。  
  A common balance point for speed, size, and quality.

- `Q5_K_M`
  品質較高，但檔案也更大。  
  Higher quality, but larger file size.

- `Q8_0`
  更接近高精度，但資源需求更高。  
  Closer to high precision, but requires more resources.

- `F16` / `BF16`
  高精度格式。  
  High precision formats.

- `COPY`
  不量化，只做複製或格式處理。  
  No quantization, only copying or format handling.

注意：  
Notes:

- 最好從 `F16`、`BF16` 或 `F32` 來源量化。  
  It is best to quantize from `F16`, `BF16`, or `F32`.

- 不建議從已量化模型再反覆量化。  
  Re-quantizing an already quantized model is generally not recommended.

### 7. 結構化輸出 / Structured Output

用 JSON Schema 限制輸出：  
Constrain output with JSON Schema:

```powershell
.\bin\llama-cli.exe -m "C:\path\model.gguf" -p "輸出一個人物 JSON" -j "{ \"type\": \"object\" }"
```

用 grammar 限制輸出：  
Constrain output with a grammar:

```powershell
.\bin\llama-cli.exe -m "C:\path\model.gguf" --grammar-file ".\grammars\json.gbnf" -p "輸出 JSON"
```

### 8. 依這台機器的建議 / Recommendations For This Machine

因為這台是 RTX 5070 Ti，VRAM 為 16 GB，建議先這樣用：  
Because this machine uses an RTX 5070 Ti with 16 GB VRAM, start with these recommendations:

- `--gpu-layers auto`
  先讓程式自動決定，不要一開始就用 `all`。  
  Let the program decide automatically instead of forcing `all` at the beginning.

- `-c 8192`
  大模型可以先從中等 context size 開始；如果還想往上推，再視 VRAM 使用量增加。  
  For larger models, start with a moderate context size and increase it later based on actual VRAM usage.

- CPU threads 不確定時，先讓目前腳本自動處理。  
  If you are unsure about CPU threads, let the current launcher script choose them automatically first.

- 平常要穩定開 API，優先使用 [Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1)。  
  For stable day-to-day API serving, prefer [Start_LCPP.ps1](C:/Users/USER/llama%20win%20cuda%2013/PS1/Start_LCPP.ps1).

### 9. 最常用速查 / Most Useful Quick Commands

```powershell
.\bin\llama-cli.exe --help
.\bin\llama-server.exe --help
.\bin\llama-server.exe --version
.\bin\llama-server.exe --list-devices
.\bin\llama-server.exe -m "C:\path\model.gguf" --port 8080 --gpu-layers auto
.\bin\llama-cli.exe -m "C:\path\model.gguf" -cnv
.\bin\llama-quantize.exe input-f16.gguf output.gguf Q4_K_M 8
```

### 10. 官方參考 / Official References

- [llama.cpp README](https://github.com/ggml-org/llama.cpp#quick-start)
- [llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [GBNF Guide](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md)
- [llama-quantize README](https://github.com/ggml-org/llama.cpp/blob/master/tools/quantize/README.md)

