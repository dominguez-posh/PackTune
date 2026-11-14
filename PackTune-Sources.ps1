<#
    One app list for both sources (Chocolatey and winget), (the runtime dependency app is in PackTune-Runtime.ps1).
    Loaded by PackTune-Main.ps1, uses its helpers (catalog, feeds, Invoke-IntuneModule, packaging).

    A "row" is one app as a person sees it: the same software, with the id it has in each source, the current
    version from each feed, the sources it is available from and the recommended source (the higher version).
    The package infos come from the same cache the interface keeps (feedcache.json, key "<chocolatey id>" and
    "winget:<id>", all lower case): pass it as -Cache (a hashtable of these entries) and nothing is asked twice;
    entries that are missing are read from the feeds and put into the cache.
#>

$script:Sources = "Chocolatey", "Winget"
$script:SourceFilters = "All", "Winget", "Chocolatey", "Both"

#region versions and recommendation

function ConvertTo-SourceVersionParts {
    param([string]$Text)
    # "1.2.3", "v1.2.3-beta", "26.05" -> numbers; anything that does not start with numbers is unknown ($null)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $Core = (($Text.Trim() -replace '^[vV]', '') -split '[-+\s]')[0]
    if ($Core -notmatch '^\d+(\.\d+)*$') { return $null }
    return @($Core.Split('.') | ForEach-Object { [decimal]$_ })
}

function Compare-SourceVersion {
    # Part by part as numbers (1.10 > 1.9, 1.2 = 1.2.0). Returns 1, 0, -1, or $null when one of them is unknown.
    param([string]$A, [string]$B)
    $PartsA = ConvertTo-SourceVersionParts $A
    $PartsB = ConvertTo-SourceVersionParts $B
    if ($null -eq $PartsA -or $null -eq $PartsB) { return $null }
    $Length = [Math]::Max($PartsA.Count, $PartsB.Count)
    for ($i = 0; $i -lt $Length; $i++) {
        $X = if ($i -lt $PartsA.Count) { $PartsA[$i] } else { 0 }
        $Y = if ($i -lt $PartsB.Count) { $PartsB[$i] } else { 0 }
        if ($X -gt $Y) { return 1 }
        if ($X -lt $Y) { return -1 }
    }
    return 0
}

function Get-RecommendedSource {
    <#
        Two sources: the one with the higher version is recommended and marked; equal or unknown versions give no
        recommendation. One source only: that source, but not marked (there is nothing to compare).
    #>
    param([bool]$HasChocolatey, [bool]$HasWinget, [string]$ChocolateyVersion, [string]$WingetVersion)
    if ($HasChocolatey -and -not $HasWinget) { return [pscustomobject]@{ Source = "Chocolatey"; Marked = $false } }
    if ($HasWinget -and -not $HasChocolatey) { return [pscustomobject]@{ Source = "Winget"; Marked = $false } }
    if (-not $HasChocolatey -and -not $HasWinget) { return [pscustomobject]@{ Source = $null; Marked = $false } }
    $Compare = Compare-SourceVersion -A $ChocolateyVersion -B $WingetVersion
    if ($Compare -eq 1) { return [pscustomobject]@{ Source = "Chocolatey"; Marked = $true } }
    if ($Compare -eq -1) { return [pscustomobject]@{ Source = "Winget"; Marked = $true } }
    return [pscustomobject]@{ Source = $null; Marked = $false }
}#Which source to recommend for an app

function Get-PackTuneDefaultSource {
    # What a deployment uses when nobody chose: the recommended source, else the preferred source of the settings
    # (when the app has it), else the one source the app has
    param([Parameter(Mandatory = $true)]$Row, [string]$Preferred = $script:Settings.Source)
    if ($Row.Recommended) { return $Row.Recommended }
    $Available = @($Row.Sources)
    if ($Preferred -and $Preferred -in $Available) { return $Preferred }
    return ($Available | Select-Object -First 1)
}#Source a deployment uses by default

#endregion

#region package infos from cache or feed

function Get-SourceCacheKey([string]$Source, [string]$Id) {
    if ($Source -eq "Winget") { return "winget:$($Id.ToLower())" }
    return $Id.ToLower()
}

