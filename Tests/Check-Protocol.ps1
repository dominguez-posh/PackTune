<#
.SYNOPSIS
    Checks of the session protocol (PackTune-Protocol.ps1): the action journal fed from fake jobs, English and German text, text and
    Markdown, secrets never recorded, atomic auto-save and recovery after a crash, history from the local folder and the package store
    (fake SharePoint), de-duplication, damaged files, the language setting. No network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Protocol.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneProtocol-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeSharePoint.ps1')

function New-FakeJob($Kind, $Title, $Display, $Status, $Result = @(), $Source = $null, [datetime]$At = (Get-Date)) {
    @{ Kind = $Kind; Title = $Title; Display = $Display; Status = $Status; Result = $Result; Source = $Source; Finished = $At }
}
$t0 = Get-Date '2026-11-14T09:00:00'

# --- the journal from fake jobs
$p = New-PackTuneProtocol -Admin 'Ada Admin' -Account 'ada@contoso.com' -Tenant 'contoso.onmicrosoft.com' -Started $t0
$jobs = @(
    (New-FakeJob 'deploy' 'Deploying 7zip' '7zip' 'succeeded' @('x') 'Chocolatey' $t0.AddMinutes(4))
    (New-FakeJob 'deploy' 'Deploying git' 'git' 'failed' @() 'winget' $t0.AddMinutes(6))
    (New-FakeJob 'assign' 'Assignment of 7zip for all users: required' '7zip: required' 'succeeded' @() $null $t0.AddMinutes(9))
    (New-FakeJob 'policy' 'Update settings of 7zip: updates user prompt, version 24.08' '7zip' 'succeeded' @() $null $t0.AddMinutes(12))
    (New-FakeJob 'remove' 'Removing Old Tool' 'Old Tool' 'succeeded' @() $null $t0.AddMinutes(15))
    (New-FakeJob 'custom' 'Removing Keevault from Intune' 'Keevault' 'succeeded' @() $null $t0.AddMinutes(16))
    (New-FakeJob 'test' 'Sandbox test of 7zip' 'Sandbox: 7zip' 'succeeded' @([pscustomobject]@{ Verdict = 'Passed'; Message = 'ok' }) $null $t0.AddMinutes(20))
    (New-FakeJob 'test' 'Sandbox test of Foo' 'Sandbox: Foo' 'succeeded' @([pscustomobject]@{ Verdict = 'Failed'; Message = 'Detection rule still true after uninstall' }) $null $t0.AddMinutes(25))
    (New-FakeJob 'custom' 'Deploying Keevault (0.9.34) from the MSI' 'Keevault 0.9.34' 'succeeded' @() $null $t0.AddMinutes(30))
    (New-FakeJob 'takeover' 'Taking over 3 app(s)' 'Import: take over' 'succeeded' @() $null $t0.AddMinutes(35))
    (New-FakeJob 'repomove' 'Moving Keevault to acme' 'Move Keevault' 'succeeded' @() $null $t0.AddMinutes(38))
    (New-FakeJob 'store' 'Setting up the PackTune site' 'Package store' 'succeeded' @() $null $t0.AddMinutes(40))
    (New-FakeJob 'custom' 'Exporting Keevault 0.9.34 from the package store' 'Export Keevault' 'succeeded' @() $null $t0.AddMinutes(41))
)
$count = 0; foreach ($j in $jobs) { if (Add-PackTuneProtocolFromJob -Protocol $p -Job $j -Cause $(if ($j.Status -eq 'failed') { 'Windows denied access (see Details).' })) { $count++ } }
Test-Check 'every job of the list is one action' ($count -eq 13 -and $p.Actions.Count -eq 13)
foreach ($kind in 'meta', 'icons', 'search', 'tenant', 'storecheck', 'assignread', 'customlist', 'connect', 'popular') {
    Test-Check "job kind '$kind' (a read or a check) is not recorded" ($null -eq (Add-PackTuneProtocolFromJob -Protocol $p -Job (New-FakeJob $kind "x $kind" 'x' 'succeeded')))
}
Test-Check 'reads and checks left the journal alone' ($p.Actions.Count -eq 13)
$cat = @($p.Actions | ForEach-Object Category)
Test-Check 'groups: deploy, assignment, policy, removal (also a custom removal), test, custom, import, repo, export, setup' ((@($cat | Where-Object { $_ -eq 'removal' }).Count -eq 2) -and ('export' -in $cat) -and ('setup' -in $cat) -and ('repo' -in $cat) -and ('import' -in $cat) -and ((@($cat | Where-Object { $_ -eq 'custom' }).Count -eq 1)))
Test-Check 'a failed job carries the short cause' ((@($p.Actions | Where-Object { $_.Subject -eq 'git' })[0].Result -eq 'failed') -and (@($p.Actions | Where-Object { $_.Subject -eq 'git' })[0].Note -like 'winget - Windows denied access*'))
$tests = @($p.Actions | Where-Object { $_.Category -eq 'test' })
Test-Check 'sandbox tests carry the verdict (passed / failed with the message)' (($tests[0].Result -eq 'passed') -and ($tests[1].Result -eq 'testfailed') -and ($tests[1].Note -like 'Detection rule*'))
Test-Check 'update settings keep their detail, deployments the source' ((@($p.Actions | Where-Object Category -eq 'policy')[0].Note -eq 'updates user prompt, version 24.08') -and (@($p.Actions | Where-Object Subject -eq '7zip' | Where-Object Category -eq 'deploy')[0].Note -eq 'Chocolatey'))
Test-Check 'the end follows the last action' (([datetime]$p.Ended) -eq $t0.AddMinutes(41))
$skip = Add-PackTuneProtocolFromJob -Protocol $p -Job (New-FakeJob 'deploy' 'Deploying z' 'z' 'skipped' @() $null $t0.AddMinutes(41))
Test-Check 'a skipped job is recorded as skipped' ($skip.Result -eq 'skipped')

