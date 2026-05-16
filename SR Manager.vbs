Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
If fso.FileExists(dir & "\SRManager.exe") Then
    cmd = """" & dir & "\SRManager.exe" & """"
Else
    cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\SlavonskaRavnica.ps1"""
End If
shell.Run cmd, 0, False
