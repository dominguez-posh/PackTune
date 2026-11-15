<#
.SYNOPSIS
    Checks of the sandbox test gate for catalog apps (PackTune-TestGate.ps1): the result per source + package + version + architecture,
    the state a newer version has, the backend refusal without a passed test (deploy, winget deploy, release), the override with a reason
    (the app notes carry testOverride=<state>;<date>;<admin>), the passed path without any override, the package store copy and its
    sync. Fake IntuneWin32App module and fake feed data, no network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-TestGate.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSources-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PSModulePath = (Join-Path $PSScriptRoot 'Fakes') + ';' + $env:PSModulePath

$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) {
    if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" }
}

. (Join-Path $repo 'PackTune-Main.ps1')
Import-Module IntuneWin32App -Force

# Signed in (fake token), stand-ins for everything that would reach the network
$Global:AccessToken = [pscustomobject]@{ ExpiresOn = (Get-Date).AddHours(2).ToUniversalTime(); access_token = 'x.e30.y' }
$Global:AuthenticationHeader = @{ Authorization = 'Bearer x'; ExpiresOn = $Global:AccessToken.ExpiresOn }
$Global:AccessTokenTenantID = 'contoso.onmicrosoft.com'
$script:Png = 'iVBORw0KGgo='
$script:ChocoFeed = @{ googlechrome = '120.0.1'; firefox = '130.0'; '7zip' = '24.09'; notepadplusplus = '8.7.1'; vlc = '3.0.20'; 'only.choco' = '1.0' }
$script:WingetFeed = @{ 'Google.Chrome' = '121.0.5'; 'Mozilla.Firefox' = '130.0.0'; '7zip.7zip' = '25.01'; 'Notepad++.Notepad++' = '8.7'; 'VideoLAN.VLC' = ''; 'Other.WingetOnly' = '2.0' }
$script:ChocoVersions = @{ vlc = @('3.0.18', '3.0.19', '3.0.20'); '7zip' = @('24.08', '24.09'); 'only.choco' = @('0.9', '1.0') }
$script:FeedCalls = 0
function Assert-WingetClient { }
function Get-ChocoInfo { param([string]$ChocoName)
    $script:FeedCalls++
    if (-not $script:ChocoFeed.ContainsKey($ChocoName.ToLower())) { throw "Chocolatey package '$ChocoName' was not found on the feed" }
    [pscustomobject]@{ Name = $ChocoName.ToLower(); Title = "Title $ChocoName"; Version = $script:ChocoFeed[$ChocoName.ToLower()]; Summary = 's'; Description = "Description of $ChocoName"; Authors = 'Author'; SoftwareSite = 'https://example.org'; SoftwareLicense = $null; IconUrl = $null; Downloads = 1; IsLatest = $true; LicenseNote = $null }
}
function Get-WingetInfo { param([string]$WingetId)
    $script:FeedCalls++
    if (-not $script:WingetFeed.ContainsKey($WingetId)) { throw "winget package '$WingetId' was not found in the winget source" }
    [pscustomobject]@{ Name = $WingetId; Title = "Title $WingetId"; Version = $script:WingetFeed[$WingetId]; Summary = 's'; Description = "Description of $WingetId"; Authors = 'Publisher'; SoftwareSite = 'https://example.org'; SoftwareLicense = $null; License = $null; IconUrl = $null; Downloads = $null; IsLatest = $true; LicenseNote = $null; Source = 'Winget' }
}
function Search-ChocoPackage { param([string]$SearchPattern, [int]$Top)
    foreach ($Id in 'googlechrome', 'only.choco') { [pscustomobject]@{ Name = $Id; Title = "Title $Id"; Version = $script:ChocoFeed[$Id]; Authors = $null; Tags = ''; IconUrl = $null; Downloads = $(if ($Id -eq 'only.choco') { 5000 } else { 1000 }) } }
}
function Search-WingetPackage { param([string]$SearchPattern, [int]$Top)
    foreach ($Id in 'Google.Chrome', 'Other.WingetOnly', 'Mozilla.Firefox') { [pscustomobject]@{ Name = $Id; Title = "Title $Id"; Version = $script:WingetFeed[$Id]; Authors = $null; Source = 'Winget' } }
}
function Get-ChocoPackageVersions { param([string]$ChocoName) @($script:ChocoVersions[$ChocoName.ToLower()]) }
function Get-WingetPackageVersions { param([string]$WingetId) @('2.0', '1.0') }
function Get-Store { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }

# the package store (fake SharePoint) for the copy of the results
. (Join-Path $PSScriptRoot 'Fakes\FakeSharePoint.ps1')
$settings = Get-PackTuneSettings; $settings.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Save-PackTuneSettings -Settings $settings | Out-Null; $script:Settings = Get-PackTuneSettings
$null = Initialize-PackTuneStore

# --- results: per source, package, version and architecture
Test-Check 'state: nothing recorded is Not tested' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version '1.0') -eq 'Not tested')
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package 'only.choco' -Version '1.0' -Verdict Failed -Cause 'Failed at step 2 of 5: Install exited with 1603'
Test-Check 'state: a failed result is Failed, with its cause, for exactly this version' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version '1.0') -eq 'Failed' -and (Get-PackTuneCatalogTest -Source Chocolatey -Package 'only.choco' -Version '1.0').cause -like '*step 2 of 5*')
Test-Check 'state: a newer version is Not tested again' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version '1.1') -eq 'Not tested')
Test-Check 'state: another source or another architecture does not share the result' ((Get-PackTuneCatalogTestState -Source Winget -Package 'only.choco' -Version '1.0') -eq 'Not tested' -and (Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version '1.0' -Architecture 'arm64') -eq 'Not tested')
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package 'only.choco' -Version '1.0' -Verdict Passed
Test-Check 'state: a later passed test replaces the failed one' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version '1.0') -eq 'Passed')
Test-Check 'state: "latest" has no version to be tested for' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version 'latest') -eq 'Not tested')
Remove-Item (Get-PackTuneCatalogTestFile) -Force
Test-Check 'results: a missing file reads as Not tested (blocks, never passes)' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package 'only.choco' -Version '1.0') -eq 'Not tested')

# --- the package store keeps a copy; a fresh start reads it back
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package '7zip' -Version '24.08' -Verdict Passed
$inStore = @($script:Fs.Keys | Where-Object { $_ -like 'SandboxTests/*.json' })
Test-Check 'store: the result is kept in the folder "SandboxTests" of the library' ($inStore.Count -ge 1 -and $inStore.Count -le 2) ($script:Fs.Keys -join ',')
Remove-Item (Get-PackTuneCatalogTestFile) -Force
$taken = Sync-PackTuneCatalogTests
Test-Check 'store: the sync brings the result back after the local file is gone' ($taken -ge 1 -and (Get-PackTuneCatalogTestState -Source Chocolatey -Package '7zip' -Version '24.08') -eq 'Passed') "taken $taken"
Test-Check 'store: a second sync takes nothing that is not newer' ((Sync-PackTuneCatalogTests) -eq 0)

# --- the backend gate: deploy
function Get-StoreApps { $f = Join-Path $env:LOCALAPPDATA 'fake-intune.json'; if (Test-Path $f) { @(Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ }) } else { @() } }
function Invoke-Deploy([scriptblock]$Do) { $script:Msg = ''; $script:Id = $null; try { $script:Id = & $Do 3>$null } catch { $script:Msg = $_.Exception.Message } }
Remove-Item (Get-PackTuneCatalogTestFile) -Force -ErrorAction SilentlyContinue
function Get-Own([string]$Package) { @(Get-StoreApps | Where-Object { $_.notes -like "*package=$Package;*" }).Count }
$before = Get-Own 'only.choco'
Invoke-Deploy { New-PackTuneChocolateyApp -ChocoName 'only.choco' -IconBase64 $script:Png -Version '1.0' -Assignment None -ErrorAction Stop }
Test-Check 'deploy (Chocolatey) without a test is refused by the backend, nothing created' (($script:Msg -like '*not tested in the sandbox*') -and ((Get-Own 'only.choco') -eq $before)) $script:Msg
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package 'only.choco' -Version '1.0' -Verdict Failed -Cause 'Failed at step 3 of 5: not detected after the install'
Invoke-Deploy { New-PackTuneChocolateyApp -ChocoName 'only.choco' -IconBase64 $script:Png -Version '1.0' -Assignment None -ErrorAction Stop }
Test-Check 'deploy (Chocolatey) after a failed test is refused and says why' (($script:Msg -like '*sandbox test failed*not detected after the install*') -and ((Get-Own 'only.choco') -eq $before)) $script:Msg
Invoke-Deploy { New-PackTuneChocolateyApp -ChocoName 'only.choco' -IconBase64 $script:Png -Version '1.0' -Assignment None -SkipTestReason '   ' -ErrorAction Stop }
Test-Check 'deploy: a blank reason is no reason' ($script:Msg -like '*sandbox test*' -and (Get-Own 'only.choco') -eq $before) $script:Msg
$warned = New-Object System.Collections.ArrayList
$id = New-PackTuneChocolateyApp -ChocoName 'only.choco' -IconBase64 $script:Png -Version '1.0' -Assignment None -SkipTestReason 'vendor confirmed, pilot group only' -ErrorAction Stop -WarningVariable +warned 3>$null
$app = Get-StoreApps | Where-Object id -eq $id
Test-Check 'override: deployed with the reason, the app notes carry testOverride=<state>;<date>;<admin>' ($id -and $app.notes -match ';testOverride=failed;\d{8};[A-Za-z0-9@._-]+$' -and (ConvertFrom-PackTuneAppNotes $app.notes).Package -eq 'only.choco' -and (ConvertFrom-PackTuneAppNotes $app.notes).Version -eq '1.0') $app.notes
Test-Check 'override: the log line names the app, the state, the reason and the admin' (($warned -join ' ') -match 'deployed without passed sandbox test: only\.choco 1\.0 \(Failed\), reason: vendor confirmed, pilot group only, admin: ') ($warned -join ' | ')
Remove-PackTuneApp -Id $id
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package 'only.choco' -Version '1.0' -Verdict Passed
$id = New-PackTuneChocolateyApp -ChocoName 'only.choco' -IconBase64 $script:Png -Version '1.0' -Assignment None -ErrorAction Stop
$app = Get-StoreApps | Where-Object id -eq $id
Test-Check 'passed test: deployed without any reason, no override in the notes' ($id -and $app.notes -notmatch 'testOverride') $app.notes