# --- text: English default, German, Markdown
$en = ConvertTo-PackTuneProtocolText -Protocol $p -Language en -Format Text
Test-Check 'English: header with date, time span, duration, administrator, tenant, number of actions' (($en -match 'Date: 2026-11-14') -and ($en -match 'Time: 09:00 - 09:41') -and ($en -match 'Duration: 41 min') -and ($en -match 'Administrator: Ada Admin \(ada@contoso.com\)') -and ($en -match 'Tenant: contoso.onmicrosoft.com') -and ($en -match 'Actions: 14'))
Test-Check 'English: groups with time, subject, result' (($en -match 'Deployments:') -and ($en -match '09:04  7zip: done \(Chocolatey\)') -and ($en -match '09:06  git: failed \(winget - Windows denied access') -and ($en -match 'Sandbox tests:') -and ($en -match 'Sandbox: 7zip: passed') -and ($en -match 'Sandbox: Foo: failed \(Detection rule'))
$de = ConvertTo-PackTuneProtocolText -Protocol $p -Language de -Format Text
$ue = [string][char]0xFC
Test-Check 'German: labels, date format, results' (($de -match 'Datum: 14\.11\.2026') -and ($de -match 'Dauer: 41 Min') -and ($de -match 'Mandant: contoso') -and ($de -match 'Bereitstellungen:') -and ($de -match '09:04  7zip: erledigt') -and ($de -match 'nicht bestanden') -and ($de -match "Entfernungen:") -and ($de -match "${ue}bersprungen"))
Test-Check 'the group order is fixed (deployments before removals before sandbox tests)' (($en.IndexOf('Deployments:') -lt $en.IndexOf('Removals:')) -and ($en.IndexOf('Removals:') -lt $en.IndexOf('Sandbox tests:')))
$md = ConvertTo-PackTuneProtocolText -Protocol $p -Language en -Format Markdown
Test-Check 'Markdown: heading, bold labels, group headings, bullet lines' (($md -match '(?m)^# PackTune session protocol') -and ($md -match '\*\*Administrator:\*\*') -and ($md -match '(?m)^## Deployments') -and ($md -match '(?m)^- 09:04  7zip: done'))
$empty = New-PackTuneProtocol -Started $t0
$emptyText = ConvertTo-PackTuneProtocolText -Protocol $empty -Language en
Test-Check 'an empty protocol says so, admin and tenant "not signed in"' (($emptyText -match 'No actions in this session') -and ($emptyText -match 'Administrator: not signed in'))
Set-PackTuneProtocolIdentity -Protocol $empty -Admin 'Bob' -Account 'bob@contoso.com' -Tenant 'contoso.com'
Set-PackTuneProtocolIdentity -Protocol $empty -Admin 'Other' -Account 'o@x.com' -Tenant 'x.com'
Test-Check 'the identity is filled once (first sign-in) and not overwritten' ($empty.Admin -eq 'Bob' -and $empty.Tenant -eq 'contoso.com')
Test-Check 'a running protocol measures until now' ((ConvertTo-PackTuneProtocolText -Protocol $empty -End $t0.AddHours(2).AddMinutes(5)) -match 'Duration: 2 h 5 min')

