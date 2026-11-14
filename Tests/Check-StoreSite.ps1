<#
.SYNOPSIS
    Checks of the standard package store site: the address found without input (tenant host from the initial domain), discovery
    (found, no access, missing, no host), the one-time setup with a fake Graph (group made private and hidden, polling for the
    site, members, library, grant), the conflicts (a group of that name that is not ours: nothing changed, fallback name) and that
    the settings stay valid. No tenant, no network.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-StoreSite.ps1
#>
$ErrorActionPreference = 'Stop'
# A check that dies half way is a failure, with a clear line and a non-zero exit code
trap { "FAIL  the check stopped before the end: $($_.Exception.Message)"; exit 1 }
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneStoreSite-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')
function Set-Tenant([string]$Tenant, [string]$Override = '', [string]$Name = 'PackTune') {
    $s = Get-PackTuneSettings; $s.TenantID = $Tenant; $s.StoreSiteUrl = $Override; $s.StoreSiteName = $Name
    [void](Save-PackTuneSettings -Settings $s); $script:Settings = Get-PackTuneSettings; $script:StoreHost = $null
}

# --- the address without input
Set-Tenant 'contoso.onmicrosoft.com'
Test-Check 'address: the standard site of the tenant from the initial domain' ((Get-PackTuneStoreSiteUrl) -eq 'https://contoso.sharepoint.com/sites/PackTune')
Set-Tenant 'Contoso.OnMicrosoft.com' '' 'PackTune-Packages'
Test-Check 'address: the remembered fallback name, host in lower case' ((Get-PackTuneStoreSiteUrl) -eq 'https://contoso.sharepoint.com/sites/PackTune-Packages')
Set-Tenant 'contoso.onmicrosoft.com' 'https://fabrikam.sharepoint.com/sites/Other'
Test-Check 'address: the advanced override wins' ((Get-PackTuneStoreSiteUrl) -eq 'https://fabrikam.sharepoint.com/sites/Other')
Set-Tenant 'contoso.com'
$Global:AccessToken = $null
Test-Check 'address: a custom domain without a way to ask the organization gives no address (the state says what to do)' (-not (Get-PackTuneStoreSiteUrl) -and (Get-PackTuneStoreState).State -eq 'NotConfigured')
$Global:AccessToken = [pscustomobject]@{ access_token = 'x.e30.y'; ExpiresOn = (Get-Date).AddHours(1).ToUniversalTime() }
function Invoke-RestMethod { param($Uri, $Headers, $ErrorAction, $Method, $Body, $ContentType) if ($Uri -like '*/organization*') { return [pscustomobject]@{ value = @([pscustomobject]@{ verifiedDomains = @([pscustomobject]@{ name = 'contoso.com'; isInitial = $false }, [pscustomobject]@{ name = 'contosoinc.onmicrosoft.com'; isInitial = $true }) }) } }; throw "unexpected $Uri" }
$script:StoreHost = $null
Test-Check 'address: a custom domain uses the initial domain from the verified domains' ((Get-PackTuneStoreSiteUrl) -eq 'https://contosoinc.sharepoint.com/sites/PackTune')
Remove-Item function:Invoke-RestMethod
$bad = $false; try { $s = Get-PackTuneSettings; $s.StoreSiteName = 'bad name!'; Save-PackTuneSettings -Settings $s | Out-Null } catch { $bad = $true }
Test-Check 'settings: the site name is validated' $bad

