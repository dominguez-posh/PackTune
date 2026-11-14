<#
.SYNOPSIS
    Checks of the sandbox module (Modules\PackTune.Sandbox.psm1) and its scripts without opening a Windows Sandbox: the
    capture and the test lab against a fake sandbox launcher that plays the part of the sandbox, a real single-use
    certificate (made and removed again in CurrentUser\My), a fake signtool, the toolchain cache with its hashes, the entry
    point rules, and the registry restore of the update capture (a protected key must not stop it). No network.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Sandbox.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSandbox-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
Import-Module (Join-Path $repo 'Modules\PackTune.Sandbox.psm1') -Force
$mod = Get-Module PackTune.Sandbox
Set-PackTuneSandboxLog -Sink { param($Text, $Level) }
Set-PackTuneSandboxOption -Name PollSeconds -Value 0
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- helpers
Test-Check 'version: any text becomes four parts, each at most 65535' ((ConvertTo-PackTuneMsixVersion '2.5') -eq '2.5.0.0' -and (ConvertTo-PackTuneMsixVersion '1.2.3.4.5') -eq '1.2.3.4' -and (ConvertTo-PackTuneMsixVersion '70000.1') -eq '65535.1.0.0')
Test-Check 'next version: last part plus one' ((Get-PackTuneNextMsixVersion '1.0.0.0') -eq '1.0.0.1' -and (Get-PackTuneNextMsixVersion '2.5') -eq '2.5.0.1')
Test-Check 'package name: only letters, digits, dots, dashes; 3 to 50 characters' ((ConvertTo-PackTuneMsixPackageName 'Contoso Tool!') -eq 'ContosoTool' -and (ConvertTo-PackTuneMsixPackageName 'x').Length -ge 3 -and (ConvertTo-PackTuneMsixPackageName ('a' * 80)).Length -eq 50)

# --- entry point of the installation folder
$folder = Join-Path $work 'setup folder'
New-Item -ItemType Directory -Path (Join-Path $folder 'sub') -Force | Out-Null
foreach ($f in 'setup.exe', 'sub\install.cmd', 'sub\run.ps1', 'pack.msi', 'readme.txt') { 'x' | Set-Content (Join-Path $folder $f) }
$entry = { param($e, $a) & $mod { param($Folder, $E, $A) Get-EntryCommand -Folder $Folder -EntryPoint $E -Arguments $A -SandboxFolder 'C:\L\installer' } $folder $e $a }
$exe = & $entry 'setup.exe' '/S'
Test-Check 'entry: an exe is started directly with its arguments' ($exe.IsDirect -and $exe.DirectPath -eq 'C:\L\installer\setup.exe' -and $exe.DirectArguments -eq '/S')
$cmd = & $entry 'sub\install.cmd' '/q'
Test-Check 'entry: a cmd runs through cmd.exe in its own folder' (-not $cmd.IsDirect -and $cmd.FilePath -like '*\cmd.exe' -and $cmd.WorkingDirectory -eq 'C:\L\installer\sub' -and $cmd.ArgumentList -like '*install.cmd*/q*')
$ps1 = & $entry 'sub\run.ps1' ''
Test-Check 'entry: a ps1 runs through PowerShell with -File' ($ps1.FilePath -like '*powershell.exe' -and $ps1.ArgumentList -like '*-File*run.ps1*')
$msi = & $entry 'pack.msi' '/qn'
Test-Check 'entry: an msi is direct, and msiexec for the wrapper' ($msi.IsDirect -and $msi.FilePath -like '*msiexec.exe' -and $msi.ArgumentList -like '/i *pack.msi* /qn')
foreach ($bad in @(@('..\outside.exe', 'outside the folder'), @('C:\Windows\notepad.exe', 'absolute'), @('missing.exe', 'missing'), @('readme.txt', 'type'))) {
    $threw = $false; try { $null = & $entry $bad[0] '' } catch { $threw = $true }
    Test-Check "entry: refused ($($bad[1]))" $threw
}

