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
function Wait-PackTuneStore([int]$Seconds) { [void]$script:Slept.Add($Seconds) }
function Invoke-PackTuneAdminGraph {
    param([string]$Token, [string]$Method = 'GET', [string]$Path, $Body)
    [void]$script:Calls.Add(@{ Method = $Method; Path = $Path; Body = $Body; Token = $Token })
    switch -Regex ("$Method $Path") {
        '^GET /sites/contoso\.sharepoint\.com:/sites/([^?]+)\?' { if ($script:SiteExists) { return [pscustomobject]@{ id = 'site-9'; webUrl = "https://contoso.sharepoint.com/sites/$($Matches[1])" } } throw 'Graph GET failed (404): Requested site could not be found' }
        '^GET /groups\?\$filter=mailNickname' { return [pscustomobject]@{ value = @($(if ($script:GroupExists) { [pscustomobject]$script:GroupExists })) } }
        '^GET /me' { return [pscustomobject]@{ id = 'user-1'; displayName = 'Ada Admin' } }
        '^POST /groups$' { $script:Created = $Body; return [pscustomobject]@{ id = 'group-1'; displayName = $Body.displayName } }
        '^PATCH /groups/' { return $null }
        '^GET /groups/([^/]+)/sites/root' { $script:SitePolls++; if ($script:SitePolls -lt $script:SiteReadyAfter) { throw 'Graph GET failed (404): The site is not ready' }; return [pscustomobject]@{ id = 'site-9'; webUrl = $script:WebUrl } }
        '^GET /groups\?\$filter=displayName' { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'group-admins'; displayName = 'Intune Admins' }) } }
        '^POST /groups/[^/]+/members/\$ref' { if ($script:FailMember) { throw 'Graph POST failed (400): not allowed' }; return $null }
        '^GET /sites/site-9/drives' { return [pscustomobject]@{ value = @($script:Drives) } }
        '^POST /sites/site-9/lists$' { $script:Drives += [pscustomobject]@{ id = 'd9'; name = $Body.displayName }; return [pscustomobject]@{ id = 'list-9' } }
        '^POST /sites/site-9/permissions$' { return $null }
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
$threw = $false; try { $null = Initialize-PackTuneStoreSite -Token 'x' } catch { $threw = $_.Exception.Message -like '*SharePoint address of the tenant*' }
Test-Check 'setup: without a known SharePoint host it says to use the advanced address' $threw

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
