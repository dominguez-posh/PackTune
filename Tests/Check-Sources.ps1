<#
.SYNOPSIS
    Non-GUI checks of the source functions (PackTune-Sources.ps1, PackTune-Release.ps1):
    recommended source, filter, merged search, deploy per source, winget runtime dependency, release through
    supersedence versus in-place update. Fake IntuneWin32App module and fake feed data, no network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Sources.ps1
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
function Get-StoreApp([string]$Package) { @(Get-Store | Where-Object { $_.notes -like "*package=$Package;*" }) }

# --- recommended source: numeric, part by part
$cases = @(
    @('1.10', '1.9', 1), @('1.9', '1.10', -1), @('1.2', '1.2.0', 0), @('26.05', '25.01', 1), @('v2.0-beta', '2.0', 0), @('1.0', '', $null), @('abc', '1.0', $null), @('', '', $null)
)
foreach ($c in $cases) { $r = Compare-SourceVersion $c[0] $c[1]; Test-Check "compare '$($c[0])' '$($c[1])' = $($c[2])" ($r -eq $c[2] -and ($null -eq $r) -eq ($null -eq $c[2])) "got $r" }
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '120.0.1' -WingetVersion '121.0.5'
Test-Check 'higher winget version is recommended and marked' ($r.Source -eq 'Winget' -and $r.Marked)
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '130.0' -WingetVersion '129.9'
Test-Check 'higher Chocolatey version is recommended and marked' ($r.Source -eq 'Chocolatey' -and $r.Marked)
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '130.0' -WingetVersion '130.0.0'
Test-Check 'equal versions: no recommendation' ($null -eq $r.Source -and -not $r.Marked)
$r = Get-RecommendedSource -HasChocolatey $true -HasWinget $true -ChocolateyVersion '130.0' -WingetVersion ''
Test-Check 'unknown version: no recommendation' ($null -eq $r.Source)
$r = Get-RecommendedSource -HasChocolatey $false -HasWinget $true -WingetVersion '1.0'
Test-Check 'one source only: that source, not marked' ($r.Source -eq 'Winget' -and -not $r.Marked)

# --- catalog: ids of both sources
$catalog = @(Get-PackTuneCatalog)
$bad = @($catalog | Where-Object { $_.WingetId -and $_.WingetId -notmatch $script:WingetIdPattern })
Test-Check 'catalog winget ids are valid ids' ($bad.Count -eq 0) ($bad.WingetId -join ', ')
Test-Check 'catalog: Brackets has its winget id' (@($catalog | Where-Object { $_.Id -eq 'brackets' -and $_.WingetId -eq 'Adobe.Brackets' }).Count -eq 1)
$dup = @($catalog | Where-Object WingetId | Group-Object { $_.WingetId.ToLower() } | Where-Object Count -gt 1)
Test-Check 'catalog: no winget id twice' ($dup.Count -eq 0) ($dup.Name -join ', ')

# --- rows from the catalog with a cache (no feed call for what the cache has)
$cache = @{
    'googlechrome' = [pscustomobject]@{ Found = $true; Version = '120.0.1'; Title = 'Chrome' }
    'winget:google.chrome' = [pscustomobject]@{ Found = $true; Version = '121.0.5'; Title = 'Chrome' }
    'firefox' = [pscustomobject]@{ Found = $true; Version = '130.0' }
    'winget:mozilla.firefox' = [pscustomobject]@{ Found = $true; Version = '130.0.0' }
    'filezilla' = [pscustomobject]@{ Found = $true; Version = '3.0' }
}
$script:FeedCalls = 0
$rows = @(Get-PackTuneSourceApps -Cache $cache -NoFetch)
Test-Check 'one row per catalog entry, no feed call with -NoFetch' ($rows.Count -eq $catalog.Count -and $script:FeedCalls -eq 0) "rows $($rows.Count), calls $script:FeedCalls"
$chrome = $rows | Where-Object CatalogId -eq 'googlechrome'
Test-Check 'Chrome row: both sources, winget recommended' (($chrome.Sources -join ',') -eq 'Chocolatey,Winget' -and $chrome.Recommended -eq 'Winget' -and $chrome.RecommendedMarked -and $chrome.Source -eq 'Winget')
$firefox = $rows | Where-Object CatalogId -eq 'firefox'
Test-Check 'Firefox row: equal versions, default is the preferred source of the settings' ($null -eq $firefox.Recommended -and $firefox.Source -eq $script:Settings.Source)
$filezilla = $rows | Where-Object CatalogId -eq 'filezilla'
Test-Check 'FileZilla row: Chocolatey only, source set, not marked' (($filezilla.Sources -join ',') -eq 'Chocolatey' -and $filezilla.Recommended -eq 'Chocolatey' -and -not $filezilla.RecommendedMarked)
$both = @(Select-PackTuneSourceApps -Apps $rows -Filter Both)
$chocoOnly = @(Select-PackTuneSourceApps -Apps $rows -Filter Chocolatey)
$wingetOnly = @(Select-PackTuneSourceApps -Apps $rows -Filter Winget)
Test-Check 'filter: All = Both + Chocolatey only + winget only' ((@(Select-PackTuneSourceApps -Apps $rows -Filter All).Count) -eq ($both.Count + $chocoOnly.Count + $wingetOnly.Count))
Test-Check 'filter: Both has the apps with two ids' ($both.Count -eq @($catalog | Where-Object WingetId).Count -and $chocoOnly.Count -eq @($catalog | Where-Object { -not $_.WingetId }).Count -and $wingetOnly.Count -eq 0) "$($both.Count)/$($chocoOnly.Count)/$($wingetOnly.Count)"
Test-Check 'filter: Chocolatey only does not contain Chrome' ($chocoOnly.CatalogId -notcontains 'googlechrome' -and $chocoOnly.CatalogId -contains 'filezilla')
# a package the source does not know is no source of the app
$cache2 = @{ 'winget:google.chrome' = [pscustomobject]@{ Found = $false; NotFound = $true }; 'googlechrome' = [pscustomobject]@{ Found = $true; Version = '120.0' } }
$chrome2 = Get-PackTuneSourceApps -Cache $cache2 -NoFetch | Where-Object CatalogId -eq 'googlechrome'
Test-Check 'winget says not found: Chrome is Chocolatey only' (($chrome2.Sources -join ',') -eq 'Chocolatey' -and $null -eq $chrome2.WingetId)
# without a cache the feeds are asked and the answer is cached
$cache3 = @{}; $script:FeedCalls = 0
$null = Resolve-PackTuneSourceInfo -Source Winget -Id '7zip.7zip' -Cache $cache3
$null = Resolve-PackTuneSourceInfo -Source Winget -Id '7zip.7zip' -Cache $cache3
Test-Check 'feed read once, then from the cache' ($script:FeedCalls -eq 1 -and $cache3['winget:7zip.7zip'].Version -eq '25.01')

