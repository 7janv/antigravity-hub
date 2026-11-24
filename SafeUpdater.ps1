# Safe Release Updater for 7janv/antigravity-hub (GitHub Releases + SHA-256 + static gate).
# Pure ASCII script. Verifies immutable release manifests, checksums, and staged files.

$script:SafeUpdaterOwner = '7janv'
$script:SafeUpdaterRepo = 'antigravity-hub'
$script:SafeUpdaterLatestReleaseApi = 'https://api.github.com/repos/7janv/antigravity-hub/releases/latest'
$script:SafeUpdaterCompareBaseUrl = 'https://github.com/7janv/antigravity-hub/compare'
$script:SafeUpdaterPreservedPaths = @(
    'accounts', 'oauth.local.clixml', 'hub-config.json', 'rotation-state.json',
    'current_active.txt', 'rotator.log', '.hub-version.json', '.hub-version',
    '.backup', 'dist', 'work', '.git', '.login-backup.dpapi', 'backups'
)
$script:SafeUpdaterDisallowedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.sys', '.ocx', '.cab', '.pif', '.lnk'
)
$script:SafeUpdaterTextExtensions = @(
    '.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.vbs', '.js', '.xaml', '.xml', '.json', '.yml', '.yaml'
)
$script:LastManifestError = ''
$script:LastStagedSecurityViolations = @()

function Get-BytesSha256Hex {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'UpdaterFileMissing' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $hash = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant())
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-HubVersionInfo {
    param([string]$BaseDir = $PSScriptRoot)
    $version = ''
    $commitSha = ''
    $installedAt = ''
    $source = 'Unknown'
    $jsonFile = Join-Path $BaseDir '.hub-version.json'
    if (Test-Path -LiteralPath $jsonFile -PathType Leaf) {
        try {
            $raw = [IO.File]::ReadAllText($jsonFile, [Text.Encoding]::UTF8)
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($parsed) {
                if ($parsed.PSObject.Properties['version'] -and ($parsed.version -is [string])) {
                    $version = $parsed.version.Trim()
                }
                if ($parsed.PSObject.Properties['commit_sha'] -and ($parsed.commit_sha -is [string])) {
                    $candidateSha = $parsed.commit_sha.Trim().ToLowerInvariant()
                    if ($candidateSha -cmatch '^[0-9a-f]{40}\z') { $commitSha = $candidateSha }
                }
                if ($parsed.PSObject.Properties['installed_at_utc'] -and ($parsed.installed_at_utc -is [string])) {
                    $installedAt = $parsed.installed_at_utc.Trim()
                }
                if ($version -or $commitSha) { $source = 'Json' }
            }
        } catch {
            $version = ''; $commitSha = ''; $installedAt = ''; $source = 'Unknown'
        }
    }
    if ($source -eq 'Unknown') {
        $legacyFile = Join-Path $BaseDir '.hub-version'
        if (Test-Path -LiteralPath $legacyFile -PathType Leaf) {
            try {
                $rawLegacy = ([IO.File]::ReadAllText($legacyFile, [Text.Encoding]::UTF8)).Trim()
                if ($rawLegacy -cmatch '^[0-9a-fA-F]{40}\z') {
                    $commitSha = $rawLegacy.ToLowerInvariant()
                    $source = 'Legacy'
                } elseif ($rawLegacy -cmatch '^v?\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?\z' -and -not $rawLegacy.Contains('..')) {
                    $version = $rawLegacy
                    $source = 'Legacy'
                }
            } catch { }
        }
    }
    return [pscustomobject]@{
        Version        = $version
        CommitSha      = $commitSha
        InstalledAtUtc = $installedAt
        Source         = $source
    }
}

function Test-AllowedReleaseUrl {
    param(
        [AllowEmptyString()][string]$Url,
        [ValidateSet('Any','Api','Asset','Compare')][string]$Kind = 'Any'
    )
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($Url -match '[\s\x00-\x1f\\]' -or $Url -match '(?i)%2f|%5c|%00') { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -cne 'https') { return $false }
    if (-not $uri.IsDefaultPort) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
    $hostName = $uri.Host.ToLowerInvariant()
    $path = $uri.AbsolutePath
    foreach ($seg in ($path -split '/')) {
        if ($seg -eq '.' -or $seg -eq '..' -or $seg -match '(?i)%2e') { return $false }
    }
    $isApi = ($hostName -ceq 'api.github.com') -and ($path -cmatch '^/repos/7janv/antigravity-hub/releases/(?:latest|tags/[A-Za-z0-9._-]+|assets/\d+)\z')
    $isAsset = (
        ($hostName -ceq 'github.com' -and $path -cmatch '^/7janv/antigravity-hub/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z') -or
        ($hostName -ceq 'api.github.com' -and $path -cmatch '^/repos/7janv/antigravity-hub/releases/assets/\d+\z') -or
        (($hostName -ceq 'objects.githubusercontent.com' -or $hostName -ceq 'release-assets.githubusercontent.com') -and $path.StartsWith('/') -and $path.Length -gt 1)
    )
    $isCompare = $false
    if ($hostName -ceq 'github.com' -and $path -cmatch '^/7janv/antigravity-hub/compare/([A-Za-z0-9._-]+)\.\.\.([A-Za-z0-9._-]+)\z') {
        $leftRef = $Matches[1]; $rightRef = $Matches[2]
        if (-not $leftRef.Contains('..') -and -not $rightRef.Contains('..') -and -not $leftRef.StartsWith('.') -and -not $rightRef.StartsWith('.')) {
            $isCompare = $true
        }
    }
    switch ($Kind) {
        'Api'     { return [bool]$isApi }
        'Asset'   { return [bool]$isAsset }
        'Compare' { return [bool]$isCompare }
        default   { return [bool]($isApi -or $isAsset -or $isCompare) }
    }
}

