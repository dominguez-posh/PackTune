# The Microsoft sign-in of PackTune in an embedded browser (WebView2): authorization code with PKCE (public client,
# loopback redirect), token redemption, the WebView2 SDK (pinned version, checked on every load), the shared and the
# temporary sign-in profiles. Needs no Keevault: Modules\Keevault.psm1 builds on it (it fills this window from Keevault),
# and other tools (AVDTune) use it alone. The token goes to the IntuneWin32App module with Set-PackTuneToken.

$script:SignInRedirect = 'http://localhost'
$script:SignInHosts = @('login.microsoftonline.com', 'login.microsoft.com', 'login.live.com')
$script:DefaultScopes = @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementRBAC.Read.All', 'Group.Read.All')
$script:Log = { param($Text, $Level) Write-Host $Text }

function Set-PackTuneSignInLog {
    <# Where the sign-in writes its progress: a script block taking (text, level). #>
    param([Parameter(Mandatory)][scriptblock]$Sink)
    $script:Log = $Sink
}
function Write-SignInLog([string]$Text, [string]$Level = 'Info') { & $script:Log $Text $Level }

$script:WriteRightsMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000

function Get-PackTuneWriteRisk {
    <#
    The principals other than this user, administrators, SYSTEM and TrustedInstaller that may change the file or one of its
    folders up to (and including) $Root (write, append, delete, change permissions or owner). Empty = trusted.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($me, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $risk = New-Object System.Collections.Generic.List[string]
    $item = [IO.Path]::GetFullPath($Path)
    while ($item) {
        if (-not (Test-Path -LiteralPath $item)) { $risk.Add("$item is missing"); break }
        $acl = Get-Acl -LiteralPath $item
        $owner = try { $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { '' }
        if ($owner -notin $allowed) { $risk.Add("$item is owned by $owner") }
        foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($ace.AccessControlType -ne 'Allow') { continue }
            if ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if (([int64]$ace.FileSystemRights -band $script:WriteRightsMask) -and $ace.IdentityReference.Value -notin $allowed) { $risk.Add("$($ace.IdentityReference.Value) may change $item") }
        }
        if ($item.TrimEnd('\') -ieq $rootFull) { break }
        $parent = Split-Path $item -Parent
        if (-not $parent -or $parent -eq $item) { break }
        $item = $parent
    }
    @($risk)
}

# ---------------------------------------------------------------- embedded browser (WebView2)
function Test-PackTuneMicrosoftSigned([string]$Path) {
    # Valid Authenticode signature whose signer is Microsoft Corporation (exact organization, not a look-alike)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $sig.Status -eq 'Valid' -and [string]$sig.SignerCertificate.Subject -match '(^|,\s*)O=Microsoft Corporation(\s*,|$)'
}

# The WebView2 SDK is pinned: this NuGet version and these SHA256 hashes (package and the three files used), no "latest"
# lookup. Changing the version is a deliberate code change: new version, new hashes (nupkg hash cross-checked against the
# SHA512 packageHash of the NuGet catalog), Tests\Check-SignIn.ps1.
$script:WebView2SdkVersion = '1.0.4314.35'   # Microsoft.Web.WebView2, published 2026-10-23
$script:WebView2NupkgSha256 = '90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4'
$script:WebView2DllSha256 = [ordered]@{
    'Microsoft.Web.WebView2.Core.dll' = 'ACDD517B951829F763D1255F32DF1E6A936CB8623A7EBFF6B8B24172DEDE6BD6'
    'Microsoft.Web.WebView2.Wpf.dll'  = 'BAAFA0A595C2CEFB3BE8F18288C3DB76F52E3966C8B99957D5E56CAF1B137BC1'
    'WebView2Loader.dll'              = 'D3FCE90BDEECB08596E377DEA6A316354DD8949E32FF09B89D51BE00C14E21B6'
}
$script:WebView2Download = $null   # tests: scriptblock (Uri, OutFile) instead of the download

function Test-PackTuneWebView2Sdk {
    <# Why the cached WebView2 SDK must not be loaded, or $null: Microsoft signature, the pinned hashes, permissions. #>
    param([Parameter(Mandatory)][string]$CacheFolder)
    foreach ($name in $script:WebView2DllSha256.Keys) {
        $f = Join-Path $CacheFolder $name
        if (-not (Test-PackTuneMicrosoftSigned $f)) { return "$name is missing or not signed by Microsoft" }
        if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne $script:WebView2DllSha256[$name]) { return "$name is not the pinned file of version $($script:WebView2SdkVersion)" }
    }
    # Every file that is loaded (the native loader too, it is loaded later by the runtime) and the folder
    foreach ($name in $script:WebView2DllSha256.Keys) {
        $risk = @(Get-PackTuneWriteRisk -Path (Join-Path $CacheFolder $name) -Root $CacheFolder)
        if ($risk.Count) { return "the folder can be changed by others: $($risk[0])" }
    }
    $null
}

function Install-PackTuneWebView2Sdk {
    <# Downloads the pinned WebView2 SDK into $CacheFolder: package hash first, then signature and hash of every file. #>
    param([Parameter(Mandatory)][string]$CacheFolder)
    $version = $script:WebView2SdkVersion
    Write-SignInLog "Downloading the WebView2 SDK $version for the embedded sign-in ..."
    $nupkg = Join-Path ([IO.Path]::GetTempPath()) ("webview2-$version-" + [guid]::NewGuid().ToString('N') + '.zip')
    $uri = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
    try {
        if ($script:WebView2Download) { & $script:WebView2Download $uri $nupkg }
        else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $uri -OutFile $nupkg -UseBasicParsing -TimeoutSec 120
        }
        $got = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash
        if ($got -ne $script:WebView2NupkgSha256) { throw "The downloaded WebView2 SDK $version is not the pinned package (SHA256 $got); nothing was installed." }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Remove-PackTuneTree -Path $CacheFolder
        New-Item -ItemType Directory -Path $CacheFolder -Force | Out-Null
        $wanted = @{
            'lib/net462/Microsoft.Web.WebView2.Core.dll' = 'Microsoft.Web.WebView2.Core.dll'
            'lib/net462/Microsoft.Web.WebView2.Wpf.dll'  = 'Microsoft.Web.WebView2.Wpf.dll'
            'runtimes/win-x64/native/WebView2Loader.dll' = 'WebView2Loader.dll'
        }
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        try { foreach ($e in $zip.Entries) { if ($wanted.ContainsKey($e.FullName)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $CacheFolder $wanted[$e.FullName]), $true) } } }
        finally { $zip.Dispose() }
    }
    finally { Remove-Item -LiteralPath $nupkg -Force -ErrorAction SilentlyContinue }
    $problem = Test-PackTuneWebView2Sdk -CacheFolder $CacheFolder
    if ($problem) { try { Remove-PackTuneTree -Path $CacheFolder } catch { }; throw "The WebView2 SDK $version was not installed: $problem." }
    ([ordered]@{ Version = $version } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $CacheFolder 'webview2-sdk.json') -Encoding UTF8
}