# --- merged search
$script:FeedCalls = 0
$found = @(Search-PackTuneApps -SearchPattern 'chrome' -Cache @{})
$names = $found | ForEach-Object { if ($_.CatalogId) { $_.CatalogId } elseif ($_.ChocoId) { $_.ChocoId } else { $_.WingetId } }
Test-Check 'search: Chrome of both sources is one row' (@($found | Where-Object CatalogId -eq 'googlechrome').Count -eq 1 -and $found.Count -eq 4) ($names -join ', ')
$c = $found | Where-Object CatalogId -eq 'googlechrome'
Test-Check 'search: merged row has both ids and versions' ($c.ChocoId -eq 'googlechrome' -and $c.WingetId -eq 'Google.Chrome' -and $c.ChocoVersion -eq '120.0.1' -and $c.WingetVersion -eq '121.0.5' -and $c.Recommended -eq 'Winget')
$ff = $found | Where-Object CatalogId -eq 'firefox'
Test-Check 'search: catalog app found by one source gets the other source from the feed' ($ff.ChocoId -eq 'firefox' -and $ff.ChocoVersion -eq '130.0' -and $ff.WingetVersion -eq '130.0.0' -and $null -eq $ff.Recommended)
$oc = $found | Where-Object ChocoId -eq 'only.choco'
$ow = $found | Where-Object WingetId -eq 'Other.WingetOnly'
Test-Check 'search: unknown packages stay separate rows of their source' ($oc -and -not $oc.WingetId -and $ow -and -not $ow.ChocoId -and $oc.Sources -eq 'Chocolatey' -and $ow.Sources -eq 'Winget')
$only = @(Search-PackTuneApps -SearchPattern 'chrome' -Cache @{} -Filter Both)
Test-Check 'search: filter Both' ($only.Count -eq 2)
function Search-WingetPackage { throw 'offline' }
$warn = @(); $partial = @(Search-PackTuneApps -SearchPattern 'chrome' -Cache @{} -NoFetch -WarningVariable warn -WarningAction SilentlyContinue)
Test-Check 'search: one source down, the other still answers with a warning' ($partial.Count -ge 2 -and $warn.Count -eq 1)

# --- deploy per source
$ids = @{ Assignment = 'Available'; IconBase64 = $script:Png }
$chromeRow = New-PackTuneSourceRow -Name 'Google Chrome' -CatalogId 'googlechrome' -ChocoId 'googlechrome' -WingetId 'Google.Chrome' -ChocoVersion '120.0.1' -WingetVersion '121.0.5'
$firefoxRow = New-PackTuneSourceRow -Name 'Mozilla Firefox' -CatalogId 'firefox' -ChocoId 'firefox' -WingetId 'Mozilla.Firefox' -ChocoVersion '131.0' -WingetVersion '130.0'
$vlcRow = New-PackTuneSourceRow -Name 'VLC' -CatalogId 'vlc' -ChocoId 'vlc' -WingetId 'VideoLAN.VLC' -ChocoVersion '3.0.20' -WingetVersion '3.0.20'
$id1 = New-PackTuneSourceApplication -App $chromeRow -Parameters $ids
$id2 = New-PackTuneSourceApplication -App $firefoxRow -Parameters $ids
$a1 = Get-Store | Where-Object id -eq $id1; $a2 = Get-Store | Where-Object id -eq $id2
Test-Check 'deploy: recommended source winget -> winget app' ($a1 -and $a1.notes -like 'PoweredByPackTune;from=Winget;package=Google.Chrome;*')
Test-Check 'deploy: recommended source Chocolatey -> Chocolatey app' ($a2 -and $a2.notes -like 'PoweredByPackTune;from=Chocolatey;package=firefox;*')
$id3 = New-PackTuneSourceApplication -App $vlcRow -Parameters $ids
$a3 = Get-Store | Where-Object id -eq $id3
Test-Check 'deploy: no recommendation -> preferred source of the settings' ($a3 -and ($a3.notes -like 'PoweredByWinget*') -eq ($script:Settings.Source -eq 'Winget')) $a3.notes
$npp = New-PackTuneSourceRow -Name 'Notepad++' -CatalogId 'notepadplusplus' -ChocoId 'notepadplusplus' -WingetId 'Notepad++.Notepad++' -ChocoVersion '8.7.1' -WingetVersion '8.7'
$npp.Source = 'Winget'
$id4 = New-PackTuneSourceApplication -App $npp -Parameters $ids
Test-Check 'deploy: the source chosen per app wins over the recommendation' ((Get-Store | Where-Object id -eq $id4).notes -like 'PoweredByPackTune;from=Winget;package=Notepad++.Notepad++;*')
$id5 = New-PackTuneSourceApplication -App $npp -Source Chocolatey -Parameters $ids
Test-Check '-Source overrides for all apps' ((Get-Store | Where-Object id -eq $id5).notes -like 'PoweredByPackTune;from=Chocolatey;package=notepadplusplus;*') ((Get-Store | Where-Object id -eq $id5).notes)
$err = $null
$null = New-PackTuneSourceApplication -App (New-PackTuneSourceRow -Name 'X' -ChocoId 'x') -Source Winget -ErrorVariable err -ErrorAction SilentlyContinue
Test-Check 'deploy: source the app does not have is an error' ($err.Count -eq 1)

