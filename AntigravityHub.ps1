param([switch]$Preview, [switch]$NoShow)
if ($NoShow -and -not $Preview) { throw 'NoShow requires Preview.' }
# ==============================================================================
# ANTIGRAVITY MULTI-ACCOUNT HUB - 100% PURE ASCII UNICODE SAFE & PORTABLE
# ==============================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms, Microsoft.VisualBasic

$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = (Get-Location).Path }
$accDir = Join-Path $baseDir "accounts"
$activeFile = Join-Path $baseDir "current_active.txt"
$geminiTokenPath = Join-Path $env:USERPROFILE ".gemini\jetski-standalone-oauth-token"
$rotatorScript = Join-Path $baseDir "AutoRotator.ps1"
$xamlFile = Join-Path $baseDir "MainWindow.xaml"

if (-not (Test-Path $accDir)) {
    New-Item -ItemType Directory -Path $accDir -Force | Out-Null
}

if ($Preview) { . (Join-Path $baseDir 'ModelQuota.ps1') } else { . $rotatorScript }
. (Join-Path $baseDir 'Dashboard.ps1')
. (Join-Path $baseDir 'AccountLogin.ps1')

if (-not $Preview -and (Get-Command Set-RestrictedOwnerAcl -ErrorAction SilentlyContinue)) {
    try { Set-RestrictedOwnerAcl $accDir } catch {}
}