function Test-SafeReleaseRelativePath {
    param([AllowEmptyString()][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ($RelativePath.Contains('\') -or $RelativePath.StartsWith('/') -or $RelativePath.EndsWith('/')) { return $false }
    if ($RelativePath.Contains('//') -or $RelativePath.Contains(':')) { return $false }
    if ($RelativePath -match '[\x00-\x1f\x7f]') { return $false }
    $segments = $RelativePath -split '/'
    if ($segments.Count -lt 1) { return $false }
    if ($segments[0].ToLowerInvariant() -in $script:SafeUpdaterPreservedPaths) { return $false }
    foreach ($seg in $segments) {
        if ([string]::IsNullOrEmpty($seg) -or $seg -eq '.' -or $seg -eq '..') { return $false }
        if ($seg.EndsWith('.') -or $seg.EndsWith(' ')) { return $false }
        if ($seg -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\z)') { return $false }
    }
    $ext = [IO.Path]::GetExtension($segments[$segments.Count - 1]).ToLowerInvariant()
    if ($ext -and ($ext -in $script:SafeUpdaterDisallowedExtensions)) { return $false }
    return $true
}

function ConvertTo-ManifestObject {
    param($Manifest)
    if ($null -eq $Manifest) { return $null }
    if ($Manifest -is [string]) {
        $trimmed = $Manifest.Trim()
        if ($trimmed -and -not $trimmed.StartsWith('{') -and (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
            $trimmed = [IO.File]::ReadAllText($Manifest, [Text.Encoding]::UTF8)
        }
        return ($trimmed | ConvertFrom-Json -ErrorAction Stop)
    }
    return $Manifest
}

function Get-ManifestFileEntries {
    param($FilesObject)
    $entries = [ordered]@{}
    if ($null -eq $FilesObject) { return $entries }
    if ($FilesObject -is [Collections.IDictionary]) {
        foreach ($k in $FilesObject.Keys) { $entries[[string]$k] = $FilesObject[$k] }
    } else {
        foreach ($prop in $FilesObject.PSObject.Properties) { $entries[[string]$prop.Name] = $prop.Value }
    }
    return $entries
}

function Test-SafeReleaseManifest {
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [switch]$ThrowOnError
    )
    $script:LastManifestError = ''
    $fail = {
        param([string]$Code)
        $script:LastManifestError = $Code
        if ($ThrowOnError) { throw $Code }
        return $false
    }
    try {
        $obj = ConvertTo-ManifestObject $Manifest
    } catch {
        return (& $fail 'UpdaterManifestParseError')
    }
    if ($null -eq $obj) { return (& $fail 'UpdaterManifestMissing') }

    $getProp = {
        param($Target, [string]$Name)
        if ($Target -is [Collections.IDictionary]) {
            if ($Target.Contains($Name)) { return $Target[$Name] }
            return $null
        }
        $p = $Target.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }

    $schemaVer = & $getProp $obj 'schema_version'
    if (($schemaVer -isnot [int] -and $schemaVer -isnot [long]) -or [int]$schemaVer -ne 1) {
        return (& $fail 'UpdaterInvalidSchemaVersion')
    }

    $version = & $getProp $obj 'version'
    if (($version -isnot [string]) -or ($version -cnotmatch '^v?\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?\z') -or $version.Contains('..')) {
        return (& $fail 'UpdaterInvalidVersion')
    }

    $commitSha = & $getProp $obj 'commit_sha'
    if (($commitSha -isnot [string]) -or ($commitSha -cnotmatch '^[0-9a-f]{40}\z')) {
        return (& $fail 'UpdaterInvalidCommitSha')
    }

    $builtAt = & $getProp $obj 'built_at_utc'
    $parsedTime = [datetimeoffset]::MinValue
    if (($builtAt -isnot [string]) -or (-not $builtAt.EndsWith('Z')) -or (-not [datetimeoffset]::TryParse($builtAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedTime))) {
        return (& $fail 'UpdaterInvalidBuildTime')
    }

    $archiveName = & $getProp $obj 'archive_name'
    if (($archiveName -isnot [string]) -or ($archiveName -cnotmatch '^[A-Za-z0-9._-]+\.zip\z') -or $archiveName.StartsWith('.') -or $archiveName.Contains('..')) {
        return (& $fail 'UpdaterInvalidArchiveName')
    }

    $archiveSha = & $getProp $obj 'archive_sha256'
    if (($archiveSha -isnot [string]) -or ($archiveSha -cnotmatch '^[0-9a-f]{64}\z')) {
        return (& $fail 'UpdaterInvalidArchiveSha')
    }

    $filesNode = & $getProp $obj 'files'
    if ($null -eq $filesNode -or ($filesNode -is [string]) -or ($filesNode -is [Array])) {
        return (& $fail 'UpdaterInvalidFilesMap')
    }
    $entries = Get-ManifestFileEntries $filesNode
    if ($entries.Count -lt 1) { return (& $fail 'UpdaterEmptyFilesMap') }

    $seenLower = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relPath in $entries.Keys) {
        if (-not (Test-SafeReleaseRelativePath $relPath)) {
            return (& $fail "UpdaterUnsafeManifestPath:$relPath")
        }
        if (-not $seenLower.Add($relPath)) {
            return (& $fail "UpdaterDuplicateManifestPath:$relPath")
        }
        $fileHash = $entries[$relPath]
        if (($fileHash -isnot [string]) -or ($fileHash -cnotmatch '^[0-9a-f]{64}\z')) {
            return (& $fail "UpdaterInvalidFileHash:$relPath")
        }
    }
    return $true
}

function Parse-Sha256Sums {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content,
        [string]$ExpectedArchiveName = '',
        [string]$ExpectedArchiveSha256 = '',
        [string]$ExpectedManifestSha256 = '',
        [string]$ManifestFileName = 'release-manifest.json'
    )
    if ([string]::IsNullOrWhiteSpace($Content)) { throw 'UpdaterInvalidChecksums' }
    $sums = @{}
    $lines = $Content -split '\r?\n'
    foreach ($line in $lines) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9._-]+)\z') {
            throw 'UpdaterInvalidChecksums'
        }
        $hash = $Matches[1]
        $fileName = $Matches[2]
        if ($fileName.StartsWith('.') -or $fileName.Contains('..')) {
            throw 'UpdaterInvalidChecksums'
        }
        if ($sums.ContainsKey($fileName)) {
            throw 'UpdaterDuplicateChecksumEntry'
        }
        $sums[$fileName] = $hash
    }
    if ($sums.Count -lt 1) { throw 'UpdaterInvalidChecksums' }

    if ($ExpectedArchiveName) {
        if (-not $sums.ContainsKey($ExpectedArchiveName)) { throw 'UpdaterMissingArchiveChecksum' }
        if ($ExpectedArchiveSha256 -and ($sums[$ExpectedArchiveName] -cne $ExpectedArchiveSha256)) {
            throw 'UpdaterArchiveChecksumMismatch'
        }
    }
    if ($ExpectedManifestSha256) {
        if (-not $sums.ContainsKey($ManifestFileName)) { throw 'UpdaterMissingManifestChecksum' }
        if ($sums[$ManifestFileName] -cne $ExpectedManifestSha256) {
            throw 'UpdaterManifestChecksumMismatch'
        }
    }
    return $sums
}

