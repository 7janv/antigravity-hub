$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$baseDir=$repo
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'AntigravityHub.ps1'),[ref]$null,[ref]$null)
foreach ($fnName in @('Get-DaemonStatus','Stop-AutoRotatorDaemon')) {
    $functionAst=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName},$true)
    if (-not $functionAst) { throw "Missing function: $fnName" }
    Invoke-Expression $functionAst.Extent.Text
}

# Verify default IntervalSeconds is 30 in AutoRotator.ps1.
$rotAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'AutoRotator.ps1'),[ref]$null,[ref]$null)
$intervalParam=$rotAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'IntervalSeconds' } | Select-Object -First 1
if (-not $intervalParam -or $intervalParam.DefaultValue.Value -ne 30) {
    throw "Expected AutoRotator.ps1 default IntervalSeconds=30"
}
Write-Host 'PASS: AutoRotator.ps1 default IntervalSeconds is 30'

# A single CIM instance has no Count in Windows PowerShell 5.1.
$expectedScript = [IO.Path]::GetFullPath((Join-Path $repo 'AutoRotator.ps1'))
$script:processes=@()
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) $script:processes }
foreach ($count in @(0,1,2)) {
    $script:processes=@(for ($i=0; $i -lt $count; $i++) {
        New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{
            ProcessId=[uint32](100+$i)
            CommandLine="powershell.exe -NoProfile -File `"$expectedScript`" -Daemon -IntervalSeconds 30"
        }
    })
    $actual=Get-DaemonStatus
    if ($actual -ne ($count -gt 0)) { throw "Incorrect daemon status for $count process(es): $actual" }
    Write-Host "PASS: Daemon status for $count scoped process(es)"
}

# Processes from a different folder or without -Daemon must be ignored.
$script:processes=@(
    New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]201;CommandLine='powershell.exe -File "C:\OtherClone\AutoRotator.ps1" -Daemon'}
    New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]202;CommandLine="notepad.exe `"$expectedScript`" Daemon"}
)
if (Get-DaemonStatus) { throw 'Get-DaemonStatus matched unrelated directory or non-daemon process' }
Write-Host 'PASS: Get-DaemonStatus ignores daemons from other directories and non-daemon commands'

$script:stoppedPids = @()
function Stop-Process { param($Id,[switch]$Force,$ErrorAction) $script:stoppedPids += $Id }
$script:processes=@(
    New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]301;CommandLine="powershell.exe -File `"$expectedScript`" -Daemon -IntervalSeconds 30"}
    New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]302;CommandLine='powershell.exe -File "C:\OtherClone\AutoRotator.ps1" -Daemon'}
    New-CimInstance -ClassName Win32_Process -ClientOnly -Property @{ProcessId=[uint32]$PID;CommandLine="powershell.exe -File `"$expectedScript`" -Daemon"}
)
$stoppedCount = Stop-AutoRotatorDaemon
if ($stoppedCount -ne 1 -or $script:stoppedPids.Count -ne 1 -or $script:stoppedPids[0] -ne 301) {
    throw "Stop-AutoRotatorDaemon stopped unexpected PIDs: $($script:stoppedPids -join ',')"
}
Write-Host 'PASS: Stop-AutoRotatorDaemon stops only current-directory daemon PIDs'
