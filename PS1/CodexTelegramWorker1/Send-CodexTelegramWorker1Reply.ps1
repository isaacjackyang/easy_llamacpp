[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ChatId,
  [Parameter(Mandatory = $true)][string]$Text,
  [int]$ReplyToMessageId = 0,
  [string]$TokenFile = "$env:USERPROFILE\.openclaw\credentials\telegram-worker1-token.txt",
  [string]$LogPath = "F:\Documents\GitHub\easy_llamacpp\.codex-telegram-worker1\sent.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $TokenFile)) {
  throw "Cannot find Telegram worker1 token file: $TokenFile"
}

$token = (Get-Content -LiteralPath $TokenFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
  throw "Telegram worker1 token file is empty: $TokenFile"
}

$body = @{
  chat_id = $ChatId
  text = $Text
  disable_web_page_preview = $true
}

if ($ReplyToMessageId -gt 0) {
  $body.reply_to_message_id = $ReplyToMessageId
}

$response = Invoke-RestMethod `
  -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) `
  -Method Post `
  -ContentType "application/json; charset=utf-8" `
  -Body ($body | ConvertTo-Json -Depth 5)

if (-not $response.ok) {
  throw "Telegram sendMessage failed."
}

$logDir = Split-Path -Parent $LogPath
if (-not [string]::IsNullOrWhiteSpace($logDir)) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

[ordered]@{
  sentAt = (Get-Date).ToString("o")
  chatId = $ChatId
  replyToMessageId = $ReplyToMessageId
  chars = $Text.Length
} | ConvertTo-Json -Compress | Add-Content -LiteralPath $LogPath -Encoding utf8

Write-Host "Telegram worker1 reply sent."