function Get-PackTuneWebView2 {
    <#
    Loads the WebView2 SDK (Core + WPF) for the embedded sign-in window: the pinned version, downloaded once from NuGet
    into $CacheFolder and checked on every load (Microsoft signature, pinned hashes, permissions). A cache of another
    version is replaced; a cache of this version that fails its check is removed and the call fails (fail closed; the next
    sign-in downloads it again). Needs the WebView2 runtime (part of Windows 11, otherwise installed with Edge).
    #>
    param([Parameter(Mandatory)][string]$CacheFolder)
    if (-not ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) {
        $marker = try { Get-Content -LiteralPath (Join-Path $CacheFolder 'webview2-sdk.json') -Raw | ConvertFrom-Json } catch { $null }
        if ([string]$marker.Version -ne $script:WebView2SdkVersion) { Install-PackTuneWebView2Sdk -CacheFolder $CacheFolder }
        $problem = Test-PackTuneWebView2Sdk -CacheFolder $CacheFolder
        if ($problem) {
            try { Remove-PackTuneTree -Path $CacheFolder } catch { }
            throw "The WebView2 SDK in $CacheFolder failed its check ($problem) and was removed. Sign in again to download it fresh from NuGet."
        }
        Add-Type -Path (Join-Path $CacheFolder 'Microsoft.Web.WebView2.Core.dll')
        Add-Type -Path (Join-Path $CacheFolder 'Microsoft.Web.WebView2.Wpf.dll')
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($CacheFolder)
    }
    try { [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString() }
    catch { throw 'The Microsoft Edge WebView2 runtime is not installed (https://go.microsoft.com/fwlink/p/?LinkId=2124703).' }
    $CacheFolder
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-SignInScopeString([string[]]$Scopes) {
    if (-not $Scopes) { $Scopes = $script:DefaultScopes }
    (@($Scopes | ForEach-Object { if ($_ -match '^https?://') { $_ } else { "https://graph.microsoft.com/$_" } }) + 'offline_access', 'openid', 'profile') -join ' '
}

function Request-PackTuneToken {
    <# Redeems an authorization code or a refresh token at the tenant's token endpoint. #>
    param([Parameter(Mandatory)][string]$TenantID, [Parameter(Mandatory)][string]$ClientID, [Parameter(Mandatory)][hashtable]$Body, [string[]]$Scopes)
    $Body.client_id = $ClientID
    $Body.scope = Get-SignInScopeString $Scopes
    try { Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 }
    catch {
        $detail = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { $null }
        throw "Token request failed: $(if ($detail) { $detail } else { $_.Exception.Message })"
    }
}

# Watches the Microsoft sign-in page and reports the current step to the host; the host answers with
# __kvFill / __kvClick. Runs after every navigation (the page switches steps without navigating).
$script:SignInPageScript = @'
(() => {
  if (window.__kvSignIn) return;
  window.__kvSignIn = true;
  const q = (s) => document.querySelector(s);
  const shown = (el) => !!el && !el.disabled && el.offsetParent !== null;
  const empty = (s) => shown(q(s)) && !q(s).value;
  // Link or tile "Face, fingerprint, PIN or security key" (only when Keevault signs the passkey and has not yet)
  const toPasskey = () => window.__kvPasskeyShim && !window.__kvPasskeyUsed && (
    [...document.querySelectorAll('a,button,div[role="button"],div[role="listitem"]')].find((el) => shown(el) && /fido|passkey/i.test(el.id || '') || shown(el) && (el.getAttribute('data-value') || '') === 'FidoKey')
    || [...document.querySelectorAll('a,button,div[role="button"],div[role="listitem"]')].find((el) => shown(el) && (el.innerText || '').length < 120 && /gesicht|fingerabdruck|sicherheitsschl|face, fingerprint|security key|passkey/i.test(el.innerText || '')));
  let last = '';
  setInterval(() => {
    let step = '';
    if (/AADSTS(65001|90094|90008|650056)|need admin approval|admin approval required|Genehmigung durch einen Administrator|Administratorgenehmigung/i.test((document.body && document.body.innerText) || '')) step = 'admin-needed';
    else if (empty('input[name="otc"]')) step = 'otp';
    else if (toPasskey()) step = 'to-passkey';
    else if (empty('input[name="passwd"]')) step = 'password';
    else if (empty('input[name="loginfmt"]')) step = 'username';
    else if (shown(q('#KmsiCheckboxField')) && shown(q('#idBtn_Back'))) step = 'kmsi';
    else if (shown(q('[data-value="PhoneAppOTP"]'))) step = 'choose-otp';
    else if (shown(q('#signInAnotherWay'))) step = 'another-way';
    if (step !== last) { last = step; if (step) window.chrome.webview.postMessage(step); }
  }, 400);
  window.__kvFill = (selector, value, submit) => {
    const el = q(selector);
    if (!el) return;
    el.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    setTimeout(() => {
      const b = q(submit) || [...document.querySelectorAll('input[type="submit"],button[type="submit"]')].find(shown);
      if (b) b.click();
    }, 300);
  };
  window.__kvClick = (selector) => { const el = q(selector); if (el) el.click(); };
  window.__kvToPasskey = () => { const el = toPasskey(); if (el) el.click(); };
})();
'@

# Runs before the page's own scripts (only when the Keevault entry holds a passkey): the first passkey request of
# the page (navigator.credentials.get) goes to the host, which has Keevault sign it; the private key never leaves
# Keevault. Declined or failed: the browser's own passkey dialog (Windows Hello) as usual.
$script:PasskeyShimScript = @'
(() => {
  if (window.__kvPasskeyShim || !navigator.credentials || !window.chrome || !window.chrome.webview) return;
  window.__kvPasskeyShim = true;
  const original = navigator.credentials.get.bind(navigator.credentials);
  const b64u = (v) => {
    const b = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const bytes = (s) => {
    s = String(s).replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
    const bin = atob(s), a = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
    return a.buffer;
  };
  const pending = new Map();
  let next = 0;
  window.__kvPasskeyResult = (id, c) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (!c) { p.fallback(); return; }
    const response = { clientDataJSON: bytes(c.response.clientDataJSON), authenticatorData: bytes(c.response.authenticatorData),
      signature: bytes(c.response.signature), userHandle: c.response.userHandle ? bytes(c.response.userHandle) : null };
    if (window.AuthenticatorAssertionResponse) Object.setPrototypeOf(response, window.AuthenticatorAssertionResponse.prototype);
    const cred = { id: c.id, rawId: bytes(c.rawId || c.id), type: 'public-key', authenticatorAttachment: c.authenticatorAttachment || 'platform',
      response, getClientExtensionResults: () => c.clientExtensionResults || {}, toJSON: () => c };
    if (window.PublicKeyCredential) Object.setPrototypeOf(cred, window.PublicKeyCredential.prototype);
    p.resolve(cred);
  };
  navigator.credentials.get = function (options) {
    const pk = options && options.publicKey;
    // Autofill requests (conditional) and every request after the first go to the browser as usual
    if (!pk || options.mediation === 'conditional' || window.__kvPasskeyUsed) return original(options);
    window.__kvPasskeyUsed = true;
    return new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, { resolve, fallback: () => original(options).then(resolve, reject) });
      window.chrome.webview.postMessage('webauthn:' + JSON.stringify({
        id, challenge: b64u(pk.challenge), rpId: pk.rpId || location.hostname,
        allow: (pk.allowCredentials || []).map((x) => b64u(x.id))
      }));
    });
  };
})();
'@

