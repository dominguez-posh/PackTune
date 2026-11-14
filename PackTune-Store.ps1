<#
    The package store of custom applications: a document library "PackTune Packages" in a private SharePoint site of the
    tenant (docs\plans\custom-applications.md, section 7). Intune cannot give content back, so every version of a custom
    application is kept here: the package, the original installer files (installer.zip, always), the recipe, the public
    certificate, the documentation and a manifest with the SHA256 of everything.

        PackTune Packages/<app id>/<version>/package.intunewin | package.msix | installer.zip | recipe.json |
                                              signing.cer | documentation.zip | manifest.json (written last)

    Access: Microsoft Graph with the delegated scope Sites.Selected. It grants nothing alone: an administrator grants the
    app registration access to that one site once (Grant-PackTuneStoreAccess, needs Sites.FullControl.All during that
    setup only). Whoever can write to the library can replace an installer that becomes an app for all devices, so
    Intune is the trust anchor: the notes of every custom app carry the full SHA256 of the manifest, and an export or an
    update checks every file against the manifest and the manifest against the notes.

    All requests go through Invoke-PackTuneStoreGraph (replaceable: the checks use a fake SharePoint).
    Loaded by PackTune-Main.ps1.
#>

$script:StoreGraph = "https://graph.microsoft.com/v1.0"
# Files up to this size go in one request; larger ones through an upload session (chunks: multiples of 320 KiB)
$script:StoreSmallLimit = 4MB
$script:StoreChunk = 327680 * 32
$script:StoreSegment = '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
$script:StoreFileNames = "package.intunewin", "package.msix", "installer.zip", "recipe.json", "signing.cer", "documentation.zip"

#region settings and state

function Test-PackTuneStoreSiteUrl {
    # https://<tenant>.sharepoint.com/sites/<name> (or /teams/<name>)
    param([string]$Url)
    return [bool]($Url -match '^https://[A-Za-z0-9-]+\.sharepoint\.com/(sites|teams)/[A-Za-z0-9._-]+/?$')
}

function Get-PackTuneStoreToken {
    <#
        Access token with the scope Sites.Selected. The normal sign-in does not ask for it (existing registrations would
        need a new consent to sign in at all); the refresh token of the sign-in gets it when it is asked for, as soon as
        the app registration holds the permission (setup, grant new permissions).
    #>
    Assert-PackTuneConnection
    Update-PackTuneToken
    if ($script:StoreToken -and $script:StoreTokenExpires -gt (Get-Date).AddMinutes(5)) { return $script:StoreToken }
    $Current = $Global:AccessToken
    if (-not $Current.RefreshToken) { return [string]$Current.access_token }   # a token without renewal data (tests, other sign-ins)
    $ClientID = if ($Current.ClientID) { $Current.ClientID } else { $script:Settings.ClientID }
    $Authority = if ($Current.Authority) { $Current.Authority } else { $script:DefaultAuthority }
    try {
        $Answer = Invoke-PackTuneTokenRequest -TenantID $Global:AccessTokenTenantID -ClientID $ClientID -Authority $Authority -Body @{ grant_type = "refresh_token"; refresh_token = $Current.RefreshToken; scope = "https://graph.microsoft.com/Sites.Selected offline_access" }
    }
    catch { throw "No access to the package store: the app registration does not hold Sites.Selected yet (Start page: set up everything, or grant the new permissions), or the consent is missing. $($_.Exception.Message)" }
    $script:StoreToken = [string]$Answer.access_token
    $script:StoreTokenExpires = (Get-Date).AddSeconds([int]$Answer.expires_in)
    return $script:StoreToken
}
$script:StoreToken = $null
$script:StoreTokenExpires = [datetime]::MinValue

