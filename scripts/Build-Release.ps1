# ==============================================================================
# ANTIGRAVITY AUTO-HUB - SAFE RELEASE PACKAGER
# Produces archive, release-manifest.json, and SHA256SUMS.txt for GitHub Releases
# ==============================================================================
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$CommitSha,
    [string]$RepoRoot,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^v?\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?\z' -or $Version.Contains('..')) {
    throw "Invalid semver Version: $Version"
}

if (-not $RepoRoot) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $RepoRoot = Split-Path $scriptDir -Parent
}
$resolvedRoot = [IO.Path]::GetFullPath($RepoRoot)
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "RepoRoot does not exist: $resolvedRoot"
}

if (-not $OutDir) {
    $OutDir = Join-Path $resolvedRoot 'dist'
}
$resolvedOut = [IO.Path]::GetFullPath($OutDir)

if (-not $CommitSha) {
    $gitOutput = & git -C $resolvedRoot rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to determine CommitSha via git rev-parse HEAD: $($gitOutput -join ' ')"
    }
    $CommitSha = ($gitOutput | Select-Object -First 1).ToString().Trim()
}
$CommitSha = $CommitSha.Trim().ToLowerInvariant()
if ($CommitSha -notmatch '^[0-9a-f]{40}\z') {
    throw "Invalid 40-char lowercase hex CommitSha: $CommitSha"
}

function Get-FileSha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hashBytes = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Test-ExcludedRelativePath {
    param([string]$RelPath)
    if ([string]::IsNullOrWhiteSpace($RelPath)) { return $true }
    if ($RelPath.StartsWith('/') -or $RelPath.Contains('\') -or $RelPath.Contains('..')) { return $true }
    $lower = $RelPath.ToLowerInvariant()
    $excludedPrefixes = @('accounts/', '.backup/', 'dist/', 'work/', '.git/', '.github/', 'tests/', 'backups/')
    foreach ($prefix in $excludedPrefixes) {
        if ($lower.StartsWith($prefix)) { return $true }
    }
    $excludedExact = @(
        'oauth.local.clixml', 'hub-config.json', 'rotation-state.json',
        'current_active.txt', 'rotator.log', '.hub-version.json', '.hub-version',
        '.login-backup.dpapi', 'handoff.md', '.env'
    )
    if ($lower -in $excludedExact) { return $true }
    if ($lower -match '\.(tmp|log|clixml|pem|key|p12|pfx|bundle|dpapi)\z') { return $true }
    return $false
}

# Collect strictly managed release files defined in the release contract.
$candidateFiles = New-Object System.Collections.Generic.List[object]

foreach ($pattern in @('*.ps1', '*.bat', '*.vbs')) {
    foreach ($f in @(Get-ChildItem -LiteralPath $resolvedRoot -Filter $pattern -File | Sort-Object Name)) {
        $candidateFiles.Add([pscustomobject]@{ RelPath = $f.Name; FullName = $f.FullName })
    }
}

foreach ($fixed in @('MainWindow.xaml', 'DashboardText.vi.json', 'README.md', 'MCP.md')) {
    $full = Join-Path $resolvedRoot $fixed
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $candidateFiles.Add([pscustomobject]@{ RelPath = $fixed; FullName = $full })
    }
}

$scriptsDir = Join-Path $resolvedRoot 'scripts'
if (Test-Path -LiteralPath $scriptsDir -PathType Container) {
    foreach ($f in @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -File | Sort-Object Name)) {
        $candidateFiles.Add([pscustomobject]@{ RelPath = "scripts/$($f.Name)"; FullName = $f.FullName })
    }
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$managedFiles = New-Object System.Collections.Generic.List[object]
foreach ($item in $candidateFiles) {
    if (Test-ExcludedRelativePath $item.RelPath) {
        throw "Excluded or unsafe release path detected: $($item.RelPath)"
    }
    if (-not $seen.Add($item.RelPath)) { continue }
    $managedFiles.Add($item)
}

if ($managedFiles.Count -eq 0) {
    throw "No managed release files found in $resolvedRoot"
}

$sortedFiles = @($managedFiles | Sort-Object -Property @{ Expression = { $_.RelPath } })

if (-not (Test-Path -LiteralPath $resolvedOut -PathType Container)) {
    New-Item -ItemType Directory -Path $resolvedOut -Force | Out-Null
}

$archiveName = "Antigravity-Auto-Hub-$Version.zip"
$archivePath = Join-Path $resolvedOut $archiveName
$manifestName = 'release-manifest.json'
$manifestPath = Join-Path $resolvedOut $manifestName
$checksumsPath = Join-Path $resolvedOut 'SHA256SUMS.txt'

if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fileHashes = [ordered]@{}
$zip = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($item in $sortedFiles) {
        $sha256 = Get-FileSha256Lower -Path $item.FullName
        $fileHashes[$item.RelPath] = $sha256
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $item.FullName,
            $item.RelPath,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
} finally {
    $zip.Dispose()
}

$archiveSha256 = Get-FileSha256Lower -Path $archivePath
$builtAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)

$manifest = [ordered]@{
    schema_version = 1
    version        = $Version
    commit_sha     = $CommitSha
    built_at_utc   = $builtAtUtc
    archive_name   = $archiveName
    archive_sha256 = $archiveSha256
    files          = $fileHashes
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$manifestJson = ($manifest | ConvertTo-Json -Depth 6) + "`n"
[IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

$manifestSha256 = Get-FileSha256Lower -Path $manifestPath
$sumsText = "$archiveSha256  $archiveName`n$manifestSha256  $manifestName`n"
[IO.File]::WriteAllText($checksumsPath, $sumsText, $utf8NoBom)

[pscustomobject]@{
    Version        = $Version
    CommitSha      = $CommitSha
    BuiltAtUtc     = $builtAtUtc
    ArchiveName    = $archiveName
    ArchivePath    = $archivePath
    ArchiveSha256  = $archiveSha256
    ManifestPath   = $manifestPath
    ManifestSha256 = $manifestSha256
    ChecksumsPath  = $checksumsPath
    FileCount      = $sortedFiles.Count
}
