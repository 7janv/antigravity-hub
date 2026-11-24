# Use a client compatible with the account's refresh token. Never pass secrets on the command line.
$ErrorActionPreference = 'Stop'
$clientId = Read-Host 'Google OAuth client ID'
if ($null -ne $clientId) { $clientId = $clientId.Trim() }
$clientSecret = Read-Host 'Google OAuth client secret' -AsSecureString
if (-not $clientId -or $clientSecret.Length -eq 0) { throw 'OAuth client configuration is required.' }
$credential = [pscredential]::new($clientId, $clientSecret)
$oauthPath = Join-Path $PSScriptRoot 'oauth.local.clixml'
$credential | Export-Clixml -LiteralPath $oauthPath
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $currentSid,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    [System.Security.AccessControl.AccessControlType]::Allow
)
$acl.SetAccessRule($rule)
[System.IO.File]::SetAccessControl($oauthPath, $acl)
Write-Host 'Saved with Windows DPAPI and owner-only NTFS permissions for this Windows user. Restart Hub and daemon to load it.'
