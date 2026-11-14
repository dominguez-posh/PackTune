<#
.SYNOPSIS
    Checks of two bugs from a real tenant: (1) Microsoft's setup client (Microsoft Graph Command Line Tools,
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
$threw = $false; try { Connect-PackTune -TenantID 'contoso.onmicrosoft.com' -ClientID $setup } catch { $threw = $_.Exception.Message -like '*setup app*' }
Test-Check 'hard guard: no Intune sign-in with the setup client' $threw
$claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("{`"appid`":`"$setup`"}")).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$threw = $false; try { Set-PackTuneToken -TokenResponse ([pscustomobject]@{ access_token = "x.$claims.y"; expires_in = 3600 }) -TenantID 'contoso.onmicrosoft.com' -ClientID '22222222-3333-4444-5555-666666666666' } catch { $threw = $_.Exception.Message -like '*setup app*' }
Test-Check 'hard guard: a token issued to the setup app is never the Intune session' $threw
$threw = $false; try { Set-PackTuneToken -TokenResponse ([pscustomobject]@{ access_token = 'x.e30.y'; expires_in = 3600 }) -TenantID 'contoso.onmicrosoft.com' -ClientID $setup } catch { $threw = $_.Exception.Message -like '*setup app*' }
Test-Check 'hard guard: the setup client as ClientID of the session is refused' $threw
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