# --- toolchain cache: state, hashes
Test-Check 'toolchain: nothing downloaded yet' ($null -eq (Get-PackTuneToolchain) -and (Get-PackTuneToolchainState).State -eq 'Missing')
$ws = Get-PackTuneSandboxWorkspace
$sdk = Join-Path $ws.Toolchain 'SdkTools'
New-Item -ItemType Directory -Path $sdk -Force | Out-Null
foreach ($n in 'MSIXPackagingTool.msixbundle', 'MSIXPackagingTool.License.xml', 'Msix-PackagingTool-Driver-Package.cab') { "content of $n" | Set-Content (Join-Path $ws.Toolchain $n) }
# a fake signtool: a console program that writes its arguments to a file and exits with the code from FAKE_SIGNTOOL_EXIT
# (for calls with a timestamp, FAKE_SIGNTOOL_TSEXIT)
$fake = Join-Path $sdk 'signtool.exe'
Add-Type -OutputAssembly $fake -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class FakeSignTool {
    public static int Main(string[] args) {
        File.AppendAllText(Environment.GetEnvironmentVariable("FAKE_SIGNTOOL_LOG"), string.Join(" ", args) + "\r\n");
        bool ts = Array.IndexOf(args, "/tr") >= 0;
        string code = Environment.GetEnvironmentVariable(ts ? "FAKE_SIGNTOOL_TSEXIT" : "FAKE_SIGNTOOL_EXIT");
        if (code == null) code = "0";
        if (code != "0") Console.Error.WriteLine("SignTool Error: fake failure");
        return int.Parse(code);
    }
}
'@
'fake makeappx' | Set-Content (Join-Path $sdk 'makeappx.exe'); 'fake dll' | Set-Content (Join-Path $sdk 'appxsip.dll')
$pinned = & (Get-Module PackTune.Sandbox) { $script:SdkBuildTools }
$hashOf = { param($p) $sha = [Security.Cryptography.SHA256]::Create(); -join ($sha.ComputeHash([IO.File]::ReadAllBytes($p)) | ForEach-Object { $_.ToString('X2') }) }
$files = foreach ($n in 'MSIXPackagingTool.msixbundle', 'MSIXPackagingTool.License.xml', 'Msix-PackagingTool-Driver-Package.cab', 'SdkTools\signtool.exe', 'SdkTools\makeappx.exe', 'SdkTools\appxsip.dll') {
    [ordered]@{ Name = $n; Url = 'https://example.invalid/' + $n; Sha256 = (& $hashOf (Join-Path $ws.Toolchain $n)) }
}
# A toolchain from before the pin: the SDK tools are not in the SHA256 list -> incomplete, downloaded again
[ordered]@{ Version = '1.2024.405.0'; SdkToolsVersion = '10.0.99999'; Downloaded = (Get-Date).ToString('o'); Files = @($files | Select-Object -First 3) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ws.Toolchain 'toolchain.json')
Test-Check 'toolchain: one without the SDK tools in its SHA256 list (older download) counts as incomplete' (-not (Get-PackTuneToolchain -VerifyHash).IsComplete)
[ordered]@{ Version = '1.2024.405.0'; SdkToolsVersion = $pinned.Version; Downloaded = (Get-Date).ToString('o'); Files = @($files) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ws.Toolchain 'toolchain.json')
$tc = Get-PackTuneToolchain -VerifyHash
Test-Check 'toolchain: complete when every file is there and its SHA256 matches' ($tc -and $tc.IsComplete -and (Get-PackTuneToolchainState).State -eq 'Ready' -and $tc.Version -eq '1.2024.405.0')
'tampered dll' | Set-Content (Join-Path $sdk 'appxsip.dll')
Test-Check 'toolchain: a changed DLL of the SDK tools fails the hash check' (-not (Get-PackTuneToolchain -VerifyHash).IsComplete)
'fake dll' | Set-Content (Join-Path $sdk 'appxsip.dll')
$moduleText = Get-Content (Join-Path $repo 'Modules\PackTune.Sandbox.psm1') -Raw
$sdkFn = [regex]::Match($moduleText, '(?s)function Update-SdkTools \{.*?\r?\n\}').Value
Test-Check 'SDK tools: pinned package version and SHA256, zip-slip safe unpacking, Microsoft signature on every exe, dll and mui' ($pinned.Version -match '^\d+\.\d+\.\d+\.\d+$' -and $pinned.Sha256 -match '^[0-9A-F]{64}$' -and $sdkFn -match '\$script:SdkBuildTools\.Version' -and $sdkFn -notmatch 'index\.json' -and $sdkFn -match 'Expand-PackTuneZip' -and $sdkFn -notmatch 'ExtractToFile' -and $sdkFn -match "Extension -in '\.exe', '\.dll', '\.mui' \}\)\) \{ Assert-MicrosoftSignature" -and $sdkFn -match 'does not have the pinned SHA256') $sdkFn
Test-Check 'SDK tools: every file of SdkTools goes into the SHA256 list' ($moduleText -match 'Get-ChildItem -LiteralPath \(Join-Path \$Dir ''SdkTools''\) -Recurse -File')
'tampered' | Set-Content (Join-Path $ws.Toolchain 'MSIXPackagingTool.License.xml')
Test-Check 'toolchain: a changed file fails the hash check' (-not (Get-PackTuneToolchain -VerifyHash).IsComplete -and (Get-PackTuneToolchain).IsComplete)
"content of MSIXPackagingTool.License.xml" | Set-Content (Join-Path $ws.Toolchain 'MSIXPackagingTool.License.xml')
Remove-Item (Join-Path $ws.Toolchain 'Msix-PackagingTool-Driver-Package.cab')
Test-Check 'toolchain: a missing file makes it incomplete and the state says so' (-not (Get-PackTuneToolchain).IsComplete -and (Get-PackTuneToolchainState).State -eq 'Damaged')
"content of Msix-PackagingTool-Driver-Package.cab" | Set-Content (Join-Path $ws.Toolchain 'Msix-PackagingTool-Driver-Package.cab')
Test-Check 'toolchain: restored files are complete again' ((Get-PackTuneToolchain -VerifyHash).IsComplete)