# --- PackTune Runtime (one dependency app for both sources)
$runtime = @(Get-Store | Where-Object { $_.notes -like '*PackTuneRuntimeApp*' })
Test-Check 'runtime app is created once per tenant' ($runtime.Count -eq 1 -and $runtime[0].displayName -eq 'PackTune Runtime' -and $runtime[0].assignment -eq 'available')
Test-Check 'every new app of both sources depends on the one runtime (AutoInstall)' (@($a1.dependencies).targetId -contains $runtime[0].id -and @($a1.dependencies)[0].dependencyType -eq 'autoInstall' -and @((Get-Store | Where-Object id -eq $id4).dependencies).targetId -contains $runtime[0].id)
Test-Check 'Chocolatey apps depend on the same runtime, no separate Chocolatey app is created' (@($a2.dependencies).Count -eq 1 -and @($a2.dependencies).targetId -contains $runtime[0].id -and @(Get-Store | Where-Object { $_.displayName -eq 'Chocolatey' }).Count -eq 0 -and @(Get-Store | Where-Object { $_.displayName -eq 'winget runtime' }).Count -eq 0)
Test-Check 'runtime app is not listed as an app of the tool' (@(Get-PackTuneTenantApps | Where-Object { $_.Id -eq $runtime[0].id }).Count -eq 0)
$scripts = Get-PackTuneRuntimeScripts
foreach ($pair in @(@('install', $scripts.Install), @('detection', $scripts.Detection), @('update', $scripts.Update))) {
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($pair[1], [ref]$tokens, [ref]$errors)
    Test-Check "runtime $($pair[0]) script: valid PowerShell, ASCII, no placeholder" ($errors.Count -eq 0 -and $pair[1] -notmatch '[^\x00-\x7F]' -and $pair[1] -notmatch '__[A-Z]+__') (@($errors | ForEach-Object Message) -join '; ')
}
Test-Check 'runtime install (both parts): Chocolatey bootstrap with retry, winget; mutex, SIDs, protected folders, 64-bit relaunch, provisioning' ($scripts.Install -match 'Global.IntuneChocoDeployment"' -and $scripts.Install -match 'Enter-DeploymentLock' -and $scripts.Install -match 'Exit-DeploymentLock' -and $scripts.Install -match 'S-1-5-18' -and $scripts.Install -match 'S-1-5-32-544' -and $scripts.Install -match 'Protect-Folder \$RuntimeRoot' -and $scripts.Install -match 'Sysnative' -and $scripts.Install -match 'Add-AppxProvisionedPackage' -and $scripts.Install -match 'DesktopAppInstaller_Dependencies' -and $scripts.Install -match 'community\.chocolatey\.org/install\.ps1' -and $scripts.Install -match 'Get-Random -Minimum 60 -Maximum 300' -and $scripts.Install -match 'chocolateyDownloadUrl')
Test-Check 'runtime detection: choco and winget work, marker revision, no time limit' ($scripts.Detection -match 'chocolatey\\bin\\choco\.exe' -and $scripts.Detection -match 'Get-Winget' -and $scripts.Detection -match 'ready\.txt' -and $scripts.Detection -match '--version' -and $scripts.Detection -notmatch 'TotalHours|AddHours|UtcNow|Get-Date')
Test-Check 'runtime install registers the daily update task for SYSTEM and copies update.ps1' ($scripts.Install -match 'Register-ScheduledTask' -and $scripts.Install -match 'S-1-5-18' -and $scripts.Install -match '-Daily' -and $scripts.Install -match 'Intune-Winget-Updates' -and $scripts.Install -match 'Update PackTune Runtime' -and $scripts.Install -match 'Copy-Item[^\n]*update\.ps1' -and $scripts.Install -match 'Write-ProtectedFile \(Join-Path \$RuntimeRoot "ready\.txt"\)' -and $scripts.Install -notmatch 'upgrade --id')
Test-Check 'runtime update script: mutex, protected folder check, device log, upgrade once per 20 hours' ($scripts.Update -match 'Enter-DeploymentLock' -and $scripts.Update -match 'Exit-DeploymentLock' -and $scripts.Update -match 'Test-ForeignItem' -and $scripts.Update -match 'Write-DeviceLog' -and $scripts.Update -match '\$LogId = "_packtune-runtime"' -and $scripts.Update -match '"upgrade", "chocolatey"' -and $scripts.Update -match 'upgrade --id Microsoft.AppInstaller' -and $scripts.Update -match 'TotalHours -lt 20' -and $scripts.Update -match 'Global.IntuneChocoDeployment"')
# every file the runtime install.ps1 copies from its own folder is in the package that was built
$runtimeSource = Join-Path $env:LOCALAPPDATA 'PackTune\package\_packtune-runtime\source'
$rtAst = [System.Management.Automation.Language.Parser]::ParseInput($scripts.Install, [ref]$null, [ref]$null)
$rtCopied = @($rtAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' -and $n.Extent.Text -like 'Join-Path $PSScriptRoot *' }, $true) | ForEach-Object { $_.CommandElements[2].Value })
Test-Check 'runtime: every helper install.ps1 copies is in the package' ($rtCopied.Count -ge 1 -and @($rtCopied | Where-Object { -not (Test-Path -LiteralPath (Join-Path $runtimeSource $_)) }).Count -eq 0) "copied: $($rtCopied -join ','); folder: $(@(Get-ChildItem $runtimeSource -ErrorAction SilentlyContinue).Name -join ',')"
# security review: folders under %ProgramFiles%, signature pin, no winget from PATH (comments removed before matching)
function Get-CodeOnly([string]$Text) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    foreach ($t in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) { $Text = $Text.Remove($t.Extent.StartOffset, $t.Extent.EndOffset - $t.Extent.StartOffset) }
    $Text
}
$rtInstall = Get-CodeOnly $scripts.Install; $rtDetection = Get-CodeOnly $scripts.Detection; $rtUpdate = Get-CodeOnly $scripts.Update
Test-Check 'runtime: folders under %ProgramFiles%\PackTune\Runtime, nothing under %ProgramData% of the tool' ($rtInstall -match '\$RuntimeRoot = Join-Path \$ToolRoot "Runtime"' -and $rtInstall -match 'Protect-Folder \$ToolRoot' -and $rtDetection -match '"PackTune\\Runtime\\ready\.txt"' -and $rtDetection -match 'ProgramW6432' -and ($rtInstall + $rtDetection + $rtUpdate) -notmatch 'IntuneWingetDeployment|IntuneChocoUpdates')
Test-Check 'runtime: App Installer bundle and dependencies must carry a valid Microsoft signature before provisioning' ($rtInstall -match 'Get-AuthenticodeSignature -LiteralPath \$Path' -and $rtInstall.Contains('"CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"') -and $rtInstall -match '\[string\]\$Signature\.Status -ne "Valid" -or \$Signer -ne \$MicrosoftPublisher' -and $rtInstall.IndexOf('Assert-MicrosoftSigned $File') -gt 0 -and $rtInstall.IndexOf('Assert-MicrosoftSigned $File') -lt $rtInstall.IndexOf('Add-AppxProvisionedPackage -Online -PackagePath $Bundle -DependencyPackagePath'))
Test-Check 'runtime: winget only from WindowsApps, never from PATH' (($rtInstall + $rtDetection + $rtUpdate) -notmatch 'Get-Command winget' -and $rtDetection -match 'WindowsApps')
Test-Check 'runtime: revision in install and detection' ([int]$script:RuntimeRevision -ge 1 -and $scripts.Detection -match "\`$Revision = '$($script:RuntimeRevision)'")
# The signature check itself, on a signed and an unsigned file of this machine (read-only)
$sigAst = [System.Management.Automation.Language.Parser]::ParseInput($scripts.Install, [ref]$null, [ref]$null)
$sigFn = $sigAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-MicrosoftSigned' }, $true)
$MicrosoftPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
. ([scriptblock]::Create($sigFn.Extent.Text))
$unsigned = Join-Path $work 'fake.msixbundle'; 'not a package' | Set-Content $unsigned
Test-Check 'runtime: an unsigned download is refused' ($(try { Assert-MicrosoftSigned $unsigned; $false } catch { $_.Exception.Message -like '*not validly signed by Microsoft*' }))
# Chain root pinned to Microsoft Root Certificate Authority 2011 (an enterprise CA with the Microsoft subject must fail)
Test-Check 'runtime: signer chain must end in the Microsoft Root CA 2011' ($rtInstall -match '\$MicrosoftRoots = @\("8F43288AD272F3103B6FB1428485EA3014C0BCFE"\)' -and $rtInstall -match '\$Chain\.Build\(\$Signature\.SignerCertificate\)' -and $rtInstall -match '\$ChainRoot -notin \$MicrosoftRoots')
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (Test-Path -LiteralPath $edge) {
    # Edge is signed by "Microsoft Corporation" and chains to Root 2011: accepted with the real pin, refused with another root
    $MicrosoftRoots = @('8F43288AD272F3103B6FB1428485EA3014C0BCFE')
    Test-Check 'runtime: a Microsoft Corporation file chaining to Root 2011 is accepted' ($(try { Assert-MicrosoftSigned $edge; $true } catch { $false }))
    $MicrosoftRoots = @('0000000000000000000000000000000000000000')
    Test-Check 'runtime: same subject but another root is refused' ($(try { Assert-MicrosoftSigned $edge; $false } catch { $_.Exception.Message -like '*does not chain to the Microsoft root*' }))
    $MicrosoftRoots = @('8F43288AD272F3103B6FB1428485EA3014C0BCFE')
}
# Validly signed, but by "Microsoft Windows" (catalog), not by the App Installer publisher
Test-Check 'runtime: a valid signature of another Microsoft publisher is refused' ($(try { Assert-MicrosoftSigned "$env:SystemRoot\System32\notepad.exe"; $false } catch { $_.Exception.Message -like '*status Valid*' -or $_.Exception.Message -like '*not validly signed*' }))

