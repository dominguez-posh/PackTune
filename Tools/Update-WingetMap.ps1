<#
.SYNOPSIS
    Regenerates data\winget-map.json (Chocolatey id -> winget id) and docs\winget-map-report.md.
    A development-time tool: the app only reads the finished file, nothing here runs at runtime.

.DESCRIPTION
    Apps: the curated catalog (catalog.json) and the popular list (top Chocolatey packages by downloads, the same
    functions the app uses: Get-PackTunePopularFeed, Select-PackTunePopular).
    Chocolatey side: title, authors, project URL, package source URL, tags, summary per package (community feed).
    winget side: the official source index (https://cdn.winget.microsoft.com/cache/source.msix, the package signature
    is verified first, index.db is dumped by Tools\Export-WingetIndex.py) and, for the candidates, the manifest of the
    latest version in microsoft/winget-pkgs (PackageName, Publisher, PackageUrl, PublisherUrl).
    Review decisions of a person live in data\winget-map-review.json and always win over the scoring.

    Scoring (Get-WingetMapScore), points per signal, the signals are listed in the map:
      url-repo    50  same GitHub owner/repo as the project URL (or the package source URL) and PackageUrl
      url-exact   50  same host and path of the project URL and PackageUrl
      url-host    25  same registered domain (project URL vs PackageUrl or PublisherUrl), not a code hosting site
      url-owner   15  same GitHub owner
      name-exact  35  normalized title equals the winget PackageName
      name-alias  25  normalized title or package id (without .install/.portable) equals the moniker, the last
                      part of the winget id or the PackageName
      name-part   10  one normalized name contains the other (5 or more characters)
      publisher   20  the winget publisher (or the first part of the id) appears in authors, title or project URL
    Accepted ("high"): score >= 55, an identity signal (url-repo, url-exact, or url-host together with a name
    signal, or name-exact together with publisher) and a lead of 15 points over the best candidate of another
    product. Score 35 to 54 (or no lead) is only a candidate for the review list. Known aliases and the review file
    are "reviewed". Packages without winget equivalent get a reason (rules in $script:NoEquivalentRules).

.PARAMETER WorkDir   download and cache folder (default: %TEMP%\PackTuneWingetMap)
.PARAMETER Offline   use the files in WorkDir only (choco.json, index.json, manifests\), no network
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tools\Update-WingetMap.ps1
#>
[CmdletBinding()]
param(
    [string]$OutPath,
    [string]$ReportPath,
    [string]$ReviewPath,
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'PackTuneWingetMap'),
    [int]$Top = 200,
    [switch]$Offline
)

$script:Repo = Split-Path $PSScriptRoot -Parent
if (-not $OutPath) { $OutPath = Join-Path $script:Repo 'data\winget-map.json' }
if (-not $ReportPath) { $ReportPath = Join-Path $script:Repo 'docs\winget-map-report.md' }
if (-not $ReviewPath) { $ReviewPath = Join-Path $script:Repo 'data\winget-map-review.json' }

$script:AcceptScore = 55
$script:CandidateScore = 35
$script:LeadScore = 15

#region matching (pure functions, no network)

function ConvertTo-WingetMapKey {
    # lower case letters and digits only; "(Install)", "(Portable)" and a trailing .install/.portable dropped first
    param([string]$Text)
    $Text = ([string]$Text) -replace '\s*\((Install|Portable)\)\s*$', '' -replace '\.(install|portable)$', ''
    return ($Text.ToLower() -replace '[^a-z0-9]', '')
}

function ConvertTo-WingetMapUrl {
    # host (without www.) and path (without trailing slash, query, fragment), lower case; $null when not a URL
    param([string]$Url)
    if ($Url -notmatch '^(?i)https?://([^/?#:]+)(?::\d+)?([^?#]*)') { return $null }
    $UrlHost = $Matches[1].ToLower() -replace '^www\.', ''
    $UrlPath = $Matches[2].ToLower().TrimEnd('/')
    return [pscustomobject]@{ Host = $UrlHost; Path = $UrlPath; Key = "$UrlHost$UrlPath" }
}

$script:CodeHosts = 'github.com', 'gitlab.com', 'sourceforge.net', 'bitbucket.org', 'codeplex.com', 'google.com', 'microsoft.com', 'github.io', 'wordpress.com', 'blogspot.com'