# --- discovery with a fake SharePoint (search by path)
Set-Tenant 'contoso.onmicrosoft.com'
$script:Mode = 'found'
function Invoke-PackTuneStoreGraph {
    param([string]$Method = 'GET', [string]$Path, [string]$Absolute, $Body, [string]$InFile, [byte[]]$Bytes, [string]$OutFile, [hashtable]$Headers = @{})
    if ($Path -like '/sites/contoso.sharepoint.com:*') {
        if ($script:Mode -eq 'missing') { throw 'SharePoint GET /sites/contoso.sharepoint.com:/sites/PackTune failed (404): Requested site could not be found' }
        if ($script:Mode -eq 'denied') { throw 'SharePoint GET /sites/contoso.sharepoint.com:/sites/PackTune failed (403): Access denied' }
        return [pscustomobject]@{ id = 'site-1'; displayName = 'PackTune'; webUrl = 'https://contoso.sharepoint.com/sites/PackTune' }
    }
    if ($Path -like '/sites/site-1/drives*') { return [pscustomobject]@{ value = @($(if ($script:Mode -ne 'nolibrary') { [pscustomobject]@{ id = 'd1'; name = 'PackTune Packages' } })) } }
    throw "fake SharePoint: $Method $Path"
}
$st = Get-PackTuneStoreState
Test-Check 'discovery: found and accessible -> Ready without any input' ($st.State -eq 'Ready' -and $st.SiteUrl -eq 'https://contoso.sharepoint.com/sites/PackTune')
$script:Mode = 'denied'; $st = Get-PackTuneStoreState
Test-Check 'discovery: found but no access -> NoAccess, "ask an administrator to add you to the PackTune site"' ($st.State -eq 'NoAccess' -and $st.Message -like '*ask an administrator to add you to the PackTune site*')
$script:Mode = 'missing'; $st = Get-PackTuneStoreState
Test-Check 'discovery: not there -> Missing, offers the one-time setup' ($st.State -eq 'Missing' -and $st.Message -like '*sets it up once*')
$script:Mode = 'nolibrary'; $st = Get-PackTuneStoreState
Test-Check 'discovery: site there, library missing -> NoLibrary' ($st.State -eq 'NoLibrary')