$runtimeId = Get-PackTuneRuntimeWin32ID
Test-Check 'runtime app found again, not created twice' ($runtimeId -eq $runtime[0].id -and @(Get-Store | Where-Object { $_.notes -like '*PackTuneRuntimeApp*' }).Count -eq 1)
# a winget app from before the runtime existed
$legacy = Get-Store | Where-Object id -eq $id1
$stored = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json
foreach ($s in @($stored)) { if ($s.id -eq $id1) { $s.dependencies = @() } }
ConvertTo-Json -InputObject @($stored) -Depth 6 | Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json')
$without = @(Get-PackTuneAppsWithoutRuntime)
Test-Check 'apps without the runtime dependency are found' ($without.Count -eq 1 -and $without[0].Id -eq $id1) "$($without.Count)"
$added = @(Add-PackTuneRuntimeDependency)
$after = Get-Store | Where-Object id -eq $id1
Test-Check 'dependency is added to the old winget app, others are left alone' ($added.Count -eq 1 -and @($added | Where-Object Added).Count -eq 1 -and @($after.dependencies).targetId -contains $runtimeId)
Test-Check 'adding it again changes nothing' (@(Add-PackTuneRuntimeDependency | Where-Object Added).Count -eq 0 -and @((Get-Store | Where-Object id -eq $id1).dependencies).Count -eq 1)


