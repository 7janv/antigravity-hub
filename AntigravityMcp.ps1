param([switch]$AllowSwitch, [switch]$LibraryOnly)
$ErrorActionPreference='Stop'
# stdout belongs exclusively to newline-delimited JSON-RPC. No GUI or daemon starts.
try { . (Join-Path $PSScriptRoot 'AutoRotator.ps1') 3>$null 4>$null 5>$null 6>$null }
catch { [Console]::Error.WriteLine('Cannot initialize Antigravity Hub. Check Windows/OAuth configuration.'); exit 1 }
$script:McpAllowSwitch=[bool]$AllowSwitch
$script:McpInitialized=$false
$script:McpInitializeReceived=$false
$script:McpAccountsCooldownSeconds=5
$script:McpAccountsCache=$null
$script:McpAccountsLastAttemptUtc=[datetime]::MinValue

function Reset-McpAccountsCooldown {
    $script:McpAccountsCache=$null
    $script:McpAccountsLastAttemptUtc=[datetime]::MinValue
}

function Test-McpAccountName {
    param($Value)
    if ($Value -isnot [string]) { return $false }
    if ($Value.Length -lt 1 -or $Value.Length -gt 200) { return $false }
    if ($Value -notmatch '^[a-zA-Z0-9_.@-]+\z') { return $false }
    if ($Value -in @('.','..') -or $Value.EndsWith('.')) { return $false }
    $stem=$Value.Split('.')[0]
    if ($stem -match '^(?i)(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z') { return $false }
    return $true
}

function Get-McpTools {
    $none=@{type='object';properties=@{};additionalProperties=$false}
    @(
        @{name='antigravity_status';description='Read local Antigravity Desktop identity and rotation state. Does not expose tokens.';inputSchema=$none;annotations=@{readOnlyHint=$true;openWorldHint=$false}}
        @{name='antigravity_accounts';description='Read quota for local saved Google accounts. Network requests to Google; no account switching.';inputSchema=$none;annotations=@{readOnlyHint=$true;openWorldHint=$true}}
    )
    if ($script:McpAllowSwitch) {
        @(
            @{name='antigravity_rotate_if_needed';description='Check quota and rotate local Antigravity Desktop only when low, idle and draft-free. May restart its language server. Does not rotate credentials of an independent MCP/provider.';inputSchema=$none;annotations=@{readOnlyHint=$false;destructiveHint=$true;idempotentHint=$false;openWorldHint=$true}}
            @{name='antigravity_switch_account';description='Switch local Antigravity Desktop to a saved account. May restart its language server; existing safety checks still apply. Requires account name from antigravity_accounts.';inputSchema=@{type='object';properties=@{account=@{type='string';minLength=1;maxLength=200;pattern='^[a-zA-Z0-9_.@-]+$'}};required=@('account');additionalProperties=$false};annotations=@{readOnlyHint=$false;destructiveHint=$true;idempotentHint=$false;openWorldHint=$true}}
            @{name='antigravity_reconcile';description='Reconcile a paused rotation only when runtime identity matches stored credentials. Updates Hub state; does not restart the IDE.';inputSchema=$none;annotations=@{readOnlyHint=$false;destructiveHint=$false;idempotentHint=$true;openWorldHint=$true}}
        )
    }
}

function Get-McpStatus {
    $runtime=$null; $runtimeError=$null
    try { $runtime=Get-RuntimeIdentity } catch { $runtimeError=Get-RuntimeFailureMessage $_ }
    $state=Read-RotationState
    # Explicit projection: never serialize runtime objects (they contain CSRF).
    @{
        scope='local_antigravity_desktop'; switchEnabled=$script:McpAllowSwitch
        connected=[bool]$runtime; email=$(if($runtime){$runtime.Email}else{$null})
        idle=$(if($runtime){[bool]$runtime.Idle}else{$null}); runtimeError=$runtimeError
        rotation=$(if($state){@{status=$state.Status;account=$state.Account;email=$state.Email;updatedAt=$state.UpdatedAt}}else{$null})
    }
}

