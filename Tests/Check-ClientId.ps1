<#
.SYNOPSIS
    Checks of two bugs from a real tenant and the sign-in to any tenant: (1) Microsoft's setup client (Microsoft Graph Command Line Tools,
    14d82eec-...) saved as PackTune's client ID; (2) PackTune Runtime reported as deployed without an app in Intune, and
    created again while the app list of the tenant lagged behind. Fake IntuneWin32App module, no tenant, no network.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-ClientId.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneClientId-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pt = Join-Path $work 'PackTune'
New-Item -ItemType Directory -Path $pt -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PSModulePath = (Join-Path $PSScriptRoot 'Fakes') + ';' + $env:PSModulePath
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
$setup = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# --- (1) settings as found on the device: the setup client as ClientID and in TenantClients, scopes of its tokens remembered
@{ TenantID = 'contoso.onmicrosoft.com'; ClientID = $setup; TenantClients = "11111111-2222-3333-4444-555555555555=$setup;contoso.onmicrosoft.com=$setup;fabrikam.onmicrosoft.com=99999999-8888-7777-6666-555555555555" } |
    ConvertTo-Json | Set-Content (Join-Path $pt 'settings.json')
'{ "contoso.onmicrosoft.com": [ "Application.ReadWrite.All", "Policy.ReadWrite.AuthenticationMethod" ] }' | Set-Content (Join-Path $pt 'grantedscopes.json')
'[]' | Set-Content (Join-Path $work 'fake-intune.json')
. (Join-Path $repo 'PackTune-Main.ps1')
Import-Module IntuneWin32App -Force

$saved = Get-Content (Join-Path $pt 'settings.json') -Raw | ConvertFrom-Json
Test-Check 'repair on start: the setup client is removed from ClientID and TenantClients of the file' ($script:SetupClientRepaired -and -not $saved.ClientID -and [string]$saved.TenantClients -notmatch $setup -and [string]$saved.TenantClients -match 'fabrikam') ($saved | ConvertTo-Json -Compress)
Test-Check 'repair on start: the scopes remembered from the setup client tokens are dropped' (-not (Test-Path (Join-Path $pt 'grantedscopes.json')))
Test-Check 'settings in memory: no client ID, so the start page asks for the app registration (Create)' (-not $script:Settings.ClientID -and $script:Settings.TenantID -eq 'contoso.onmicrosoft.com')
Test-Check 'tenant lookup never answers with the setup client' ($null -eq (Get-PackTuneTenantClient 'contoso.onmicrosoft.com') -and (Get-PackTuneTenantClient 'fabrikam.onmicrosoft.com') -eq '99999999-8888-7777-6666-555555555555')
$s = Get-PackTuneSettings; $s.ClientID = $setup
$threw = $false; $msg = ''; try { Save-PackTuneSettings -Settings $s | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'hard guard: the setup client cannot be saved as ClientID' ($threw -and $msg -like '*Microsoft Graph Command Line Tools*') $msg
$s = Get-PackTuneSettings; $s.ClientID = '22222222-3333-4444-5555-666666666666'; $s.TenantClients = "x.onmicrosoft.com=$setup"
$null = Save-PackTuneSettings -Settings $s
Test-Check 'hard guard: a setup client pair in TenantClients is dropped on save' ([string](Get-PackTuneSettings).TenantClients -notmatch $setup -and (Get-PackTuneSettings).ClientID -eq '22222222-3333-4444-5555-666666666666') (Get-PackTuneSettings).TenantClients
# --- sign-in to any tenant without settings: through the setup app for the session, never saved as ClientID
function New-TestJwt([hashtable]$Claims) { 'x.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') + '.y' }
$tidA = 'aaaaaaaa-0000-4000-8000-000000000001'; $tidB = 'bbbbbbbb-0000-4000-8000-000000000002'; $me = 'cccccccc-0000-4000-8000-00000000000c'
$script:TenantGuidLookup = { param($d) switch ($d) { 'contoso.onmicrosoft.com' { 'aaaaaaaa-0000-4000-8000-000000000001' } 'fabrikam.onmicrosoft.com' { 'bbbbbbbb-0000-4000-8000-000000000002' } default { $null } } }
$script:PkceCalls = @()
function Invoke-PackTunePkceSignIn { param($TenantID, $ClientID, $TimeoutSeconds, $Authority, $UrlHandler, $ShouldCancel, $Scope)
    $script:PkceCalls += , @($TenantID, $ClientID)
    [pscustomobject]@{ access_token = (New-TestJwt @{ appid = $ClientID; tid = $script:NextTid; oid = $me; upn = 'admin@fabrikam.onmicrosoft.com' }); expires_in = 3600; scope = 'https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All' }
}
$empty = Get-PackTuneSettings; $empty.TenantID = ''; $empty.ClientID = ''; $empty.TenantClients = ''; $empty.TenantAliases = ''
$null = Save-PackTuneSettings -Settings $empty; $script:Settings = Get-PackTuneSettings
$t = Get-PackTuneSignInTarget
Test-Check 'empty settings: the sign-in goes to any tenant through the setup app' ($t.TenantID -eq 'organizations' -and $t.ClientID -eq $setup -and $t.Setup) ($t | ConvertTo-Json -Compress)
$script:NextTid = $tidB
$threw = ''; try { Connect-PackTune 6>$null } catch { $threw = $_.Exception.Message }
Test-Check 'empty settings: Connect-PackTune signs in (organizations, setup app), no "enter tenant and client ID" error' (-not $threw -and $script:PkceCalls[-1][0] -eq 'organizations' -and $script:PkceCalls[-1][1] -eq $setup) $threw
Test-Check 'the session is marked as setup app, the tenant is the one of the token' ($Global:AccessToken.SetupClient -and $Global:AccessTokenTenantID -eq $tidB -and $Global:AccessToken.ClientID -eq $setup)
Test-Check 'the setup app is not put into the settings (memory or file)' (-not $script:Settings.ClientID -and -not (Get-PackTuneSettings).ClientID)
$Global:AccessToken = $null

