Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
strScriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
strPs1 = strScriptDir & "\AutoRotator.ps1"
strPowerShell = WshShell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
WshShell.Run """" & strPowerShell & """ -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File """ & strPs1 & """ -Daemon -IntervalSeconds 30", 0, False