function Invoke-McpTool {
    param([string]$Name, $Arguments)
    if ($null -eq $Arguments) { $Arguments=[pscustomobject]@{} }
    if ($Arguments -isnot [pscustomobject]) { throw 'Invalid arguments' }
    $keys=@($Arguments.PSObject.Properties | ForEach-Object { $_.Name })
    $known=@(Get-McpTools | ForEach-Object { $_.name })
    if ($Name -notin $known) { throw 'Unknown or disabled tool' }
    if ($Name -eq 'antigravity_switch_account') {
        if ($keys.Count -ne 1 -or $keys[0] -ne 'account' -or -not (Test-McpAccountName $Arguments.account)) { throw 'Invalid account' }
    } elseif ($keys.Count) { throw 'Unexpected arguments' }
    switch ($Name) {
        'antigravity_status' { return Get-McpStatus }
        'antigravity_accounts' {
            $now=[datetime]::UtcNow
            if ($script:McpAccountsCooldownSeconds -gt 0 -and
                ($now - $script:McpAccountsLastAttemptUtc).TotalSeconds -lt $script:McpAccountsCooldownSeconds) {
                if ($null -ne $script:McpAccountsCache) {
                    return @{accounts=$script:McpAccountsCache;cached=$true}
                }
                throw 'Rate limited'
            }
            $script:McpAccountsLastAttemptUtc=$now
            $accounts=@(Get-AllAccountsQuota | ForEach-Object {
                $hasArgon=$_.Success -and $null -ne $_.ArgonWeekly -and [double]$_.ArgonWeekly -ge 0
                @{account=$_.AccountName;email=$_.Email;quotaAvailable=[bool]$_.Success
                  remaining5h=$(if($_.Success){$_.Gemini5H}else{$null})
                  remainingWeekly=$(if($_.Success){$_.GeminiWeekly}else{$null})
                  remainingArgonWeekly=$(if($hasArgon -and $_.ArgonQuotaSource -ne 'ModelCatalog'){$_.ArgonWeekly}else{$null})
                  remainingArgon=$(if($hasArgon){$_.ArgonWeekly}else{$null})
                  argonStatus=$(if($_.ArgonStatus -in @('Available','Disabled','Unknown')){$_.ArgonStatus}elseif($hasArgon){'Available'}else{'Unknown'})
                  argonQuotaSource=$(if($_.ArgonQuotaSource -in @('Summary','ModelCatalog')){$_.ArgonQuotaSource}else{$null})}
            })
            $script:McpAccountsCache=$accounts
            return @{accounts=$accounts}
        }
        'antigravity_switch_account' {
            $accepted=Switch-ActiveAccount -targetAccountName $Arguments.account 3>$null 4>$null 5>$null 6>$null
            if ($accepted) { Reset-McpAccountsCooldown }
            return @{operationAccepted=[bool]$accepted;status=(Get-McpStatus)}
        }
        'antigravity_rotate_if_needed' {
            Invoke-AutoRotationCheck 3>$null 4>$null 5>$null 6>$null | Out-Null
            Reset-McpAccountsCooldown
            # A completed check may deliberately do nothing. Do not claim a switch.
            return @{checkCompleted=$true;status=(Get-McpStatus)}
        }
        'antigravity_reconcile' {
            $accepted=Repair-RotationState 3>$null 4>$null 5>$null 6>$null
            if ($accepted) { Reset-McpAccountsCooldown }
            return @{reconciled=[bool]$accepted;status=(Get-McpStatus)}
        }
    }
}

function New-McpError {
    param($Id,[int]$Code,[string]$Message)
    @{jsonrpc='2.0';id=$Id;error=@{code=$Code;message=$Message}}
}

function Invoke-McpMessage {
    param([string]$Line)
    try { $request=ConvertFrom-Json -InputObject $Line -ErrorAction Stop }
    catch { return New-McpError $null -32700 'Parse error' }
    if ($request -isnot [pscustomobject] -or $request.jsonrpc -cne '2.0' -or $request.method -isnot [string]) {
        return New-McpError $null -32600 'Invalid request'
    }
    $hasId=$request.PSObject.Properties.Name -contains 'id'
    if (-not $hasId) {
        if ($request.method -ceq 'notifications/initialized' -and $script:McpInitializeReceived) { $script:McpInitialized=$true }
        return # Never execute tools from a notification.
    }
    $id=$request.id
    if ($null -eq $id -or ($id -isnot [string] -and $id -isnot [int] -and $id -isnot [long])) {
        return New-McpError $null -32600 'Invalid request id'
    }
    if ($null -ne $request.params -and $request.params -isnot [pscustomobject]) { return New-McpError $id -32602 'Invalid params' }
    switch -CaseSensitive ($request.method) {
        'initialize' {
            if ($script:McpInitializeReceived) { return New-McpError $id -32600 'Already initialized' }
            if ($request.params.protocolVersion -isnot [string] -or $request.params.clientInfo -isnot [pscustomobject] -or $request.params.capabilities -isnot [pscustomobject]) {
                return New-McpError $id -32602 'Invalid initialization params'
            }
            $version=$request.params.protocolVersion
            if ($version -notin @('2024-11-05','2025-03-26','2025-06-18','2025-11-25')) { $version='2025-11-25' }
            $script:McpInitializeReceived=$true
            return @{jsonrpc='2.0';id=$id;result=@{protocolVersion=$version;capabilities=@{tools=@{listChanged=$false}};serverInfo=@{name='antigravity-auto-hub';version='1.0.0'};instructions='Controls local Windows Antigravity Desktop only. No token export. Independent MCP providers require their own credential adapter. Switching may restart the language server; wait for idle and no drafts.'}}
        }
        'ping' { return @{jsonrpc='2.0';id=$id;result=@{}} }
        default {
            if (-not $script:McpInitialized) { return New-McpError $id -32002 'Initialize the session first' }
            if ($request.method -ceq 'tools/list') {
                return @{jsonrpc='2.0';id=$id;result=@{tools=@(Get-McpTools)}}
            }
            if ($request.method -cne 'tools/call') { return New-McpError $id -32601 'Method not found' }
            if ($request.params.name -isnot [string]) { return New-McpError $id -32602 'Missing tool name' }
            try {
                $value=Invoke-McpTool $request.params.name $request.params.arguments
                $failed=($value.ContainsKey('operationAccepted') -and -not $value.operationAccepted) -or
                    ($value.ContainsKey('reconciled') -and -not $value.reconciled)
                $result=@{content=@(@{type='text';text=($value | ConvertTo-Json -Depth 15 -Compress)});isError=[bool]$failed}
            } catch {
                # Do not serialize exception messages: downstream errors can contain credentials.
                $result=@{content=@(@{type='text';text='Tool unavailable, invalid arguments, or operation failed. Check local Hub configuration and rotator.log.'});isError=$true}
            }
            return @{jsonrpc='2.0';id=$id;result=$result}
        }
    }
}