function Resolve-PackTuneSourceInfo {
    <#
        Version of one package in one source: from the cache, otherwise from the feed (and into the cache).
        Available = $false only when the source says it has no such package; an unreachable feed leaves the package
        available with an unknown version.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Chocolatey", "Winget")][string]$Source,
        [Parameter(Mandatory = $true)][string]$Id,
        [hashtable]$Cache,
        [switch]$NoFetch
    )
    $Key = Get-SourceCacheKey $Source $Id
    $Entry = if ($Cache) { $Cache[$Key] } else { $null }
    if ($Entry -and ($Entry.Found -or $Entry.NotFound)) {
        return [pscustomobject]@{ Source = $Source; Id = $Id; Available = [bool]$Entry.Found; Version = $(if ($Entry.Found) { [string]$Entry.Version } else { $null }); Title = $Entry.Title; FromCache = $true }
    }
    if ($NoFetch) { return [pscustomobject]@{ Source = $Source; Id = $Id; Available = $true; Version = $null; Title = $null; FromCache = $false } }
    try {
        $Info = if ($Source -eq "Winget") { Get-WingetInfo -WingetId $Id } else { Get-ChocoInfo -ChocoName $Id }
        if ($Cache) {
            $Cache[$Key] = [pscustomobject]@{
                Fetched = (Get-Date).ToString("o"); Found = $true; Name = $Info.Name; Title = $Info.Title; Version = $Info.Version
                Summary = $Info.Summary; Description = $Info.Description; Authors = $Info.Authors; IconUrl = $Info.IconUrl
                ProjectUrl = $Info.SoftwareSite; LicenseUrl = $Info.SoftwareLicense; Downloads = $Info.Downloads; LicenseNote = $Info.LicenseNote
                License = $Info.License; Partial = $false
            }
        }
        return [pscustomobject]@{ Source = $Source; Id = $Id; Available = $true; Version = [string]$Info.Version; Title = $Info.Title; FromCache = $false }
    }
    catch {
        $NotFound = $_.Exception.Message -like "*was not found*"
        if ($Cache -and $NotFound) { $Cache[$Key] = [pscustomobject]@{ Fetched = (Get-Date).ToString("o"); Found = $false; NotFound = $true; Name = $Id; Error = $_.Exception.Message } }
        return [pscustomobject]@{ Source = $Source; Id = $Id; Available = (-not $NotFound); Version = $null; Title = $null; FromCache = $false }
    }
}#Version of a package from the cache or the feed

function New-PackTuneSourceRow {
    # Builds the row of one app from what is known; only the ids that exist count as sources
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Category,
        [string]$CatalogId,
        [string]$ChocoId,
        [string]$WingetId,
        [string]$ChocoVersion,
        [string]$WingetVersion,
        [bool]$ChocoAvailable = $true,
        [bool]$WingetAvailable = $true
    )
    $HasChoco = [bool]$ChocoId -and $ChocoAvailable
    $HasWinget = [bool]$WingetId -and $WingetAvailable
    $Recommendation = Get-RecommendedSource -HasChocolatey $HasChoco -HasWinget $HasWinget -ChocolateyVersion $ChocoVersion -WingetVersion $WingetVersion
    $Row = [pscustomobject]@{
        Name              = $Name
        Category          = $Category
        CatalogId         = $CatalogId
        ChocoId           = $(if ($HasChoco) { $ChocoId } else { $null })
        WingetId          = $(if ($HasWinget) { $WingetId } else { $null })
        ChocoVersion      = $(if ($HasChoco) { $ChocoVersion } else { $null })
        WingetVersion     = $(if ($HasWinget) { $WingetVersion } else { $null })
        Sources           = @(@($(if ($HasChoco) { "Chocolatey" }), $(if ($HasWinget) { "Winget" })) | Where-Object { $_ })
        Recommended       = $Recommendation.Source
        RecommendedMarked = $Recommendation.Marked
        Source            = $null
    }
    # Source = what a deployment of this row uses (the person can change it per app)
    $Row.Source = Get-PackTuneDefaultSource -Row $Row
    return $Row
}#One app with the ids, versions and recommendation of both sources