function Test-AllowedProductionUrl {
    param([Parameter(Mandatory=$true)][string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
    $scheme = $uri.Scheme.ToLowerInvariant()
    $hostName = $uri.Host.ToLowerInvariant()
    $path = $uri.AbsolutePath

    if ($hostName -eq '127.0.0.1' -or $hostName -eq '::1' -or $hostName -eq '[::1]') {
        return ($scheme -eq 'http' -or $scheme -eq 'https')
    }
    if ($hostName -eq 'schemas.microsoft.com') {
        return ($scheme -eq 'http' -or $scheme -eq 'https')
    }
    if ($scheme -ne 'https') { return $false }
    if (-not $uri.IsDefaultPort) { return $false }

    if ($hostName -eq 'googleapis.com' -or $hostName.EndsWith('.googleapis.com')) { return $true }
    if ($hostName -eq 'google.com' -or $hostName.EndsWith('.google.com')) { return $true }
    if ($hostName -eq 'objects.githubusercontent.com' -or $hostName -eq 'release-assets.githubusercontent.com') { return $true }
    if ($hostName -eq 'img.shields.io') { return $true }
    if ($hostName -eq 'github.com') {
        if ($path -imatch '/archive/refs/heads/') { return $false }
        return ($path -cmatch '^/7janv/antigravity-hub(?:\.git|/|)?\z' -or $path -cmatch '^/7janv/antigravity-hub/')
    }
    if ($hostName -eq 'api.github.com') {
        return ($path -cmatch '^/repos/7janv/antigravity-hub(?:/|\z)')
    }
    return $false
}

function Test-StagedReleaseSecurity {
    param(
        [Parameter(Mandatory=$true)][string]$StagingDir,
        [switch]$ThrowOnError
    )
    $script:LastStagedSecurityViolations = @()
    $violations = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
        $violations.Add('StagingDirMissing')
        $script:LastStagedSecurityViolations = @($violations)
        if ($ThrowOnError) { throw 'UpdaterSecurityGateFailed: StagingDirMissing' }
        return $false
    }
    $stagingRoot = [IO.Path]::GetFullPath($StagingDir).TrimEnd('\') + '\'
    $allItems = @(Get-ChildItem -LiteralPath $StagingDir -Recurse -Force -ErrorAction Stop)

    # Construct dangerous pattern tokens without matching this scanner itself.
    $patEncodedCmd = '(?i)-Encoded' + 'Command\b'
    $patFromBase64 = '(?i)FromBase64' + 'String\b'
    $patWebStr = '(?i)Download' + 'String\b'
    $patWebFile = '(?i)Download' + 'File\b'
    $patObjProvider = '(?i)ObjectData' + 'Provider\b'
    $patInvokeExpr = '(?i)Invoke-' + 'Expression\b'
    $patEvalAlias = '(?i)\bi' + 'ex\b'
    $patBidi = '[\u202A-\u202E\u2066-\u2069\u200B-\u200F\u061C]'
    $patUrl = '(?i)\bhttps?://(?:(?:\[::1\])|(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?))(?::\d+)?(?:/[^\s"''`<>)\],;]*)?'

    foreach ($item in $allItems) {
        $fullPath = [IO.Path]::GetFullPath($item.FullName)
        if (-not $fullPath.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $violations.Add("OutsideStaging:$($item.Name)")
            continue
        }
        $rel = $fullPath.Substring($stagingRoot.Length) -replace '\\', '/'
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $violations.Add("ReparsePoint:$rel")
            continue
        }
        if ($item.PSIsContainer) { continue }

        $ext = $item.Extension.ToLowerInvariant()
        if ($ext -in $script:SafeUpdaterDisallowedExtensions) {
            $violations.Add("DisallowedExtension:$rel")
            continue
        }

        $bytes = [IO.File]::ReadAllBytes($fullPath)
        if ($ext -eq '.ps1') {
            $hasNonAscii = $false
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -gt 127) { $hasNonAscii = $true; break }
            }
            if ($hasNonAscii) {
                $violations.Add("NonAsciiPowerShell:$rel")
            }
        }

        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if ($text -match $patBidi) {
            $violations.Add("BidiOrZeroWidthUnicode:$rel")
        }
        if ($text.Length -gt 1 -and $text.IndexOf([char]0xFEFF, 1) -ge 0) {
            $violations.Add("MidFileBom:$rel")
        }

        if ($ext -in $script:SafeUpdaterTextExtensions) {
            $isTestFile = $rel -imatch '^tests/'
            if ($text -match $patEncodedCmd) { $violations.Add("ForbiddenPattern:EncodedCmd:$rel") }
            if ($text -match $patWebStr) { $violations.Add("ForbiddenPattern:WebStr:$rel") }
            if ($text -match $patWebFile) { $violations.Add("ForbiddenPattern:WebFile:$rel") }
            if ($text -match $patObjProvider) { $violations.Add("ForbiddenPattern:ObjProvider:$rel") }
            if (-not $isTestFile) {
                if ($text -match $patInvokeExpr) { $violations.Add("ForbiddenPattern:EvalExpr:$rel") }
                if ($text -match $patEvalAlias) { $violations.Add("ForbiddenPattern:EvalAlias:$rel") }
            }
            if ($text -match $patFromBase64) {
                # Only allow DPAPI payload unprotection inside RotationCore.ps1 or AntigravityHub.ps1.
                $dpapiAllowed = $false
                if ($rel -ieq 'RotationCore.ps1' -or $rel -ieq 'AntigravityHub.ps1') {
                    $lines = $text -split '\r?\n'
                    $allSafe = $true
                    for ($li = 0; $li -lt $lines.Count; $li++) {
                        if ($lines[$li] -match $patFromBase64) {
                            $lo = [math]::Max(0, $li - 2)
                            $hi = [math]::Min($lines.Count - 1, $li + 3)
                            $windowText = ($lines[$lo..$hi]) -join "`n"
                            if ($windowText -notmatch 'ProtectedData\]::Unprotect' -or $windowText -match '(?i)ScriptBlock|Assembly|Start-Process') {
                                $allSafe = $false; break
                            }
                        }
                    }
                    $dpapiAllowed = $allSafe
                }
                if (-not $dpapiAllowed) {
                    $violations.Add("ForbiddenPattern:Base64Decode:$rel")
                }
            }

            if (-not $isTestFile) {
                foreach ($m in [regex]::Matches($text, $patUrl)) {
                    $foundUrl = $m.Value.TrimEnd('.', ',', ';', ':')
                    if (-not (Test-AllowedProductionUrl $foundUrl)) {
                        $violations.Add("UnauthorizedUrl:${rel}:$foundUrl")
                    }
                }
            }
        }
    }

    $script:LastStagedSecurityViolations = @($violations)
    if ($violations.Count -gt 0) {
        if ($ThrowOnError) {
            throw ("UpdaterSecurityGateFailed: " + ($violations -join '; '))
        }
        return $false
    }
    return $true
}

