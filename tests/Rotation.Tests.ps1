$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'AutoRotator.ps1')
function Assert($Condition,$Name){if(-not $Condition){throw $Name};Write-Host "PASS: $Name"}
$script:Selected='Claude Sonnet 5.5 Medium';$script:Idle=$true;$script:FixtureState=$null
$script:FixtureConfig=[pscustomobject]@{AutoRotationEnabled=$true;MinQuotaPercent=20;CooldownSeconds=120;EnableNotifications=$true}
function Get-HubConfig {$script:FixtureConfig}
$script:LogMessages = New-Object System.Collections.Generic.List[string]
function Write-RotatorLog {param($Message) $script:LogMessages.Add([string]$Message)}
$script:QuotaScanCalls = 0
function Get-RuntimeIdentity {[pscustomobject]@{Email='current@example.test';Idle=$script:Idle;Runtimes=@(@{})}}
function Get-RuntimeSelectedModel {param($Runtime) $script:Selected}
function Get-AllAccountsQuota {param([switch]$IncludeModels) $script:QuotaScanCalls++; Assert $IncludeModels 'Automatic scan includes model catalogs';$script:FixtureAccounts}
function Read-RotationState {$script:FixtureState}
function Switch-ActiveAccount {param($targetAccountName,$Reason,[switch]$Notify,$ExpectedModel,$ExpectedEmail) $script:Switched=$targetAccountName;$script:ExpectedModel=$ExpectedModel;$script:ExpectedEmail=$ExpectedEmail;$true}
function Account($Name,[double]$Quota,[string]$Status='Available',[double]$Shared=1){
    [pscustomobject]@{AccountName=$Name;Email="$Name@example.test";Success=$true;ModelsStatus='Available';Gemini5H=1;GeminiWeekly=1;ArgonWeekly=0;ModelQuotas=@([pscustomobject]@{Name='Claude Sonnet 5.5 (Medium)';Family='Sonnet';Remaining=$Quota;Status=$Status});QuotaGroups=@([pscustomobject]@{Name='Claude and GPT models';Window='weekly';Remaining=$Shared})}
}
function Check($Accounts,$Expected,$Name){$script:FixtureAccounts=$Accounts;$script:Switched='';Invoke-AutoRotationCheck;Assert ($script:Switched -eq $Expected) $Name}
Check @((Account current .19),(Account other .8)) 'other' 'Selected Sonnet below twenty percent rotates despite unrelated exhausted Argon'
Assert ($script:ExpectedModel -eq $script:Selected -and $script:ExpectedEmail -eq 'current@example.test') 'Transaction receives expected model and active identity for race protection'
Check @((Account current .20),(Account other .8)) '' 'Exactly twenty percent does not trigger'
Check @((Account current .21),(Account other .8)) '' 'Healthy selected model does not rotate for unused models'
Check @((Account current .1),(Account other .2)) '' 'Target must exceed twenty percent'
Check @((Account current .1),(Account other .1)) '' 'Exhausted pool never ping-pongs'
Check @((Account current .1),(Account other 1 Disabled)) '' 'Target without access is rejected'
Check @((Account current .1),(Account other -1 Unknown)) '' 'Unknown target quota is rejected'
Check @((Account current -1 Unknown),(Account other .9)) '' 'Unknown current quota never triggers rotation'
$failed=Account current .1;$failed.Success=$false
Check @($failed,(Account other .9)) '' 'Failed active quota request defers rather than forcing rotation'
$failed=Account other .9;$failed.ModelsStatus='Unavailable'
Check @((Account current .1),$failed) '' 'Failed target catalog never reuses stale model quota'
foreach($invalid in @($null,'NaN',1.5)){
    $invalidTarget=Account other .9;$invalidTarget.ModelQuotas[0].Remaining=$invalid
    Check @((Account current .1),$invalidTarget) '' 'Invalid model fraction is rejected before ranking'
}
Check @((Account current .9 Available .19),(Account other .9 Available .8)) 'other' 'Shared weekly limit below twenty percent triggers for selected Claude'
Check @((Account current .1),(Account other .9 Available .1)) '' 'High model percentage cannot override exhausted shared quota'
Check @((Account current .1),(Account lower .6),(Account best .9)) 'best' 'Best target has the most remaining quota for the selected model'
$wrong=Account other .9;$wrong.ModelQuotas[0].Name='Claude Sonnet 5.5 (High)'
Check @((Account current .1),$wrong) '' 'A different effort variant is not substituted for the selected model'
$script:Idle=$false
Check @((Account current .1),(Account other .9)) '' 'Busy agents defer rotation without switching'
$script:Idle=$true;$script:Selected=''
Check @((Account current .1),(Account other .9)) '' 'Unrecognized or ambiguous selected model fails closed'
$script:Selected='Claude Sonnet 5.5 Medium'
$script:FixtureState=@{Status='Verified';UpdatedAt=[datetime]::UtcNow.AddSeconds(-30).ToString('o')}
Check @((Account current .1),(Account other .9)) '' 'Persistent cooldown protects manual and automatic switches'
$script:FixtureState=@{Status='Verified';UpdatedAt=[datetime]::UtcNow.AddMinutes(-3).ToString('o')}
Check @((Account current .1),(Account other .9)) 'other' 'Expired cooldown permits automatic rotation'
foreach($name in @('Gemini 3.8 Flash High','Gemini 4 Neon Medium','Gemini 4 Argon Medium','Gemini 4 Hydrogen Medium','Gemini 4 Carbon High','Claude Opus 5.5 Medium','GPT-OSS 120B Medium','Orchestrator (Neon)','Orchestrator (Argon)','Orchestrator (Carbon)')){
    $script:Selected=$name;$current=Account current .1;$target=Account other .8
    foreach($account in @($current,$target)){$account.ModelQuotas[0].Name=$name;$account.ModelQuotas[0].Family=Get-ModelQuotaFamily '' $name;$account.QuotaGroups=@()}
    Check @($current,$target) 'other' "Selected model supported: $name"
}
foreach($family in @('Neon','Hydrogen')){
    $script:Selected="Gemini 4 $family Extra";$current=Account current .1;$target=Account other .8
    foreach($account in @($current,$target)){
        $account.ModelQuotas[0].Name="Gemini 4 $family (XHigh)";$account.ModelQuotas[0].Family=$family
        $account.QuotaGroups=@(@{Name='Gemini Models';Remaining=.9},@{Name='Gemini 4 Argon';Remaining=0},@{Name='Orchestrator (Neon)';Remaining=0})
    }
    Check @($current,$target) 'other' "$family Extra matches reported XHigh, ignoring unrelated groups"
    $target.QuotaGroups+=@{Name="Gemini 4 $family";Remaining=.1}
    Check @($current,$target) '' "$family quota respects the model's own group"
}
foreach($planner in @('Neon','Argon','Carbon')){
    $script:Selected="Orchestrator ($planner)";$current=Account current .1;$target=Account other .8
    $current.ModelQuotas[0].Name=$script:Selected;$current.ModelQuotas[0].Family='Orchestrator'
    $target.ModelQuotas[0].Name="Gemini 4 $planner Medium";$target.ModelQuotas[0].Family=$planner
    Check @($current,$target) '' "Standalone $planner quota does not establish Orchestrator access"
}
$script:FixtureConfig.AutoRotationEnabled=$false
$script:Switched='';$script:FixtureAccounts=@((Account current .1),(Account other .8))
Invoke-AutoRotationCheck
Assert ($script:Switched -eq '') 'Paused auto-rotation skips switching'

