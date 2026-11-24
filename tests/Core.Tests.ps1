$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AutoRotator.ps1')
$script:Failed=0
function Assert($condition, $name) {
    if (-not $condition) { $script:Failed++; Write-Host "FAIL: $name" } else { Write-Host "PASS: $name" }
}
function Summary($buckets) { [pscustomobject]@{groups=@([pscustomobject]@{displayName='Gemini';buckets=$buckets})} }
function Bucket($window,$fraction) { [pscustomobject]@{window=$window;remainingFraction=$fraction} }
foreach ($fixture in @(@{}, (Summary @()), (Summary @((Bucket '5h' 1))), (Summary @((Bucket '5h' $null),(Bucket 'week' 1))), (Summary @((Bucket '5h' 2),(Bucket 'week' 1))), (Summary @((Bucket '5h' 'NaN'),(Bucket 'week' 1))))) {
    $rejected=$false
    try { Convert-QuotaSummary $fixture | Out-Null } catch { $rejected=$true }
    Assert $rejected 'Unknown or invalid quota is rejected'
}
$quota=Convert-QuotaSummary (Summary @((Bucket '5h' 0),(Bucket 'week' .7)))
Assert ($quota.Gemini5H -eq 0 -and $quota.GeminiWeekly -eq .7 -and $quota.ArgonWeekly -eq -1) 'Zero is real exhaustion and missing Argon stays -1'
$quota=Convert-QuotaSummary (Summary @((Bucket '5h' .9),(Bucket '5h' .2),(Bucket 'week' .7)))
Assert ($quota.Gemini5H -eq .2) 'Multiple windows use lowest quota'
$argonSummary=[pscustomobject]@{groups=@(
    [pscustomobject]@{displayName='Gemini Models';buckets=@((Bucket '5h' .95),(Bucket 'weekly' .80))}
    [pscustomobject]@{displayName='Gemini 4 Argon';description='For paid Pro plans, Argon quota is separate.';buckets=@([pscustomobject]@{bucketId='gemini-argon-wtu-weekly';displayName='Gemini 4 Argon Weekly Limit';window='weekly';remainingFraction=.25})}
)}
$argonQuota=Convert-QuotaSummary $argonSummary
Assert ($argonQuota.Gemini5H -eq .95 -and $argonQuota.GeminiWeekly -eq .80 -and $argonQuota.ArgonWeekly -eq .25) 'Gemini 4 Argon weekly bucket is tracked separately from standard Gemini weekly'

