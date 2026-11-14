<#
.SYNOPSIS
    Checks of the winget map (data\winget-map.json, Tools\Update-WingetMap.ps1) and its use in the app:
    schema of the file, valid ids, no duplicates, consistency with catalog.json, the matching rules on fake winget
    data (URL, names, publisher, variants, versioned ids, pre-release channels, review decisions), and the wiring
    (catalog fills gaps only, popular list prefers the map over the name match). No network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-WingetMap.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneWingetMap-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PSModulePath = (Join-Path $PSScriptRoot 'Fakes') + ';' + $env:PSModulePath

$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) {
    if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" }
}

. (Join-Path $repo 'PackTune-Main.ps1')
. (Join-Path $repo 'Tools\Update-WingetMap.ps1')

#region the file in the repo

$mapPath = Join-Path $repo 'data\winget-map.json'
$reviewPath = Join-Path $repo 'data\winget-map-review.json'
$raw = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8
$doc = $raw | ConvertFrom-Json
Test-Check 'map file: schema 1, generated date, apps and noEquivalent' ($doc.schema -eq 1 -and $doc.generated -match '^\d{4}-\d{2}-\d{2}$' -and $doc.apps -and $doc.noEquivalent)
$entries = @($doc.apps.PSObject.Properties)
$badEntry = @($entries | Where-Object {
        $v = $_.Value
        $_.Name -cne $_.Name.ToLower() -or $v.winget -notmatch $script:WingetIdPattern -or $v.winget -notmatch '^[A-Za-z0-9][A-Za-z0-9+-]*(\.[A-Za-z0-9][A-Za-z0-9+_-]*)+$' -or `
            [string]$v.confidence -notin 'high', 'reviewed' -or [string]$v.checked -notmatch '^\d{4}-\d{2}-\d{2}$' -or $null -eq $v.signals -or ($v.signals -is [string] -and -not $v.signals)
    })
Test-Check 'map file: every entry has a valid winget id (Publisher.Package), confidence high or reviewed, checked date, signals' ($entries.Count -ge 100 -and $badEntry.Count -eq 0) (($badEntry | ForEach-Object { $_.Name }) -join ',')
$keys = @([regex]::Matches($raw, '(?m)^\s+"([^"]+)":\s*\{\s*?
\s+"winget":') | ForEach-Object { $_.Groups[1].Value.ToLower() })
$dupes = @($keys | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
Test-Check 'map file: no duplicate Chocolatey id (case-insensitive)' ($keys.Count -eq $entries.Count -and $dupes.Count -eq 0) ($dupes -join ',')
$noEq = @($doc.noEquivalent.PSObject.Properties)
Test-Check 'map file: every no-equivalent entry has a reason and is not also mapped' (@($noEq | Where-Object { -not [string]$_.Value }).Count -eq 0 -and @($noEq | Where-Object { $doc.apps.PSObject.Properties[$_.Name] }).Count -eq 0)
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$notInMap = @($review.accept.PSObject.Properties | Where-Object { -not $doc.apps.PSObject.Properties[$_.Name.ToLower()] -or $doc.apps.PSObject.Properties[$_.Name.ToLower()].Value.winget -ine $_.Value.winget })
Test-Check 'review file: every accepted decision is in the map with that id' ($notInMap.Count -eq 0) (($notInMap | ForEach-Object { $_.Name }) -join ',')

# curated catalog: the map never disagrees with a catalog winget id (documented exceptions only)
$catalog = @(Get-Content -LiteralPath (Join-Path $repo 'catalog.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$allowedDifference = @('python3')   # the catalog pins Python 3.13, the map names the newest line
$differ = @($catalog | Where-Object { $_.winget -and $doc.apps.PSObject.Properties[$_.id.ToLower()] -and $doc.apps.PSObject.Properties[$_.id.ToLower()].Value.winget -ine $_.winget -and $_.id -notin $allowedDifference })
Test-Check 'curated: the map agrees with every catalog winget id (exceptions: python3)' ($differ.Count -eq 0) (($differ | ForEach-Object { "$($_.id): $($_.winget) vs $($doc.apps.PSObject.Properties[$_.id.ToLower()].Value.winget)" }) -join '; ')
Test-Check 'curated: catalog ids are unique and every winget id has a valid format' ((@($catalog | Group-Object { $_.id.ToLower() } | Where-Object Count -gt 1).Count -eq 0) -and (@($catalog | Where-Object { $_.winget -and $_.winget -notmatch $script:WingetIdPattern }).Count -eq 0))

#endregion

#region matching rules on fake data

function New-FakeRecord($Id, $Name, $Moniker = '', $Publisher = '') { [pscustomobject]@{ id = $Id; name = $Name; moniker = $Moniker; version = '1.0'; path = "manifests/x/$Id/1.0/hash"; tags = @(); commands = @(); publisher = $Publisher } }
function New-FakeItem($Id, $Title, $Authors, $Url, $Source = '') { [pscustomobject]@{ id = $Id; title = $Title; authors = $Authors; projectUrl = $Url; packageSourceUrl = $Source; tags = ''; summary = '' } }
$records = @(
    (New-FakeRecord 'Acme.Writer' 'Acme Writer' 'writer' 'acme')
    (New-FakeRecord 'Acme.Writer.Preview' 'Acme Writer Preview' '' 'acme')
    (New-FakeRecord 'Acme.Writer.ESR' 'Acme Writer ESR' '' 'acme')
    (New-FakeRecord 'Contoso.Browser' 'Contoso Browser' 'cb' 'contoso')
    (New-FakeRecord 'Other.Browser' 'Contoso Browser' '' 'other')
    (New-FakeRecord 'Vendor.Tool.2' 'Vendor Tool' '' 'vendor')
    (New-FakeRecord 'Vendor.Tool.3' 'Vendor Tool' '' 'vendor')
    (New-FakeRecord 'Someone.Zipper' 'Zipper' 'zipper' 'someone')
    (New-FakeRecord 'Real.Zipper' 'Zipper' 'zipper' 'real')
    (New-FakeRecord 'Net.Sharp' 'Sharp Pad' '' 'net')
)
$manifests = @{
    'Acme.Writer'          = @{ Name = 'Acme Writer'; PublisherName = 'Acme Inc'; PackageUrl = 'https://acme.example/writer'; PublisherUrl = 'https://acme.example' }
    'Acme.Writer.Preview'  = @{ Name = 'Acme Writer Preview'; PublisherName = 'Acme Inc'; PackageUrl = 'https://acme.example/writer'; PublisherUrl = 'https://acme.example' }
    'Acme.Writer.ESR'      = @{ Name = 'Acme Writer ESR'; PublisherName = 'Acme Inc'; PackageUrl = 'https://acme.example/writer'; PublisherUrl = 'https://acme.example' }
    'Contoso.Browser'      = @{ Name = 'Contoso Browser'; PublisherName = 'Contoso'; PackageUrl = 'https://www.contoso.example/browser/'; PublisherUrl = 'https://contoso.example' }
    'Other.Browser'        = @{ Name = 'Contoso Browser'; PublisherName = 'Other'; PackageUrl = 'https://other.example'; PublisherUrl = '' }
    'Vendor.Tool.2'        = @{ Name = 'Vendor Tool'; PublisherName = 'Vendor'; PackageUrl = 'https://vendor.example/tool'; PublisherUrl = '' }
    'Vendor.Tool.3'        = @{ Name = 'Vendor Tool'; PublisherName = 'Vendor'; PackageUrl = 'https://vendor.example/tool'; PublisherUrl = '' }
    'Someone.Zipper'       = @{ Name = 'Zipper'; PublisherName = 'Someone'; PackageUrl = 'https://someone.example/zipper'; PublisherUrl = '' }
    'Real.Zipper'          = @{ Name = 'Zipper'; PublisherName = 'Real'; PackageUrl = 'https://real.example/zipper'; PublisherUrl = '' }
    'Net.Sharp'            = @{ Name = 'Sharp Pad'; PublisherName = 'Net'; PackageUrl = 'https://github.com/net/sharp'; PublisherUrl = '' }
}
$provider = { param($Record) $m = $manifests[$Record.id]; if ($m) { [pscustomobject]$m } }
$items = @(
    (New-FakeItem 'acmewriter' 'Acme Writer' 'Acme Inc' 'https://acme.example/writer')
    (New-FakeItem 'contoso-browser' 'Contoso Browser' 'Contoso' 'https://www.contoso.example/browser')
    (New-FakeItem 'vendortool' 'Vendor Tool' 'Vendor' 'https://vendor.example/tool/')
    (New-FakeItem 'zipper' 'Zipper' 'Somebody' 'https://zipper.example')
    (New-FakeItem 'sharppad' 'Sharp Pad' 'Net Team' 'https://github.com/net/sharp.git')
    (New-FakeItem 'unknownthing' 'Unknown Thing' 'Nobody' 'https://nowhere.example')
    (New-FakeItem 'acme.extension' 'Acme Extension' 'Acme' 'https://acme.example')
    (New-FakeItem 'kb123456' 'Windows Update' 'Microsoft' 'https://microsoft.example')
    (New-FakeItem 'ghost' 'Ghost App' 'Ghost' 'https://ghost.example')
    (New-FakeItem 'reviewed' 'Reviewed App' 'R' 'https://r.example')
    (New-FakeItem 'rejectme' 'Contoso Browser' 'Contoso' 'https://www.contoso.example/browser')
)
$fakeReview = '{ "accept": { "ghost": { "winget": "Acme.Writer", "note": "by hand" }, "missing": { "winget": "No.SuchId", "note": "" } }, "noEquivalent": { "reviewed": "decided by a person" }, "reject": { "rejectme": ["Contoso.Browser"] } }' | ConvertFrom-Json
$build = Invoke-WingetMapBuild -Items $items -IndexRecords $records -Review $fakeReview -ManifestProvider $provider -Checked '2026-01-01'

$a = $build.Map['acmewriter']
Test-Check 'rules: same project URL, same name and publisher -> accepted with the plain id (Preview and ESR are variants)' ($a -and $a.winget -eq 'Acme.Writer' -and $a.confidence -eq 'high' -and $a.signals -contains 'url-exact' -and $a.signals -contains 'name-exact' -and $a.signals -contains 'publisher' -and $a.checked -eq '2026-01-01') ($a | ConvertTo-Json -Compress)
Test-Check 'rules: URL with www and trailing slash is the same URL' ($build.Map['contoso-browser'].winget -eq 'Contoso.Browser')
Test-Check 'rules: a package with the same name from another publisher does not beat the one with the matching URL' ($build.Map['contoso-browser'].winget -ne 'Other.Browser')
Test-Check 'rules: versioned ids of one product -> the highest line, noted' ($build.Map['vendortool'].winget -eq 'Vendor.Tool.3' -and $build.Map['vendortool'].note -match 'highest') ($build.Map['vendortool'] | ConvertTo-Json -Compress)
Test-Check 'rules: only the name matches (two publishers, no URL, no publisher) -> candidate, not accepted' (-not $build.Map.Contains('zipper') -and $build.Candidates.Contains('zipper') -and @($build.Candidates['zipper']).Count -ge 2)
Test-Check 'rules: GitHub owner/repo equal (.git ignored) -> accepted' ($build.Map['sharppad'].winget -eq 'Net.Sharp' -and $build.Map['sharppad'].signals -contains 'url-repo')
Test-Check 'rules: nothing similar -> nothing found, not in the map' (-not $build.Map.Contains('unknownthing') -and $build.None.Contains('unknownthing'))
Test-Check 'rules: Chocolatey extension and KB packages -> no equivalent with reason' ($build.NoEquivalent['acme.extension'] -match 'extension' -and $build.NoEquivalent['kb123456'] -match 'KB')
Test-Check 'review: accept wins, a missing id is ignored, noEquivalent wins, reject removes a candidate' ($build.Map['ghost'].winget -eq 'Acme.Writer' -and $build.Map['ghost'].confidence -eq 'reviewed' -and -not $build.Map.Contains('missing') -and $build.NoEquivalent['reviewed'] -eq 'decided by a person' -and $build.Map['rejectme'].winget -ne 'Contoso.Browser') ($build.Map['rejectme'] | ConvertTo-Json -Compress)

$pkg = [pscustomobject]@{ Id = 'app.install'; Title = 'App (Install)'; Authors = 'X'; ProjectUrl = 'https://github.com/x/app'; PackageSourceUrl = 'https://github.com/chocolatey-community/chocolatey-packages/tree/master/automatic/app' }
$cand = [pscustomobject]@{ Id = 'X.App'; Name = 'App'; Moniker = 'app'; Publisher = 'x'; PackageUrl = 'https://github.com/x/app'; PublisherUrl = ''; PublisherName = 'X' }
$score = Get-WingetMapScore -Package $pkg -Candidate $cand
Test-Check 'score: (Install) suffix and .install are ignored, the Chocolatey community repository is no product URL' ($score.Signals -contains 'url-repo' -and $score.Signals -contains 'name-exact' -and $score.Identity)
$weak = Get-WingetMapScore -Package $pkg -Candidate ([pscustomobject]@{ Id = 'Y.Other'; Name = 'Other'; Moniker = ''; Publisher = 'y'; PackageUrl = 'https://github.com/y/other'; PublisherUrl = ''; PublisherName = '' })
Test-Check 'score: unrelated package scores nothing and has no identity' ($weak.Score -eq 0 -and -not $weak.Identity)
Test-Check 'file text: the map text has schema, apps and no-equivalent reasons' ((Get-WingetMapFileText -Build $build -Checked '2026-01-01' -IndexInfo 'fake') -match '"schema":\s*1' -and (Get-WingetMapFileText -Build $build -Checked '2026-01-01' -IndexInfo 'fake') -match 'Chocolatey extension')

#endregion

#region use in the app

$fakeMap = Join-Path $work 'fake-map.json'
@{ schema = 1; apps = [ordered]@{
        mappedtool = @{ winget = 'Mapped.Tool'; confidence = 'high'; checked = '2026-01-01'; signals = @('url-exact') }
        reviewedtool = @{ winget = 'Reviewed.Tool'; confidence = 'reviewed'; checked = '2026-01-01'; signals = @('review') }
        weaktool = @{ winget = 'Weak.Tool'; confidence = 'candidate'; checked = '2026-01-01'; signals = @() }
        badid = @{ winget = 'bad id!'; confidence = 'high'; checked = '2026-01-01'; signals = @() }
        notepad3 = @{ winget = 'Mapped.Notepad3'; confidence = 'high'; checked = '2026-01-01'; signals = @() }
    } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fakeMap -Encoding UTF8
$realPath = $script:WingetMapPath
$script:WingetMapPath = $fakeMap; $script:WingetMapLoaded = $null
Test-Check 'wiring: mapped id by Chocolatey id (case-insensitive), reviewed counts, candidate and invalid ids do not' ((Get-PackTuneMappedWingetId 'MappedTool') -eq 'Mapped.Tool' -and (Get-PackTuneMappedWingetId 'reviewedtool') -eq 'Reviewed.Tool' -and $null -eq (Get-PackTuneMappedWingetId 'weaktool') -and $null -eq (Get-PackTuneMappedWingetId 'badid') -and $null -eq (Get-PackTuneMappedWingetId 'nothing') -and $null -eq (Get-PackTuneMappedWingetId ''))
$script:WingetMapPath = Join-Path $work 'missing.json'; $script:WingetMapLoaded = $null
Test-Check 'wiring: a missing map file gives no ids and no error' ($null -eq (Get-PackTuneMappedWingetId 'mappedtool') -and (Get-PackTuneWingetMap).Count -eq 0)
$broken = Join-Path $work 'broken.json'; Set-Content -LiteralPath $broken -Value '{ not json'
$script:WingetMapPath = $broken; $script:WingetMapLoaded = $null
Test-Check 'wiring: a broken map file gives no ids and no error' ($null -eq (Get-PackTuneMappedWingetId 'mappedtool'))

# catalog: the winget id of catalog.json stays, the map fills only a gap
$fullCatalog = @(Get-Content -LiteralPath (Join-Path $repo 'catalog.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ })
$withId = $fullCatalog | Where-Object { $_.winget } | Select-Object -First 1
$noId = $fullCatalog | Where-Object { -not $_.winget } | Select-Object -First 1
$catMap = Join-Path $work 'cat-map.json'
@{ schema = 1; apps = [ordered]@{
        ($withId.id.ToLower()) = @{ winget = 'Wrong.Override'; confidence = 'high'; checked = '2026-01-01'; signals = @() }
        ($noId.id.ToLower()) = @{ winget = 'Filled.Gap'; confidence = 'high'; checked = '2026-01-01'; signals = @() }
    } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $catMap -Encoding UTF8
$script:WingetMapPath = $catMap; $script:WingetMapLoaded = $null
$cat = @(Get-PackTuneCatalog)
Test-Check 'catalog: the catalog winget id stays authoritative, the map fills a gap' (($cat | Where-Object Id -eq $withId.id).WingetId -eq $withId.winget -and ($cat | Where-Object Id -eq $noId.id).WingetId -eq 'Filled.Gap') "$($withId.id) $($noId.id)"

# popular list: the map before the strict name match, the strict match for the rest
function New-FeedPackage($Name, $Title, $Downloads, $Tags = '', $Authors = 'Someone', $Site = 'https://example.org', $Summary = 'S', $Version = '1.0') {
    [pscustomobject]@{ Name = $Name; Title = $Title; Version = $Version; Summary = $Summary; Description = "Description of $Name"; Authors = $Authors; SoftwareSite = $Site; SoftwareLicense = $null; IconUrl = $null; Downloads = $Downloads; Tags = $Tags; IsLatest = $true; LicenseNote = $null }
}
$feed = @(
    (New-FeedPackage 'mappedtool' 'Mapped Tool' 900)
    (New-FeedPackage 'notepad3' 'Notepad3' 800 'editor' 'Rizonesoft' 'https://www.rizonesoft.com')
    (New-FeedPackage 'akelpad' 'AkelPad' 700 'editor' 'Alexey')
    (New-FeedPackage 'plain' 'Plain Thing' 600)
)
$script:Asked = New-Object System.Collections.ArrayList
$finder = { param($Term) [void]$script:Asked.Add($Term); if ($Term -eq 'AkelPad') { [pscustomobject]@{ Name = 'Alexey.AkelPad'; Title = 'AkelPad'; Version = '4.9' } } }
$script:WingetMapPath = $fakeMap; $script:WingetMapLoaded = $null
$meta = @{ 'winget:mapped.tool' = [pscustomobject]@{ Version = '7.7' } }
$rows = @(Get-PackTunePopularApps -FeedPackages $feed -WingetFinder $finder -Cache $meta)
$mt = $rows | Where-Object ChocoId -eq 'mappedtool'; $n3 = $rows | Where-Object ChocoId -eq 'notepad3'; $ak = $rows | Where-Object ChocoId -eq 'akelpad'; $pl = $rows | Where-Object ChocoId -eq 'plain'
Test-Check 'popular: a mapped package gets its winget id and the version the cache knows, without a winget search' ($mt.WingetId -eq 'Mapped.Tool' -and $mt.WingetVersion -eq '7.7' -and ($mt.Sources -join ',') -eq 'Chocolatey,Winget' -and $script:Asked -notcontains 'Mapped Tool')
Test-Check 'popular: the map wins over the strict name match' ($n3.WingetId -eq 'Mapped.Notepad3' -and $script:Asked -notcontains 'Notepad3')
Test-Check 'popular: the strict name match stays the fallback, the rest is Chocolatey only' ($ak.WingetId -eq 'Alexey.AkelPad' -and -not $pl.WingetId -and ($pl.Sources -join ',') -eq 'Chocolatey')
$nw = @(Get-PackTunePopularApps -FeedPackages $feed -NoWinget)
Test-Check 'popular: -NoWinget ignores the map' (@($nw | Where-Object WingetId).Count -eq 0)
$script:WingetMapPath = $realPath; $script:WingetMapLoaded = $null
Test-Check 'wiring: the shipped map is found by the default path and has entries' ((Get-PackTuneWingetMap).Count -ge 100 -and (Get-PackTuneMappedWingetId 'vlc') -eq 'VideoLAN.VLC')

#endregion

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