# --- no secrets
$leak = Add-PackTuneProtocolAction -Protocol $p -Category setup -Subject 'Sign-in eyJhbGciOiJSUzI1NiIsInR5cCI6.eyJhdWQiOiJodHRwczovL2dyYXBo.c2lnbmF0dXJlMTIzNDU2' -Result failed -Note 'password=Hunter2! client_secret: abc123 Bearer AbCdEf0123456789xyz https://x/y?sig=SECRETSIG&a=1 app 6f0f2a3c-1111-2222-3333-444455556666 key QWxhZGRpbjpvcGVuIHNlc2FtZSBBbGFkZGluOm9wZW4gc2VzYW1l'
$leakText = $leak.Subject + ' ' + $leak.Note
Test-Check 'tokens, passwords, secrets, bearer values, SAS signatures, long keys and ids are cleaned out of every text' (($leakText -notmatch 'eyJ') -and ($leakText -notmatch 'Hunter2') -and ($leakText -notmatch 'abc123') -and ($leakText -notmatch 'AbCdEf0123') -and ($leakText -notmatch 'SECRETSIG') -and ($leakText -notmatch '6f0f2a3c') -and ($leakText -notmatch 'QWxhZGRpbjpvcGVu')) $leakText
Test-Check 'texts are short (200 characters at most)' ((Remove-PackTuneProtocolSecrets ('a b ' * 200)).Length -le 200)
[void]$p.Actions.RemoveAt($p.Actions.Count - 1)

