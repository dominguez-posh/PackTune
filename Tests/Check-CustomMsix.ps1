<#
.SYNOPSIS
    Checks of the custom MSIX applications ("Other", PackTune-CustomMsix.ps1): identity and fixed subject, the device
    scripts, the build with a certificate per version (made and removed around the capture, also on errors), the package
    store, deployment as ONE Win32 app, update on top of the stored previous version, export, delete. The sandbox
    module (Modules\PackTune.Sandbox.psm1, tested in Check-Sandbox.ps1) is replaced by stand-ins (the capture needs Windows Sandbox: it is run by hand and by Tests\Spike-MsixWin32.ps1 for
    the device side). Fake IntuneWin32App module and fake SharePoint; no tenant, no network.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-CustomMsix.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneMsix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
function Get-Store { $f = Join-Path $env:LOCALAPPDATA 'fake-intune.json'; if (Test-Path $f) { @(Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ }) } else { @() } }
. (Join-Path $PSScriptRoot 'Fakes\FakeSharePoint.ps1')

# --- identity: fixed subject per app
$id = Get-PackTuneCustomMsixIdentity -Name 'Contoso Helper Tool'
Test-Check 'identity: PackTune.<Name> and the subject CN=PackTune <Name>' (($id.PackageName -eq 'PackTune.ContosoHelperTool') -and ($id.Subject -eq 'CN=PackTune Contoso Helper Tool'))
Test-Check 'identity: characters that break a subject are dropped' ((Get-PackTuneCustomMsixIdentity -Name 'A, B+C="D"<E>;F\G#H').Subject -eq 'CN=PackTune A BC=D"E;FGH'.Replace('=D"', 'D').Replace(';', '')) (Get-PackTuneCustomMsixIdentity -Name 'A, B+C="D"<E>;F\G#H').Subject
Test-Check 'identity: a long name is cut (package name 40, subject 64 after CN=)' (((Get-PackTuneCustomMsixIdentity -Name ('X' * 100)).PackageName.Length -le 49) -and ((Get-PackTuneCustomMsixIdentity -Name ('X' * 100)).Subject.Length -le 67))
$threw = $false; try { $null = Get-PackTuneCustomMsixIdentity -Name '+++' } catch { $threw = $true }
Test-Check 'identity: a name without letters is refused' $threw
Test-Check 'identity: the same name always gives the same identity and subject' (((Get-PackTuneCustomMsixIdentity -Name 'Contoso Helper Tool').Subject) -eq $id.Subject)
Test-Check 'next version: last number plus one, four parts' (((Get-PackTuneNextVersion -Version '1.0.0.0') -eq '1.0.0.1') -and ((Get-PackTuneNextVersion -Version '2.5') -eq '2.5.0.1'))

# --- device scripts
$thumb1 = 'A' * 40
$scripts = Get-PackTuneCustomMsixScripts -AppId 'contoso-helper-tool-1a2b3c4d' -PackageName 'PackTune.ContosoHelperTool' -Version '1.0.0.0' -Thumbprint $thumb1
foreach ($pair in @(@('install', $scripts.Install), @('detection', $scripts.Detection))) {
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($pair[1], [ref]$tokens, [ref]$errors)
    Test-Check "$($pair[0]) script: valid PowerShell, ASCII, no placeholder" (($errors.Count -eq 0) -and ($pair[1] -notmatch '[^\x00-\x7F]') -and ($pair[1] -notmatch '__[A-Z0-9]+__')) (@($errors | ForEach-Object Message) -join '; ')
}
$i = $scripts.Install
Test-Check 'install: lock, protected folders, SIDs, 64-bit relaunch, device log' (($i -match 'Global\\PackTune') -and ($i -match 'Enter-DeploymentLock') -and ($i -match 'Exit-DeploymentLock') -and ($i -match 'Protect-Folder \$AppRoot') -and ($i -match 'S-1-5-18') -and ($i -match 'Sysnative') -and ($i -match 'Write-DeviceLog') -and ($i -match 'exit 1618'))
Test-Check 'install: signature thumbprint checked before the certificate is trusted, then TrustedPeople and provisioning' (($i.IndexOf('Get-AuthenticodeSignature') -gt 0) -and ($i.IndexOf('Get-AuthenticodeSignature') -lt $i.IndexOf('Add-TrustedCert $Cer')) -and ($i.IndexOf('Add-TrustedCert $Cer') -lt $i.IndexOf('Add-AppxProvisionedPackage -Online -PackagePath $Msix')) -and ($i -match '"TrustedPeople", "LocalMachine"') -and ($i -match '-SkipLicense'))
Test-Check 'install: a failed update restores the earlier version from the protected copy and keeps its certificate' (($i -match '\$PreviousMsix = Join-Path \$CurrentFolder "package.msix"') -and ($i -match 'Add-AppxProvisionedPackage -Online -PackagePath \$PreviousMsix') -and ($i -match 'earlier version restored') -and ($i.IndexOf('$PreviousMsix') -lt $i.IndexOf('Remove-TrustedCert $Thumbprint')) -and ($i -match 'if \(\$OldThumb -and \$OldThumb -ne \$Thumbprint -and \(Get-CertReferences \$OldThumb\) -eq 0\) \{ Remove-TrustedCert \$OldThumb'))
Test-Check 'install: the earlier certificate is removed only after the new version is in, and only when unreferenced' (($i.IndexOf('Remove-TrustedCert $OldThumb') -gt $i.IndexOf('Write-ProtectedFile $Marker')) -and ($i -match 'Get-CertReferences'))
Test-Check 'install: a copy of the working version is kept in the protected folder for a later restore' (($i -match 'Protect-Folder \$CurrentFolder') -and ($i.IndexOf('Protect-Folder $CurrentFolder') -gt $i.IndexOf('$Installed = $true')))
Test-Check 'uninstall: package removed, only the certificate of this version, kept when another app needs it' (($i -match 'Remove-AppxProvisionedPackage') -and ($i -match 'Remove-AppxPackage -Package \$Package.PackageFullName -AllUsers') -and ($i -match 'is still used by another app, kept'))
Test-Check 'install script: the baked values' (($i -match "\`$Identity = 'PackTune.ContosoHelperTool'") -and ($i -match "\`$Version = '1.0.0.0'") -and ($i -match "\`$Thumbprint = '$thumb1'") -and ($i -match "\`$AppId = 'contoso-helper-tool-1a2b3c4d'"))
Test-Check 'detection: the provisioned package of this identity and version or newer, no time limit' (($scripts.Detection -match 'Get-AppxProvisionedPackage -Online') -and ($scripts.Detection -match "\`$Identity = 'PackTune.ContosoHelperTool'") -and ($scripts.Detection -match '\[version\]\$Found.Version -ge \[version\]\$Version') -and ($scripts.Detection -notmatch 'Get-Date|UtcNow'))