function Get-WingetMapDomain {
    param([string]$UrlHost)
    $Labels = @($UrlHost -split '\.')
    if ($Labels.Count -le 2) { return $UrlHost }
    # co.uk style second level domains keep three labels
    if ($Labels[-2] -in 'co', 'com', 'org', 'net', 'gov', 'ac' -and $Labels[-1].Length -eq 2) { return ($Labels[-3..-1] -join '.') }
    return ($Labels[-2..-1] -join '.')
}

function Get-WingetMapOwnerRepo {
    # github.com/owner/repo -> "owner/repo"; owner only -> "owner/"; other hosts $null
    param($Url)
    if (-not $Url -or $Url.Host -ne 'github.com') { return $null }
    $Parts = @($Url.Path.Trim('/') -split '/' | Where-Object { $_ })
    if ($Parts.Count -ge 2) { return "$($Parts[0])/$($Parts[1])" -replace '\.git$', '' }
    if ($Parts.Count -eq 1) { return "$($Parts[0])/" }
    return $null
}

function Get-WingetMapScore {
    <#
        Score of one winget candidate for one Chocolatey package, with the signals that count.
        $Package: Id, Title, Authors, ProjectUrl, PackageSourceUrl. $Candidate: Id, Name, Moniker, Publisher
        (normalized, from the index), PackageUrl, PublisherUrl, PublisherName (from the manifest, may be empty).
    #>
    param([Parameter(Mandatory = $true)]$Package, [Parameter(Mandatory = $true)]$Candidate)
    $Signals = New-Object System.Collections.ArrayList
    $Score = 0
    $Title = ConvertTo-WingetMapKey $(if ($Package.Title) { $Package.Title } else { $Package.Id })
    $BaseId = ConvertTo-WingetMapKey $Package.Id
    $WName = ConvertTo-WingetMapKey $Candidate.Name
    $WMoniker = ConvertTo-WingetMapKey $Candidate.Moniker
    $WLast = ConvertTo-WingetMapKey (([string]$Candidate.Id -split '\.')[-1])
    $WPackageUrl = ConvertTo-WingetMapUrl $Candidate.PackageUrl
    $WPublisherUrl = ConvertTo-WingetMapUrl $Candidate.PublisherUrl
    $CProject = ConvertTo-WingetMapUrl $Package.ProjectUrl
    $CSource = ConvertTo-WingetMapUrl $Package.PackageSourceUrl
    # the package source of most Chocolatey packages is the community repository, not the product
    if ($CSource -and ($CSource.Host -eq 'github.com') -and $CSource.Path -match '^/chocolatey(-community)?/') { $CSource = $null }

    # URL signals: the strongest one counts
    $Url = 0; $UrlName = $null
    foreach ($C in @($CProject, $CSource)) {
        if (-not $C -or -not $WPackageUrl) { continue }
        $COwnerRepo = Get-WingetMapOwnerRepo $C; $WOwnerRepo = Get-WingetMapOwnerRepo $WPackageUrl
        if ($COwnerRepo -and $WOwnerRepo -and $COwnerRepo -eq $WOwnerRepo -and -not $COwnerRepo.EndsWith('/')) { if ($Url -lt 50) { $Url = 50; $UrlName = 'url-repo' } }
        elseif ($C.Host -eq $WPackageUrl.Host -and $C.Path -eq $WPackageUrl.Path -and $C.Host -notin $script:CodeHosts) { if ($Url -lt 50) { $Url = 50; $UrlName = 'url-exact' } }
        elseif ($COwnerRepo -and $WOwnerRepo -and $COwnerRepo.Split('/')[0] -eq $WOwnerRepo.Split('/')[0]) { if ($Url -lt 15) { $Url = 15; $UrlName = 'url-owner' } }
        elseif ($C.Host -notin $script:CodeHosts -and (Get-WingetMapDomain $C.Host) -eq (Get-WingetMapDomain $WPackageUrl.Host)) { if ($Url -lt 25) { $Url = 25; $UrlName = 'url-host' } }
    }
    if ($Url -lt 25 -and $CProject -and $WPublisherUrl -and $CProject.Host -notin $script:CodeHosts -and (Get-WingetMapDomain $CProject.Host) -eq (Get-WingetMapDomain $WPublisherUrl.Host)) { $Url = 25; $UrlName = 'url-host' }
    if ($Url -gt 0) { $Score += $Url; [void]$Signals.Add($UrlName) }

    # name signals
    $Name = 0; $NameName = $null
    if ($Title.Length -ge 2 -and $Title -eq $WName) { $Name = 35; $NameName = 'name-exact' }
    elseif ($BaseId.Length -ge 2 -and $BaseId -eq $WName) { $Name = 35; $NameName = 'name-exact' }
    elseif (($Title.Length -ge 2 -and ($Title -eq $WMoniker -or $Title -eq $WLast)) -or ($BaseId.Length -ge 2 -and ($BaseId -eq $WMoniker -or $BaseId -eq $WLast))) { $Name = 25; $NameName = 'name-alias' }
    else {
        foreach ($K in @($Title, $BaseId)) {
            foreach ($W in @($WName, $WLast)) {
                if ($K.Length -ge 5 -and $W.Length -ge 5 -and ($K.Contains($W) -or $W.Contains($K))) { $Name = 10; $NameName = 'name-part' }
            }
        }
    }
    if ($Name -gt 0) { $Score += $Name; [void]$Signals.Add($NameName) }

    # publisher signal
    $Context = ConvertTo-WingetMapKey "$($Package.Authors) $($Package.Title) $(if ($CProject) { $CProject.Host })"
    $Publishers = @($Candidate.Publisher, (ConvertTo-WingetMapKey $Candidate.PublisherName), (ConvertTo-WingetMapKey (([string]$Candidate.Id -split '\.')[0]))) | Where-Object { $_ -and $_.Length -ge 3 }
    foreach ($P in $Publishers) { if ($Context.Contains($P)) { $Score += 20; [void]$Signals.Add('publisher'); break } }

    $Identity = ($Url -ge 50) -or ($Url -ge 25 -and $Name -ge 25) -or ($Name -ge 35 -and $Signals.Contains('publisher')) -or ($Name -ge 25 -and $Signals.Contains('publisher') -and $Url -ge 15)
    return [pscustomobject]@{ Score = $Score; Signals = @($Signals); Identity = [bool]$Identity }
}