# Transaction tests use isolated files and mocked native boundaries. No live credentials/processes.
$repoRoot = $baseDir
$testDir = Join-Path $repoRoot ('work\test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
try {
$baseDir=$testDir; $accDir=$testDir; $geminiTokenPath=Join-Path $testDir 'fallback.txt'; $activeFile=Join-Path $testDir 'active.txt'; $stateFile=Join-Path $testDir 'state.json'; $logFile=Join-Path $testDir 'rotator.log'

# --- Config, atomic save, and log rotation tests ---
$defaultCfg = Get-HubConfig
Assert ($defaultCfg.PauseScanWhenIdeClosed -eq $true) 'Get-HubConfig defaults PauseScanWhenIdeClosed to true'
$defaultCfg.PauseScanWhenIdeClosed = $false
Save-HubConfig $defaultCfg
$loadedCfg = Get-HubConfig
Assert ($loadedCfg.PauseScanWhenIdeClosed -eq $false) 'Save-HubConfig atomically persists PauseScanWhenIdeClosed'
Assert (@(Get-ChildItem -LiteralPath $testDir -Filter 'hub-config.json.*.tmp').Count -eq 0) 'Save-HubConfig leaves no temporary files'
$script:MaxLogBytes = 512; $script:MaxLogLines = 5
for ($li = 1; $li -le 40; $li++) { Write-RotatorLog "fixture-log-line-$li-padding-0123456789abcdef" }
$logLines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
$logSize = (Get-Item -LiteralPath $logFile).Length
Assert ($logSize -le 512 -and $logLines.Count -lt 40 -and $logLines[$logLines.Count - 1] -match 'fixture-log-line-40') 'Write-RotatorLog trims rotator.log safely when size cap exceeded'
$script:MaxLogBytes = 2097152; $script:MaxLogLines = 2500

# --- DPAPI account storage and owner-only ACL tests ---
$dpapiPath = Join-Path $testDir 'dpapi-acct.json'
Save-AccountFile $dpapiPath '{"token":{"refresh_token":"dpapi-secret-refresh-token","access_token":"dpapi-access"}}'
$rawDpapiText = [IO.File]::ReadAllText($dpapiPath)
$rawDpapiObj = $rawDpapiText | ConvertFrom-Json
Assert ($rawDpapiObj.format -eq 'dpapi-v1' -and $rawDpapiObj.protected_payload -and $rawDpapiText -notmatch 'dpapi-secret-refresh-token') 'Save-AccountFile encrypts account payload in dpapi-v1 envelope'
$decryptedObj = Read-AccountFile $dpapiPath
Assert ($decryptedObj.token.refresh_token -eq 'dpapi-secret-refresh-token') 'Read-AccountFile decrypts dpapi-v1 account payload'
$dpapiAcl = [IO.File]::GetAccessControl($dpapiPath, [System.Security.AccessControl.AccessControlSections]::Access)
$dpapiRules = @($dpapiAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
Assert ($dpapiAcl.AreAccessRulesProtected -and $dpapiRules.Count -eq 1 -and $dpapiRules[0].IdentityReference -eq $currentSid) 'Save-AccountFile restricts NTFS ACL to current user only'
$legacyPath = Join-Path $testDir 'legacy-acct.json'
Write-AtomicText $legacyPath '{"token":{"refresh_token":"legacy-plaintext-rt"}}'
Assert ((Read-AccountFile $legacyPath).token.refresh_token -eq 'legacy-plaintext-rt') 'Read-AccountFile remains backward-compatible with legacy plaintext JSON'
$corruptPath = Join-Path $testDir 'corrupt-dpapi.json'
Write-AtomicText $corruptPath '{"format":"dpapi-v1","protected_payload":"not-valid-dpapi"}'
$corruptFailed = $false
try { $null = Read-AccountFile $corruptPath } catch { $corruptFailed = $true }
Assert $corruptFailed 'Corrupt dpapi-v1 payload fails closed'
Remove-Item -LiteralPath $dpapiPath,$legacyPath,$corruptPath -Force

# --- 30-minute OAuth access_token cache and HTTP 401 retry tests ---
$savedCid = $script:GoogleClientId; $savedCsec = $script:GoogleClientSecret
$script:GoogleClientId = 'cache-test-id'; $script:GoogleClientSecret = 'cache-test-secret'
Clear-AccessTokenCache
$script:TokenHttpCalls = 0; $script:TokenExpiresIn = 3600; $script:Simulate401Once = $false
function Invoke-RestMethod {
    param($Uri,$Method,$Headers,$Body,$ContentType,$TimeoutSec,$ErrorAction)
    if ($Uri -eq 'https://oauth2.googleapis.com/token') {
        $script:TokenHttpCalls++
        return [pscustomobject]@{access_token="cached-tok-$($script:TokenHttpCalls)";expires_in=$script:TokenExpiresIn}
    }
    if ($Uri -match '/userinfo$') {
        if ($script:Simulate401Once) {
            $script:Simulate401Once = $false
            throw [Exception]::new('The remote server returned an error: (401) Unauthorized.')
        }
        return [pscustomobject]@{email='cache@example.test'}
    }
    if ($Uri -match ':loadCodeAssist$') { return [pscustomobject]@{cloudaicompanionProject='proj-1';currentTier=@{id='free-tier'}} }
    if ($Uri -match ':retrieveUserQuotaSummary$') {
        return [pscustomobject]@{groups=@([pscustomobject]@{displayName='Gemini Models';buckets=@([pscustomobject]@{window='5h';remainingFraction=.8},[pscustomobject]@{window='weekly';remainingFraction=.9})})}
    }
    if ($Uri -match ':fetchAvailableModels$') { return [pscustomobject]@{models=[pscustomobject]@{}} }
    throw "Unexpected URI: $Uri"
}
$cacheTok = [pscustomobject]@{token=@{refresh_token='cache-rt-1'}}
$t1 = Get-FreshToken $cacheTok
$t2 = Get-FreshToken $cacheTok
Assert ($script:TokenHttpCalls -eq 1 -and $t1.token.access_token -eq $t2.token.access_token) 'Get-FreshToken caches access_token for 30 minutes across repeated calls'
$cacheKey1 = Get-Sha256Hex 'cache-rt-1'
$ttl1 = ($script:AccessTokenCache[$cacheKey1].CacheExpiresAt - [datetime]::UtcNow).TotalSeconds
Assert ($ttl1 -gt 1700 -and $ttl1 -le 1805) '3600s expires_in is capped to 1800s cache TTL'
$t3 = Get-FreshToken $cacheTok -ForceRefresh
Assert ($script:TokenHttpCalls -eq 2 -and $t3.token.access_token -eq 'cached-tok-2') 'Get-FreshToken -ForceRefresh bypasses cache'
$script:TokenExpiresIn = 300
$null = Get-FreshToken ([pscustomobject]@{token=@{refresh_token='cache-rt-short'}})
$ttlShort = ($script:AccessTokenCache[(Get-Sha256Hex 'cache-rt-short')].CacheExpiresAt - [datetime]::UtcNow).TotalSeconds
Assert ($ttlShort -gt 200 -and $ttlShort -le 245) 'Short expires_in caps cache TTL at expires_in - 60'
Clear-AccessTokenCache
Assert ($script:AccessTokenCache.Count -eq 0) 'Clear-AccessTokenCache empties cached tokens'
$script:TokenExpiresIn = 3600; $script:TokenHttpCalls = 0
$retryAcctPath = Join-Path $testDir 'retry401.json'
Save-AccountFile $retryAcctPath '{"token":{"refresh_token":"retry-rt"}}'
$null = Get-FreshToken ([pscustomobject]@{token=@{refresh_token='retry-rt'}})
$script:Simulate401Once = $true
$retryQuota = Get-AccountQuotaInfo $retryAcctPath
Assert ($retryQuota.Success -and $script:TokenHttpCalls -eq 2) 'HTTP 401 invalidates cached access_token and retries once with ForceRefresh'
Remove-Item -LiteralPath $retryAcctPath -Force
Clear-AccessTokenCache
$script:GoogleClientId = $savedCid; $script:GoogleClientSecret = $savedCsec

# --- Account filename disambiguation and login crash-recovery backup tests (AST from AntigravityHub.ps1) ---
$hubAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'AntigravityHub.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in @('Resolve-AccountFileName','Get-LoginBackupPath','Save-LoginCredentialBackup','Restore-LoginCredentialBackup','Remove-LoginTempDirectory')) {
    $fnDef = $hubAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName}, $true)
    if (-not $fnDef) { throw "Missing function in AntigravityHub.ps1: $fnName" }
    Invoke-Expression $fnDef.Extent.Text
}
$nameDir = Join-Path $testDir 'names'
New-Item -ItemType Directory -Path $nameDir -Force | Out-Null
Save-AccountFile (Join-Path $nameDir 'alice.json') '{"token":{"refresh_token":"rt-gmail"}}'
function Get-CredentialEmail { param($Content) if ($Content -match 'rt-gmail') { 'alice@gmail.com' } else { 'other@example.test' } }
Assert ((Resolve-AccountFileName -Email 'alice@corp.com' -AccountsDir $nameDir -RefreshToken 'rt-corp') -eq 'alice_corp') 'Same email prefix on different domain disambiguates instead of overwriting'
Assert ((Resolve-AccountFileName -Email 'alice@gmail.com' -AccountsDir $nameDir -RefreshToken 'rt-gmail') -eq 'alice') 'Same email and refresh token reuses existing account filename'
Assert ((Resolve-AccountFileName -Email 'user+tag@gmail.com' -AccountsDir $nameDir -RefreshToken 'rt-tag') -eq 'user_tag') 'Plus-tagged email prefix is sanitized into switch-safe account name'
Assert ((Resolve-AccountFileName -Email 'con@example.com' -AccountsDir $nameDir -RefreshToken 'rt-con') -eq 'acc_con') 'Reserved Windows device name email prefix is prefixed safely'
Save-AccountFile (Join-Path $nameDir 'Acc_2.json') '{"token":{"refresh_token":"rt-acc2"}}'
Assert ((Resolve-AccountFileName -Email '' -AccountsDir $nameDir) -eq 'Acc_1') 'Offline account naming finds first free slot without overwriting gaps'