function Invoke-PackTuneStoreGraph {
    <#
        One Graph request of the store. -Path is relative to the Graph root, -Absolute a full URL (upload sessions, with no
        token). A body object is sent as JSON, -InFile / -Bytes as the content, -OutFile saves the answer. Returns the answer
        parsed ($null when there is none).
    #>
    param(
        [string]$Method = "GET", [string]$Path, [string]$Absolute, $Body, [string]$InFile, [byte[]]$Bytes, [string]$OutFile, [hashtable]$Headers = @{}
    )
    $Token = if ($Absolute) { $null } else { Get-PackTuneStoreToken }
    $Uri = if ($Absolute) { $Absolute } else { "$($script:StoreGraph)$Path" }
    $Request = @{ Method = $Method; Uri = $Uri; UseBasicParsing = $true; TimeoutSec = 300; ErrorAction = "Stop"; Headers = $Headers }
    if (-not $Absolute) { $Request.Headers["Authorization"] = "Bearer $Token" }
    if ($null -ne $Body) { $Request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress)); $Request.ContentType = "application/json" }
    elseif ($Bytes) { $Request.Body = $Bytes; $Request.ContentType = "application/octet-stream" }
    elseif ($InFile) { $Request.InFile = $InFile; $Request.ContentType = "application/octet-stream" }
    if ($OutFile) { $Request.OutFile = $OutFile }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($Attempt = 1; ; $Attempt++) {
        try {
            $Response = Invoke-WebRequest @Request
            if ($OutFile -or -not $Response.Content) { return $null }
            return ([string]$Response.Content | ConvertFrom-Json)
        }
        catch {
            $Code = 0; $Wait = 0
            try { $Code = [int]$_.Exception.Response.StatusCode; $Wait = [int]($_.Exception.Response.Headers["Retry-After"]) } catch { }
            if ($Code -in 429, 502, 503, 504 -and $Attempt -lt 5 -and -not $InFile) {
                if ($Wait -le 0) { $Wait = 4 * $Attempt }
                Start-Sleep -Seconds ([Math]::Min(60, $Wait)); continue
            }
            $Detail = $null
            try { $Detail = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { }
            throw "SharePoint $Method $(if ($Absolute) { 'upload' } else { $Path }) failed$(if ($Code) { " ($Code)" }): $(if ($Detail) { $Detail } else { $_.Exception.Message })"
        }
    }
}