function Get-WingetMapFamily {
    # winget id without trailing version parts: Untis.Untis.2026 -> untis.untis, SublimeHQ.SublimeText.4 -> sublimehq.sublimetext
    param([string]$Id)
    return ($Id.ToLower() -replace '(\.\d+)+$', '')
}

function Get-WingetMapVersionKey {
    param([string]$Id)
    $Tail = if ($Id -match '((\.\d+)+)$') { $Matches[1] } else { '' }
    return (@($Tail -split '\.' | Where-Object { $_ } | ForEach-Object { '{0:D6}' -f [int]$_ }) -join '.')
}

function Select-WingetMapCandidate {
    <#
        Decision for one package from its scored candidates (each with Id, Score, Signals, Identity).
        Returns Status (accepted | candidate | none), Best, Others (review list) and a Note.
        Candidates of one family (versioned ids of one product) count as one product: the highest line wins.
    #>
    param([AllowEmptyCollection()][object[]]$Scored, [int]$AcceptScore = 55, [int]$CandidateScore = 35, [int]$Lead = 15)
    $Scored = @($Scored | Where-Object { $_.Score -ge $CandidateScore } | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, Id)
    if ($Scored.Count -eq 0) { return [pscustomobject]@{ Status = 'none'; Best = $null; Others = @(); Note = '' } }
    $Note = ''
    # Pre-release channels (X.Preview, X.Beta, X.RC, X.Nightly ...) are not the product: when the plain id is a
    # candidate too, the channel id is dropped and the plain id keeps the better score and signals
    $ChannelPattern = '(?i)\.(preview|alpha|beta|rc|nightly|canary|dev|insiders|prerelease|experimental)$'
    $Ids = @{}; foreach ($C in $Scored) { $Ids[$C.Id.ToLower()] = $C }
    foreach ($C in @($Scored)) {
        if ($C.Id -match $ChannelPattern) {
            $Stem = $C.Id -replace $ChannelPattern, ''
            if ($Ids.ContainsKey($Stem.ToLower())) {
                $Plain = $Ids[$Stem.ToLower()]
                if ($C.Score -gt $Plain.Score) { $Plain.Score = $C.Score; $Plain.Signals = $C.Signals; $Plain.Identity = $C.Identity }
                $Scored = @($Scored | Where-Object { $_.Id -ine $C.Id })
            }
        }
    }
    $Scored = @($Scored | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, Id)
    $Top = $Scored[0]
    # One product: the top id, its variants (X.ESR, X.de) and its versioned lines (X.1, X.2, Python.3.14 and .3.15).
    # The shortest id near the top is the base; versioned lines win (highest), otherwise the base itself.
    $Near = @($Scored | Where-Object { $_.Score -ge $Top.Score - 5 })
    $Base = @($Near | Sort-Object { $_.Id.Length }, Id)[0]
    $Stem = Get-WingetMapFamily $Base.Id
    $Group = @($Scored | Where-Object { $_.Id -ieq $Base.Id -or $_.Id.ToLower().StartsWith($Base.Id.ToLower() + '.') -or (Get-WingetMapFamily $_.Id) -eq $Stem })
    $Pick = $Base
    $Numbered = @($Group | Where-Object { (Get-WingetMapFamily $_.Id) -eq $Stem -and (Get-WingetMapVersionKey $_.Id) -ne "" -and $_.Score -ge $Top.Score - 5 })
    if ($Numbered.Count -gt 0) {
        $Pick = @($Numbered | Sort-Object -Property @{ Expression = { Get-WingetMapVersionKey $_.Id }; Descending = $true })[0]
        $Note = "versioned ids: $((@($Numbered | Sort-Object Id | ForEach-Object { $_.Id })) -join ', '); the highest line is used"
    }
    $Top = $Pick
    $GroupIds = @($Group | ForEach-Object { $_.Id.ToLower() })
    $Rest = @($Scored | Where-Object { $_.Id.ToLower() -notin $GroupIds })
    # only candidates that could be the product themselves (identity signal) count as a competitor
    $SecondScore = 0
    foreach ($R in $Rest) { if ($R.Identity) { $SecondScore = $R.Score; break } }
    $BestScore = ($Group | Measure-Object -Property Score -Maximum).Maximum
    $GroupIdentity = @($Group | Where-Object { $_.Identity }).Count -gt 0
    if ($BestScore -ge $AcceptScore -and $GroupIdentity -and ($BestScore - $SecondScore) -ge $Lead) {
        return [pscustomobject]@{ Status = 'accepted'; Best = $Top; Others = $Rest; Note = $Note }
    }
    return [pscustomobject]@{ Status = 'candidate'; Best = $Top; Others = $Rest; Note = $Note }
}