# --- stand-ins for the sandbox module (it is checked on its own in Check-Sandbox.ps1)
$script:Certs = New-Object System.Collections.ArrayList
$script:CertsRemoved = New-Object System.Collections.ArrayList
$script:Captures = New-Object System.Collections.ArrayList
$script:FailCapture = $false
$script:CertCounter = 0
$script:SandboxHere = $true
function Test-PackTuneSandboxAvailable { $script:SandboxHere }
$script:Events = New-Object System.Collections.ArrayList
$script:Signed = New-Object System.Collections.ArrayList
$script:Tamper = $null   # a script block that changes the unsigned capture output (what an installer in the sandbox could do)
function New-PackTuneSigningCertificate { param([string]$Subject, [string]$OutputFolder)
    [void]$script:Events.Add('cert')
    $script:CertCounter++
    $thumb = ('{0:X40}' -f $script:CertCounter)
    $cer = Join-Path $OutputFolder "$thumb.cer"; "public certificate $thumb" | Set-Content $cer
    [void]$script:Certs.Add(@{ Thumbprint = $thumb; Subject = $Subject })
    [pscustomobject]@{ Thumbprint = $thumb; Subject = $Subject; CerPath = $cer; NotAfter = (Get-Date).AddYears(5) }
}
function Remove-PackTuneSigningCertificate { param([string]$Thumbprint) [void]$script:Events.Add('remove'); [void]$script:CertsRemoved.Add($Thumbprint); $true }
function Invoke-PackTuneMsixCapture {
    param([string]$InstallerFolder, [string]$EntryPoint, [string]$Arguments, [string]$PackageName, [string]$DisplayName, [string]$Version, [string]$PublisherDisplayName, [string]$BasePackage, [string]$CertificateThumbprint, [switch]$SkipSigning, [string]$Publisher, [switch]$AllowNetwork)
    [void]$script:Events.Add('capture')
    $baseBytes = if ($BasePackage) { [IO.File]::ReadAllBytes($BasePackage) } else { $null }
    [void]$script:Captures.Add(@{ Folder = $InstallerFolder; Entry = $EntryPoint; Arguments = $Arguments; PackageName = $PackageName; Version = $Version; Thumbprint = $CertificateThumbprint; SkipSigning = [bool]$SkipSigning; Publisher = $Publisher; Network = [bool]$AllowNetwork; Base = $BasePackage; BaseBytes = $baseBytes; Files = @(Get-ChildItem $InstallerFolder -Recurse -File).Name })
    if ($script:FailCapture) { return [pscustomobject]@{ State = 'Failed'; Message = 'the installer exited with code 1603'; PackagePath = $null; JobPath = 'C:\jobs\x'; Identity = $null; Documentation = $null } }
    $out = Join-Path $work "msix\$PackageName`_$Version.msix"; New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
    $text = "MSIX $PackageName $Version publisher $Publisher"
    if ($script:Tamper) { $text = & $script:Tamper $text }
    [IO.File]::WriteAllBytes($out, [Text.Encoding]::ASCII.GetBytes($text))
    $doc = Join-Path $work "doc-$Version"; New-Item -ItemType Directory -Path $doc -Force | Out-Null; '<html>doc</html>' | Set-Content (Join-Path $doc 'index.html')
    # The sandbox reports the identity it was asked for; the build must not trust it (it reads the signed package)
    [pscustomobject]@{ State = 'Succeeded'; Message = 'ok'; PackagePath = $out; JobPath = 'C:\jobs\ok'; Identity = [pscustomobject]@{ Name = $PackageName; Version = $Version; FullName = "$PackageName`_$Version`_x64__abc" }; Documentation = $doc }
}
function Invoke-PackTuneSigning { param([string]$Path, [string]$CertificateThumbprint, [switch]$AllowNoTimestamp)
    $live = @($script:Certs | Where-Object { $_.Thumbprint -eq $CertificateThumbprint }).Count -eq 1 -and $script:CertsRemoved -notcontains $CertificateThumbprint
    [void]$script:Events.Add('sign')
    [void]$script:Signed.Add(@{ Path = $Path; Thumbprint = $CertificateThumbprint; CertLive = $live })
    [IO.File]::WriteAllText($Path, [IO.File]::ReadAllText($Path) + " signed with $CertificateThumbprint")
}
# The package identity and its signature, read from the (fake) package file itself
function Get-PackTuneMsixIdentity { param([string]$Path)
    $m = [regex]::Match([IO.File]::ReadAllText($Path), '^MSIX (\S+) (\S+) publisher (.+?)( signed with ([0-9A-F]{40}))?$')
    [pscustomobject]@{ Name = $m.Groups[1].Value; Version = $m.Groups[2].Value; Publisher = $m.Groups[3].Value; FullName = "$($m.Groups[1].Value)_$($m.Groups[2].Value)_x64__abc" }
}
function Get-AuthenticodeSignature { param([string]$LiteralPath)
    $m = [regex]::Match([IO.File]::ReadAllText($LiteralPath), 'signed with ([0-9A-F]{40})$')
    if ($m.Success) { [pscustomobject]@{ Status = 'UnknownError'; SignerCertificate = [pscustomobject]@{ Thumbprint = $m.Groups[1].Value } } } else { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
}

# --- the capture needs Windows Sandbox: without it nothing is started and no certificate is made
$script:SandboxHere = $false
$threw = $false; try { $null = Invoke-PackTuneCustomMsixBuild -Folder $work -EntryPoint 'x.exe' -Name 'Contoso Helper Tool' -Version '1.0.0.0' } catch { $threw = $_.Exception.Message -like '*Windows Sandbox is not installed*' }
Test-Check 'capture: without Windows Sandbox it is refused before a certificate is made' ($threw -and ($script:Certs.Count -eq 0))
$script:SandboxHere = $true

# --- the store is needed
$settings = Get-PackTuneSettings; $settings.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Save-PackTuneSettings -Settings $settings | Out-Null; $script:Settings = Get-PackTuneSettings
$folder = Join-Path $work 'helper-setup'; New-Item -ItemType Directory -Path (Join-Path $folder 'bin') -Force | Out-Null
'setup v1' | Set-Content (Join-Path $folder 'setup.exe'); 'payload' | Set-Content (Join-Path $folder 'bin\tool.dll'); 'x' | Set-Content (Join-Path $folder 'install.cmd')
$script:SiteReachable = $true
$threw = $false; $msg = ''; try { $null = New-PackTuneCustomOtherApp -Folder $folder -EntryPoint 'setup.exe' -Arguments '/S' -Name 'Contoso Helper Tool' -Publisher 'Contoso' } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'deploy: without a library in the store nothing is captured (the store is required)' ($threw -and ($msg -like '*package store is not ready*') -and ($script:Captures.Count -eq 0) -and ($script:Certs.Count -eq 0)) $msg
$null = Initialize-PackTuneStore

# --- capture failure: certificate removed, nothing stored or uploaded
$script:FailCapture = $true
$threw = $false; $msg = ''; try { $null = New-PackTuneCustomOtherApp -Folder $folder -EntryPoint 'setup.exe' -Arguments '/S' -Name 'Contoso Helper Tool' -Publisher 'Contoso' } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'capture failure: error with the cause, no certificate was ever made, nothing stored or uploaded' ($threw -and ($msg -like '*1603*') -and ($script:Certs.Count -eq 0) -and ($script:Fs.Count -eq 0) -and (@(Get-Store).Count -eq 0)) $msg
$script:FailCapture = $false
# A capture output that does not match what was asked for (the installer changed the job folder): refused after
# signing, the certificate is removed, nothing stored or uploaded
foreach ($t in @(@('version', { param($x) $x -replace ' 1\.0\.0\.0 ', " 1.0.0.0';calc;' " }), @('name', { param($x) $x -replace 'PackTune\.ContosoHelperTool', 'PackTune.Other' }), @('publisher', { param($x) $x -replace 'publisher .*$', 'publisher CN=Evil' }), @('higher version', { param($x) $x -replace ' 1\.0\.0\.0 ', ' 9.9.9.9 ' }))) {
    $script:Tamper = $t[1]; $script:Certs.Clear(); $script:CertsRemoved.Clear()
    $threw = $false; $msg = ''; try { $null = New-PackTuneCustomOtherApp -Folder $folder -EntryPoint 'setup.exe' -Name 'Contoso Helper Tool' -Publisher 'Contoso' -Version '1.0.0.0' } catch { $threw = $true; $msg = $_.Exception.Message }
    Test-Check "tampered capture output ($($t[0])): refused, certificate removed, nothing stored or uploaded" ($threw -and ($msg -like '*not used*') -and ($script:Certs.Count -eq 1) -and ($script:CertsRemoved.Count -eq 1) -and ($script:Fs.Count -eq 0) -and (@(Get-Store).Count -eq 0)) $msg
}
$script:Tamper = $null
$script:Certs.Clear(); $script:CertsRemoved.Clear(); $script:Captures.Clear(); $script:Events.Clear(); $script:Signed.Clear()
$threw = $false; try { $null = Get-PackTuneCustomMsixScripts -AppId 'x-1' -PackageName 'PackTune.X' -Version "1.0.0.0';calc;'" -Thumbprint ('A' * 40) } catch { $threw = $true }
Test-Check 'device scripts: a version that is not four numbers is refused before it is baked in' $threw
$threw = $false; try { $null = Get-PackTuneCustomMsixScripts -AppId "x';calc;'" -PackageName 'PackTune.X' -Version '1.0.0.0' -Thumbprint ('A' * 40) } catch { $threw = $true }
Test-Check 'device scripts: an app id with quotes is refused' $threw
foreach ($bad in @(@('..\x', 'setup.exe'), @($folder, 'missing.exe'), @((Join-Path $work 'nofolder'), 'setup.exe'))) {
    $threw = $false; try { $null = New-PackTuneCustomOtherApp -Folder $bad[0] -EntryPoint $bad[1] -Name 'Contoso Helper Tool' } catch { $threw = $true }
    Test-Check "deploy refuses: folder '$(Split-Path $bad[0] -Leaf)' entry '$($bad[1])'" ($threw -and ($script:Captures.Count -eq 0))
}

# --- deploy: ONE Win32 app, cert inside, files in the store
$id1 = New-PackTuneCustomOtherApp -Folder $folder -EntryPoint 'setup.exe' -Arguments '/S' -Name 'Contoso Helper Tool' -Publisher 'Contoso' -Assignment Available -Version '1.0.0.0'
$apps = @(Get-Store)
$a1 = $apps | Where-Object id -eq $id1
$cap = $script:Captures[0]
$thumb = $script:Certs[0].Thumbprint
$notes1 = ConvertFrom-PackTuneCustomNotes $a1.notes
Test-Check 'deploy: ONE Intune app (no second app, no certificate profile), Win32, Available' (($apps.Count -eq 1) -and ($a1.displayName -eq 'Contoso Helper Tool') -and ($a1.publisher -eq 'Contoso') -and ($a1.assignment -eq 'available') -and (@($a1.dependencies).Count -eq 0))
Test-Check 'deploy: the capture got the folder, entry point, arguments and the identity; the version certificate signed it' (($cap.Folder -eq $folder) -and ($cap.Entry -eq 'setup.exe') -and ($cap.Arguments -eq '/S') -and ($cap.PackageName -eq 'PackTune.ContosoHelperTool') -and $cap.SkipSigning -and ($cap.Publisher -eq 'CN=PackTune Contoso Helper Tool') -and ($script:Signed[0].Thumbprint -eq $thumb) -and $script:Signed[0].CertLive -and ([string]::IsNullOrEmpty($cap.Base))) "folder=$($cap.Folder) entry=$($cap.Entry) args=$($cap.Arguments) pn=$($cap.PackageName) skip=$($cap.SkipSigning) base=$($cap.Base)"
Test-Check 'certificate: made only after the capture finished, removed right after signing' (($script:Events -join ',') -eq 'capture,cert,sign,remove') ($script:Events -join ',')
Test-Check 'certificate: made for the call with the fixed subject, removed right after, also the only one' (($script:Certs.Count -eq 1) -and ($script:Certs[0].Subject -eq 'CN=PackTune Contoso Helper Tool') -and ($script:CertsRemoved -contains $thumb) -and ($script:CertsRemoved.Count -eq 1))
Test-Check 'notes: custom=msix with app, version, identity, certificate thumbprint and the full manifest hash' (($notes1.Kind -eq 'msix') -and ($notes1.Version -eq '1.0.0.0') -and ($notes1.Identity -eq 'PackTune.ContosoHelperTool') -and ($notes1.Thumbprint -eq $thumb) -and ($notes1.Manifest.Length -eq 64) -and ($a1.notes.Length -lt 400)) $a1.notes
$detText = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($a1.detection))
Test-Check 'deploy: the detection checks the provisioned package of the identity and version' (($detText -match 'PackTune.ContosoHelperTool') -and ($detText -match "1.0.0.0"))
$src = Join-Path $work "PackTune\package\custom-$($notes1.AppId)\source"
Test-Check 'package: install.ps1, package.msix and the public certificate of this version, no private key anywhere' ((Test-Path (Join-Path $src 'install.ps1')) -and (Test-Path (Join-Path $src 'package.msix')) -and ((Get-Content (Join-Path $src 'signing.cer') -Raw) -like "*$thumb*") -and (@(Get-ChildItem $src -Recurse | Where-Object { $_.Extension -in '.pfx', '.pvk', '.key' }).Count -eq 0))
Test-Check 'package: the install script carries the thumbprint of this version' ((Get-Content (Join-Path $src 'install.ps1') -Raw) -match "\`$Thumbprint = '$thumb'")
$keys = @($script:Fs.Keys | Where-Object { $_ -like "$($notes1.AppId)/1.0.0.0/*" } | ForEach-Object { $_.Split('/')[-1] } | Sort-Object)
Test-Check 'store: package, original installer files (zip), recipe, certificate, documentation and the manifest' (($keys -join ',') -eq 'documentation.zip,installer.zip,manifest.json,package.intunewin,package.msix,recipe.json,signing.cer') ($keys -join ',')
$recipe = [Text.Encoding]::UTF8.GetString($script:Fs["$($notes1.AppId)/1.0.0.0/recipe.json"]) | ConvertFrom-Json
Test-Check 'store: the recipe holds entry point, arguments, subject and thumbprint' (($recipe.entryPoint -eq 'setup.exe') -and ($recipe.arguments -eq '/S') -and ($recipe.subject -eq 'CN=PackTune Contoso Helper Tool') -and ($recipe.thumbprint -eq $thumb))
$sha = [Security.Cryptography.SHA256]::Create(); $mh = -join ($sha.ComputeHash($script:Fs["$($notes1.AppId)/1.0.0.0/manifest.json"]) | ForEach-Object { $_.ToString('x2') })
Test-Check 'trust anchor: the full manifest hash in the Intune notes is the hash of the stored manifest' ($mh -eq $notes1.Manifest)
$dup = $false; try { $null = New-PackTuneCustomOtherApp -Folder $folder -EntryPoint 'setup.exe' -Name 'Contoso Helper Tool' } catch { $dup = $_.Exception.Message -like '*exists already*' }
Test-Check 'the same application name is refused (use New version)' $dup
$custom = @(Get-PackTuneCustomApps)
Test-Check 'the list shows it with kind msix, identity and thumbprint' (($custom.Count -eq 1) -and ($custom[0].Kind -eq 'msix') -and ($custom[0].Identity -eq 'PackTune.ContosoHelperTool') -and ($custom[0].Thumbprint -eq $thumb))