# --- migration of an existing tenant: old Chocolatey app and old winget runtime app
$Store = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$oldChoco = [pscustomobject]@{ id = 'old-choco'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; dependencies = @(); supersedence = @(); assignments = @() }
$oldWinget = [pscustomobject]@{ id = 'old-winget'; displayName = 'winget runtime'; notes = 'WingetRuntimeApp'; dependencies = @(); supersedence = @(); assignments = @() }
foreach ($s in $stored) {
    if ($s.id -eq $id2) { $s.dependencies = @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' }) }
    if ($s.id -eq $id1) { $s.dependencies = @([pscustomobject]@{ targetId = 'old-winget'; dependencyType = 'autoInstall' }) }
}
ConvertTo-Json -InputObject @($stored + $oldChoco + $oldWinget) -Depth 6 | Set-Content $Store
$old = @(Get-PackTuneOldDependencyApps)
Test-Check 'old Chocolatey app and old winget runtime app are recognized' ($old.Count -eq 2 -and ($old | Where-Object Kind -eq 'Chocolatey').Id -eq 'old-choco' -and ($old | Where-Object Kind -eq 'WingetRuntime').Id -eq 'old-winget')
Test-Check 'old dependency apps are not apps of the runtime and not in the tool list as dependency of PackTune' (@(Get-PackTuneTenantApps | Where-Object { $_.Id -eq 'old-winget' }).Count -eq 0)
$state = Get-PackTuneRuntimeState
Test-Check 'readiness state: runtime present, apps still on old dependencies -> Migrate' ($state.State -eq 'Migrate' -and $state.RuntimePresent -and $state.RuntimeId -eq $runtimeId -and @($state.AppsOnOldDependencies).Count -ge 2 -and @($state.UnusedOld).Count -eq 0)
$unusedBefore = @(Get-PackTuneUnusedDependencyApps)
Test-Check 'old apps in use are not offered for removal' ($unusedBefore.Count -eq 0)
$choco2 = $false
try { Remove-PackTuneApp -Id 'old-choco' } catch { $choco2 = $_.Exception.Message -like '*Switch them to the PackTune Runtime*' }
Test-Check 'old Chocolatey app in use cannot be removed' ($choco2 -and @(Get-Store | Where-Object id -eq 'old-choco').Count -eq 1)
# the app being switched also supersedes another app: the switch must keep that (updateRelationships replaces the whole set)
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
foreach ($s in $stored) { if ($s.id -eq $id1) { $s.supersedence = @([pscustomobject]@{ targetId = $id2; supersedenceType = 'update' }) } }
ConvertTo-Json -InputObject @($stored) -Depth 6 | Set-Content $Store
$moved = @(Switch-PackTuneAppsToRuntime)
Test-Check 'switch: the supersedence of the app survives the change of its dependencies' (@((Get-Store | Where-Object id -eq $id1).supersedence).targetId -eq $id2)
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
foreach ($s in $stored) { if ($s.id -eq $id1) { $s.supersedence = @() } }
ConvertTo-Json -InputObject @($stored) -Depth 6 | Set-Content $Store
$after1 = Get-Store | Where-Object id -eq $id1; $after2 = Get-Store | Where-Object id -eq $id2
Test-Check 'switch: apps get the runtime, the old dependency is taken away' (@($after1.dependencies).Count -eq 1 -and @($after1.dependencies).targetId -eq $runtimeId -and @($after2.dependencies).Count -eq 1 -and @($after2.dependencies).targetId -eq $runtimeId -and $moved.Count -ge 2 -and (@($moved | Where-Object OldRemoved).Count -ge 2))
Test-Check 'switch again changes nothing' (@(Switch-PackTuneAppsToRuntime).Count -eq 0)
$state = Get-PackTuneRuntimeState
Test-Check 'readiness state after the switch: Ready, both old apps unused' ($state.State -eq 'Ready' -and @($state.UnusedOld).Count -eq 2 -and @($state.AppsOnOldDependencies).Count -eq 0)
$dry = @(Remove-PackTuneUnusedDependencyApps -WhatIf)
Test-Check '-WhatIf lists the unused old apps and deletes nothing' ($dry.Count -eq 2 -and @(Get-Store | Where-Object id -in 'old-choco', 'old-winget').Count -eq 2)
Test-Check 'nothing is deleted automatically (switch left the old apps)' (@(Get-Store | Where-Object id -in 'old-choco', 'old-winget').Count -eq 2)
$gone = @(Remove-PackTuneUnusedDependencyApps)
Test-Check 'unused old dependency apps can be removed on request' ($gone.Count -eq 2 -and @(Get-Store | Where-Object id -in 'old-choco', 'old-winget').Count -eq 0)
# an old app that is still used by an app outside the tool stays on the list of used ones
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
ConvertTo-Json -InputObject @($stored + [pscustomobject]@{ id = 'old-choco'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; dependencies = @(); supersedence = @(); assignments = @() } + [pscustomobject]@{ id = 'foreign'; displayName = 'Other app'; notes = ''; dependencies = @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' }); supersedence = @(); assignments = @() }) -Depth 6 | Set-Content $Store
Test-Check 'old app used by any app in the tenant is not offered for removal' (@(Get-PackTuneUnusedDependencyApps).Count -eq 0)
ConvertTo-Json -InputObject @(@(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object { $_.id -notin 'old-choco', 'foreign' }) -Depth 6 | Set-Content $Store
# the job fails when the change does not hold in the tenant: Graph accepts the call but the dependencies stay (what the user saw as Done)
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
foreach ($s in $stored) { if ($s.id -eq $id2) { $s.dependencies = @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' }) } }
ConvertTo-Json -InputObject @($stored + [pscustomobject]@{ id = 'old-choco'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; dependencies = @(); supersedence = @(); assignments = @() }) -Depth 6 | Set-Content $Store
$origSetRel = ${function:Set-PackTuneAppRelationships}
function Set-PackTuneAppRelationships { param($AppId, $Own) }
$failMsg = ''; $log = @()
try { $log = @(Switch-PackTuneAppsToRuntime 6>&1 2>&1 | ForEach-Object { "$_" }) } catch { $failMsg = $_.Exception.Message }
Test-Check 'switch: a change that does not hold in the tenant fails the job with the cause per app (never Done)' ($failMsg -like '*could not be switched*' -and $failMsg -like '*still depends on the old dependency app*' -and $failMsg -like "*$id2*") $failMsg
Set-Item function:Set-PackTuneAppRelationships $origSetRel
# the job writes per app what it found and did, then a summary
$log = @(Switch-PackTuneAppsToRuntime 6>&1 | ForEach-Object { "$_" })
Test-Check 'switch: the log names the app, the old dependency found, what was added/removed, and a summary' (($log -join "`n") -match 'old dependencies found: Chocolatey \(old-choco\)' -and ($log -join "`n") -match 'old dependency\(ies\) removed, confirmed in the tenant' -and ($log -join "`n") -match 'Summary: 1 app\(s\) switched')
ConvertTo-Json -InputObject @(@(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object { $_.id -ne 'old-choco' }) -Depth 6 | Set-Content $Store

# removal and relationships (the service refuses to delete a parent of another app)
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$mk = { param($i, $n, $deps, $sup) [pscustomobject]@{ id = $i; displayName = $n; notes = ''; dependencies = @($deps); supersedence = @($sup); assignments = @() } }
ConvertTo-Json -InputObject @($stored + (& $mk 'rel-a' 'App A' @([pscustomobject]@{ targetId = 'rel-b'; dependencyType = 'autoInstall' }) @([pscustomobject]@{ targetId = 'rel-c'; supersedenceType = 'update' })) + (& $mk 'rel-b' 'App B' @() @()) + (& $mk 'rel-c' 'App C' @() @())) -Depth 6 | Set-Content $Store
$direct = ''; try { Invoke-IntuneModule { Remove-IntuneWin32App -ID 'rel-a' } } catch { $direct = $_.Exception.Message }
Test-Check 'fake service: a plain delete of an app with relationships fails like the real one (parent of another app)' ($direct -like '*parent of another app*')
$info = Get-PackTuneAppRemovalInfo -AppId 'rel-a'
Test-Check 'removal info: what the app depends on / supersedes, nothing depends on it' (@($info.Own).Count -eq 2 -and @($info.Dependents).Count -eq 0)
$infoB = Get-PackTuneAppRemovalInfo -AppId 'rel-b'
Test-Check 'removal info: who depends on an app' (@($infoB.Dependents).Count -eq 1 -and $infoB.Dependents[0].TargetId -eq 'rel-a' -and $infoB.Dependents[0].TargetName -eq 'App A')
$refused = ''; try { Remove-PackTuneIntuneApp -Id 'rel-b' -Name 'App B' } catch { $refused = $_.Exception.Message }
Test-Check 'an app that another app depends on is never deleted, the dependents are named' ($refused -like '*App A (rel-a)*' -and @(Get-Store | Where-Object id -eq 'rel-b').Count -eq 1) $refused
$log = @(Remove-PackTuneIntuneApp -Id 'rel-c' -Name 'App C' 6>&1 | ForEach-Object { "$_" })
Test-Check 'a superseded app: the supersedence on the superseding app is taken off, then it is deleted' (@(Get-Store | Where-Object id -eq 'rel-c').Count -eq 0 -and @((Get-Store | Where-Object id -eq 'rel-a').supersedence).Count -eq 0 -and @((Get-Store | Where-Object id -eq 'rel-a').dependencies).Count -eq 1 -and ($log -join "`n") -match 'taking that supersedence off')
$log = @(Remove-PackTuneIntuneApp -Id 'rel-a' -Name 'App A' 6>&1 | ForEach-Object { "$_" })
Test-Check 'an app with relationships of its own: they are cleared (and logged) first, then it is deleted and read back' (@(Get-Store | Where-Object id -eq 'rel-a').Count -eq 0 -and ($log -join "`n") -match 'has 1 relationship\(s\) of its own' -and ($log -join "`n") -match 'Deleted App A \(rel-a\)')
$null = Remove-PackTuneIntuneApp -Id 'rel-b' -Name 'App B'
Test-Check 'after its dependent is gone the dependency app can be deleted' (@(Get-Store | Where-Object id -eq 'rel-b').Count -eq 0)
# unused old apps: kept ones are logged with their users
$stored = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
ConvertTo-Json -InputObject @($stored + ([pscustomobject]@{ id = 'old-choco'; displayName = 'Chocolatey'; notes = 'FiredWithPowershell'; dependencies = @(); supersedence = @(); assignments = @() }) + (& $mk 'foreign2' 'Other app' @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' }) @())) -Depth 6 | Set-Content $Store
$log = @(Remove-PackTuneUnusedDependencyApps 6>&1 | ForEach-Object { "$_" })
Test-Check 'removing old dependency apps: an app still used is kept and the log says by which app' (($log -join "`n") -match 'Kept Chocolatey \(old-choco\): still used by Other app \(foreign2\)' -and @(Get-Store | Where-Object id -eq 'old-choco').Count -eq 1)
ConvertTo-Json -InputObject @(@(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object { $_.id -notin 'old-choco', 'foreign2' }) -Depth 6 | Set-Content $Store
# no runtime yet: state Missing
$none = @(Get-Content $Store -Raw | ConvertFrom-Json | ForEach-Object { $_ })
ConvertTo-Json -InputObject @($none | Where-Object { $_.notes -notlike '*PackTuneRuntimeApp*' }) -Depth 6 | Set-Content $Store
Test-Check 'readiness state without runtime: Missing' ((Get-PackTuneRuntimeState).State -eq 'Missing')
ConvertTo-Json -InputObject @($none) -Depth 6 | Set-Content $Store
Test-Check 'compat names of the interface point to the one runtime' ((get-ChocoWin32ID) -eq $runtimeId -and (Get-WingetRuntimeWin32ID -NoCreate) -eq $runtimeId)
# app registration: the old name is recognized, the owner check stays (see GUI smoke test for the creation path)
$reg = (Get-Command New-PackTuneAppRegistration).Parameters
Test-Check 'app registration is named PackTune and recognizes the old name' ($reg.DisplayName.Attributes.Count -ge 0 -and (Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match '\[string\]\$DisplayName = "PackTune"' -and (Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match 'FormerNames = @\("Intune Chocolatey Deployment"\)' -and (Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw) -match 'you are not its only owner')
# --- release: supersedence for Available, in place for Required
$pin = @{ Assignment = 'Available'; IconBase64 = $script:Png; Version = '24.08' }
$availId = New-PackTuneChocolateyApp -ChocoName '7zip' @pin
Test-Check 'precondition: pinned Available Chocolatey app' ($availId -and (Get-PackTuneReleasePath -AppId $availId) -eq 'Supersedence')
$result = Publish-PackTuneRelease -AppId $availId -Version '24.09'
$old = Get-Store | Where-Object id -eq $availId
$new = Get-Store | Where-Object id -eq $result.AppId
Test-Check 'Available app: release goes through supersedence' ($result.Path -eq 'Supersedence' -and $result.AppId -ne $availId -and $result.OldAppId -eq $availId)
Test-Check 'new app: version, notes, name, icon and settings copied' ($new.displayVersion -eq '24.09' -and $new.notes -like '*package=7zip;version=24.09;*' -and $new.displayName -eq $old.displayName -and $new.hasIcon -and $new.description -eq $old.description -and $new.applicableArchitectures -eq $old.applicableArchitectures -and $new.publisher -eq $old.publisher) "$($new.notes)"
Test-Check 'new app supersedes the old one with type update' (@($new.supersedence).Count -eq 1 -and $new.supersedence[0].targetId -eq $availId -and $new.supersedence[0].supersedenceType -eq 'update')
Test-Check 'new app has the dependencies of the old one' (@($new.dependencies).Count -eq @($old.dependencies).Count -and @($new.dependencies).Count -ge 1 -and @($new.dependencies)[0].targetId -eq @($old.dependencies)[0].targetId)
Test-Check 'new app: same Available assignment with auto-update of superseded apps' (@($new.assignments).Count -eq 1 -and $new.assignments[0].Intent -eq 'available' -and $new.assignments[0].AutoUpdateSupersededApps -eq 'enabled')
Test-Check 'old app is untouched (content, assignment)' ($old.uploads -eq 1 -and $old.assignment -eq 'available' -and $old.notes -like '*version=24.08;*')
# Required: in place
$reqId = New-PackTuneChocolateyApp -ChocoName 'only.choco' -Assignment Required -IconBase64 $script:Png -Version '0.9'
Test-Check 'precondition: Required app takes the in-place path' ((Get-PackTuneReleasePath -AppId $reqId) -eq 'InPlace')
$appsBefore = (Get-Store).Count
$r2 = Publish-PackTuneRelease -AppId $reqId -Version '1.0'
$req = Get-Store | Where-Object id -eq $reqId
Test-Check 'Required app: updated in place, no new app' ($r2.Path -eq 'InPlace' -and $r2.AppId -eq $reqId -and (Get-Store).Count -eq $appsBefore -and $req.uploads -eq 2 -and $req.notes -like '*version=1.0;*' -and @($req.supersedence).Count -eq 0)
# Required and Available together: in place as well
$stored = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json
foreach ($s in @($stored)) { if ($s.id -eq $reqId) { $s.assignments = @($s.assignments) + [pscustomobject]@{ Type = '#microsoft.graph.groupAssignmentTarget'; Intent = 'available'; GroupID = 'g1' } } }
ConvertTo-Json -InputObject @($stored) -Depth 6 | Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json')
Test-Check 'Required plus Available: in place' ((Get-PackTuneReleasePath -AppId $reqId) -eq 'InPlace')
# a failing release leaves nothing behind
$before = (Get-Store).Count
# (not $failed: variable names ignore case, that would be the failure counter $script:Failed)
$releaseThrew = $false
try { Publish-PackTuneRelease -AppId $availId -Version '9.9.9' | Out-Null } catch { $releaseThrew = $true }
Test-Check 'unknown version: error, no new app' ($releaseThrew -and (Get-Store).Count -eq $before)

# --- cleanup of superseded apps
$rows = @(Get-PackTuneSupersededApps)
Test-Check 'superseded app is found' ($rows.Count -eq 1 -and $rows[0].OldId -eq $availId -and $rows[0].NewId -eq $result.AppId -and $rows[0].NewVersion -eq '24.09')
$kept = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 3 })
Test-Check 'still installed on devices: stays' ($kept.Count -eq 1 -and -not $kept[0].Removed -and $kept[0].InstalledCount -eq 3 -and @(Get-Store | Where-Object id -eq $availId).Count -eq 1)
$unknown = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) throw 'no status' })
Test-Check 'install status not readable: stays' (-not $unknown[0].Removed -and @(Get-Store | Where-Object id -eq $availId).Count -eq 1)
$dry = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 } -WhatIf)
Test-Check '-WhatIf removes nothing' (-not $dry[0].Removed -and @(Get-Store | Where-Object id -eq $availId).Count -eq 1)
$gone = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 })
Test-Check 'no device has it: old app removed, new app stays, relation cleared' ($gone[0].Removed -and @(Get-Store | Where-Object id -eq $availId).Count -eq 0 -and @(Get-Store | Where-Object id -eq $result.AppId).Count -eq 1 -and @((Get-Store | Where-Object id -eq $result.AppId).supersedence).Count -eq 0 -and @((Get-Store | Where-Object id -eq $result.AppId).dependencies).Count -ge 1)
Test-Check 'nothing left to clean up' (@(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 }).Count -eq 0)


# --- popular apps: top Chocolatey packages by downloads, merged with the catalog
function New-FeedPackage($Id, $Title, $Downloads, $Tags = '', $Authors = '', $Site = 'https://example.org', $Description = 'A program', $Version = '1.0') {
    [pscustomobject]@{ Name = $Id; Title = $Title; Version = $Version; Downloads = [string]$Downloads; Tags = $Tags; Authors = $Authors; SoftwareSite = $Site; Description = $Description; Summary = 's'; IconUrl = $null; SoftwareLicense = $null; LicenseNote = $null }
}
$feed = @(
    (New-FeedPackage 'chocolatey' 'Chocolatey' 900 'nuget')
    (New-FeedPackage 'chocolatey-core.extension' 'Chocolatey Core' 880)
    (New-FeedPackage 'googlechrome' 'Google Chrome' 870 'browser' 'Google')
    (New-FeedPackage 'GoogleChrome.install' 'Google Chrome (Install)' 860)
    (New-FeedPackage '7zip.install' '7-Zip (Install)' 850 'zip archive')
    (New-FeedPackage 'notepad3' 'Notepad3' 840 'editor notepad' 'Rizonesoft' 'https://www.rizonesoft.com' 'Editor' '6.0')
    (New-FeedPackage 'notepad3.install' 'Notepad3 (Install)' 830 'editor')
    (New-FeedPackage 'akelpad' 'AkelPad' 820 'editor text' 'Alexey' 'https://example.org' 'Editor' '4.9')
    (New-FeedPackage 'only.installer.install' 'Only Installer (Install)' 810 'media player')
    (New-FeedPackage 'bad id!' 'Bad Id' 800)
    (New-FeedPackage '..\evil' 'Evil' 790)
    (New-FeedPackage 'oldtool' 'Old Tool' 780 'deprecated tools')
    (New-FeedPackage 'twin' 'Twin' 770 'chat messenger' 'Twin Corp')
    (New-FeedPackage 'mystery' 'Mystery Thing' 760 'zzz' 'Nobody')
    (New-FeedPackage 'lastone' 'Last One' 750 'vpn')
)
$kept = @(Select-PackTunePopular -Packages $feed -Top 200)
$ids = $kept.Name -join ','
Test-Check 'popular: order of the downloads kept' ($ids -eq 'notepad3,akelpad,only.installer.install,twin,mystery,lastone') $ids
Test-Check 'popular: invalid ids are dropped (space, path characters)' ($kept.Name -notcontains 'bad id!' -and $kept.Name -notcontains '..\evil')
Test-Check 'popular: infrastructure and deprecated packages are dropped' ($kept.Name -notcontains 'chocolatey' -and $kept.Name -notcontains 'chocolatey-core.extension' -and $kept.Name -notcontains 'oldtool')
Test-Check 'popular: x.install is dropped when x is there, kept when it is alone' ($kept.Name -notcontains 'notepad3.install' -and $kept.Name -contains 'only.installer.install')
Test-Check 'popular: what the catalog has is not listed twice (googlechrome, GoogleChrome.install, 7zip.install)' ($kept.Name -notcontains 'googlechrome' -and $kept.Name -notcontains 'GoogleChrome.install' -and $kept.Name -notcontains '7zip.install')
Test-Check 'popular: at most -Top' (@(Select-PackTunePopular -Packages $feed -Top 3).Count -eq 3)
Test-Check 'popular: category from the tags, "Other" as fallback' ((Get-PackTunePopularCategory 'zip archive') -eq 'Utilities' -and (Get-PackTunePopularCategory 'chat messenger') -eq 'Communication' -and (Get-PackTunePopularCategory 'vpn') -eq 'Remote & Network' -and (Get-PackTunePopularCategory 'zzz') -eq 'Other' -and (Get-PackTunePopularCategory '') -eq 'Other')
# winget: only when it clearly is the same product
$winget = @{
    'Notepad3' = @([pscustomobject]@{ Name = 'Rizonesoft.Notepad3'; Title = 'Notepad3'; Version = '6.1' })
    'AkelPad'  = @([pscustomobject]@{ Name = 'AkelPad.AkelPad'; Title = 'AkelPad'; Version = '4.9.9' })
    'Twin'     = @([pscustomobject]@{ Name = 'Twin.Corp.Twin'; Title = 'Twin'; Version = '2' }, [pscustomobject]@{ Name = 'Twin.Corp.TwinPro'; Title = 'Twin'; Version = '3' })
    'Mystery Thing' = @([pscustomobject]@{ Name = 'Someone.Mystery'; Title = 'Mystery Thing Pro'; Version = '1' })
    'Last One' = @([pscustomobject]@{ Name = 'bad id'; Title = 'Last One'; Version = '1' })
}
$finder = { param($Term) $winget[$Term] }
$byName = @{}; foreach ($p in $feed) { $byName[$p.Name] = $p }
$m1 = Resolve-PackTuneWingetMatch -Package $byName['notepad3'] -Finder $finder
Test-Check 'winget match: same name and publisher in authors or project URL' ($m1 -and $m1.Name -eq 'Rizonesoft.Notepad3')
Test-Check 'winget match: same name but the publisher does not show in the package -> none' ($null -eq (Resolve-PackTuneWingetMatch -Package $byName['akelpad'] -Finder $finder))
Test-Check 'winget match: two candidates -> none' ($null -eq (Resolve-PackTuneWingetMatch -Package $byName['twin'] -Finder $finder))
Test-Check 'winget match: different name -> none' ($null -eq (Resolve-PackTuneWingetMatch -Package $byName['mystery'] -Finder $finder))
Test-Check 'winget match: invalid winget id -> none' ($null -eq (Resolve-PackTuneWingetMatch -Package $byName['lastone'] -Finder $finder))
$popCache = Join-Path $work 'popular.json'
$meta = @{}
$script:FeedCalls = 0
$rows = @(Get-PackTunePopularApps -FeedPackages $feed -WingetFinder $finder -CachePath $popCache -Cache $meta)
$nr = $rows | Where-Object ChocoId -eq 'notepad3'; $ak = $rows | Where-Object ChocoId -eq 'akelpad'
Test-Check 'popular rows: popular flag, downloads, category' ($rows.Count -eq 6 -and @($rows | Where-Object { -not $_.Popular }).Count -eq 0 -and $nr.Category -eq 'Developer' -and $nr.Downloads -eq 840 -and ($rows | Where-Object ChocoId -eq 'mystery').Category -eq 'Other')
Test-Check 'popular rows: verified winget id gives both sources and the Recommended logic, the rest is Chocolatey only' ((($nr.Sources) -join ',') -eq 'Chocolatey,Winget' -and $nr.WingetId -eq 'Rizonesoft.Notepad3' -and $nr.Recommended -eq 'Winget' -and $nr.RecommendedMarked -and ($ak.Sources -join ',') -eq 'Chocolatey' -and $null -eq $ak.WingetId)
Test-Check 'popular rows: the filter helper works on them (Both / Chocolatey only)' (@(Select-PackTuneSourceApps -Apps $rows -Filter Both).Count -eq 1 -and @(Select-PackTuneSourceApps -Apps $rows -Filter Chocolatey).Count -eq 5)
Test-Check 'popular rows: package infos seeded into the cache, no lookup per package' ($meta['notepad3'].Found -and $meta['notepad3'].Version -eq '6.0' -and $meta.Count -eq 6)
Test-Check 'popular rows: no duplicate of a catalog app' (@($rows | Where-Object { $_.ChocoId -in 'googlechrome', '7zip.install' }).Count -eq 0)
function Get-PackTunePopularFeed { $script:FeedCalls++; throw 'the feed must not be asked while the cache is fresh' }
$cached = @(Get-PackTunePopularApps -CachePath $popCache -WingetFinder $finder)
Test-Check 'popular: the cache (24 hours) is used without asking the feed, matches included' ($cached.Count -eq 6 -and $script:FeedCalls -eq 0 -and ($cached | Where-Object ChocoId -eq 'notepad3').WingetId -eq 'Rizonesoft.Notepad3')
$old = Get-Content $popCache -Raw | ConvertFrom-Json; $old.Fetched = (Get-Date).AddHours(-30).ToString('o'); $old | ConvertTo-Json -Depth 4 | Set-Content $popCache
$stale = $false; try { $null = Get-PackTunePopularApps -CachePath $popCache -WingetFinder $finder } catch { $stale = $_.Exception.Message -like '*must not be asked*' }
Test-Check 'popular: an older cache is read again from the feed' $stale
$forced = $false; try { $null = Get-PackTunePopularApps -CachePath $popCache -Force } catch { $forced = $_.Exception.Message -like '*must not be asked*' }
Test-Check 'popular: -Force ignores a fresh cache (Refresh versions)' $forced
Remove-Item Function:\Get-PackTunePopularFeed
# the feed retries with a wait when it limits the requests
$script:Attempts = 0; $script:Waited = 0
function Start-Sleep { param($Seconds, $Milliseconds) $script:Waited += $Seconds }
$feedXml = '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata"><entry><title type="text">demo</title><m:properties><d:Version>1.0</d:Version><d:Tags>a b</d:Tags></m:properties></entry></feed>'
function Invoke-WebRequest { param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction) $script:Attempts++; if ($script:Attempts -lt 3) { throw [System.InvalidOperationException]::new('The operation has timed out') }; [pscustomobject]@{ Content = $feedXml } }
$got = @(Invoke-ChocoFeed -Query "Search()?searchTerm=''")
Test-Check 'feed: a timeout is retried with a growing wait (5 s, then 10 s) and then answers' ($script:Attempts -eq 3 -and $script:Waited -eq 15 -and $got.Count -eq 1 -and $got[0].Name -eq 'demo' -and $got[0].Tags -eq 'a b') "attempts=$script:Attempts waited=$script:Waited"
$script:Attempts = 0
function Invoke-WebRequest { param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction) $script:Attempts++; throw [System.InvalidOperationException]::new('The operation has timed out') }
$gaveUp = $false; try { $null = Invoke-ChocoFeed -Query 'x' } catch { $gaveUp = $true }
Test-Check 'feed: after four attempts it gives up with the error' ($gaveUp -and $script:Attempts -eq 4)
$script:Attempts = 0
function Invoke-WebRequest { param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction) $script:Attempts++; throw [System.InvalidOperationException]::new('The remote name could not be resolved') }
$null = try { Invoke-ChocoFeed -Query 'x' } catch { }
Test-Check 'feed: an error that is no rate limit is not retried' ($script:Attempts -eq 1)
Remove-Item Function:\Invoke-WebRequest, Function:\Start-Sleep

