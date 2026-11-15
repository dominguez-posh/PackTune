<#
.SYNOPSIS
    Checks of Modules\PackTune.SignIn.psm1, the Microsoft sign-in that other tools (AVDTune, elevated) use without Keevault:
    it loads alone; the WebView2 SDK is pinned (version and SHA256 of the package and of each file, no "latest" lookup) and
    checked on every load, fail closed; temporary sign-in profiles are deleted after the browser ended, leftovers at start.
    Nothing is downloaded (download stand-in), no Keevault, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-SignIn.ps1
#>
$ErrorActionPreference = 'Stop'
trap { "FAIL  the check stopped before the end: $($_.Exception.Message)"; exit 1 }
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSignInCheck-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = Join-Path $work 'Local'
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
function Get-Thrown([scriptblock]$Block) { try { & $Block | Out-Null; '' } catch { $_.Exception.Message } }

# --- the module alone, without Keevault
Import-Module (Join-Path $repo 'Modules\PackTune.SignIn.psm1') -Force
$mod = Get-Module PackTune.SignIn
$needed = 'Invoke-PackTuneBrowserSignIn', 'Request-PackTuneToken', 'Set-PackTuneSignInLog', 'Get-PackTuneWebView2'
Test-Check 'the sign-in module loads alone and exports what AVDTune uses' ($mod -and -not (Get-Module Keevault) -and @($needed | Where-Object { -not (Get-Command $_ -Module PackTune.SignIn -ErrorAction SilentlyContinue) }).Count -eq 0)
$src = Get-Content (Join-Path $repo 'Modules\PackTune.SignIn.psm1') -Raw
$code = ($src -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*//' }) -join "`n"
Test-Check 'the sign-in module calls no Keevault code (no MCP, no Keevault functions)' ($code -notmatch 'Keevault(Mcp|Trust|Processes)|Connect-PackTuneWithKeevault|keevault-mcp|Import-Module')
$log = New-Object System.Collections.Generic.List[string]
Set-PackTuneSignInLog { param($t, $l) $log.Add("$l|$t") }
& $mod { Write-SignInLog 'hello' }
Test-Check 'Set-PackTuneSignInLog: the progress goes to the given sink' ($log -contains 'Info|hello')

# --- pinned WebView2 SDK
$pin = & $mod { [pscustomobject]@{ Version = $script:WebView2SdkVersion; Nupkg = $script:WebView2NupkgSha256; Dll = $script:WebView2DllSha256 } }
Test-Check 'pinned: a fixed stable version and SHA256 of the package and of all three files' ($pin.Version -match '^\d+\.\d+\.\d+\.\d+$' -and $pin.Nupkg -match '^[0-9A-F]{64}$' -and @($pin.Dll.Values | Where-Object { $_ -match '^[0-9A-F]{64}$' }).Count -eq 3) ($pin | ConvertTo-Json -Compress)
Test-Check 'pinned: no lookup of the latest version' ($src -notmatch 'index\.json' -and $src -notmatch 'versions \|')
# Stand-ins signed by Microsoft (System.Management.Automation.dll, renamed) in a package of the expected layout
$sma = [System.Management.Automation.PSObject].Assembly.Location
$pkgDir = Join-Path $work 'pkg'
foreach ($rel in 'lib\net462\Microsoft.Web.WebView2.Core.dll', 'lib\net462\Microsoft.Web.WebView2.Wpf.dll', 'runtimes\win-x64\native\WebView2Loader.dll') {
    $t = Join-Path $pkgDir $rel; New-Item -ItemType Directory -Path (Split-Path $t) -Force | Out-Null; Copy-Item $sma $t
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$goodPkg = Join-Path $work 'good.nupkg'
# Entry names with "/" as in a real .nupkg (CreateFromDirectory of .NET Framework may write "\")
$zw = [IO.Compression.ZipFile]::Open($goodPkg, 'Create')
try { foreach ($rel in 'lib/net462/Microsoft.Web.WebView2.Core.dll', 'lib/net462/Microsoft.Web.WebView2.Wpf.dll', 'runtimes/win-x64/native/WebView2Loader.dll') { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zw, $sma, $rel) } }
finally { $zw.Dispose() }
$badPkg = Join-Path $work 'bad.nupkg'; 'not the package' | Set-Content $badPkg
$global:DlUris = New-Object System.Collections.Generic.List[string]
$global:DlSource = $badPkg
& $mod { $script:WebView2Download = { param($Uri, $Out) $global:DlUris.Add($Uri); Copy-Item $global:DlSource $Out } }
$cache = Join-Path $env:LOCALAPPDATA 'PackTune\WebView2'
$m = Get-Thrown { & $mod { param($c) Install-PackTuneWebView2Sdk -CacheFolder $c } $cache }
Test-Check 'download: a package with another hash is refused, nothing installed' ($m -like '*not the pinned package*' -and -not (Test-Path (Join-Path $cache 'Microsoft.Web.WebView2.Core.dll'))) $m
Test-Check 'download: exactly the pinned version from nuget.org' ($global:DlUris[-1] -eq "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$($pin.Version)/microsoft.web.webview2.$($pin.Version).nupkg") $global:DlUris[-1]
$global:DlSource = $goodPkg
$standIn = (Get-FileHash $sma -Algorithm SHA256).Hash
& $mod { param($n) $script:WebView2NupkgSha256 = $n } (Get-FileHash $goodPkg -Algorithm SHA256).Hash
$m = Get-Thrown { & $mod { param($c) Install-PackTuneWebView2Sdk -CacheFolder $c } $cache }
Test-Check 'download: the right package, but files other than the pinned ones are refused and removed' ($m -like '*is not the pinned file*' -and -not (Test-Path $cache)) $m
& $mod { param($h) foreach ($k in @($script:WebView2DllSha256.Keys)) { $script:WebView2DllSha256[$k] = $h } } $standIn
$m = Get-Thrown { & $mod { param($c) Install-PackTuneWebView2Sdk -CacheFolder $c } $cache }
$marker = Get-Content (Join-Path $cache 'webview2-sdk.json') -Raw | ConvertFrom-Json
Test-Check 'download: pinned package and files -> installed, version recorded' (-not $m -and $marker.Version -eq $pin.Version -and $null -eq (& $mod { param($c) Test-PackTuneWebView2Sdk -CacheFolder $c } $cache)) $m
[IO.File]::AppendAllText((Join-Path $cache 'Microsoft.Web.WebView2.Wpf.dll'), 'x')
$p = & $mod { param($c) Test-PackTuneWebView2Sdk -CacheFolder $c } $cache
Test-Check 'every load: a changed file of the pinned version is not loaded' ($p -like '*Wpf.dll is missing or not signed by Microsoft*' -or $p -like '*Wpf.dll is not the pinned file*') $p
$m = Get-Thrown { Get-PackTuneWebView2 -CacheFolder $cache }
Test-Check 'Get-PackTuneWebView2 fails closed: the SDK is removed, the message says to sign in again' ($m -like '*failed its check*removed*Sign in again*' -and -not (Test-Path $cache)) $m
# A cache of another version (or of earlier PackTune versions) is replaced by the pinned one, never loaded
New-Item -ItemType Directory -Path $cache -Force | Out-Null
foreach ($n in 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll') { Copy-Item $sma (Join-Path $cache $n) }
'{ "Version": "1.0.1" }' | Set-Content (Join-Path $cache 'webview2-sdk.json')
$global:DlSource = $badPkg; $before = $global:DlUris.Count
$m = Get-Thrown { Get-PackTuneWebView2 -CacheFolder $cache }
Test-Check 'a cache of another version: the pinned version is downloaded instead (here refused: wrong package)' ($global:DlUris.Count -eq $before + 1 -and $m -like '*not the pinned package*') $m
Test-Check 'look-alike signer names do not pass the Microsoft check' ('CN=x, O=Microsoft Corporation Evil, C=US' -notmatch '(^|,\s*)O=Microsoft Corporation(\s*,|$)' -and 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond' -match '(^|,\s*)O=Microsoft Corporation(\s*,|$)')

# --- temporary sign-in profiles
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'Default\Network') -Force | Out-Null
$cookie = Join-Path $tmp 'Default\Network\Cookies'; 'cookie' | Set-Content $cookie
# A browser stand-in holds the cookie file for 1.5 seconds (a process this check starts and waits for)
$holder = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "`$f = [IO.File]::Open('$cookie', 'Open', 'Read', 'None'); Start-Sleep -Milliseconds 1500; `$f.Close()"
Start-Sleep -Milliseconds 600
$ok = & $mod { param($f) Remove-PackTuneTempProfile -Folder $f -BrowserPid 0 -Tries 30 -DelayMs 200 } $tmp
Test-Check 'temporary profile: deleted with retries once the browser released the files' ($ok -and -not (Test-Path $tmp)) "ok=$ok"
$holder.WaitForExit(); $holder.Dispose()
$tmp2 = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp2 | Out-Null
$browser = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 1200'
$t0 = Get-Date
$ok = & $mod { param($f, $p) Remove-PackTuneTempProfile -Folder $f -BrowserPid $p } $tmp2 $browser.Id
Test-Check 'temporary profile: deleted after the browser process has ended (waited for it)' ($ok -and -not (Test-Path $tmp2) -and $browser.HasExited -and ((Get-Date) - $t0).TotalMilliseconds -ge 900) ((Get-Date) - $t0).TotalMilliseconds
$browser.Dispose()
$old = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $old | Out-Null
(Get-Item $old).LastWriteTime = (Get-Date).AddHours(-2)
$fresh = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $fresh | Out-Null
& $mod { Clear-PackTuneSignInLeftovers }
Test-Check 'leftovers of earlier runs are removed at start, a profile of a running sign-in stays' (-not (Test-Path $old) -and (Test-Path $fresh))
Remove-Item $fresh -Recurse -Force
Test-Check 'the sign-in window deletes its temporary profile through Remove-PackTuneTempProfile (after the browser ended)' ($src -match 'Remove-PackTuneTempProfile -Folder \$userData -BrowserPid \$ctx\.BrowserPid' -and $src -match 'try \{ Clear-PackTuneSignInLeftovers \} catch')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
