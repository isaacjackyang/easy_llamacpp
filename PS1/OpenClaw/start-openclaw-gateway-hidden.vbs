Option Explicit

Dim shell, fso, scriptDir, powershellExe, launcherScript, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(powershellExe) Then
  powershellExe = "powershell.exe"
End If

launcherScript = fso.BuildPath(scriptDir, "start-openclaw-gateway-hidden.ps1")
command = """" & powershellExe & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & launcherScript & """"

shell.Run command, 0, False
WScript.Quit 0
