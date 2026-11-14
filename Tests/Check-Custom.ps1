<#
.SYNOPSIS
    Checks of the custom applications (PackTune-Custom.ps1): reading an MSI without installing it, the device scripts,
    the notes marker, deployment and a new version through supersedence with the fake IntuneWin32App module.
    The MSI files are made here with the Windows Installer API (a Property table only: readable, not installable);
    nothing is installed and no tenant is used.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Custom.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneCustom-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PSModulePath = (Join-Path $PSScriptRoot 'Fakes') + ';' + $env:PSModulePath
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }

. (Join-Path $repo 'PackTune-Main.ps1')
Import-Module IntuneWin32App -Force
$Global:AccessToken = [pscustomobject]@{ ExpiresOn = (Get-Date).AddHours(2).ToUniversalTime(); access_token = 'x.e30.y' }
$Global:AuthenticationHeader = @{ Authorization = 'Bearer x'; ExpiresOn = $Global:AccessToken.ExpiresOn }
$Global:AccessTokenTenantID = 'contoso.onmicrosoft.com'
function Get-Store { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }

function New-TestMsi {
    # A Property table is all PackTune reads; the file is not installable
    param([string]$Path, [hashtable]$Properties)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 3))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(255) NOT NULL PRIMARY KEY `Property`)'))
    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    foreach ($key in $Properties.Keys) {
        $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('$key', '$($Properties[$key])')"))
        [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
        [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    }
    [void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
    foreach ($o in $v, $view, $db, $installer) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
$upgrade = '{11111111-2222-3333-4444-555555555555}'
$msi1 = Join-Path $work 'contoso-tool-1.0.msi'
$msi2 = Join-Path $work 'contoso-tool-2.0.msi'
$msiOther = Join-Path $work 'other-product.msi'
$msiSame = Join-Path $work 'contoso-tool-same-code.msi'
New-TestMsi $msi1 @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}'; ProductName = 'Contoso Tool'; ProductVersion = '1.0.0'; Manufacturer = 'Contoso Ltd'; UpgradeCode = $upgrade }
New-TestMsi $msi2 @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000002}'; ProductName = 'Contoso Tool'; ProductVersion = '2.0.0'; Manufacturer = 'Contoso Ltd'; UpgradeCode = $upgrade }
New-TestMsi $msiOther @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000003}'; ProductName = 'Other Product'; ProductVersion = '3.0.0'; Manufacturer = 'Other'; UpgradeCode = '{99999999-2222-3333-4444-555555555555}' }
New-TestMsi $msiSame @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}'; ProductName = 'Contoso Tool'; ProductVersion = '1.5.0'; Manufacturer = 'Contoso Ltd'; UpgradeCode = $upgrade }

# --- reading an MSI
$p = Get-PackTuneMsiProperties -Path $msi1
Test-Check 'MSI: properties are read without installing it' (($p['ProductName'] -eq 'Contoso Tool') -and ($p['ProductVersion'] -eq '1.0.0') -and ($p['ProductCode'] -eq '{AAAAAAAA-0000-0000-0000-000000000001}'))
$info1 = Get-PackTuneMsiInfo -Path $msi1
Test-Check 'MSI info: name, version, manufacturer, product and upgrade code, hash' (($info1.Name -eq 'Contoso Tool') -and ($info1.Version -eq '1.0.0') -and ($info1.Manufacturer -eq 'Contoso Ltd') -and ($info1.ProductCode -eq '{AAAAAAAA-0000-0000-0000-000000000001}') -and ($info1.UpgradeCode -eq $upgrade) -and ($info1.Sha256 -match '^[0-9A-F]{64}$'))
$appId = Get-PackTuneCustomAppId $info1
Test-Check 'app id: readable and the same for every version of the product' (($appId -match '^contoso-tool-[0-9a-f]{8}$') -and ($appId -eq (Get-PackTuneCustomAppId (Get-PackTuneMsiInfo -Path $msi2))))
$notMsi = Join-Path $work 'readme.txt'; 'x' | Set-Content $notMsi
$bad = @(
    @($notMsi, 'not an .msi'),
    @((Join-Path $work 'missing.msi'), 'missing file')
)
foreach ($b in $bad) { $threw = $false; try { $null = Get-PackTuneMsiInfo -Path $b[0] } catch { $threw = $true }; Test-Check "MSI info refuses: $($b[1])" $threw }
$fake = Join-Path $work 'fake.msi'; 'this is not an installer database' | Set-Content $fake
$threw = $false; try { $null = Get-PackTuneMsiInfo -Path $fake } catch { $threw = $_.Exception.Message -like '*not a readable MSI*' }
Test-Check 'MSI info refuses a file that is no MSI database' $threw
$noCode = Join-Path $work 'nocode.msi'; New-TestMsi $noCode @{ ProductName = 'X'; ProductVersion = '1.0' }
$threw = $false; try { $null = Get-PackTuneMsiInfo -Path $noCode } catch { $threw = $_.Exception.Message -like '*ProductCode*' }
Test-Check 'MSI info refuses an MSI without a valid ProductCode' $threw
$badVer = Join-Path $work 'badver.msi'; New-TestMsi $badVer @{ ProductCode = '{AAAAAAAA-0000-0000-0000-0000000000FF}'; ProductName = 'X'; ProductVersion = 'one.two' }
$threw = $false; try { $null = Get-PackTuneMsiInfo -Path $badVer } catch { $threw = $_.Exception.Message -like '*ProductVersion*' }
Test-Check 'MSI info refuses a version that is no number' $threw
Test-Check 'MSI: no icon in the file, no icon taken' ($null -eq (Get-PackTuneMsiIconBase64 -Info $info1))

