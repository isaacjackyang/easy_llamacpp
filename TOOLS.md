# TOOLS

## STT / TTS 調用說明

這個專案裡的 TTS 和 STT 不是由 `Start.cmd` 單獨管理，而是跟 OpenClaw gateway 一起啟動。正常情況下，請先把 OpenClaw 啟動起來，再去呼叫 TTS / STT HTTP 介面。

### 啟動方式

推薦用下面任一種方式啟動：

```powershell
.\start_openclaw.cmd
```

或：

```powershell
powershell -ExecutionPolicy Bypass -File .\PS1\Start_OpenClaw.ps1
```

如果你是從主選單走完整流程，也可以用：

```text
Start.cmd -> Quick Start And OpenClaw
```

補充：

- `start_openclaw.cmd` 會呼叫 `PS1\Start_OpenClaw.ps1`
- OpenClaw gateway 會一起管理 TTS / STT sidecars
- TTS 預設監聽 `127.0.0.1:8000`
- STT 預設監聽 `127.0.0.1:8001`
- 如果 llama.cpp 模型切換了，想同步到 OpenClaw，可執行：

```powershell
.\update_openclaw_sataus.cmd -RestartOpenClaw
```

### 健康檢查

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health
Invoke-RestMethod http://127.0.0.1:8001/health
```

TTS `/health` 會回傳目前模型、預設 speaker、speaker 數量與 port。  
STT `/health` 會回傳目前模型、裝置、預設語言與 port。

## TTS

### 服務資訊

- 位址：`http://127.0.0.1:8000`
- 預設 speaker：`Zhifeng Female`
- 預設 language：`zh`
- 回應格式：`audio/wav`

### 呼叫方式

TTS 支援兩種呼叫方式：

1. `GET /?text=...&speaker=...&language=...`
2. `POST /`，Body 為 JSON

最常用的欄位如下：

- `text`: 要合成的文字
- `speaker`: 可省略，未填時使用 `Zhifeng Female`
- `language`: 可省略，未填時使用 `zh`

### PowerShell 範例

GET 方式：

```powershell
$text = [uri]::EscapeDataString("你好，這是一段測試語音。")
Invoke-WebRequest `
  -Uri "http://127.0.0.1:8000/?text=$text&speaker=Zhifeng%20Female&language=zh" `
  -OutFile ".\tts-output.wav"
```

POST 方式：

```powershell
$body = @{
  text = "你好，這是一段測試語音。"
  speaker = "Zhifeng Female"
  language = "zh"
} | ConvertTo-Json

Invoke-WebRequest `
  -Uri "http://127.0.0.1:8000/" `
  -Method Post `
  -ContentType "application/json; charset=utf-8" `
  -Body $body `
  -OutFile ".\tts-output.wav"
```

### curl.exe 範例

```powershell
curl.exe "http://127.0.0.1:8000/?text=%E4%BD%A0%E5%A5%BD&speaker=Zhifeng%20Female&language=zh" --output tts-output.wav
```

```powershell
curl.exe -X POST "http://127.0.0.1:8000/" ^
  -H "Content-Type: application/json" ^
  -d "{\"text\":\"你好，這是一段測試語音。\",\"speaker\":\"Zhifeng Female\",\"language\":\"zh\"}" ^
  --output tts-output.wav
```

### 失敗時常見回應

- `400 {"error":"No text provided"}`
- `500 {"error":"..."}` 代表模型合成過程出錯

## STT

### 服務資訊

- 位址：`http://127.0.0.1:8001`
- 預設 language：`zh`
- 主要端點：`POST /transcribe`
- 也接受：`POST /`
- 回應格式：JSON

### 重要限制

STT 不是上傳音檔內容，而是傳「本機音檔路徑」給服務端讀取。  
也就是說，`audioPath` 必須是這台 Windows 機器上真的存在的檔案路徑。

最常用的欄位如下：

- `audioPath`: 音檔完整路徑
- `language`: 可省略，未填時等同 `zh`

另外也接受這幾個別名：

- `audio_file`
- `path`

語言可用 `zh`、`zh-tw`、`en`、`ja`、`ko`、`yue` 等簡寫；服務端會自動轉成模型需要的語言名稱。

### PowerShell 範例

```powershell
$body = @{
  audioPath = "C:\Temp\sample.wav"
  language = "zh"
} | ConvertTo-Json

Invoke-RestMethod `
  -Uri "http://127.0.0.1:8001/transcribe" `
  -Method Post `
  -ContentType "application/json; charset=utf-8" `
  -Body $body
```

預期回傳類似：

```json
{
  "text": "這是辨識出來的文字",
  "language": "Chinese",
  "requestedLanguage": "Chinese",
  "model": "Qwen/Qwen3-ASR-1.7B",
  "device": "cpu"
}
```

### curl.exe 範例

```powershell
curl.exe -X POST "http://127.0.0.1:8001/transcribe" ^
  -H "Content-Type: application/json" ^
  -d "{\"audioPath\":\"C:\\\\Temp\\\\sample.wav\",\"language\":\"zh\"}"
```

### 失敗時常見回應

- `400 {"error":"No audioPath provided"}`
- `404 {"error":"Audio file not found: ..."}`
- `500 {"error":"..."}` 代表辨識過程出錯

## 排錯

### 先確認服務有起來

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health
Invoke-RestMethod http://127.0.0.1:8001/health
```

### 如果 health 沒回應

1. 先重新啟動 OpenClaw：

```powershell
.\start_openclaw.cmd
```

2. 若剛切過 llama.cpp 模型，執行：

```powershell
.\update_openclaw_sataus.cmd -RestartOpenClaw
```

3. 檢查 OpenClaw 日誌：

```text
C:\Users\<你的使用者>\.openclaw\logs\
```

### 停用自動啟動

如果只是暫時不想讓背景服務和自啟繼續跑，可以用：

```powershell
.\stop_auto_service.cmd
```
