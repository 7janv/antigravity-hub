$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'AntigravityMcp.ps1') -LibraryOnly
$script:Checks=0
function Assert($condition,[string]$name) {
    if (-not $condition) { throw "FAIL: $name" }
    $script:Checks++; Write-Host "PASS: $name"
}
function Message($method,$parameters=@{},$id=1) {
    Invoke-McpMessage (@{jsonrpc='2.0';id=$id;method=$method;params=$parameters} | ConvertTo-Json -Depth 8 -Compress)
}
Assert ((Invoke-McpMessage '{bad').error.code -eq -32700) 'Malformed JSON returns parse error'
Assert ((Invoke-McpMessage '[]').error.code -eq -32600) 'Batch request rejected'
Assert ((Message 'tools/list').error.code -eq -32002) 'Tools unavailable before initialization'
$hello=Message 'initialize' @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='tests';version='1'}}
Assert ($hello.result.protocolVersion -eq '2025-06-18') 'MCP version negotiation'
$notification=Invoke-McpMessage '{"jsonrpc":"2.0","method":"notifications/initialized"}'
Assert ($null -eq $notification -and $script:McpInitialized) 'Initialized notification produces no output'
$listing=Message 'tools/list'
Assert (@($listing.result.tools).Count -eq 2) 'Default server exposes read-only tools'
Assert ((Message 'ping').result.Count -eq 0) 'Ping supported'
Assert ((Message 'unsupported').error.code -eq -32601) 'Unknown RPC rejected'

$script:SwitchCalls=0
function Get-RuntimeIdentity { [pscustomobject]@{Email='fixture@example.test';Idle=$true;Runtimes=@(@{Csrf='SECRET_SENTINEL'})} }
function Read-RotationState { [pscustomobject]@{Status='Verified';Account='fixture';Email='fixture@example.test';UpdatedAt='2026-09-16';Private='SECRET_SENTINEL'} }
function Get-AllAccountsQuota { @([pscustomobject]@{AccountName='fixture';Email='fixture@example.test';Success=$false;Gemini5H=-1;GeminiWeekly=-1;ArgonWeekly=-1;TokenPath='SECRET_SENTINEL';Error='SECRET_SENTINEL'}) }
function Switch-ActiveAccount { param($targetAccountName) $script:SwitchCalls++; Write-Host 'not protocol'; $script:SwitchResult }
function Invoke-AutoRotationCheck { Write-Host 'not protocol' }
function Repair-RotationState { $false }
$status=Message 'tools/call' @{name='antigravity_status';arguments=@{}}
$text=$status | ConvertTo-Json -Depth 12
Assert (-not $text.Contains('SECRET_SENTINEL') -and $text.Contains('fixture@example.test')) 'Status uses allowlist projection without CSRF'
$accounts=Message 'tools/call' @{name='antigravity_accounts';arguments=@{}}
$data=$accounts.result.content[0].text | ConvertFrom-Json
Assert ($null -eq $data.accounts[0].remaining5h -and $null -eq $data.accounts[0].remainingArgonWeekly -and -not ($accounts | ConvertTo-Json -Depth 12).Contains('SECRET_SENTINEL')) 'Unknown quota stays null, token paths omitted'
$script:QuotaCalls=0
Reset-McpAccountsCooldown
function Get-AllAccountsQuota { $script:QuotaCalls++; @(
    [pscustomobject]@{AccountName='disabled';Success=$true;Gemini5H=1;GeminiWeekly=1;ArgonWeekly=-1;ArgonStatus='Disabled';ArgonQuotaSource='ModelCatalog'},
    [pscustomobject]@{AccountName='enabled';Success=$true;Gemini5H=1;GeminiWeekly=1;ArgonWeekly=.6;ArgonStatus='Available';ArgonQuotaSource='ModelCatalog'}
) }
$accounts=Message 'tools/call' @{name='antigravity_accounts';arguments=@{}}
$data=$accounts.result.content[0].text|ConvertFrom-Json
Assert ($data.accounts[0].argonStatus -eq 'Disabled' -and $null -eq $data.accounts[0].remainingArgon) 'MCP exposes disabled Argon separately from zero or unknown quota'
Assert ($data.accounts[1].remainingArgon -eq .6 -and $null -eq $data.accounts[1].remainingArgonWeekly -and $data.accounts[1].argonQuotaSource -eq 'ModelCatalog') 'MCP model quota does not claim an unreported weekly window'
$cachedAccounts=Message 'tools/call' @{name='antigravity_accounts';arguments=@{}}
$cachedData=$cachedAccounts.result.content[0].text|ConvertFrom-Json
Assert ($script:QuotaCalls -eq 1 -and $cachedData.cached -eq $true -and $cachedData.accounts.Count -eq 2) 'Rapid repeated antigravity_accounts call is served from cooldown cache'
$blocked=Message 'tools/call' @{name='antigravity_switch_account';arguments=@{account='fixture'}}
Assert ($blocked.result.isError -and $script:SwitchCalls -eq 0) 'Read-only gate enforced on tool execution'
$script:McpAllowSwitch=$true
Assert (@((Message 'tools/list').result.tools).Count -eq 5) 'Explicit switch permission exposes mutation tools'
foreach ($args in @(
    @{account='../escape'},@{account='fixture';force=$true},@{account=123},@{},
    @{account="..`n"},@{account="fixture`n"},@{account='fixture.'},@{account='...'},
    @{account='CON'},@{account='con.json'},@{account='PRN'},@{account='AUX'},
    @{account='NUL.txt'},@{account='COM1'},@{account='com9.bak'},@{account='LPT1'},@{account='lpt9.json'}
)) {
    $result=Message 'tools/call' @{name='antigravity_switch_account';arguments=$args}
    Assert ($result.result.isError -and $script:SwitchCalls -eq 0) 'Invalid mutation arguments rejected'
}
Assert ((Test-McpAccountName 'console') -and (Test-McpAccountName 'user.name@example.test') -and (Test-McpAccountName 'COM0')) 'Valid non-reserved account names remain accepted'
$notification=Invoke-McpMessage '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"antigravity_switch_account","arguments":{"account":"fixture"}}}'
Assert ($null -eq $notification -and $script:SwitchCalls -eq 0) 'Mutation notifications never execute'
$script:SwitchResult=$false
$rejected=Message 'tools/call' @{name='antigravity_switch_account';arguments=@{account='fixture'}}
Assert ($rejected.result.isError -and $script:SwitchCalls -eq 1) 'Deferred switch returns tool error'
$script:SwitchResult=$true
$accepted=Message 'tools/call' @{name='antigravity_switch_account';arguments=@{account='fixture'}}
Assert (-not $accepted.result.isError -and $script:SwitchCalls -eq 2) 'Switch delegates to existing engine'
$check=Message 'tools/call' @{name='antigravity_rotate_if_needed';arguments=@{}}
Assert (($check.result.content[0].text | ConvertFrom-Json).checkCompleted -and -not $check.result.content[0].text.Contains('switched')) 'Quota check does not claim a switch'
Reset-McpAccountsCooldown
$script:FailCalls=0
function Get-AllAccountsQuota { $script:FailCalls++; throw 'SECRET_SENTINEL' }
$failure=Message 'tools/call' @{name='antigravity_accounts';arguments=@{}}
Assert ($failure.result.isError -and -not ($failure | ConvertTo-Json -Depth 12).Contains('SECRET_SENTINEL')) 'Downstream exceptions redacted'
$throttled=Message 'tools/call' @{name='antigravity_accounts';arguments=@{}}
Assert ($throttled.result.isError -and $script:FailCalls -eq 1) 'Repeated failed antigravity_accounts call is rate limited during cooldown'