function New-McpLineReader {
    param([IO.Stream]$Stream, [int]$MaxBytes=65536)
    [pscustomobject]@{
        Stream=$Stream; MaxBytes=$MaxBytes; Buffer=(New-Object byte[] 4096)
        Offset=0; Count=0; FirstLine=$true; Eof=$false
        Encoding=[Text.UTF8Encoding]::new($false)
    }
}

function Read-McpBoundedLine {
    param($Reader)
    $acc=[IO.MemoryStream]::new()
    $tooLarge=$false
    $hasData=$false
    $maxAllow=$Reader.MaxBytes + 4
    try {
        while ($true) {
            if ($Reader.Offset -ge $Reader.Count) {
                if ($Reader.Eof) { break }
                $read=$Reader.Stream.Read($Reader.Buffer, 0, $Reader.Buffer.Length)
                if ($read -le 0) { $Reader.Eof=$true; break }
                $Reader.Offset=0; $Reader.Count=$read
            }
            $available=$Reader.Count - $Reader.Offset
            $nlIndex=[Array]::IndexOf($Reader.Buffer, [byte]10, $Reader.Offset, $available)
            $foundNewline=($nlIndex -ge 0)
            $take=if ($foundNewline) { $nlIndex - $Reader.Offset } else { $available }
            $hasData=$true
            if (-not $tooLarge -and $take -gt 0) {
                if (($acc.Length + $take) -gt $maxAllow) {
                    $tooLarge=$true
                    $acc.SetLength(0)
                } else {
                    $acc.Write($Reader.Buffer, $Reader.Offset, $take)
                }
            }
            $Reader.Offset=if ($foundNewline) { $nlIndex + 1 } else { $Reader.Count }
            if ($foundNewline) { break }
        }
        if (-not $hasData) {
            return [pscustomobject]@{Eof=$true; TooLarge=$false; Line=$null}
        }
        if ($tooLarge) {
            $Reader.FirstLine=$false
            return [pscustomobject]@{Eof=$false; TooLarge=$true; Line=$null}
        }
        $bytes=$acc.ToArray()
        $start=0; $len=$bytes.Length
        if ($Reader.FirstLine) {
            $Reader.FirstLine=$false
            if ($len -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $start=3; $len-=3
            }
        }
        if ($len -gt 0 -and $bytes[$start + $len - 1] -eq 0x0D) { $len-- }
        if ($len -gt $Reader.MaxBytes) {
            return [pscustomobject]@{Eof=$false; TooLarge=$true; Line=$null}
        }
        $text=$Reader.Encoding.GetString($bytes, $start, $len)
        return [pscustomobject]@{Eof=$false; TooLarge=$false; Line=$text}
    } finally {
        $acc.Dispose()
    }
}

if (-not $LibraryOnly) {
    # Read redirected UTF-8 directly with a strict byte cap before buffering;
    # Console encoding/codepage can prepend or misread the first BOM on Windows.
    $lineReader=New-McpLineReader ([Console]::OpenStandardInput()) 65536
    $outputWriter=[IO.StreamWriter]::new([Console]::OpenStandardOutput(), [Text.UTF8Encoding]::new($false))
    $outputWriter.AutoFlush=$true
    while ($true) {
        $entry=Read-McpBoundedLine $lineReader
        if ($entry.Eof) { break }
        try {
            if ($entry.TooLarge) { $response=New-McpError $null -32600 'Request too large' }
            else {
                if ([string]::IsNullOrWhiteSpace($entry.Line)) { continue }
                $response=Invoke-McpMessage $entry.Line
            }
            if ($null -ne $response) { $outputWriter.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress)) }
        } catch { $outputWriter.WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}') }
    }
}