function Get-PackTuneSourceApps {
    <#
        The curated catalog as one list: per app the sources it is available from, the current version of each
        (cache, then feed) and the recommended source. -NoFetch uses only what is in the cache.
    #>
    param([hashtable]$Cache, [switch]$NoFetch, [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All")
    $Rows = foreach ($Entry in @(Get-PackTuneCatalog)) {
        $Choco = if ($Entry.Id) { Resolve-PackTuneSourceInfo -Source Chocolatey -Id $Entry.Id -Cache $Cache -NoFetch:$NoFetch }
        $Winget = if ($Entry.WingetId) { Resolve-PackTuneSourceInfo -Source Winget -Id $Entry.WingetId -Cache $Cache -NoFetch:$NoFetch }
        New-PackTuneSourceRow -Name $Entry.Name -Category $Entry.Category -CatalogId $Entry.Id -ChocoId $Entry.Id -WingetId $Entry.WingetId `
            -ChocoVersion $(if ($Choco) { $Choco.Version }) -WingetVersion $(if ($Winget) { $Winget.Version }) `
            -ChocoAvailable $(if ($Choco) { $Choco.Available } else { $false }) -WingetAvailable $(if ($Winget) { $Winget.Available } else { $false })
    }
    return @(Select-PackTuneSourceApps -Apps @($Rows) -Filter $Filter)
}#The catalog with both sources per app

function Select-PackTuneSourceApps {
    <#
        Filter of the app list: All, Winget (apps only winget has), Chocolatey (apps only Chocolatey has),
        Both (apps available from both sources).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Apps, [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All")
    $Apps = @($Apps)
    switch ($Filter) {
        "Winget" { return @($Apps | Where-Object { @($_.Sources).Count -eq 1 -and $_.Sources -contains "Winget" }) }
        "Chocolatey" { return @($Apps | Where-Object { @($_.Sources).Count -eq 1 -and $_.Sources -contains "Chocolatey" }) }
        "Both" { return @($Apps | Where-Object { @($_.Sources).Count -eq 2 }) }
        default { return $Apps }
    }
}#All / winget only / Chocolatey only / both

#endregion

#region search across both sources

function Search-PackTuneApps {
    <#
        Searches Chocolatey and winget and merges the hits per app: hits that belong to the same catalog entry (its
        Chocolatey id and its winget id) become one row, everything else stays a row of its own. The other source of a
        catalog app is looked up for its version even when the search did not return it. A source that cannot be
        reached gives a warning; the other one still answers.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SearchPattern,
        [int]$Top = 30,
        [hashtable]$Cache,
        [switch]$NoFetch,
        [ValidateSet("All", "Winget", "Chocolatey", "Both")][string]$Filter = "All"
    )
    $Catalog = @(Get-PackTuneCatalog)
    $ByChoco = @{}; $ByWinget = @{}
    foreach ($Entry in $Catalog) {
        if ($Entry.Id) { $ByChoco[$Entry.Id.ToLower()] = $Entry }
        if ($Entry.WingetId) { $ByWinget[$Entry.WingetId.ToLower()] = $Entry }
    }
    $ChocoHits = @(); $WingetHits = @()
    try { $ChocoHits = @(Search-ChocoPackage -SearchPattern $SearchPattern -Top $Top) } catch { Write-Warning "Chocolatey search failed: $($_.Exception.Message)" }
    try { $WingetHits = @(Search-WingetPackage -SearchPattern $SearchPattern -Top $Top) } catch { Write-Warning "winget search failed: $($_.Exception.Message)" }

    # Merge: key = catalog entry, or the package of its own source
    $Merged = [ordered]@{}
    $Get = {
        param($Key)
        if (-not $Merged.Contains($Key)) { $Merged[$Key] = @{ Entry = $null; ChocoId = $null; ChocoVersion = $null; WingetId = $null; WingetVersion = $null; Title = $null; Downloads = $null; Tags = $null; IconUrl = $null } }
        $Merged[$Key]
    }
    foreach ($Hit in $ChocoHits) {
        $Entry = $ByChoco[([string]$Hit.Name).ToLower()]
        $Slot = & $Get $(if ($Entry) { "catalog:$($Entry.Id.ToLower())" } else { "chocolatey:$(([string]$Hit.Name).ToLower())" })
        $Slot.Entry = $Entry; $Slot.ChocoId = $Hit.Name; $Slot.ChocoVersion = $Hit.Version; if (-not $Slot.Title) { $Slot.Title = $Hit.Title }
        $Slot.Downloads = $Hit.Downloads; $Slot.Tags = $Hit.Tags; $Slot.IconUrl = $Hit.IconUrl
        if ($Entry) { $Slot.WingetId = $Entry.WingetId }
    }
    foreach ($Hit in $WingetHits) {
        $Entry = $ByWinget[([string]$Hit.Name).ToLower()]
        $Slot = & $Get $(if ($Entry) { "catalog:$($Entry.Id.ToLower())" } else { "winget:$(([string]$Hit.Name).ToLower())" })
        $Slot.Entry = $Entry; $Slot.WingetId = $Hit.Name; $Slot.WingetVersion = $Hit.Version; if (-not $Slot.Title) { $Slot.Title = $Hit.Title }
        if ($Entry) { $Slot.ChocoId = $Entry.Id }
    }

    $Rows = foreach ($Slot in $Merged.Values) {
        # The other source of a catalog app: its version from cache or feed
        $ChocoAvailable = $true; $WingetAvailable = $true
        if ($Slot.ChocoId -and -not $Slot.ChocoVersion) {
            $Info = Resolve-PackTuneSourceInfo -Source Chocolatey -Id $Slot.ChocoId -Cache $Cache -NoFetch:$NoFetch
            $Slot.ChocoVersion = $Info.Version; $ChocoAvailable = $Info.Available
        }
        if ($Slot.WingetId -and -not $Slot.WingetVersion) {
            $Info = Resolve-PackTuneSourceInfo -Source Winget -Id $Slot.WingetId -Cache $Cache -NoFetch:$NoFetch
            $Slot.WingetVersion = $Info.Version; $WingetAvailable = $Info.Available
        }
        $Name = if ($Slot.Entry) { $Slot.Entry.Name } elseif ($Slot.Title) { $Slot.Title } elseif ($Slot.ChocoId) { $Slot.ChocoId } else { $Slot.WingetId }
        $Row = New-PackTuneSourceRow -Name $Name -Category $(if ($Slot.Entry) { $Slot.Entry.Category }) -CatalogId $(if ($Slot.Entry) { $Slot.Entry.Id }) `
            -ChocoId $Slot.ChocoId -WingetId $Slot.WingetId -ChocoVersion $Slot.ChocoVersion -WingetVersion $Slot.WingetVersion `
            -ChocoAvailable $ChocoAvailable -WingetAvailable $WingetAvailable
        # Relevance: the Chocolatey download count (also for a winget package matched to it); unknown = -1
        $Count = -1.0
        $Raw = $Slot.Downloads
        if ($null -eq $Raw -and $Cache -and $Slot.ChocoId) { $Known = $Cache[(Get-SourceCacheKey "Chocolatey" $Slot.ChocoId)]; if ($Known) { $Raw = $Known.Downloads } }
        $Parsed = 0.0
        if ($null -ne $Raw -and [double]::TryParse([string]$Raw, [ref]$Parsed)) { $Count = $Parsed }
        $Row | Add-Member -NotePropertyName Downloads -NotePropertyValue $Count -Force
        $Row | Add-Member -NotePropertyName Tags -NotePropertyValue ([string]$Slot.Tags) -Force
        $Row | Add-Member -NotePropertyName IconUrl -NotePropertyValue ([string]$Slot.IconUrl) -Force
        $Row
    }
    # Most relevant first: Chocolatey download count, packages without a count (winget only) after them, then by name
    $Sorted = @(Select-PackTuneSourceApps -Apps @($Rows) -Filter $Filter | Sort-Object -Property @{ Expression = { $_.Downloads }; Descending = $true }, @{ Expression = { $_.Name } })
    return $Sorted
}#Search in both repositories, one row per app

#endregion

#region deploy per source

function New-PackTuneSourceApplication {
    <#
        Deploys apps of the merged list, each from its own source: -Source (all apps), else the Source of the row
        (default = recommended source, else the preferred source of the settings). -Parameters are handed on to
        New-PackTuneChocolateyApp / New-PackTuneWingetApp (Assignment, UpdateMode, Version, ...).
        Returns the Intune app ids.
    #>
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]$App,
        [ValidateSet("Chocolatey", "Winget")][string]$Source,
        [hashtable]$Parameters = @{}
    )
    process {
        foreach ($Row in @($App)) {
            $Use = if ($Source) { $Source } elseif ($Row.Source) { $Row.Source } else { Get-PackTuneDefaultSource -Row $Row }
            if ($Use -eq "Winget") {
                if (-not $Row.WingetId) { Write-Error "$($Row.Name) is not available from winget"; continue }
                New-PackTuneWingetApp -WingetId $Row.WingetId @Parameters
            }
            elseif ($Use -eq "Chocolatey") {
                if (-not $Row.ChocoId) { Write-Error "$($Row.Name) is not available from Chocolatey"; continue }
                New-PackTuneChocolateyApp -ChocoName $Row.ChocoId @Parameters
            }
            else { Write-Error "$($Row.Name) has no source to deploy from" }
        }
    }
}#Deploys apps, each from the chosen source

