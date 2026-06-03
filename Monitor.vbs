Option Explicit

Dim shell, fso, scriptDir, cmdPath, i, arg, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmdPath = fso.BuildPath(scriptDir, "Monitor.cmd")

If Not fso.FileExists(cmdPath) Then
    MsgBox "Cannot find monitor launcher: " & cmdPath, vbCritical, "Monitor"
    WScript.Quit 1
End If

command = """" & cmdPath & """"
For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments.Item(i)
    arg = Replace(arg, """", """""")
    command = command & " """ & arg & """"
Next

shell.Run command, 0, False