# Entra refuses the consent of a user who is no administrator: the tool says this instead of an error
$script:AdminConsentMessage = 'An administrator must confirm these permissions.'
$script:SignInDiag = @{ Count = 0; LastFolder = $null; LastBrowserPid = $null; FirstMethod = '' }
function Set-PackTuneSignInMethod([string]$Method) {
    # How the first sign-in of this run was done (embedded Microsoft / browser / Keevault), for the log
    if (-not $script:SignInDiag.FirstMethod) { $script:SignInDiag.FirstMethod = $Method }
}
function Get-PackTuneCookieSummary {
    # Names (never values) of the Microsoft sign-in cookies of a WebView2, read through its CookieManager before the navigation
    param($CoreWebView2, [int]$TimeoutMs = 3000)
    $out = @()
    foreach ($site in 'https://login.microsoftonline.com', 'https://login.live.com') {
        try {
            $task = $CoreWebView2.CookieManager.GetCookiesAsync($site)
            $until = (Get-Date).AddMilliseconds($TimeoutMs)
            while (-not $task.IsCompleted -and (Get-Date) -lt $until) {
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
            }
            if ($task.IsCompleted -and -not $task.IsFaulted) {
                $cookies = @($task.Result)
                $names = @($cookies | ForEach-Object { if ($_.IsSession) { "$($_.Name) (session)" } else { "$($_.Name) (persistent)" } } | Sort-Object -Unique)
                $out += "$($site -replace '^https://', ''): $($cookies.Count) cookie(s)$(if ($names.Count) { ' [' + ($names -join ', ') + ']' })"
            }
            else { $out += "$($site -replace '^https://', ''): not readable" }
        }
        catch { $out += "$($site -replace '^https://', ''): not readable ($($_.Exception.Message))" }
    }
    $out -join '; '
}