$script:BackupCred = 'mutated-by-crash'
function Get-StoredCredential { $script:BackupCred }
function Restore-StoredCredential { param($Content) $script:BackupCred = $Content }
function Remove-StoredCredential { $script:BackupCred = $null; $true }
function Write-RotatorLog { param($msg) }
$loginTmp = Join-Path $env:TEMP ('ag_login_' + (Get-Random -Minimum 100000 -Maximum 999999))
New-Item -ItemType Directory -Path $loginTmp -Force | Out-Null
$bp = Save-LoginCredentialBackup -OldCredential 'orig-cred-json' -OldFallback 'orig-fallback-json' -HadFallback $true -TempDir $loginTmp
Assert ((Test-Path -LiteralPath $bp) -and ([IO.File]::ReadAllText($bp) -notmatch 'orig-cred-json')) 'Login crash backup is encrypted on disk with DPAPI'
Write-AtomicText $geminiTokenPath 'mutated-fallback'
Assert (Restore-LoginCredentialBackup) 'Startup login crash backup recovery succeeds'
Assert ($script:BackupCred -eq 'orig-cred-json' -and [IO.File]::ReadAllText($geminiTokenPath) -eq 'orig-fallback-json' -and -not (Test-Path -LiteralPath $bp) -and -not (Test-Path -LiteralPath $loginTmp)) 'Startup recovery restores WinCred, fallback token, cleans temp dir, and deletes backup file'

