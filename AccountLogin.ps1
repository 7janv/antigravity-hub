# Isolated official login helper. Never expose its output, CSRF or OAuth response.
if (-not ('AntigravityAccountLogin' -as [type])) {
Add-Type -IgnoreWarnings -WarningAction SilentlyContinue @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

public sealed class AntigravityAccountLogin : IDisposable {
    private const int AF_INET = 2;
    private const int AF_INET6 = 23;
    private const int TCP_TABLE_OWNER_PID_LISTENER = 3;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int pdwSize, bool bOrder, int ulAf, int TableClass, uint Reserved);

    private readonly object gate = new object();
    private readonly string csrf = Guid.NewGuid().ToString();
    private HttpWebRequest request;
    private Task loginTask;
    private bool disposed;
    private string authUrl;
    private int port;
    private bool portLocked;
    private string verifiedAddress;
    private string failure;
    private bool succeeded;
    private bool started;
    private string responseJson;
    public Process Process { get; private set; }
    public string AuthUrl { get { lock (gate) return authUrl; } }
    public int Port { get { lock (gate) return port; } }
    public bool PortLocked { get { lock (gate) return portLocked; } }
    public string VerifiedAddress { get { lock (gate) return verifiedAddress; } }
    public string Failure { get { lock (gate) return failure; } }
    public bool Succeeded { get { lock (gate) return succeeded; } }
    public bool RequestStarted { get { lock (gate) return request != null; } }
    public string ResponseJson { get { lock (gate) return responseJson; } }

    private static int DecodeNetworkPort(uint rawPort) {
        return ((int)(rawPort & 0xFF) << 8) | (int)((rawPort >> 8) & 0xFF);
    }

    public static string FormatLoopbackHost(string address) {
        if (address == "127.0.0.1") return "127.0.0.1";
        if (address == "::1") return "[::1]";
        throw new ArgumentException("InvalidLoopbackAddress");
    }

    public static bool IsLoopbackPortOwnedByProcess(int pid, int listenPort, string address) {
        if (pid <= 0 || listenPort <= 0 || listenPort > 65535) return false;
        bool isV4 = address == "127.0.0.1";
        bool isV6 = address == "::1";
        if (!isV4 && !isV6) return false;
        int af = isV4 ? AF_INET : AF_INET6;
        int rowSize = isV4 ? 24 : 56;
        int size = 0;
        for (int attempt = 0; attempt < 3; attempt++) {
            uint res = GetExtendedTcpTable(IntPtr.Zero, ref size, false, af, TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (res != ERROR_INSUFFICIENT_BUFFER && res != 0) return false;
            if (size < 4) return false;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                res = GetExtendedTcpTable(buffer, ref size, false, af, TCP_TABLE_OWNER_PID_LISTENER, 0);
                if (res == ERROR_INSUFFICIENT_BUFFER) continue;
                if (res != 0) return false;
                int count = Marshal.ReadInt32(buffer);
                if (count <= 0 || (long)count * rowSize + 4 > size) return false;
                IntPtr rowPtr = IntPtr.Add(buffer, 4);
                if (isV4) {
                    uint loopbackV4 = BitConverter.ToUInt32(IPAddress.Loopback.GetAddressBytes(), 0);
                    for (int i = 0; i < count; i++) {
                        uint localAddr = (uint)Marshal.ReadInt32(rowPtr, 4);
                        uint localPort = (uint)Marshal.ReadInt32(rowPtr, 8);
                        int owningPid = Marshal.ReadInt32(rowPtr, 20);
                        if (owningPid == pid && localAddr == loopbackV4 && DecodeNetworkPort(localPort) == listenPort) return true;
                        rowPtr = IntPtr.Add(rowPtr, 24);
                    }
                } else {
                    byte[] loopbackV6 = IPAddress.IPv6Loopback.GetAddressBytes();
                    byte[] rowAddr = new byte[16];
                    for (int i = 0; i < count; i++) {
                        Marshal.Copy(rowPtr, rowAddr, 0, 16);
                        uint localPort = (uint)Marshal.ReadInt32(rowPtr, 20);
                        int owningPid = Marshal.ReadInt32(rowPtr, 52);
                        if (owningPid == pid && DecodeNetworkPort(localPort) == listenPort) {
                            bool match = true;
                            for (int b = 0; b < 16; b++) { if (rowAddr[b] != loopbackV6[b]) { match = false; break; } }
                            if (match) return true;
                        }
                        rowPtr = IntPtr.Add(rowPtr, 56);
                    }
                }
                return false;
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
        }
        return false;
    }

    public static string ResolveLoopbackAddress(int pid, int listenPort) {
        if (IsLoopbackPortOwnedByProcess(pid, listenPort, "127.0.0.1")) return "127.0.0.1";
        if (IsLoopbackPortOwnedByProcess(pid, listenPort, "::1")) return "::1";
        return null;
    }

    public static string ExtractAuthUrl(string line) {
        if (String.IsNullOrEmpty(line)) return null;
        foreach (Match m in Regex.Matches(line, @"https://[^\s<>""']+")) {
            Uri uri;
            if (Uri.TryCreate(m.Value, UriKind.Absolute, out uri) && uri.Scheme == "https" &&
                uri.Host == "accounts.google.com" && uri.IsDefaultPort && uri.UserInfo == "" &&
                (uri.AbsolutePath == "/o/oauth2/auth" || uri.AbsolutePath == "/o/oauth2/v2/auth") &&
                !String.IsNullOrEmpty(uri.Query)) return uri.AbsoluteUri;
        }
        return null;
    }

    public static ProcessStartInfo CreateStartInfo(string executable, string directory, string csrf) {
        if (String.IsNullOrWhiteSpace(executable)) throw new ArgumentException("InvalidExecutable");
        for (int i = 0; i < executable.Length; i++) {
            if (Char.IsControl(executable[i])) throw new ArgumentException("InvalidExecutable");
        }
        if (String.IsNullOrWhiteSpace(directory)) throw new ArgumentException("InvalidGeminiDirectory");
        for (int i = 0; i < directory.Length; i++) {
            if (directory[i] == '"' || Char.IsControl(directory[i])) throw new ArgumentException("InvalidGeminiDirectory");
        }
        string cleanDir = directory.TrimEnd('\\');
        if (String.IsNullOrWhiteSpace(cleanDir) || cleanDir.EndsWith(":")) throw new ArgumentException("InvalidGeminiDirectory");
        if (String.IsNullOrWhiteSpace(csrf)) throw new ArgumentException("InvalidCsrfToken");
        for (int i = 0; i < csrf.Length; i++) {
            if (csrf[i] == '"' || Char.IsWhiteSpace(csrf[i]) || Char.IsControl(csrf[i])) throw new ArgumentException("InvalidCsrfToken");
        }
        var psi = new ProcessStartInfo(executable);
        psi.Arguments = "--standalone --subclient_type=hub --override_ide_name=antigravity" +
            " --api_server_url=https://generativelanguage.googleapis.com" +
            " --cloud_code_endpoint=https://daily-cloudcode-pa.googleapis.com" +
            " --gemini_dir=\"" + cleanDir + "\" --app_data_dir=app --csrf_token=" + csrf;
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardError = true; psi.RedirectStandardOutput = true; psi.RedirectStandardInput = true;
        // Ask the official helper to print the URL; the Hub opens it once.
        psi.EnvironmentVariables["ANTIGRAVITY_VSCODE_HOST"] = "1";
        return psi;
    }

    public static bool IsVerificationUrl(string value) {
        Uri uri;
        return Uri.TryCreate(value, UriKind.Absolute, out uri) && uri.Scheme == "https" &&
            uri.Host == "accounts.google.com" && uri.IsDefaultPort && uri.UserInfo == "" &&
            uri.AbsolutePath == "/signin/continue";
    }

    private void HandleOutputLine(string line) {
        if (line == null) return;
        lock (gate) {
            if (disposed) return;
            var found = ExtractAuthUrl(line);
            if (request != null && found != null && authUrl == null) authUrl = found;
            if (!portLocked && port == 0) {
                var m = Regex.Match(line, @"listening on \w+ port at (\d+) for HTTPS\b");
                int value;
                if (m.Success && Int32.TryParse(m.Groups[1].Value, out value) && value > 0 && value <= 65535) {
                    port = value;
                    portLocked = true;
                }
            }
        }
    }

    private void OnOutput(object sender, DataReceivedEventArgs e) {
        HandleOutputLine(e.Data);
    }

    public AntigravityAccountLogin(string executable, string directory) {
        Process = new Process(); Process.StartInfo = CreateStartInfo(executable, directory, csrf);
        Process.OutputDataReceived += OnOutput; Process.ErrorDataReceived += OnOutput;
        try {
            if (!Process.Start()) throw new InvalidOperationException("LoginHelperStartFailed");
            started = true;
            Process.BeginOutputReadLine(); Process.BeginErrorReadLine(); Process.StandardInput.Close();
        } catch { Dispose(); throw new InvalidOperationException("LoginHelperStartFailed"); }
    }

    // Verifies process liveness and exact loopback listener ownership before invoking.
    public void BeginLogin() {
        BeginLogin(null);
    }

    public void BeginLogin(string loopbackAddress) {
        lock (gate) {
            if (disposed || request != null || port == 0) return;
            if (Process == null || Process.HasExited) throw new InvalidOperationException("LoginHelperExited");
            string targetAddress;
            if (String.IsNullOrEmpty(loopbackAddress)) {
                targetAddress = ResolveLoopbackAddress(Process.Id, port);
            } else if ((loopbackAddress == "127.0.0.1" || loopbackAddress == "::1") &&
                IsLoopbackPortOwnedByProcess(Process.Id, port, loopbackAddress)) {
                targetAddress = loopbackAddress;
            } else {
                targetAddress = null;
            }
            if (targetAddress == null) throw new InvalidOperationException("LoginListenerMismatch");
            portLocked = true;
            verifiedAddress = targetAddress;
            request = (HttpWebRequest)WebRequest.Create("https://" + FormatLoopbackHost(targetAddress) + ":" + port +
                "/exa.language_server_pb.LanguageServerService/Login");
            request.Proxy = null; request.AllowAutoRedirect = false;
            request.Method = "POST"; request.ContentType = "application/json";
            request.Headers["x-codeium-csrf-token"] = csrf;
            request.Timeout = 300000; request.ReadWriteTimeout = 300000;
            request.ServerCertificateValidationCallback = (a,b,c,d) => true;
            var pending = request;
            loginTask = Task.Run(() => {
                try {
                    var body = Encoding.UTF8.GetBytes("{}"); pending.ContentLength = body.Length;
                    using (var stream = pending.GetRequestStream()) stream.Write(body, 0, body.Length);
                    using (var response = pending.GetResponse()) {
                        using (var reader = new StreamReader(response.GetResponseStream())) {
                            var buffer = new char[4096]; var result = new StringBuilder(); int read;
                            while ((read = reader.Read(buffer, 0, buffer.Length)) > 0) {
                                if (result.Length + read > 1048576) throw new IOException("LoginResponseTooLarge");
                                result.Append(buffer, 0, read);
                            }
                            lock (gate) { if (!disposed) { responseJson = result.ToString(); succeeded = true; } }
                        }
                    }
                } catch {
                    lock (gate) { if (!disposed) failure = "LoginRequestFailed"; }
                }
            });
        }
    }

    public string ReadUserStatus() {
        return ReadAuthRpc("GetUserStatus");
    }

    public string ReadAuthStatus() {
        return ReadAuthRpc("GetAuthStatus");
    }

    private string ReadAuthRpc(string method) {
        int targetPort;
        string targetAddress;
        lock (gate) {
            if (disposed || !succeeded) throw new InvalidOperationException("LoginNotComplete");
            targetPort = port;
            targetAddress = verifiedAddress;
        }
        if (Process == null || Process.HasExited) throw new InvalidOperationException("LoginHelperExited");
        if (targetPort <= 0 || String.IsNullOrEmpty(targetAddress) ||
            !IsLoopbackPortOwnedByProcess(Process.Id, targetPort, targetAddress)) {
            throw new InvalidOperationException("LoginListenerMismatch");
        }
        var read = (HttpWebRequest)WebRequest.Create("https://" + FormatLoopbackHost(targetAddress) + ":" + targetPort +
            "/exa.language_server_pb.LanguageServerService/" + method);
        read.Proxy = null; read.AllowAutoRedirect = false; read.Method = "POST";
        read.ContentType = "application/json"; read.Headers["x-codeium-csrf-token"] = csrf;
        read.Timeout = 5000; read.ReadWriteTimeout = 5000;
        read.ServerCertificateValidationCallback = (a,b,c,d) => true;
        var bytes = Encoding.UTF8.GetBytes("{}"); read.ContentLength = bytes.Length;
        using(var stream = read.GetRequestStream()) stream.Write(bytes,0,bytes.Length);
        using(var response = read.GetResponse())
        using(var reader = new StreamReader(response.GetResponseStream())) {
            var buffer = new char[4096]; var result = new StringBuilder(); int count;
            while ((count = reader.Read(buffer,0,buffer.Length)) > 0) {
                if(result.Length + count > 1048576) throw new IOException("LoginResponseTooLarge");
                result.Append(buffer,0,count);
            }
            return result.ToString();
        }
    }

    public void Dispose() {
        Task pendingTask;
        lock (gate) {
            disposed = true;
            responseJson = null;
            pendingTask = loginTask;
            if (request != null) { try { request.Abort(); } catch { } }
        }
        if (started && Process != null) {
            bool exited = false;
            try { exited = Process.HasExited; } catch (InvalidOperationException) { exited = true; }
            if (!exited) {
                try {
                    Process.Kill();
                } catch (InvalidOperationException) {
                } catch (Win32Exception) {
                    try { if (!Process.HasExited) throw; } catch (InvalidOperationException) { }
                }
                if (!Process.WaitForExit(5000)) throw new InvalidOperationException("LoginHelperStopFailed");
            }
        }
        if (pendingTask != null) { try { pendingTask.Wait(5000); } catch { } }
        if (Process != null) { try { Process.Dispose(); } catch { } }
    }
}
'@
}