#endregion


#region popular Chocolatey packages

# Infrastructure and library packages that nobody deploys as an app (they are pulled in as dependencies)
$script:PopularSkipIds = '^(chocolatey|chocolatey[-.].+|.+\.extension|.+\.template|.+\.commandline|kb\d+|flashplayer.*|adobeshockwaveplayer|silverlight|visualstudio-installer)$'
# Tag words to category, first match wins; the categories are those of catalog.json, everything else is "Other"
$script:PopularCategories = @(
    @('Browsers', '\b(browser|web-browser|firefox|chromium)\b'),
    @('Office & PDF', '\b(pdf|office|document|documents|spreadsheet|ebook|reader)\b'),
    @('Remote & Network', '\b(ssh|sftp|ftp|vpn|remote|rdp|network|networking|telnet|putty|wifi|dns|proxy)\b'),
    @('Runtimes', '\b(runtime|jre|jdk|java|dotnet|\.net|framework|vcredist|redistributable|python|nodejs|node)\b'),
    @('Developer', '\b(developer|development|programming|ide|editor|git|sdk|compiler|code|devops|docker|database|sql|api|debug)\b'),
    @('Media & Creative', '\b(audio|video|music|media|player|image|photo|graphics|design|3d|recorder|streaming|screenshot|codec|converter)\b'),
    @('Communication', '\b(chat|messenger|communication|email|mail|conferencing|meeting|voip|irc)\b'),
    @('Utilities', '\b(utility|utilities|archive|zip|compression|cleaner|launcher|clipboard|file|search|manager)\b'),
    @('Admin tools', '\b(admin|sysadmin|system|monitoring|backup|disk|partition|sysinternals|diagnostic|benchmark|hardware|tool|tools)\b')
)