# The registration of the tenant after such a sign-in: Graph stand-in (organization, applications, owners)
$script:GraphApps = @(); $script:GraphCalls = @()
function Invoke-RestMethod { param($Method, $Uri, $Headers, $TimeoutSec, $ErrorAction, $Body)
    $script:GraphCalls += [string]$Uri
    $org = if ($script:NextTid -eq $tidA) { 'contoso' } else { 'fabrikam' }
    if ($Uri -like '*/organization*') { return @{ value = @(@{ verifiedDomains = @(@{ name = "$org.onmicrosoft.com"; isInitial = $true }, @{ name = "$org.com"; isInitial = $false }) }) } }
    if ($Uri -match '/applications/([^/]+)/owners') { $id = $Matches[1]; return @{ value = @(@($script:GraphApps | Where-Object { $_.id -eq $id })[0].owners | ForEach-Object { @{ id = $_ } }) } }
    if ($Uri -like '*/applications?*') { return @{ value = @($script:GraphApps) } }
    throw "unexpected $Uri"
}
function Set-SetupSession([string]$Tid) { $script:NextTid = $Tid; Connect-PackTune -TenantID '' -ClientID '' 6>$null }
Set-SetupSession $tidB
$r = Resolve-PackTuneSignInRegistration -GraphUrl 'https://graph.test' 3>$null
Test-Check 'not found: no registration in the tenant -> ClientID empty, tenant = initial domain of the token' ($r.Source -eq 'none' -and -not $r.ClientID -and $r.TenantID -eq 'fabrikam.onmicrosoft.com' -and $r.TenantGuid -eq $tidB) ($r | ConvertTo-Json -Compress)
$script:GraphApps = @(@{ id = 'o1'; appId = '44444444-0000-4000-8000-000000000004'; displayName = 'PackTune'; publicClient = @{ redirectUris = @('http://localhost') }; owners = @('someone-else') })
$r = Resolve-PackTuneSignInRegistration -GraphUrl 'https://graph.test' 3>$null
Test-Check 'not used: a registration of the same name owned by someone else' ($r.Source -eq 'none' -and -not $r.ClientID) ($r | ConvertTo-Json -Compress)
$script:GraphApps = @(@{ id = 'o2'; appId = '55555555-0000-4000-8000-000000000005'; displayName = 'Intune Chocolatey Deployment'; publicClient = @{ redirectUris = @('http://localhost') }; owners = @($me) })   # registration under the earlier name
$r = Resolve-PackTuneSignInRegistration -GraphUrl 'https://graph.test' 3>$null
Test-Check 'found: the registration owned by the signed-in admin (also under the earlier name)' ($r.Source -eq 'found' -and $r.ClientID -eq '55555555-0000-4000-8000-000000000005' -and $r.TenantID -eq 'fabrikam.onmicrosoft.com') ($r | ConvertTo-Json -Compress)
# Saved for that tenant (as the interface does): the tenant field follows the sign-in, TenantClients remembers it
$s = Get-PackTuneSettings; $s.TenantID = $r.TenantID; $s.ClientID = $r.ClientID; $null = Save-PackTuneSettings -Settings $s; $script:Settings = Get-PackTuneSettings
Register-PackTuneTenantAlias -Guid $r.TenantGuid -Name @($r.TenantID); $script:Settings = Get-PackTuneSettings
$t = Get-PackTuneSignInTarget
Test-Check 'after it was found: the next sign-in uses the registration of that tenant directly' ($t.TenantID -eq 'fabrikam.onmicrosoft.com' -and $t.ClientID -eq '55555555-0000-4000-8000-000000000005' -and -not $t.Setup) ($t | ConvertTo-Json -Compress)
# Tenant switch: another account signs in to any tenant; a known tenant answers from TenantClients without searching
$script:GraphApps = @(); $script:GraphCalls = @()
Set-SetupSession $tidB
$r = Resolve-PackTuneSignInRegistration -GraphUrl 'https://graph.test' 3>$null
Test-Check 'known tenant (by GUID): the remembered registration, no search in the tenant' ($r.Source -eq 'known' -and $r.ClientID -eq '55555555-0000-4000-8000-000000000005' -and -not @($script:GraphCalls | Where-Object { $_ -like '*/applications*' }).Count) ($r | ConvertTo-Json -Compress)
$script:NextTid = $tidA
$t = Get-PackTuneSignInTarget -TenantID '' -ClientID ''
Test-Check 'another account or tenant: any tenant through the setup app, whatever is saved' ($t.TenantID -eq 'organizations' -and $t.Setup)
Set-SetupSession $tidA
$r = Resolve-PackTuneSignInRegistration -GraphUrl 'https://graph.test' 3>$null
Test-Check 'tenant switch to a tenant without registration: its tenant, no client ID (Create offered)' ($r.TenantGuid -eq $tidA -and $r.TenantID -eq 'contoso.onmicrosoft.com' -and -not $r.ClientID -and $r.Source -eq 'none') ($r | ConvertTo-Json -Compress)
$t = Get-PackTuneSignInTarget -TenantID 'fabrikam.onmicrosoft.com' -ClientID ''
Test-Check 'a known tenant without the client ID typed in: its registration from TenantClients' ($t.ClientID -eq '55555555-0000-4000-8000-000000000005' -and -not $t.Setup)
$s = Get-PackTuneSettings; $s.ClientID = $setup
$threw = $false; try { Save-PackTuneSettings -Settings $s | Out-Null } catch { $threw = $true }
Test-Check 'the guard stays: the setup app is never saved as the client ID' $threw
$Global:AccessToken = $null
$gui = Get-Content (Join-Path $repo 'Start-PackTune.ps1') -Raw
Test-Check 'interface: no blocking "Enter tenant and the client ID" before the sign-in' ($gui -notmatch 'Enter tenant and the client ID of your app registration first')
Test-Check 'interface: after a sign-in through the setup app the registration is looked up and the sign-in switches to it' ($gui -match 'if \(\$setup\) \{ Start-RegistrationLookup \}' -and $gui -match 'Switch-SignInToRegistration \$client')
Remove-Item Function:\Invoke-RestMethod
$main = Get-Content (Join-Path $repo 'PackTune-Main.ps1') -Raw
$gui = Get-Content (Join-Path $repo 'Start-PackTune.ps1') -Raw
Test-Check 'app registration: a result with the setup client is never saved (function and the interface)' ($main -match 'if \(-not \$App\.appId -or \(Test-PackTuneSetupClient' -and $gui -match "PSObject\.Properties\['Account'\] -and -not \(Test-PackTuneSetupClient")
Test-Check 'start page: red item "App registration needed" with Create after the repair' ($gui -match 'elseif \(\$script:SetupClientRepaired -and -not \$script:Settings\.ClientID\) \{ "App registration needed' -and $gui -match 'if \(\$script:SetupClientRepaired\) \{ Write-UiLog')