# --- a real single-use certificate: non-exportable key, removed again
$certDir = Join-Path $work 'certs'
$cert = New-PackTuneSigningCertificate -Subject 'CN=PackTune Sandbox Check' -OutputFolder $certDir
$inStore = Test-Path "Cert:\CurrentUser\My\$($cert.Thumbprint)"
$item = Get-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
$exportable = $true; try { $null = $item.Export('Pfx', 'x'); $exportable = $true } catch { $exportable = $false }
$eku = ($item.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] }).EnhancedKeyUsages.Value
$cerFile = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $cert.CerPath
Test-Check 'certificate: made in CurrentUser\My with a key, public .cer written, code signing only' ($inStore -and $item.HasPrivateKey -and (Test-Path $cert.CerPath) -and $cerFile.Thumbprint -eq $cert.Thumbprint -and $eku -contains '1.3.6.1.5.5.7.3.3' -and @($eku).Count -eq 1)
Test-Check 'certificate: the private key cannot be exported' (-not $exportable)
$threw = $false; try { $null = New-PackTuneSigningCertificate -Subject 'CN=bad,subject' } catch { $threw = $true }
Test-Check 'certificate: a subject with a comma is refused' $threw
# --- fake msix with the identity of the certificate
function New-FakeMsix([string]$Path, [string]$Name, [string]$Publisher, [string]$Version, [string]$Display = 'Check App') {
    if (Test-Path $Path) { Remove-Item $Path -Force }
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        $e = $zip.CreateEntry('AppxManifest.xml'); $w = New-Object IO.StreamWriter($e.Open())
        $w.Write("<Package xmlns=`"http://schemas.microsoft.com/appx/manifest/foundation/windows10`"><Identity Name=`"$Name`" Publisher=`"$Publisher`" Version=`"$Version`" ProcessorArchitecture=`"x64`"/><Properties><DisplayName>$Display</DisplayName><PublisherDisplayName>Check Publisher</PublisherDisplayName></Properties><Applications><Application Id=`"App`" Executable=`"VFS\ProgramFilesX64\Check\app.exe`"/></Applications></Package>")
        $w.Dispose()
        $e2 = $zip.CreateEntry('VFS/ProgramFilesX64/Check/app.exe'); $w2 = New-Object IO.StreamWriter($e2.Open()); $w2.Write('binary'); $w2.Dispose()
    }
    finally { $zip.Dispose() }
}
$msix = Join-Path $work 'pkg\Check_1.0.0.0.msix'
New-FakeMsix $msix 'PackTune.Check' $cert.Subject '1.0.0.0'
$info = Get-PackTuneMsixInfo -Path $msix
Test-Check 'package info: identity, display names, applications, signed or not' ($info.Name -eq 'PackTune.Check' -and $info.Version -eq '1.0.0.0' -and $info.DisplayName -eq 'Check App' -and $info.Applications.Count -eq 1 -and -not $info.IsSigned)
$identity = Get-PackTuneMsixIdentity -Path $msix
Test-Check 'identity: family name and full name with the 13 character publisher id' ($identity.PublisherId -match '^[0-9a-z]{13}$' -and $identity.FamilyName -eq "PackTune.Check_$($identity.PublisherId)" -and $identity.FullName -eq "PackTune.Check_1.0.0.0_x64__$($identity.PublisherId)")
Test-Check 'identity: the publisher id of a known subject' ((& $mod { Get-PackTunePublisherHash -Publisher 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }) -eq '8wekyb3d8bbwe')