function Get-PackTunePopularCategory {
    # Category from the package tags (space separated); "Other" when no word matches
    param([string]$Tags)
    $Text = ([string]$Tags).ToLower()
    foreach ($Rule in $script:PopularCategories) { if ($Text -match $Rule[1]) { return $Rule[0] } }
    return "Other"
}#Category of a package from its tags

function ConvertTo-PackTuneComparable {
    param([string]$Text)
    $Text = ([string]$Text) -replace '\s*\((Install|Portable)\)\s*$', ''
    return ($Text.ToLower() -replace '[^a-z0-9]', '')
}

function Select-PackTunePopular {
    <#
        From packages in order of downloads (most first): the ones worth listing as apps. Dropped are ids that are not
        valid package ids, infrastructure and library packages, deprecated packages, x.install / x.portable when x is in
        the list too, and everything the curated catalog already has. At most -Top, order kept.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Packages, [object[]]$Catalog, [int]$Top = 200)
    if ($null -eq $Catalog) { $Catalog = @(Get-PackTuneCatalog) }
    $Known = @{}
    foreach ($Entry in @($Catalog)) { if ($Entry.Id) { $Known[([string]$Entry.Id).ToLower()] = $true } }
    $Ids = @{}; foreach ($P in @($Packages)) { if ($P.Name) { $Ids[([string]$P.Name).ToLower()] = $true } }
    $Kept = New-Object System.Collections.ArrayList
    foreach ($P in @($Packages)) {
        $Id = [string]$P.Name
        if ($Id -notmatch $script:WingetIdPattern) { continue }
        $Lower = $Id.ToLower()
        if ($Lower -match $script:PopularSkipIds) { continue }
        if ("$($P.Title) $($P.Tags)" -match '(?i)\bdeprecated\b|\((remove only|final version - eol)\)|\beol\b|end of life' -or [string]$P.Description -match '(?i)^\s*\[?deprecated') { continue }
        $Base = $Lower -replace '\.(install|portable)$', ''
        if ($Base -ne $Lower -and $Ids.ContainsKey($Base)) { continue }
        if ($Known.ContainsKey($Lower) -or $Known.ContainsKey($Base) -or $Known.ContainsKey("$Base.install") -or $Known.ContainsKey("$Base.portable")) { continue }
        if ($Kept.Count -ge $Top) { break }
        [void]$Kept.Add($P)
    }
    return @($Kept)
}#Filters the packages by downloads for the popular list

function Get-PackTunePopularFeed {
    # One set of paged requests to the community feed, the query behind "choco search --order-by-popularity"
    # (Search() ordered by DownloadCount), 40 per page (the most the feed gives), a pause between pages; stops when -Top packages survive the filter
    param([int]$Top = 200, [int]$MaxPages = 16)
    $All = New-Object System.Collections.ArrayList
    for ($Page = 0; $Page -lt $MaxPages; $Page++) {
        $Query = "Search()?searchTerm=''&targetFramework=''&includePrerelease=false&`$filter=IsLatestVersion&`$orderby=DownloadCount%20desc,Id&`$skip=$($Page * 40)&`$top=40"
        $Batch = @(Invoke-ChocoFeed -Query $Query)
        foreach ($P in $Batch) { [void]$All.Add($P) }
        if ($Batch.Count -lt 40 -or @(Select-PackTunePopular -Packages @($All) -Top $Top).Count -ge $Top) { break }
        Start-Sleep -Seconds 1
    }
    return @($All)
}#Packages of the community feed by download count