function Invoke-SafeReleaseHttpDownload {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [ValidateSet('Api','Asset')][string]$Kind = 'Asset',
        [string]$OutFile = '',
        [int]$TimeoutMs = 20000,
        [long]$MaxBytes = 52428800
    )
    if (-not (Test-AllowedReleaseUrl -Url $Url -Kind $Kind)) {
        throw 'UpdaterUntrustedUrl'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $currentUrl = $Url
    $redirects = 0
    while ($true) {
        $req = [Net.HttpWebRequest]::Create($currentUrl)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'Antigravity-Auto-Hub'
        if ($Kind -eq 'Api') {
            $req.Accept = 'application/vnd.github+json'
        }
        $resp = $null
        try {
            $resp = [Net.HttpWebResponse]$req.GetResponse()
        } catch [Net.WebException] {
            $resp = [Net.HttpWebResponse]$_.Exception.Response
            if ($null -eq $resp) { throw 'UpdaterNetworkError' }
        }
        try {
            $code = [int]$resp.StatusCode
            if ($code -in @(301, 302, 303, 307, 308)) {
                $redirects++
                if ($redirects -gt 5) { throw 'UpdaterTooManyRedirects' }
                $loc = $resp.Headers['Location']
                if ([string]::IsNullOrWhiteSpace($loc)) { throw 'UpdaterInvalidRedirect' }
                $nextUri = $null
                if (-not [Uri]::TryCreate([Uri]$currentUrl, $loc, [ref]$nextUri)) { throw 'UpdaterInvalidRedirect' }
                $currentUrl = $nextUri.AbsoluteUri
                if (-not (Test-AllowedReleaseUrl -Url $currentUrl -Kind 'Asset')) {
                    throw 'UpdaterUntrustedRedirect'
                }
                continue
            }
            if ($code -lt 200 -or $code -ge 300) {
                throw "UpdaterHttpError:$code"
            }
            if ($resp.ContentLength -gt $MaxBytes) {
                throw 'UpdaterPayloadTooLarge'
            }
            $stream = $resp.GetResponseStream()
            $buf = New-Object byte[] 16384
            [long]$total = 0
            if ($OutFile) {
                $outStream = [IO.File]::Create($OutFile)
                try {
                    while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $total += $read
                        if ($total -gt $MaxBytes) { throw 'UpdaterPayloadTooLarge' }
                        $outStream.Write($buf, 0, $read)
                    }
                } finally {
                    $outStream.Dispose()
                }
                return $OutFile
            } else {
                $mem = [IO.MemoryStream]::new()
                try {
                    while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $total += $read
                        if ($total -gt $MaxBytes) { throw 'UpdaterPayloadTooLarge' }
                        $mem.Write($buf, 0, $read)
                    }
                    return $mem.ToArray()
                } finally {
                    $mem.Dispose()
                }
            }
        } finally {
            if ($resp) { $resp.Dispose() }
        }
    }
}