function Get-AccountLoginResult {
    param($Session)
    if (-not $Session.Succeeded) { return $null }
    try { $result=$Session.ResponseJson | ConvertFrom-Json -ErrorAction Stop } catch { throw 'LoginInvalidResponse' }
    $auth=$result.authResult
    if ($null -eq $auth) { $auth=$result.auth_result }
    # OAuth success does not imply Antigravity eligibility. Never save a rejected
    # account or let optional diagnostics obscure the provider's outcome.
    foreach ($failure in @(
        @('ineligible','ineligible','LoginIneligible'),
        @('verificationRequired','verification_required','LoginVerificationRequired'),
        @('tosViolation','tos_violation','LoginTermsRejected'),
        @('generalError','general_error','LoginProviderError'),
        @('projectRequired','project_required','LoginProjectRequired'),
        @('headlessAuthRequired','headless_auth_required','LoginInteractiveRequired'),
        @('licenseRequired','license_required','LoginLicenseRequired')
    )) {
        if ($null -ne $auth.($failure[0]) -or $null -ne $auth.($failure[1])) { throw $failure[2] }
    }
    $valid=$auth.hasValidAuth
    if ($null -eq $valid) { $valid=$auth.has_valid_auth }
    if ($valid -isnot [bool] -or -not $valid) { throw 'LoginAuthRejected' }
    return $auth
}