function Get-PackTuneSessionFolder {
    <# The WebView2 profile of all embedded sign-ins of this Windows user (one Microsoft session: no second password or passkey).
       Only the current user gets access. Sign out clears it (Clear-PackTuneSession). #>
    param([string]$Root = (Join-Path $env:LOCALAPPDATA 'PackTune'))
    $folder = Join-Path $Root 'WebView2Session'
    if (-not (Test-Path $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        (New-Object System.IO.DirectoryInfo $folder).SetAccessControl($acl)
    }
    catch { }
    $folder
}

$script:SignInEnvironments = @{}
$script:TempProfileName = '^PackTuneSignIn-[0-9a-f]{32}$'   # the only names the temporary-profile cleanup deletes

function Remove-PackTuneTree {
    <#
    Deletes a folder tree WITHOUT following links: a symbolic link or junction (reparse point) is removed itself, never
    what it points to (the recursive delete of older Windows PowerShell 5.1 builds can follow junctions). Literal paths
    only (no wildcards). Throws when something is locked, so callers can retry.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
        return
    }
    if (-not $item.PSIsContainer) { $item.Attributes = 'Normal'; [IO.File]::Delete($item.FullName); return }
    foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) { Remove-PackTuneTree -Path $child.FullName }
    $item.Attributes = 'Directory'
    [IO.Directory]::Delete($item.FullName, $false)
}

function Remove-PackTuneTempProfile {
    <# Deletes a temporary sign-in profile (cookies) once its WebView2 browser process has ended; retries while files are locked. #>
    param([Parameter(Mandatory)][string]$Folder, [int]$BrowserPid, [int]$WaitSeconds = 10, [int]$Tries = 20, [int]$DelayMs = 250)
    if ((Split-Path $Folder -Leaf) -notmatch $script:TempProfileName) { throw "Not a temporary sign-in profile: $Folder" }
    if ($BrowserPid) {
        try { $p = Get-Process -Id $BrowserPid -ErrorAction Stop; [void]$p.WaitForExit($WaitSeconds * 1000) } catch { }
    }
    for ($i = 0; $i -lt $Tries; $i++) {
        if (-not (Test-Path -LiteralPath $Folder)) { return $true }
        try { Remove-PackTuneTree -Path $Folder; return $true } catch { Start-Sleep -Milliseconds $DelayMs }
    }
    Write-SignInLog "The temporary sign-in profile $Folder could not be deleted yet; it is removed at the next start." 'Warning'
    $false
}

