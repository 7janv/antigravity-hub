$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('work\installer clone '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$previousLocal=$env:LOCALAPPDATA
$previousId=$env:ANTIGRAVITY_GOOGLE_CLIENT_ID
$previousSecret=$env:ANTIGRAVITY_GOOGLE_CLIENT_SECRET
$systemRoot=$env:WINDIR
if (-not $systemRoot) { $systemRoot=$env:SystemRoot }
if (-not $systemRoot) { $systemRoot='C:\Windows' }
$powershellExe=Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Assert($Value,$Name) { if(-not $Value){throw $Name}; Write-Host "PASS: $Name" }

try {
    foreach($file in @('Setup.ps1','OAuthSetup.ps1')) { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $fixture }
    $env:LOCALAPPDATA=Join-Path $fixture 'local app data'
    $env:ANTIGRAVITY_GOOGLE_CLIENT_ID=$null; $env:ANTIGRAVITY_GOOGLE_CLIENT_SECRET=$null
    $install=Join-Path $env:LOCALAPPDATA 'Programs\Antigravity'
    New-Item -ItemType Directory -Path (Join-Path $install 'resources\bin') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $install 'Antigravity.exe'),'fixture, never executed')
    [IO.File]::WriteAllText((Join-Path $install 'resources\bin\language_server.exe'),"123456789012-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.apps.googleusercontent.com`0GOCSPX-"+('A'*28))
    # Substitute only external system/network dependencies. Run the real installer
    # and OAuth bootstrap in a separate Windows PowerShell 5.1 process.
    [IO.File]::WriteAllText((Join-Path $fixture 'AutoRotator.ps1'),@'
$geminiTokenPath=Join-Path $PSScriptRoot 'missing-token'
function Assert-AntigravityVersion { param($Version,$ExecutablePath) }
function Get-StoredCredential {
    if(Test-Path (Join-Path $PSScriptRoot 'no-login')){return $null}
    return '{"token":{"refresh_token":"fixture-refresh"}}'
}
function Invoke-RestMethod {
    param($Uri,$Method,$Body,$TimeoutSec,$ErrorAction)
    if(Test-Path (Join-Path $PSScriptRoot 'offline')){throw 'FixtureNetworkError'}
    return @{access_token='fixture-access';expires_in=3600}
}
function New-Object {
    param([string]$TypeName,[object[]]$ArgumentList,[string]$ComObject)
    if($ComObject){throw 'UnexpectedShortcutCreation'}
    Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}
function Start-Process { throw 'UnexpectedProcessStart' }
'@)
    $output=& $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'Setup.ps1') -ConfigureOnly 2>&1
    Assert ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $fixture 'oauth.local.clixml'))) 'Real installer configures a fresh clone without manual OAuth entry'
    Assert (($output -join "`n") -match 'ConfigureOnly' -and ($output -join "`n") -notmatch 'fixture-access|fixture-refresh|GOCSPX-') 'Configure-only installer stops before shortcuts and never prints credentials'
    [IO.File]::WriteAllText((Join-Path $fixture 'no-login'),'fixture')
    $output=& $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'Setup.ps1') 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'dang nhap Google tren MAY NAY' -and ($output -join "`n") -notmatch '\[3/5\]') 'Missing login stops real installer before shortcut or daemon creation'
    Remove-Item -LiteralPath (Join-Path $fixture 'no-login')
    [IO.File]::WriteAllText((Join-Path $fixture 'offline'),'fixture')
    $output=& $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'Setup.ps1') 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'Kiem tra mang/proxy/firewall' -and ($output -join "`n") -notmatch '\[3/5\]') 'Network failure stops real installer with actionable message'
    Remove-Item -LiteralPath (Join-Path $install 'Antigravity.exe')
    $output=& $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'Setup.ps1') 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'Cai Antigravity, dang nhap Google') 'Missing Antigravity is explained before OAuth setup'

    # Verify hardened 30s daemon interval & full System32 executable paths across setup and launchers
    $setupSrc=[IO.File]::ReadAllText((Join-Path $repo 'Setup.ps1'),[Text.Encoding]::UTF8)
    $setupBatSrc=[IO.File]::ReadAllText((Join-Path $repo 'Setup-Install.bat'),[Text.Encoding]::UTF8)
    $switchBatSrc=[IO.File]::ReadAllText((Join-Path $repo 'Chuyen-Doi-Tai-Khoan.bat'),[Text.Encoding]::UTF8)
    $daemonVbsSrc=[IO.File]::ReadAllText((Join-Path $repo 'launch-rotator-daemon.vbs'),[Text.Encoding]::UTF8)
    $switchVbsSrc=[IO.File]::ReadAllText((Join-Path $repo 'launch-switcher.vbs'),[Text.Encoding]::UTF8)
    $configOAuthSrc=[IO.File]::ReadAllText((Join-Path $repo 'Configure-OAuth.ps1'),[Text.Encoding]::UTF8)

    Assert ($setupSrc -match '-IntervalSeconds 30' -and $setupSrc -notmatch '-IntervalSeconds 25') 'Setup.ps1 configures 30s daemon interval'
    Assert ($daemonVbsSrc -match '-IntervalSeconds 30' -and $daemonVbsSrc -notmatch '-IntervalSeconds 25') 'launch-rotator-daemon.vbs configures 30s daemon interval'
    Assert ($setupSrc -match 'System32\\wscript\.exe' -and $setupSrc -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe' -and $setupSrc -notmatch 'TargetPath\s*=\s*"wscript\.exe"' -and $setupSrc -notmatch 'FileName\s*=\s*"powershell\.exe"') 'Setup.ps1 uses full System32 paths for wscript.exe and powershell.exe'
    Assert ($setupBatSrc -match '%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') 'Setup-Install.bat uses full System32 powershell.exe path'
    Assert ($switchBatSrc -match '%SystemRoot%\\System32\\wscript\.exe') 'Chuyen-Doi-Tai-Khoan.bat uses full System32 wscript.exe path'
    Assert ($daemonVbsSrc -match '%SystemRoot%' -and $daemonVbsSrc -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') 'launch-rotator-daemon.vbs uses full System32 powershell.exe path'
    Assert ($switchVbsSrc -match '%SystemRoot%' -and $switchVbsSrc -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') 'launch-switcher.vbs uses full System32 powershell.exe path'
    Assert ($configOAuthSrc -match 'SetAccessRuleProtection\(\$true,\s*\$false\)' -and $configOAuthSrc -match 'WindowsIdentity\]::GetCurrent\(\)\.User' -and $configOAuthSrc -match 'SetAccessControl') 'Configure-OAuth.ps1 enforces CurrentUser-only NTFS ACL on oauth.local.clixml'

    # Verify Build-Release.ps1 archive, release-manifest.json, and SHA256SUMS.txt in isolated temp dirs
    $mockRepo=Join-Path $fixture 'release-src'
    $mockDist=Join-Path $fixture 'release-dist'
    New-Item -ItemType Directory -Path (Join-Path $mockRepo 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mockRepo 'accounts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mockRepo '.backup') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mockRepo 'work') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mockRepo 'tests') -Force | Out-Null

    [IO.File]::WriteAllText((Join-Path $mockRepo 'AntigravityHub.ps1'),"# hub`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'SafeUpdater.ps1'),"# updater`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'MainWindow.xaml'),"<Window/>`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'DashboardText.vi.json'),"{}`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'Setup-Install.bat'),"@echo off`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'launch-switcher.vbs'),"WScript.Quit 0`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'README.md'),"# Hub`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'MCP.md'),"# MCP`n")
    [IO.File]::WriteAllText((Join-Path $mockRepo 'scripts\Build-Release.ps1'),"# builder`n")
    # State and non-managed files that MUST NEVER be packed
    [IO.File]::WriteAllText((Join-Path $mockRepo 'accounts\secret.json'),'{"token":"do-not-pack"}')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'oauth.local.clixml'),'<Objs/>')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'hub-config.json'),'{"PauseScanWhenIdeClosed":true}')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'rotation-state.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'current_active.txt'),'acc1')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'rotator.log'),'log')
    [IO.File]::WriteAllText((Join-Path $mockRepo '.hub-version.json'),'{"version":"v2.0.0"}')
    [IO.File]::WriteAllText((Join-Path $mockRepo '.login-backup.dpapi'),'secret')
    [IO.File]::WriteAllText((Join-Path $mockRepo '.backup\old.ps1'),'# old')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'work\scratch.txt'),'tmp')
    [IO.File]::WriteAllText((Join-Path $mockRepo 'tests\Fake.Tests.ps1'),'# test')

    $testSha=('a'*40)
    $buildScript=Join-Path $repo 'scripts\Build-Release.ps1'
    $buildResult=& $buildScript -Version 'v2.1.0-test' -CommitSha $testSha -RepoRoot $mockRepo -OutDir $mockDist
    Assert ((Test-Path -LiteralPath $buildResult.ArchivePath) -and (Test-Path -LiteralPath $buildResult.ManifestPath) -and (Test-Path -LiteralPath $buildResult.ChecksumsPath)) 'Build-Release.ps1 generates zip, release-manifest.json, and SHA256SUMS.txt'

    $manifestObj=[IO.File]::ReadAllText($buildResult.ManifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $actualArchiveSha=(Get-FileHash -LiteralPath $buildResult.ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $actualManifestSha=(Get-FileHash -LiteralPath $buildResult.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert ($manifestObj.schema_version -eq 1 -and $manifestObj.version -eq 'v2.1.0-test' -and $manifestObj.commit_sha -eq $testSha -and $manifestObj.archive_name -eq 'Antigravity-Auto-Hub-v2.1.0-test.zip' -and $manifestObj.archive_sha256 -eq $actualArchiveSha -and $manifestObj.built_at_utc -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z') 'release-manifest.json matches exact contract schema and archive SHA-256'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipReader=[IO.Compression.ZipFile]::OpenRead($buildResult.ArchivePath)
    try {
        $entryNames=@($zipReader.Entries | ForEach-Object { $_.FullName } | Sort-Object)
        $manifestNames=@($manifestObj.files.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        $sameSet=($entryNames.Count -eq $manifestNames.Count) -and (($entryNames -join '|') -eq ($manifestNames -join '|'))
        $noBadPaths=@($entryNames | Where-Object { $_ -like '*\*' -or $_ -like '/*' -or $_ -like '*..*' -or $_ -like 'accounts/*' -or $_ -like 'tests/*' -or $_ -like '.backup/*' -or $_ -like 'work/*' -or $_ -in @('oauth.local.clixml','hub-config.json','rotation-state.json','current_active.txt','rotator.log','.hub-version.json','.login-backup.dpapi') }).Count -eq 0
        Assert ($sameSet -and $noBadPaths -and ('scripts/Build-Release.ps1' -in $entryNames) -and ('AntigravityHub.ps1' -in $entryNames)) 'Release archive contains exact forward-slash managed files and excludes all local state'
    } finally {
        $zipReader.Dispose()
    }

    $sumsLines=@([IO.File]::ReadAllLines($buildResult.ChecksumsPath,[Text.Encoding]::UTF8) | Where-Object { $_.Length -gt 0 })
    Assert ($sumsLines.Count -eq 2 -and $sumsLines[0] -ceq "$actualArchiveSha  Antigravity-Auto-Hub-v2.1.0-test.zip" -and $sumsLines[1] -ceq "$actualManifestSha  release-manifest.json") 'SHA256SUMS.txt matches exact two-space format and checksums for archive and manifest'

    $badVersionRejected=$false
    try { & $buildScript -Version '../bad' -CommitSha $testSha -RepoRoot $mockRepo -OutDir $mockDist | Out-Null } catch { $badVersionRejected=$true }
    Assert $badVersionRejected 'Build-Release.ps1 rejects invalid version strings'

    # Verify Uninstall.ps1 in isolated temp directories (WhatIf, preserve data, PurgeData)
    $uBase=Join-Path $fixture 'uninstall-base'
    $uStartup=Join-Path $fixture 'uninstall-startup'
    $uDesktop=Join-Path $fixture 'uninstall-desktop'
    New-Item -ItemType Directory -Path (Join-Path $uBase 'accounts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $uBase '.backup\20260101') -Force | Out-Null
    New-Item -ItemType Directory -Path $uStartup -Force | Out-Null
    New-Item -ItemType Directory -Path $uDesktop -Force | Out-Null
    $uStartupLnk=Join-Path $uStartup 'AntigravityAutoRotator.lnk'
    $uDesktopLnk=Join-Path $uDesktop 'Antigravity Auto-Hub.lnk'
    [IO.File]::WriteAllText($uStartupLnk,'lnk')
    [IO.File]::WriteAllText($uDesktopLnk,'lnk')
    [IO.File]::WriteAllText((Join-Path $uBase '.backup\20260101\AntigravityHub.ps1'),'backup')
    [IO.File]::WriteAllText((Join-Path $uBase '.login-backup.dpapi'),'dpapi')
    [IO.File]::WriteAllText((Join-Path $uBase 'accounts\user1.json'),'{"format":"dpapi-v1"}')
    [IO.File]::WriteAllText((Join-Path $uBase 'hub-config.json'),'{"PauseScanWhenIdeClosed":true}')
    [IO.File]::WriteAllText((Join-Path $uBase 'oauth.local.clixml'),'<Objs/>')

    $uninstallScript=Join-Path $repo 'Uninstall.ps1'
    & $uninstallScript -BaseDir $uBase -StartupDir $uStartup -DesktopDir $uDesktop -WhatIf | Out-Null
    Assert ((Test-Path -LiteralPath $uStartupLnk) -and (Test-Path -LiteralPath $uDesktopLnk) -and (Test-Path -LiteralPath (Join-Path $uBase '.backup'))) 'Uninstall.ps1 -WhatIf does not delete shortcuts or backups'

    & $uninstallScript -BaseDir $uBase -StartupDir $uStartup -DesktopDir $uDesktop | Out-Null
    Assert ((-not (Test-Path -LiteralPath $uStartupLnk)) -and (-not (Test-Path -LiteralPath $uDesktopLnk)) -and (-not (Test-Path -LiteralPath (Join-Path $uBase '.backup'))) -and (-not (Test-Path -LiteralPath (Join-Path $uBase '.login-backup.dpapi')))) 'Uninstall.ps1 removes Startup/Desktop shortcuts and internal backups'
    Assert ((Test-Path -LiteralPath (Join-Path $uBase 'accounts\user1.json')) -and (Test-Path -LiteralPath (Join-Path $uBase 'hub-config.json')) -and (Test-Path -LiteralPath (Join-Path $uBase 'oauth.local.clixml'))) 'Uninstall.ps1 preserves accounts/, hub-config.json, and oauth.local.clixml by default'

    & $uninstallScript -BaseDir $uBase -StartupDir $uStartup -DesktopDir $uDesktop -PurgeData | Out-Null
    Assert ((-not (Test-Path -LiteralPath (Join-Path $uBase 'accounts'))) -and (-not (Test-Path -LiteralPath (Join-Path $uBase 'hub-config.json'))) -and (-not (Test-Path -LiteralPath (Join-Path $uBase 'oauth.local.clixml')))) 'Uninstall.ps1 -PurgeData removes accounts/, hub-config.json, and oauth.local.clixml'
} finally {
    $env:LOCALAPPDATA=$previousLocal
    $env:ANTIGRAVITY_GOOGLE_CLIENT_ID=$previousId; $env:ANTIGRAVITY_GOOGLE_CLIENT_SECRET=$previousSecret
    $resolved=[IO.Path]::GetFullPath($fixture)
    $workRoot=[IO.Path]::GetFullPath((Join-Path $repo 'work'))
    $allowedRoot=$workRoot+'\'
    if($resolved.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^installer clone [a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    if ((Test-Path -LiteralPath $workRoot -PathType Container) -and (@(Get-ChildItem -LiteralPath $workRoot -Force).Count -eq 0)) {
        Remove-Item -LiteralPath $workRoot -Force
    }
}