function ConvertTo-PackTuneStorePath {
    # A path inside the library, each segment checked and encoded
    param([Parameter(Mandatory = $true)][string[]]$Segments)
    foreach ($S in $Segments) { if ($S -notmatch $script:StoreSegment -or $S -match '\.\.') { throw "'$S' is not a valid name for the package store" } }
    return (($Segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/")
}

function Resolve-PackTuneStore {
    <#
        Site and library of the store: Site (id, name, url), Drive (id) or $null when the library does not exist.
        Throws with a clear message when the site cannot be reached (wrong address, no access granted yet).
    #>
    param([string]$SiteUrl = $script:Settings.StoreSiteUrl, [string]$Library = $script:Settings.StoreLibrary)
    if (-not (Test-PackTuneStoreSiteUrl $SiteUrl)) { throw "The address of the SharePoint site is not set or not valid (https://<tenant>.sharepoint.com/sites/<name>)." }
    $Uri = [uri]$SiteUrl
    $Site = Invoke-PackTuneStoreGraph -Path "/sites/$($Uri.Host):$($Uri.AbsolutePath.TrimEnd('/'))?`$select=id,displayName,webUrl"
    if (-not $Site.id) { throw "The site $SiteUrl was not found." }
    $Drives = @((Invoke-PackTuneStoreGraph -Path "/sites/$($Site.id)/drives?`$select=id,name,webUrl").value)
    $Drive = @($Drives | Where-Object { $_.name -eq $Library }) | Select-Object -First 1
    [pscustomobject]@{ Site = $Site; SiteId = [string]$Site.id; SiteName = [string]$Site.displayName; Drive = $Drive; DriveId = $(if ($Drive) { [string]$Drive.id } else { $null }); Library = $Library }
}

function Get-PackTuneStoreState {
    <#
        What the readiness list shows: State is NotConfigured (no site address), NoAccess (the site cannot be read: access not
        granted yet or wrong address), NoLibrary (site fine, library missing), Ready. Message says what to do.
    #>
    param([string]$SiteUrl = $script:Settings.StoreSiteUrl, [string]$Library = $script:Settings.StoreLibrary)
    if (-not $SiteUrl) { return [pscustomobject]@{ State = "NotConfigured"; Message = "Enter the address of the SharePoint site that keeps the packages."; Store = $null } }
    if (-not (Test-PackTuneStoreSiteUrl $SiteUrl)) { return [pscustomobject]@{ State = "NotConfigured"; Message = "The address must look like https://<tenant>.sharepoint.com/sites/<name>."; Store = $null } }
    try { $Store = Resolve-PackTuneStore -SiteUrl $SiteUrl -Library $Library }
    catch { return [pscustomobject]@{ State = "NoAccess"; Message = "The site cannot be read: $($_.Exception.Message) An administrator grants PackTune access to this one site (Grant access)."; Store = $null } }
    if (-not $Store.DriveId) { return [pscustomobject]@{ State = "NoLibrary"; Message = "The site is reachable, the library '$Library' does not exist yet."; Store = $Store } }
    [pscustomobject]@{ State = "Ready"; Message = "The package store '$Library' on $($Store.SiteName) is ready."; Store = $Store }
}#State of the package store

function Initialize-PackTuneStore {
    # Creates the document library when it is missing (needs the role manage on the site, or write when the library exists)
    param([string]$SiteUrl = $script:Settings.StoreSiteUrl, [string]$Library = $script:Settings.StoreLibrary)
    $Store = Resolve-PackTuneStore -SiteUrl $SiteUrl -Library $Library
    if ($Store.DriveId) { return $Store }
    $List = Invoke-PackTuneStoreGraph -Method POST -Path "/sites/$($Store.SiteId)/lists" -Body @{ displayName = $Library; list = @{ template = "documentLibrary" } }
    $Drive = Invoke-PackTuneStoreGraph -Path "/sites/$($Store.SiteId)/lists/$($List.id)/drive?`$select=id,name"
    $Store.Drive = $Drive; $Store.DriveId = [string]$Drive.id
    return $Store
}

function Grant-PackTuneStoreAccess {
    <#
        One-time setup by an administrator: gives the PackTune app registration the role write (manage: also creates the
        library) on this one site. Needs a sign-in with Sites.FullControl.All, which is used for this call only; the
        daily work needs Sites.Selected only. -Token is that administrator's access token.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SiteUrl, [Parameter(Mandatory = $true)][string]$ClientID, [string]$Token,
        [ValidateSet("write", "manage")][string]$Role = "write"
    )
    if (-not (Test-PackTuneStoreSiteUrl $SiteUrl)) { throw "The address of the SharePoint site is not valid." }
    if ($ClientID -notmatch '^[0-9a-fA-F-]{36}$') { throw "The client ID of the app registration is not valid." }
    if (-not $Token) {
        # No token handed over (the window of the interface was not available): sign in in the browser, with the setup app of Microsoft
        $Tenant = if ($script:Settings.TenantID) { $script:Settings.TenantID } else { "organizations" }
        $Token = [string](Invoke-PackTunePkceSignIn -TenantID $Tenant -ClientID "14d82eec-204b-4c2f-b7e8-296a70dab67e" -Scope "https://graph.microsoft.com/Sites.FullControl.All offline_access openid profile").access_token
    }
    $Uri = [uri]$SiteUrl
    $Headers = @{ Authorization = "Bearer $Token" }
    $Site = Invoke-RestMethod -Uri "$($script:StoreGraph)/sites/$($Uri.Host):$($Uri.AbsolutePath.TrimEnd('/'))?`$select=id" -Headers $Headers -ErrorAction Stop
    $Body = @{ roles = @($Role); grantedToIdentities = @(@{ application = @{ id = $ClientID; displayName = "PackTune" } }) } | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Method Post -Uri "$($script:StoreGraph)/sites/$($Site.id)/permissions" -Headers $Headers -ContentType "application/json" -Body $Body -ErrorAction Stop | Out-Null
    return [pscustomobject]@{ SiteId = $Site.id; Role = $Role }
}#Grants PackTune access to the one site (administrator, once)

function Get-PackTuneStoreWarnings {
    # Who else can reach the library: sharing links and other principals (write access = the power to replace an installer)
    param([Parameter(Mandatory = $true)]$Store)
    $Warnings = New-Object System.Collections.ArrayList
    try {
        $Links = @((Invoke-PackTuneStoreGraph -Path "/drives/$($Store.DriveId)/root/permissions").value | Where-Object { $_.link })
        if ($Links.Count -gt 0) { [void]$Warnings.Add("The library has $($Links.Count) sharing link(s): anyone with a link can read the installers. Remove them.") }
    }
    catch { [void]$Warnings.Add("The permissions of the library could not be read: $($_.Exception.Message)") }
    return @($Warnings)
}

#endregion

#region files

function Send-PackTuneStoreFile {
    # Uploads one file (one request up to 4 MB, otherwise an upload session in chunks)
    param([Parameter(Mandatory = $true)][string]$DriveId, [Parameter(Mandatory = $true)][string[]]$Segments, [Parameter(Mandatory = $true)][string]$LocalPath)
    $Remote = ConvertTo-PackTuneStorePath $Segments
    $Size = (Get-Item -LiteralPath $LocalPath).Length
    if ($Size -le $script:StoreSmallLimit) {
        Invoke-PackTuneStoreGraph -Method PUT -Path "/drives/$DriveId/root:/${Remote}:/content" -Bytes ([IO.File]::ReadAllBytes($LocalPath)) | Out-Null
        return
    }
    $Session = Invoke-PackTuneStoreGraph -Method POST -Path "/drives/$DriveId/root:/${Remote}:/createUploadSession" -Body @{ item = @{ "@microsoft.graph.conflictBehavior" = "replace" } }
    if (-not $Session.uploadUrl) { throw "SharePoint gave no upload session for $($Segments -join '/')" }
    $Stream = [IO.File]::OpenRead($LocalPath)
    try {
        $Buffer = New-Object byte[] $script:StoreChunk
        $Position = [int64]0
        while ($Position -lt $Size) {
            $Read = $Stream.Read($Buffer, 0, $Buffer.Length)
            if ($Read -le 0) { break }
            $Chunk = if ($Read -eq $Buffer.Length) { $Buffer } else { $Buffer[0..($Read - 1)] }
            Invoke-PackTuneStoreGraph -Method PUT -Absolute $Session.uploadUrl -Bytes ([byte[]]$Chunk) -Headers @{ "Content-Range" = "bytes $Position-$($Position + $Read - 1)/$Size" } | Out-Null
            $Position += $Read
        }
    }
    finally { $Stream.Dispose() }
}

function Receive-PackTuneStoreFile {
    param([Parameter(Mandatory = $true)][string]$DriveId, [Parameter(Mandatory = $true)][string[]]$Segments, [Parameter(Mandatory = $true)][string]$Destination)
    $Remote = ConvertTo-PackTuneStorePath $Segments
    Invoke-PackTuneStoreGraph -Path "/drives/$DriveId/root:/${Remote}:/content" -OutFile $Destination | Out-Null
}

function Get-PackTuneStoreChildren {
    param([Parameter(Mandatory = $true)][string]$DriveId, [string[]]$Segments = @())
    $Where = if ($Segments.Count) { "root:/$(ConvertTo-PackTuneStorePath $Segments):" } else { "root" }
    $Items = @()
    $Answer = Invoke-PackTuneStoreGraph -Path "/drives/$DriveId/$Where/children?`$select=name,size,folder"
    $Items += @($Answer.value)
    return $Items
}

function Remove-PackTuneStoreItem {
    param([Parameter(Mandatory = $true)][string]$DriveId, [Parameter(Mandatory = $true)][string[]]$Segments)
    Invoke-PackTuneStoreGraph -Method DELETE -Path "/drives/$DriveId/root:/$(ConvertTo-PackTuneStorePath $Segments)" | Out-Null
}

function New-PackTuneZip {
    # A folder as one zip (the original installer files of a build); returns the path
    param([Parameter(Mandatory = $true)][string]$Folder, [Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path -LiteralPath $Folder).ProviderPath, $Path, [IO.Compression.CompressionLevel]::Optimal, $false)
    return $Path
}

# Expand-PackTuneZip (zip-slip safe unpacking) lives in Modules\PackTune.Sandbox.psm1: the toolchain download uses it too

#endregion

#region versions: publish, list, export

function Publish-PackTuneStoreVersion {
    <#
        Stores one version: the files (name -> local path; names from the fixed list), then manifest.json last. A version
        without manifest is incomplete. Returns the manifest hash (full SHA256 of manifest.json): it goes into the
        notes of the Intune app.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][hashtable]$Files,
        $Store = (Resolve-PackTuneStore), [string]$Kind = "msi", [string]$WorkFolder = ([IO.Path]::GetTempPath())
    )
    if (-not $Store.DriveId) { throw "The package store has no library yet." }
    foreach ($Name in $Files.Keys) { if ($Name -notin $script:StoreFileNames) { throw "'$Name' is not a file name of the package store" }; if (-not (Test-Path -LiteralPath $Files[$Name])) { throw "File $($Files[$Name]) for $Name is missing" } }
    $Entries = foreach ($Name in ($Files.Keys | Sort-Object)) {
        $Item = Get-Item -LiteralPath $Files[$Name]
        [ordered]@{ name = $Name; sha256 = (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256).Hash; size = $Item.Length }
    }
    $Manifest = [ordered]@{ format = "PackTune.Store"; version = 1; app = $AppId; appVersion = $Version; kind = $Kind; created = (Get-Date).ToUniversalTime().ToString("o"); files = @($Entries) }
    $ManifestFile = Join-Path $WorkFolder ("packtune-manifest-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        [IO.File]::WriteAllText($ManifestFile, ($Manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
        foreach ($Name in ($Files.Keys | Sort-Object)) { Send-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($AppId, $Version, $Name) -LocalPath $Files[$Name] }
        Send-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($AppId, $Version, "manifest.json") -LocalPath $ManifestFile
        return (Get-FileHash -LiteralPath $ManifestFile -Algorithm SHA256).Hash
    }
    finally { Remove-Item -LiteralPath $ManifestFile -Force -ErrorAction SilentlyContinue }
}#Stores one version of a custom application