# --- signing by thumbprint with the fake signtool
$env:FAKE_SIGNTOOL_LOG = Join-Path $work 'signtool.log'
$env:FAKE_SIGNTOOL_EXIT = '0'; $env:FAKE_SIGNTOOL_TSEXIT = '0'
$null = Invoke-PackTuneSigning -Path $msix -CertificateThumbprint $cert.Thumbprint
$line = @(Get-Content $env:FAKE_SIGNTOOL_LOG)[-1]
Test-Check 'signing: SHA256, the certificate by thumbprint from the My store, RFC 3161 timestamp' ($line -match '/fd SHA256' -and $line -match "/sha1 $($cert.Thumbprint)" -and $line -match '/s My' -and $line -match '/tr http' -and $line -match '/td SHA256')
Remove-Item $env:FAKE_SIGNTOOL_LOG
$env:FAKE_SIGNTOOL_TSEXIT = '1'
$threw = $false; $msg = ''; try { $null = Invoke-PackTuneSigning -Path $msix -CertificateThumbprint $cert.Thumbprint } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'signing: without a reachable timestamp server it fails and nothing is signed without one' ($threw -and $msg -like '*timestamp*' -and @(Get-Content $env:FAKE_SIGNTOOL_LOG).Count -eq 1) $msg
Remove-Item $env:FAKE_SIGNTOOL_LOG
$null = Invoke-PackTuneSigning -Path $msix -CertificateThumbprint $cert.Thumbprint -AllowNoTimestamp
Test-Check 'signing: -AllowNoTimestamp falls back to a signature without a timestamp' (@(Get-Content $env:FAKE_SIGNTOOL_LOG).Count -eq 2 -and @(Get-Content $env:FAKE_SIGNTOOL_LOG)[-1] -notmatch '/tr')
$env:FAKE_SIGNTOOL_TSEXIT = '0'
$other = Join-Path $work 'pkg\Other_1.0.0.0.msix'; New-FakeMsix $other 'PackTune.Other' 'CN=Somebody Else' '1.0.0.0'
$threw = $false; $msg = ''; try { $null = Invoke-PackTuneSigning -Path $other -CertificateThumbprint $cert.Thumbprint } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'signing: a publisher that differs from the certificate subject is refused' ($threw -and $msg -like '*Publisher mismatch*') $msg
foreach ($badThumb in 'ABC', ('G' * 40), ('0' * 40)) {
    $threw = $false; try { $null = Invoke-PackTuneSigning -Path $msix -CertificateThumbprint $badThumb } catch { $threw = $true }
    Test-Check "signing: thumbprint '$($badThumb.Substring(0, [Math]::Min(6, $badThumb.Length)))' is refused" $threw
}