# Verify Convert-QuotaGroups control-character stripping and 160-char caps.
$sanitizedGroups=@(Convert-QuotaGroups ([pscustomobject]@{groups=@(
    [pscustomobject]@{displayName="  Gemini`tModels`r`n";buckets=@(
        [pscustomobject]@{window="5h`nwindow";remainingFraction=.5;resetTime='2026-10-01T00:00:00Z'}
        [pscustomobject]@{window=('w'*161);remainingFraction=.9;resetTime='2026-10-01T00:00:00Z'}
    )}
    [pscustomobject]@{displayName=('g'*161);buckets=@([pscustomobject]@{window='weekly';remainingFraction=.5})}
    [pscustomobject]@{displayName="`t`n";buckets=@([pscustomobject]@{window='weekly';remainingFraction=.5})}
)}))
Assert ($sanitizedGroups.Count -eq 1 -and $sanitizedGroups[0].Name -ceq 'Gemini Models' -and $sanitizedGroups[0].Window -ceq '5h window') 'Convert-QuotaGroups strips control chars and enforces 160-char caps'

# Verify bounded line reader rejects lines exceeding 65536 bytes and recovers on the next line.
$bom=[byte[]]@(0xEF,0xBB,0xBF)
$exactBytes=[Text.Encoding]::UTF8.GetBytes(('a'*65536)+"`r`n")
$overBytes=[Text.Encoding]::UTF8.GetBytes(('b'*70000)+"`n")
$afterBytes=[Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","id":7,"method":"ping"}'+"`n")
$mem=[IO.MemoryStream]::new()
try {
    $mem.Write($bom,0,$bom.Length); $mem.Write($exactBytes,0,$exactBytes.Length)
    $mem.Write($overBytes,0,$overBytes.Length); $mem.Write($afterBytes,0,$afterBytes.Length)
    $mem.Position=0
    $reader=New-McpLineReader $mem 65536
    $e1=Read-McpBoundedLine $reader
    $e2=Read-McpBoundedLine $reader
    $e3=Read-McpBoundedLine $reader
    $e4=Read-McpBoundedLine $reader
    Assert (-not $e1.Eof -and -not $e1.TooLarge -and $e1.Line.Length -eq 65536) 'Bounded reader accepts exact 65536-byte line with BOM and CRLF'
    Assert (-not $e2.Eof -and $e2.TooLarge -and $null -eq $e2.Line) 'Bounded reader rejects oversized line without buffering unbounded memory'
    Assert (-not $e3.Eof -and -not $e3.TooLarge -and $e3.Line -ceq '{"jsonrpc":"2.0","id":7,"method":"ping"}') 'Bounded reader recovers cleanly on subsequent line'
    Assert $e4.Eof 'Bounded reader signals EOF cleanly'
} finally { $mem.Dispose() }

# Real stdio subprocess from a fresh folder with spaces, no account files/config.
$stage=Join-Path $repo ('work\mcp smoke ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($file in @('AntigravityMcp.ps1','AutoRotator.ps1','RotationCore.ps1','ModelQuota.ps1','RuntimeBridge.ps1','Configure-Mcp.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $stage
    }
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName='powershell.exe'
    $psi.Arguments='-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $stage 'AntigravityMcp.ps1') + '"'
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables.Remove('ANTIGRAVITY_GOOGLE_CLIENT_ID')
    $psi.EnvironmentVariables.Remove('ANTIGRAVITY_GOOGLE_CLIENT_SECRET')
    $process=[Diagnostics.Process]::Start($psi)
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
    $lines=@(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
        '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"antigravity_accounts","arguments":{}}}'
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"antigravity_switch_account","arguments":{"account":"fixture"}}}'
        ('{"jsonrpc":"2.0","id":5,"method":"ping","pad":"' + ('x'*70000) + '"}')
        '{"jsonrpc":"2.0","id":6,"method":"ping"}'
    )
    # Exercise the Windows UTF-8 BOM case explicitly, independent of the host codepage.
    $inputWriter=[IO.StreamWriter]::new($process.StandardInput.BaseStream, [Text.UTF8Encoding]::new($true))
    foreach ($line in $lines) { $inputWriter.WriteLine($line) }
    $inputWriter.Close()
    if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'MCP smoke timed out' }
    $stdout=$outTask.GetAwaiter().GetResult(); $stderr=$errTask.GetAwaiter().GetResult()
    Assert ($process.ExitCode -eq 0 -and -not $stderr) 'Fresh-clone server exits cleanly at EOF'
    $responses=@($stdout -split '\r?\n' | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json $_ })
    Assert ($responses.Count -eq 6 -and $responses[0].result.protocolVersion -eq '2025-11-25' -and @($responses | Where-Object {$_.jsonrpc -ne '2.0'}).Count -eq 0) 'UTF-8 BOM input initializes; stdout contains only JSON-RPC'
    Assert (@($responses[1].result.tools).Count -eq 2 -and $responses[3].result.isError) 'Real subprocess enforces read-only default'
    Assert (@(($responses[2].result.content[0].text | ConvertFrom-Json).accounts).Count -eq 0) 'Fresh clone empty pool works without OAuth secrets'
    Assert ($responses[4].error.code -eq -32600 -and $responses[5].id -eq 6 -and @($responses[5].result.PSObject.Properties).Count -eq 0) 'Subprocess rejects >64 KB request and still serves subsequent ping'
    $config=(& powershell.exe -NoProfile -File (Join-Path $stage 'Configure-Mcp.ps1') -AllowSwitch) | Out-String | ConvertFrom-Json
    $server=$config.mcpServers.'antigravity-auto-hub'
    Assert ($server.args -contains (Join-Path $stage 'AntigravityMcp.ps1') -and $server.args -contains '-AllowSwitch') 'Generated config uses actual clone path with spaces'
} finally {
    $resolved=[IO.Path]::GetFullPath($stage)
    $allowedRoot=[IO.Path]::GetFullPath((Join-Path $repo 'work'))+'\'
    if ($resolved.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^mcp smoke [a-f0-9]{32}\z') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "MCP: $script:Checks checks passed"