Write-AtomicText (Join-Path $testDir 'target.json') '{"token":{"refresh_token":"fixture"}}'
function Write-RotatorLog { param($msg) }
function Send-ToastNotification { param($Message) }
$script:TargetArgonWeekly=1.0
function Get-AccountQuotaInfo { param($tokenFilePath) [pscustomobject]@{Success=$true;Email='target@example.test';Gemini5H=1.0;GeminiWeekly=1.0;ArgonWeekly=$script:TargetArgonWeekly} }
function Get-FreshToken { param($Token) [pscustomobject]@{token=@{access_token='fixture-only';refresh_token='fixture-only'}} }
function Get-RuntimeIdentity { $script:FixtureRuntime }
$script:ThrowDebugger=$false
function Get-RuntimeWindows { param($Runtime) if ($script:ThrowDebugger) { throw 'Debugger unavailable.' }; @([pscustomobject]@{Safe=$script:SafeWindow}) }
function Restore-RuntimeWindows { param($SavedWindows) $script:RestoredWindows++ }
$script:FixtureStoredCred='{"token":{"refresh_token":"fixture"}}'
function Get-StoredCredential { $script:FixtureStoredCred }
function Invoke-RestMethod { param($Uri) [pscustomobject]@{email=$script:StoredEmail} }
function Get-CredentialEmail { param($Content) if ($script:EmailBranch) { if ($Content -match 'different-token') { 'old@example.test' } else { 'target@example.test' } } else { $script:StoredEmail } }
function Set-StoredCredential { param($Content) $script:Writes++; if($script:FailWrite){throw 'fixture write failure'} }
function Restore-StoredCredential { param($Content) $script:Rollbacks++ }
function Remove-StoredCredential { $script:RollbackDeletes++; $true }
function Restart-AntigravityRuntime { param($Runtime) $script:Restarts++ }
function Wait-AntigravityIdentity { param($Email) $script:Verified }
function Reset-Fixture {
    $script:FixtureRuntime=[pscustomobject]@{Email='old@example.test';Idle=$true;Runtimes=@([pscustomobject]@{ProcessId=0})}
    $script:Writes=0; $script:Rollbacks=0; $script:RollbackDeletes=0; $script:Restarts=0; $script:RestoredWindows=0
    $script:Verified=$true; $script:FailWrite=$false; $script:SafeWindow=$true; $script:ThrowDebugger=$false
    $script:FixtureStoredCred='{"token":{"refresh_token":"fixture"}}'
    $script:StoredEmail='old@example.test'; $script:TargetArgonWeekly=1.0
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile }
    Write-AtomicText $geminiTokenPath 'old-fallback'
    Write-AtomicText $activeFile 'old-account'
}
Reset-Fixture
$script:TargetArgonWeekly=.05
Assert (-not (Switch-ActiveAccount 'target') -and $script:Writes -eq 0) 'Exhausted Gemini 4 Argon target quota is rejected before switching'
Assert ($script:LastSwitchMessage -eq (Get-SwitchFailureMessage 'Target quota unavailable or exhausted.')) 'Exhausted Argon target reports quota unavailable or exhausted'
Reset-Fixture
$script:FixtureRuntime.Idle=$false
Assert (-not (Switch-ActiveAccount 'target') -and $script:Writes -eq 0 -and $script:Restarts -eq 0) 'Running agent defers without writes'
Assert ($script:LastSwitchMessage -eq (Get-SwitchFailureMessage 'SwitchAgentRunning')) 'Running agent reports the specific deferral reason'
Reset-Fixture
$script:SafeWindow=$false
Assert (-not (Switch-ActiveAccount 'target') -and $script:Writes -eq 0) 'Unsaved draft defers without writes'
Assert ($script:LastSwitchMessage -eq (Get-SwitchFailureMessage 'Unsaved draft or focused editor; rotation deferred.')) 'Draft protection reports an actionable reason'
Reset-Fixture
$script:ThrowDebugger=$true
Assert (-not (Switch-ActiveAccount 'target') -and $script:Writes -eq 0) 'Unavailable debugger fails closed on automatic pre-2.34 switch'
Assert ($script:LastSwitchMessage -eq (Get-SwitchFailureMessage 'Debugger unavailable.')) 'Unavailable debugger reports actionable deferral reason'
Assert (Switch-ActiveAccount 'target' -Manual) 'Manual switch remains available when debugger is unavailable'
Reset-Fixture
$script:FixtureStoredCred=$null
Remove-Item -LiteralPath $geminiTokenPath -Force
$script:Verified=$false
Assert (-not (Switch-ActiveAccount 'target' -Manual) -and $script:RollbackDeletes -eq 1 -and $script:Rollbacks -eq 0) 'Manual switch rollback deletes credential cleanly when prior credential was null'
Reset-Fixture
Assert (Switch-ActiveAccount 'target') 'Verified transaction succeeds'
Assert ((Read-RotationState).Status -eq 'Verified' -and $script:Restarts -eq 1 -and $script:RestoredWindows -eq 1) 'Runtime restarted, navigation restored, identity verified'
Assert ((Get-Content $activeFile -Raw) -eq 'target') 'Active marker written only after verification'
Assert (-not (Switch-ActiveAccount 'target') -and $script:Writes -eq 1) 'Persistent cooldown blocks second switch'
Assert ($script:LastSwitchMessage -eq (Get-SwitchFailureMessage 'SwitchCooldown')) 'Cooldown explains why a repeated switch is deferred'
Assert ((Get-SwitchFailureMessage 'secret-fixture-provider-url') -notmatch 'secret-fixture-provider-url') 'Unknown switch exceptions never leak raw details'
Set-RotationState 'Verified' 'old-account' 'old@example.test'
$expired=Read-RotationState
$expired.UpdatedAt=[datetime]::UtcNow.AddMinutes(-3).ToString('o')
Write-AtomicText $stateFile ($expired | ConvertTo-Json -Compress)
Assert (Switch-ActiveAccount 'target') 'Manual switch accepts cooldown older than 120 real seconds'
Reset-Fixture
$script:Verified=$false
Assert (-not (Switch-ActiveAccount 'target')) 'Wrong runtime identity rejects success'
Assert ($script:Rollbacks -eq 1 -and (Read-RotationState).Status -eq 'NeedsAttention') 'Unverified switch rolls back and pauses'
Assert ((Get-Content $activeFile -Raw) -eq 'old-account') 'Failed switch preserves active marker'
Reset-Fixture
$script:FailWrite=$true
Assert (-not (Switch-ActiveAccount 'target') -and $script:Rollbacks -eq 1 -and $script:Restarts -eq 0) 'Credential write failure rolls back without restart'
Reset-Fixture
$script:FixtureRuntime=$null
Assert (Switch-ActiveAccount 'target') 'Closed IDE prepares account'
Assert ((Read-RotationState).Status -eq 'Prepared' -and $script:Restarts -eq 0 -and (Get-Content $activeFile -Raw) -eq 'old-account') 'Prepared account is not reported as active'
Reset-Fixture
foreach ($badName in @('../outside', "target`n", "..`n", 'CON', 'nul.backup', 'COM1', 'LPT9', 'alice.')) {
    Assert (-not (Switch-ActiveAccount $badName) -and $script:Writes -eq 0) "Invalid account name rejected: $($badName -replace "`n",'<LF>')"
}
Reset-Fixture
$script:StoredEmail='different@example.test'
Assert (-not (Switch-ActiveAccount 'target') -and $script:Writes -eq 0) 'Rollback credential must match runtime identity'
Reset-Fixture
Set-RotationState 'NeedsAttention' '' 'old@example.test'
$expired=Read-RotationState
$expired.UpdatedAt=[datetime]::UtcNow.AddMinutes(-3).ToString('o')
Write-AtomicText $stateFile ($expired | ConvertTo-Json -Compress)
Write-AtomicText (Join-Path $testDir 'target.json') '{"token":{"refresh_token":"target-token"}}'
Write-AtomicText (Join-Path $testDir 'old-account.json') '{"token":{"refresh_token":"different-token"}}'
$script:EmailBranch = $true
Assert (Repair-RotationState) 'Repair reconciles matching runtime and stored email even when refresh token string differs'
Assert ((Read-RotationState).Status -eq 'Verified' -and (Read-RotationState).Account -eq 'old-account') 'Reconciled state is Verified with matching account name'
Assert (([IO.File]::ReadAllText((Join-Path $testDir 'old-account.json')) | ConvertFrom-Json).format -eq 'dpapi-v1') 'Repair-RotationState persists refreshed account file using DPAPI'
$script:EmailBranch = $false
Reset-Fixture
$stateTs = [datetime]::UtcNow.AddMinutes(-3)
Set-RotationState 'NeedsAttention' '' 'old@example.test' $stateTs.ToString('o')
$script:FixtureRuntime=[pscustomobject]@{Email='old@example.test';Idle=$true;Runtimes=@([pscustomobject]@{ProcessId=444;CreationDate=$stateTs.AddMinutes(-5);NoCsrfBridge=$true})}
Assert (-not (Repair-RotationState)) 'Repair refuses tautological WinCred-vs-WinCred clear in NoCsrfBridge when runtime predates failure'
$script:FixtureRuntime=[pscustomobject]@{Email='old@example.test';Idle=$true;Runtimes=@([pscustomobject]@{ProcessId=555;CreationDate=$stateTs.AddMinutes(1);NoCsrfBridge=$true})}
Assert (Repair-RotationState) 'Repair accepts NoCsrfBridge runtime started after NeedsAttention timestamp'
Reset-Fixture
Set-RotationState 'NeedsAttention' '' 'old@example.test'
$expired=Read-RotationState
$expired.UpdatedAt=[datetime]::UtcNow.AddMinutes(-3).ToString('o')
Write-AtomicText $stateFile ($expired | ConvertTo-Json -Compress)
Write-AtomicText (Join-Path $testDir 'target.json') '{"token":{"refresh_token":"fixture"}}'
Assert (Switch-ActiveAccount 'target') 'Manual switch automatically reconciles previous NeedsAttention state when identities match'
Reset-Fixture
Set-RotationState 'NeedsAttention' '' 'old@example.test'
$expired=Read-RotationState
$expired.UpdatedAt=[datetime]::UtcNow.AddMinutes(-3).ToString('o')
Write-AtomicText $stateFile ($expired | ConvertTo-Json -Compress)
$script:StoredEmail='mismatch@example.test'
Assert (-not (Switch-ActiveAccount 'target')) 'Manual switch blocks when NeedsAttention cannot be reconciled'
Assert ($script:LastSwitchMessage -eq (Get-SwitchFailureMessage 'Previous switch requires reconciliation.')) 'Failure message indicates previous switch requires reconciliation'
function Get-AccountQuotaInfo {
    param($tokenFilePath,[switch]$IncludeModels)
    [pscustomobject]@{Success=$true;Email='target@example.test';ModelsStatus='Available';Gemini5H=0;GeminiWeekly=0;ArgonWeekly=0;QuotaGroups=@(@{Name='Claude and GPT models';Remaining=$script:ModelRemaining});ModelQuotas=@(@{Name='Claude Sonnet 5.5 (Medium)';Family='Sonnet';Status='Available';Remaining=$script:ModelRemaining})}
}
function Get-RuntimeSelectedModel {
    param($Runtime)
    $script:ModelReads++
    if($script:ChangeAfterRestart -and $script:ModelReads -gt 2){return 'Gemini 3.8 Flash High'}
    if($script:ChangeModel -and $script:ModelReads -gt 1){return 'Gemini 3.8 Flash High'}
    return 'Claude Sonnet 5.5 Medium'
}
Reset-Fixture
$script:ModelRemaining=.8;$script:ModelReads=0;$script:ChangeModel=$false
Assert (Switch-ActiveAccount 'target' -ExpectedModel 'Claude Sonnet 5.5 Medium' -ExpectedEmail 'old@example.test') 'Model-aware switch ignores exhausted unused Gemini and Argon quotas'
Reset-Fixture
$script:ModelRemaining=.2;$script:ModelReads=0
Assert (-not (Switch-ActiveAccount 'target' -ExpectedModel 'Claude Sonnet 5.5 Medium') -and $script:Writes -eq 0) 'Transaction rechecks selected-model target quota before credential writes'
Reset-Fixture
$script:ModelRemaining=.8;$script:ModelReads=0;$script:ChangeModel=$true
Assert (-not (Switch-ActiveAccount 'target' -ExpectedModel 'Claude Sonnet 5.5 Medium') -and $script:Writes -eq 0) 'Model changed during quota lookup aborts before credential writes'
Reset-Fixture
$script:ModelReads=0;$script:ChangeModel=$false
Assert (-not (Switch-ActiveAccount 'target' -ExpectedModel 'Gemini 3.8 Flash High') -and $script:Writes -eq 0) 'Stale automatic model intent cannot switch the current selection'
Reset-Fixture
Assert (-not (Switch-ActiveAccount 'target' -ExpectedEmail 'different@example.test') -and $script:Writes -eq 0) 'Changed active identity invalidates pending automatic switch'
Reset-Fixture
$script:ModelReads=0
Assert (Switch-ActiveAccount 'target') 'Manual switching remains available with selected-model quota policy'
Reset-Fixture
$script:ModelReads=0;$script:ChangeAfterRestart=$true
Assert (-not (Switch-ActiveAccount 'target' -ExpectedModel 'Claude Sonnet 5.5 Medium') -and $script:Rollbacks -eq 1 -and $script:Restarts -eq 2 -and (Read-RotationState).Status -eq 'NeedsAttention') 'Changed model after restart rolls back credential and restarts server to prevent split-brain'
} finally {
    $resolved = [IO.Path]::GetFullPath($testDir)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work')) + '\'
    if ($resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^test-[a-f0-9]{32}\z') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($script:Failed) { throw "$script:Failed test(s) failed" }