# --- update: previous MSIX from the store, new version, new certificate, same subject, supersedence
$v1Msix = [Text.Encoding]::ASCII.GetBytes("MSIX PackTune.ContosoHelperTool 1.0.0.0 publisher CN=PackTune Contoso Helper Tool signed with $thumb")
$folder2 = Join-Path $work 'helper-setup-2'; New-Item -ItemType Directory -Path $folder2 -Force | Out-Null; 'setup v2' | Set-Content (Join-Path $folder2 'setup.exe'); 'new file' | Set-Content (Join-Path $folder2 'extra.dll')
$script:Captures.Clear()
$id2 = Update-PackTuneCustomOtherApp -AppId $id1 -InstallerFolder $folder2
$a2 = Get-Store | Where-Object id -eq $id2
$cap2 = $script:Captures[0]
$thumb2 = $script:Certs[1].Thumbprint
$notes2 = ConvertFrom-PackTuneCustomNotes $a2.notes
Test-Check 'update: the previous MSIX from the store is the base of the capture (restored in the sandbox)' (($cap2.Base -like '*previous*package.msix') -and ([Text.Encoding]::ASCII.GetString($cap2.BaseBytes) -eq [Text.Encoding]::ASCII.GetString($v1Msix)))
Test-Check 'update: the new installer folder, the stored entry point and arguments, version one higher' (($cap2.Folder -eq $folder2) -and ($cap2.Entry -eq 'setup.exe') -and ($cap2.Arguments -eq '/S') -and ($cap2.Version -eq '1.0.0.1') -and ($cap2.PackageName -eq 'PackTune.ContosoHelperTool'))
Test-Check 'update: a NEW certificate with the SAME subject, the earlier one is not used, both private keys are gone' (($thumb2 -ne $thumb) -and ($script:Certs[1].Subject -eq $script:Certs[0].Subject) -and ($script:Signed[-1].Thumbprint -eq $thumb2) -and ($script:CertsRemoved -contains $thumb2) -and ($script:CertsRemoved.Count -eq 2))
Test-Check 'update: a new app that supersedes the old one (update) with the assignment, still no dependency' ((@($a2.supersedence).Count -eq 1) -and ($a2.supersedence[0].targetId -eq $id1) -and ($a2.supersedence[0].supersedenceType -eq 'update') -and ($a2.assignments[0].Intent -eq 'available') -and ($a2.assignments[0].AutoUpdateSupersededApps -eq 'enabled') -and (@($a2.dependencies).Count -eq 0))
Test-Check 'update: notes of the new version, name and publisher of the old one' (($notes2.Version -eq '1.0.0.1') -and ($notes2.Thumbprint -eq $thumb2) -and ($a2.displayName -eq 'Contoso Helper Tool') -and ($a2.publisher -eq 'Contoso') -and ($notes2.AppId -eq $notes1.AppId))
$keys2 = @($script:Fs.Keys | Where-Object { $_ -like "$($notes1.AppId)/1.0.0.1/*" } | ForEach-Object { $_.Split('/')[-1] } | Sort-Object)
Test-Check 'update: both versions are in the store, the new installer files are kept with the new version' ((($keys2 -join ',') -eq 'documentation.zip,installer.zip,manifest.json,package.intunewin,package.msix,recipe.json,signing.cer') -and (@(Get-PackTuneStoreVersions -AppId $notes1.AppId | Where-Object Complete).Count -eq 2))
# the stored installer.zip of 1.0.0.1 holds the new files
$tmpZip = Join-Path $work 'v2-installer.zip'; [IO.File]::WriteAllBytes($tmpZip, $script:Fs["$($notes1.AppId)/1.0.0.1/installer.zip"]); Expand-PackTuneZip -Path $tmpZip -Destination (Join-Path $work 'v2-files')
Test-Check 'update: installer.zip of the new version holds the files of the new folder' ((Test-Path (Join-Path $work 'v2-files\extra.dll')) -and ((Get-Content (Join-Path $work 'v2-files\setup.exe') -Raw).Trim() -eq 'setup v2'))
# update without a new folder: the stored installer files are used (edited export -> same entry)
$script:Captures.Clear()
$id3 = Update-PackTuneCustomOtherApp -AppId $id2 -Version '2.0.0.0' -AllowNetwork
Test-Check 'network: off for a capture unless it is allowed for that one (update with -AllowNetwork)' ((-not $cap.Network) -and (-not $cap2.Network) -and $script:Captures[0].Network)
Test-Check 'update without a folder: the stored installer files of the previous version are used, the given version too' (($script:Captures[0].Folder -like '*previous*installer') -and ($script:Captures[0].Version -eq '2.0.0.0') -and ($script:Captures[0].Files -contains 'extra.dll'))
$threw = $false; try { $null = Update-PackTuneCustomOtherApp -AppId $id3 -Version '1.0.0.0' } catch { $threw = $_.Exception.Message -like '*not newer*' }
Test-Check 'update: a version that is not newer is refused' $threw

