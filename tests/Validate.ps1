$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$systemRoot=$env:WINDIR
if (-not $systemRoot) { $systemRoot=$env:SystemRoot }
if (-not $systemRoot) { $systemRoot='C:\Windows' }
$powershellExe=Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$ps1Files=@(Get-ChildItem -LiteralPath $repo -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
$scriptsDir=Join-Path $repo 'scripts'
if (Test-Path -LiteralPath $scriptsDir -PathType Container) {
    $ps1Files+=@(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -File)
}
foreach ($file in $ps1Files) {
    if (@([IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count) { throw "Non-ASCII script: $($file.FullName)" }
    $tokens=$null; $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "PowerShell parse error: $($file.FullName): $($parseErrors.Message -join ', ')" }
}

$excludedDirs=@('.git','work','dist','.backup','accounts','backups')
$checkedExts=@('.ps1','.xaml','.js','.vbs','.bat','.json','.yml')
$unsafeUnicodePattern='[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\u061C\uFEFF]'
$dirStack=New-Object System.Collections.Generic.Stack[string]
$dirStack.Push($repo)
while ($dirStack.Count -gt 0) {
    $currentDir=$dirStack.Pop()
    foreach ($subDir in @(Get-ChildItem -LiteralPath $currentDir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($excludedDirs -contains $subDir.Name.ToLowerInvariant()) { continue }
        $dirStack.Push($subDir.FullName)
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $currentDir -File -Force -ErrorAction SilentlyContinue)) {
        if ($checkedExts -notcontains $file.Extension.ToLowerInvariant()) { continue }
        $rawText=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
        if ([regex]::IsMatch($rawText,$unsafeUnicodePattern)) {
            throw "Unsafe BiDi or zero-width Unicode character detected in: $($file.FullName)"
        }
    }
}

Add-Type -AssemblyName PresentationFramework
$reader=[Xml.XmlReader]::Create((Join-Path $repo 'MainWindow.xaml'))
try { $window=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
foreach ($name in @('BtnRefresh','BtnAddAccount','AccountsContainer','TxtDaemonStatus','ChkPauseWhenIdeClosed')) {
    if (-not $window.FindName($name)) { throw "Missing UI control: $name" }
}
Write-Host 'PASS: ASCII, BiDi/Unicode safety, PowerShell syntax and WPF XAML load'
& node (Join-Path $PSScriptRoot 'RuntimeWindow.Tests.js')
if ($LASTEXITCODE) { throw 'Runtime window safety tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'RuntimeSelection.Tests.ps1')
if ($LASTEXITCODE) { throw 'Runtime selection tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Rotation.Tests.ps1')
if ($LASTEXITCODE) { throw 'Rotation tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Core.Tests.ps1')
if ($LASTEXITCODE) { throw 'Core tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Quota.Tests.ps1')
if ($LASTEXITCODE) { throw 'Quota tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Argon.Tests.ps1')
if ($LASTEXITCODE) { throw 'Argon account quota tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Plan.Tests.ps1')
if ($LASTEXITCODE) { throw 'Account plan tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Models.Tests.ps1')
if ($LASTEXITCODE) { throw 'Model quota tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'OAuth.Tests.ps1')
if ($LASTEXITCODE) { throw 'OAuth configuration tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'SetupOAuth.Tests.ps1')
if ($LASTEXITCODE) { throw 'Automatic OAuth setup tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'SetupHttp.Tests.ps1')
if ($LASTEXITCODE) { throw 'Setup HTTP error tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Setup.Tests.ps1')
if ($LASTEXITCODE) { throw 'Installer integration tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Updater.Tests.ps1')
if ($LASTEXITCODE) { throw 'Safe updater tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Compatibility.Tests.ps1')
if ($LASTEXITCODE) { throw 'Compatibility tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Daemon.Tests.ps1')
if ($LASTEXITCODE) { throw 'Daemon status tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Login.Tests.ps1')
if ($LASTEXITCODE) { throw 'Account login tests failed' }
& $powershellExe -NoProfile -File (Join-Path $PSScriptRoot 'Mcp.Tests.ps1')
if ($LASTEXITCODE) { throw 'MCP tests failed' }
& $powershellExe -NoProfile -STA -File (Join-Path $PSScriptRoot 'Dashboard.Tests.ps1')
if ($LASTEXITCODE) { throw 'Dashboard tests failed' }
& $powershellExe -NoProfile -STA -File (Join-Path $PSScriptRoot 'WindowLayout.Tests.ps1')
if ($LASTEXITCODE) { throw 'Window layout tests failed' }