function Get-AvailableHubRelease {
    param(
        [string]$BaseDir = $PSScriptRoot,
        [string]$ApiUrl = $script:SafeUpdaterLatestReleaseApi
    )
    if (-not (Test-AllowedReleaseUrl -Url $ApiUrl -Kind 'Api')) {
        throw 'UpdaterUntrustedUrl'
    }
    $current = Get-HubVersionInfo -BaseDir $BaseDir
    $releaseBytes = Invoke-SafeReleaseHttpDownload -Url $ApiUrl -Kind 'Api' -TimeoutMs 15000 -MaxBytes 2097152
    $release = ([Text.Encoding]::UTF8.GetString($releaseBytes)) | ConvertFrom-Json -ErrorAction Stop
    if (-not $release -or $release.draft -or $release.prerelease) {
        throw 'UpdaterInvalidRelease'
    }
    $assets = @($release.assets)
    $manifestAsset = $assets | Where-Object { $_.name -ceq 'release-manifest.json' } | Select-Object -First 1
    $sumsAsset = $assets | Where-Object { $_.name -ceq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $manifestAsset -or -not $sumsAsset) {
        throw 'UpdaterMissingReleaseAssets'
    }
    $manifestUrl = [string]$manifestAsset.browser_download_url
    $sumsUrl = [string]$sumsAsset.browser_download_url
    if (-not (Test-AllowedReleaseUrl -Url $manifestUrl -Kind 'Asset') -or -not (Test-AllowedReleaseUrl -Url $sumsUrl -Kind 'Asset')) {
        throw 'UpdaterUntrustedAssetUrl'
    }

    $manifestBytes = Invoke-SafeReleaseHttpDownload -Url $manifestUrl -Kind 'Asset' -TimeoutMs 15000 -MaxBytes 1048576
    $sumsBytes = Invoke-SafeReleaseHttpDownload -Url $sumsUrl -Kind 'Asset' -TimeoutMs 15000 -MaxBytes 262144

    $manifestSha = Get-BytesSha256Hex $manifestBytes
    $manifestText = [Text.Encoding]::UTF8.GetString($manifestBytes)
    $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
    $null = Test-SafeReleaseManifest -Manifest $manifest -ThrowOnError

    if ($release.tag_name -and ($release.tag_name -cne $manifest.version)) {
        throw 'UpdaterTagVersionMismatch'
    }

    $archiveAsset = $assets | Where-Object { $_.name -ceq $manifest.archive_name } | Select-Object -First 1
    if (-not $archiveAsset) { throw 'UpdaterMissingArchiveAsset' }
    $archiveUrl = [string]$archiveAsset.browser_download_url
    if (-not (Test-AllowedReleaseUrl -Url $archiveUrl -Kind 'Asset')) {
        throw 'UpdaterUntrustedAssetUrl'
    }

    $sumsText = [Text.Encoding]::UTF8.GetString($sumsBytes)
    $sums = Parse-Sha256Sums -Content $sumsText -ExpectedArchiveName $manifest.archive_name -ExpectedArchiveSha256 $manifest.archive_sha256 -ExpectedManifestSha256 $manifestSha

    $hasUpdate = $true
    if ($current.Version -and ($current.Version -ceq $manifest.version)) {
        if (-not $current.CommitSha -or ($current.CommitSha -ceq $manifest.commit_sha)) {
            $hasUpdate = $false
        }
    } elseif (-not $current.Version -and $current.CommitSha -and ($current.CommitSha -ceq $manifest.commit_sha)) {
        $hasUpdate = $false
    }

    $compareUrl = ''
    $fromRef = if ($current.CommitSha) { $current.CommitSha } elseif ($current.Version) { $current.Version } else { '' }
    $toRef = if ($manifest.commit_sha) { $manifest.commit_sha } else { $manifest.version }
    if ($fromRef -and $toRef -and ($fromRef -cne $toRef)) {
        $candidateCompare = "$script:SafeUpdaterCompareBaseUrl/$fromRef...$toRef"
        if (Test-AllowedReleaseUrl -Url $candidateCompare -Kind 'Compare') {
            $compareUrl = $candidateCompare
        }
    }

    $rawNotes = if ($release.body -is [string]) { $release.body } else { '' }
    $cleanNotes = ($rawNotes -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\u202A-\u202E\u2066-\u2069\u200B-\u200F\u061C]', '').Trim()
    if ($cleanNotes.Length -gt 2000) { $cleanNotes = $cleanNotes.Substring(0, 2000) + '...' }

    return [pscustomobject]@{
        HasUpdate      = $hasUpdate
        CurrentVersion = $current.Version
        CurrentSha     = $current.CommitSha
        LatestVersion  = [string]$manifest.version
        LatestSha      = [string]$manifest.commit_sha
        ReleaseNotes   = $cleanNotes
        CompareUrl     = $compareUrl
        ArchiveUrl     = $archiveUrl
        ArchiveName    = [string]$manifest.archive_name
        ArchiveSha256  = [string]$manifest.archive_sha256
        ManifestSha256 = $manifestSha
        Manifest       = $manifest
        Checksums      = $sums
    }
}