# --- the store was tampered with: no update, no export
$script:Captures.Clear()
$notes3 = ConvertFrom-PackTuneCustomNotes ((Get-Store | Where-Object id -eq $id3).notes)
$k = "$($notes1.AppId)/2.0.0.0/package.msix"; $orig = $script:Fs[$k]; $evil = $orig.Clone(); $evil[0] = [byte](($evil[0] + 1) % 256); $script:Fs[$k] = $evil
$threw = $false; $msg = ''; try { $null = Update-PackTuneCustomOtherApp -AppId $id3 -Version '3.0.0.0' } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'tampered store: the update is refused before anything is captured' ($threw -and ($msg -like '*package.msix*does not match*') -and ($script:Captures.Count -eq 0)) $msg
$threw = $false; try { $null = Export-PackTuneCustomApp -AppId $notes1.AppId -Version '2.0.0.0' -Destination (Join-Path $work 'exp-bad') } catch { $threw = $true }
Test-Check 'tampered store: the export is refused too' ($threw -and -not (Test-Path (Join-Path $work 'exp-bad\installer')))
$script:Fs[$k] = $orig

# --- no anchor in the notes: update and export refused (fail closed)
$stored3 = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw
$notesNoAnchor = ((Get-Store | Where-Object id -eq $id3).notes) -replace ';manifest=[0-9a-f]+', ''
Invoke-IntuneModule { Set-IntuneWin32App -ID $id3 -Notes $notesNoAnchor } | Out-Null
$threw = $false; $msg = ''; try { $null = Update-PackTuneCustomOtherApp -AppId $id3 -Version '3.0.0.0' } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'no anchor: the update is refused with the re-anchor hint, nothing captured' ($threw -and $msg -like '*records no manifest*' -and $msg -like '*Get-PackTuneCustomAnchorReport*' -and $script:Captures.Count -eq 0) $msg
$threw = $false; try { $null = Export-PackTuneCustomApp -AppId $notes1.AppId -Version '2.0.0.0' -Destination (Join-Path $work 'exp-noanchor') } catch { $threw = $true }
Test-Check 'no anchor: the export is refused' ($threw -and -not (Test-Path (Join-Path $work 'exp-noanchor\package.msix')))
Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') $stored3
$threw = $false; $msg = ''; try { $null = Export-PackTuneCustomApp -AppId $notes1.AppId -Version '9.9.9.9' -Destination (Join-Path $work 'exp-gone') } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'export of a version without its Intune app is refused (nothing vouches for it)' ($threw -and $msg -like '*no Intune app*') $msg

