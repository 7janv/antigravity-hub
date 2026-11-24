$ErrorActionPreference='Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'AutoRotator.ps1')
function Assert($Value,$Name){if(-not $Value){throw $Name};Write-Host "PASS: $Name"}
function Test-Path {param($LiteralPath) $true}
function Get-Content {param($LiteralPath,$First) '9222'}
function Get-NetTCPConnection {param($LocalPort,$State,$ErrorAction) [pscustomobject]@{OwningProcess=$script:Owner;LocalAddress='127.0.0.1'}}
function Invoke-RestMethod {param($Uri,$TimeoutSec,$ErrorAction) $script:Pages}
$script:Owner=123
$runtime=[pscustomobject]@{ParentProcessId=123;Port=5000}
$real=[pscustomobject]@{id='fixture';type='page';url='https://127.0.0.1:5000/';webSocketDebuggerUrl='ws://127.0.0.1:9222/devtools/page/fixture'}
$script:Pages=@($real,[pscustomobject]@{type='page';url='data:text/html,fixture'},[pscustomobject]@{type='page';url='about:blank'})
Assert (@(Get-RuntimePages $runtime).Count -eq 1) 'Authenticated IDE pages remain scoped while unrelated data preview pages are excluded'
$script:Pages=@($real,[pscustomobject]@{type='page';url='https://example.test/'})
$failed=$false;try{Get-RuntimePages $runtime|Out-Null}catch{$failed=$true}
Assert $failed 'Unexpected network page fails closed rather than inspecting its content'
$script:Pages=@($real);$script:Owner=999
$failed=$false;try{Get-RuntimePages $runtime|Out-Null}catch{$failed=$true}
Assert $failed 'Debugger must belong to the verified Antigravity process'

# Antigravity 2.34+ (NoCsrfBridge, Port=0) CDP page validation tests
$script:Owner=123
$noCsrfRuntime=[pscustomobject]@{ProcessId=456;ParentProcessId=123;Port=0;NoCsrfBridge=$true}
$page234=[pscustomobject]@{id='p234';type='page';url='https://127.0.0.1:54321/';webSocketDebuggerUrl='ws://127.0.0.1:9222/devtools/page/p234'}
function Get-NetTCPConnection {
    param($LocalPort,$State,$ErrorAction)
    if ($LocalPort -eq 9222) { return [pscustomobject]@{OwningProcess=123;LocalAddress='127.0.0.1'} }
    if ($LocalPort -eq 54321) { return [pscustomobject]@{OwningProcess=$script:LsPortOwner;LocalAddress='127.0.0.1'} }
    return @()
}
$script:LsPortOwner=456
$script:Pages=@($page234)
Assert (@(Get-RuntimePages $noCsrfRuntime).Count -eq 1) 'NoCsrfBridge (Port=0) accepts loopback HTTPS page owned by language_server.exe'
$script:LsPortOwner=9999
$failed=$false;try{Get-RuntimePages $noCsrfRuntime|Out-Null}catch{$failed=$true}
Assert $failed 'NoCsrfBridge (Port=0) rejects loopback page owned by foreign process'
$script:LsPortOwner=456
$script:Pages=@($page234,[pscustomobject]@{type='page';url='https://example.test/';webSocketDebuggerUrl='ws://127.0.0.1:9222/devtools/page/evil'})
$failed=$false;try{Get-RuntimePages $noCsrfRuntime|Out-Null}catch{$failed=$true}
Assert $failed 'NoCsrfBridge (Port=0) still rejects external network pages'

# Restore real Test-Path and Get-Content for isolated temp brain transcript tests
Remove-Item Function:\Test-Path, Function:\Get-Content
$brainFixture = Join-Path $repoRoot ('work\brain-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $brainFixture -Force | Out-Null
try {
    $script:BrainRootOverride = $brainFixture
    function Write-FixtureTranscript([string]$ConvId, [string]$Line, [int]$AgeSeconds) {
        $dir = Join-Path $brainFixture "$ConvId\.system_generated\logs"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'transcript.jsonl'
        [IO.File]::WriteAllText($file, $Line + "`n", [Text.UTF8Encoding]::new($false))
        (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddSeconds(-$AgeSeconds)
        return $file
    }
    $null = Write-FixtureTranscript 'conv-done' '{"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[]}' 2
    Assert (Test-RuntimeIdle $noCsrfRuntime) 'NoCsrfBridge is idle when all recent transcripts ended DONE without tool_calls'

    $null = Write-FixtureTranscript 'conv-active' '{"type":"USER_INPUT","status":"DONE"}' 20
    Assert (-not (Test-RuntimeIdle $noCsrfRuntime)) 'NoCsrfBridge inspects ALL recent transcripts and stays busy when another chat is active (20s < 45s)'

    (Get-Item -LiteralPath (Join-Path $brainFixture 'conv-active\.system_generated\logs\transcript.jsonl')).LastWriteTime = (Get-Date).AddSeconds(-60)
    Assert (Test-RuntimeIdle $noCsrfRuntime) 'NoCsrfBridge becomes idle once non-tool step exceeds 45s threshold'

    $null = Write-FixtureTranscript 'conv-tool' '{"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"run_command"}]}' 60
    Assert (-not (Test-RuntimeIdle $noCsrfRuntime)) 'NoCsrfBridge protects active tool_calls step beyond 45s (up to 120s)'

    (Get-Item -LiteralPath (Join-Path $brainFixture 'conv-tool\.system_generated\logs\transcript.jsonl')).LastWriteTime = (Get-Date).AddSeconds(-130)
    Assert (Test-RuntimeIdle $noCsrfRuntime) 'NoCsrfBridge clears stale tool transcript past 120s'
} finally {
    $script:BrainRootOverride = $null
    $resolved = [IO.Path]::GetFullPath($brainFixture)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work')) + '\'
    if ($resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^brain-[a-f0-9]{32}\z') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# NoCsrfBridge Wait-AntigravityIdentity PID verification tests
$script:WaitIdentityPollMs = 10
$script:WaitRuntime = @()
$script:LiveProc = $null
function Get-AntigravityRuntime { $script:WaitRuntime }
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) $script:LiveProc }
$created = Get-Date
$script:WaitRuntime = @([pscustomobject]@{ProcessId=100;Email='new@example.test';CreationDate=$created;NoCsrfBridge=$true})
$script:LiveProc = [pscustomobject]@{ProcessId=100;CreationDate=$created}
Assert (-not (Wait-AntigravityIdentity 'new@example.test' -TimeoutSeconds 0 -PreviousProcessIds @(100))) 'NoCsrfBridge Wait-AntigravityIdentity rejects unchanged PID'
Assert (-not (Wait-AntigravityIdentity 'new@example.test' -TimeoutSeconds 0)) 'NoCsrfBridge Wait-AntigravityIdentity rejects missing PreviousProcessIds'
$script:WaitRuntime = @([pscustomobject]@{ProcessId=200;Email='new@example.test';CreationDate=$created;NoCsrfBridge=$true})
$script:LiveProc = $null
Assert (-not (Wait-AntigravityIdentity 'new@example.test' -TimeoutSeconds 0 -PreviousProcessIds @(100))) 'NoCsrfBridge Wait-AntigravityIdentity rejects dead new PID'
$script:LiveProc = [pscustomobject]@{ProcessId=200;CreationDate=$created}
Assert (Wait-AntigravityIdentity 'new@example.test' -TimeoutSeconds 0 -PreviousProcessIds @(100)) 'NoCsrfBridge Wait-AntigravityIdentity confirms live replacement PID'
$script:WaitIdentityPollMs = $null