# Reasons why a package has no winget equivalent by its nature (checked before matching); first match wins
$script:NoEquivalentRules = @(
    , @('^(chocolatey|chocolatey[-.].+|chocolateygui|choco-cleaner|chocobutler|boxstarter(\..+)?|chocolatey-.+)$', 'Chocolatey tooling (only useful with Chocolatey itself)')
    , @('\.(extension|template|commandline)$', 'Chocolatey extension or template package')
    , @('^kb\d+$', 'Windows update package (KB), no application')
    , @('^(psw?indowsupdate|powershell-packagemanagement|opencppcoverage|docfx|octopustools)$', 'PowerShell module or developer helper without installer package in winget')
    , @('^(netfx-.+|dotnet4\.[0-9.]+|dotnet3\.5|dotnetfx|dotnet4\.5(\.\d)?|dotnet4\.6\.1)$', '.NET Framework: part of Windows (feature), no separate winget package')
    , @('^(microsoft-vclibs-.+|microsoft-ui-xaml-.+)$', 'AppX framework dependency, installed as dependency by apps')
    , @('^(vcredist(20(05|08|10|12|13|15|17)|140|-all)|vcredist2015)$', 'Visual C++ redistributable: winget has one package per version and platform (Microsoft.VCRedist.*), not one equivalent id')
    , @('^(flashplayer.*|adobeshockwaveplayer|silverlight|quicktime|adobeair|classic-shell|adblockplusie|atom)$', 'Discontinued product')
    , @('^(nvidia-display-driver|amd-ryzen-chipset|sqlserver-odbcdriver)$', 'Driver or hardware component, not distributed through winget')
)