# --- re-anchor: a wanted change in the store is recorded only after the report, with the hash that was shown
$k2 = "$($notes1.AppId)/2.0.0.0"
$origPkg = $script:Fs["$k2/package.msix"]; $origMan = $script:Fs["$k2/manifest.json"]
$newPkg = [Text.Encoding]::ASCII.GetBytes('MSIX PackTune.ContosoHelperTool 2.0.0.0 rebuilt by an administrator')
$script:Fs["$k2/package.msix"] = $newPkg
$man = [Text.Encoding]::UTF8.GetString($origMan) | ConvertFrom-Json
foreach ($f in $man.files) { if ($f.name -eq 'package.msix') { $f.sha256 = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($newPkg) | ForEach-Object { $_.ToString('X2') }); $f.size = $newPkg.Length } }
$script:Fs["$k2/manifest.json"] = [Text.Encoding]::UTF8.GetBytes(($man | ConvertTo-Json -Depth 6))
$threw = $false; try { $null = Update-PackTuneCustomOtherApp -AppId $id3 -Version '3.0.0.0' } catch { $threw = $_.Exception.Message -like '*does not match the one recorded in Intune*' }
Test-Check 're-anchor: a consistently changed store is refused until it is re-anchored' $threw
$report = Get-PackTuneCustomAnchorReport -Id $id3
Test-Check 're-anchor: the report shows the change, the new manifest hash and every file' ($report.Changed -and $report.StoreManifest -ne $report.Recorded -and $report.StoreManifest.Length -eq 64 -and @($report.Files | Where-Object Name -eq 'package.msix').Sha256 -eq ($man.files | Where-Object name -eq 'package.msix').sha256) ($report | ConvertTo-Json -Compress -Depth 3)
$threw = $false; try { Set-PackTuneCustomManifestAnchor -Id $id3 -StoreManifest ('1' * 64) -Confirm:$false | Out-Null } catch { $threw = $_.Exception.Message -like '*changed again*' }
Test-Check 're-anchor: a hash other than the one in the report is refused, nothing written' ($threw -and ((ConvertFrom-PackTuneCustomNotes ((Get-Store | Where-Object id -eq $id3).notes)).Manifest -eq $report.Recorded))
$null = Set-PackTuneCustomManifestAnchor -Id $id3 -StoreManifest $report.StoreManifest -WhatIf
Test-Check 're-anchor: -WhatIf records nothing' ((ConvertFrom-PackTuneCustomNotes ((Get-Store | Where-Object id -eq $id3).notes)).Manifest -eq $report.Recorded)
$null = Set-PackTuneCustomManifestAnchor -Id $id3 -StoreManifest $report.StoreManifest -Confirm:$false
$after = (Get-Store | Where-Object id -eq $id3).notes
$before3 = (@($stored3 | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object id -eq $id3).notes
Test-Check 're-anchor: the shown hash is recorded, the rest of the notes stays' (((ConvertFrom-PackTuneCustomNotes $after).Manifest -eq $report.StoreManifest) -and (($after -replace 'manifest=[0-9a-f]+', '') -eq ($before3 -replace 'manifest=[0-9a-f]+', ''))) $after
$exAnch = Export-PackTuneCustomApp -AppId $notes1.AppId -Version '2.0.0.0' -Destination (Join-Path $work 'exp-anchored')
Test-Check 're-anchor: after it the export works with the changed store' ([IO.File]::ReadAllText((Join-Path $work 'exp-anchored\package.msix')) -like '*rebuilt by an administrator*')
# back to the original content and anchor
$script:Fs["$k2/package.msix"] = $origPkg; $script:Fs["$k2/manifest.json"] = $origMan
Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') $stored3

# --- export to edit and replace
$dest = Join-Path $work 'export-v1'
$ex = Export-PackTuneCustomApp -AppId $notes1.AppId -Version '1.0.0.0' -Destination $dest
Test-Check 'export: package, certificate, recipe, documentation and the original installer files unpacked' ((Test-Path (Join-Path $dest 'package.msix')) -and (Test-Path (Join-Path $dest 'signing.cer')) -and (Test-Path (Join-Path $dest 'recipe.json')) -and (Test-Path (Join-Path $dest 'installer\setup.exe')) -and (Test-Path (Join-Path $dest 'installer\bin\tool.dll')) -and ((Get-Content (Join-Path $dest 'installer\setup.exe') -Raw).Trim() -eq 'setup v1') -and ($ex.InstallerFolder -eq (Join-Path $dest 'installer')))
$exLatest = Export-PackTuneCustomApp -AppId $notes1.AppId -Destination (Join-Path $work 'export-latest')
Test-Check 'export without a version: the newest one' ($exLatest.Version -eq '2.0.0.0')
# edited export used for the next version
$edited = Join-Path $dest 'installer'; 'setup v1 patched' | Set-Content (Join-Path $edited 'setup.exe')
$script:Captures.Clear()
$id4 = Update-PackTuneCustomOtherApp -AppId $id3 -InstallerFolder $edited -Version '2.1.0.0'
Test-Check 'edit and replace: the edited export is the installer folder of the next version' (($script:Captures[0].Folder -eq $edited) -and (@(Get-Store | Where-Object id -eq $id4).Count -eq 1))

# --- delete with confirmation of the store part
Remove-PackTuneCustomApp -Id $id4
$stored = @($script:Fs.Keys | Where-Object { $_ -like "$($notes1.AppId)/*" }).Count
Test-Check 'delete: the Intune app goes, the store stays unless it is asked for' (($stored -gt 0) -and (@(Get-Store | Where-Object id -eq $id4).Count -eq 0))
$threw = $false; try { Remove-PackTuneCustomStore -AppId $notes1.AppId } catch { $threw = $_.Exception.Message -like '*still in the tenant*' }
Test-Check 'delete: the store of an application with Intune apps left is not touched' $threw
foreach ($left in @($id3, $id2, $id1)) { if (@(Get-Store | Where-Object id -eq $left).Count) { try { Remove-PackTuneCustomApp -Id $left } catch { } } }
Remove-PackTuneCustomApp -Id (New-PackTuneCustomOtherApp -Folder $folder -EntryPoint 'setup.exe' -Name 'Another Thing' -Version '1.0.0.0') -DeleteStore
$another = (Get-PackTuneCustomAppId ([pscustomobject]@{ Name = 'PackTune.AnotherThing'; UpgradeCode = '' }))
Test-Check 'delete with the store part: the stored files of the last version go too' (@($script:Fs.Keys | Where-Object { $_ -like "$another/*" }).Count -eq 0)

# --- icon: the largest Square150x150 asset of the captured package
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-LogoPng([int]$Size) { $b = New-Object System.Drawing.Bitmap $Size, $Size; $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::SteelBlue); $g.Dispose(); $m = New-Object IO.MemoryStream; $b.Save($m, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); $m.ToArray() }
function New-LogoMsix([string]$Path, [string]$Visual, [hashtable]$Assets) {
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        $e = $zip.CreateEntry('AppxManifest.xml'); $w = New-Object IO.StreamWriter($e.Open()); $w.Write("<Package xmlns='http://schemas.microsoft.com/appx/manifest/foundation/windows10' xmlns:uap='http://schemas.microsoft.com/appx/manifest/uap/windows10'><Applications><Application Id='A'><uap:VisualElements $Visual/></Application></Applications></Package>"); $w.Dispose()
        foreach ($k in $Assets.Keys) { $e = $zip.CreateEntry($k); $s = $e.Open(); $s.Write($Assets[$k], 0, $Assets[$k].Length); $s.Dispose() }
    }
    finally { $zip.Dispose() }
}
$logoDir = Join-Path $work 'logo'; New-Item -ItemType Directory -Path $logoDir -Force | Out-Null
$msixA = Join-Path $logoDir 'a.msix'
New-LogoMsix $msixA "Square150x150Logo='Assets\Logo.png' Square44x44Logo='Assets\Small.png'" @{ 'Assets/Logo.scale-100.png' = (New-LogoPng 150); 'Assets/Logo.scale-200.png' = (New-LogoPng 300); 'Assets/Logo.scale-400.png' = (New-LogoPng 600); 'Assets/Small.scale-200.png' = (New-LogoPng 88) }
$logo = Get-PackTuneMsixLogoBase64 -MsixPath $msixA
$logoSize = if ($logo) { $img = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [Convert]::FromBase64String($logo)))); $img.Width } else { 0 }
Test-Check 'msix logo: the largest file of the Square150x150 asset (all scales) is used' ($logo -and $logoSize -ge 300) "width $logoSize"
$msixB = Join-Path $logoDir 'b.msix'
New-LogoMsix $msixB "Square44x44Logo='Assets\Small.png'" @{ 'Assets/Small.targetsize-48.png' = (New-LogoPng 48); 'Assets/Small.targetsize-256.png' = (New-LogoPng 256) }
$logoB = Get-PackTuneMsixLogoBase64 -MsixPath $msixB
Test-Check 'msix logo: without a 150 asset the 44x44 one is taken' ([bool]$logoB)
$msixC = Join-Path $logoDir 'c.msix'
New-LogoMsix $msixC "Square150x150Logo='Assets\Missing.png'" @{ 'Assets/Other.png' = (New-LogoPng 50) }
Test-Check 'msix logo: no matching asset gives no icon (the fallback applies)' ($null -eq (Get-PackTuneMsixLogoBase64 -MsixPath $msixC))
# --- readiness texts exist
Test-Check 'the readiness helpers exist for the interface' ((Get-Command Get-PackTuneToolchainState, Get-PackTuneStoreState -ErrorAction SilentlyContinue).Count -eq 2)

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
