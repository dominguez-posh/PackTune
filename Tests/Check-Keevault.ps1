<#
.SYNOPSIS
    Security checks of Modules\Keevault.psm1, which also runs elevated (AVDTune on multi-session hosts):
    (1) Keevault is started as Node only from this user's installation (or Program Files), a running Keevault counts only
    in this session and for this user, files writable by others / wrong signature / wrong pinned hash are refused;
    (2) the cached WebView2 SDK is checked (Microsoft signature, hashes of the checked download, permissions) on every load,
    fail closed; (3) temporary sign-in profiles are deleted after the browser has ended (with retries), leftovers at start.
    No Keevault is started, nothing is downloaded, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Keevault.ps1
#>
$ErrorActionPreference = 'Stop'
trap { "FAIL  the check stopped before the end: $($_.Exception.Message)"; exit 1 }
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneKeevault-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = Join-Path $work 'Local'; $env:APPDATA = Join-Path $work 'Roaming'
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
function Get-Thrown([scriptblock]$Block) { try { & $Block | Out-Null; '' } catch { $_.Exception.Message } }

Import-Module (Join-Path $repo 'Modules\Keevault.psm1') -Force
$mod = Get-Module Keevault
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$session = (Get-Process -Id $PID).SessionId

# An unsigned Keevault.exe at the installed place, the MCP script of this user
$kvDir = Join-Path $env:LOCALAPPDATA 'Programs\Keevault'; New-Item -ItemType Directory -Path $kvDir -Force | Out-Null
$exe = Join-Path $kvDir 'Keevault.exe'
Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition 'public static class KvFake { public static void Main() { } }'
$mcpDir = Join-Path $env:APPDATA 'KeyVault PwSafe\mcp'; New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
$mcp = Join-Path $mcpDir 'keevault-mcp.cjs'; 'console.log(1)' | Set-Content $mcp
$evilDir = Join-Path $work 'Evil'; New-Item -ItemType Directory -Path $evilDir -Force | Out-Null
$evil = Join-Path $evilDir 'Keevault.exe'; Copy-Item $exe $evil

& $mod { $script:KeevaultProcessSource = { $global:KvTestProcs } }
function Set-Procs($List) { $global:KvTestProcs = $List }
# --- (1) which Keevault counts and is started
Set-Procs @([pscustomobject]@{ Id = 1; SessionId = $session + 1; Path = $exe; OwnerSid = $me })
$kv = Find-KeevaultMcp
Test-Check 'a Keevault in another session does not count' (-not $kv.Running -and $kv.Exe -eq $exe)
Set-Procs @([pscustomobject]@{ Id = 1; SessionId = $session; Path = $exe; OwnerSid = 'S-1-5-21-1-2-3-999' })
Test-Check 'a Keevault of another user does not count' (-not (Find-KeevaultMcp).Running)
Set-Procs @([pscustomobject]@{ Id = 1; SessionId = $session; Path = $evil; OwnerSid = $me })
$kv = Find-KeevaultMcp
Test-Check 'the exe is never taken from a running process (other path)' (-not $kv.Running -and $kv.Exe -eq $exe) $kv.Exe
Set-Procs @([pscustomobject]@{ Id = 1; SessionId = $session; Path = $exe; OwnerSid = $me })
$kv = Find-KeevaultMcp
Test-Check 'own session, own user, installed exe: Keevault counts as running' ($kv.Running -and $kv.Installed -and $kv.McpEnabled)
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } $kv }
Test-Check 'unsigned Keevault at its place, files only writable by this user/admins: trusted' (-not $m) $m
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } ([pscustomobject]@{ Exe = $evil; Script = $mcp }) }
Test-Check 'an exe outside the installation folders is refused' ($m -like '*only an installation under*') $m
# Writable by Everyone: program folder, then the MCP script
function Grant-Everyone([string]$Path) { $a = Get-Acl $Path; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-1-0'), 'Modify', 'Allow'))); Set-Acl $Path $a }
function Revoke-Everyone([string]$Path) { $a = Get-Acl $Path; [void]$a.RemoveAccessRuleAll((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-1-0'), 'Modify', 'Allow'))); Set-Acl $Path $a }
Grant-Everyone $kvDir
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } $kv }
Test-Check 'program folder writable by others: refused with the reason' ($m -like '*can be changed by others*S-1-1-0*') $m
Revoke-Everyone $kvDir
Grant-Everyone $mcp
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } $kv }
Test-Check 'MCP script writable by others: refused' ($m -like "*MCP script is not used*") $m
Revoke-Everyone $mcp
Set-KeevaultTrust -Sha256 @('00' * 32)
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } $kv }
Test-Check 'pinned hash: another Keevault.exe is refused' ($m -like '*not one of the pinned versions*') $m
Set-KeevaultTrust -Sha256 @((Get-FileHash $exe -Algorithm SHA256).Hash)
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } $kv }
Test-Check 'pinned hash: the pinned Keevault.exe is trusted' (-not $m) $m
Set-KeevaultTrust -Sha256 @() -Publisher @('CN=Keevault')
$m = Get-Thrown { & $mod { param($k) Assert-KeevaultTrust $k } $kv }
Test-Check 'pinned publisher: an unsigned Keevault.exe is refused' ($m -like '*not signed, but a publisher is pinned*') $m
Set-KeevaultTrust -Publisher @()
$src = Get-Content (Join-Path $repo 'Modules\Keevault.psm1') -Raw
Test-Check 'Connect-KeevaultMcp checks the trust before it starts Keevault as Node' ($src -match "Assert-KeevaultTrust \`$kv\s+\`$psi = New-Object System\.Diagnostics\.ProcessStartInfo")

