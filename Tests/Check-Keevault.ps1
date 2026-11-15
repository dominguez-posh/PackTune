<#
.SYNOPSIS
    Security checks of Modules\Keevault.psm1, which also runs elevated (AVDTune on multi-session hosts):
    (1) Keevault is started as Node only from this user's installation (or Program Files), a running Keevault counts only
    in this session and for this user, files writable by others / wrong signature / wrong pinned hash are refused.
    The sign-in itself (WebView2 SDK, temporary profiles) is checked in Tests\Check-SignIn.ps1.
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
# Keevault builds on the sign-in module (one shared instance) and passes its functions on
$signin = Get-Module -All PackTune.SignIn
Test-Check 'Keevault uses the sign-in module and passes on its functions (callers that import only Keevault keep working)' ($signin -and (Get-Command Invoke-PackTuneBrowserSignIn).Module.Name -in 'Keevault', 'PackTune.SignIn' -and (Get-Command Connect-PackTuneWithKeevault).Module.Name -eq 'Keevault' -and $src -notmatch 'function Invoke-PackTuneBrowserSignIn')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