function Resolve-PackTuneWingetMatch {
    <#
        The winget id of a Chocolatey package, only when it clearly is the same product: exactly one search hit whose
        name equals the package title (ignoring case, spaces and punctuation) and whose publisher (first part of the
        winget id) appears in the authors or the project URL of the package. Anything else: $null, never a guess.
    #>
    param([Parameter(Mandatory = $true)]$Package, [scriptblock]$Finder = { param($Term) Search-WingetPackage -SearchPattern $Term -Top 8 })
    $Title = ConvertTo-PackTuneComparable $(if ($Package.Title) { $Package.Title } else { $Package.Name })
    if ($Title.Length -lt 3) { return $null }
    $Context = ConvertTo-PackTuneComparable "$($Package.Authors) $($Package.SoftwareSite)"
    $Hits = @(& $Finder $(if ($Package.Title) { ([string]$Package.Title -replace '\s*\((Install|Portable)\)\s*$', '').Trim() } else { $Package.Name }))
    $Match = @($Hits | Where-Object {
            $Id = [string]$_.Name
            if ($Id -notmatch $script:WingetIdPattern) { return $false }
            $Publisher = ConvertTo-PackTuneComparable (($Id -split '\.')[0])
            $Publisher.Length -ge 3 -and $Context.Contains($Publisher) -and (ConvertTo-PackTuneComparable $_.Title) -eq $Title
        })
    if ($Match.Count -eq 1) { return $Match[0] }
    return $null
}#The winget package of a Chocolatey package when it is clearly the same

function Get-PackTunePopularApps {
    <#
        The popular list as rows of the app list (like Get-PackTuneSourceApps, with Popular = $true and Downloads):
        the top Chocolatey packages by downloads that the catalog does not have, with a winget id only when
        Resolve-PackTuneWingetMatch verifies it. Cached in -CachePath for -MaxAgeHours (the answer, including the
        matches, so the winget lookups run once a day); -Force ignores the cache. -Cache (the package info cache of the
        interface) gets the package infos of the list, so no lookup per package follows.
    #>
    param(
        [int]$Top = 200,
        [string]$CachePath,
        [int]$MaxAgeHours = 24,
        [switch]$Force,
        # Use the cache whatever its age (the list shows at once; a forced refresh follows)
        [switch]$AllowStale,
        [hashtable]$Cache,
        # Packages instead of the feed, and a winget search instead of the module (tests)
        [object[]]$FeedPackages,
        [scriptblock]$WingetFinder,
        [switch]$NoWinget
    )
    $Records = $null
    if ($CachePath -and -not $Force -and -not $FeedPackages -and (Test-Path -LiteralPath $CachePath)) {
        try {
            $Saved = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
            if ($AllowStale -or ([datetime]$Saved.Fetched) -gt (Get-Date).AddHours(-$MaxAgeHours)) { $Records = @($Saved.Apps) }
        }
        catch { Write-Verbose "The popular list cache is unreadable: $($_.Exception.Message)" }
    }
    if ($null -eq $Records) {
        $Raw = if ($FeedPackages) { @($FeedPackages) } else { @(Get-PackTunePopularFeed -Top $Top) }
        $Selected = @(Select-PackTunePopular -Packages $Raw -Top $Top)
        $CanMatch = -not $NoWinget
        if ($CanMatch -and -not $WingetFinder) { try { Assert-WingetClient } catch { $CanMatch = $false; Write-Warning "winget is not available, the popular apps are listed for Chocolatey only" } }
        $Records = foreach ($P in $Selected) {
            $Hit = $null
            if ($CanMatch) {
                try { $Hit = if ($WingetFinder) { Resolve-PackTuneWingetMatch -Package $P -Finder $WingetFinder } else { Resolve-PackTuneWingetMatch -Package $P } }
                catch { Write-Verbose "winget match of $($P.Name) failed: $($_.Exception.Message)" }
            }
            [pscustomobject]@{
                ChocoId = [string]$P.Name; Name = $(if ($P.Title) { ([string]$P.Title -replace '\s*\((Install|Portable)\)\s*$', '').Trim() } else { [string]$P.Name })
                Version = [string]$P.Version; Downloads = [string]$P.Downloads; Category = (Get-PackTunePopularCategory $P.Tags)
                WingetId = $(if ($Hit) { [string]$Hit.Name } else { $null }); WingetVersion = $(if ($Hit) { [string]$Hit.Version } else { $null })
                Title = [string]$P.Title; Summary = [string]$P.Summary; Description = [string]$P.Description; Authors = [string]$P.Authors
                IconUrl = [string]$P.IconUrl; ProjectUrl = [string]$P.SoftwareSite; LicenseUrl = [string]$P.SoftwareLicense; LicenseNote = [string]$P.LicenseNote
            }
        }
        $Records = @($Records)
        if ($CachePath) {
            try {
                New-Item -ItemType Directory -Path (Split-Path -Path $CachePath -Parent) -Force | Out-Null
                [pscustomobject]@{ Fetched = (Get-Date).ToString("o"); Apps = $Records } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $CachePath -Encoding UTF8
            }
            catch { Write-Verbose "The popular list could not be cached: $($_.Exception.Message)" }
        }
    }
    foreach ($R in $Records) {
        if ($Cache) {
            $Key = Get-SourceCacheKey "Chocolatey" $R.ChocoId
            $Cache[$Key] = [pscustomobject]@{
                Fetched = (Get-Date).ToString("o"); Found = $true; Name = $R.ChocoId; Title = $R.Title; Version = $R.Version; Summary = $R.Summary
                Description = $R.Description; Authors = $R.Authors; IconUrl = $R.IconUrl; ProjectUrl = $R.ProjectUrl; LicenseUrl = $R.LicenseUrl
                Downloads = $R.Downloads; LicenseNote = $R.LicenseNote; License = $null; Partial = $false
            }
        }
        $Row = New-PackTuneSourceRow -Name $R.Name -Category $R.Category -ChocoId $R.ChocoId -WingetId $R.WingetId -ChocoVersion $R.Version -WingetVersion $R.WingetVersion
        $Row | Add-Member -NotePropertyName Popular -NotePropertyValue $true -Force
        $Row | Add-Member -NotePropertyName Downloads -NotePropertyValue ([double]($R.Downloads -replace '[^\d]', '0')) -Force
        $Row
    }
}#The popular apps as rows of the app list