# --- (2) WebView2 SDK on every load: stand-ins signed by Microsoft (System.Management.Automation.dll, renamed)
$sma = [System.Management.Automation.PSObject].Assembly.Location
$cache = Join-Path $env:LOCALAPPDATA 'PackTune\WebView2'; New-Item -ItemType Directory -Path $cache -Force | Out-Null
$names = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll'
foreach ($n in $names) { Copy-Item $sma (Join-Path $cache $n) }
$p = & $mod { param($c) Test-PackTuneWebView2Sdk -CacheFolder $c } $cache
Test-Check 'no record of a checked download: not loaded' ($p -like '*no record*') $p
$hashes = [ordered]@{}; foreach ($n in $names) { $hashes[$n] = (Get-FileHash (Join-Path $cache $n) -Algorithm SHA256).Hash }
([ordered]@{ Version = '1.0.0'; Sha256 = $hashes } | ConvertTo-Json) | Set-Content (Join-Path $cache 'webview2-sdk.json')
$p = & $mod { param($c) Test-PackTuneWebView2Sdk -CacheFolder $c } $cache
Test-Check 'signed by Microsoft and the files of the checked download: loaded' ($null -eq $p) $p
$hashes['Microsoft.Web.WebView2.Wpf.dll'] = '11' * 32
([ordered]@{ Version = '1.0.0'; Sha256 = $hashes } | ConvertTo-Json) | Set-Content (Join-Path $cache 'webview2-sdk.json')
$p = & $mod { param($c) Test-PackTuneWebView2Sdk -CacheFolder $c } $cache
Test-Check 'another (still Microsoft-signed) file than the checked one: not loaded' ($p -like '*Wpf.dll is not the file of the checked download*') $p
Copy-Item $exe (Join-Path $cache 'WebView2Loader.dll') -Force
$hashes['Microsoft.Web.WebView2.Wpf.dll'] = (Get-FileHash (Join-Path $cache 'Microsoft.Web.WebView2.Wpf.dll') -Algorithm SHA256).Hash
$hashes['WebView2Loader.dll'] = (Get-FileHash (Join-Path $cache 'WebView2Loader.dll') -Algorithm SHA256).Hash
([ordered]@{ Version = '1.0.0'; Sha256 = $hashes } | ConvertTo-Json) | Set-Content (Join-Path $cache 'webview2-sdk.json')
$p = & $mod { param($c) Test-PackTuneWebView2Sdk -CacheFolder $c } $cache
Test-Check 'an unsigned DLL: not loaded' ($p -like '*WebView2Loader.dll is missing or not signed by Microsoft*') $p
$m = Get-Thrown { Get-PackTuneWebView2 -CacheFolder $cache }
Test-Check 'Get-PackTuneWebView2 fails closed: the SDK is removed, the message says to sign in again' ($m -like '*failed its check*removed*Sign in again*' -and -not (Test-Path $cache)) $m
Test-Check 'look-alike signer names do not pass the Microsoft check' ('CN=x, O=Microsoft Corporation Evil, C=US' -notmatch '(^|,\s*)O=Microsoft Corporation(\s*,|$)' -and 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond' -match '(^|,\s*)O=Microsoft Corporation(\s*,|$)')

# --- (3) temporary sign-in profiles
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
