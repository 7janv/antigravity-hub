# ==============================================================================
# ANTIGRAVITY AUTO-HUB - SAFE UNINSTALLER
# Stops install-scoped daemon, removes shortcuts/backups, preserves user data
# unless -PurgeData is explicitly specified.
# ==============================================================================
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseDir,
    [string]$StartupDir,
    [string]$DesktopDir,
    [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'

if (-not $BaseDir) {
    $BaseDir = $PSScriptRoot
    if (-not $BaseDir) { $BaseDir = (Get-Location).Path }
}
$resolvedBase = [IO.Path]::GetFullPath($BaseDir)
if (-not (Test-Path -LiteralPath $resolvedBase -PathType Container)) {
    throw "BaseDir does not exist: $resolvedBase"
}

if (-not $StartupDir) {
    $StartupDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
}
if (-not $DesktopDir) {
    $DesktopDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
}

function Test-InsideRoot {
    param([string]$RootPath, [string]$CandidatePath)
    $rootNorm = [IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
    $candNorm = [IO.Path]::GetFullPath($CandidatePath)
    return $candNorm.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)
}

# 1. Stop ONLY AutoRotator.ps1 daemon processes scoped to this BaseDir
$rotatorScript = [IO.Path]::GetFullPath((Join-Path $resolvedBase 'AutoRotator.ps1'))
$stoppedPids = @()
$daemons = @()
$searcher = New-Object System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'")
try {
    foreach ($obj in $searcher.Get()) {
        $procId = [int]$obj['ProcessId']
        $cmdLine = [string]$obj['CommandLine']
        if ($procId -ne $PID -and $cmdLine -and
            $cmdLine.IndexOf($rotatorScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $cmdLine -match '(?i)\s-Daemon(?:\s|$)') {
            $daemons += [pscustomobject]@{ ProcessId = $procId; CommandLine = $cmdLine }
        }
    }
} finally {
    $searcher.Dispose()
}
foreach ($proc in $daemons) {
    if ($PSCmdlet.ShouldProcess("PID $($proc.ProcessId) ($rotatorScript)", 'Stop background daemon')) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedPids += $proc.ProcessId
        Write-Host "Stopped daemon PID: $($proc.ProcessId)" -ForegroundColor Yellow
    }
}

# 2. Remove Startup shortcut
$startupLnk = Join-Path $StartupDir 'AntigravityAutoRotator.lnk'
if (Test-Path -LiteralPath $startupLnk -PathType Leaf) {
    if ($PSCmdlet.ShouldProcess($startupLnk, 'Remove Windows Startup shortcut')) {
        Remove-Item -LiteralPath $startupLnk -Force
        Write-Host "Removed Startup shortcut: $startupLnk" -ForegroundColor Green
    }
}

# 3. Remove Desktop shortcut
$desktopLnk = Join-Path $DesktopDir 'Antigravity Auto-Hub.lnk'
if (Test-Path -LiteralPath $desktopLnk -PathType Leaf) {
    if ($PSCmdlet.ShouldProcess($desktopLnk, 'Remove Desktop shortcut')) {
        Remove-Item -LiteralPath $desktopLnk -Force
        Write-Host "Removed Desktop shortcut: $desktopLnk" -ForegroundColor Green
    }
}

# 4. Clean up internal backup artifacts inside BaseDir
$backupDir = Join-Path $resolvedBase '.backup'
if ((Test-Path -LiteralPath $backupDir -PathType Container) -and (Test-InsideRoot $resolvedBase $backupDir)) {
    if ($PSCmdlet.ShouldProcess($backupDir, 'Remove update backup directory')) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force
        Write-Host "Removed backup directory: $backupDir" -ForegroundColor Green
    }
}

$loginBackup = Join-Path $resolvedBase '.login-backup.dpapi'
if ((Test-Path -LiteralPath $loginBackup -PathType Leaf) -and (Test-InsideRoot $resolvedBase $loginBackup)) {
    if ($PSCmdlet.ShouldProcess($loginBackup, 'Remove login crash-recovery backup')) {
        Remove-Item -LiteralPath $loginBackup -Force
        Write-Host "Removed login backup: $loginBackup" -ForegroundColor Green
    }
}

# 5. Preserve user data unless -PurgeData is explicitly specified
if ($PurgeData) {
    $accDir = Join-Path $resolvedBase 'accounts'
    if ((Test-Path -LiteralPath $accDir -PathType Container) -and (Test-InsideRoot $resolvedBase $accDir)) {
        if ($PSCmdlet.ShouldProcess($accDir, 'Purge saved accounts directory')) {
            Remove-Item -LiteralPath $accDir -Recurse -Force
            Write-Host "Purged accounts directory: $accDir" -ForegroundColor Yellow
        }
    }

    $dataFiles = @(
        'hub-config.json',
        'oauth.local.clixml',
        'rotation-state.json',
        'current_active.txt',
        'rotator.log',
        '.hub-version.json',
        '.hub-version'
    )
    foreach ($name in $dataFiles) {
        $target = Join-Path $resolvedBase $name
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Test-InsideRoot $resolvedBase $target)) {
            if ($PSCmdlet.ShouldProcess($target, 'Purge local user data file')) {
                Remove-Item -LiteralPath $target -Force
                Write-Host "Purged data file: $target" -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host 'Preserved local user data (accounts/, hub-config.json, oauth.local.clixml). Pass -PurgeData to remove them.' -ForegroundColor Cyan
}

Write-Host 'Uninstall complete.' -ForegroundColor Green