# Closed-IDE PauseScanWhenIdeClosed and CLI mode tests
$script:RuntimeOpen = $false
function Get-RuntimeIdentity {
    if ($script:RuntimeOpen) { return [pscustomobject]@{Email='current@example.test';Idle=$true;Runtimes=@(@{})} }
    return $null
}
$script:StoredLookups = 0
function Get-StoredActiveAccountName { $script:StoredLookups++; 'current' }
function CliAccount($Name,[double]$G5H,[double]$GW,[double]$Argon=-1){
    [pscustomobject]@{AccountName=$Name;Email="$Name@example.test";Success=$true;ModelsStatus='Available';Gemini5H=$G5H;GeminiWeekly=$GW;ArgonWeekly=$Argon;ModelQuotas=@();QuotaGroups=@()}
}

$script:FixtureConfig=[pscustomobject]@{AutoRotationEnabled=$true;CliRotationEnabled=$true;PauseScanWhenIdeClosed=$true;MinQuotaPercent=20;CooldownSeconds=120;EnableNotifications=$true}
$script:LogMessages.Clear(); $script:QuotaScanCalls = 0; $script:StoredLookups = 0
$script:FixtureAccounts=@((CliAccount current .1 .8),(CliAccount other .85 .9))
$script:Switched=''
Invoke-AutoRotationCheck
Invoke-AutoRotationCheck
Invoke-AutoRotationCheck
Assert ($script:Switched -eq '' -and $script:QuotaScanCalls -eq 0 -and $script:StoredLookups -eq 0) 'PauseScanWhenIdeClosed=true skips all Google API calls when IDE is closed'
Assert ($script:LogMessages.Count -eq 1 -and $script:LogMessages[0] -match 'paused') 'Closed-IDE pause log line is deduplicated across repeated ticks'
$script:RuntimeOpen = $true
$script:FixtureAccounts=@((Account current .8),(Account other .8))
Invoke-AutoRotationCheck
$script:RuntimeOpen = $false
$script:LogMessages.Clear()
Invoke-AutoRotationCheck
Assert ($script:LogMessages.Count -eq 1 -and $script:LogMessages[0] -match 'paused') 'Closed-IDE pause log resets after IDE resumes and closes again'

$script:FixtureConfig=[pscustomobject]@{AutoRotationEnabled=$true;CliRotationEnabled=$true;PauseScanWhenIdeClosed=$false;MinQuotaPercent=20;CooldownSeconds=120;EnableNotifications=$true}
Check @((CliAccount current .1 .8),(CliAccount other .85 .9)) 'other' 'CLI mode rotates when IDE is closed, PauseScanWhenIdeClosed=false, and active quota is low'
Check @((CliAccount current .75 .8),(CliAccount other .9 .95)) '' 'CLI mode skips rotation when active quota is healthy'
$script:FixtureConfig.CliRotationEnabled=$false
$script:QuotaScanCalls = 0; $script:LogMessages.Clear()
Check @((CliAccount current .1 .8),(CliAccount other .85 .9)) '' 'CLI mode respects disabled CliRotationEnabled setting'
Invoke-AutoRotationCheck
Assert ($script:QuotaScanCalls -eq 0 -and $script:LogMessages.Count -eq 1) 'Disabled CliRotationEnabled makes zero API calls and deduplicates log'