# --- (2) PackTune Runtime: no success without an app, read back, duplicates found and listed
$Global:AccessToken = [pscustomobject]@{ ExpiresOn = (Get-Date).AddHours(2).ToUniversalTime(); access_token = 'x.e30.y' }
$Global:AuthenticationHeader = @{ Authorization = 'Bearer x'; ExpiresOn = $Global:AccessToken.ExpiresOn }
$script:RuntimeReadBackSeconds = 0
function Get-Store { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ }) }
New-Item -ItemType File -Path (Join-Path $work 'fake-add-silent') -Force | Out-Null
$threw = $false; $msg = ''; $log = ''
try { $log = (Get-PackTuneRuntimeWin32ID 6>&1 | Out-String) } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'module gives up (warning, no object): an error, never "successfully deployed"' ($threw -and $msg -like '*was not created*' -and $log -notmatch 'successfully deployed' -and @(Get-Store | Where-Object { $_.notes -like '*PackTuneRuntimeApp*' }).Count -eq 0) $msg
Remove-Item (Join-Path $work 'fake-add-silent')
$id1 = Get-PackTuneRuntimeWin32ID
Test-Check 'deploy: the created app is read back by its id, its id is remembered for the tenant' ($id1 -match '^[0-9a-f-]{36}$' -and @(Get-Store | Where-Object id -eq $id1).Count -eq 1 -and (Get-PackTuneRuntimeIdMemory) -contains $id1)
# The tenant list lags behind: the runtime is found by the remembered id, nothing is created a second time
New-Item -ItemType File -Path (Join-Path $work 'fake-list-lag') -Force | Out-Null
(Get-Item (Join-Path $work 'fake-list-lag')).LastWriteTime = (Get-Date).AddHours(-1)
$id2 = Get-PackTuneRuntimeWin32ID
Test-Check 'list lag: the runtime is found again by its remembered id, no second app' ($id2 -eq $id1 -and @(Get-Store | Where-Object { $_.notes -like '*PackTuneRuntimeApp*' }).Count -eq 1)
Remove-Item (Join-Path $work 'fake-list-lag')
# Duplicates from earlier runs (as in the tenant): found, the oldest is used, listed, removed only on request
$apps = @(Get-Content (Join-Path $work 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ })
$first = $apps[0]
$dupA = $first.PSObject.Copy(); $dupA.id = [guid]::NewGuid().ToString(); $dupA.createdDateTime = (Get-Date).AddMinutes(5).ToString('o')
$dupB = $first.PSObject.Copy(); $dupB.id = [guid]::NewGuid().ToString(); $dupB.createdDateTime = (Get-Date).AddMinutes(6).ToString('o')
ConvertTo-Json -InputObject @($apps + $dupA + $dupB) -Depth 6 | Set-Content (Join-Path $work 'fake-intune.json')
$state = Get-PackTuneRuntimeState
Test-Check 'duplicates: the oldest runtime is used, the two others are listed for a cleanup' ($state.RuntimeId -eq $id1 -and @($state.RuntimeDuplicates).Count -eq 2 -and (@($state.RuntimeDuplicates.Id) -contains $dupA.id) -and (@(Get-Store).Count -eq 3)) ($state | ConvertTo-Json -Depth 3 -Compress)
$null = Remove-PackTuneRuntimeDuplicates -WhatIf
Test-Check 'duplicates: nothing is removed without a confirmation (-WhatIf)' (@(Get-Store).Count -eq 3)
$removed = @(Remove-PackTuneRuntimeDuplicates -Confirm:$false)
Test-Check 'duplicates: on request the extra ones go, the oldest stays' (@($removed | Where-Object Removed).Count -eq 2 -and @(Get-Store).Count -eq 1 -and (Get-Store)[0].id -eq $id1) ($removed | ConvertTo-Json -Compress)
$rt = Get-Content (Join-Path $repo 'PackTune-Runtime.ps1') -Raw
Test-Check 'lookup: no display name filter of the module, the whole list plus the remembered ids' ($rt -notmatch 'Get-IntuneWin32App -DisplayName \$script:RuntimeName' -and $rt -match 'Invoke-IntuneModule \{ Get-IntuneWin32App \} \| Where-Object')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