function Get-PackTuneStoreVersions {
    # The versions of one app in the store; Complete = has a manifest (a version without it is unfinished)
    param([Parameter(Mandatory = $true)][string]$AppId, $Store = (Resolve-PackTuneStore))
    if (-not $Store.DriveId) { return @() }
    try { $Folders = @(Get-PackTuneStoreChildren -DriveId $Store.DriveId -Segments @($AppId) | Where-Object { $_.folder }) } catch { return @() }
    foreach ($F in $Folders) {
        $Files = @(Get-PackTuneStoreChildren -DriveId $Store.DriveId -Segments @($AppId, [string]$F.name))
        [pscustomobject]@{ AppId = $AppId; Version = [string]$F.name; Complete = [bool](@($Files | Where-Object { $_.name -eq "manifest.json" }).Count); Files = @($Files.name) }
    }
}

function Get-PackTuneStoreApps {
    param($Store = (Resolve-PackTuneStore))
    if (-not $Store.DriveId) { return @() }
    @(Get-PackTuneStoreChildren -DriveId $Store.DriveId | Where-Object { $_.folder } | ForEach-Object { [string]$_.name })
}

function ConvertTo-PackTuneManifestAnchor {
    # The manifest hash as it goes into the notes of an Intune app: the full SHA256, 64 lower-case hex characters
    param([Parameter(Mandatory = $true)][string]$Hash)
    $Anchor = $Hash.Trim().ToLower()
    if ($Anchor -notmatch '^[0-9a-f]{64}$') { throw "'$Hash' is not a SHA256 of a manifest" }
    return $Anchor
}

