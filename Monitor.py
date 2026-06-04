#!/usr/bin/env python
"""Single-file Windows GUI for monitoring local PYTHON THINKER services."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import threading
import urllib.error
import urllib.request
import webbrowser
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import tkinter as tk
from tkinter import ttk


USER_HOME = Path(os.environ.get("USERPROFILE", str(Path.home())))
HERMES_HOME = USER_HOME / "AppData" / "Local" / "hermes"
PROJECT_ROOT = Path(__file__).resolve().parent
EASY_LOGS = PROJECT_ROOT / "logs"
JSON_ROOT = PROJECT_ROOT / "json"
MONITOR_LAYOUT_FILE = JSON_ROOT / "monitor-layout.json"
DEFAULT_REFRESH_MS = 5000
DEFAULT_TIMEOUT = 2.0
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
POWERSHELL_EXE = str(
    Path(os.environ.get("SystemRoot", r"C:\Windows"))
    / "System32"
    / "WindowsPowerShell"
    / "v1.0"
    / "powershell.exe"
)
CMD_EXE = os.environ.get("ComSpec", r"C:\Windows\System32\cmd.exe")
HERMES_EXE = HERMES_HOME / "hermes-agent" / "venv" / "Scripts" / "hermes.exe"
HERMES_GATEWAY_CMD = HERMES_HOME / "gateway-service" / "Hermes_Gateway.cmd"
DEFAULT_CARD_ORDER = ["llama", "watchdog", "dashboard", "gateway", "hermes", "tts", "asr"]


@dataclass
class ServiceStatus:
    key: str
    title_zh: str
    title_en: str
    state: str
    summary_zh: str
    summary_en: str
    compact_details: list[str] = field(default_factory=list)
    details: list[str] = field(default_factory=list)
    updated_at: str = ""


def bi(zh: str, en: str) -> str:
    return f"{zh}\n{en}"


def choose_text(zh: str, en: str, language: str) -> str:
    if language == "zh":
        return zh
    if language == "en":
        return en
    if zh == en:
        return zh
    return bi(zh, en)


def choose_bilingual_value(value: str, language: str) -> str:
    parts = str(value).splitlines()
    if len(parts) >= 2:
        return choose_text(parts[0], parts[1], language)
    return str(value)


def is_command_detail(value: str) -> bool:
    return str(value).startswith(("命令列:", "Command:"))


def iso_now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def decode_bytes(value: bytes) -> str:
    for encoding in ("utf-8", "cp950", "utf-8-sig", "utf-16-le", sys.getdefaultencoding()):
        try:
            return value.decode(encoding)
        except UnicodeDecodeError:
            continue
    return value.decode("utf-8", errors="replace")


def read_json_file(path: Path) -> Any:
    for encoding in ("utf-8", "utf-8-sig"):
        try:
            return json.loads(path.read_text(encoding=encoding))
        except OSError:
            return None
        except json.JSONDecodeError:
            continue
    return None


def read_text_tail(path: Path, max_lines: int = 20) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()[-max_lines:]
    except OSError:
        return []


def basename(value: str) -> str:
    return Path(value).name if value else "-"


def format_ts(value: Any) -> str:
    if value in (None, "", 0):
        return "-"
    try:
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value).strftime("%Y-%m-%d %H:%M:%S")
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return str(value)


def detail(label_zh: str, value_zh: str, label_en: str | None = None, value_en: str | None = None) -> str:
    actual_label_en = label_en or label_zh
    actual_value_en = value_en if value_en is not None else value_zh
    return bi(f"{label_zh}: {value_zh}", f"{actual_label_en}: {actual_value_en}")


def run_powershell_json(command: str) -> list[dict[str, Any]]:
    try:
        result = subprocess.run(
            [POWERSHELL_EXE, "-NoProfile", "-Command", command],
            capture_output=True,
            text=False,
            timeout=20,
            check=False,
            creationflags=CREATE_NO_WINDOW,
        )
    except OSError:
        return []

    if result.returncode != 0:
        return []

    payload = decode_bytes(result.stdout).strip()
    if not payload:
        return []

    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return []

    if isinstance(data, dict):
        return [data]
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


def get_process_rows() -> list[dict[str, Any]]:
    command = (
        "@(Get-CimInstance Win32_Process "
        "| Where-Object { $_.Name -in @('python.exe','pythonw.exe','hermes.exe','llama-server.exe','powershell.exe') } "
        "| Select-Object ProcessId, ParentProcessId, Name, CommandLine, ExecutablePath) | ConvertTo-Json -Compress"
    )
    return run_powershell_json(command)


def get_listener_rows() -> list[dict[str, Any]]:
    command = (
        "@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue "
        "| Where-Object { $_.LocalPort -in @(8080,9119,7101,7201) } "
        "| Select-Object LocalAddress, LocalPort, OwningProcess, State) | ConvertTo-Json -Compress"
    )
    return run_powershell_json(command)


def process_by_pid(process_rows: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    output: dict[int, dict[str, Any]] = {}
    for row in process_rows:
        pid = row.get("ProcessId")
        if isinstance(pid, int):
            output[pid] = row
    return output


def listeners_by_port(listener_rows: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    output: dict[int, dict[str, Any]] = {}
    for row in listener_rows:
        port = row.get("LocalPort")
        if isinstance(port, int):
            output[port] = row
    return output


def find_processes(process_rows: list[dict[str, Any]], *patterns: str) -> list[dict[str, Any]]:
    lowered = [pattern.lower() for pattern in patterns if pattern]
    matches: list[dict[str, Any]] = []
    for row in process_rows:
        cmd = str(row.get("CommandLine") or "").lower()
        if all(pattern in cmd for pattern in lowered):
            matches.append(row)
    return matches


def http_probe(url: str, timeout: float = DEFAULT_TIMEOUT) -> str:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        return f"HTTP {exc.code}"
    except Exception as exc:
        return f"ERR {exc.__class__.__name__}"


def tcp_probe(host: str, port: int, timeout: float = DEFAULT_TIMEOUT) -> str:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return "TCP OK"
    except Exception as exc:
        return f"ERR {exc.__class__.__name__}"


def extract_flag(args: list[str], name: str) -> str:
    try:
        index = args.index(name)
    except ValueError:
        return ""
    return str(args[index + 1]) if index + 1 < len(args) else ""


def summarize_platforms(platforms: dict[str, Any]) -> tuple[str, str]:
    zh_parts = []
    en_parts = []
    for key, value in sorted(platforms.items()):
        if not isinstance(value, dict):
            continue
        state = str(value.get("state", "?"))
        zh_parts.append(f"{key}={state}")
        en_parts.append(f"{key}={state}")
    return (", ".join(zh_parts) if zh_parts else "-", ", ".join(en_parts) if en_parts else "-")


def parse_llama_activity(stderr_lines: list[str]) -> tuple[str, str]:
    for line in reversed(stderr_lines):
        if "slot print_timing" in line:
            match = re.search(r"task\s+(\d+).+n_decoded =\s+(\d+)", line)
            if match:
                return (
                    f"正在解碼 task {match.group(1)}，已產生 {match.group(2)} tokens",
                    f"Currently decoding task {match.group(1)} with {match.group(2)} tokens decoded",
                )
            return ("stderr 顯示目前仍有解碼活動", "stderr shows active decoding")
        if "request cancelled" in line:
            return ("最近有請求被取消或逾時", "Recent client timeout or cancellation detected")
        if "server is listening" in line:
            return ("最近狀態顯示服務已開始監聽", "Recent state shows the server is listening")
    return ("最近沒有明顯活動", "No obvious recent activity")


def check_llama(process_rows: list[dict[str, Any]], listener_rows: list[dict[str, Any]]) -> ServiceStatus:
    owner = read_json_file(EASY_LOGS / "llama-runtime-owner.json") or {}
    by_pid = process_by_pid(process_rows)
    by_port = listeners_by_port(listener_rows)
    port_row = by_port.get(8080)
    server_pid = owner.get("server_pid") if isinstance(owner, dict) else None
    proc = by_pid.get(server_pid) if isinstance(server_pid, int) else None
    stderr_lines = read_text_tail(EASY_LOGS / "llama-server.stderr.log", max_lines=25)
    activity_zh, activity_en = parse_llama_activity(stderr_lines)
    probe = http_probe("http://127.0.0.1:8080/v1/models")

    model_path = str(owner.get("model_path") or "")
    mmproj_path = str(owner.get("mmproj_path") or "")
    args = owner.get("server_args") if isinstance(owner.get("server_args"), list) else []
    ctx_size = extract_flag([str(item) for item in args], "--ctx-size")

    if port_row and probe.startswith("HTTP"):
        state = "ok"
        summary_zh = f"8080 正在服務，模型是 {basename(model_path)}"
        summary_en = f"Listening on 8080 with model {basename(model_path)}"
    elif port_row or proc:
        state = "warn"
        summary_zh = "程序存在，但 API 尚未完全就緒"
        summary_en = "Process exists but API readiness is incomplete"
    else:
        state = "down"
        summary_zh = "本機 8080 沒有偵測到 llama.cpp listener"
        summary_en = "No local llama.cpp listener on 8080"

    compact = [
        detail("PID", str(server_pid or "-"), "PID"),
        detail("模型", basename(model_path), "Model", basename(model_path)),
        detail("API 探測", probe, "API probe", probe),
        detail("活動", activity_zh, "Activity", activity_en),
    ]
    details = compact + [
        detail("Mmproj", basename(mmproj_path) if mmproj_path else "none", "Mmproj", basename(mmproj_path) if mmproj_path else "none"),
        detail("上下文", ctx_size or "-", "Context", ctx_size or "-"),
    ]
    if proc:
        details.append(detail("命令列", str(proc.get("CommandLine", "-")), "Command", str(proc.get("CommandLine", "-"))))

    return ServiceStatus(
        key="llama",
        title_zh="llama.cpp 服務",
        title_en="llama.cpp Service",
        state=state,
        summary_zh=summary_zh,
        summary_en=summary_en,
        compact_details=compact,
        details=details,
        updated_at=iso_now(),
    )


def check_watchdog(process_rows: list[dict[str, Any]]) -> ServiceStatus:
    owner = read_json_file(EASY_LOGS / "llama-runtime-owner.json") or {}
    by_pid = process_by_pid(process_rows)
    watchdog_pid = owner.get("watchdog_pid") if isinstance(owner, dict) else None
    server_pid = owner.get("server_pid") if isinstance(owner, dict) else None
    proc = by_pid.get(watchdog_pid) if isinstance(watchdog_pid, int) else None
    runtime_status = str(owner.get("status") or "unknown") if isinstance(owner, dict) else "unknown"
    restart_count = owner.get("restart_count", 0) if isinstance(owner, dict) else 0
    last_restart_at = format_ts(owner.get("last_restart_at")) if isinstance(owner, dict) else "-"
    last_exit_code = str(owner.get("last_exit_code", "-")) if isinstance(owner, dict) else "-"

    if proc:
        state = "ok"
        summary_zh = "統一 watchdog 正在守護 llama.cpp，已啟用自動恢復"
        summary_en = "Unified watchdog is supervising llama.cpp with auto-recovery enabled"
    elif owner:
        state = "warn"
        summary_zh = f"watchdog 有狀態檔，但目前狀態是 {runtime_status}"
        summary_en = f"Watchdog state exists but runtime state is {runtime_status}"
    else:
        state = "down"
        summary_zh = "目前沒有統一 watchdog 在運行"
        summary_en = "No unified watchdog is currently running"

    compact = [
        detail("PID", str(watchdog_pid or "-"), "PID"),
        detail("追蹤 server", str(server_pid or "-"), "Tracked server", str(server_pid or "-")),
        detail("狀態", runtime_status, "Status", runtime_status),
    ]
    details = compact + [
        detail("自動重啟次數", str(restart_count), "Restart count", str(restart_count)),
        detail("最近重啟", last_restart_at, "Last restart", last_restart_at),
        detail("最近退出碼", last_exit_code, "Last exit code", last_exit_code),
    ]
    if proc:
        details.append(detail("命令列", str(proc.get("CommandLine", "-")), "Command", str(proc.get("CommandLine", "-"))))

    return ServiceStatus(
        key="watchdog",
        title_zh="llama 看門狗",
        title_en="llama Watchdog",
        state=state,
        summary_zh=summary_zh,
        summary_en=summary_en,
        compact_details=compact,
        details=details,
        updated_at=iso_now(),
    )


def check_dashboard(listener_rows: list[dict[str, Any]]) -> ServiceStatus:
    by_port = listeners_by_port(listener_rows)
    port_row = by_port.get(9119)
    probe = http_probe("http://127.0.0.1:9119/")

    if port_row and probe.startswith("HTTP"):
        state = "ok"
        summary_zh = "Dashboard 正常服務於 9119"
        summary_en = "Dashboard is serving normally on 9119"
    elif port_row:
        state = "warn"
        summary_zh = "Dashboard port 已開，但 HTTP 探測未完成"
        summary_en = "Dashboard port is open but HTTP probing is incomplete"
    else:
        state = "down"
        summary_zh = "Dashboard 沒有監聽 9119"
        summary_en = "Dashboard is not listening on 9119"

    compact = [
        detail("Listener PID", str(port_row.get("OwningProcess")) if port_row else "-", "Listener PID", str(port_row.get("OwningProcess")) if port_row else "-"),
        detail("HTTP 探測", probe, "HTTP probe", probe),
    ]
    details = compact + [detail("網址", "http://127.0.0.1:9119", "URL", "http://127.0.0.1:9119")]

    return ServiceStatus(
        key="dashboard",
        title_zh="Hermes 儀表板",
        title_en="Hermes Dashboard",
        state=state,
        summary_zh=summary_zh,
        summary_en=summary_en,
        compact_details=compact,
        details=details,
        updated_at=iso_now(),
    )


def check_gateway(process_rows: list[dict[str, Any]]) -> ServiceStatus:
    gateway_state = read_json_file(HERMES_HOME / "gateway_state.json") or {}
    by_pid = process_by_pid(process_rows)
    pid = gateway_state.get("pid") if isinstance(gateway_state, dict) else None
    proc = by_pid.get(pid) if isinstance(pid, int) else None
    gateway_processes = find_processes(process_rows, "hermes_cli.main gateway")
    platforms = gateway_state.get("platforms") if isinstance(gateway_state.get("platforms"), dict) else {}
    platforms_zh, platforms_en = summarize_platforms(platforms)
    gateway_state_name = str(gateway_state.get("gateway_state") or "unknown")
    active_agents = gateway_state.get("active_agents", "-")

    if proc and gateway_state_name == "running":
        state = "ok"
        summary_zh = f"Gateway 正在運行，active_agents={active_agents}"
        summary_en = f"Gateway running, active_agents={active_agents}"
    elif proc or gateway_processes or gateway_state:
        state = "warn"
        summary_zh = f"Gateway 有跡象存在，但狀態是 {gateway_state_name}"
        summary_en = f"Gateway hints exist but state is {gateway_state_name}"
    else:
        state = "down"
        summary_zh = "沒有偵測到 gateway process 或狀態檔"
        summary_en = "No gateway process or state file found"

    compact = [
        detail("PID", str(pid or "-"), "PID"),
        detail("Gateway 狀態", gateway_state_name, "gateway_state", gateway_state_name),
        detail("平台連線", platforms_zh, "platforms", platforms_en),
    ]
    details = compact + [
        detail("活躍代理數", str(active_agents), "active_agents", str(active_agents)),
        detail("更新時間", format_ts(gateway_state.get("updated_at")), "updated_at", format_ts(gateway_state.get("updated_at"))),
    ]
    if proc:
        details.append(detail("命令列", str(proc.get("CommandLine", "-")), "Command", str(proc.get("CommandLine", "-"))))

    return ServiceStatus(
        key="gateway",
        title_zh="Hermes Gateway",
        title_en="Hermes Gateway",
        state=state,
        summary_zh=summary_zh,
        summary_en=summary_en,
        compact_details=compact,
        details=details,
        updated_at=iso_now(),
    )


def check_hermes_main(process_rows: list[dict[str, Any]]) -> ServiceStatus:
    hermes_bins = [row for row in process_rows if str(row.get("Name")) == "hermes.exe"]
    run_agents = find_processes(process_rows, "run_agent.py")
    dashboards = find_processes(process_rows, "dashboard")

    if hermes_bins or run_agents or dashboards:
        state = "ok"
        summary_zh = f"Hermes 主入口存在：hermes={len(hermes_bins)}，run_agent={len(run_agents)}"
        summary_en = f"Hermes main entry found: hermes={len(hermes_bins)}, run_agent={len(run_agents)}"
    else:
        state = "down"
        summary_zh = "目前沒有看到 Hermes 主入口程序"
        summary_en = "No Hermes main-entry process is visible right now"

    compact = [
        detail("hermes.exe 數量", str(len(hermes_bins)), "hermes.exe count", str(len(hermes_bins))),
        detail("run_agent 數量", str(len(run_agents)), "run_agent count", str(len(run_agents))),
        detail("dashboard 命令數量", str(len(dashboards)), "dashboard command count", str(len(dashboards))),
    ]
    details = compact + [
        bi(
            "這張卡代表 Hermes 主入口；Start/Stop 會呼叫 start.cmd / stop.cmd。",
            "This card represents the Hermes main entry; Start/Stop uses start.cmd / stop.cmd.",
        )
    ]
    for row in (hermes_bins + run_agents)[:3]:
        details.append(detail("命令列", str(row.get("CommandLine", "-")), "Command", str(row.get("CommandLine", "-"))))

    return ServiceStatus(
        key="hermes",
        title_zh="Hermes 主入口",
        title_en="Hermes Main Entry",
        state=state,
        summary_zh=summary_zh,
        summary_en=summary_en,
        compact_details=compact,
        details=details,
        updated_at=iso_now(),
    )


def check_worker(
    key: str,
    title_zh: str,
    title_en: str,
    port: int,
    expected_pid: int | None,
    command_hint: str,
    process_rows: list[dict[str, Any]],
    listener_rows: list[dict[str, Any]],
    registry_row: dict[str, Any] | None,
) -> ServiceStatus:
    by_pid = process_by_pid(process_rows)
    by_port = listeners_by_port(listener_rows)
    port_row = by_port.get(port)
    proc = by_pid.get(expected_pid) if expected_pid else None
    if not proc and port_row:
        proc = by_pid.get(port_row.get("OwningProcess"))
    if not proc:
        matches = find_processes(process_rows, command_hint)
        proc = matches[0] if matches else None

    probe = http_probe(f"http://127.0.0.1:{port}/")
    tcp = tcp_probe("127.0.0.1", port)
    cmd = ""
    if proc:
        cmd = str(proc.get("CommandLine") or "")
    elif registry_row:
        cmd = str(registry_row.get("command") or "")

    checkpoint_match = re.search(r"--checkpoint\s+([^\s]+)", cmd)
    checkpoint = checkpoint_match.group(1) if checkpoint_match else "-"

    if port_row and (probe.startswith("HTTP") or tcp == "TCP OK"):
        state = "ok"
        summary_zh = f"{title_zh} 正在監聽 {port}"
        summary_en = f"{title_en} is listening on {port}"
    elif port_row or proc or registry_row:
        state = "warn"
        summary_zh = f"{title_zh} 只有部分存活訊號"
        summary_en = f"Only partial {title_en} signals were found"
    else:
        state = "down"
        summary_zh = f"沒有偵測到 {title_zh} 在 {port} 的 listener"
        summary_en = f"No {title_en} listener was found on {port}"

    compact = [
        detail("Listener PID", str(port_row.get("OwningProcess")) if port_row else "-", "Listener PID", str(port_row.get("OwningProcess")) if port_row else "-"),
        detail("Checkpoint", checkpoint, "Checkpoint", checkpoint),
        detail("TCP 探測", tcp, "TCP probe", tcp),
    ]
    details = compact + [
        detail("Registry PID", str(expected_pid or "-"), "Registry PID", str(expected_pid or "-")),
        detail("HTTP 探測", probe, "HTTP probe", probe),
        detail("啟動時間", format_ts(registry_row.get("started_at") if registry_row else None), "Started", format_ts(registry_row.get("started_at") if registry_row else None)),
    ]
    if cmd:
        details.append(detail("命令列", cmd, "Command", cmd))

    return ServiceStatus(
        key=key,
        title_zh=title_zh,
        title_en=title_en,
        state=state,
        summary_zh=summary_zh,
        summary_en=summary_en,
        compact_details=compact,
        details=details,
        updated_at=iso_now(),
    )


def get_registry_row(kind: str) -> dict[str, Any] | None:
    process_registry = read_json_file(HERMES_HOME / "processes.json")
    if not isinstance(process_registry, list):
        return None
    needle = "qwen3_tts_http_api.py" if kind == "tts" else "qwen3_asr_http_worker.py"
    for row in process_registry:
        if not isinstance(row, dict):
            continue
        if needle in str(row.get("command") or ""):
            return row
    return None


def collect_snapshot() -> dict[str, Any]:
    process_rows = get_process_rows()
    listener_rows = get_listener_rows()
    registry_tts = get_registry_row("tts")
    registry_asr = get_registry_row("asr")

    services = [
        check_llama(process_rows, listener_rows),
        check_watchdog(process_rows),
        check_dashboard(listener_rows),
        check_gateway(process_rows),
        check_hermes_main(process_rows),
        check_worker("tts", "語音合成", "TTS", 7101, int(registry_tts.get("pid")) if registry_tts and isinstance(registry_tts.get("pid"), int) else None, "qwen3_tts_http_api.py", process_rows, listener_rows, registry_tts),
        check_worker("asr", "語音辨識", "ASR", 7201, int(registry_asr.get("pid")) if registry_asr and isinstance(registry_asr.get("pid"), int) else None, "qwen3_asr_http_worker.py", process_rows, listener_rows, registry_asr),
    ]

    counts = {"ok": 0, "warn": 0, "down": 0}
    for service in services:
        counts[service.state] = counts.get(service.state, 0) + 1

    return {
        "collected_at": iso_now(),
        "project_root": str(PROJECT_ROOT),
        "hermes_home": str(HERMES_HOME),
        "counts": counts,
        "services": [asdict(service) for service in services],
    }


def run_hidden(args: list[str], cwd: Path | None = None, env: dict[str, str] | None = None, wait: bool = False) -> tuple[int, str]:
    try:
        if wait:
            completed = subprocess.run(
                args,
                cwd=str(cwd) if cwd else None,
                env=env,
                capture_output=True,
                text=False,
                timeout=60,
                check=False,
                creationflags=CREATE_NO_WINDOW,
            )
            output = "\n".join(part for part in (decode_bytes(completed.stdout).strip(), decode_bytes(completed.stderr).strip()) if part)
            return completed.returncode, output

        subprocess.Popen(args, cwd=str(cwd) if cwd else None, env=env, creationflags=CREATE_NO_WINDOW)
        return 0, ""
    except Exception as exc:
        return 1, str(exc)


def run_hidden_cmd(script_path: Path, cwd: Path | None = None, wait: bool = False) -> tuple[int, str]:
    return run_hidden([CMD_EXE, "/c", str(script_path)], cwd=cwd or script_path.parent, wait=wait)


def taskkill_pids(pids: set[int]) -> tuple[int, str]:
    messages = []
    for pid in sorted(pid for pid in pids if pid > 0):
        code, output = run_hidden(["taskkill.exe", "/PID", str(pid), "/T", "/F"], wait=True)
        messages.append(output or f"taskkill PID {pid} return={code}")
    return 0, "\n".join(messages)


def msys_to_windows(token: str) -> str:
    if re.match(r"^/[a-zA-Z]/", token):
        drive = token[1].upper()
        rest = token[3:].replace("/", "\\")
        return f"{drive}:\\{rest}"
    return token


def normalize_registry_command(command: str) -> tuple[list[str], dict[str, str]]:
    env = os.environ.copy()
    tokens = shlex.split(command, posix=True)
    args: list[str] = []
    for token in tokens:
        if "=" in token and not args and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            key, value = token.split("=", 1)
            env[key] = value
            continue
        args.append(msys_to_windows(token))
    return args, env


def get_runtime_pids(port: int | None = None, hints: list[str] | None = None, extra_pids: list[int] | None = None) -> set[int]:
    process_rows = get_process_rows()
    listener_rows = get_listener_rows()
    by_pid = process_by_pid(process_rows)
    by_port = listeners_by_port(listener_rows)
    pids: set[int] = set()

    if port:
        row = by_port.get(port)
        if row and isinstance(row.get("OwningProcess"), int):
            pids.add(int(row["OwningProcess"]))

    if hints:
        for hint in hints:
            for row in find_processes(process_rows, hint):
                pid = row.get("ProcessId")
                if isinstance(pid, int):
                    pids.add(pid)

    if extra_pids:
        for pid in extra_pids:
            if pid in by_pid:
                pids.add(pid)

    return pids


def start_llama() -> str:
    code, output = run_hidden_cmd(PROJECT_ROOT / "Start.cmd", cwd=PROJECT_ROOT)
    if code != 0:
        raise RuntimeError(output or "failed to launch Start.cmd")
    return bi("已開啟 llama.cpp 啟動入口。", "Opened the llama.cpp launcher entry point.")


def stop_llama() -> str:
    code, output = run_hidden_cmd(PROJECT_ROOT / "stop_llamacpp.cmd", cwd=PROJECT_ROOT, wait=True)
    if code != 0:
        raise RuntimeError(output or "failed to stop llama.cpp")
    return bi("已要求停止 llama.cpp。", "Requested llama.cpp shutdown.")


def start_watchdog() -> str:
    script = PROJECT_ROOT / "start_watchdog.cmd"
    if not script.exists():
        raise RuntimeError(f"missing {script}")
    code, output = run_hidden_cmd(script, cwd=PROJECT_ROOT, wait=True)
    if code != 0:
        raise RuntimeError(output or "failed to start watchdog")
    return bi("已要求啟動統一 watchdog。", "Requested unified watchdog startup.")


def stop_watchdog() -> str:
    script = PROJECT_ROOT / "stop_watchdog.cmd"
    if not script.exists():
        raise RuntimeError(f"missing {script}")
    code, output = run_hidden_cmd(script, cwd=PROJECT_ROOT, wait=True)
    if code != 0:
        raise RuntimeError(output or "failed to stop watchdog")
    return bi("已要求停止統一 watchdog。", "Requested unified watchdog shutdown.")


def start_dashboard() -> str:
    if not HERMES_EXE.exists():
        raise RuntimeError(f"missing {HERMES_EXE}")
    code, output = run_hidden([str(HERMES_EXE), "dashboard", "--no-open", "--skip-build"], cwd=HERMES_HOME)
    if code != 0:
        raise RuntimeError(output or "failed to start dashboard")
    return bi("已要求啟動 Hermes Dashboard。", "Requested Hermes Dashboard startup.")


def stop_dashboard() -> str:
    if not HERMES_EXE.exists():
        raise RuntimeError(f"missing {HERMES_EXE}")
    code, output = run_hidden([str(HERMES_EXE), "dashboard", "--stop"], cwd=HERMES_HOME, wait=True)
    if code != 0:
        raise RuntimeError(output or "failed to stop dashboard")
    return bi("已要求停止 Hermes Dashboard。", "Requested Hermes Dashboard shutdown.")


def start_gateway() -> str:
    if not HERMES_GATEWAY_CMD.exists():
        raise RuntimeError(f"missing {HERMES_GATEWAY_CMD}")
    code, output = run_hidden_cmd(HERMES_GATEWAY_CMD, cwd=HERMES_GATEWAY_CMD.parent)
    if code != 0:
        raise RuntimeError(output or "failed to start gateway")
    return bi("已要求啟動 Hermes Gateway。", "Requested Hermes Gateway startup.")


def stop_gateway() -> str:
    if not HERMES_EXE.exists():
        raise RuntimeError(f"missing {HERMES_EXE}")
    code, output = run_hidden([str(HERMES_EXE), "gateway", "stop"], cwd=HERMES_HOME, wait=True)
    if code != 0:
        raise RuntimeError(output or "failed to stop gateway")
    return bi("已要求停止 Hermes Gateway。", "Requested Hermes Gateway shutdown.")


def start_hermes_main() -> str:
    script = HERMES_HOME / "start.cmd"
    if not script.exists():
        raise RuntimeError(f"missing {script}")
    code, output = run_hidden_cmd(script, cwd=HERMES_HOME)
    if code != 0:
        raise RuntimeError(output or "failed to start Hermes main entry")
    return bi("已啟動 Hermes 主入口流程。", "Started the Hermes main-entry flow.")


def stop_hermes_main() -> str:
    script = HERMES_HOME / "stop.cmd"
    if not script.exists():
        raise RuntimeError(f"missing {script}")
    code, output = run_hidden_cmd(script, cwd=HERMES_HOME, wait=True)
    if code != 0:
        raise RuntimeError(output or "failed to stop Hermes main entry")
    return bi("已停止 Hermes 主入口流程。", "Stopped the Hermes main-entry flow.")


def start_worker(kind: str) -> str:
    row = get_registry_row(kind)
    if not row:
        raise RuntimeError(f"no registry command found for {kind}")
    command = str(row.get("command") or "").strip()
    cwd = Path(str(row.get("cwd") or PROJECT_ROOT))
    args, env = normalize_registry_command(command)
    if not args:
        raise RuntimeError(f"registry command for {kind} is empty")
    code, output = run_hidden(args, cwd=cwd, env=env)
    if code != 0:
        raise RuntimeError(output or f"failed to start {kind}")
    if kind == "tts":
        return bi("已要求啟動 TTS 服務。", "Requested TTS startup.")
    return bi("已要求啟動 ASR 服務。", "Requested ASR startup.")


def stop_worker(kind: str) -> str:
    row = get_registry_row(kind)
    extra_pids: list[int] = []
    if row and isinstance(row.get("pid"), int):
        extra_pids.append(int(row["pid"]))
    if kind == "tts":
        pids = get_runtime_pids(port=7101, hints=["qwen3_tts_http_api.py"], extra_pids=extra_pids)
        message = bi("已要求停止 TTS 服務。", "Requested TTS shutdown.")
    else:
        pids = get_runtime_pids(port=7201, hints=["qwen3_asr_http_worker.py"], extra_pids=extra_pids)
        message = bi("已要求停止 ASR 服務。", "Requested ASR shutdown.")
    if not pids:
        return bi("目前沒有對應程序在運行。", "No matching process is currently running.")
    taskkill_pids(pids)
    return message


ACTION_MAP: dict[str, dict[str, Any]] = {
    "llama": {"start": start_llama, "stop": stop_llama},
    "watchdog": {"start": start_watchdog, "stop": stop_watchdog},
    "dashboard": {"start": start_dashboard, "stop": stop_dashboard},
    "gateway": {"start": start_gateway, "stop": stop_gateway},
    "hermes": {"start": start_hermes_main, "stop": stop_hermes_main},
    "tts": {"start": lambda: start_worker("tts"), "stop": lambda: stop_worker("tts")},
    "asr": {"start": lambda: start_worker("asr"), "stop": lambda: stop_worker("asr")},
}


def load_card_order() -> list[str]:
    payload = read_json_file(MONITOR_LAYOUT_FILE)
    raw_order = payload.get("card_order") if isinstance(payload, dict) else None
    if not isinstance(raw_order, list):
        return DEFAULT_CARD_ORDER[:]

    order = [str(item) for item in raw_order if str(item) in DEFAULT_CARD_ORDER]
    for key in DEFAULT_CARD_ORDER:
        if key not in order:
            order.append(key)
    return order


def save_card_order(order: list[str]) -> None:
    JSON_ROOT.mkdir(parents=True, exist_ok=True)
    payload = {"card_order": [key for key in order if key in DEFAULT_CARD_ORDER]}
    tmp_path = MONITOR_LAYOUT_FILE.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp_path.replace(MONITOR_LAYOUT_FILE)


class MonitorApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("PYTHON THINKER / PYTHON THINKER")
        self.root.geometry("1260x980")
        self.root.minsize(1040, 780)
        self.root.configure(bg="#0f172a")
        self.auto_refresh = tk.BooleanVar(value=True)
        self.stay_on_top = tk.BooleanVar(value=False)
        self.refresh_seconds = tk.StringVar(value="5")
        self.display_mode = tk.StringVar(value="detailed")
        self.language_mode = tk.StringVar(value="zh")
        self.status_text = tk.StringVar(value=self.t("正在收集服務狀態...", "Collecting service status..."))
        self.card_widgets: dict[str, dict[str, Any]] = {}
        self.card_order = load_card_order()
        self.after_id: str | None = None
        self.snapshot: dict[str, Any] | None = None
        self.busy_services: set[str] = set()
        self.dragging_key: str | None = None
        self.layout_dirty = False
        self.refresh_in_progress = False
        self.pending_refresh = False
        self.canvas_window_id: int | None = None
        self.current_columns = 2

        self._build_ui()
        self.refresh()

    def t(self, zh: str, en: str) -> str:
        return choose_text(zh, en, self.language_mode.get())

    def tv(self, value: str) -> str:
        return choose_bilingual_value(value, self.language_mode.get())

    def _build_ui(self) -> None:
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Card.TLabelframe", background="#111827", foreground="#e5e7eb")
        style.configure("Card.TFrame", background="#111827")
        style.configure("Meta.TLabel", background="#0f172a", foreground="#cbd5e1")
        style.configure("Body.TLabel", background="#111827", foreground="#e5e7eb")
        style.configure("Title.TLabel", background="#111827", foreground="#f8fafc")
        style.configure("Toolbar.TFrame", background="#0f172a")

        toolbar = ttk.Frame(self.root, style="Toolbar.TFrame", padding=12)
        toolbar.pack(fill="x")

        ttk.Label(
            toolbar,
            text=self.t("PYTHON THINKER 服務監看器", "PYTHON THINKER Service Monitor"),
            style="Meta.TLabel",
            font=("Segoe UI", 18, "bold"),
            justify="left",
        ).pack(side="left")

        ttk.Button(toolbar, text=self.t("立即更新", "Refresh"), command=self.refresh).pack(side="right", padx=(8, 0))
        ttk.Button(toolbar, text=self.t("llama 記錄", "llama Logs"), command=lambda: self.open_path(EASY_LOGS)).pack(side="right", padx=(8, 0))
        ttk.Button(toolbar, text=self.t("Hermes 記錄", "Hermes Logs"), command=lambda: self.open_path(HERMES_HOME / "logs")).pack(side="right", padx=(8, 0))
        ttk.Button(toolbar, text=self.t("儀表板", "Dashboard"), command=lambda: webbrowser.open("http://127.0.0.1:9119")).pack(side="right")

        controls = ttk.Frame(self.root, style="Toolbar.TFrame", padding=(12, 0, 12, 8))
        controls.pack(fill="x")
        ttk.Checkbutton(controls, text=self.t("自動更新", "Auto refresh"), variable=self.auto_refresh, command=self._schedule_refresh).pack(side="left")
        ttk.Label(controls, text=self.t("更新秒數", "Interval"), style="Meta.TLabel").pack(side="left", padx=(16, 6))
        ttk.Entry(controls, textvariable=self.refresh_seconds, width=6).pack(side="left")
        ttk.Checkbutton(controls, text=self.t("視窗置頂", "Topmost"), variable=self.stay_on_top, command=self._apply_topmost).pack(side="left", padx=(16, 0))
        ttk.Label(controls, text=self.t("顯示", "View"), style="Meta.TLabel").pack(side="left", padx=(16, 6))
        ttk.Radiobutton(controls, text=self.t("精簡", "Compact"), value="compact", variable=self.display_mode, command=self._render_snapshot).pack(side="left")
        ttk.Radiobutton(controls, text=self.t("詳細", "Detailed"), value="detailed", variable=self.display_mode, command=self._render_snapshot).pack(side="left", padx=(6, 0))
        ttk.Label(controls, text=self.t("語言", "Language"), style="Meta.TLabel").pack(side="left", padx=(16, 6))
        ttk.Radiobutton(controls, text="中", value="zh", variable=self.language_mode, command=self._render_snapshot).pack(side="left")
        ttk.Radiobutton(controls, text="EN", value="en", variable=self.language_mode, command=self._render_snapshot).pack(side="left", padx=(6, 0))
        ttk.Radiobutton(controls, text=self.t("雙語", "Both"), value="both", variable=self.language_mode, command=self._render_snapshot).pack(side="left", padx=(6, 0))
        ttk.Label(controls, textvariable=self.status_text, style="Meta.TLabel", justify="right").pack(side="right")

        canvas_holder = ttk.Frame(self.root, style="Toolbar.TFrame")
        canvas_holder.pack(fill="both", expand=True, padx=12, pady=(0, 12))

        self.canvas = tk.Canvas(canvas_holder, bg="#0f172a", highlightthickness=0)
        scrollbar = ttk.Scrollbar(canvas_holder, orient="vertical", command=self.canvas.yview)
        self.cards_frame = ttk.Frame(self.canvas, style="Toolbar.TFrame")
        self.cards_frame.bind("<Configure>", lambda event: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas_window_id = self.canvas.create_window((0, 0), window=self.cards_frame, anchor="nw")
        self.canvas.configure(yscrollcommand=scrollbar.set)

        self.canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)
        self.canvas.bind("<Configure>", self._on_canvas_configure)

        for key in DEFAULT_CARD_ORDER:
            self._create_card(key)
        self._reflow_cards()

        for col in range(2):
            self.cards_frame.grid_columnconfigure(col, weight=1)

        self.root.bind_all("<ButtonRelease-1>", self._on_card_drag_end, add="+")

    def _create_card(self, key: str) -> None:
        frame = ttk.LabelFrame(self.cards_frame, text="", style="Card.TLabelframe", padding=14)
        frame.grid_columnconfigure(0, weight=1)

        header = ttk.Frame(frame, style="Card.TFrame")
        header.grid(row=0, column=0, sticky="ew")
        header.grid_columnconfigure(0, weight=1)

        title_label = ttk.Label(header, text=self.t("載入中", "Loading"), style="Title.TLabel", font=("Segoe UI", 12, "bold"), justify="left")
        title_label.grid(row=0, column=0, sticky="w")

        button_frame = ttk.Frame(header, style="Card.TFrame")
        button_frame.grid(row=0, column=1, sticky="e")
        drag_label = ttk.Label(button_frame, text=self.t("拖拉", "Drag"), style="Body.TLabel", justify="center", cursor="fleur")
        drag_label.pack(side="left", padx=(0, 8))
        copy_button = ttk.Button(button_frame, text=self.t("複製命令", "Copy Cmd"), command=lambda service_key=key: self.copy_command(service_key))
        start_button = ttk.Button(button_frame, text=self.t("啟動", "Start"), command=lambda service_key=key: self.trigger_action(service_key, "start"))
        stop_button = ttk.Button(button_frame, text=self.t("停止", "Stop"), command=lambda service_key=key: self.trigger_action(service_key, "stop"))
        start_button.pack(side="left", padx=(0, 6))
        stop_button.pack(side="left")
        copy_button.pack(side="left", padx=(6, 0))

        badge = tk.Label(frame, text=self.t("待定", "PENDING"), bg="#475569", fg="white", font=("Segoe UI", 10, "bold"), padx=10, pady=4, justify="center")
        badge.grid(row=1, column=0, sticky="w", pady=(10, 0))

        summary = ttk.Label(frame, text=self.t("等待第一次更新...", "Waiting for first refresh..."), style="Body.TLabel", font=("Segoe UI", 11, "bold"), wraplength=540, justify="left")
        summary.grid(row=2, column=0, sticky="w", pady=(10, 6))

        details = tk.Text(frame, height=10, wrap="word", bg="#111827", fg="#dbeafe", insertbackground="#dbeafe", relief="flat", font=("Consolas", 10))
        details.grid(row=3, column=0, sticky="nsew")
        details.configure(state="disabled")

        meta = ttk.Label(frame, text=self.t("更新時間: -", "Updated: -"), style="Body.TLabel", justify="left")
        meta.grid(row=4, column=0, sticky="w", pady=(8, 0))

        drag_label.bind("<ButtonPress-1>", lambda event, service_key=key: self._on_card_drag_start(service_key))
        for widget in (frame, header, title_label, badge, summary, details, meta, drag_label):
            widget.bind("<Enter>", lambda event, service_key=key: self._on_card_drag_enter(service_key, event), add="+")

        self.card_widgets[key] = {
            "frame": frame,
            "title": title_label,
            "badge": badge,
            "summary": summary,
            "details": details,
            "meta": meta,
            "start": start_button,
            "stop": stop_button,
            "copy": copy_button,
            "drag": drag_label,
            "command": "",
        }

    def _reflow_cards(self) -> None:
        for widgets in self.card_widgets.values():
            widgets["frame"].grid_forget()

        for col in range(2):
            self.cards_frame.grid_columnconfigure(col, weight=1 if col < self.current_columns else 0)

        for index, key in enumerate(self.card_order):
            widgets = self.card_widgets.get(key)
            if not widgets:
                continue
            row = index // self.current_columns
            column = index % self.current_columns
            widgets["frame"].grid(row=row, column=column, sticky="nsew", padx=8, pady=8)

    def _move_card(self, dragged_key: str, target_key: str, insert_after: bool) -> None:
        if dragged_key == target_key:
            return
        if dragged_key not in self.card_order or target_key not in self.card_order:
            return

        new_order = [key for key in self.card_order if key != dragged_key]
        target_index = new_order.index(target_key)
        if insert_after:
            target_index += 1
        new_order.insert(target_index, dragged_key)
        if new_order == self.card_order:
            return

        self.card_order = new_order
        self.layout_dirty = True
        self._reflow_cards()

    def _on_card_drag_start(self, service_key: str) -> None:
        self.dragging_key = service_key
        self.status_text.set(
            self.t(
                f"正在拖拉 {service_key.upper()}，移到其他卡片上方或下方即可重排。",
                f"Dragging {service_key.upper()}. Move over another card to reorder it.",
            )
        )

    def _on_card_drag_enter(self, service_key: str, event: tk.Event) -> None:
        if not self.dragging_key or self.dragging_key == service_key:
            return

        frame = self.card_widgets[service_key]["frame"]
        midpoint = frame.winfo_rooty() + (frame.winfo_height() / 2)
        insert_after = event.y_root >= midpoint
        self._move_card(self.dragging_key, service_key, insert_after)

    def _on_card_drag_end(self, _event: tk.Event | None = None) -> None:
        if not self.dragging_key:
            return
        released_key = self.dragging_key
        self.dragging_key = None
        if self.layout_dirty:
            try:
                save_card_order(self.card_order)
            except OSError as exc:
                self.status_text.set(self.t(f"卡片順序儲存失敗：{exc}", f"Failed to save card order: {exc}"))
                return
            finally:
                self.layout_dirty = False
        counts = self.snapshot["counts"] if self.snapshot else {"ok": 0, "warn": 0, "down": 0}
        self.status_text.set(
            self.t(
                f"已更新 {released_key.upper()} 的卡片順序 | OK {counts['ok']} WARN {counts['warn']} DOWN {counts['down']}",
                f"Updated card order for {released_key.upper()} | OK {counts['ok']} WARN {counts['warn']} DOWN {counts['down']}",
            )
        )

    def _apply_topmost(self) -> None:
        self.root.attributes("-topmost", self.stay_on_top.get())

    def _on_mousewheel(self, event: tk.Event) -> None:
        self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    def _on_canvas_configure(self, event: tk.Event) -> None:
        if self.canvas_window_id is not None:
            self.canvas.itemconfigure(self.canvas_window_id, width=event.width)

        next_columns = 1 if event.width < 980 else 2
        usable_width = max(360, event.width - 48)
        wraplength = int((usable_width / next_columns) - 90)
        for widgets in self.card_widgets.values():
            widgets["summary"].configure(wraplength=max(280, wraplength))

        if next_columns != self.current_columns:
            self.current_columns = next_columns
            self._reflow_cards()

    def _schedule_refresh(self) -> None:
        if self.after_id:
            self.root.after_cancel(self.after_id)
            self.after_id = None
        if not self.auto_refresh.get():
            return
        try:
            interval_ms = max(1000, int(float(self.refresh_seconds.get()) * 1000))
        except ValueError:
            interval_ms = DEFAULT_REFRESH_MS
        self.after_id = self.root.after(interval_ms, self.refresh)

    def open_path(self, path: Path) -> None:
        try:
            os.startfile(str(path))  # type: ignore[attr-defined]
        except Exception:
            webbrowser.open(path.as_uri())

    def refresh(self) -> None:
        if self.refresh_in_progress:
            self.pending_refresh = True
            self.status_text.set(self.t("上一輪更新仍在進行中...", "Previous refresh is still running..."))
            return

        if self.after_id:
            self.root.after_cancel(self.after_id)
            self.after_id = None

        self.refresh_in_progress = True
        self.status_text.set(self.t("正在收集服務狀態...", "Collecting service status..."))

        def worker() -> None:
            try:
                snapshot = collect_snapshot()
                error = None
            except Exception as exc:
                snapshot = None
                error = exc
            self.root.after(0, lambda: self._finish_refresh(snapshot, error))

        threading.Thread(target=worker, daemon=True).start()

    def _finish_refresh(self, snapshot: dict[str, Any] | None, error: Exception | None) -> None:
        self.refresh_in_progress = False
        if error:
            self.status_text.set(self.t(f"更新失敗：{error}", f"Refresh failed: {error}"))
        elif snapshot:
            self.snapshot = snapshot
            counts = self.snapshot["counts"]
            self.status_text.set(
                self.t(
                    f"已更新 {self.snapshot['collected_at']} | OK {counts['ok']} WARN {counts['warn']} DOWN {counts['down']}",
                    f"Refreshed {self.snapshot['collected_at']} | OK {counts['ok']} WARN {counts['warn']} DOWN {counts['down']}",
                )
            )
            self._render_snapshot()

        if self.pending_refresh:
            self.pending_refresh = False
            self.refresh()
            return

        self._schedule_refresh()

    def _render_snapshot(self) -> None:
        if not self.snapshot:
            return
        for service in self.snapshot["services"]:
            self._render_service(service)

    def _render_service(self, service: dict[str, Any]) -> None:
        widgets = self.card_widgets[service["key"]]
        badge = widgets["badge"]
        title = widgets["title"]
        summary = widgets["summary"]
        details = widgets["details"]
        meta = widgets["meta"]
        start_button = widgets["start"]
        stop_button = widgets["stop"]

        colors = {
            "ok": ("#16a34a", self.t("正常", "OK")),
            "warn": ("#d97706", self.t("警告", "WARN")),
            "down": ("#dc2626", self.t("停止", "DOWN")),
        }
        color, label = colors.get(service["state"], ("#475569", self.t(service["state"], service["state"].upper())))
        badge.configure(text=label, bg=color)
        title.configure(text=self.t(service["title_zh"], service["title_en"]))

        is_compact = self.display_mode.get() == "compact"
        if is_compact:
            summary.grid_remove()
            details.grid_remove()
            meta.grid_remove()
        else:
            summary.grid()
            details.grid()
            meta.grid()
            summary.configure(text=self.t(service["summary_zh"], service["summary_en"]))
            detail_items = service.get("details") or service.get("compact_details") or []
            command_items = [item for item in detail_items if is_command_detail(item)]
            regular_items = [item for item in detail_items if not is_command_detail(item)]
            widgets["command"] = self._extract_command(command_items[0]) if command_items else ""
            body = "\n".join(f"- {self.tv(item).replace(chr(10), chr(10) + '  ')}" for item in regular_items)
            if widgets["command"]:
                body = "\n".join(part for part in (body, f"- {self.t('命令列已收合，可用右上角按鈕複製。', 'Command is collapsed; use the top-right button to copy it.')}") if part)
            details.configure(state="normal")
            details.delete("1.0", "end")
            details.insert("1.0", body)
            details.configure(state="disabled")
            meta.configure(text=self.t(f"更新時間: {service['updated_at']}", f"Updated: {service['updated_at']}"))
            widgets["copy"].configure(state="normal" if widgets["command"] else "disabled")

        widgets["frame"].configure(padding=10 if is_compact else 14)
        busy = service["key"] in self.busy_services
        start_button.configure(state="disabled" if busy else "normal")
        stop_button.configure(state="disabled" if busy else "normal")

    def trigger_action(self, service_key: str, action: str) -> None:
        handler = ACTION_MAP.get(service_key, {}).get(action)
        if not handler:
            self.status_text.set(self.t("這個服務沒有對應的操作。", "No action is mapped for this service."))
            return
        if service_key in self.busy_services:
            return

        self.busy_services.add(service_key)
        self._render_snapshot()
        service_label = service_key.upper()
        self.status_text.set(
            self.t(
                f"正在執行 {service_label} 的 {action} 操作...",
                f"Running {action} for {service_label}...",
            )
        )

        def worker() -> None:
            try:
                message = handler()
            except Exception as exc:
                message = self.t(
                    f"{service_label} 操作失敗：{exc}",
                    f"{service_label} action failed: {exc}",
                )
            self.root.after(0, lambda: self._finish_action(service_key, message))

        threading.Thread(target=worker, daemon=True).start()

    def _finish_action(self, service_key: str, message: str) -> None:
        self.busy_services.discard(service_key)
        self.status_text.set(message)
        self.refresh()

    def _extract_command(self, item: str) -> str:
        lines = str(item).splitlines()
        preferred = lines[0] if self.language_mode.get() != "en" else (lines[1] if len(lines) > 1 else lines[0])
        return re.sub(r"^(命令列|Command):\s*", "", preferred).strip()

    def copy_command(self, service_key: str) -> None:
        widgets = self.card_widgets.get(service_key)
        command = str(widgets.get("command") if widgets else "").strip()
        if not command:
            self.status_text.set(self.t("這張卡目前沒有可複製的命令列。", "This card has no command to copy."))
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(command)
        self.status_text.set(self.t(f"已複製 {service_key.upper()} 命令列。", f"Copied {service_key.upper()} command."))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PYTHON THINKER service monitor")
    parser.add_argument("--snapshot", action="store_true", help="Print one JSON snapshot and exit")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.snapshot:
        print(json.dumps(collect_snapshot(), ensure_ascii=False, indent=2))
        return 0

    root = tk.Tk()
    app = MonitorApp(root)
    app._apply_topmost()
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