function Clear-PackTuneSignInLeftovers {
    <# Temporary sign-in profiles of earlier runs (%TEMP%\PackTuneSignIn-*) that are older than a sign-in can take. #>
    param([int]$OlderThanMinutes = 30)
    $cut = (Get-Date).AddMinutes(-$OlderThanMinutes)
    foreach ($d in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'PackTuneSignIn-*' -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $script:TempProfileName -and $_.LastWriteTime -lt $cut })) {
        try { Remove-PackTuneTree -Path $d.FullName } catch { }
    }
}
# Leftovers of earlier runs go at the start (best effort: a profile still in use stays)
try { Clear-PackTuneSignInLeftovers } catch { }
function Get-PackTuneEnvironment {
    <# ONE CoreWebView2Environment per profile folder, created once and used by every sign-in window and the keep-alive window
       (all of them need the same options: none; the passkey shim is a script, not an environment option). Waits with the dispatcher
       running; throws 'The embedded browser could not start: ...' when it cannot be created. #>
    param([Parameter(Mandatory)][string]$UserDataFolder, [int]$TimeoutSeconds = 20)
    if ($script:SignInEnvironments.ContainsKey($UserDataFolder)) { return $script:SignInEnvironments[$UserDataFolder] }
    try {
        New-Item -ItemType Directory -Path $UserDataFolder -Force | Out-Null
        $task = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $UserDataFolder, $null)
        $until = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $task.IsCompleted -and (Get-Date) -lt $until) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 20
        }
        if (-not $task.IsCompleted) { throw 'timed out creating the browser environment' }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException().Message }
        $script:SignInEnvironments[$UserDataFolder] = $task.Result
        $task.Result
    }
    catch { throw "The embedded browser could not start: $($_.Exception.Message)" }
}

function Start-PackTuneSessionHold {
    # A tiny hidden WebView2 on the session folder keeps the browser process (and with it the session cookies) alive
    # between the sign-in windows of one run; every sign-in window then finds the Microsoft session again.
    param([Parameter(Mandatory)][string]$UserDataFolder)
    if ($script:SessionHold -and $script:SessionHold.Folder -eq $UserDataFolder) { return }
    try {
        $w = New-Object System.Windows.Window
        $w.WindowStyle = 'None'; $w.ShowInTaskbar = $false; $w.ShowActivated = $false; $w.ResizeMode = 'NoResize'
        $w.Width = 1; $w.Height = 1; $w.Left = -32000; $w.Top = -32000
        $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
        $w.Content = $wv
        $holdEnv = Get-PackTuneEnvironment $UserDataFolder
        $w.Add_Loaded({ try { [void]$wv.EnsureCoreWebView2Async($holdEnv) } catch { Write-SignInLog "The keep-alive browser window could not start: $($_.Exception.Message)" 'Warning' } }.GetNewClosure())
        $w.Show()
        $script:SessionHold = @{ Folder = $UserDataFolder; Window = $w; View = $wv }
    }
    catch { $script:SessionHold = $null; Write-SignInLog "The keep-alive browser window could not start: $($_.Exception.Message)" 'Warning' }
}

function Close-PackTuneSessionHold {
    # Ends the hidden browser (the cookies stay in the folder). Clear = delete cookies and the folder too (Sign out).
    param([switch]$Clear)
    $h = $script:SessionHold
    $script:SessionHold = $null
    if ($h) {
        try { if ($Clear -and $h.View.CoreWebView2) { $h.View.CoreWebView2.CookieManager.DeleteAllCookies() } } catch { }
        try { $h.View.Dispose() } catch { }
        try { $h.Window.Close() } catch { }
    }
}