function Save-PackTuneStoreVersion {
    <#
        Downloads one version into -Destination and checks it: the manifest against -ExpectedManifest (its SHA256 from the
        Intune notes; refused when it differs or is missing: fail closed), every file against the manifest. Nothing is unpacked
        when anything does not match. installer.zip is unpacked into <Destination>\installer. Returns what was saved.
        Apps of the first release recorded only the first 16 characters of the hash: still accepted, with a warning to
        re-anchor them (Set-PackTuneCustomManifestAnchor).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$Destination,
        [AllowEmptyString()][string]$ExpectedManifest, $Store = (Resolve-PackTuneStore)
    )
    if (-not $Store.DriveId) { throw "The package store has no library yet." }
    $Anchor = ([string]$ExpectedManifest).Trim().ToLower()
    if ($Anchor -notmatch '^([0-9a-f]{64}|[0-9a-f]{16})$') {
        throw "The Intune app of $AppId $Version records no manifest of the package store (manifest= in its notes), so the stored files cannot be trusted: nothing was downloaded. An administrator can check what is in the store and record it again (Get-PackTuneCustomAnchorReport, then Set-PackTuneCustomManifestAnchor)."
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $ManifestFile = Join-Path $Destination "manifest.json"
    Receive-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($AppId, $Version, "manifest.json") -Destination $ManifestFile
    $Hash = (Get-FileHash -LiteralPath $ManifestFile -Algorithm SHA256).Hash
    $IsMatch = if ($Anchor.Length -eq 64) { $Hash -eq $Anchor } else { $Hash.StartsWith($Anchor, [StringComparison]::OrdinalIgnoreCase) }
    if (-not $IsMatch) {
        Remove-Item -LiteralPath $ManifestFile -Force
        throw "The manifest in the package store does not match the one recorded in Intune (store $($Hash.ToLower()), Intune $Anchor). The store was changed: nothing was downloaded. If the change is known and wanted, an administrator can record the new manifest after checking it (Get-PackTuneCustomAnchorReport, then Set-PackTuneCustomManifestAnchor)."
    }
    if ($Anchor.Length -eq 16) { Write-Warning "$AppId $Version records only the start of the manifest hash (first release of custom applications). Record the full hash: Set-PackTuneCustomManifestAnchor." }
    $Manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
    if ($Manifest.format -ne "PackTune.Store" -or $Manifest.app -ne $AppId -or $Manifest.appVersion -ne $Version) { throw "The manifest does not belong to $AppId $Version" }
    $Saved = New-Object System.Collections.ArrayList
    foreach ($Entry in @($Manifest.files)) {
        if ([string]$Entry.name -notin $script:StoreFileNames) { throw "The manifest names an unexpected file '$($Entry.name)'" }
        $Target = Join-Path $Destination ([string]$Entry.name)
        Receive-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($AppId, $Version, [string]$Entry.name) -Destination $Target
        if ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ne [string]$Entry.sha256) {
            throw "$($Entry.name) does not match the manifest (SHA256): the file in the package store was changed. Nothing was unpacked."
        }
        [void]$Saved.Add($Target)
    }
    $Installer = $null
    $Zip = Join-Path $Destination "installer.zip"
    if (Test-Path -LiteralPath $Zip) { $Installer = Join-Path $Destination "installer"; Expand-PackTuneZip -Path $Zip -Destination $Installer }
    [pscustomobject]@{ AppId = $AppId; Version = $Version; Destination = $Destination; Files = @($Saved); InstallerFolder = $Installer; ManifestHash = $Hash; Kind = [string]$Manifest.kind }
}#Downloads and verifies one version

function Remove-PackTuneStoreApp {
    # Deletes the folder of one app (all its versions); SharePoint keeps it in the recycle bin
    param([Parameter(Mandatory = $true)][string]$AppId, $Store = (Resolve-PackTuneStore))
    if ($Store.DriveId) { Remove-PackTuneStoreItem -DriveId $Store.DriveId -Segments @($AppId) }
}

#endregion