#endregion

#region my apps and refresh schedule

# Apps the user added from the search: %LOCALAPPDATA%\PackTune\my-apps.json (name, ids, category, date; no tenant data)
function Get-PackTuneMyAppsPath { Join-Path $script:WorkRoot "my-apps.json" }

function Test-PackTuneMyApp {
    # A valid entry: a name, at least one id of a source, every id a valid package id
    param($Entry)
    if (-not $Entry) { return $false }
    $Name = [string]$Entry.Name
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 150 -or $Name -match '[\x00-\x1F]') { return $false }
    $Choco = [string]$Entry.ChocoId; $Winget = [string]$Entry.WingetId
    if (-not $Choco -and -not $Winget) { return $false }
    if ($Choco -and $Choco -notmatch $script:WingetIdPattern) { return $false }
    if ($Winget -and $Winget -notmatch $script:WingetIdPattern) { return $false }
    return $true
}

function Get-PackTuneMyApps {
    # The saved apps; entries that are not valid are ignored (the file could have been edited by hand)
    param([string]$Path = (Get-PackTuneMyAppsPath))
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { $Saved = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | ForEach-Object { $_ }) } catch { Write-Warning "my-apps.json is unreadable: $($_.Exception.Message)"; return @() }
    @($Saved | Where-Object { Test-PackTuneMyApp $_ } | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; ChocoId = [string]$_.ChocoId; WingetId = [string]$_.WingetId; Category = $(if ($_.Category) { [string]$_.Category } else { "Other" }); Added = [string]$_.Added }
        })
}