# --- auto-save, atomic, recovery
$folder = Join-Path $work 'Protocols'
$json = Save-PackTuneProtocol -Protocol $p -Folder $folder
$base = [IO.Path]::GetFileNameWithoutExtension($json)
Test-Check 'saved as <date-time>-<user>.json and .md' (($base -eq ('2026-11-14-090000-' + (($env:USERNAME -replace '[^A-Za-z0-9._-]', '-').Trim('-.')))) -and (Test-Path (Join-Path $folder "$base.md")))
Test-Check 'no temporary file is left behind' (@(Get-ChildItem $folder -Filter '*.tmp').Count -eq 0)
$default = Get-PackTuneProtocolFolder
Test-Check 'the default folder is %LOCALAPPDATA%\PackTune\Protocols' ($default -eq (Join-Path $work 'PackTune\Protocols'))
$p2 = New-PackTuneProtocol -Admin 'Ada Admin' -Account 'ada@contoso.com' -Tenant 'contoso.onmicrosoft.com' -Started $t0.AddDays(1)
[void](Add-PackTuneProtocolAction -Protocol $p2 -Category deploy -Subject 'First' -At $t0.AddDays(1).AddMinutes(3))
$null = Save-PackTuneProtocol -Protocol $p2 -Folder $folder
[void](Add-PackTuneProtocolAction -Protocol $p2 -Category deploy -Subject 'Second' -At $t0.AddDays(1).AddMinutes(7))
$null = Save-PackTuneProtocol -Protocol $p2 -Folder $folder
# the window crashes here: the file holds both actions, the end is the last action
$usr = (($env:USERNAME -replace '[^A-Za-z0-9._-]', '-').Trim('-.'))
$recovered = Read-PackTuneProtocolJson -Text ([IO.File]::ReadAllText((Join-Path $folder "2026-11-15-090000-$usr.json")))
Test-Check 'recovery: after a crash the file holds every recorded action and the end of the last one' ($recovered -and @($recovered.Actions).Count -eq 2 -and ([datetime]$recovered.Ended) -eq $t0.AddDays(1).AddMinutes(7) -and $recovered.Admin -eq 'Ada Admin')
Test-Check 'recovered protocols render like live ones' ((ConvertTo-PackTuneProtocolText -Protocol $recovered -Language en) -match 'Second: done')
Test-Check 'a half-written or foreign file is not a protocol' (($null -eq (Read-PackTuneProtocolJson -Text '{"Format":"PackTune.Protocol","Id":')) -and ($null -eq (Read-PackTuneProtocolJson -Text '{"a":1}')) -and ($null -eq (Read-PackTuneProtocolJson -Text 'nonsense')))
Set-Content -Path (Join-Path $folder 'broken.json') -Value '{"Format":"PackTune.Protocol","Id":'
# a stored file written by someone else with a secret inside is cleaned when read
$evil = Read-PackTuneProtocolJson -Text '{"Format":"PackTune.Protocol","Id":"2026-01-01-000000","Started":"2026-01-01T00:00:00","Actions":[{"At":"2026-01-01T00:01:00","Category":"deploy","Subject":"x password=abc","Result":"ok","Note":""},{"At":"2026-01-01T00:01:00","Category":"nonsense","Subject":"y","Result":"ok"}]}'
Test-Check 'reading: unknown groups are dropped and texts are cleaned again' ((@($evil.Actions).Count -eq 1) -and ($evil.Actions[0].Subject -notmatch 'abc'))

# --- history: local + store, other administrators, de-duplicated
$null = Get-PackTuneProtocolHistory -Folder $folder
$h = @(Get-PackTuneProtocolHistory -Folder $folder)
Test-Check 'history (local only): newest first, date, admin, duration, number of actions' (($h.Count -eq 2) -and ($h[0].Id -eq '2026-11-15-090000') -and ($h[0].Count -eq 2) -and ($h[0].Admin -eq 'Ada Admin') -and ($h[0].Duration.TotalMinutes -eq 7) -and ($h[1].Count -eq 13 -or $h[1].Count -eq 14) -and ($h[0].Where -eq 'Local'))
$s0 = Get-PackTuneSettings; $s0.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Save-PackTuneSettings -Settings $s0 | Out-Null; $script:Settings = Get-PackTuneSettings
$null = Initialize-PackTuneStore
$store = Resolve-PackTuneStore