# --- capture against a fake sandbox
$script:Wsb = $null; $script:JobSeen = $null; $script:Fail = $false
function New-CaptureLauncher {
    {
        param($WsbPath)
        $script:Wsb = $WsbPath
        $job = Split-Path $WsbPath -Parent
        $info = Get-Content (Join-Path $job 'job.json') -Raw | ConvertFrom-Json
        $script:JobSeen = @{ Path = $job; Info = $info; Template = (Get-Content (Join-Path $job 'template.xml') -Raw); Entry = $(if (Test-Path (Join-Path $job 'input\entry.json')) { Get-Content (Join-Path $job 'input\entry.json') -Raw | ConvertFrom-Json }); Base = @(Get-ChildItem (Join-Path $job 'input\base') -ErrorAction SilentlyContinue | ForEach-Object Name) }
        if ($script:Fail) { @{ State = 'Failed'; Step = 'Conversion'; Message = 'No package was created (exit code 1603).' } | ConvertTo-Json | Set-Content (Join-Path $job 'status.json'); return }
        $xml = [xml]$script:JobSeen.Template
        $pi = $xml.MsixPackagingToolTemplate.PackageInformation
        New-FakeMsix (Join-Path $job "out\$($info.PackageFile)") $pi.PackageName $pi.PublisherName $pi.Version $pi.PackageDisplayName
        'conversion log' | Set-Content (Join-Path $job 'out\conversion.log')
        @{ State = 'Succeeded'; Step = 'Done'; Message = 'Package created (0.1 MB).' } | ConvertTo-Json | Set-Content (Join-Path $job 'status.json')
    }
}
Set-PackTuneSandboxLauncher -Launcher (New-CaptureLauncher)
$env:FAKE_SIGNTOOL_LOG = Join-Path $work 'signtool2.log'
$cap = Invoke-PackTuneMsixCapture -InstallerFolder $folder -EntryPoint 'setup.exe' -Arguments '/S' -PackageName 'PackTune.Check' -DisplayName 'Check App' -Version '1.2.0.0' -PublisherDisplayName 'Check Publisher' -CertificateThumbprint $cert.Thumbprint
$wsb = Get-Content $script:Wsb -Raw
Test-Check 'capture: succeeded, signed with the thumbprint, identity and documentation returned' ($cap.State -eq 'Succeeded' -and (Test-Path $cap.PackagePath) -and (Get-Content $env:FAKE_SIGNTOOL_LOG) -match "/sha1 $($cert.Thumbprint)" -and $cap.Identity.Name -eq 'PackTune.Check' -and $cap.Identity.Version -eq '1.2.0.0' -and (Test-Path (Join-Path $cap.Documentation 'index.html'))) ($cap | Out-String)
Test-Check 'capture: the .wsb maps the job (write), the scripts and the toolchain (read only) and the installer folder (read only)' ($wsb -match [regex]::Escape($script:JobSeen.Path) -and $wsb -match 'C:\\PackTuneSandbox\\Job' -and $wsb -match 'C:\\PackTuneSandbox\\Tools' -and $wsb -match 'C:\\PackTuneSandbox\\Toolchain' -and $wsb -match 'C:\\PackTuneSandbox\\Input' -and $wsb -match 'Bootstrap.ps1' -and ([regex]::Matches($wsb, '<ReadOnly>true</ReadOnly>')).Count -eq 3 -and ([regex]::Matches($wsb, '<ReadOnly>false</ReadOnly>')).Count -eq 1) $wsb
Test-Check 'capture: the template names the installer, its arguments, the publisher of the certificate and the version' ($script:JobSeen.Template -match 'C:\\PackTuneSandboxLocal\\input\\installer\\setup.exe' -and $script:JobSeen.Template -match 'Arguments="/S"' -and $script:JobSeen.Template -match [regex]::Escape("PublisherName=`"$($cert.Subject)`"") -and $script:JobSeen.Template -match 'Version="1.2.0.0"')
Test-Check 'capture: the job says it is a package job with the installation folder' ($script:JobSeen.Info.Mode -eq 'Package' -and $script:JobSeen.Info.InputFolder -eq $true -and $script:JobSeen.Info.AutoClose -eq $true -and $script:JobSeen.Info.PackageFile -eq 'PackTune.Check_1.2.0.0.msix')
Test-Check 'capture: the wsb needs no network setting beyond the default and boots Bootstrap.ps1 from the mapped scripts' ($wsb -match '<Networking>Enable</Networking>')

# a script entry point goes through the wrapper (entry.json), without a base there is no restore
$null = Invoke-PackTuneMsixCapture -InstallerFolder $folder -EntryPoint 'sub\install.cmd' -Arguments '/q' -PackageName 'PackTune.Check' -DisplayName 'Check App' -Version '1.3.0.0' -CertificateThumbprint $cert.Thumbprint
Test-Check 'capture of a script: the wrapper runs it (entry.json), no restore without a base package' ($script:JobSeen.Entry.FilePath -like '*cmd.exe' -and $script:JobSeen.Template -match 'UpdateCapture.ps1' -and $script:JobSeen.Template -notmatch '-Restore')

# an update on top of a base package: identity from the base, version raised, base copied, restore in the wrapper
$basePkg = Join-Path $work 'base\PackTune.Check_1.2.0.0.msix'; New-FakeMsix $basePkg 'PackTune.Check' $cert.Subject '1.2.0.0' 'Base Name'
$upd = Invoke-PackTuneMsixCapture -InstallerFolder $folder -EntryPoint 'setup.exe' -Arguments '/S' -BasePackage $basePkg -CertificateThumbprint $cert.Thumbprint
Test-Check 'update capture: identity from the base package, version plus one, the base is copied into the job' ($upd.State -eq 'Succeeded' -and $upd.Identity.Name -eq 'PackTune.Check' -and $upd.Identity.Version -eq '1.2.0.1' -and $script:JobSeen.Base -contains 'PackTune.Check_1.2.0.0.msix') ($upd | Out-String)
Test-Check 'update capture: the wrapper restores the base first, into the default install root' ($script:JobSeen.Template -match '-Restore' -and $script:JobSeen.Template -match 'C:\\Program Files\\PackTune.Check' -and $script:JobSeen.Entry.FilePath -like '*setup.exe')

# a failed capture: state Failed with the cause, nothing signed
Remove-Item $env:FAKE_SIGNTOOL_LOG
$script:Fail = $true
$bad = Invoke-PackTuneMsixCapture -InstallerFolder $folder -EntryPoint 'setup.exe' -PackageName 'PackTune.Check' -Version '1.4.0.0' -CertificateThumbprint $cert.Thumbprint
Test-Check 'capture failure: State Failed with the message and the job folder, nothing signed' ($bad.State -eq 'Failed' -and $bad.Message -like '*1603*' -and $bad.JobPath -and -not (Test-Path $env:FAKE_SIGNTOOL_LOG))
$script:Fail = $false
$threw = $false; try { $null = Invoke-PackTuneMsixCapture -InstallerFolder $folder -EntryPoint 'setup.exe' -PackageName 'PackTune.Check' }
catch { $threw = $_.Exception.Message -like '*CertificateThumbprint*' }
Test-Check 'capture: without a certificate it is refused' $threw
# the certificate goes away again
Test-Check 'certificate: removed with its key, verified; removing again says it was not there' ((Remove-PackTuneSigningCertificate -Thumbprint $cert.Thumbprint) -eq $true -and -not (Test-Path "Cert:\CurrentUser\My\$($cert.Thumbprint)") -and (Remove-PackTuneSigningCertificate -Thumbprint $cert.Thumbprint) -eq $false)
$threw = $false; try { $null = Remove-PackTuneSigningCertificate -Thumbprint 'xyz' } catch { $threw = $true }
Test-Check 'certificate: a bad thumbprint is refused (no wildcards into the path)' $threw

# --- the test lab against a fake sandbox
$labSource = Join-Path $work 'lab-source'; New-Item -ItemType Directory -Path $labSource -Force | Out-Null; 'payload' | Set-Content (Join-Path $labSource 'choco-app.ps1')
$script:LabVerdict = 'Succeeded'
Set-PackTuneSandboxLauncher -Launcher {
    param($WsbPath)
    $script:Wsb = $WsbPath
    $job = Split-Path $WsbPath -Parent
    $script:JobSeen = @{ Path = $job; Info = (Get-Content (Join-Path $job 'job.json') -Raw | ConvertFrom-Json); Source = @(Get-ChildItem (Join-Path $job 'input\source') | ForEach-Object Name) }
    @{ State = $script:LabVerdict; Step = 'Done'; Message = 'reported by the lab'; Result = @{ Verdict = $(if ($script:LabVerdict -eq 'Succeeded') { 'Passed' } else { 'Failed' }); Notes = 'n' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $job 'status.json')
}
$lab = Start-PackTuneWin32Lab -DisplayName 'Check App' -Version '1.0' -SourcePath $labSource -Scripts @{ 'Install.ps1' = 'exit 0'; 'Uninstall.ps1' = 'exit 0'; 'Detect.ps1' = 'Write-Output ok' } -AutoRun
$wsb = Get-Content $script:Wsb -Raw
Test-Check 'lab: the verdict follows the lab report' ($lab.Verdict -eq 'Passed' -and $lab.Message -eq 'reported by the lab' -and $lab.JobPath)
Test-Check 'lab: scripts and package files end up in one source folder, the job says Lab and AutoRun' ($script:JobSeen.Source -contains 'Install.ps1' -and $script:JobSeen.Source -contains 'Detect.ps1' -and $script:JobSeen.Source -contains 'choco-app.ps1' -and $script:JobSeen.Info.Mode -eq 'Lab' -and $script:JobSeen.Info.AutoRun -eq $true -and $script:JobSeen.Info.AutoClose -eq $false)
Test-Check 'lab: no toolchain is mapped (the lab does not need it)' ($wsb -notmatch 'Toolchain' -and $wsb -match 'Tools')
$script:LabVerdict = 'Failed'
$lab = Start-PackTuneWin32Lab -DisplayName 'Check App' -Scripts @{ 'Install.ps1' = 'exit 1'; 'Uninstall.ps1' = ''; 'Detect.ps1' = '' }
Test-Check 'lab: a failed report is a failed verdict; without -AutoRun the lab waits for the person' ($lab.Verdict -eq 'Failed' -and $script:JobSeen.Info.AutoRun -eq $false)
$threw = $false; try { $null = Start-PackTuneWin32Lab -DisplayName 'x' -Scripts @{ 'Install.ps1' = '' } } catch { $threw = $_.Exception.Message -like '*Uninstall.ps1*' -or $_.Exception.Message -like '*Detect.ps1*' }
Test-Check 'lab: the three scripts are required' $threw
Set-PackTuneSandboxLauncher -Launcher $null

# --- the scripts that run in the sandbox
foreach ($file in Get-ChildItem (Join-Path $repo 'Sandbox') -Filter *.ps1) {
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $text = [IO.File]::ReadAllText($file.FullName)
    Test-Check "sandbox script $($file.Name): valid PowerShell, plain ASCII (Windows PowerShell 5.1 reads it in the local code page)" (($errors.Count -eq 0) -and ($text -notmatch '[^\x00-\x7F]')) (@($errors | ForEach-Object Message) -join '; ')
}
# the registry restore: a key that cannot be written must not stop it (reg.exe writes to stderr, the script runs with Stop)
$tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Sandbox\UpdateCapture.ps1'), [ref]$null, [ref]$null)
$fn = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Invoke-Reg', 'Get-RegistrySubkey', 'Get-MsixVfsMap', 'Get-MsixRestorePlan' }, $true))
Test-Check 'restore: the functions are in the update capture script' ($fn.Count -eq 4)
$ErrorActionPreference = 'Stop'
foreach ($f in $fn) { . ([scriptblock]::Create($f.Extent.Text)) }
$r = $null; $threw = $false
try { $r = Invoke-Reg copy 'HKCU\Software\PackTuneNoSuchKey1' 'HKCU\Software\PackTuneNoSuchKey2' /s /f } catch { $threw = $true }
Test-Check 'restore: reg.exe failing with an error text gives an exit code, not an exception (the earlier "Access denied" abort)' (-not $threw -and $r.Exit -ne 0 -and $r.Text) "threw=$threw $($r | Out-String)"
$threw = $false; $subs = $null
try { $subs = @(Get-RegistrySubkey 'HKCU\Software\PackTuneNoSuchKey1') } catch { $threw = $true }
Test-Check 'restore: the subkeys of a key that does not exist are an empty list' (-not $threw -and $subs.Count -eq 0)
$plan = @(Get-MsixRestorePlan -Path $basePkg -InstallRoot 'C:\Program Files\PackTune.Check')
Test-Check 'restore: files of VFS go to their real location, metadata is skipped' (($plan | Where-Object Name -eq 'VFS/ProgramFilesX64/Check/app.exe').Target -eq (Join-Path $env:ProgramFiles 'Check\app.exe') -and ($plan | Where-Object Name -eq 'AppxManifest.xml').Kind -eq 'Skip')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