function Save-PackTuneMyApps {
    param([object[]]$Apps, [string]$Path = (Get-PackTuneMyAppsPath))
    New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
    ConvertTo-Json -InputObject @($Apps | ForEach-Object { [ordered]@{ Name = $_.Name; ChocoId = $_.ChocoId; WingetId = $_.WingetId; Category = $_.Category; Added = $_.Added } }) -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-PackTuneMyApp {
    <#
        Adds an app to the list (persisted). Invalid ids or names are refused with an error. An app that is in the list
        or in the curated catalog already is not added twice (Added = $false in the answer).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ChocoId,
        [string]$WingetId,
        # Chocolatey tags: the category is derived from them, "Other" when nothing fits
        [string]$Tags,
        [string]$Path = (Get-PackTuneMyAppsPath)
    )
    $Entry = [pscustomobject]@{ Name = $Name.Trim(); ChocoId = $ChocoId; WingetId = $WingetId; Category = (Get-PackTunePopularCategory $Tags); Added = (Get-Date).ToString("yyyy-MM-dd") }
    if (-not (Test-PackTuneMyApp $Entry)) { throw "'$Name' cannot be added: a name and at least one valid package id are needed" }
    $Same = { param($A, $B) ($A.ChocoId -and $B.ChocoId -and $A.ChocoId -ieq $B.ChocoId) -or ($A.WingetId -and $B.WingetId -and $A.WingetId -ieq $B.WingetId) }
    $Existing = @(Get-PackTuneMyApps -Path $Path)
    $Hit = @($Existing | Where-Object { & $Same $_ $Entry }) | Select-Object -First 1
    if (-not $Hit) {
        $Hit = @(Get-PackTuneCatalog | Where-Object { & $Same ([pscustomobject]@{ ChocoId = $_.Id; WingetId = $_.WingetId }) $Entry }) | Select-Object -First 1
        if ($Hit) { return [pscustomobject]@{ Added = $false; Reason = "$($Hit.Name) is in the curated list already"; Entry = $null } }
    }
    else { return [pscustomobject]@{ Added = $false; Reason = "$($Hit.Name) is in your list already"; Entry = $Hit } }
    Save-PackTuneMyApps -Apps (@($Existing) + $Entry) -Path $Path
    return [pscustomobject]@{ Added = $true; Reason = ""; Entry = $Entry }
}#Adds an app of the search to my apps

function Remove-PackTuneMyApp {
    # Takes an app off the list again; nothing in Intune is touched
    param([string]$ChocoId, [string]$WingetId, [string]$Path = (Get-PackTuneMyAppsPath))
    $Existing = @(Get-PackTuneMyApps -Path $Path)
    $Keep = @($Existing | Where-Object { -not (($ChocoId -and $_.ChocoId -ieq $ChocoId) -or ($WingetId -and $_.WingetId -ieq $WingetId)) })
    if ($Keep.Count -ne $Existing.Count) { Save-PackTuneMyApps -Apps $Keep -Path $Path }
    return ($Existing.Count - $Keep.Count)
}

function Get-PackTuneMyAppRows {
    # The added apps as rows of the app list: versions from the cache (-NoFetch) or the feeds, Mine = $true
    param([hashtable]$Cache, [switch]$NoFetch, [string]$Path = (Get-PackTuneMyAppsPath))
    foreach ($A in @(Get-PackTuneMyApps -Path $Path)) {
        $Choco = if ($A.ChocoId) { Resolve-PackTuneSourceInfo -Source Chocolatey -Id $A.ChocoId -Cache $Cache -NoFetch:$NoFetch }
        $Winget = if ($A.WingetId) { Resolve-PackTuneSourceInfo -Source Winget -Id $A.WingetId -Cache $Cache -NoFetch:$NoFetch }
        $Row = New-PackTuneSourceRow -Name $A.Name -Category $A.Category -ChocoId $A.ChocoId -WingetId $A.WingetId `
            -ChocoVersion $(if ($Choco) { $Choco.Version }) -WingetVersion $(if ($Winget) { $Winget.Version }) `
            -ChocoAvailable $(if ($Choco) { $Choco.Available } else { $false }) -WingetAvailable $(if ($Winget) { $Winget.Available } else { $false })
        $Row | Add-Member -NotePropertyName Mine -NotePropertyValue $true -Force
        $Row
    }
}#My apps as rows of the app list

# The list refreshes itself at the start of the interface, but not more often than every hour (the Chocolatey feed limits
# the requests); "Refresh versions" always forces it. The stamp is written when a full refresh has finished.
function Get-PackTuneRefreshStampPath { Join-Path $script:WorkRoot "last-refresh.txt" }
function Test-PackTuneRefreshDue {
    param([int]$MinMinutes = 60, [string]$Path = (Get-PackTuneRefreshStampPath), [datetime]$Now = (Get-Date))
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try { $Last = [datetime]::Parse((Get-Content -LiteralPath $Path -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $true }
    return (($Now.ToUniversalTime() - $Last.ToUniversalTime()).TotalMinutes -ge $MinMinutes)
}
function Set-PackTuneRefreshStamp {
    param([string]$Path = (Get-PackTuneRefreshStampPath), [datetime]$Now = (Get-Date))
    New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Now.ToUniversalTime().ToString("o") -Encoding ASCII
}

#endregion