# --- search order: most downloaded first, winget-only after the counted ones
# (the earlier offline stub of the winget search is replaced by the normal one)
function Search-WingetPackage { param([string]$SearchPattern, [int]$Top)
    foreach ($Id in 'Google.Chrome', 'Other.WingetOnly', 'Mozilla.Firefox') { [pscustomobject]@{ Name = $Id; Title = "Title $Id"; Version = $script:WingetFeed[$Id]; Authors = $null; Source = 'Winget' } }
}
$ordered = @(Search-PackTuneApps -SearchPattern 'x' -Cache @{} -NoFetch)
$orderText = ($ordered | ForEach-Object { "$($_.Name)=$($_.Downloads)" }) -join ', '
Test-Check 'search: ordered by the Chocolatey download count, uncounted rows last' (($ordered[0].ChocoId -eq 'only.choco') -and ($ordered[1].CatalogId -eq 'googlechrome') -and ($ordered[0].Downloads -eq 5000) -and ($ordered[1].Downloads -eq 1000) -and (@($ordered | Where-Object { $_.Downloads -lt 0 }).Count -ge 1) -and (($ordered | Select-Object -Last 1).Downloads -lt 0)) $orderText
$uncounted = @($ordered | Where-Object { $_.Downloads -lt 0 }).Name
Test-Check 'search: rows without a count are sorted by name' ((($uncounted -join '|') -eq ((@($uncounted) | Sort-Object) -join '|')))
Test-Check 'search: rows carry tags and icon url for the dialog' (($null -ne $ordered[0].Tags) -and ($ordered[0].PSObject.Properties.Name -contains 'IconUrl'))
$withCache = @(Search-PackTuneApps -SearchPattern 'x' -Cache @{ 'firefox' = [pscustomobject]@{ Found = $true; Version = '130.0'; Downloads = '9000' } } -NoFetch)
Test-Check 'search: a winget hit matched to a Chocolatey package takes its download count' ((($withCache | Where-Object CatalogId -eq 'firefox').Downloads -eq 9000) -and ($withCache[0].CatalogId -eq 'firefox')) (($withCache | ForEach-Object { "$($_.Name)=$($_.Downloads)" }) -join ', ')