function Get-WingetMapNoEquivalentReason {
    param([string]$ChocoId, [string]$Tags, [string]$Title)
    $Lower = $ChocoId.ToLower()
    foreach ($Rule in $script:NoEquivalentRules) { if ($Lower -match $Rule[0]) { return $Rule[1] } }
    return $null
}

#endregion

#region sources (network)

function Get-WingetMapFile {
    # one file: from WorkDir when there (and -Offline or fresh), otherwise downloaded
    param([string]$Uri, [string]$Path, [switch]$Offline)
    if (Test-Path -LiteralPath $Path) { return $Path }
    if ($Offline) { return $null }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing -TimeoutSec 300
    return $Path
}

function Get-WingetMapIndex {
    # The winget index as a list of records. The msix is checked for the Microsoft signature before anything is read.
    param([string]$WorkDir, [switch]$Offline)
    $Json = Join-Path $WorkDir 'index.json'
    if (-not (Test-Path -LiteralPath $Json)) {
        if ($Offline) { throw "Offline: $Json is missing" }
        $Msix = Join-Path $WorkDir 'source.msix'
        if (Test-Path -LiteralPath $Msix) { Remove-Item -LiteralPath $Msix -Force }
        $null = Get-WingetMapFile -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -Path $Msix
        $Sig = Get-AuthenticodeSignature -LiteralPath $Msix
        if ($Sig.Status -ne 'Valid' -or $Sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "The signature of source.msix is not valid ($($Sig.Status)): not used" }
        $Unzip = Join-Path $WorkDir 'msix'
        if (Test-Path -LiteralPath $Unzip) { Remove-Item -LiteralPath $Unzip -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Zip = [IO.Compression.ZipFile]::OpenRead($Msix)
        try {
            $Entry = $Zip.GetEntry('Public/index.db')
            New-Item -ItemType Directory -Path $Unzip -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, (Join-Path $Unzip 'index.db'), $true)
        }
        finally { $Zip.Dispose() }
        $Python = (Get-Command python -ErrorAction Stop).Source
        & $Python -I (Join-Path $PSScriptRoot 'Export-WingetIndex.py') (Join-Path $Unzip 'index.db') $Json
        if ($LASTEXITCODE -ne 0) { throw 'Export-WingetIndex.py failed' }
    }
    return @(Get-Content -LiteralPath $Json -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
}

function Get-WingetMapManifest {
    # PackageName, Publisher, PackageUrl, PublisherUrl of the latest manifest in winget-pkgs (cached per id)
    param($Record, [string]$WorkDir, [switch]$Offline)
    $Cache = Join-Path $WorkDir ("manifests\" + ($Record.id -replace '[^A-Za-z0-9._+-]', '_') + '.json')
    if (Test-Path -LiteralPath $Cache) { return (Get-Content -LiteralPath $Cache -Raw -Encoding UTF8 | ConvertFrom-Json) }
    if ($Offline) { return $null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Folder = ($Record.path -replace '/[^/]+$', '')
    $Base = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/$Folder/$($Record.id)"
    $Get = { param($Uri) try { [string](Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60).Content } catch { $null } }
    $Read = { param($Text, $Key) if ($Text -match ('(?m)^' + $Key + ':\s*[' + [char]39 + [char]34 + ']?([^\r\n' + [char]39 + [char]34 + ']+)')) { $Matches[1].Trim() } else { '' } }
    $Main = & $Get "$Base.yaml"
    $Locale = $null
    if ($Main) {
        $Loc = & $Read $Main 'DefaultLocale'
        if ($Loc) { $Locale = & $Get "$Base.locale.$Loc.yaml" }
    }
    $Text = if ($Locale) { $Locale } else { $Main }
    $Result = [pscustomobject]@{
        Id = $Record.id; Name = $(if ($Text) { & $Read $Text 'PackageName' } else { '' }); PublisherName = $(if ($Text) { & $Read $Text 'Publisher' } else { '' })
        PackageUrl = $(if ($Text) { & $Read $Text 'PackageUrl' } else { '' }); PublisherUrl = $(if ($Text) { & $Read $Text 'PublisherUrl' } else { '' }); Fetched = [bool]$Text
    }
    New-Item -ItemType Directory -Path (Split-Path $Cache -Parent) -Force | Out-Null
    $Result | ConvertTo-Json | Set-Content -LiteralPath $Cache -Encoding UTF8
    return $Result
}

function Get-WingetMapChocoData {
    # Chocolatey metadata of the apps (curated catalog and popular list), cached in choco.json
    param([string]$WorkDir, [int]$Top, [switch]$Offline)
    $Json = Join-Path $WorkDir 'choco.json'
    if (-not (Test-Path -LiteralPath $Json)) {
        if ($Offline) { throw "Offline: $Json is missing" }
        $env:LOCALAPPDATA = Join-Path $WorkDir 'localappdata'
        . (Join-Path $script:Repo 'PackTune-Main.ps1')
        $Catalog = @(Get-PackTuneCatalog)
        $Popular = @(Select-PackTunePopular -Packages @(Get-PackTunePopularFeed -Top $Top) -Catalog $Catalog -Top $Top)
        $Items = New-Object System.Collections.ArrayList
        foreach ($Id in (@($Catalog | ForEach-Object { $_.Id }) + @($Popular | ForEach-Object { $_.Name }))) {
            $Escaped = [uri]::EscapeDataString($Id.ToLower().Replace("'", "''"))
            $P = $null
            try { $P = (Invoke-ChocoFeed -Query "Packages()?`$filter=tolower(Id)%20eq%20'$Escaped'%20and%20IsLatestVersion" | Select-Object -First 1) }
            catch { Write-Warning "$Id : $($_.Exception.Message)" }
            # PackageSourceUrl is not in the objects of the app, ask the feed entry again for it
            $Source = ''
            try {
                $Uri = $script:Settings.MetadataFeed.TrimEnd('/') + "/Packages()?`$filter=tolower(Id)%20eq%20'$Escaped'%20and%20IsLatestVersion"
                $Xml = [xml](Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60).Content
                $Source = [string](Get-FeedText $Xml.feed.entry.properties 'PackageSourceUrl')
            }
            catch { Write-Verbose "no source url of $Id" }
            [void]$Items.Add([pscustomobject]@{
                    id = $Id; curated = [bool]($Catalog | Where-Object Id -eq $Id); title = [string]$P.Title; authors = [string]$P.Authors
                    projectUrl = [string]$P.SoftwareSite; packageSourceUrl = $Source; tags = [string]$P.Tags; summary = [string]$P.Summary
                    downloads = [string]$P.Downloads; version = [string]$P.Version
                })
            Start-Sleep -Milliseconds 250
        }
        $CatalogOut = @($Catalog | ForEach-Object { [pscustomobject]@{ id = $_.Id; winget = $_.WingetId; name = $_.Name } })
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        [pscustomobject]@{ items = @($Items); catalog = $CatalogOut; top = @($Popular | ForEach-Object { $_.Name }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Json -Encoding UTF8
    }
    return (Get-Content -LiteralPath $Json -Raw -Encoding UTF8 | ConvertFrom-Json)
}

#endregion

#region build

function Get-WingetMapCandidateRecords {
    # cheap preselection from the index: the records whose names, moniker or id parts look like the package
    param($Package, $Index, [int]$Max = 10)
    $Rank = @{}
    $Keys = @{}
    foreach ($K in @((ConvertTo-WingetMapKey $(if ($Package.title) { $Package.title } else { $Package.id })), (ConvertTo-WingetMapKey $Package.id))) { if ($K.Length -ge 2) { $Keys[$K] = $true } }
    $Found = @{}
    foreach ($K in $Keys.Keys) {
        foreach ($Map in @($Index.ByName, $Index.ByMoniker, $Index.ByLast, $Index.ByFullId)) {
            if ($Map.ContainsKey($K)) { foreach ($R in $Map[$K]) { $Found[$R.id] = $R; $Rank[$R.id] = 0 } }
        }
        if ($K.Length -ge 5) {
            foreach ($R in $Index.Records) {
                if ($Found.ContainsKey($R.id)) { continue }
                if (($R.nameKey.Length -ge 5 -and ($R.nameKey.Contains($K) -or $K.Contains($R.nameKey))) -or ($R.lastKey.Length -ge 5 -and ($R.lastKey.Contains($K) -or $K.Contains($R.lastKey)))) { $Found[$R.id] = $R; $Rank[$R.id] = 1 }
            }
        }
    }
    return @($Found.Values | Sort-Object -Property @{ Expression = { $Rank[$_.id] } }, @{ Expression = { $_.id.Length } } | Select-Object -First $Max)
}

function New-WingetMapIndexLookup {
    param($Records)
    $Lookup = @{ Records = @(); ByName = @{}; ByMoniker = @{}; ByLast = @{}; ByFullId = @{} }
    $Add = { param($Map, $Key, $R) if ($Key) { if (-not $Map.ContainsKey($Key)) { $Map[$Key] = New-Object System.Collections.ArrayList }; [void]$Map[$Key].Add($R) } }
    $All = New-Object System.Collections.ArrayList
    foreach ($R in $Records) {
        $R | Add-Member -NotePropertyName nameKey -NotePropertyValue (ConvertTo-WingetMapKey $R.name) -Force
        $R | Add-Member -NotePropertyName lastKey -NotePropertyValue (ConvertTo-WingetMapKey (([string]$R.id -split '\.')[-1])) -Force
        & $Add $Lookup.ByName $R.nameKey $R
        & $Add $Lookup.ByMoniker (ConvertTo-WingetMapKey $R.moniker) $R
        & $Add $Lookup.ByLast $R.lastKey $R
        & $Add $Lookup.ByFullId (ConvertTo-WingetMapKey $R.id) $R
        [void]$All.Add($R)
    }
    $Lookup.Records = @($All)
    return $Lookup
}

function Invoke-WingetMapBuild {
    <#
        Builds the map from the Chocolatey items, the index records, the review decisions and a manifest provider
        ({ param($Record) } returning PackageName, PublisherName, PackageUrl, PublisherUrl or $null).
        Returns Map (ordered, choco id -> entry), NoEquivalent, Candidates (choco id -> scored list), None.
    #>
    param([object[]]$Items, [object[]]$IndexRecords, $Review, [scriptblock]$ManifestProvider, [string]$Checked = (Get-Date).ToString('yyyy-MM-dd'))
    $Lookup = New-WingetMapIndexLookup -Records $IndexRecords
    $ById = @{}; foreach ($R in $IndexRecords) { $ById[$R.id.ToLower()] = $R }
    $Map = [ordered]@{}; $NoEq = [ordered]@{}; $Candidates = [ordered]@{}; $None = [ordered]@{}
    $Aliases = @{}; if ($Review -and $Review.accept) { foreach ($P in $Review.accept.PSObject.Properties) { $Aliases[$P.Name.ToLower()] = $P.Value } }
    $Rejects = @{}; if ($Review -and $Review.reject) { foreach ($P in $Review.reject.PSObject.Properties) { $Rejects[$P.Name.ToLower()] = @($P.Value | ForEach-Object { $_.ToLower() }) } }
    $ReviewedNoEq = @{}; if ($Review -and $Review.noEquivalent) { foreach ($P in $Review.noEquivalent.PSObject.Properties) { $ReviewedNoEq[$P.Name.ToLower()] = [string]$P.Value } }
    foreach ($Item in @($Items | Sort-Object { $_.id.ToLower() })) {
        $Key = $Item.id.ToLower()
        $Package = [pscustomobject]@{ Id = $Item.id; Title = $Item.title; Authors = $Item.authors; ProjectUrl = $Item.projectUrl; PackageSourceUrl = $Item.packageSourceUrl }
        if ($Aliases.ContainsKey($Key)) {
            $Alias = $Aliases[$Key]; $Wid = [string]$Alias.winget
            if ($ById.ContainsKey($Wid.ToLower())) {
                $Map[$Key] = [ordered]@{ winget = $ById[$Wid.ToLower()].id; confidence = 'reviewed'; score = 0; signals = @('review'); checked = $Checked; note = [string]$Alias.note }
                continue
            }
            Write-Warning "Review entry $Key -> $Wid is not in the winget index and is ignored"
        }
        if ($ReviewedNoEq.ContainsKey($Key)) { $NoEq[$Key] = $ReviewedNoEq[$Key]; continue }
        $Reason = Get-WingetMapNoEquivalentReason -ChocoId $Item.id -Tags $Item.tags -Title $Item.title
        if ($Reason) { $NoEq[$Key] = $Reason; continue }
        $Scored = New-Object System.Collections.ArrayList
        $Skip = if ($Rejects.ContainsKey($Key)) { $Rejects[$Key] } else { @() }
        foreach ($Record in @(Get-WingetMapCandidateRecords -Package $Item -Index $Lookup)) {
            if ($Record.id.ToLower() -in $Skip) { continue }
            $Manifest = if ($ManifestProvider) { & $ManifestProvider $Record } else { $null }
            $Candidate = [pscustomobject]@{
                Id = $Record.id; Name = $(if ($Manifest -and $Manifest.Name) { $Manifest.Name } else { $Record.name }); Moniker = $Record.moniker; Publisher = $Record.publisher
                PackageUrl = $(if ($Manifest) { $Manifest.PackageUrl } else { '' }); PublisherUrl = $(if ($Manifest) { $Manifest.PublisherUrl } else { '' }); PublisherName = $(if ($Manifest) { $Manifest.PublisherName } else { '' })
            }
            $S = Get-WingetMapScore -Package $Package -Candidate $Candidate
            [void]$Scored.Add([pscustomobject]@{ Id = $Record.id; Name = $Candidate.Name; Score = $S.Score; Signals = $S.Signals; Identity = $S.Identity })
        }
        $Decision = Select-WingetMapCandidate -Scored @($Scored) -AcceptScore $script:AcceptScore -CandidateScore $script:CandidateScore -Lead $script:LeadScore
        if ($Decision.Status -eq 'accepted') {
            $Map[$Key] = [ordered]@{ winget = $Decision.Best.Id; confidence = 'high'; score = $Decision.Best.Score; signals = @($Decision.Best.Signals); checked = $Checked; note = $Decision.Note }
        }
        elseif ($Decision.Status -eq 'candidate') {
            $Candidates[$Key] = @(@($Decision.Best) + @($Decision.Others) | Select-Object -First 3)
        }
        else { $None[$Key] = 'no winget package found' }
    }
    return [pscustomobject]@{ Map = $Map; NoEquivalent = $NoEq; Candidates = $Candidates; None = $None }
}

function Get-WingetMapFileText {
    param($Build, [string]$Checked, [string]$IndexInfo)
    $Entries = [ordered]@{}
    foreach ($K in $Build.Map.Keys) { $Entries[$K] = $Build.Map[$K] }
    $NoEq = [ordered]@{}
    foreach ($K in $Build.NoEquivalent.Keys) { $NoEq[$K] = $Build.NoEquivalent[$K] }
    $Doc = [ordered]@{ schema = 1; generated = $Checked; source = $IndexInfo; apps = $Entries; noEquivalent = $NoEq }
    return ($Doc | ConvertTo-Json -Depth 6)
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $Checked = (Get-Date).ToString('yyyy-MM-dd')
    $Data = Get-WingetMapChocoData -WorkDir $WorkDir -Top $Top -Offline:$Offline
    $Index = Get-WingetMapIndex -WorkDir $WorkDir -Offline:$Offline
    $Review = $null
    if (Test-Path -LiteralPath $ReviewPath) { $Review = Get-Content -LiteralPath $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $Provider = { param($Record) Get-WingetMapManifest -Record $Record -WorkDir $WorkDir -Offline:$Offline }
    $Build = Invoke-WingetMapBuild -Items @($Data.items) -IndexRecords $Index -Review $Review -ManifestProvider $Provider -Checked $Checked
    New-Item -ItemType Directory -Path (Split-Path $OutPath -Parent) -Force | Out-Null
    $Text = Get-WingetMapFileText -Build $Build -Checked $Checked -IndexInfo "winget source index, $($Index.Count) packages"
    [IO.File]::WriteAllText($OutPath, $Text + "`n", (New-Object System.Text.UTF8Encoding($false)))
    . (Join-Path $PSScriptRoot 'WingetMapReport.ps1')
    $Report = New-WingetMapReport -Build $Build -Data $Data -IndexCount $Index.Count -Checked $Checked
    [IO.File]::WriteAllText($ReportPath, $Report, (New-Object System.Text.UTF8Encoding($false)))
    "Map: $($Build.Map.Count) accepted, $($Build.Candidates.Count) candidates for review, $($Build.NoEquivalent.Count) without equivalent, $($Build.None.Count) not found"
}