# --- msiexec arguments
Test-Check 'arguments: public properties become NAME="value"' ((ConvertTo-PackTuneMsiArguments @{ ALLUSERS = '1' }) -eq 'ALLUSERS="1"')
foreach ($b in @(@{ 'lower' = '1' }, @{ 'BAD NAME' = '1' }, @{ 'X' = 'a"b' }, @{ 'X' = 'a`b' }, @{ 'X' = "a`nb" })) {
    $threw = $false; try { $null = ConvertTo-PackTuneMsiArguments $b } catch { $threw = $true }
    Test-Check "arguments refused: $(($b.Keys | Select-Object -First 1))=$(($b.Values | Select-Object -First 1) -replace '\s', '_')" $threw
}

# --- device scripts
$scripts = Get-PackTuneCustomMsiScripts -Info $info1 -AppId $appId -ExtraArguments 'ALLUSERS="1"'
foreach ($pair in @(@('install', $scripts.Install), @('detection', $scripts.Detection))) {
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($pair[1], [ref]$tokens, [ref]$errors)
    Test-Check "$($pair[0]) script: valid PowerShell, ASCII, no placeholder" (($errors.Count -eq 0) -and ($pair[1] -notmatch '[^\x00-\x7F]') -and ($pair[1] -notmatch '__[A-Z0-9]+__')) (@($errors | ForEach-Object Message) -join '; ')
}
$i = $scripts.Install
Test-Check 'install script: lock, protected folders, SIDs, 64-bit relaunch, device log' (($i -match 'Global\\PackTune') -and ($i -match 'Enter-DeploymentLock') -and ($i -match 'Exit-DeploymentLock') -and ($i -match 'Protect-Folder \$AppRoot') -and ($i -match 'S-1-5-18') -and ($i -match 'Sysnative') -and ($i -match 'Write-DeviceLog'))
Test-Check 'install script: silent msiexec, uninstall by product code, success codes, hash check before the install' (($i -match '/i `"\$Msi`" /qn /norestart') -and ($i -match '/x \$ProductCode /qn /norestart') -and ($i -match '\$Success = 0, 1641, 3010') -and ($i -match 'Get-FileHash') -and ($i.IndexOf('Get-FileHash') -lt $i.IndexOf('Invoke-Msi "/i')))
Test-Check 'install script: the values of this MSI are baked in' (($i -match [regex]::Escape($info1.ProductCode)) -and ($i -match $info1.Sha256) -and ($i -match "\`$Version = '1.0.0'") -and ($i -match "\`$ExtraArguments = 'ALLUSERS=`"1`"'") -and ($i -match 'contoso-tool-1.0.msi'))
Test-Check 'install script: the MSI is installed from the protected folder, not from the Intune cache' ($i -match 'Join-Path \$AppRoot \$MsiFile' -and $i -match 'Copy-Item -LiteralPath \(Join-Path \$PSScriptRoot \$MsiFile\)')
Test-Check 'install script: 1618 when another installation holds the lock' ($i -match 'exit 1618')
$d = $scripts.Detection
Test-Check 'detection: product code in both registry views, version compared, no time limit' (($d -match 'Registry64') -and ($d -match 'Registry32') -and ($d -match [regex]::Escape($info1.ProductCode)) -and ($d -match '\[version\]\$Installed -lt \[version\]\$Version') -and ($d -notmatch 'Get-Date|UtcNow'))
# the detection is read only: with a product code that is not installed it answers "not installed"
$detFile = Join-Path $work 'detect.ps1'
Set-Content $detFile ($d.Replace($info1.ProductCode, '{DEADBEEF-0000-0000-0000-00000000F00D}')) -Encoding ASCII
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $detFile | Out-Null
Test-Check 'detection: an unknown product code is not installed (exit 1)' ($LASTEXITCODE -eq 1) $LASTEXITCODE

# --- notes
$notes = ConvertTo-PackTuneCustomNotes -Info $info1 -AppId $appId
$back = ConvertFrom-PackTuneCustomNotes $notes
Test-Check 'notes: PoweredByPackTune;custom=msi with app, version, product and upgrade code' (($notes -like 'PoweredByPackTune;custom=msi;app=contoso-tool-*;ver=1.0.0;product={AAAAAAAA-0000-0000-0000-000000000001};upgrade=*') -and ($back.Kind -eq 'msi') -and ($back.Version -eq '1.0.0') -and ($back.ProductCode -eq $info1.ProductCode) -and ($back.UpgradeCode -eq $upgrade) -and ($back.AppId -eq $appId)) $notes
Test-Check 'notes: other notes are not custom notes' (($null -eq (ConvertFrom-PackTuneCustomNotes 'PoweredByPackTune;from=Winget;package=x')) -and ($null -eq (ConvertFrom-PackTuneCustomNotes 'PoweredByChocolatey;package=x')) -and ($null -eq (ConvertFrom-PackTuneCustomNotes '')) -and ($null -eq (ConvertFrom-PackTuneCustomNotes 'PoweredByPackTune;custom=evil;app=x')))
Test-Check 'notes: a custom app is no catalog app (source unknown)' ($null -eq (Get-PackTuneNotesSource $notes))
Test-Check 'notes stay short' ($notes.Length -lt 300) $notes.Length

# --- deploy
$id1 = New-PackTuneCustomMsiApp -MsiPath $msi1 -Assignment Available -Properties @{ ALLUSERS = '1' }
$a1 = Get-Store | Where-Object id -eq $id1
Test-Check 'deploy: a Win32 app with the MSI name, version, publisher, notes and assignment' (($a1.displayName -eq 'Contoso Tool') -and ($a1.displayVersion -eq '1.0.0') -and ($a1.publisher -eq 'Contoso Ltd') -and ($a1.notes -eq $notes) -and ($a1.assignment -eq 'available'))
$detText = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($a1.detection))
Test-Check 'deploy: detection rule is the product code script' (($detText -match [regex]::Escape($info1.ProductCode)) -and ($a1.install -match 'install\.ps1'))
Test-Check 'deploy: no dependency app (msiexec is part of Windows)' (@($a1.dependencies).Count -eq 0)
Test-Check 'deploy: the work folder holds install.ps1 and the MSI' ((Test-Path (Join-Path $work "PackTune\package\custom-$appId\source\install.ps1")) -and (Test-Path (Join-Path $work "PackTune\package\custom-$appId\source\contoso-tool-1.0.msi")))
$again = $false; $againMsg = ''; try { $null = New-PackTuneCustomMsiApp -MsiPath $msi1 -Assignment None } catch { $againMsg = $_.Exception.Message; $again = $againMsg -like '*deployed already*' }
Test-Check 'deploy: the same product code is refused' ($again -and (@(Get-Store).Count -eq 1)) "msg=$againMsg count=$(@(Get-Store).Count)"
$list = @(Get-PackTuneCustomApps -WithAssignments)
Test-Check 'list: found by the marker, with product code, version and intents' (($list.Count -eq 1) -and ($list[0].ProductCode -eq $info1.ProductCode) -and ($list[0].Version -eq '1.0.0') -and ($list[0].Intents -contains 'available') -and ($list[0].Source -eq 'Custom'))
Test-Check 'catalog lists do not contain custom apps' (@(Get-PackTuneTenantApps).Count -eq 0)

# --- new version
$threw = $false; try { $null = Publish-PackTuneCustomVersion -AppId $id1 -MsiPath $msiSame } catch { $threw = $_.Exception.Message -like '*same product code*' }
Test-Check 'new version: the same product code is refused' $threw
$threw = $false; try { $null = Publish-PackTuneCustomVersion -AppId $id1 -MsiPath $msiOther } catch { $threw = $_.Exception.Message -like '*another product*' }
Test-Check 'new version: an MSI of another product is refused' $threw
$threw = $false; try { $null = Publish-PackTuneCustomVersion -AppId $id1 -MsiPath $msi1 } catch { $threw = $true }
Test-Check 'new version: the same MSI again is refused' $threw
$id2 = Publish-PackTuneCustomVersion -AppId $id1 -MsiPath $msi2
$a2 = Get-Store | Where-Object id -eq $id2
$o1 = Get-Store | Where-Object id -eq $id1
Test-Check 'new version: new app 2.0.0 with the name and publisher of the old one' (($id2 -ne $id1) -and ($a2.displayName -eq 'Contoso Tool') -and ($a2.displayVersion -eq '2.0.0') -and ($a2.notes -like '*;ver=2.0.0;product={AAAAAAAA-0000-0000-0000-000000000002};*'))
Test-Check 'new version: supersedes the old app (update) and takes its Available assignment with auto-update' ((@($a2.supersedence).Count -eq 1) -and ($a2.supersedence[0].targetId -eq $id1) -and ($a2.supersedence[0].supersedenceType -eq 'update') -and (@($a2.assignments).Count -eq 1) -and ($a2.assignments[0].Intent -eq 'available') -and ($a2.assignments[0].AutoUpdateSupersededApps -eq 'enabled'))
Test-Check 'new version: the old app is untouched' (($o1.displayVersion -eq '1.0.0') -and ($o1.assignment -eq 'available') -and ($o1.uploads -eq 1))
Test-Check 'new version: both are listed, the new one in the superseded pairs' ((@(Get-PackTuneCustomApps).Count -eq 2) -and (@(Get-PackTuneSupersededApps).Count -eq 1) -and ((Get-PackTuneSupersededApps)[0].OldId -eq $id1))
$kept = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 2 })
Test-Check 'cleanup: the old version stays while devices have it' ((-not $kept[0].Removed) -and (@(Get-Store | Where-Object id -eq $id1).Count -eq 1))
$gone = @(Remove-PackTuneSupersededApps -InstallCount { param($Id) 0 })
Test-Check 'cleanup: removed when no device has it, the new app stays' (($gone[0].Removed) -and (@(Get-Store | Where-Object id -eq $id1).Count -eq 0) -and (@(Get-Store | Where-Object id -eq $id2).Count -eq 1))
$threw = $false; try { Remove-PackTuneCustomApp -Id 'no-such-app' } catch { $threw = $_.Exception.Message -like '*not a custom application*' }
Test-Check 'remove: only custom apps, anything else is refused' $threw
Remove-PackTuneCustomApp -Id $id2
Test-Check 'remove: the custom app is gone from the tenant' (@(Get-Store).Count -eq 0)

# --- other parts keep working
$insight = Import-Module (Join-Path $repo 'Modules\TenantInsight.psm1') -Force -PassThru
Set-TenantInsightHooks -Markers @{ Tool = $script:AppMarker; Winget = $script:WingetMarker; ChocolateyApp = $script:ChocoAppMarker; PackTune = $script:ToolMarker } -ConvertFromNotes ${function:ConvertFrom-PackTuneAppNotes} -ConvertToNotes ${function:ConvertTo-PackTuneAppNotes} -NewPolicy ${function:New-PackTuneAppPolicy} -NewChocoApp { } -NewWingetApp { } -SignIn { }
$class = @(Get-InsightClassification -RawApps @([pscustomobject]@{ id = 'c1'; displayName = 'Custom'; notes = $notes; createdDateTime = '2026-01-01T00:00:00Z'; AppType = 'Win32'; installCommandLine = 'x' }))
Test-Check 'import: a custom app is not taken for a Chocolatey app' (($class[0].Kind -ne 'ToolCreated') -and ($class[0].Source -ne 'Chocolatey')) "$($class[0].Kind)/$($class[0].Source)"

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