# --- my apps: add, persist, remove, validation
$myPath = Join-Path $work 'my-apps.json'
$myAdd = Add-PackTuneMyApp -Name 'Obsidian' -ChocoId 'obsidian' -WingetId 'Obsidian.Obsidian' -Tags 'notes markdown editor' -Path $myPath
Test-Check 'my apps: added and saved with an auto category' (($myAdd.Added) -and (Test-Path $myPath) -and (@(Get-PackTuneMyApps -Path $myPath).Count -eq 1) -and ((Get-PackTuneMyApps -Path $myPath)[0].Category -eq 'Developer'))
Test-Check 'my apps: the file holds names and ids only' (((Get-Content $myPath -Raw) -notmatch '(?i)tenant|token|secret|clientid') -and ((@((Get-Content $myPath -Raw | ConvertFrom-Json)[0].PSObject.Properties.Name) -join ',') -eq 'Name,ChocoId,WingetId,Category,Added'))
$myAgain = Add-PackTuneMyApp -Name 'Obsidian again' -ChocoId 'OBSIDIAN' -Path $myPath
Test-Check 'my apps: the same package is not added twice (case-insensitive)' ((-not $myAgain.Added) -and ($myAgain.Reason -like '*already*') -and (@(Get-PackTuneMyApps -Path $myPath).Count -eq 1))
$myDupe = Add-PackTuneMyApp -Name 'Chrome' -ChocoId 'googlechrome' -Path $myPath
Test-Check 'my apps: an app of the curated catalog is not added' ((-not $myDupe.Added) -and ($myDupe.Reason -like '*curated*'))
$myNoWinget = Add-PackTuneMyApp -Name 'Only Choco' -ChocoId 'only.choco' -Tags 'zzz' -Path $myPath
Test-Check 'my apps: a Chocolatey-only app, category falls back to Other' (($myNoWinget.Added) -and ($myNoWinget.Entry.Category -eq 'Other') -and [string]::IsNullOrEmpty($myNoWinget.Entry.WingetId))
foreach ($bad in @(@('Bad', 'bad id!', ''), @('Bad', '', '..\evil'), @('Bad', 'a$(calc)', ''), @('Fine name', 'ok.id', 'x y'), @('Bad', '', ''))) {
    $rejected = $false; try { $null = Add-PackTuneMyApp -Name $bad[0] -ChocoId $bad[1] -WingetId $bad[2] -Path $myPath } catch { $rejected = $true }
    Test-Check "my apps: refused ($($bad -join '|'))" $rejected
}
$emptyName = $false; try { $null = Add-PackTuneMyApp -Name ' ' -ChocoId 'ok.id' -Path $myPath } catch { $emptyName = $true }
Test-Check 'my apps: a blank name is refused' $emptyName
Test-Check 'my apps: nothing invalid was saved' (@(Get-PackTuneMyApps -Path $myPath).Count -eq 2)
$hand = @(@{ Name = 'Fine'; ChocoId = 'fine.app' }, @{ Name = 'Evil'; ChocoId = 'a b;c' }, @{ Name = ''; ChocoId = 'noname' }, @{ Name = 'NoId' }) | ConvertTo-Json
Set-Content (Join-Path $work 'hand.json') $hand
Test-Check 'my apps: invalid entries of an edited file are ignored' ((@(Get-PackTuneMyApps -Path (Join-Path $work 'hand.json')).Name -join ',') -eq 'Fine')
$myRows = @(Get-PackTuneMyAppRows -Cache @{ 'obsidian' = [pscustomobject]@{ Found = $true; Version = '1.5' }; 'winget:obsidian.obsidian' = [pscustomobject]@{ Found = $true; Version = '1.6' } } -NoFetch -Path $myPath)
$obs = $myRows | Where-Object ChocoId -eq 'obsidian'
Test-Check 'my apps: rows are marked Mine, with both sources and the recommendation' (($myRows.Count -eq 2) -and (@($myRows | Where-Object { -not $_.Mine }).Count -eq 0) -and ($obs.Recommended -eq 'Winget') -and ((@($obs.Sources) -join ',') -eq 'Chocolatey,Winget'))
$removed1 = Remove-PackTuneMyApp -ChocoId 'obsidian' -Path $myPath
$removed2 = Remove-PackTuneMyApp -ChocoId 'obsidian' -Path $myPath
Test-Check 'my apps: removing takes it off the list and the file' (($removed1 -eq 1) -and ($removed2 -eq 0) -and (@(Get-PackTuneMyApps -Path $myPath).Count -eq 1))
Test-Check 'my apps: survives a restart (read back from the file)' ((Get-PackTuneMyApps -Path $myPath)[0].ChocoId -eq 'only.choco')

