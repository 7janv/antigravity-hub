$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'SafeUpdater.ps1')

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $err = $null
    try { & $Action | Out-Null } catch { $err = $_.Exception.Message }
    Assert ($null -ne $err -and $err -match $Pattern) "$Name (got: $err)"
}

function New-ZipFromMap {
    param([string]$ZipPath, [hashtable]$Entries)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($key in $Entries.Keys) {
            $entry = $zip.CreateEntry($key)
            $stream = $entry.Open()
            try {
                $val = $Entries[$key]
                $bytes = if ($val -is [byte[]]) { $val } else { [Text.UTF8Encoding]::new($false).GetBytes([string]$val) }
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function New-FixtureRelease {
    param(
        [string]$RootDir,
        [string]$Version = 'v2.1.0',
        [string]$CommitSha = ('a' * 40),
        [hashtable]$Files = @{
            'AntigravityHub.ps1'       = "# v2.1.0 hub`nWrite-Output 'ok'`n"
            'Dashboard.ps1'            = "# v2.1.0 dashboard`n`$u = 'https://api.github.com/repos/7janv/antigravity-hub/releases/latest'`n"
            'scripts/Build-Release.ps1' = "# v2.1.0 builder`nWrite-Output 'build'`n"
        },
        [hashtable]$ExtraZipEntries = @{}
    )
    $archiveName = "Antigravity-Auto-Hub-$Version.zip"
    $zipPath = Join-Path $RootDir $archiveName
    $zipMap = @{}
    $fileHashes = [ordered]@{}
    foreach ($k in $Files.Keys) {
        $zipMap[$k] = $Files[$k]
        $bytes = if ($Files[$k] -is [byte[]]) { $Files[$k] } else { [Text.UTF8Encoding]::new($false).GetBytes([string]$Files[$k]) }
        $fileHashes[$k] = Get-BytesSha256Hex $bytes
    }
    foreach ($k in $ExtraZipEntries.Keys) { $zipMap[$k] = $ExtraZipEntries[$k] }
    New-ZipFromMap -ZipPath $zipPath -Entries $zipMap
    $archiveSha = Get-FileSha256Hex $zipPath
    $manifestObj = [ordered]@{
        schema_version = 1
        version        = $Version
        commit_sha     = $CommitSha
        built_at_utc   = '2026-11-24T00:00:00Z'
        archive_name   = $archiveName
        archive_sha256 = $archiveSha
        files          = $fileHashes
    }
    $manifestJson = $manifestObj | ConvertTo-Json -Depth 6
    $manifestPath = Join-Path $RootDir 'release-manifest.json'
    [IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))
    $manifestSha = Get-FileSha256Hex $manifestPath
    $sumsText = "$archiveSha  $archiveName`n$manifestSha  release-manifest.json`n"
    $sumsPath = Join-Path $RootDir 'SHA256SUMS.txt'
    [IO.File]::WriteAllText($sumsPath, $sumsText, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        ZipPath      = $zipPath
        ManifestPath = $manifestPath
        ManifestJson = $manifestJson
        ManifestObj  = ($manifestJson | ConvertFrom-Json)
        ManifestSha  = $manifestSha
        ArchiveName  = $archiveName
        ArchiveSha   = $archiveSha
        SumsPath     = $sumsPath
        SumsText     = $sumsText
    }
}

$workRoot = Join-Path $repo ('work\updater-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

try {
    # 1. URL allowlist checks
    foreach ($good in @(
        @('https://api.github.com/repos/7janv/antigravity-hub/releases/latest', 'Api'),
        @('https://api.github.com/repos/7janv/antigravity-hub/releases/tags/v2.1.0', 'Api'),
        @('https://github.com/7janv/antigravity-hub/releases/download/v2.1.0/Antigravity-Auto-Hub-v2.1.0.zip', 'Asset'),
        @('https://objects.githubusercontent.com/github-production-release-asset-2e65be/12345', 'Asset'),
        @('https://release-assets.githubusercontent.com/github-production-release-asset/67890', 'Asset'),
        @('https://github.com/7janv/antigravity-hub/compare/v2.0.0...v2.1.0', 'Compare'),
        @('https://github.com/7janv/antigravity-hub/compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'Compare')
    )) {
        Assert (Test-AllowedReleaseUrl -Url $good[0] -Kind $good[1]) "Allowlisted $($good[1]) URL accepted: $($good[0])"
    }
    foreach ($bad in @(
        'http://api.github.com/repos/7janv/antigravity-hub/releases/latest',
        'https://api.github.com/repos/other-owner/other-repo/commits/main',
        'https://github.com/other-owner/other-repo/releases/download/v2.1.0/foo.zip',
        'https://github.com/7janv/antigravity-hub/archive/refs/heads/main.zip',
        'https://github.com/7janv/antigravity-hub-evil/releases/download/v1.0.0/x.zip',
        'https://github.com:444/7janv/antigravity-hub/compare/v1.0.0...v2.0.0',
        'https://user@github.com/7janv/antigravity-hub/compare/v1.0.0...v2.0.0',
        'https://github.com/7janv/antigravity-hub/compare/../../evil/repo',
        'https://evil.test/release.zip',
        ''
    )) {
        Assert (-not (Test-AllowedReleaseUrl -Url $bad -Kind 'Any')) "Untrusted URL rejected: $bad"
    }

    # 2. Manifest schema and SHA256SUMS parsing checks
    $validDir = Join-Path $workRoot 'valid'
    New-Item -ItemType Directory -Path $validDir -Force | Out-Null
    $rel = New-FixtureRelease -RootDir $validDir
    Assert (Test-SafeReleaseManifest -Manifest $rel.ManifestObj) 'Valid release manifest passes schema validation'
    $parsedSums = Parse-Sha256Sums -Content $rel.SumsText -ExpectedArchiveName $rel.ArchiveName -ExpectedArchiveSha256 $rel.ArchiveSha -ExpectedManifestSha256 $rel.ManifestSha
    Assert ($parsedSums[$rel.ArchiveName] -ceq $rel.ArchiveSha -and $parsedSums['release-manifest.json'] -ceq $rel.ManifestSha) 'SHA256SUMS parses and cross-checks archive and manifest hashes'

    $badSchema = $rel.ManifestJson | ConvertFrom-Json; $badSchema.schema_version = 2
    Assert (-not (Test-SafeReleaseManifest -Manifest $badSchema)) 'Rejects unsupported schema_version'
    $badSha = $rel.ManifestJson | ConvertFrom-Json; $badSha.commit_sha = 'A' * 40
    Assert (-not (Test-SafeReleaseManifest -Manifest $badSha)) 'Rejects uppercase/invalid commit_sha'
    $badPath = [ordered]@{ schema_version = 1; version = 'v2.1.0'; commit_sha = ('a' * 40); built_at_utc = '2026-11-24T00:00:00Z'; archive_name = 'a.zip'; archive_sha256 = ('b' * 64); files = @{ 'accounts/stolen.json' = ('c' * 64) } }
    Assert (-not (Test-SafeReleaseManifest -Manifest $badPath)) 'Rejects manifest attempting to overwrite preserved accounts/ path'
    $badExe = [ordered]@{ schema_version = 1; version = 'v2.1.0'; commit_sha = ('a' * 40); built_at_utc = '2026-11-24T00:00:00Z'; archive_name = 'a.zip'; archive_sha256 = ('b' * 64); files = @{ 'dropper.exe' = ('c' * 64) } }
    Assert (-not (Test-SafeReleaseManifest -Manifest $badExe)) 'Rejects manifest containing disallowed .exe file'
    $badTrav = [ordered]@{ schema_version = 1; version = 'v2.1.0'; commit_sha = ('a' * 40); built_at_utc = '2026-11-24T00:00:00Z'; archive_name = 'a.zip'; archive_sha256 = ('b' * 64); files = @{ '../escape.ps1' = ('c' * 64) } }
    Assert (-not (Test-SafeReleaseManifest -Manifest $badTrav)) 'Rejects manifest containing path traversal'
    Assert-Throws { Parse-Sha256Sums -Content "bad-line" } 'UpdaterInvalidChecksums' 'Rejects malformed SHA256SUMS line'
    Assert-Throws { Parse-Sha256Sums -Content $rel.SumsText -ExpectedArchiveName $rel.ArchiveName -ExpectedArchiveSha256 ('0' * 64) } 'UpdaterArchiveChecksumMismatch' 'Rejects archive checksum mismatch in SHA256SUMS'

    # 3. Valid end-to-end staged extract + install preserving local state
    $stageOk = Join-Path $workRoot 'stage-ok'
    $installDir = Join-Path $workRoot 'install-ok'
    New-Item -ItemType Directory -Path (Join-Path $installDir 'accounts') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $installDir 'AntigravityHub.ps1'), '# old hub')
    [IO.File]::WriteAllText((Join-Path $installDir 'Dashboard.ps1'), '# old dashboard')
    [IO.File]::WriteAllText((Join-Path $installDir 'accounts\alice.json'), '{"format":"dpapi-v1","protected_payload":"KEEP"}')
    [IO.File]::WriteAllText((Join-Path $installDir 'hub-config.json'), '{"MinQuotaPercent":25}')
    [IO.File]::WriteAllText((Join-Path $installDir 'oauth.local.clixml'), '<clixml>KEEP</clixml>')
    [IO.File]::WriteAllText((Join-Path $installDir '.hub-version'), ('1' * 40))

    $legacyInfo = Get-HubVersionInfo -BaseDir $installDir
    Assert ($legacyInfo.Source -eq 'Legacy' -and $legacyInfo.CommitSha -ceq ('1' * 40)) 'Reads legacy .hub-version fallback'

    $expanded = Expand-VerifiedReleaseArchive -ArchivePath $rel.ZipPath -Manifest $rel.ManifestPath -StagingDir $stageOk -Checksums $rel.SumsPath
    Assert ($expanded.FileCount -eq 3 -and $expanded.Version -ceq 'v2.1.0') 'Valid archive passes SHA-256, 1-to-1 file hashes, and security gate'

    $installed = Install-VerifiedHubRelease -StagingDir $stageOk -Manifest $rel.ManifestObj -BaseDir $installDir
    Assert ($installed.Version -ceq 'v2.1.0' -and (Test-Path -LiteralPath $installed.BackupDir)) 'Install creates backup and applies verified files'
    Assert (([IO.File]::ReadAllText((Join-Path $installDir 'AntigravityHub.ps1'))) -match 'v2.1.0 hub') 'Managed root script updated'
    Assert (([IO.File]::ReadAllText((Join-Path $installDir 'scripts\Build-Release.ps1'))) -match 'v2.1.0 builder') 'Managed nested script updated'
    Assert (([IO.File]::ReadAllText((Join-Path $installed.BackupDir 'AntigravityHub.ps1'))) -eq '# old hub') 'Previous file backed up in .backup'
    Assert (([IO.File]::ReadAllText((Join-Path $installDir 'accounts\alice.json'))) -match 'KEEP') 'accounts/ preserved untouched'
    Assert (([IO.File]::ReadAllText((Join-Path $installDir 'hub-config.json'))) -match '25') 'hub-config.json preserved untouched'
    Assert (([IO.File]::ReadAllText((Join-Path $installDir 'oauth.local.clixml'))) -match 'KEEP') 'oauth.local.clixml preserved untouched'
    $newInfo = Get-HubVersionInfo -BaseDir $installDir
    Assert ($newInfo.Source -eq 'Json' -and $newInfo.Version -ceq 'v2.1.0' -and $newInfo.CommitSha -ceq ('a' * 40) -and $newInfo.InstalledAtUtc.EndsWith('Z')) 'Writes and reads .hub-version.json accurately'

    # 4. Tampered archive SHA-256 rejected
    $tamperedZip = Join-Path $workRoot 'tampered.zip'
    $origZipBytes = [IO.File]::ReadAllBytes($rel.ZipPath)
    $tampBytes = New-Object byte[] ($origZipBytes.Length + 1)
    [Array]::Copy($origZipBytes, $tampBytes, $origZipBytes.Length)
    $tampBytes[$tampBytes.Length - 1] = 0x00
    [IO.File]::WriteAllBytes($tamperedZip, $tampBytes)
    Assert-Throws {
        Expand-VerifiedReleaseArchive -ArchivePath $tamperedZip -Manifest $rel.ManifestObj -StagingDir (Join-Path $workRoot 'stage-tamp-arch') -Checksums $parsedSums
    } 'UpdaterArchiveHashMismatch' 'Tampered archive SHA-256 rejected'

    # 5. Tampered per-file SHA-256 rejected (archive hash matches manifest, but one file hash mismatches)
    $badFileDir = Join-Path $workRoot 'bad-file'
    New-Item -ItemType Directory -Path $badFileDir -Force | Out-Null
    $badFileRel = New-FixtureRelease -RootDir $badFileDir
    $badFileManifest = $badFileRel.ManifestJson | ConvertFrom-Json
    $badFileManifest.files.'Dashboard.ps1' = 'f' * 64
    Assert-Throws {
        Expand-VerifiedReleaseArchive -ArchivePath $badFileRel.ZipPath -Manifest $badFileManifest -StagingDir (Join-Path $workRoot 'stage-bad-file')
    } 'UpdaterFileHashMismatch' 'Tampered per-file SHA-256 rejected'

    # 6. Extra unmanifested file in archive rejected
    $extraDir = Join-Path $workRoot 'extra-file'
    New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
    $extraRel = New-FixtureRelease -RootDir $extraDir -ExtraZipEntries @{ 'sneaky.ps1' = '# sneaky' }
    Assert-Throws {
        Expand-VerifiedReleaseArchive -ArchivePath $extraRel.ZipPath -Manifest $extraRel.ManifestObj -StagingDir (Join-Path $workRoot 'stage-extra')
    } 'UpdaterUnexpectedArchiveEntry' 'Extra unmanifested file in archive rejected'

    # 7. Missing manifested file in archive rejected
    $missingDir = Join-Path $workRoot 'missing-file'
    New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
    $missingRel = New-FixtureRelease -RootDir $missingDir -Files @{ 'AntigravityHub.ps1' = '# only one' }
    $missingManifest = $missingRel.ManifestJson | ConvertFrom-Json
    $missingManifest.files | Add-Member -NotePropertyName 'Dashboard.ps1' -NotePropertyValue ('d' * 64)
    Assert-Throws {
        Expand-VerifiedReleaseArchive -ArchivePath $missingRel.ZipPath -Manifest $missingManifest -StagingDir (Join-Path $workRoot 'stage-missing')
    } 'UpdaterMissingManifestFile' 'Missing manifested file rejected'

    # 8. Zip-Slip archive rejected (entry ..\..\evil.ps1 and ../../evil.ps1)
    $slipDir = Join-Path $workRoot 'zip-slip'
    New-Item -ItemType Directory -Path $slipDir -Force | Out-Null
    $slipRel = New-FixtureRelease -RootDir $slipDir -ExtraZipEntries @{ '../../evil.ps1' = '# pwned' }
    $slipStage = Join-Path $workRoot 'stage-slip\nested'
    Assert-Throws {
        Expand-VerifiedReleaseArchive -ArchivePath $slipRel.ZipPath -Manifest $slipRel.ManifestObj -StagingDir $slipStage
    } 'UpdaterZipSlipBlocked' 'Zip-Slip ../../evil.ps1 archive rejected'
    Assert (-not (Test-Path -LiteralPath (Join-Path $workRoot 'evil.ps1'))) 'Zip-Slip never writes outside staging directory'

    # 9. Static security gate checks
    $gateCases = @(
        @{ Name = 'Disallowed .exe'; File = 'tool.exe'; Content = 'MZ' },
        @{ Name = 'DownloadString pattern'; File = 'Mod.ps1'; Content = '$wc.' + 'Download' + 'String("https://accounts.google.com")' },
        @{ Name = 'Invoke-Expression in production'; File = 'Mod.ps1'; Content = 'Invoke-' + 'Expression "1+1"' },
        @{ Name = 'iex alias in production'; File = 'Mod.ps1'; Content = 'i' + 'ex "1+1"' },
        @{ Name = 'EncodedCommand pattern'; File = 'Mod.ps1'; Content = 'powershell -Encoded' + 'Command AAA=' },
        @{ Name = 'Base64 decode outside DPAPI'; File = 'Mod.ps1'; Content = '[Convert]::' + 'FromBase64' + 'String("YWJj")' },
        @{ Name = 'ObjectDataProvider in XAML'; File = 'MainWindow.xaml'; Content = '<Window><' + 'ObjectData' + 'Provider/></Window>' },
        @{ Name = 'BiDi RLO Unicode'; File = 'MainWindow.xaml'; Content = '<Window Title="a' + [char]0x202E + 'b"/>' },
        @{ Name = 'Non-ASCII in .ps1'; File = 'Mod.ps1'; Content = "# " + [char]0x00E9 },
        @{ Name = 'Unauthorized external URL'; File = 'Mod.ps1'; Content = '$u = "https://evil.test/dropper"' },
        @{ Name = 'Unauthorized repo URL'; File = 'Mod.ps1'; Content = '$u = "https://github.com/other-owner/other-repo.git"' },
        @{ Name = 'Mutable refs/heads archive URL'; File = 'Mod.ps1'; Content = '$u = "https://github.com/7janv/antigravity-hub/archive/refs/heads/main.zip"' }
    )
    $caseIdx = 0
    foreach ($tc in $gateCases) {
        $caseIdx++
        $gDir = Join-Path $workRoot "gate-$caseIdx"
        New-Item -ItemType Directory -Path $gDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $gDir $tc.File), $tc.Content, [Text.UTF8Encoding]::new($false))
        Assert (-not (Test-StagedReleaseSecurity -StagingDir $gDir)) "Static gate rejects: $($tc.Name)"
    }

    # Verify SafeUpdater.ps1 itself and DPAPI ProtectedData::Unprotect in RotationCore.ps1 pass the static gate!
    $selfStage = Join-Path $workRoot 'gate-self'
    New-Item -ItemType Directory -Path $selfStage -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'SafeUpdater.ps1') -Destination $selfStage
    $dpapiSample = @(
        'function Unprotect-AccountPayload { param([string]$Payload)'
        '    $bytes = [Convert]::' + 'FromBase64' + 'String($Payload)'
        '    return [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)'
        '}'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $selfStage 'RotationCore.ps1'), $dpapiSample, [Text.UTF8Encoding]::new($false))
    Assert (Test-StagedReleaseSecurity -StagingDir $selfStage) 'SafeUpdater.ps1 itself and DPAPI Unprotect in RotationCore.ps1 pass static gate'

    # 10. Automatic rollback on mid-way install failure
    $rbInstall = Join-Path $workRoot 'install-rollback'
    New-Item -ItemType Directory -Path $rbInstall -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $rbInstall 'AntigravityHub.ps1'), '# original hub')
    [IO.File]::WriteAllText((Join-Path $rbInstall 'Dashboard.ps1'), '# original dashboard')
    [IO.File]::WriteAllText((Join-Path $rbInstall '.hub-version.json'), '{"version":"v2.0.0","commit_sha":"' + ('1' * 40) + '","installed_at_utc":"2026-10-01T00:00:00Z"}')
    $script:CopyCount = 0
    Assert-Throws {
        Install-VerifiedHubRelease -StagingDir $stageOk -Manifest $rel.ManifestObj -BaseDir $rbInstall -CopyHook {
            param($relPath, $src, $dst)
            $script:CopyCount++
            if ($script:CopyCount -eq 2) { throw 'SimulatedMidInstallWriteFailure' }
            [IO.File]::Copy($src, $dst, $true)
        }
    } 'SimulatedMidInstallWriteFailure' 'Mid-way install failure surfaces error'
    Assert (([IO.File]::ReadAllText((Join-Path $rbInstall 'AntigravityHub.ps1'))) -eq '# original hub') 'Rollback restores first overwritten file from .backup'
    Assert (([IO.File]::ReadAllText((Join-Path $rbInstall 'Dashboard.ps1'))) -eq '# original dashboard') 'Rollback preserves second file untouched'
    Assert (-not (Test-Path -LiteralPath (Join-Path $rbInstall 'scripts\Build-Release.ps1'))) 'Rollback cleans up newly created files'
    Assert ((Get-HubVersionInfo -BaseDir $rbInstall).Version -ceq 'v2.0.0') 'Rollback leaves .hub-version.json at previous version'

    # 11. Mocked Get-AvailableHubRelease end-to-end check
    $script:MockManifestBytes = [IO.File]::ReadAllBytes($rel.ManifestPath)
    $script:MockSumsBytes = [IO.File]::ReadAllBytes($rel.SumsPath)
    $script:MockReleaseJson = (@{
        tag_name   = 'v2.1.0'
        draft      = $false
        prerelease = $false
        body       = "Release notes" + [char]0x202E + " clean"
        assets     = @(
            @{ name = 'release-manifest.json'; browser_download_url = 'https://github.com/7janv/antigravity-hub/releases/download/v2.1.0/release-manifest.json' },
            @{ name = 'SHA256SUMS.txt'; browser_download_url = 'https://github.com/7janv/antigravity-hub/releases/download/v2.1.0/SHA256SUMS.txt' },
            @{ name = $rel.ArchiveName; browser_download_url = "https://github.com/7janv/antigravity-hub/releases/download/v2.1.0/$($rel.ArchiveName)" }
        )
    } | ConvertTo-Json -Depth 6)
    function Invoke-SafeReleaseHttpDownload {
        param($Url, $Kind, $OutFile, $TimeoutMs, $MaxBytes)
        if ($Url -like '*/releases/latest') { return [Text.Encoding]::UTF8.GetBytes($script:MockReleaseJson) }
        if ($Url -like '*release-manifest.json') { return $script:MockManifestBytes }
        if ($Url -like '*SHA256SUMS.txt') { return $script:MockSumsBytes }
        throw "UnexpectedMockUrl:$Url"
    }
    $avail = Get-AvailableHubRelease -BaseDir $rbInstall
    Assert ($avail.HasUpdate -and $avail.LatestVersion -ceq 'v2.1.0' -and $avail.CompareUrl -ceq "https://github.com/7janv/antigravity-hub/compare/$('1' * 40)...$('a' * 40)") 'Get-AvailableHubRelease returns verified update metadata and allowlisted compare URL'
    Assert ($avail.ReleaseNotes -ceq 'Release notes clean') 'Release notes strip BiDi control characters'
    $alreadyLatest = Get-AvailableHubRelease -BaseDir $installDir
    Assert (-not $alreadyLatest.HasUpdate) 'Matching version and commit SHA reports already up to date'

    # 12. Scoped daemon matching
    $dirA = 'C:\Users\Test\Hub A'
    $dirB = 'C:\Users\Test\Hub B'
    Assert (Test-IsScopedDaemonCommandLine -CommandLine "powershell.exe -NoProfile -File `"$dirA\AutoRotator.ps1`" -Daemon -IntervalSeconds 30" -BaseDir $dirA -RequireDaemonFlag) 'Scoped daemon matcher accepts exact directory daemon'
    Assert (-not (Test-IsScopedDaemonCommandLine -CommandLine "powershell.exe -NoProfile -File `"$dirB\AutoRotator.ps1`" -Daemon -IntervalSeconds 30" -BaseDir $dirA -RequireDaemonFlag)) 'Scoped daemon matcher ignores AutoRotator.ps1 from another directory'
    Assert (-not (Test-IsScopedDaemonCommandLine -CommandLine "powershell.exe -NoProfile -File `"$dirA\AutoRotator.ps1.bak`" -Daemon" -BaseDir $dirA -RequireDaemonFlag)) 'Scoped daemon matcher rejects suffix-collision filename'
    Assert (-not (Test-IsScopedDaemonCommandLine -CommandLine "powershell.exe -NoProfile -File `"$dirA\AutoRotator.ps1`"" -BaseDir $dirA -RequireDaemonFlag)) 'Scoped daemon matcher requires -Daemon flag when requested'

    Write-Host 'ALL UPDATER TESTS PASSED'
} finally {
    $resolved = [IO.Path]::GetFullPath($workRoot)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $repo 'work')) + '\'
    if ($resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^updater-test-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
