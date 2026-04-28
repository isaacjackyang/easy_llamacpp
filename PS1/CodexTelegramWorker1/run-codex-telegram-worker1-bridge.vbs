Option Explicit

Dim shell, fso, scriptDir, powershellExe, runnerScript, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(powershellExe) Then
  powershellExe = "powershell.exe"
End If

runnerScript = fso.BuildPath(scriptDir, "run-codex-telegram-worker1-bridge.ps1")
command = """" & powershellExe & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & runnerScript & """"

shell.Run command, 0, False
WScript.Quit 0