function Get-DaemonStatus {
    $root = if ($baseDir) { $baseDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $expectedScript = [IO.Path]::GetFullPath((Join-Path $root 'AutoRotator.ps1'))
    $procs = @(Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%AutoRotator.ps1%Daemon%'" -ErrorAction SilentlyContinue)
    $scoped = @($procs | Where-Object {
        $cmd = [string]$_.CommandLine
        $cmd -and $cmd.IndexOf($expectedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $cmd -match '(?i)(^|\s)-Daemon(\s|\z)'
    })
    return ($scoped.Count -gt 0)
}

function Stop-AutoRotatorDaemon {
    $root = if ($baseDir) { $baseDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $expectedScript = [IO.Path]::GetFullPath((Join-Path $root 'AutoRotator.ps1'))
    $procs = @(Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%AutoRotator.ps1%Daemon%'" -ErrorAction SilentlyContinue)
    $stopped = 0
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if (-not $cmd -or $cmd.IndexOf($expectedScript, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $cmd -notmatch '(?i)(^|\s)-Daemon(\s|\z)') { continue }
        if ($proc.ProcessId -eq $PID) { continue }
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $stopped++
        } catch {}
    }
    return $stopped
}

function Start-AutoRotatorDaemon {
    if (-not (Get-DaemonStatus)) {
        $vbs = Join-Path $baseDir "launch-rotator-daemon.vbs"
        if (Test-Path -LiteralPath $vbs) {
            $wscriptExe = Join-Path $env:WINDIR "System32\wscript.exe"
            Start-Process -FilePath $wscriptExe -ArgumentList """$vbs"""
        } else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
            $psi.Arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File ""$rotatorScript"" -Daemon -IntervalSeconds 30"
            $psi.CreateNoWindow = $true
            $psi.UseShellExecute = $false
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        }
    }
}

function Remove-LoginTempDirectory {
    param([string]$Path)
    if (-not $Path) { return }
    $resolved = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^ag_login_[0-9]+\z') { return }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        if (-not (Test-Path -LiteralPath $resolved)) { return }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $resolved)) { return }
        Start-Sleep -Milliseconds 150
    }
}

function Get-LoginBackupPath {
    $root = if ($baseDir) { $baseDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return (Join-Path $root '.login-backup.dpapi')
}

function Save-LoginCredentialBackup {
    param([string]$OldCredential, [string]$OldFallback, [bool]$HadFallback, [string]$TempDir)
    $backupPath = Get-LoginBackupPath
    $payload = [ordered]@{
        credential = $OldCredential
        fallback = $OldFallback
        had_fallback = $HadFallback
        temp_dir = $TempDir
        created_at_utc = [datetime]::UtcNow.ToString('o')
    }
    $envelope = Protect-AccountPayload $payload
    $temp = "$backupPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, $envelope, [Text.UTF8Encoding]::new($false))
        Set-RestrictedOwnerAcl $temp
        if ([IO.File]::Exists($backupPath)) { [IO.File]::Replace($temp, $backupPath, [NullString]::Value) }
        else { [IO.File]::Move($temp, $backupPath) }
        Set-RestrictedOwnerAcl $backupPath
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
    return $backupPath
}

function Restore-LoginCredentialBackup {
    $backupPath = Get-LoginBackupPath
    if (-not (Test-Path -LiteralPath $backupPath)) { return $true }
    $mutex = [Threading.Mutex]::new($false, 'Local\AntigravityAutoHub.Switch')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return $false }
        if (-not (Test-Path -LiteralPath $backupPath)) { return $true }
        $raw = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8 -ErrorAction Stop
        $plain = Unprotect-AccountPayload $raw
        $data = $plain | ConvertFrom-Json -ErrorAction Stop
        $oldCred = if ($data.PSObject.Properties['credential']) { [string]$data.credential } else { '' }
        if ((Get-StoredCredential) -cne $oldCred) {
            if ($oldCred) {
                Restore-StoredCredential $oldCred
            } else {
                $null = if (Get-Command Remove-StoredCredential -ErrorAction SilentlyContinue) { Remove-StoredCredential } else { [WinCred]::Delete('gemini:antigravity') }
            }
        }
        $hadFallback = [bool]($data.PSObject.Properties['had_fallback'] -and $data.had_fallback)
        if ($hadFallback) {
            $oldFb = if ($data.PSObject.Properties['fallback']) { [string]$data.fallback } else { '' }
            $fbDir = Split-Path -Path $geminiTokenPath -Parent
            if ($fbDir -and -not (Test-Path -LiteralPath $fbDir)) {
                New-Item -ItemType Directory -Path $fbDir -Force | Out-Null
                try { Set-RestrictedOwnerAcl $fbDir } catch {}
            }
            Write-AtomicText $geminiTokenPath $oldFb
            try { Set-RestrictedOwnerAcl $geminiTokenPath } catch {}
        } elseif (Test-Path -LiteralPath $geminiTokenPath) {
            [IO.File]::Delete($geminiTokenPath)
        }
        if ($data.PSObject.Properties['temp_dir'] -and $data.temp_dir) {
            Remove-LoginTempDirectory ([string]$data.temp_dir)
        }
        [IO.File]::Delete($backupPath)
        Write-RotatorLog 'Recovered interrupted login credential backup on startup.'
        return $true
    } catch {
        try { Set-RotationState 'NeedsAttention' } catch {}
        try { Write-RotatorLog 'Startup login backup recovery failed; automatic rotation paused.' } catch {}
        return $false
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Resolve-AccountFileName {
    param([string]$Email, [string]$AccountsDir, [string]$RefreshToken = '')
    $safeCheck = {
        param([string]$Candidate)
        if (Get-Command Test-SafeAccountName -ErrorAction SilentlyContinue) { return (Test-SafeAccountName $Candidate) }
        if ([string]::IsNullOrEmpty($Candidate)) { return $false }
        if ($Candidate -notmatch '^[a-zA-Z0-9_.@-]+\z' -or $Candidate -in @('.','..') -or $Candidate.EndsWith('.')) { return $false }
        $stem = ($Candidate -split '\.')[0]
        return ($stem -notmatch '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z')
    }
    $isSameAccount = {
        param([string]$ExistingPath)
        if (-not (Test-Path -LiteralPath $ExistingPath)) { return $false }
        try {
            $existingRaw = Read-AccountFile $ExistingPath -AsRawJson
            $existingObj = $existingRaw | ConvertFrom-Json
            if ($RefreshToken -and (Get-RefreshToken $existingObj) -ceq $RefreshToken) { return $true }
            if ($Email -and (Get-Command Get-CredentialEmail -ErrorAction SilentlyContinue)) {
                $existingEmail = Get-CredentialEmail $existingRaw
                if ($existingEmail -and $existingEmail -ieq $Email) { return $true }
            }
        } catch {}
        return $false
    }
    if ($Email -and $Email -match '^([^@]+)@([^@]+)\z') {
        $rawLocal = $Matches[1]
        $rawDomain = $Matches[2]
        $base = (($rawLocal -replace '[^a-zA-Z0-9._-]', '_').TrimEnd('.'))
        if (-not (& $safeCheck $base)) { $base = ('acc_' + $base).TrimEnd('.') }
        if (-not (& $safeCheck $base)) { $base = 'account' }
        $domainShort = ((($rawDomain -split '\.')[0]) -replace '[^a-zA-Z0-9_-]', '_').TrimEnd('.')
        $domainFull = (($rawDomain -replace '[^a-zA-Z0-9._-]', '_').TrimEnd('.'))
        $candidates = New-Object System.Collections.Generic.List[string]
        $candidates.Add($base)
        if ($domainShort) { $candidates.Add("${base}_${domainShort}") }
        if ($domainFull -and $domainFull -ine $domainShort) { $candidates.Add("${base}_${domainFull}") }
        foreach ($cand in $candidates) {
            if (-not (& $safeCheck $cand)) { continue }
            $path = Join-Path $AccountsDir ($cand + '.json')
            if (-not (Test-Path -LiteralPath $path) -or (& $isSameAccount $path)) { return $cand }
        }
        $prefix = if ($domainShort) { "${base}_${domainShort}" } else { $base }
        for ($n = 2; $n -lt 1000; $n++) {
            $cand = "${prefix}_${n}"
            if (-not (& $safeCheck $cand)) { continue }
            $path = Join-Path $AccountsDir ($cand + '.json')
            if (-not (Test-Path -LiteralPath $path) -or (& $isSameAccount $path)) { return $cand }
        }
        throw 'LoginTokenMissing'
    }
    for ($n = 1; $n -lt 10000; $n++) {
        $cand = "Acc_$n"
        $path = Join-Path $AccountsDir ($cand + '.json')
        if (-not (Test-Path -LiteralPath $path)) { return $cand }
    }
    throw 'LoginTokenMissing'
}

if (-not $Preview) {
    $null = Restore-LoginCredentialBackup
    Start-AutoRotatorDaemon
}

if (-not (Test-Path $xamlFile)) {
    Write-Error "Khong tim thay file MainWindow.xaml tai $xamlFile"
    exit 1
}

$xamlText = [System.IO.File]::ReadAllText($xamlFile, [System.Text.Encoding]::UTF8)
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xamlText))
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$reader.Dispose()
. (Join-Path $baseDir 'WindowBounds.ps1')
[HubWindowBounds]::Attach($window)
$window.Width=[math]::Min($window.Width,[Windows.SystemParameters]::WorkArea.Width)
$window.Height=[math]::Min($window.Height,[Windows.SystemParameters]::WorkArea.Height)

$titleBar = $window.FindName("TitleBar")
$btnMinimize = $window.FindName("BtnMinimize")
$btnClose = $window.FindName("BtnClose")
$btnRefresh = $window.FindName("BtnRefresh")
$btnSaveCurrent = $window.FindName("BtnSaveCurrent")
$btnAddAccount = $window.FindName("BtnAddAccount")
$btnOpenFolder = $window.FindName("BtnOpenFolder")
$txtFooterPath = $window.FindName("TxtFooterPath")
$accountsContainer = $window.FindName("AccountsContainer")

if ($txtFooterPath) {
    $txtFooterPath.Text = "Th$([char]0x01B0) m$([char]0x1EE5)c l$([char]0x01B0)u tr$([char]0x1EEF): $baseDir"
}

$titleBar.Add_MouseLeftButtonDown({ param($sender,$event)
    if ($event.OriginalSource -is [Windows.Controls.Button]) { return }
    if ($event.ClickCount -eq 2) { Switch-HubWindowState } else { $window.DragMove() }
})
function Switch-HubWindowState {
    $window.WindowState=if($window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}
}
$window.FindName('BtnMaximize').Add_Click({ Switch-HubWindowState })
$btnMinimize.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$btnClose.Add_Click({ $window.Close() })
$btnOpenFolder.Add_Click({ Start-Process -FilePath (Join-Path $env:WINDIR "explorer.exe") -ArgumentList $baseDir })

$btnRefresh.Add_Click({ Load-Accounts-UI -Reconcile })

$btnSaveCurrent.Add_Click({
    if ($Preview) { return }
    $savedDisplayEmail = $null
    $missingCred = $false
    $saveLock = [Threading.Mutex]::new($false, 'Local\AntigravityAutoHub.Switch')
    $saveLocked = $false
    try {
        try { $saveLocked = $saveLock.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $saveLocked = $true }
        if (-not $saveLocked) {
            Show-AccountLoginFailure 'LoginBusy'
            return
        }
        $cred = [WinCred]::Read("gemini:antigravity")
        if (-not $cred -and (Test-Path -LiteralPath $geminiTokenPath)) {
            $cred = [System.IO.File]::ReadAllText($geminiTokenPath, [System.Text.Encoding]::UTF8)
        }

        if (-not $cred) {
            $missingCred = $true
        } else {
            $email = ""
            $refreshToken = ""
            try {
                $json = $cred | ConvertFrom-Json
                $refreshToken = Get-RefreshToken $json
                if ($refreshToken) {
                    $fresh = Get-FreshToken $json
                    $uinfo = Invoke-RestMethod -Uri "https://www.googleapis.com/oauth2/v3/userinfo" -Headers @{ Authorization = "Bearer $($fresh.token.access_token)" } -TimeoutSec 5
                    $email = [string]$uinfo.email
                }
            } catch {}

            $cleanName = Resolve-AccountFileName -Email $email -AccountsDir $accDir -RefreshToken $refreshToken
            $targetFile = Join-Path $accDir "$cleanName.json"
            Save-AccountFile $targetFile $cred
            $savedDisplayEmail = if ($email) { $email } else { $cleanName }
        }
    } finally {
        if ($saveLocked) { $saveLock.ReleaseMutex() }
        $saveLock.Dispose()
    }
    if ($missingCred) {
        [System.Windows.MessageBox]::Show("Kh$([char]0x00F4)ng t$([char]0x00EC)m th$([char]0x1EA5)y token $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p hi$([char]0x1EC7)n t$([char]0x1EA1)i trong Antigravity IDE.`nH$([char]0x00E3)y $([char]0x0111)$([char]0x1EA3)m b$([char]0x1EA3)o b$([char]0x1EA1)n $([char]0x0111)$([char]0x00E3) $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p Google tr$([char]0x00EA)n IDE.", "Th$([char]0x00F4)ng b$([char]0x00E1)o", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    if ($savedDisplayEmail) {
        Load-Accounts-UI
        [System.Windows.MessageBox]::Show("$([char]0x0110)$([char]0x00E3) t$([char]0x1EF1) $([char]0x0111)$([char]0x1ED9)ng nh$([char]0x1EAD)n di$([char]0x1EC7)n v$([char]0x00E0) l$([char]0x01B0)u t$([char]0x00E0)i kho$([char]0x1EA3)n: $savedDisplayEmail v$([char]0x00E0)o kho xoay tua th$([char]0x00E0)nh c$([char]0x00F4)ng!", "Th$([char]0x00E0)nh C$([char]0x00F4)ng", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    }
})

function Complete-AccountLogin {
    if (-not $script:loginProtection) { return $true }
    $cleanupOk=$true
    try {
        if ($script:activeLoginTimer) { $script:activeLoginTimer.Stop() }
        if ($script:loginSession) { $script:loginSession.Dispose() }
        if ($script:loginSnapshotReady) {
            if ((Get-StoredCredential) -cne $script:loginOldCredential) {
                if ($script:loginOldCredential) { Restore-StoredCredential $script:loginOldCredential }
                elseif (-not [WinCred]::Delete('gemini:antigravity')) { throw 'LoginRestoreFailed' }
            }
            if ($null -ne $script:loginOldFallback) {
                Write-AtomicText $geminiTokenPath $script:loginOldFallback
                if (Get-Command Set-RestrictedOwnerAcl -ErrorAction SilentlyContinue) {
                    try { Set-RestrictedOwnerAcl $geminiTokenPath } catch {}
                }
            }
            elseif (Test-Path -LiteralPath $geminiTokenPath) { [IO.File]::Delete($geminiTokenPath) }
        }
        Remove-LoginTempDirectory $script:activeLoginTempDir
        if ($script:loginBackupPath -and [IO.File]::Exists($script:loginBackupPath)) {
            [IO.File]::Delete($script:loginBackupPath)
        }
    } catch {
        $cleanupOk=$false
        Set-RotationState 'NeedsAttention'
        Write-RotatorLog 'Login cleanup requires verification; automatic rotation paused.'
    } finally {
        $script:loginProtection.ReleaseMutex()
        $script:loginProtection.Dispose()
        $script:loginProtection=$null; $script:loginSnapshotReady=$false
        $script:loginOldCredential=$null; $script:loginOldFallback=$null
        $script:loginSession=$null; $script:activeLoginTempDir=$null; $script:loginBackupPath=$null
        $accountsContainer.IsEnabled=$true; $btnAddAccount.IsEnabled=$true; $btnSaveCurrent.IsEnabled=$true
        $btnAddAccount.Content = "+ Th$([char]0x00EA)m T$([char]0x00E0)i Kho$([char]0x1EA3)n M$([char]0x1EDB)i"
    }
    return $cleanupOk
}

function Get-AccountLoginFailureMessage {
    param([string]$Code)
    $message = switch ($Code) {
        'LoginVerificationTimeout' { "$([char]0x0110)$([char]0x00E3) h$([char]0x1EBF)t 5 ph$([char]0x00FA)t ch$([char]0x1EDD) x$([char]0x00E1)c minh Google. Hub ch$([char]0x01B0)a l$([char]0x01B0)u t$([char]0x00E0)i kho$([char]0x1EA3)n. Ho$([char]0x00E0)n t$([char]0x1EA5)t y$([char]0x00EA)u c$([char]0x1EA7)u tr$([char]0x00EA)n trang x$([char]0x00E1)c minh r$([char]0x1ED3)i b$([char]0x1EA5)m Th$([char]0x00EA)m T$([char]0x00E0)i Kho$([char]0x1EA3)n M$([char]0x1EDB)i $([char]0x0111)$([char]0x1EC3) th$([char]0x1EED) l$([char]0x1EA1)i." }
        'LoginIneligible' { "Antigravity ch$([char]0x01B0)a x$([char]0x00E1)c nh$([char]0x1EAD)n phi$([char]0x00EA)n $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p n$([char]0x00E0)y (ineligible). Hub ch$([char]0x01B0)a l$([char]0x01B0)u t$([char]0x00E0)i kho$([char]0x1EA3)n v$([char]0x00E0) ch$([char]0x01B0)a nh$([char]0x1EAD)n $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c li$([char]0x00EA)n k$([char]0x1EBF)t x$([char]0x00E1)c minh $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c h$([char]0x1ED7) tr$([char]0x1EE3). H$([char]0x00E3)y ki$([char]0x1EC3)m tra th$([char]0x00F4)ng b$([char]0x00E1)o trong Antigravity ch$([char]0x00ED)nh th$([char]0x1EE9)c; m$([char]0x00E3) n$([char]0x00E0)y ch$([char]0x01B0)a x$([char]0x00E1)c $([char]0x0111)$([char]0x1ECB)nh $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c nguy$([char]0x00EA)n nh$([char]0x00E2)n c$([char]0x1EE5) th$([char]0x1EC3)." }
        'LoginVerificationRequired' { "Antigravity y$([char]0x00EA)u c$([char]0x1EA7)u x$([char]0x00E1)c minh th$([char]0x00EA)m t$([char]0x00E0)i kho$([char]0x1EA3)n. H$([char]0x00E3)y m$([char]0x1EDF) $([char]0x1EE9)ng d$([char]0x1EE5)ng Antigravity ch$([char]0x00ED)nh th$([char]0x1EE9)c, ho$([char]0x00E0)n t$([char]0x1EA5)t x$([char]0x00E1)c minh r$([char]0x1ED3)i th$([char]0x00EA)m l$([char]0x1EA1)i v$([char]0x00E0)o Hub. T$([char]0x00E0)i kho$([char]0x1EA3)n ch$([char]0x01B0)a $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c l$([char]0x01B0)u." }
        'LoginTermsRejected' { "Antigravity t$([char]0x1EEB) ch$([char]0x1ED1)i t$([char]0x00E0)i kho$([char]0x1EA3)n v$([char]0x1EDB)i tr$([char]0x1EA1)ng th$([char]0x00E1)i tosViolation. H$([char]0x00E3)y ki$([char]0x1EC3)m tra th$([char]0x00F4)ng b$([char]0x00E1)o trong $([char]0x1EE9)ng d$([char]0x1EE5)ng ch$([char]0x00ED)nh th$([char]0x1EE9)c ho$([char]0x1EB7)c li$([char]0x00EA)n h$([char]0x1EC7) h$([char]0x1ED7) tr$([char]0x1EE3) Antigravity. T$([char]0x00E0)i kho$([char]0x1EA3)n ch$([char]0x01B0)a $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c l$([char]0x01B0)u." }
        'LoginProviderError' { "Antigravity tr$([char]0x1EA3) v$([char]0x1EC1) l$([char]0x1ED7)i khi x$([char]0x00E1)c th$([char]0x1EF1)c t$([char]0x00E0)i kho$([char]0x1EA3)n. H$([char]0x00E3)y ki$([char]0x1EC3)m tra $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p trong $([char]0x1EE9)ng d$([char]0x1EE5)ng ch$([char]0x00ED)nh th$([char]0x1EE9)c r$([char]0x1ED3)i th$([char]0x1EED) l$([char]0x1EA1)i. T$([char]0x00E0)i kho$([char]0x1EA3)n ch$([char]0x01B0)a $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c l$([char]0x01B0)u." }
        'LoginProjectRequired' { "Antigravity y$([char]0x00EA)u c$([char]0x1EA7)u c$([char]0x1EA5)u h$([char]0x00EC)nh project tr$([char]0x01B0)$([char]0x1EDB)c khi d$([char]0x00F9)ng t$([char]0x00E0)i kho$([char]0x1EA3)n. H$([char]0x00E3)y ho$([char]0x00E0)n t$([char]0x1EA5)t y$([char]0x00EA)u c$([char]0x1EA7)u trong $([char]0x1EE9)ng d$([char]0x1EE5)ng ch$([char]0x00ED)nh th$([char]0x1EE9)c r$([char]0x1ED3)i th$([char]0x00EA)m l$([char]0x1EA1)i v$([char]0x00E0)o Hub." }
        'LoginInteractiveRequired' { "Antigravity y$([char]0x00EA)u c$([char]0x1EA7)u ph$([char]0x01B0)$([char]0x01A1)ng th$([char]0x1EE9)c x$([char]0x00E1)c th$([char]0x1EF1)c kh$([char]0x00E1)c (headlessAuthRequired); Hub ch$([char]0x01B0)a h$([char]0x1ED7) tr$([char]0x1EE3) b$([char]0x01B0)$([char]0x1EDB)c n$([char]0x00E0)y. H$([char]0x00E3)y $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p trong $([char]0x1EE9)ng d$([char]0x1EE5)ng ch$([char]0x00ED)nh th$([char]0x1EE9)c." }
        'LoginLicenseRequired' { "Antigravity y$([char]0x00EA)u c$([char]0x1EA7)u gi$([char]0x1EA5)y ph$([char]0x00E9)p s$([char]0x1EED) d$([char]0x1EE5)ng cho t$([char]0x00E0)i kho$([char]0x1EA3)n n$([char]0x00E0)y. H$([char]0x00E3)y ki$([char]0x1EC3)m tra quy$([char]0x1EC1)n truy c$([char]0x1EAD)p trong $([char]0x1EE9)ng d$([char]0x1EE5)ng ch$([char]0x00ED)nh th$([char]0x1EE9)c r$([char]0x1ED3)i th$([char]0x00EA)m l$([char]0x1EA1)i v$([char]0x00E0)o Hub." }
        'LoginAuthRejected' { "Antigravity ch$([char]0x01B0)a x$([char]0x00E1)c nh$([char]0x1EAD)n t$([char]0x00E0)i kho$([char]0x1EA3)n h$([char]0x1EE3)p l$([char]0x1EC7) d$([char]0x00F9) Google c$([char]0x00F3) th$([char]0x1EC3) $([char]0x0111)$([char]0x00E3) $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p th$([char]0x00E0)nh c$([char]0x00F4)ng. T$([char]0x00E0)i kho$([char]0x1EA3)n ch$([char]0x01B0)a $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c l$([char]0x01B0)u. H$([char]0x00E3)y ki$([char]0x1EC3)m tra $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p trong $([char]0x1EE9)ng d$([char]0x1EE5)ng Antigravity ch$([char]0x00ED)nh th$([char]0x1EE9)c." }
        'LoginCleanupFailed' { "Kh$([char]0x00F4)ng kh$([char]0x00F4)i ph$([char]0x1EE5)c $([char]0x0111)$([char]0x1EA7)y $([char]0x0111)$([char]0x1EE7) $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c th$([char]0x00F4)ng tin $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p tr$([char]0x01B0)$([char]0x1EDB)c $([char]0x0111)$([char]0x00F3). T$([char]0x1EF1) $([char]0x0111)$([char]0x1ED9)ng xoay $([char]0x0111)$([char]0x00E3) t$([char]0x1EA1)m d$([char]0x1EEB)ng. H$([char]0x00E3)y ki$([char]0x1EC3)m tra t$([char]0x00E0)i kho$([char]0x1EA3)n $([char]0x0111)ang d$([char]0x00F9)ng trong Antigravity tr$([char]0x01B0)$([char]0x1EDB)c khi ti$([char]0x1EBF)p t$([char]0x1EE5)c." }
        'LoginBusy' { "$([char]0x0110)ang c$([char]0x00F3) thao t$([char]0x00E1)c chuy$([char]0x1EC3)n ho$([char]0x1EB7)c th$([char]0x00EA)m t$([char]0x00E0)i kho$([char]0x1EA3)n. Vui l$([char]0x00F2)ng th$([char]0x1EED) l$([char]0x1EA1)i sau." }
        'LoginHelperMissing' { "Kh$([char]0x00F4)ng t$([char]0x00EC)m th$([char]0x1EA5)y language_server.exe c$([char]0x1EE7)a Antigravity." }
        'LoginUrlTimeout' { "Kh$([char]0x00F4)ng nh$([char]0x1EAD)n $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c li$([char]0x00EA)n k$([char]0x1EBF)t Google sau 30 gi$([char]0x00E2)y. Ki$([char]0x1EC3)m tra k$([char]0x1EBF)t n$([char]0x1ED1)i m$([char]0x1EA1)ng ho$([char]0x1EB7)c c$([char]0x1EAD)p nh$([char]0x1EAD)t Antigravity r$([char]0x1ED3)i th$([char]0x1EED) l$([char]0x1EA1)i." }
        'LoginTimeout' { "$([char]0x0110)$([char]0x00E3) h$([char]0x1EBF)t 5 ph$([char]0x00FA)t ch$([char]0x1EDD) $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p. B$([char]0x1EA5)m Th$([char]0x00EA)m T$([char]0x00E0)i Kho$([char]0x1EA3)n M$([char]0x1EDB)i $([char]0x0111)$([char]0x1EC3) th$([char]0x1EED) l$([char]0x1EA1)i." }
        'LoginBrowserFailed' { "Kh$([char]0x00F4)ng m$([char]0x1EDF) $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c tr$([char]0x00EC)nh duy$([char]0x1EC7)t m$([char]0x1EB7)c $([char]0x0111)$([char]0x1ECB)nh. Ki$([char]0x1EC3)m tra $([char]0x1EE9)ng d$([char]0x1EE5)ng m$([char]0x1EDF) li$([char]0x00EA)n k$([char]0x1EBF)t HTTPS trong Windows." }
        'LoginTokenMissing' { "$([char]0x0110)$([char]0x0103)ng nh$([char]0x1EAD)p ch$([char]0x01B0)a tr$([char]0x1EA3) v$([char]0x1EC1) token h$([char]0x1EE3)p l$([char]0x1EC7). Vui l$([char]0x00F2)ng th$([char]0x1EED) l$([char]0x1EA1)i." }
        default { "Kh$([char]0x00F4)ng ho$([char]0x00E0)n t$([char]0x1EA5)t $([char]0x0111)$([char]0x01B0)$([char]0x1EE3)c lu$([char]0x1ED3)ng $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p. Ki$([char]0x1EC3)m tra m$([char]0x1EA1)ng, c$([char]0x1EA5)u h$([char]0x00EC)nh OAuth v$([char]0x00E0) phi$([char]0x00EA)n b$([char]0x1EA3)n Antigravity r$([char]0x1ED3)i th$([char]0x1EED) l$([char]0x1EA1)i." }
    }
    return $message
}

function Show-AccountLoginFailure {
    param([string]$Code)
    $message=Get-AccountLoginFailureMessage $Code
    # Only fixed codes enter logs; never URLs, raw helper output or OAuth errors.
    $safeCode = if ($Code -in @('LoginBusy','LoginHelperMissing','LoginUrlTimeout','LoginTimeout','LoginBrowserFailed','LoginTokenMissing','LoginHelperExited','LoginRequestFailed','LoginListenerMismatch','LoginAuthRejected','LoginInvalidResponse','LoginIdentityMissing','LoginCleanupFailed','LoginIneligible','LoginVerificationRequired','LoginTermsRejected','LoginProviderError','LoginProjectRequired','LoginInteractiveRequired','LoginLicenseRequired','LoginVerificationTimeout')) { $Code } else { 'LoginFailed' }
    Write-RotatorLog "Account login failed: $safeCode."
    [System.Windows.MessageBox]::Show($window, $message, "Th$([char]0x00EA)m t$([char]0x00E0)i kho$([char]0x1EA3)n", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
}
$window.Add_Closed({ Complete-AccountLogin })

$btnAddAccount.Add_Click({
    if ($Preview) { return }
    if ($script:loginProtection) { Complete-AccountLogin; return }
    $lsPath=Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\resources\bin\language_server.exe'
    if (-not (Test-Path -LiteralPath $lsPath)) { Show-AccountLoginFailure 'LoginHelperMissing'; return }
    $loginLock=[Threading.Mutex]::new($false, 'Local\AntigravityAutoHub.Switch')
    $loginLocked=$false
    try { $loginLocked=$loginLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $loginLocked=$true }
    if (-not $loginLocked) { $loginLock.Dispose(); Show-AccountLoginFailure 'LoginBusy'; return }
    $script:loginProtection=$loginLock
    try {
        $script:loginSnapshotReady=$false
        $script:loginOldCredential=Get-StoredCredential
        $script:loginOldFallback=$null
        $hadOldFallback=$false
        if (Test-Path -LiteralPath $geminiTokenPath) {
            $script:loginOldFallback=[IO.File]::ReadAllText($geminiTokenPath)
            $hadOldFallback=$true
        }
        $script:activeLoginTempDir=Join-Path $env:TEMP ('ag_login_'+(Get-Random))
        New-Item -ItemType Directory -Path $script:activeLoginTempDir -ErrorAction Stop | Out-Null
        $script:loginBackupPath=Save-LoginCredentialBackup -OldCredential $script:loginOldCredential -OldFallback $script:loginOldFallback -HadFallback $hadOldFallback -TempDir $script:activeLoginTempDir
        $script:loginSnapshotReady=$true
        $accountsContainer.IsEnabled=$false; $btnSaveCurrent.IsEnabled=$false
        $btnAddAccount.Content="H$([char]0x1EE7)y $([char]0x0111)$([char]0x0103)ng nh$([char]0x1EAD)p"
        $script:loginSession=[AntigravityAccountLogin]::new($lsPath,$script:activeLoginTempDir)
        $script:loginClock=[Diagnostics.Stopwatch]::StartNew()
        $script:loginBrowserOpened=$false
        $script:loginResultAt=$null
        $script:loginVerificationAt=$null
        $loginTimer=New-Object System.Windows.Threading.DispatcherTimer
        $loginTimer.Interval=[TimeSpan]::FromMilliseconds(250)
        $script:activeLoginTimer=$loginTimer
        $loginTimer.Add_Tick({
            try {
                $session=$script:loginSession
                if (-not $session) { return }
                Update-AccountLoginSession $session
                if ($session.AuthUrl -and -not $script:loginBrowserOpened) {
                    $url=$session.AuthUrl
                    if ($url -notmatch '[?&]prompt=') { $url+='&prompt=select_account' }
                    try {
                        $browser=[Diagnostics.ProcessStartInfo]::new($url)
                        $browser.UseShellExecute=$true
                        [Diagnostics.Process]::Start($browser) | Out-Null
                    } catch { throw 'LoginBrowserFailed' }
                    $script:loginBrowserOpened=$true
                    Write-RotatorLog 'Account login: Google authorization opened.'
                }
                if (-not $script:loginBrowserOpened -and $script:loginClock.Elapsed.TotalSeconds -ge 30) { throw 'LoginUrlTimeout' }
                if ($null -eq $script:loginVerificationAt -and $script:loginClock.Elapsed.TotalSeconds -ge 300) { throw 'LoginTimeout' }
                if ($null -ne $script:loginVerificationAt -and $script:loginClock.Elapsed.TotalSeconds-$script:loginVerificationAt -ge 300) { throw 'LoginVerificationTimeout' }
                if (-not $session.Succeeded) { return }
                $script:activeLoginTimer.Stop()
                $listeners=@(Get-NetTCPConnection -LocalPort $session.Port -State Listen -ErrorAction Stop)
                if (-not ($listeners | Where-Object {$_.OwningProcess -eq $session.Process.Id -and $_.LocalAddress -in @('127.0.0.1','::1')})) { throw 'LoginListenerMismatch' }
                $progress=Get-AccountLoginProgress $session -Recheck:($null -ne $script:loginVerificationAt)
                if ($progress.Status -eq 'VerificationRequired') {
                    if ($null -eq $script:loginVerificationAt) {
                        $browser=[Diagnostics.ProcessStartInfo]::new($progress.VerificationUrl)
                        $browser.UseShellExecute=$true
                        try { [Diagnostics.Process]::Start($browser) | Out-Null } catch { throw 'LoginBrowserFailed' }
                        $script:loginVerificationAt=$script:loginClock.Elapsed.TotalSeconds
                        $btnAddAccount.Content="H$([char]0x1EE7)y x$([char]0x00E1)c minh"
                        Write-RotatorLog 'Account login: official Google verification opened; waiting for valid auth.'
                    }
                    $script:activeLoginTimer.Interval=[TimeSpan]::FromSeconds(2)
                    $script:activeLoginTimer.Start()
                    return
                }
                if ($null -eq $script:loginResultAt) { $script:loginResultAt=$script:loginClock.Elapsed.TotalSeconds }
                $identity=$session.ReadUserStatus() | ConvertFrom-Json
                $candidates=@(Get-AccountLoginTokenCandidates $script:activeLoginTempDir $geminiTokenPath)
                $verified=Get-VerifiedAccountLoginToken $candidates $identity.userStatus.email
                if (-not $verified) {
                    $tempTokens=@(Get-ChildItem -LiteralPath $script:activeLoginTempDir -Recurse -File -Filter '*token*' -ErrorAction SilentlyContinue).Count
                    Write-RotatorLog "Account login token verification pending: candidates=$($candidates.Count), helperTokenFiles=$tempTokens."
                    if ($script:loginClock.Elapsed.TotalSeconds-$script:loginResultAt -ge 15) { throw 'LoginTokenMissing' }
                    $script:activeLoginTimer.Interval=[TimeSpan]::FromSeconds(2)
                    $script:activeLoginTimer.Start()
                    return
                }
                $token=$verified.Token
                $user=[pscustomobject]@{email=$verified.Email}
                $newRefresh=Get-RefreshToken $token
                $cleanName=Resolve-AccountFileName -Email $user.email -AccountsDir $accDir -RefreshToken $newRefresh
                Save-AccountFile (Join-Path $accDir ($cleanName+'.json')) ($token | ConvertTo-Json -Depth 6 -Compress)
                if (-not (Complete-AccountLogin)) { throw 'LoginCleanupFailed' }
                Write-RotatorLog 'Account login completed; account saved and previous credential restored.'
                Load-Accounts-UI
                [System.Windows.MessageBox]::Show($window, "$([char]0x0110)$([char]0x00E3) th$([char]0x00EA)m t$([char]0x00E0)i kho$([char]0x1EA3)n: $($user.email)", "Th$([char]0x00EA)m t$([char]0x00E0)i kho$([char]0x1EA3)n", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            } catch {
                $code=$_.Exception.Message
                if (-not (Complete-AccountLogin)) { $code='LoginCleanupFailed' }
                Show-AccountLoginFailure $code
            }
        })
        $loginTimer.Start()
    } catch {
        $code='LoginFailed'
        if (-not (Complete-AccountLogin)) { $code='LoginCleanupFailed' }
        Show-AccountLoginFailure $code
    }
})

Initialize-HubDashboard

$script:HubForceExit = $false
$script:HubTrayIcon = $null
$script:HubTrayToggleItem = $null
if (-not $NoShow -and -not $Preview) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $tray = [System.Windows.Forms.NotifyIcon]::new()
        $agExe = "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe"
        $tray.Icon = if (Test-Path -LiteralPath $agExe) { [System.Drawing.Icon]::ExtractAssociatedIcon($agExe) } else { [System.Drawing.SystemIcons]::Application }
        $tray.Text = 'Antigravity Auto-Hub'
        $menu = [System.Windows.Forms.ContextMenuStrip]::new()
        $itemOpen = $menu.Items.Add((Get-HubText TrayOpen))
        $itemOpen.Font = [System.Drawing.Font]::new($itemOpen.Font, [System.Drawing.FontStyle]::Bold)
        $itemOpen.Add_Click({
            $window.Show()
            if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
            $window.Activate()
        })
        $itemScan = $menu.Items.Add((Get-HubText TrayScan))
        $itemScan.Add_Click({ Load-Accounts-UI -Reconcile })
        $cfgNow = if (Get-Command Get-HubConfig -ErrorAction SilentlyContinue) { Get-HubConfig } else { [pscustomobject]@{AutoRotationEnabled=$true} }
        $script:HubTrayToggleItem = $menu.Items.Add($(if ($cfgNow.AutoRotationEnabled) { Get-HubText BtnPauseRotation } else { Get-HubText BtnResumeRotation }))
        $script:HubTrayToggleItem.Add_Click({
            $c = Get-HubConfig; $c.AutoRotationEnabled = -not $c.AutoRotationEnabled; Save-HubConfig $c
            Update-HubSettingsUi; Load-Accounts-UI
        })
        $null = $menu.Items.Add('-')
        $itemExit = $menu.Items.Add((Get-HubText TrayExit))
        $itemExit.Add_Click({
            $script:HubForceExit = $true
            if ($script:HubTrayIcon) { $script:HubTrayIcon.Visible = $false; $script:HubTrayIcon.Dispose(); $script:HubTrayIcon = $null }
            $window.Close()
        })
        $itemStopAndExit = $menu.Items.Add("D$([char]0x1EEB)ng daemon & Tho$([char]0x00E1)t h$([char]0x1EB3)n")
        $itemStopAndExit.Add_Click({
            $null = Stop-AutoRotatorDaemon
            $script:HubForceExit = $true
            if ($script:HubTrayIcon) { $script:HubTrayIcon.Visible = $false; $script:HubTrayIcon.Dispose(); $script:HubTrayIcon = $null }
            $window.Close()
        })
        $tray.ContextMenuStrip = $menu
        $tray.Add_DoubleClick({
            $window.Show()
            if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
            $window.Activate()
        })
        $tray.Visible = $true
        $script:HubTrayIcon = $tray
        $script:HubTrayNotified = $false
        $window.Add_Closing({ param($s, $e)
            if (-not $script:HubForceExit -and $script:HubTrayIcon) {
                $e.Cancel = $true
                $window.Hide()
                if (-not $script:HubTrayNotified) {
                    $script:HubTrayNotified = $true
                    $script:HubTrayIcon.ShowBalloonTip(2000, 'Antigravity Auto-Hub', (Get-HubText TrayHiddenTip), [System.Windows.Forms.ToolTipIcon]::Info)
                }
            }
        })
    } catch {}
}
if (-not $NoShow) {
    try { $window.ShowDialog() | Out-Null }
    finally { if ($script:HubTrayIcon) { $script:HubTrayIcon.Visible = $false; $script:HubTrayIcon.Dispose() } }
}