Send-PackTuneProtocolToStore -Protocol $p -Store $store
$keys = @($script:Fs.Keys | Sort-Object)
Test-Check 'store upload: json and md in the folder Protocols of the library' (($keys -contains "Protocols/2026-11-14-090000-$usr.json") -and ($keys -contains "Protocols/2026-11-14-090000-$usr.md"))
$stored = Read-PackTuneProtocolJson -Text ([Text.Encoding]::UTF8.GetString($script:Fs["Protocols/2026-11-14-090000-$usr.json"]))
Test-Check 'store upload: the stored json is the protocol' ($stored -and @($stored.Actions).Count -eq $p.Actions.Count)
Send-PackTuneProtocolToStore -Protocol $p -Store $store
Test-Check 'uploading again replaces the file (no duplicates)' (@($script:Fs.Keys | Where-Object { $_ -like 'Protocols/*.json' }).Count -eq 1)
# another administrator's protocol, only in the store
$pb = New-PackTuneProtocol -Admin 'Bob Builder' -Account 'bob@contoso.com' -Tenant 'contoso.onmicrosoft.com' -Started $t0.AddDays(2)
[void](Add-PackTuneProtocolAction -Protocol $pb -Category removal -Subject 'Thing' -At $t0.AddDays(2).AddMinutes(30))
Send-PackTuneProtocolToStore -Protocol $pb -Store $store -Language de
$h = @(Get-PackTuneProtocolHistory -Folder $folder -Store $store)
Test-Check 'history: local + store, the same protocol once (Both), the other administrator read-only (Store)' (($h.Count -eq 3) -and ($h[0].Admin -eq 'Bob Builder') -and ($h[0].Where -eq 'Store') -and (@($h | Where-Object Where -eq 'Both').Count -eq 1) -and (@($h | Where-Object Where -eq 'Local').Count -eq 1))
Test-Check 'history rows hold the protocol for viewing and copying' ((ConvertTo-PackTuneProtocolText -Protocol $h[0].Protocol -Language de) -match 'Thing: erledigt')
Test-Check 'the folder Protocols is not an app of the package store' (@(Get-PackTuneStoreApps -Store $store) -notcontains 'Protocols')
$script:SiteReachable = $true
$warn = $null; $script:Fs['Protocols/bad.json'] = [Text.Encoding]::UTF8.GetBytes('{"Format":')
$h = @(Get-PackTuneProtocolHistory -Folder $folder -Store $store -Warnings ([ref]$warn))
Test-Check 'history: a damaged store file is skipped, the rest is shown' ($h.Count -eq 3)
$fakeGraph = ${function:Invoke-PackTuneStoreGraph}; function Invoke-PackTuneStoreGraph { throw 'SharePoint GET failed (403): Access denied' }

$warn = $null; $h = @(Get-PackTuneProtocolHistory -Folder $folder -Store $store -Warnings ([ref]$warn))
Test-Check 'history: the store cannot be read -> only the local protocols and a note, no error' (($h.Count -eq 2) -and ($warn.Count -eq 1))
${function:Invoke-PackTuneStoreGraph} = $fakeGraph
$script:SiteReachable = $true

# --- settings: language preference
$s = Get-PackTuneSettings
Test-Check 'language preference: English by default' ($s.ProtocolLanguage -eq 'en')
$s.ProtocolLanguage = 'de'; Save-PackTuneSettings -Settings $s | Out-Null
Test-Check 'language preference: German is stored' ((Get-PackTuneSettings).ProtocolLanguage -eq 'de')
$s.ProtocolLanguage = 'fr'; Save-PackTuneSettings -Settings $s | Out-Null
Test-Check 'language preference: anything else falls back to English' ((Get-PackTuneSettings).ProtocolLanguage -eq 'en')

# --- settings: saving works while another reader holds the file for a moment (the race behind the flaky smoke step)
$ready = Join-Path $work 'lock-ready.txt'
$holder = Start-Job -ArgumentList $script:SettingsPath, $ready -ScriptBlock { param($Path, $Ready) $f = [IO.File]::Open($Path, 'Open', 'Read', 'Read'); 'x' | Set-Content $Ready; Start-Sleep -Milliseconds 400; $f.Dispose() }
for ($i = 0; $i -lt 100 -and -not (Test-Path $ready); $i++) { Start-Sleep -Milliseconds 50 }
$s = Get-PackTuneSettings; $s.ProtocolLanguage = 'de'
$threw = $false; try { Save-PackTuneSettings -Settings $s | Out-Null } catch { $threw = $true }
Wait-Job $holder | Out-Null; Remove-Job $holder -Force
Test-Check 'settings: a short lock by another reader does not lose the change, no half-written file' ((-not $threw) -and ((Get-PackTuneSettings).ProtocolLanguage -eq 'de') -and (@(Get-ChildItem (Split-Path $script:SettingsPath) -Filter 'settings.json.*.tmp').Count -eq 0))

if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 } else { 'All checks passed.' }