# --- winget
Invoke-Deploy { New-PackTuneWingetApp -WingetId 'Google.Chrome' -IconBase64 $script:Png -Version '1.0' -Assignment None -ErrorAction Stop }
Test-Check 'deploy (winget) without a test is refused by the backend' ($script:Msg -like '*not tested in the sandbox*') $script:Msg
$wid = New-PackTuneWingetApp -WingetId 'Google.Chrome' -IconBase64 $script:Png -Version '1.0' -Assignment None -SkipTestReason 'no sandbox on this build machine' -ErrorAction Stop 3>$null
Test-Check 'override (winget): deployed, notes carry the override' ($wid -and ((Get-StoreApps | Where-Object id -eq $wid).notes -match ';testOverride=nottested;\d{8};')) ((Get-StoreApps | Where-Object id -eq $wid).notes)

# --- release (new version of an app)
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package '7zip' -Version '24.08' -Verdict Passed
$zid = New-PackTuneChocolateyApp -ChocoName '7zip' -IconBase64 $script:Png -Version '24.08' -Assignment Available -ErrorAction Stop
$count = @(Get-StoreApps).Count
Invoke-Deploy { Publish-PackTuneRelease -AppId $zid -Version '24.09' }
Test-Check 'release of a version without a passed test is refused, no new app' (($script:Msg -like '*not tested in the sandbox*') -and @(Get-StoreApps).Count -eq $count) $script:Msg
Invoke-Deploy { Publish-PackTuneRelease -AppId $zid -UpdateMode Custom -GraceHours 12 }
Test-Check 'a changed update policy alone needs no test' (-not $script:Msg) $script:Msg
$res = Publish-PackTuneRelease -AppId $zid -Version '24.09' -SkipTestReason 'security fix, tested by the vendor' 3>$null
$new = Get-StoreApps | Where-Object id -eq $res.AppId
Test-Check 'release with a reason: the new app carries the override in its notes' ($new -and $new.notes -match ';testOverride=nottested;\d{8};') $new.notes
$null = Save-PackTuneCatalogTest -Source Chocolatey -Package '7zip' -Version '24.09' -Verdict Passed
Test-Check 'state: the released version is tested separately' ((Get-PackTuneCatalogTestState -Source Chocolatey -Package '7zip' -Version '24.09') -eq 'Passed')

# --- the command line parameter exists on every deploy path
foreach ($f in 'New-PackTuneChocolateyApp', 'New-PackTuneWingetApp', 'Update-PackTuneApp', 'Publish-PackTuneRelease', 'Publish-PackTuneSupersedingApp') {
    Test-Check "$f has -SkipTestReason" ((Get-Command $f).Parameters.ContainsKey('SkipTestReason'))
}
Test-Check 'override note: only plain characters, no blanks (readable back from the notes)' ((ConvertTo-PackTuneTestOverrideNote -State 'Not tested' -Admin 'a b;c@x.test') -match '^testOverride=nottested;\d{8};abc@x\.test$')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 } else { 'All checks passed.' }