function Expand-VerifiedReleaseArchive {
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$StagingDir,
        $Checksums = $null
    )
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw 'UpdaterArchiveMissing' }

    $manifestFileSha = ''
    if (($Manifest -is [string]) -and -not $Manifest.Trim().StartsWith('{') -and (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        $manifestFileSha = Get-FileSha256Hex $Manifest
    }
    $manifestObj = ConvertTo-ManifestObject $Manifest
    $null = Test-SafeReleaseManifest -Manifest $manifestObj -ThrowOnError

    $actualArchiveSha = Get-FileSha256Hex $ArchivePath
    if ($actualArchiveSha -cne $manifestObj.archive_sha256) {
        throw 'UpdaterArchiveHashMismatch'
    }

    if ($null -ne $Checksums) {
        $sumsMap = $null
        if ($Checksums -is [Collections.IDictionary]) {
            $sumsMap = $Checksums
            if (-not $sumsMap.Contains($manifestObj.archive_name) -or ($sumsMap[$manifestObj.archive_name] -cne $actualArchiveSha)) {
                throw 'UpdaterArchiveChecksumMismatch'
            }
            if ($manifestFileSha -and (-not $sumsMap.Contains('release-manifest.json') -or ($sumsMap['release-manifest.json'] -cne $manifestFileSha))) {
                throw 'UpdaterManifestChecksumMismatch'
            }
        } elseif ($Checksums -is [string]) {
            $sumsText = $Checksums
            if (Test-Path -LiteralPath $Checksums -PathType Leaf) {
                $sumsText = [IO.File]::ReadAllText($Checksums, [Text.Encoding]::UTF8)
            }
            $sumsMap = Parse-Sha256Sums -Content $sumsText -ExpectedArchiveName $manifestObj.archive_name -ExpectedArchiveSha256 $actualArchiveSha -ExpectedManifestSha256 $manifestFileSha
        } else {
            throw 'UpdaterInvalidChecksums'
        }
    }

    if (Test-Path -LiteralPath $StagingDir) {
        $existing = @(Get-ChildItem -LiteralPath $StagingDir -Force -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) { throw 'UpdaterStagingDirNotEmpty' }
    } else {
        New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    }
    $stagingRoot = [IO.Path]::GetFullPath($StagingDir).TrimEnd('\') + '\'

    $expectedFiles = Get-ManifestFileEntries $manifestObj.files
    $expectedLookup = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($k in $expectedFiles.Keys) { $expectedLookup[$k] = [string]$expectedFiles[$k] }
    $extractedLookup = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        [long]$maxEntryBytes = 20971520
        foreach ($entry in $zip.Entries) {
            $entryName = [string]$entry.FullName
            if ($entryName.Contains('\') -or $entryName.StartsWith('/') -or $entryName.Contains(':')) {
                throw 'UpdaterZipSlipBlocked'
            }
            if ($entryName.EndsWith('/')) {
                $dirRel = $entryName.TrimEnd('/')
                if (-not (Test-SafeReleaseRelativePath $dirRel)) { throw 'UpdaterZipSlipBlocked' }
                $dirFull = [IO.Path]::GetFullPath((Join-Path $stagingRoot ($dirRel -replace '/', '\')))
                if (-not $dirFull.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'UpdaterZipSlipBlocked'
                }
                continue
            }
            if (-not (Test-SafeReleaseRelativePath $entryName)) {
                throw 'UpdaterZipSlipBlocked'
            }
            $destPath = [IO.Path]::GetFullPath((Join-Path $stagingRoot ($entryName -replace '/', '\')))
            if (-not $destPath.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'UpdaterZipSlipBlocked'
            }
            if ($extractedLookup.ContainsKey($entryName)) {
                throw 'UpdaterDuplicateArchiveEntry'
            }
            if (-not $expectedLookup.ContainsKey($entryName)) {
                throw "UpdaterUnexpectedArchiveEntry:$entryName"
            }
            if ($entry.Length -gt $maxEntryBytes) {
                throw "UpdaterArchiveEntryTooLarge:$entryName"
            }

            $destDir = Split-Path -Path $destPath -Parent
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            $inStream = $entry.Open()
            $outStream = [IO.File]::Create($destPath)
            try {
                $buf = New-Object byte[] 16384
                [long]$written = 0
                while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                    $written += $read
                    if ($written -gt $maxEntryBytes) { throw "UpdaterArchiveEntryTooLarge:$entryName" }
                    $outStream.Write($buf, 0, $read)
                }
            } finally {
                $outStream.Dispose()
                $inStream.Dispose()
            }

            $fileSha = Get-FileSha256Hex $destPath
            if ($fileSha -cne $expectedLookup[$entryName]) {
                throw "UpdaterFileHashMismatch:$entryName"
            }
            $extractedLookup[$entryName] = $fileSha
        }
    } finally {
        $zip.Dispose()
    }

    foreach ($reqFile in $expectedLookup.Keys) {
        if (-not $extractedLookup.ContainsKey($reqFile)) {
            throw "UpdaterMissingManifestFile:$reqFile"
        }
    }
    $diskFiles = @(Get-ChildItem -LiteralPath $StagingDir -Recurse -File -Force)
    if ($diskFiles.Count -ne $expectedLookup.Count) {
        throw 'UpdaterStagingFileCountMismatch'
    }

    $null = Test-StagedReleaseSecurity -StagingDir $StagingDir -ThrowOnError

    return [pscustomobject]@{
        StagingDir = $stagingRoot.TrimEnd('\')
        Version    = [string]$manifestObj.version
        CommitSha  = [string]$manifestObj.commit_sha
        FileCount  = $extractedLookup.Count
        Files      = $expectedFiles
    }
}

function Write-SafeUpdaterAtomicText {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Content)
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($tmp, $Content, [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path) {
            try {
                [IO.File]::Replace($tmp, $Path, $null, $true)
            } catch {
                Move-Item -LiteralPath $tmp -Destination $Path -Force
            }
        } else {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-VerifiedHubRelease {
    param(
        [Parameter(Mandatory=$true)][string]$StagingDir,
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$BaseDir,
        [scriptblock]$CopyHook = $null
    )
    $manifestObj = ConvertTo-ManifestObject $Manifest
    $null = Test-SafeReleaseManifest -Manifest $manifestObj -ThrowOnError
    if (-not (Test-Path -LiteralPath $StagingDir -PathType Container)) { throw 'UpdaterStagingDirMissing' }
    if (-not (Test-Path -LiteralPath $BaseDir -PathType Container)) { throw 'UpdaterBaseDirMissing' }

    $stagingRoot = [IO.Path]::GetFullPath($StagingDir).TrimEnd('\') + '\'
    $baseRoot = [IO.Path]::GetFullPath($BaseDir).TrimEnd('\') + '\'
    $expectedFiles = Get-ManifestFileEntries $manifestObj.files

    # Re-verify every staged file hash and security gate before touching BaseDir.
    foreach ($relPath in $expectedFiles.Keys) {
        $srcPath = [IO.Path]::GetFullPath((Join-Path $stagingRoot ($relPath -replace '/', '\')))
        if (-not $srcPath.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'UpdaterZipSlipBlocked' }
        if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) { throw "UpdaterMissingManifestFile:$relPath" }
        $sha = Get-FileSha256Hex $srcPath
        if ($sha -cne [string]$expectedFiles[$relPath]) { throw "UpdaterFileHashMismatch:$relPath" }
    }
    $null = Test-StagedReleaseSecurity -StagingDir $StagingDir -ThrowOnError

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupDir = Join-Path (Join-Path $baseRoot '.backup') $stamp
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $backedUp = [Collections.Generic.List[string]]::new()
    $createdNew = [Collections.Generic.List[string]]::new()

    foreach ($relPath in $expectedFiles.Keys) {
        $destPath = [IO.Path]::GetFullPath((Join-Path $baseRoot ($relPath -replace '/', '\')))
        if (-not $destPath.StartsWith($baseRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'UpdaterZipSlipBlocked' }
        if (Test-Path -LiteralPath $destPath -PathType Leaf) {
            $bkpPath = Join-Path $backupDir ($relPath -replace '/', '\')
            $bkpParent = Split-Path -Path $bkpPath -Parent
            if (-not (Test-Path -LiteralPath $bkpParent)) {
                New-Item -ItemType Directory -Path $bkpParent -Force | Out-Null
            }
            [IO.File]::Copy($destPath, $bkpPath, $true)
            $backedUp.Add($relPath)
        }
    }

    try {
        foreach ($relPath in $expectedFiles.Keys) {
            $srcPath = [IO.Path]::GetFullPath((Join-Path $stagingRoot ($relPath -replace '/', '\')))
            $destPath = [IO.Path]::GetFullPath((Join-Path $baseRoot ($relPath -replace '/', '\')))
            $existedBefore = Test-Path -LiteralPath $destPath -PathType Leaf
            $destParent = Split-Path -Path $destPath -Parent
            if (-not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }
            if ($CopyHook) {
                & $CopyHook $relPath $srcPath $destPath
            } else {
                [IO.File]::Copy($srcPath, $destPath, $true)
            }
            if (-not $existedBefore) {
                $createdNew.Add($relPath)
            }
        }
        $versionRecord = [ordered]@{
            version          = [string]$manifestObj.version
            commit_sha       = [string]$manifestObj.commit_sha
            installed_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } | ConvertTo-Json -Depth 4
        Write-SafeUpdaterAtomicText -Path (Join-Path $baseRoot '.hub-version.json') -Content $versionRecord
    } catch {
        foreach ($relNew in $createdNew) {
            $p = Join-Path $baseRoot ($relNew -replace '/', '\')
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($relOld in $backedUp) {
            $bkpPath = Join-Path $backupDir ($relOld -replace '/', '\')
            $destPath = Join-Path $baseRoot ($relOld -replace '/', '\')
            if (Test-Path -LiteralPath $bkpPath -PathType Leaf) {
                $destParent = Split-Path -Path $destPath -Parent
                if (-not (Test-Path -LiteralPath $destParent)) {
                    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
                }
                [IO.File]::Copy($bkpPath, $destPath, $true)
            }
        }
        throw
    }

    return [pscustomobject]@{
        Version        = [string]$manifestObj.version
        CommitSha      = [string]$manifestObj.commit_sha
        BackupDir      = $backupDir
        InstalledFiles = @($expectedFiles.Keys)
    }
}

function Test-IsScopedDaemonCommandLine {
    param(
        [AllowEmptyString()][string]$CommandLine,
        [Parameter(Mandatory=$true)][string]$BaseDir,
        [switch]$RequireDaemonFlag
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($BaseDir)) { return $false }
    if ($RequireDaemonFlag -and ($CommandLine -notmatch '(?i)(?:^|\s)-Daemon(?:\s|$)')) { return $false }
    $targetPath = [IO.Path]::GetFullPath((Join-Path $BaseDir 'AutoRotator.ps1'))
    $escaped = [regex]::Escape($targetPath)
    return ($CommandLine -imatch "(?:^|[\s`"'])$escaped(?:[\s`"']|\z)")
}

function Get-ScopedDaemonProcesses {
    param(
        [Parameter(Mandatory=$true)][string]$BaseDir,
        [switch]$RequireDaemonFlag
    )
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue)
    return @($procs | Where-Object {
        Test-IsScopedDaemonCommandLine -CommandLine ([string]$_.CommandLine) -BaseDir $BaseDir -RequireDaemonFlag:$RequireDaemonFlag
    })
}

function Stop-ScopedDaemonProcesses {
    param([Parameter(Mandatory=$true)][string]$BaseDir)
    $procs = @(Get-ScopedDaemonProcesses -BaseDir $BaseDir)
    $stopped = 0
    foreach ($proc in $procs) {
        if ($proc.ProcessId -and ([int]$proc.ProcessId -ne $PID)) {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    return $stopped
}