function Get-AccountLoginProgress {
    param($Session, [switch]$Recheck)
    # Only the isolated helper is polled; the main app's auth state is untouched.
    $response=if($Recheck){$Session.ReadAuthStatus()}else{$Session.ResponseJson}
    try { $body=$response | ConvertFrom-Json -ErrorAction Stop } catch { throw 'LoginInvalidResponse' }
    $auth=$body.authResult
    if($null -eq $auth){$auth=$body.auth_result}
    try {
        $null=Get-AccountLoginResult ([pscustomobject]@{Succeeded=$true;ResponseJson=$response})
        return [pscustomobject]@{Status='Ready';VerificationUrl=$null}
    } catch {
        $code=$_.Exception.Message
        if($code -notin @('LoginIneligible','LoginVerificationRequired')){throw}
        $details=if($null -ne $auth.ineligible){$auth.ineligible}elseif($null -ne $auth.verificationRequired){$auth.verificationRequired}else{$auth.verification_required}
        $url=$details.verificationUrl
        if(-not $url){$url=$details.verification_url}
        if(-not [AntigravityAccountLogin]::IsVerificationUrl($url)){throw $code}
        return [pscustomobject]@{Status='VerificationRequired';VerificationUrl=$url}
    }
}

function Get-AccountLoginTokenCandidates {
    param([string]$TempDirectory, [string]$FallbackPath)
    # Read only the helper's documented token filename, never arbitrary profile files.
    foreach ($path in @((Join-Path $TempDirectory 'jetski-standalone-oauth-token'),
                       (Join-Path $TempDirectory 'app\jetski-standalone-oauth-token'),$FallbackPath)) {
        if ($path -and [IO.File]::Exists($path)) {
            try {
                if (([IO.FileInfo]::new($path)).Length -le 1MB) {
                    [IO.File]::ReadAllText($path)
                }
            } catch {}
        }
    }
    $stored=Get-StoredCredential
    if ($stored) { $stored }
}

