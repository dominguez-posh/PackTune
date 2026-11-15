# Sign-in with an account stored in Keevault (the user's password manager), through Keevault's MCP interface.
# Keevault comes to the front, the user picks the Microsoft account and Keevault hands over user name, password and
# the current one-time code (tool request_microsoft_login). An embedded browser (WebView2) runs the normal Microsoft
# sign-in and fills these in step by step; the user can type or choose another method at any time.
# The authorization code is redeemed here (public client with PKCE, the tool's own app registration).
# Same technique as in MSIX Sandbox Studio; the token goes to the IntuneWin32App module with Set-PackTuneToken.

# The Microsoft sign-in itself (embedded window, token, WebView2 SDK, profiles) is Modules\PackTune.SignIn.psm1. Imported
# without -Force: when the caller has loaded it already, the same instance (log sink, session state) is shared.
Import-Module (Join-Path $PSScriptRoot 'PackTune.SignIn.psm1')

# ---------------------------------------------------------------- Keevault MCP client (JSON-RPC over stdio)
# Keevault.exe is started as Node (ELECTRON_RUN_AS_NODE) with the MCP host script: whatever runs there runs with the rights
# of this process, which may be elevated (AVDTune runs this module as administrator). So the exe and the script are taken
# only from fixed places of this user (or Program Files), never from the path of a running process, and they must not be
# writable by anyone but this user, administrators and the system. Keevault is not Authenticode-signed (checked on
# 0.10.0.0): a signature, once present, must be valid and from a pinned publisher; a pinned SHA256 list can be set too
# (Set-KeevaultTrust). The running Keevault counts only in this session and for this user.
$script:KeevaultPublishers = @()       # pinned signer subjects (Keevault ships unsigned today)
$script:KeevaultSha256 = @()           # optional pinned SHA256 hashes of Keevault.exe (empty = not pinned)
$script:KeevaultProcessSource = $null  # tests: scriptblock returning @{ Id; SessionId; Path; OwnerSid }

function Set-KeevaultTrust {
    <# Pins the Keevault signer subjects and/or SHA256 hashes of Keevault.exe (for example an elevated caller like AVDTune). #>
    param([string[]]$Publisher, [string[]]$Sha256)
    if ($PSBoundParameters.ContainsKey('Publisher')) { $script:KeevaultPublishers = @($Publisher | Where-Object { $_ }) }
    if ($PSBoundParameters.ContainsKey('Sha256')) { $script:KeevaultSha256 = @($Sha256 | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() }) }
}

function Get-KeevaultTrustedRoots {
    @((Join-Path $env:LOCALAPPDATA 'Programs\Keevault'), (Join-Path $env:ProgramFiles 'Keevault')) | Where-Object { $_ }
}

