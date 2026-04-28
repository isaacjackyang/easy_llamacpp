Option Explicit

Dim shell, fso, scriptDir, powershellExe, watchdogScript, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(powershellExe) Then
  powershellExe = "powershell.exe"
End If

watchdogScript = fso.BuildPath(scriptDir, "watch-openclaw-stack.ps1")
command = """" & powershellExe & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & watchdogScript & """"

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