function Get-VerifiedAccountLoginToken {
    param([string[]]$Candidates, [string]$ExpectedEmail)
    if ($ExpectedEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+\z') { throw 'LoginIdentityMissing' }
    foreach ($raw in @($Candidates | Select-Object -Unique)) {
        try {
            $parsed=$raw | ConvertFrom-Json -ErrorAction Stop
            if (-not (Get-RefreshToken $parsed)) { continue }
            $token=Get-FreshToken $parsed
            $user=Invoke-RestMethod 'https://www.googleapis.com/oauth2/v3/userinfo' -Headers @{Authorization="Bearer $($token.token.access_token)"} -TimeoutSec 10 -ErrorAction Stop
            if ($user.email -ieq $ExpectedEmail) { return [pscustomobject]@{Email=$user.email;Token=$token} }
        } catch {}
    }
    return $null
}

function Get-AccountLoginVerifiedAddress {
    param([int]$Port, [int]$ProcessId)
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
        Where-Object { $_.OwningProcess -eq $ProcessId -and $_.LocalAddress -in @('127.0.0.1','::1') })
    if ($listeners | Where-Object { $_.LocalAddress -eq '127.0.0.1' }) { return '127.0.0.1' }
    if ($listeners | Where-Object { $_.LocalAddress -eq '::1' }) { return '::1' }
    return $null
}

function Update-AccountLoginSession {
    param($Session)
    if ($Session.Process.HasExited) { throw 'LoginHelperExited' }
    if ($Session.Failure) { throw 'LoginRequestFailed' }
    if ($Session.Port -and -not $Session.RequestStarted) {
        $address = Get-AccountLoginVerifiedAddress -Port $Session.Port -ProcessId $Session.Process.Id
        if (-not $address) {
            throw 'LoginListenerMismatch'
        }
        $Session.BeginLogin($address)
    }
}