function Test-KeevaultPathUnder([string]$Path, [string[]]$Roots) {
    if (-not $Path) { return $false }
    $full = try { [IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($r in $Roots) { $root = [IO.Path]::GetFullPath($r).TrimEnd('\') + '\'; if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}


function Get-KeevaultProcesses {
    # The running Keevault processes with session and owner (the owner query works for own processes without elevation)
    if ($script:KeevaultProcessSource) { return @(& $script:KeevaultProcessSource) }
    foreach ($p in @(Get-Process Keevault -ErrorAction SilentlyContinue)) {
        $sid = try { [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction Stop | Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch { '' }
        [pscustomobject]@{ Id = $p.Id; SessionId = $p.SessionId; Path = $(try { $p.Path } catch { '' }); OwnerSid = $sid }
    }
}

function Find-KeevaultMcp {
    <#
    Where Keevault and its MCP host script are, and whether it is installed, MCP is switched on and the app runs. The exe is
    the installed one of this user (or Program Files); a running Keevault counts only in this session, for this user and
    with that same exe. The trust of the files is checked by Assert-KeevaultTrust before anything is started.
    #>
    $exe = @(Get-KeevaultTrustedRoots | ForEach-Object { Join-Path $_ 'Keevault.exe' } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'Programs\Keevault\Keevault.exe' }
    $script = Join-Path $env:APPDATA 'KeyVault PwSafe\mcp\keevault-mcp.cjs'
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = (Get-Process -Id $PID).SessionId
    $running = @(Get-KeevaultProcesses | Where-Object { $_.SessionId -eq $session -and $_.OwnerSid -eq $me -and $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($exe)) }) | Select-Object -First 1
    [pscustomobject]@{
        Exe        = $exe
        Script     = $script
        Installed  = (Test-Path -LiteralPath $exe)
        McpEnabled = (Test-Path -LiteralPath $script)
        Running    = [bool]$running
    }
}

function Assert-KeevaultTrust {
    <# Refuses to start Keevault as Node unless the exe and the MCP script are where and what they should be (see above). #>
    param([Parameter(Mandatory)]$Kv)
    $roots = @(Get-KeevaultTrustedRoots)
    if (-not (Test-KeevaultPathUnder $Kv.Exe $roots)) { throw "Keevault is not started from $($Kv.Exe): only an installation under $($roots -join ' or ') is used." }
    $root = @($roots | Where-Object { Test-KeevaultPathUnder $Kv.Exe @($_) })[0]
    $risk = @(Get-PackTuneWriteRisk -Path $Kv.Exe -Root $root)
    if ($risk.Count) { throw "Keevault is not started: its program files can be changed by others ($($risk[0])). Reinstall Keevault or fix the permissions." }
    $scriptRoot = Join-Path $env:APPDATA 'KeyVault PwSafe'
    $risk = @(Get-PackTuneWriteRisk -Path $Kv.Script -Root $scriptRoot)
    if ($risk.Count) { throw "Keevault's MCP script is not used: it can be changed by others ($($risk[0]))." }
    $sig = Get-AuthenticodeSignature -FilePath $Kv.Exe
    if ($sig.Status -ne 'NotSigned') {
        if ($sig.Status -ne 'Valid') { throw "Keevault is not started: its signature is $($sig.Status)." }
        if ($script:KeevaultPublishers.Count -and [string]$sig.SignerCertificate.Subject -notin $script:KeevaultPublishers) { throw "Keevault is not started: it is signed by '$($sig.SignerCertificate.Subject)', not by the pinned publisher." }
    }
    elseif ($script:KeevaultPublishers.Count) { throw 'Keevault is not started: it is not signed, but a publisher is pinned.' }
    if ($script:KeevaultSha256.Count) {
        $hash = (Get-FileHash -LiteralPath $Kv.Exe -Algorithm SHA256).Hash
        if ($hash -notin $script:KeevaultSha256) { throw "Keevault is not started: Keevault.exe ($hash) is not one of the pinned versions." }
    }
}

function Connect-KeevaultMcp {
    <# Starts Keevault's MCP host (Keevault.exe as Node) and runs the MCP handshake. $OnWait runs while waiting. #>
    param([scriptblock]$OnWait)
    $kv = Find-KeevaultMcp
    if (-not $kv.Installed) { throw 'Keevault is not installed on this computer.' }
    if (-not $kv.McpEnabled) { throw 'AI agents (MCP) are switched off in Keevault: Keevault > Settings > AI agents (MCP) > switch on and save.' }
    if (-not $kv.Running) { throw 'Keevault is not running. Start and unlock Keevault, then sign in again.' }
    Assert-KeevaultTrust $kv

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $kv.Exe
    $psi.Arguments = '"{0}"' -f $kv.Script
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $process = [System.Diagnostics.Process]::Start($psi)
    [void]$process.StandardError.ReadToEndAsync()   # drained so the host never blocks on a full pipe

    $client = [pscustomobject]@{ Process = $process; NextId = 0; Pending = $null }
    try {
        [void](Invoke-KeevaultMcpRequest -Client $client -Method 'initialize' -TimeoutSeconds 20 -OnWait $OnWait -Params @{
            protocolVersion = '2025-06-18'
            capabilities    = @{}
            clientInfo      = @{ name = 'PackTune'; version = '2.1.0' }
        })
        Send-KeevaultMcpMessage -Client $client -Message @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    }
    catch { Close-KeevaultMcp $client; throw }
    $client
}

function Send-KeevaultMcpMessage {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][hashtable]$Message)
    # UTF-8 without BOM, one JSON object per line (.NET Framework has no StandardInputEncoding)
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($Message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    $stream = $Client.Process.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Invoke-KeevaultMcpRequest {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnWait
    )
    $Client.NextId++
    $id = $Client.NextId
    Send-KeevaultMcpMessage -Client $Client -Message @{ jsonrpc = '2.0'; id = $id; method = $Method; params = $Params }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (-not $Client.Pending) { $Client.Pending = $Client.Process.StandardOutput.ReadLineAsync() }
        while (-not $Client.Pending.Wait(50)) {
            if ($OnWait) { & $OnWait }
            if ($Client.Process.HasExited) { throw 'The connection to Keevault ended unexpectedly.' }
            if ((Get-Date) -gt $deadline) { throw "Keevault did not answer within $TimeoutSeconds seconds." }
        }
        $line = $Client.Pending.Result
        $Client.Pending = $null
        if ($null -eq $line) { throw 'The connection to Keevault ended unexpectedly.' }
        if (-not $line.Trim()) { continue }
        $msg = $line | ConvertFrom-Json
        if ($msg.id -ne $id) { continue }   # notifications or other replies
        if ($msg.error) { throw "Keevault: $($msg.error.message)" }
        return $msg.result
    }
}

function Invoke-KeevaultMcpTool {
    <# Calls a Keevault tool and returns its result object; a tool error (e.g. declined) becomes an exception. #>
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{},
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnWait
    )
    $r = Invoke-KeevaultMcpRequest -Client $Client -Method 'tools/call' -Params @{ name = $Name; arguments = $Arguments } -TimeoutSeconds $TimeoutSeconds -OnWait $OnWait
    $text = @($r.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
    if ($r.isError) { throw "Keevault: $text" }
    if ($r.structuredContent) { return $r.structuredContent }
    $text | ConvertFrom-Json
}

function Close-KeevaultMcp {
    param($Client)
    if (-not $Client -or -not $Client.Process) { return }
    try { $Client.Process.StandardInput.Close() } catch { }
    if (-not $Client.Process.WaitForExit(2000)) { try { $Client.Process.Kill() } catch { } }
    $Client.Process.Dispose()
}

# ---------------------------------------------------------------- Keevault sign-in
function Connect-PackTuneWithKeevault {
    <#
    Signs in to Microsoft Graph with an account from Keevault and returns the token response. Keevault asks the
    user to approve and pick the account (only accounts released for AI agents); the embedded sign-in fills in
    user name, password and one-time code. A fresh one-time code is requested from Keevault when the first one
    has expired. The caller hands the token to the IntuneWin32App module (Set-PackTuneToken).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantID,
        [Parameter(Mandatory)][string]$ClientID,
        [string]$UserDataFolder,
        [ValidateSet('default', 'consent')][string]$Prompt = 'default',
        [Parameter(Mandatory)][string]$CacheFolder,
        [string[]]$Scopes,
        [System.Windows.Window]$Owner,
        [scriptblock]$OnWait,
        # Gets the chosen user name and returns @{ TenantID; ClientID } to sign in with (an account of another
        # tenant needs that tenant's app registration), or throws to stop
        [scriptblock]$OnAccount
    )
    $client = Connect-KeevaultMcp -OnWait $OnWait
    try {
        $request = @{ purpose = "PackTune: sign in to Microsoft Intune (Graph), tenant $TenantID" }
        # Keevault lists the accounts of this tenant first (older versions show only those)
        if ($TenantID -match '\.' -and $TenantID -notmatch '^[0-9a-f-]{36}$') { $request.tenant = $TenantID }
        Write-SignInLog 'Keevault: choose the Microsoft account in Keevault ...'
        $login = Invoke-KeevaultMcpTool -Client $client -Name 'request_microsoft_login' -Arguments $request -OnWait $OnWait
        Write-SignInLog "Keevault: signing in as $($login.username) ($($login.title))."
        if ($OnAccount) {
            $target = & $OnAccount ([string]$login.username)
            if ($target.TenantID) { $TenantID = $target.TenantID }
            if ($target.ClientID) { $ClientID = $target.ClientID }
        }
        $creds = @{
            Username = [string]$login.username
            Password = [string]$login.password
            Otp      = [string]$login.totp
            OtpUntil = if ($login.totp) { (Get-Date).AddSeconds([int]$login.totpValidForSeconds - 3) } else { [datetime]::MinValue }
            Used     = $false
        }
        $fill = {
            param($step)
            switch ($step) {
                'username' { $creds.Username }
                'password' { $creds.Password }
                'otp' {
                    if (-not $creds.Otp) { return $null }
                    if ($creds.Used -or (Get-Date) -gt $creds.OtpUntil) {
                        try { $creds.Otp = [string](Invoke-KeevaultMcpTool -Client $client -Name 'get_totp' -Arguments @{ vaultId = $login.vaultId; entryId = $login.entryId } -TimeoutSeconds 120 -OnWait $OnWait).code }
                        catch { Write-SignInLog "Keevault: no new one-time code ($($_.Exception.Message))." 'Warning'; return $null }
                    }
                    $creds.Used = $true
                    $creds.Otp
                }
            }
        }
        # Entry with a passkey (or without password): Keevault signs the passkey request, the user confirms in Keevault
        $passkey = $null
        if ($login.passkey -or -not $login.password) {
            $passkey = {
                param($origin, $challenge, $rpId, $allow)
                Write-SignInLog 'Keevault: confirm the passkey sign-in in Keevault ...'
                $a = @{ vaultId = $login.vaultId; entryId = $login.entryId; origin = $origin; challenge = $challenge }
                if ($rpId) { $a.rpId = $rpId.ToLower() }
                $r = Invoke-KeevaultMcpTool -Client $client -Name 'sign_in_with_passkey' -Arguments $a -TimeoutSeconds 180 -OnWait $OnWait
                Write-SignInLog 'Keevault: passkey signed.'
                $r.credential
            }
        }
        $hint = if ($passkey) { "Keevault signs in $($login.username) with the passkey; confirm it in Keevault. You can type yourself or choose another sign-in method at any time." }
        else { "Keevault fills in the account $($login.username). You can type yourself or choose another sign-in method (e.g. a passkey) at any time." }
        $token = Invoke-PackTuneBrowserSignIn -TenantID $TenantID -ClientID $ClientID -CacheFolder $CacheFolder -UserDataFolder $UserDataFolder -Prompt $Prompt -Scopes $Scopes -LoginHint $login.username `
            -Fill $fill -HasOtp:([bool]$login.totp) -Passkey $passkey -Hint $hint -Owner $Owner -Title 'Sign in to Microsoft Intune with Keevault'
    }
    finally {
        if ($creds) { $creds.Password = $null; $creds.Otp = $null }
        Close-KeevaultMcp $client
    }
    # Where the sign-in went (another tenant when the account belongs to one)
    $token | Add-Member -NotePropertyName SignInTenantID -NotePropertyValue $TenantID -Force
    $token | Add-Member -NotePropertyName SignInClientID -NotePropertyValue $ClientID -Force
    $token
}


# Keevault's own functions; the sign-in functions are passed on as well, so callers that import only this module keep working
Export-ModuleMember -Function Set-KeevaultTrust, Find-KeevaultMcp, Connect-KeevaultMcp, Invoke-KeevaultMcpRequest, Invoke-KeevaultMcpTool, Close-KeevaultMcp, Connect-PackTuneWithKeevault,
    Set-PackTuneSignInLog, Get-PackTuneWebView2, Get-PackTuneEnvironment, Set-PackTuneSignInMethod, Get-PackTuneCookieSummary, Get-PackTuneSessionFolder, Start-PackTuneSessionHold, Close-PackTuneSessionHold, Clear-PackTuneSession, Get-PackTuneAuthorizeUrl, Request-PackTuneToken, Invoke-PackTuneBrowserSignIn