# --- refresh schedule: not more often than every 60 minutes, the button forces
$stamp = Join-Path $work 'last-refresh.txt'
$base = [datetime]'2026-11-14T10:00:00Z'
Test-Check 'refresh: due when there is no stamp' (Test-PackTuneRefreshDue -Path $stamp -Now $base)
Set-PackTuneRefreshStamp -Path $stamp -Now $base
Test-Check 'refresh: skipped 59 minutes after the last full refresh' (-not (Test-PackTuneRefreshDue -Path $stamp -Now $base.AddMinutes(59)))
Test-Check 'refresh: due after 60 minutes' (Test-PackTuneRefreshDue -Path $stamp -Now $base.AddMinutes(60))
'garbage' | Set-Content $stamp
Test-Check 'refresh: an unreadable stamp means due' (Test-PackTuneRefreshDue -Path $stamp -Now $base)
# the popular list: an older cache shows at once (AllowStale), a normal call asks the feed again
$popOld = Join-Path $work 'popular-stale.json'
$null = Get-PackTunePopularApps -FeedPackages $feed -WingetFinder $finder -CachePath $popOld
$o = Get-Content $popOld -Raw | ConvertFrom-Json; $o.Fetched = (Get-Date).AddDays(-3).ToString('o'); $o | ConvertTo-Json -Depth 4 | Set-Content $popOld
function Get-PackTunePopularFeed { throw 'feed asked' }
$staleRows = @(Get-PackTunePopularApps -CachePath $popOld -AllowStale)
$staleAsked = $false; try { $null = Get-PackTunePopularApps -CachePath $popOld } catch { $staleAsked = $true }
Test-Check 'popular: a three days old cache is shown at once when stale is allowed, a normal call asks the feed' (($staleRows.Count -eq 6) -and $staleAsked)
Remove-Item Function:\Get-PackTunePopularFeed
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