# --- setup with a fake Graph of the administrator
$script:Calls = New-Object System.Collections.ArrayList
$script:GroupExists = $null
$script:SitePolls = 0; $script:SiteReadyAfter = 3
$script:SiteExists = $false
$script:Drives = @()
$script:WebUrl = 'https://contoso.sharepoint.com/sites/PackTune'
$script:Slept = New-Object System.Collections.ArrayList
$script:FailMember = $false
$script:Created = $null
$script:Perms = @(); $script:DropGrant = $false; $script:PatchTries = 0; $script:PatchFails = 0
function Wait-PackTuneStore([int]$Seconds) { [void]$script:Slept.Add($Seconds) }
function Invoke-PackTuneAdminGraph {
    param([string]$Token, [string]$Method = 'GET', [string]$Path, $Body)
    [void]$script:Calls.Add(@{ Method = $Method; Path = $Path; Body = $Body; Token = $Token })
    switch -Regex ("$Method $Path") {
        '^GET /sites/contoso\.sharepoint\.com:/sites/([^?]+)\?' { if ($script:SiteExists) { return [pscustomobject]@{ id = 'site-9'; webUrl = "https://contoso.sharepoint.com/sites/$($Matches[1])" } } throw 'Graph GET failed (404): Requested site could not be found' }
        '^GET /groups\?\$filter=mailNickname' { return [pscustomobject]@{ value = @($(if ($script:GroupExists) { [pscustomobject]$script:GroupExists })) } }
        '^GET /me' { return [pscustomobject]@{ id = 'user-1'; displayName = 'Ada Admin' } }
        '^POST /groups$' { $script:Created = $Body; return [pscustomobject]@{ id = 'group-1'; displayName = $Body.displayName } }
        '^PATCH /groups/' { $script:PatchTries++; if ($script:PatchTries -le $script:PatchFails) { throw 'Graph PATCH failed (404): Resource not found' }; return $null }
        '^GET /groups/([^/]+)/sites/root' { $script:SitePolls++; if ($script:SitePolls -lt $script:SiteReadyAfter) { throw 'Graph GET failed (404): The site is not ready' }; return [pscustomobject]@{ id = 'site-9'; webUrl = $script:WebUrl } }
        '^GET /groups\?\$filter=displayName' { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'group-admins'; displayName = 'Intune Admins' }) } }
        '^POST /groups/[^/]+/members/\$ref' { if ($script:FailMember) { throw 'Graph POST failed (400): not allowed' }; return $null }
        '^GET /sites/site-9/drives' { return [pscustomobject]@{ value = @($script:Drives) } }
        '^POST /sites/site-9/lists$' { $script:Drives += [pscustomobject]@{ id = 'd9'; name = $Body.displayName }; return [pscustomobject]@{ id = 'list-9' } }
        '^POST /sites/site-9/permissions$' {
            if (-not $script:DropGrant) { $script:Perms += @{ id = "perm-$($script:Perms.Count + 1)"; roles = @($Body.roles); grantedToIdentitiesV2 = @(@{ application = @{ id = $Body.grantedToIdentities[0].application.id; displayName = $Body.grantedToIdentities[0].application.displayName } }) } }
            return $null
        }
        '^GET /sites/site-9/permissions$' { return [pscustomobject]@{ value = @($script:Perms | ForEach-Object { [pscustomobject]$_ }) } }
        '^DELETE /sites/site-9/permissions/(.+)$' { $id = $Matches[1]; $script:Perms = @($script:Perms | Where-Object { $_.id -ne $id }); return $null }
        default { throw "fake admin Graph: $Method $Path" }
    }
}
$client = '11111111-2222-3333-4444-555555555555'
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client -AdminGroup 'Intune Admins'
$g = $script:Created
Test-Check 'setup: a private Microsoft 365 group PackTune, hidden in Outlook, no welcome mail, signing administrator as owner' ($r.State -eq 'Ready' -and $g.displayName -eq 'PackTune' -and $g.mailNickname -eq 'packtune' -and $g.visibility -eq 'Private' -and ($g.groupTypes -contains 'Unified') -and $g.mailEnabled -and -not $g.securityEnabled -and ($g.resourceBehaviorOptions -contains 'HideGroupInOutlook') -and ($g.resourceBehaviorOptions -contains 'WelcomeEmailDisabled') -and ($g.resourceBehaviorOptions -notcontains 'SubscribeNewGroupMembers') -and ($g.'owners@odata.bind' -like '*users/user-1') -and ($g.description -like '*PackTune package store*'))
Test-Check 'setup: hidden from the address lists (best effort)' (@($script:Calls | Where-Object { $_.Method -eq 'PATCH' -and $_.Body.hideFromAddressLists }).Count -eq 1)
Test-Check 'setup: waits for the site of the group, polling with a growing pause (2, 4)' ($script:SitePolls -eq 3 -and ($script:Slept -join ',') -eq '2,4') "$($script:SitePolls) / $($script:Slept -join ',')"
Test-Check 'setup: the chosen Entra group becomes a member' (@($script:Calls | Where-Object { $_.Path -like '/groups/group-1/members/$ref' -and $_.Body.'@odata.id' -like '*groups/group-admins' }).Count -eq 1)
Test-Check 'setup: library created on the site, then the app registration gets role write on that one site' (@($script:Drives | Where-Object name -eq 'PackTune Packages').Count -eq 1 -and @($script:Calls | Where-Object { $_.Path -eq '/sites/site-9/permissions' -and $_.Body.roles -eq 'write' -and $_.Body.grantedToIdentities[0].application.id -eq $client }).Count -eq 1)
Test-Check 'setup: every call used the setup token, the result names the site and the steps' (@($script:Calls | Where-Object { $_.Token -ne 'admin-token' }).Count -eq 0 -and $r.SiteUrl -eq 'https://contoso.sharepoint.com/sites/PackTune' -and @($r.Steps).Count -ge 5 -and @($r.Warnings).Count -eq 0)
# the site exists already: nothing is created, library and grant are made
$script:Calls.Clear(); $script:SiteExists = $true; $script:Drives = @(); $script:Created = $null
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'setup: a site that exists is used, no group is made' ($r.State -eq 'Ready' -and -not $script:Created -and @($script:Calls | Where-Object { $_.Path -like '/groups*' }).Count -eq 0 -and @($script:Drives).Count -eq 1)
$script:Calls.Clear()
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'setup: again is harmless (the library is not made twice)' (@($script:Drives).Count -eq 1 -and @($script:Calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -like '*lists' }).Count -eq 0)
# a group of that nickname that is not ours: conflict
$script:Calls.Clear(); $script:SiteExists = $false; $script:SitePolls = 0; $script:Created = $null
$script:GroupExists = @{ id = 'foreign-1'; displayName = 'PackTune (Marketing)'; description = 'Marketing team' }
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'conflict: a group with that mail nickname that is not ours changes nothing and offers PackTune-Packages' ($r.State -eq 'Conflict' -and $r.FallbackName -eq 'PackTune-Packages' -and $r.Message -like '*not made by PackTune*' -and -not $script:Created -and @($script:Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
$script:GroupExists = $null; $script:SitePolls = 0
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client -SiteName 'PackTune-Packages'
Test-Check 'conflict: with the fallback name the group is made under it' ($r.State -eq 'Ready' -and $script:Created.mailNickname -eq 'packtune-packages' -and $script:Created.displayName -eq 'PackTune Packages')
# our own group without a site yet is used instead of making another
$script:GroupExists = @{ id = 'group-1'; displayName = 'PackTune'; description = 'PackTune package store: packages' }
$script:Calls.Clear(); $script:SitePolls = 0; $script:Created = $null
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'our own group (made by an earlier run) is used, none is made' ($r.State -eq 'Ready' -and -not $script:Created)
# the site never comes
$script:SitePolls = 0; $script:SiteReadyAfter = 9999; $script:Slept.Clear()
$msg = ''; try { $null = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client -PollMinutes 0 } catch { $msg = $_.Exception.Message }
Test-Check 'setup: a site that does not come in time is an error that says to run Set up again' ($msg -like '*not ready after*Run Set up again*') $msg
# an Entra group that cannot be added is a warning, the setup goes on
$script:SitePolls = 0; $script:SiteReadyAfter = 1; $script:FailMember = $true; $script:GroupExists = $null
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client -AdminGroup 'Intune Admins'
Test-Check 'setup: an Entra group that cannot be added is a warning, the store is set up anyway' ($r.State -eq 'Ready' -and @($r.Warnings).Count -eq 1 -and $r.Warnings[0] -like '*could not be added*')
$threw = $false; try { $null = Initialize-PackTuneStoreSite -Token 'x' -SiteName 'bad name' } catch { $threw = $true }
Test-Check 'setup: an invalid site name is refused' $threw
Set-Tenant 'contoso.com'; $Global:AccessToken = $null
$threw = $false; try { $null = Initialize-PackTuneStoreSite -Token 'x' -ClientID $client } catch { $threw = $_.Exception.Message -like '*SharePoint address of the tenant*' }
Test-Check 'setup: without a known SharePoint host it says to use the advanced address' $threw

# --- the permission goes to PackTune's OWN app registration, read back; the setup app of Microsoft never holds it
$setupId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$s = Get-PackTuneSettings; $s.ClientID = $client; $s.TenantID = 'contoso.onmicrosoft.com'; [void](Save-PackTuneSettings -Settings $s); $script:Settings = Get-PackTuneSettings; $script:StoreHost = $null
Test-Check 'client id: the settings of PackTune give its own app registration' ((Get-PackTuneAppClientId) -eq $client)
# Settings of an earlier version that still hold the setup app (Save-PackTuneSettings refuses it, see Check-ClientId): in memory only
$saveMsg = ''; try { $s.ClientID = $setupId; [void](Save-PackTuneSettings -Settings $s) } catch { $saveMsg = $_.Exception.Message }
Test-Check 'client id: the setup app of Microsoft cannot be saved as the client id' ($saveMsg -like '*Microsoft Graph Command Line Tools*') $saveMsg
$script:Settings = Get-PackTuneSettings; $script:Settings.ClientID = $setupId
$Global:AccessToken = [pscustomobject]@{ ClientID = $client; access_token = 'x.e30.y' }
$msgFirst = ''; try { $null = Get-PackTuneAppClientId } catch { $msgFirst = $_.Exception.Message }
Test-Check 'client id: when the settings hold the setup app of Microsoft it is refused, whatever the sign-in says' ($msgFirst -like 'App registration missing - set it up first*')
$Global:AccessToken = $null
$msg = ''; try { $null = Get-PackTuneAppClientId } catch { $msg = $_.Exception.Message }
Test-Check 'client id: only the setup app known -> an error, nothing is granted to it' ($msg -like 'App registration missing*') $msg
$s.ClientID = $client; [void](Save-PackTuneSettings -Settings $s); $script:Settings = Get-PackTuneSettings
$script:Perms = @(); $script:SiteExists = $true; $script:Drives = @(); $script:Calls.Clear()
$r = Initialize-PackTuneStoreSite -Token 'admin-token'
Test-Check 'setup: without -ClientID the permission goes to the app registration of the settings, listed back with its name' ($r.State -eq 'Ready' -and @($script:Perms).Count -eq 1 -and $script:Perms[0].grantedToIdentitiesV2[0].application.id -eq $client -and $script:Perms[0].grantedToIdentitiesV2[0].application.displayName -eq 'PackTune' -and @($script:Calls | Where-Object { $_.Method -eq 'GET' -and $_.Path -eq '/sites/site-9/permissions' }).Count -ge 1)
$msg = ''; try { $null = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $setupId } catch { $msg = $_.Exception.Message }
Test-Check 'setup: the setup app of Microsoft is refused as holder of the permission' ($msg -like '*not to the setup app of Microsoft*' -and @($script:Perms | Where-Object { $_.grantedToIdentitiesV2[0].application.id -eq $setupId }).Count -eq 0) $msg
$script:Perms = @(); $script:DropGrant = $true
$msg = ''; try { $null = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client } catch { $msg = $_.Exception.Message }
Test-Check 'setup: a permission the site does not list afterwards is an error (read back)' ($msg -like '*does not list PackTune*when read back*') $msg
$script:DropGrant = $false
# an earlier version granted the setup app: found, reported, removed on request
$script:Perms = @(@{ id = 'perm-old'; roles = @('write'); grantedToIdentitiesV2 = @(@{ application = @{ id = $setupId; displayName = 'PackTune' } }) })
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'repair: the site where the setup app holds a permission reports it, PackTune gets its own permission' ($r.WrongGrants -eq 1 -and @($r.Warnings | Where-Object { $_ -like '*setup app of Microsoft holds a permission*' }).Count -eq 1 -and @($script:Perms | Where-Object { $_.grantedToIdentitiesV2[0].application.id -eq $client }).Count -eq 1)
$null = @(Remove-PackTuneStoreWrongGrants -Token 'admin-token' -SiteId 'site-9')
Test-Check 'repair: removing the wrong grant takes only the setup app off, PackTune keeps its own' (@($script:Perms | Where-Object { $_.grantedToIdentitiesV2[0].application.id -eq $setupId }).Count -eq 0 -and @($script:Perms | Where-Object { $_.grantedToIdentitiesV2[0].application.id -eq $client }).Count -eq 1)
$script:Perms = @()
$g = Grant-PackTuneStoreAccess -SiteUrl 'https://contoso.sharepoint.com/sites/PackTune' -ClientID $client -Token 'admin-token'
Test-Check 'grant only (Grant access): own client id, read back, result says whether a wrong grant exists' ($g.ClientId -eq $client -and $g.WrongGrants -eq 0 -and @($script:Perms).Count -eq 1)
$msg = ''; try { $null = Grant-PackTuneStoreAccess -SiteUrl 'https://contoso.sharepoint.com/sites/PackTune' -ClientID $setupId -Token 'admin-token' } catch { $msg = $_.Exception.Message }
Test-Check 'grant only: the setup app as target is refused' ($msg -like '*not to the setup app of Microsoft*') $msg

# --- hiding the group from the address lists: retried (replication), information when it never works
$script:SiteExists = $false; $script:GroupExists = $null; $script:SitePolls = 0; $script:SiteReadyAfter = 1; $script:Perms = @(); $script:Drives = @(); $script:Slept.Clear(); $script:PatchTries = 0; $script:PatchFails = 2
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'hide from address lists: a 404 right after the group was made is retried with a growing pause and then works' ($script:PatchTries -eq 3 -and ($script:Slept -join ',') -like '2,4*' -and @($r.Steps | Where-Object { $_ -like 'The group is hidden from the address lists' }).Count -eq 1 -and @($r.Warnings).Count -eq 0)
$script:SiteExists = $false; $script:GroupExists = $null; $script:SitePolls = 0; $script:Perms = @(); $script:Drives = @(); $script:PatchTries = 0; $script:PatchFails = 99
$r = Initialize-PackTuneStoreSite -Token 'admin-token' -ClientID $client
Test-Check 'hide from address lists: when it never works it is information in the steps, not a warning, the setup goes on' ($r.State -eq 'Ready' -and @($r.Warnings).Count -eq 0 -and @($r.Steps | Where-Object { $_ -like 'Info: the group could not be hidden from the address lists*' }).Count -eq 1 -and $script:PatchTries -eq 5)

# --- the readiness check: mapped causes, a short timeout
$script:StoreTimeoutSec = 300
$seenTimeout = 0
function Invoke-PackTuneStoreGraph {
    param([string]$Method = 'GET', [string]$Path, [string]$Absolute, $Body, [string]$InFile, [byte[]]$Bytes, [string]$OutFile, [hashtable]$Headers = @{})
    $script:seenTimeout = $script:StoreTimeoutSec
    throw $script:GraphError
}
$script:GraphError = 'SharePoint GET failed (403): Access denied'
$st = Get-PackTuneStoreState
Test-Check 'check: a 403 says PackTune has no access yet and an administrator confirms it once (the Grant access case)' ($st.State -eq 'NoAccess' -and $st.Message -like '*no access to the site yet - an administrator confirms it once*Grant access*')
Test-Check 'check: the request has a short timeout (30 s), restored afterwards' ($script:seenTimeout -eq 30 -and $script:StoreTimeoutSec -eq 300)
$script:GraphError = 'Der Remotename konnte nicht aufgel?st werden'
Test-Check 'check: a network error is its own short cause' ((Get-PackTuneStoreState).Message -like '*cannot be reached*')
$script:GraphError = 'The operation has timed out.'
Test-Check 'check: a timeout is its own short cause' ((Get-PackTuneStoreState).Message -like '*did not answer in time*')


# --- the token for the store: the cause of a failure decides the text (no network is no missing grant)
$Global:AccessToken = [pscustomobject]@{ access_token = 'x.e30.y'; RefreshToken = 'r'; ClientID = '11111111-2222-3333-4444-555555555555'; ExpiresOn = (Get-Date).AddHours(1).ToUniversalTime() }
$Global:AccessTokenTenantID = 'contoso.onmicrosoft.com'
function Assert-PackTuneConnection { }
function Update-PackTuneToken { }
$script:StoreToken = $null
function Invoke-PackTuneTokenRequest { throw "Der Remotename konnte nicht aufgel$([char]0xF6)st werden: 'login.microsoftonline.com'" }
$m = ''; try { [void](Get-PackTuneStoreToken) } catch { $m = $_.Exception.Message }
Test-Check 'store token: a DNS failure says no connection (network), not a missing grant' ($m -like 'No connection to Microsoft (network)*' -and $m -notlike '*does not hold Sites.Selected*') $m
function Invoke-PackTuneTokenRequest { throw 'Response status code does not indicate success: 403 (Forbidden). AADSTS65001: consent' }
$m = ''; try { [void](Get-PackTuneStoreToken) } catch { $m = $_.Exception.Message }
Test-Check 'store token: 403 / missing consent says the grant is missing' ($m -like 'No access to the package store*Sites.Selected*') $m
Remove-Item function:Invoke-PackTuneTokenRequest
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