function Clear-PackTuneSession {
    param([Parameter(Mandatory)][string]$UserDataFolder)
    Close-PackTuneSessionHold -Clear
    for ($i = 0; $i -lt 5; $i++) {
        try { Remove-PackTuneTree -Path $UserDataFolder; return $true }
        catch { Start-Sleep -Milliseconds 300 }
    }
    $false   # still locked by the browser process; the cookies were deleted above
}
function Get-PackTuneAuthorizeUrl {
    # The authorize URL of the v2 endpoint (dynamic consent: the scopes asked for here are what the sign-in grants).
    # Prompt: 'default' sends none (an existing session goes straight on, the consent page shows when a scope is new),
    # 'consent' makes the administrator see the consent page. Never 'login' in this tool.
    param([Parameter(Mandatory)][string]$TenantID, [Parameter(Mandatory)][string]$ClientID, [string[]]$Scopes, [Parameter(Mandatory)][string]$State, [Parameter(Mandatory)][string]$Challenge,
        [string]$Prompt = 'default', [string]$LoginHint)
    $query = [ordered]@{
        client_id             = $ClientID
        response_type         = 'code'
        redirect_uri          = $script:SignInRedirect
        response_mode         = 'query'
        scope                 = (Get-SignInScopeString $Scopes)
        state                 = $State
        code_challenge        = $Challenge
        code_challenge_method = 'S256'
    }
    if ($Prompt -and $Prompt -ne 'default') { $query.prompt = $Prompt }
    if ($LoginHint) { $query.login_hint = $LoginHint }
    "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/authorize?" + (($query.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [Uri]::EscapeDataString($_.Value) }) -join '&')
}
function Invoke-PackTuneBrowserSignIn {
    <#
    Runs the Microsoft sign-in (authorization code + PKCE) in an embedded browser window and returns the token
    response (access_token, refresh_token, expires_in, scope). $Fill gets the step ('username', 'password', 'otp')
    and returns the value to fill in, or $null to leave it to the user. Each value is filled in once (the one-time
    code twice at most), so a rejected password is not retried. Cookies live in a temporary profile only.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantID,
        [Parameter(Mandatory)][string]$ClientID,
        [Parameter(Mandatory)][string]$CacheFolder,
        [string[]]$Scopes,
        [string]$LoginHint,
        [scriptblock]$Fill,
        [switch]$HasOtp,
        # Signs a passkey request: gets (origin, challenge, rpId, allowed credential ids) and returns the
        # PublicKeyCredential as object, or $null for the browser's own passkey dialog
        [scriptblock]$Passkey,
        [string]$Title = 'Sign in to Microsoft Intune',
        [string]$Hint,
        # Profile folder kept after the window closes (shared session) and the prompt: login (always ask) or select_account
        [string]$UserDataFolder,
        [ValidateSet("login", "select_account", "none", "consent", "default")][string]$Prompt = "default",
        [System.Windows.Window]$Owner,
        # Tests: gets ($win, $wv) before the window opens (e.g. to render it off-screen)
        [scriptblock]$Configure
    )
    [void](Get-PackTuneWebView2 -CacheFolder $CacheFolder)
    Add-Type -AssemblyName System.Web
    if ($Prompt -eq 'consent' -and -not $Hint) { $Hint = 'Microsoft asks you to confirm your identity for this permission change. An administrator then confirms the permissions for the organization.' }

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes); $verifier = ConvertTo-Base64Url $bytes
    $rng.GetBytes($bytes); $state = ConvertTo-Base64Url $bytes
    $sha = [Security.Cryptography.SHA256]::Create()
    $challenge = ConvertTo-Base64Url $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
    $url = Get-PackTuneAuthorizeUrl -TenantID $TenantID -ClientID $ClientID -Scopes $Scopes -State $state -Challenge $challenge -Prompt $Prompt -LoginHint $LoginHint

    # Window in the Windows 11 look of the tool: hint on top, browser in the middle, Cancel below; modal to the owner
    $brush = New-Object System.Windows.Media.BrushConverter
    $win = New-Object System.Windows.Window
    $win.Title = $Title
    $win.Width = 500; $win.Height = 700
    $win.Background = $brush.ConvertFrom('#F3F3F3')
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
    $win.ResizeMode = 'CanResize'
    $win.ShowInTaskbar = $true
    if ($Owner) { $win.Owner = $Owner; $win.WindowStartupLocation = 'CenterOwner' } else { $win.WindowStartupLocation = 'CenterScreen' }
    $grid = New-Object System.Windows.Controls.DockPanel
    if ($Hint) {
        $head = New-Object System.Windows.Controls.Border
        $head.Padding = '16,10'
        [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = $Hint
        $text.Foreground = $brush.ConvertFrom('#5F5F5F')
        $text.TextWrapping = 'Wrap'; $text.FontSize = 12
        $head.Child = $text
        [void]$grid.Children.Add($head)
    }
    $foot = New-Object System.Windows.Controls.Border
    $foot.Padding = '16,10'; $foot.Background = $brush.ConvertFrom('#F7F7F7'); $foot.BorderBrush = $brush.ConvertFrom('#E5E5E5'); $foot.BorderThickness = '0,1,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($foot, 'Bottom')
    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = 'Cancel'; $cancel.HorizontalAlignment = 'Right'; $cancel.Padding = '18,6'; $cancel.IsCancel = $true
    $cancel.Add_Click({ $win.Close() })
    $foot.Child = $cancel
    [void]$grid.Children.Add($foot)

    $persistent = [bool]$UserDataFolder   # a shared profile keeps the Microsoft session between sign-ins of the same run (no second password)
    $userData = if ($persistent) { $UserDataFolder } else { Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N')) }
    $environment = Get-PackTuneEnvironment $userData   # throws "could not start" (the caller falls back / tells) instead of leaving a blank window
    if ($persistent) { Start-PackTuneSessionHold $UserDataFolder }
    $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    [void]$grid.Children.Add($wv)
    $win.Content = $grid

    $ctx = @{ AdminNeeded = $false; Redirect = $null; Done = @{}; Otp = 0; ToPasskey = 0; PasskeyBusy = $false; Error = $null }
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) { $ctx.Error = "The embedded browser could not start: $($e.InitializationException.Message)"; $win.Close(); return }
        try { $ctx.BrowserPid = $s.CoreWebView2.BrowserProcessId } catch { }
        $s.CoreWebView2.Settings.AreDevToolsEnabled = $false
        $s.CoreWebView2.Settings.IsStatusBarEnabled = $false
        if ($Passkey) { [void]$s.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync($script:PasskeyShimScript) }
        # Diagnostics (no tokens, no cookie values): profile, browser process, cookies before the navigation, request parameters
        try {
            $d = $script:SignInDiag; $d.Count++
            $browserPid = $s.CoreWebView2.BrowserProcessId
            $holdPid = $null; try { if ($script:SessionHold -and $script:SessionHold.View.CoreWebView2) { $holdPid = $script:SessionHold.View.CoreWebView2.BrowserProcessId } } catch { }
            $sameFolder = $d.LastFolder -and $d.LastFolder -eq $userData
            $sameProc = $d.LastBrowserPid -and $d.LastBrowserPid -eq $browserPid
            $q = [System.Web.HttpUtility]::ParseQueryString(([Uri]$url).Query)
            Write-SignInLog ("Sign-in window #{0}: first sign-in of this run: {1}; user data folder: {2} (persistent profile: {3}, same folder as the previous window: {4}); browser process {5} (same as the previous window: {6}; hidden session window runs: {7}{8})" -f `
                $d.Count, $(if ($d.FirstMethod) { $d.FirstMethod } else { 'embedded Microsoft' }), $userData, $persistent, $(if ($d.LastFolder) { $sameFolder } else { 'n/a (first window)' }), $browserPid, $(if ($d.LastBrowserPid) { $sameProc } else { 'n/a (first window)' }), [bool]$script:SessionHold, $(if ($holdPid) { ", same process as this window: $($holdPid -eq $browserPid)" } else { '' })) 'Info'
            Write-SignInLog ("Sign-in window #{0}: client id {1}; prompt {2}; login_hint sent: {3}; domain_hint sent: {4}; scopes: {5}" -f $d.Count, $ClientID, $(if ($q['prompt']) { $q['prompt'] } else { '(none)' }), [bool]$q['login_hint'], [bool]$q['domain_hint'], $q['scope']) 'Info'
            Write-SignInLog ("Sign-in window #{0}: cookies before the navigation: {1}" -f $d.Count, (Get-PackTuneCookieSummary $s.CoreWebView2)) 'Info'
            $d.LastFolder = $userData; $d.LastBrowserPid = $browserPid
        }
        catch { Write-SignInLog "Sign-in diagnostics failed: $($_.Exception.Message)" 'Warning' }
        $s.CoreWebView2.Navigate($url)
    })
    $wv.Add_NavigationStarting({
        param($s, $e)
        if ($e.Uri.StartsWith($script:SignInRedirect, [StringComparison]::OrdinalIgnoreCase)) {
            $e.Cancel = $true
            $ctx.Redirect = $e.Uri
            $win.Close()
        }
    })
    $wv.Add_NavigationCompleted({ param($s, $e) [void]$s.ExecuteScriptAsync($script:SignInPageScript) })
    $wv.Add_WebMessageReceived({
        param($s, $e)
        # Values only go to Microsoft's sign-in pages
        $origin = try { ([Uri]$e.Source).Host } catch { '' }
        if ($origin -notin $script:SignInHosts) { return }
        $step = $e.TryGetWebMessageAsString()
        $js = { param($f, [string[]]$a) [void]$s.ExecuteScriptAsync("window.$f(" + (($a | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ')') }
        if ($step -and $step.StartsWith('webauthn:')) {
            # Passkey request of the page: Keevault signs it (the user confirms in Keevault), else the browser dialog
            $req = $step.Substring(9) | ConvertFrom-Json
            $cred = $null
            if ($Passkey -and -not $ctx.PasskeyBusy) {
                $ctx.PasskeyBusy = $true
                try { $cred = & $Passkey ([Uri]$e.Source).GetLeftPart([UriPartial]::Authority) ([string]$req.challenge) ([string]$req.rpId) @($req.allow) }
                catch { Write-SignInLog "Keevault: passkey not signed ($($_.Exception.Message)). Windows asks for the passkey instead." 'Warning' }
                finally { $ctx.PasskeyBusy = $false }
            }
            $answer = if ($cred) { ConvertTo-Json $cred -Depth 6 -Compress } else { 'null' }
            [void]$s.ExecuteScriptAsync("window.__kvPasskeyResult($([int]$req.id), $answer)")
            return
        }
        switch ($step) {
            'admin-needed' { $ctx.AdminNeeded = $true }
            'to-passkey' {
                # Keevault has the passkey: take "Face, fingerprint, PIN or security key" instead of the password
                if (-not $Passkey -or $ctx.ToPasskey -ge 2) { return }
                $ctx.ToPasskey++
                [void]$s.ExecuteScriptAsync('window.__kvToPasskey()')
            }
            'username' {
                if ($ctx.Done.username -or -not $Fill) { return }
                $ctx.Done.username = $true
                $v = & $Fill 'username'
                if ($v) { & $js '__kvFill' 'input[name="loginfmt"]', $v, '#idSIButton9' }
            }
            'password' {
                if ($ctx.Done.password -or -not $Fill) { return }
                $ctx.Done.password = $true
                $v = & $Fill 'password'
                if ($v) { & $js '__kvFill' 'input[name="passwd"]', $v, '#idSIButton9' }
            }
            'otp' {
                if ($ctx.Otp -ge 2 -or -not $Fill) { return }
                $ctx.Otp++
                $v = & $Fill 'otp'
                if ($v) { & $js '__kvFill' 'input[name="otc"]', $v, '#idSubmit_SAOTCC_Continue' }
            }
            'kmsi' {
                # "Stay signed in?": Yes in the shared profile, so Microsoft sets the persistent cookie (ESTSAUTHPERSISTENT) and the next window needs no new sign-in. Temporary profile: No.
                if ($persistent) { & $js '__kvClick' '#idSIButton9'; Write-SignInLog 'Sign-in window: Stay signed in? answered Yes (the session cookie is kept in the profile).' } else { & $js '__kvClick' '#idBtn_Back' }
            }
            'choose-otp' {
                if (-not $HasOtp -or $ctx.Done.chooseOtp) { return }
                $ctx.Done.chooseOtp = $true
                & $js '__kvClick' '[data-value="PhoneAppOTP"]'
            }
            'another-way' {
                if (-not $HasOtp -or $ctx.Done.anotherWay) { return }
                $ctx.Done.anotherWay = $true
                & $js '__kvClick' '#signInAnotherWay'
            }
        }
    })
    # Come to the front even if another app (Keevault) has the focus right now
    $win.Add_ContentRendered({ if ($win.ShowActivated) { $win.Topmost = $true; [void]$win.Activate(); $win.Topmost = $false } })
    if ($Configure) { & $Configure $win $wv }
    $win.Add_Loaded({ try { [void]$wv.EnsureCoreWebView2Async($environment) } catch { $ctx.Error = "The embedded browser could not start: $($_.Exception.Message)"; $win.Close() } })
    # A window that never initializes must not stay blank
    $watch = New-Object System.Windows.Threading.DispatcherTimer
    $watch.Interval = [TimeSpan]::FromSeconds(25)
    $watch.Add_Tick({ $watch.Stop(); if (-not $wv.CoreWebView2) { $ctx.Error = 'The embedded browser could not start: it did not initialize in time.'; $win.Close() } })
    $watch.Start()
    try { [void]$win.ShowDialog() }
    finally {
        $watch.Stop()
        $wv.Dispose()
        # The temporary profile holds the session cookies: deleted after its browser process has ended, with retries
        if (-not $persistent) { [void]$script:SignInEnvironments.Remove($userData); [void](Remove-PackTuneTempProfile -Folder $userData -BrowserPid $ctx.BrowserPid) }
    }

    if ($ctx.Error) { throw $ctx.Error }
    if (-not $ctx.Redirect) { if ($ctx.AdminNeeded) { throw $script:AdminConsentMessage }; throw 'Sign-in cancelled.' }
    $result = [System.Web.HttpUtility]::ParseQueryString(([Uri]$ctx.Redirect).Query)
    if ($result['error'] -in 'consent_required', 'interaction_required' -or "$($result['error_description'])" -match 'AADSTS(65001|90094|90008|650056)') { throw $script:AdminConsentMessage }
    if ($result['error']) { throw "Sign-in failed: $($result['error_description'])" }
    if ($result['state'] -ne $state) { throw 'Sign-in failed: the answer does not belong to this sign-in.' }
    Request-PackTuneToken -TenantID $TenantID -ClientID $ClientID -Scopes $Scopes -Body @{
        grant_type    = 'authorization_code'
        code          = $result['code']
        redirect_uri  = $script:SignInRedirect
        code_verifier = $verifier
    }
}


Export-ModuleMember -Function Set-PackTuneSignInLog, Write-SignInLog, Get-PackTuneWriteRisk, Get-PackTuneWebView2, Get-PackTuneEnvironment, Set-PackTuneSignInMethod,
    Get-PackTuneCookieSummary, Get-PackTuneSessionFolder, Start-PackTuneSessionHold, Close-PackTuneSessionHold, Clear-PackTuneSession, Get-PackTuneAuthorizeUrl,
    Request-PackTuneToken, Invoke-PackTuneBrowserSignIn
