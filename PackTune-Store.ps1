<#
    The package store of custom applications: a document library "PackTune Packages" in a private SharePoint site of the
    tenant (docs\plans\custom-applications.md, section 7). Intune cannot give content back, so every version of a custom
    application is kept here: the package, the original installer files (installer.zip, always), the recipe, the public
    certificate, the documentation and a manifest with the SHA256 of everything.

        PackTune Packages/<app id>/<version>/package.intunewin | package.msix | installer.zip | recipe.json |
                                              signing.cer | documentation.zip | manifest.json (written last)

    Access: Microsoft Graph with the delegated scope Sites.Selected. It grants nothing alone: an administrator grants the
    app registration access to that one site once (Grant-PackTuneStoreAccess, needs Sites.FullControl.All and, for making the site, Group.ReadWrite.All during that
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
$script:StoreFileNames = "package.intunewin", "package.msix", "installer.zip", "recipe.json", "signing.cer", "documentation.zip", "test.json"
# Shown before and after the one-time site grant (interface, command line, README)
$script:StoreGrantConsentNote = "The consents for Sites.FullControl.All and Group.ReadWrite.All (the second one only for creating the site) that the setup sign-in gives Microsoft's app 'Microsoft Graph Command Line Tools' stays in the tenant afterwards; PackTune uses it for the grant only. Remove it when it is not needed any more: Entra admin center > Enterprise applications > Microsoft Graph Command Line Tools > Permissions (Admin consent and User consent) > Revoke, or with Microsoft Graph PowerShell remove its oauth2PermissionGrant (Remove-MgOauth2PermissionGrant) or take these two permissions out of its scope (Update-MgOauth2PermissionGrant)."

#region settings and state

#region the standard site (discovery and setup)

$script:StoreStandardName = "PackTune"
$script:StoreFallbackName = "PackTune-Packages"
$script:StoreGroupMarker = "PackTune package store"
$script:StoreHost = $null

$script:StoreSetupClientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"   # Microsoft Graph Command Line Tools: only the sign-in of the setup, never the holder of a site permission
$script:StoreTimeoutSec = 300

function Get-PackTuneAppClientId {
    <#
        The client id of PackTune's OWN app registration (the one the tool signs in with), the one that gets the permission on the site.
        Never the setup app of Microsoft (the administrator signs in through it, it must not end up as the holder of the site permission).
    #>
    $Candidate = [string]$script:Settings.ClientID
    if ($Candidate -match '^[0-9a-fA-F-]{36}$' -and $Candidate -ine $script:StoreSetupClientId) { return $Candidate }
    throw "App registration missing - set it up first (Start page). The client id in the settings is empty or is the setup app of Microsoft, never PackTune's own."
}

function Get-PackTuneStoreCause {
    # A short English cause for the readiness item from what Graph or the network said (the raw text stays in the log)
    param([string]$Text)
    if ($Text -match '(?i)\b40[13]\b|forbidden|verboten|access denied|accessDenied|insufficient privileges|unauthorized') { return "PackTune has no access to the site yet - an administrator confirms it once (Grant access). If the site belongs to someone else, ask an administrator to add you to the PackTune site." }
    if ($Text -match '(?i)timed out|timeout|zeit.{1,2}berschreitung|operation has timed out') { return "SharePoint did not answer in time. It is checked again at the next start or with Check." }
    if ($Text -match '(?i)remote name|remotename|could not be resolved|unable to connect|no such host|network|netzwerk|connection (was )?(closed|refused|reset)') { return "SharePoint cannot be reached (network or VPN). It is checked again later." }
    $One = ($Text -replace '\s+', ' ').Trim()
    if ($One.Length -gt 140) { $One = $One.Substring(0, 137) + '...' }
    return "The site cannot be read: $One"
}

function Grant-PackTuneSitePermission {
    <#
        Gives PackTune's own app registration a role on ONE site and reads the site permissions back: the grant counts only when the
        application with this client id is in the list afterwards (the earlier version could not tell whose id it had written).
    #>
    param([Parameter(Mandatory = $true)][string]$Token, [Parameter(Mandatory = $true)][string]$SiteId, [Parameter(Mandatory = $true)][string]$ClientID, [ValidateSet("write", "manage")][string]$Role = "write")
    if ($ClientID -notmatch '^[0-9a-fA-F-]{36}$') { throw "The client ID of the app registration is not valid." }
    if ($ClientID -ieq $script:StoreSetupClientId) { throw "The site permission must go to PackTune's own app registration, not to the setup app of Microsoft ($ClientID)." }
    [void](Invoke-PackTuneAdminGraph -Token $Token -Method POST -Path "/sites/$SiteId/permissions" -Body @{ roles = @($Role); grantedToIdentities = @(@{ application = @{ id = $ClientID; displayName = "PackTune" } }) })
    $Holders = @(Get-PackTuneSitePermissions -Token $Token -SiteId $SiteId | Where-Object { $_.ClientId -ieq $ClientID })
    if ($Holders.Count -eq 0) { throw "The permission was sent, but the site does not list PackTune ($ClientID) as holder when read back." }
    return $Holders[0]
}

function Get-PackTuneSitePermissions {
    # Application permissions of the site: PermissionId, ClientId, DisplayName, Roles
    param([Parameter(Mandatory = $true)][string]$Token, [Parameter(Mandatory = $true)][string]$SiteId)
    foreach ($Entry in @((Invoke-PackTuneAdminGraph -Token $Token -Path "/sites/$SiteId/permissions").value | Where-Object { $_ })) {
        $Apps = @(@($Entry.grantedToIdentitiesV2) + @($Entry.grantedToIdentities) + @($Entry.grantedToV2) | Where-Object { $_ -and $_.application } | ForEach-Object { $_.application })
        foreach ($App in $Apps) { [pscustomobject]@{ PermissionId = [string]$Entry.id; ClientId = [string]$App.id; DisplayName = [string]$App.displayName; Roles = @($Entry.roles) } }
    }
}

function Get-PackTuneStoreWrongGrants {
    # Permissions of the site held by the setup app of Microsoft (an earlier PackTune version granted it there by mistake)
    param([Parameter(Mandatory = $true)][string]$Token, [Parameter(Mandatory = $true)][string]$SiteId)
    @(Get-PackTuneSitePermissions -Token $Token -SiteId $SiteId | Where-Object { $_.ClientId -ieq $script:StoreSetupClientId })
}

function Remove-PackTuneStoreWrongGrants {
    param([Parameter(Mandatory = $true)][string]$Token, [Parameter(Mandatory = $true)][string]$SiteId)
    foreach ($Wrong in @(Get-PackTuneStoreWrongGrants -Token $Token -SiteId $SiteId)) {
        [void](Invoke-PackTuneAdminGraph -Token $Token -Method DELETE -Path "/sites/$SiteId/permissions/$($Wrong.PermissionId)")
        Write-Host "Removed the permission of the setup app ($($Wrong.ClientId), $($Wrong.DisplayName)) from the site"
        [pscustomobject]@{ PermissionId = $Wrong.PermissionId; ClientId = $Wrong.ClientId; Removed = $true }
    }
    if (@(Get-PackTuneStoreWrongGrants -Token $Token -SiteId $SiteId).Count) { throw "The permission of the setup app could not be removed from the site." }
}
function Invoke-PackTuneAdminGraph {
    <# One Graph request with the token of the administrator's setup sign-in (not the daily token). Replaceable: the checks use a fake. #>
    param([Parameter(Mandatory = $true)][string]$Token, [string]$Method = "GET", [Parameter(Mandatory = $true)][string]$Path, $Body)
    $Request = @{ Method = $Method; Uri = "$($script:StoreGraph)$Path"; Headers = @{ Authorization = "Bearer $Token" }; ErrorAction = "Stop" }
    if ($null -ne $Body) { $Request.Body = ($Body | ConvertTo-Json -Depth 8 -Compress); $Request.ContentType = "application/json" }
    try { return (Invoke-RestMethod @Request) }
    catch {
        $Code = 0; try { $Code = [int]$_.Exception.Response.StatusCode } catch { }
        $Detail = $null; try { $Detail = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { }
        throw "Graph $Method $Path failed$(if ($Code) { " ($Code)" }): $(if ($Detail) { $Detail } else { $_.Exception.Message })"
    }
}

function Wait-PackTuneStore([int]$Seconds) { Start-Sleep -Seconds $Seconds }

function Get-PackTuneStoreHost {
    <#
        The SharePoint host of the tenant (<initial domain>.sharepoint.com): from the tenant setting when it is the initial domain,
        else from the verified domains of the organization (the one marked initial). $null when it cannot be found.
    #>
    if ($script:StoreHost) { return $script:StoreHost }
    $Tenant = [string]$script:Settings.TenantID
    if ($Tenant -match '^([A-Za-z0-9-]+)\.onmicrosoft\.com$') { $script:StoreHost = "$($Matches[1].ToLower()).sharepoint.com"; return $script:StoreHost }
    try {
        Assert-PackTuneConnection
        $Org = Invoke-RestMethod -Uri "$($script:StoreGraph)/organization?`$select=verifiedDomains" -Headers @{ Authorization = "Bearer $($Global:AccessToken.access_token)" } -ErrorAction Stop
        $Initial = @(@($Org.value).verifiedDomains | Where-Object { $_.isInitial }) | Select-Object -First 1
        if ($Initial.name -match '^([A-Za-z0-9-]+)\.onmicrosoft\.com$') { $script:StoreHost = "$($Matches[1].ToLower()).sharepoint.com" }
    }
    catch { }
    return $script:StoreHost
}

function Get-PackTuneStoreSiteUrl {
    # The site of the store: the address from the advanced settings when there is one, else the standard site of the tenant
    # (https://<tenant>.sharepoint.com/sites/PackTune, or the fallback name that was chosen after a conflict). $null when the host is unknown.
    if ($script:Settings.StoreSiteUrl) { return [string]$script:Settings.StoreSiteUrl }
    $Name = if ($script:Settings.StoreSiteName) { [string]$script:Settings.StoreSiteName } else { $script:StoreStandardName }
    $HostName = Get-PackTuneStoreHost
    if (-not $HostName) { return $null }
    return "https://$HostName/sites/$Name"
}

$script:StoreSetupStepTitles = @('Sign in (administrator)', 'Create the Microsoft 365 group PackTune', 'Wait for the SharePoint site', 'Add members', 'Create the library', 'Grant PackTune access to the site', 'Check')
$script:StoreStepNow = 0
function Write-PackTuneStep {
    <# One event of a multi-step job, as a readable log line: "Step 3/7 running: Wait for the SharePoint site". The interface turns these
       lines into its step list (state running / done / error / detail); the activity log shows them as they are. #>
    param([int]$Number, [int]$Total, [ValidateSet('running', 'done', 'error', 'detail')][string]$State, [string]$Text)
    if ($State -in 'running') { $script:StoreStepNow = $Number }
    Write-Host "Step $Number/$Total ${State}: $Text"
}
function Initialize-PackTuneStoreSite {
    param(
        [Parameter(Mandatory = $true)][string]$Token, [string]$ClientID = (Get-PackTuneAppClientId), [string]$SiteName,
        [string]$AdminGroup, [string]$Library = $script:Settings.StoreLibrary, [int]$PollMinutes = 6
    )
    # The steps are reported as they happen; an error is attached to the step that was running
    $script:StoreStepNow = 1
    Write-PackTuneStep 1 7 done 'Signed in as administrator'
    try { Invoke-PackTuneStoreSiteSetup @PSBoundParameters }
    catch {
        $Cause = ($_.Exception.Message -replace '\s+', ' ').Trim()
        Write-PackTuneStep ([Math]::Max(2, $script:StoreStepNow)) 7 error $Cause
        throw
    }
}
function Invoke-PackTuneStoreSiteSetup {
    <#
        One-time setup by an administrator (-Token: the setup sign-in with Sites.FullControl.All and Group.ReadWrite.All; the daily
        sign-in never has them): makes the standard site when it is missing, then the library, then gives PackTune's app registration
        write access to that one site.
          1. the site https://<tenant>.sharepoint.com/sites/<name> exists: it is used as it is
          2. otherwise a private Microsoft 365 group "PackTune" (hidden in Outlook, no welcome mail, hidden from address lists when the
             tenant allows it) with the signing administrator as owner and, optionally, an Entra group as member; its site is awaited
             (polled with a growing pause)
          3. the library, 4. the grant (role write)
        A group with that mail nickname that PackTune did not create is a conflict: nothing is changed, State is Conflict and
        FallbackName says which name to ask for (PackTune-Packages). Returns State (Ready, Conflict), SiteUrl, SiteName, Steps and Warnings.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Token, [string]$ClientID = (Get-PackTuneAppClientId), [string]$SiteName,
        [string]$AdminGroup, [string]$Library = $script:Settings.StoreLibrary, [int]$PollMinutes = 6
    )
    if (-not $SiteName) { $SiteName = if ($script:Settings.StoreSiteName) { [string]$script:Settings.StoreSiteName } else { $script:StoreStandardName } }
    if ($SiteName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,40}$') { throw "The site name '$SiteName' is not valid (letters, digits, hyphen)." }
    $HostName = Get-PackTuneStoreHost
    if (-not $HostName) { throw "The SharePoint address of the tenant could not be found. Enter the address of the site under Advanced instead." }
    $Steps = New-Object System.Collections.ArrayList; $Warnings = New-Object System.Collections.ArrayList
    $Url = "https://$HostName/sites/$SiteName"
    $Site = $null
    try { $Site = Invoke-PackTuneAdminGraph -Token $Token -Path "/sites/${HostName}:/sites/${SiteName}?`$select=id,webUrl,displayName" } catch { if ($_.Exception.Message -notmatch '404|not found|itemNotFound|ResourceNotFound') { throw } }
    if ($Site.id) {
        [void]$Steps.Add("The site $Url exists already, it is used as it is")
        foreach ($N in 2, 3, 4) { Write-PackTuneStep $N 7 done "$($script:StoreSetupStepTitles[$N - 1]): not needed, the site exists already" }
    }
    else {
        Write-PackTuneStep 2 7 running $script:StoreSetupStepTitles[1]
        $Nick = $SiteName.ToLower()
        $Existing = @((Invoke-PackTuneAdminGraph -Token $Token -Path "/groups?`$filter=mailNickname eq '$Nick'&`$select=id,displayName,description").value) | Select-Object -First 1
        if ($Existing -and ([string]$Existing.description -notlike "*$($script:StoreGroupMarker)*")) {
            Write-PackTuneStep 2 7 error "A group named '$($Existing.displayName)' exists in this tenant and was not made by PackTune."
            return [pscustomobject]@{ State = "Conflict"; SiteUrl = $Url; SiteName = $SiteName; FallbackName = $(if ($SiteName -ne $script:StoreFallbackName) { $script:StoreFallbackName } else { $null })
                Steps = @($Steps); Warnings = @($Warnings); Message = "A group named '$($Existing.displayName)' (mail nickname $Nick) exists in this tenant and was not made by PackTune." }
        }
        $GroupId = $null
        if ($Existing) { $GroupId = [string]$Existing.id; [void]$Steps.Add("The PackTune group exists already (no site yet), it is used") }
        else {
            $Me = Invoke-PackTuneAdminGraph -Token $Token -Path "/me?`$select=id,displayName"
            $Group = Invoke-PackTuneAdminGraph -Token $Token -Method POST -Path "/groups" -Body @{
                displayName = $(if ($SiteName -eq $script:StoreStandardName) { "PackTune" } else { $SiteName.Replace("-", " ") }); description = "$($script:StoreGroupMarker): packages of the custom applications. Only Intune administrators belong here."
                mailNickname = $Nick; mailEnabled = $true; securityEnabled = $false; groupTypes = @("Unified"); visibility = "Private"
                resourceBehaviorOptions = @("HideGroupInOutlook", "WelcomeEmailDisabled")
                "owners@odata.bind" = @("$($script:StoreGraph)/users/$($Me.id)"); "members@odata.bind" = @("$($script:StoreGraph)/users/$($Me.id)")
            }
            $GroupId = [string]$Group.id
            [void]$Steps.Add("Private Microsoft 365 group '$($Group.displayName)' created ($GroupId), owner: $($Me.displayName)")
            # The group is replicated to Exchange a moment after it is made: the first PATCH can get 404. Retried with a growing pause; what Exchange
            # does not support is no problem (the group is hidden in Outlook anyway), so it is information, not a warning.
            $Hidden = $false; $Pause = 2
            for ($Try = 1; $Try -le 5 -and -not $Hidden; $Try++) {
                try { [void](Invoke-PackTuneAdminGraph -Token $Token -Method PATCH -Path "/groups/$GroupId" -Body @{ hideFromAddressLists = $true; hideFromOutlookClients = $true }); $Hidden = $true }
                catch { if ($Try -lt 5) { Wait-PackTuneStore $Pause; $Pause = [Math]::Min(20, $Pause * 2) } }
            }
            if ($Hidden) { [void]$Steps.Add("The group is hidden from the address lists") }
            else { [void]$Steps.Add("Info: the group could not be hidden from the address lists (Exchange does not offer it for this group yet or at all); it is hidden in Outlook through its settings") }
        }
        Write-PackTuneStep 2 7 done "Group ready"
        Write-PackTuneStep 3 7 running "$($script:StoreSetupStepTitles[2]) (can take a few minutes)"
        # the site of the group is made in the background: poll with a growing pause
        $Deadline = (Get-Date).AddMinutes($PollMinutes); $Pause = 2
        while ($true) {
            try { $Site = Invoke-PackTuneAdminGraph -Token $Token -Path "/groups/$GroupId/sites/root?`$select=id,webUrl,displayName"; if ($Site.id) { break } } catch { }
            if ((Get-Date) -gt $Deadline) { throw "The site of the group was not ready after $PollMinutes minutes. Run Set up again in a few minutes; the group exists and is used." }
            Write-PackTuneStep 3 7 detail "SharePoint is still preparing the site ..."
            Wait-PackTuneStore $Pause; $Pause = [Math]::Min(20, $Pause * 2)
        }
        if ($Site.webUrl) { $Url = ([string]$Site.webUrl).TrimEnd('/') }
        [void]$Steps.Add("The site is ready: $Url")
        Write-PackTuneStep 3 7 done "The site is ready"
        Write-PackTuneStep 4 7 running $script:StoreSetupStepTitles[3]
        if ($AdminGroup) {
            try {
                $Other = if ($AdminGroup -match '^[0-9a-fA-F-]{36}$') { [pscustomobject]@{ id = $AdminGroup } } else { @((Invoke-PackTuneAdminGraph -Token $Token -Path "/groups?`$filter=displayName eq '$($AdminGroup.Replace("'", "''"))'&`$select=id,displayName").value) | Select-Object -First 1 }
                if (-not $Other.id) { throw "no group named '$AdminGroup'" }
                [void](Invoke-PackTuneAdminGraph -Token $Token -Method POST -Path "/groups/$GroupId/members/`$ref" -Body @{ "@odata.id" = "$($script:StoreGraph)/groups/$($Other.id)" })
                [void]$Steps.Add("Group '$AdminGroup' added as member")
            }
            catch { [void]$Warnings.Add("The group '$AdminGroup' could not be added: $($_.Exception.Message) Add it in Microsoft 365 / Entra by hand.") }
        }
    }
    if ($Site.id -and $Steps.Count -and $Steps[-1] -notlike "*Group '*") { }
    Write-PackTuneStep 4 7 done "Members: you (owner)$(if ($AdminGroup) { " and the group '$AdminGroup'" })"
    # the library, then the access of the app registration
    Write-PackTuneStep 5 7 running $script:StoreSetupStepTitles[4]
    $Drives = @((Invoke-PackTuneAdminGraph -Token $Token -Path "/sites/$($Site.id)/drives?`$select=id,name").value)
    if (-not (@($Drives | Where-Object { $_.name -eq $Library }))) {
        [void](Invoke-PackTuneAdminGraph -Token $Token -Method POST -Path "/sites/$($Site.id)/lists" -Body @{ displayName = $Library; list = @{ template = "documentLibrary" } })
        [void]$Steps.Add("Library '$Library' created")
    }
    else { [void]$Steps.Add("Library '$Library' exists already") }
    Write-PackTuneStep 5 7 done "Library '$Library' is there"
    Write-PackTuneStep 6 7 running $script:StoreSetupStepTitles[5]
    $Holder = Grant-PackTuneSitePermission -Token $Token -SiteId $Site.id -ClientID $ClientID -Role "write"
    [void]$Steps.Add("PackTune (app registration $ClientID, $($Holder.DisplayName)) has write access to this one site, confirmed by reading the permissions back")
    $Wrong = @(Get-PackTuneStoreWrongGrants -Token $Token -SiteId $Site.id)
    if ($Wrong.Count) { [void]$Warnings.Add("The setup app of Microsoft holds a permission on this site (an earlier version granted it there by mistake). It can be removed.") }
    Write-PackTuneStep 6 7 done "PackTune has write access to this one site"
    Write-PackTuneStep 7 7 running $script:StoreSetupStepTitles[6]
    $Check = @((Invoke-PackTuneAdminGraph -Token $Token -Path "/sites/$($Site.id)/drives?`$select=id,name").value | Where-Object { $_.name -eq $Library })
    if (-not $Check.Count) { throw "The library '$Library' was not found after the setup." }
    Write-PackTuneStep 7 7 done "Site, library and access checked"
    [pscustomobject]@{ State = "Ready"; SiteUrl = $Url; SiteName = $SiteName; SiteId = [string]$Site.id; FallbackName = $null; Steps = @($Steps); Warnings = @($Warnings); WrongGrants = $Wrong.Count; Message = "The package store is set up on $Url." }
}#Creates the standard site, the library and the access (administrator, once)

#endregion

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
    $Request = @{ Method = $Method; Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $script:StoreTimeoutSec; ErrorAction = "Stop"; Headers = $Headers }
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
    param([string]$SiteUrl = (Get-PackTuneStoreSiteUrl), [string]$Library = $script:Settings.StoreLibrary)
    if (-not (Test-PackTuneStoreSiteUrl $SiteUrl)) { throw "The address of the SharePoint site is not known or not valid (https://<tenant>.sharepoint.com/sites/<name>)." }
    $Uri = [uri]$SiteUrl
    $Site = Invoke-PackTuneStoreGraph -Path "/sites/$($Uri.Host):$($Uri.AbsolutePath.TrimEnd('/'))?`$select=id,displayName,webUrl"
    if (-not $Site.id) { throw "The site $SiteUrl was not found." }
    $Drives = @((Invoke-PackTuneStoreGraph -Path "/sites/$($Site.id)/drives?`$select=id,name,webUrl").value)
    $Drive = @($Drives | Where-Object { $_.name -eq $Library }) | Select-Object -First 1
    [pscustomobject]@{ Site = $Site; SiteId = [string]$Site.id; SiteName = [string]$Site.displayName; Drive = $Drive; DriveId = $(if ($Drive) { [string]$Drive.id } else { $null }); Library = $Library }
}

function Get-PackTuneStoreState {
    <#
        What the readiness list shows, found without any input: the standard site https://<tenant>.sharepoint.com/sites/PackTune (or the
        address from the advanced settings). State is NotConfigured (the SharePoint address of the tenant is unknown), Missing (no such
        site: an administrator sets it up once), NoAccess (the site exists, this account or PackTune has no access: ask an administrator to
        add you), NoLibrary (site fine, library missing), Ready. Message says what to do.
    #>
    param([string]$SiteUrl, [string]$Library = $script:Settings.StoreLibrary)
    if (-not $SiteUrl) { $SiteUrl = Get-PackTuneStoreSiteUrl }
    if (-not $SiteUrl) { return [pscustomobject]@{ State = "NotConfigured"; Message = "The SharePoint address of the tenant could not be found. Enter the address of the site under Advanced."; Store = $null; SiteUrl = $null } }
    if (-not (Test-PackTuneStoreSiteUrl $SiteUrl)) { return [pscustomobject]@{ State = "NotConfigured"; Message = "The address must look like https://<tenant>.sharepoint.com/sites/<name>."; Store = $null; SiteUrl = $SiteUrl } }
    # A check never hangs: 30 seconds per request, then it says so
    $Before = $script:StoreTimeoutSec; $script:StoreTimeoutSec = 30
    try { $Store = Resolve-PackTuneStore -SiteUrl $SiteUrl -Library $Library }
    catch {
        $Text = $_.Exception.Message
        if ($Text -match '404|not found|itemNotFound|ResourceNotFound|was not found') { return [pscustomobject]@{ State = "Missing"; Message = "The PackTune site does not exist in this tenant yet. An administrator sets it up once (Set up)."; Store = $null; SiteUrl = $SiteUrl } }
        return [pscustomobject]@{ State = "NoAccess"; Message = (Get-PackTuneStoreCause $Text); Store = $null; SiteUrl = $SiteUrl; Raw = $Text }
    }
    finally { $script:StoreTimeoutSec = $Before }
    if (-not $Store.DriveId) { return [pscustomobject]@{ State = "NoLibrary"; Message = "The site is reachable, the library '$Library' does not exist yet."; Store = $Store; SiteUrl = $SiteUrl } }
    [pscustomobject]@{ State = "Ready"; Message = "The package store '$Library' on $($Store.SiteName) is ready."; Store = $Store; SiteUrl = $SiteUrl }}#State of the package store

function Initialize-PackTuneStore {
    # Creates the document library when it is missing (needs the role manage on the site, or write when the library exists)
    param([string]$SiteUrl = (Get-PackTuneStoreSiteUrl), [string]$Library = $script:Settings.StoreLibrary)
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
        library) on this one site. Needs a sign-in with Sites.FullControl.All, which PackTune uses for this call only; the
        daily work needs Sites.Selected only. -Token is that administrator's access token.
        The sign-in goes through Microsoft's app "Microsoft Graph Command Line Tools" (14d82eec-...). The consent for
        Sites.FullControl.All given there STAYS in the tenant after this call ($script:StoreGrantConsentNote says where
        and how to remove it); PackTune does not remove it, because other tools of the tenant may use that app too.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SiteUrl, [string]$ClientID = (Get-PackTuneAppClientId), [string]$Token,
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
    $Site = Invoke-PackTuneAdminGraph -Token $Token -Path "/sites/$($Uri.Host):$($Uri.AbsolutePath.TrimEnd('/'))?`$select=id"
    $Holder = Grant-PackTuneSitePermission -Token $Token -SiteId $Site.id -ClientID $ClientID -Role $Role
    Write-Host "PackTune (app registration $ClientID, $($Holder.DisplayName)) holds the role $Role on this site, confirmed by reading the permissions back"
    $Wrong = @(Get-PackTuneStoreWrongGrants -Token $Token -SiteId $Site.id)
    if ($Wrong.Count) { Write-Warning "The setup app of Microsoft ($($script:StoreSetupClientId)) holds a permission on this site (an earlier version granted it there by mistake). It can be removed." }
    Write-Warning $script:StoreGrantConsentNote
    return [pscustomobject]@{ SiteId = $Site.id; Role = $Role; ClientId = $ClientID; WrongGrants = $Wrong.Count }
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
    @(Get-PackTuneStoreChildren -DriveId $Store.DriveId | Where-Object { $_.folder -and [string]$_.name -ne $script:ProtocolFolderName } | ForEach-Object { [string]$_.name })
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
