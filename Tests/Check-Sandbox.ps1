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
# --- tests never look at the real Windows Sandbox processes
Test-Check 'isolation: a run with its own %LOCALAPPDATA% (every check and the smoke) is isolated from the real sandbox processes' (& $mod { Test-SandboxIsolated })
$env:PACKTUNE_SANDBOX_FAKEIDS = ''
Test-Check 'isolation: no fake ids: no sandbox is running, whatever runs on the computer' (-not (Test-PackTuneSandboxRunning) -and @(& $mod { Get-SandboxProcessIds }).Count -eq 0)
$env:PACKTUNE_SANDBOX_FAKEIDS = '77,88'
Test-Check 'isolation: PACKTUNE_SANDBOX_FAKEIDS is the answer instead (ids 77 and 88, a sandbox is running)' ((Test-PackTuneSandboxRunning) -and (@(& $mod { Get-SandboxProcessIds }) -join ',') -eq '77,88')
$env:PACKTUNE_SANDBOX_FAKEIDS = ''
$env:PACKTUNE_SANDBOX_REAL = '1'
Test-Check 'isolation: only a live spike (PACKTUNE_SANDBOX_REAL=1) looks at the real processes' (-not (& $mod { Test-SandboxIsolated }))
$env:PACKTUNE_SANDBOX_REAL = ''
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
Test-Check 'capture: no network by default, no clipboard, boots Bootstrap.ps1 from the mapped scripts' ($wsb -match '<Networking>Disable</Networking>' -and $wsb -match '<ClipboardRedirection>Disable</ClipboardRedirection>' -and $wsb -notmatch 'ClipboardRedirection>Enable' -and $wsb -match 'Bootstrap\.ps1')

# a script entry point goes through the wrapper (entry.json), without a base there is no restore
$null = Invoke-PackTuneMsixCapture -InstallerFolder $folder -EntryPoint 'sub\install.cmd' -Arguments '/q' -PackageName 'PackTune.Check' -DisplayName 'Check App' -Version '1.3.0.0' -CertificateThumbprint $cert.Thumbprint -AllowNetwork
Test-Check 'capture: network only when it is allowed for that capture' ((Get-Content $script:Wsb -Raw) -match '<Networking>Enable</Networking>')
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
$origLauncher = & $mod { $script:Launcher }
# --- the sandbox PackTune started is closed after the verdict (and only that one); keep-open leaves it
& $mod { $script:FakeProcs = @(); function script:Get-SandboxProcessIds { @($script:FakeProcs) }; function script:Stop-SandboxProcessId([int]$Id) { [void]$script:StopCalls.Add($Id); $script:FakeProcs = @($script:FakeProcs | Where-Object { $_ -ne $Id }) }; $script:StopCalls = New-Object System.Collections.ArrayList }
Set-PackTuneSandboxOption -Name CloseDelaySeconds -Value 0
$script:Logs = New-Object System.Collections.ArrayList
Set-PackTuneSandboxLog -Sink { param($Text, $Level) [void]$script:Logs.Add($Text) }
Set-PackTuneSandboxLauncher -Launcher {
    param($WsbPath)
    $job = Split-Path $WsbPath -Parent
    & $mod { $script:FakeProcs = @($script:FakeProcs) + @(222, 223) }
    @{ State = 'Succeeded'; Step = 'Done'; Message = 'ok'; Result = @{ Verdict = 'Passed'; Notes = 'n' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $job 'status.json')
}
& $mod { $script:FakeProcs = @(111) }   # a sandbox process that was there before (not PackTune's)
Set-PackTuneSandboxOption -Name KeepLabOpen -Value $false   # the default keeps the lab sandbox open for the next test (checked below)
$labClose = Start-PackTuneWin32Lab -DisplayName 'Close App' -Scripts @{ 'Install.ps1' = 'exit 0'; 'Uninstall.ps1' = 'exit 0'; 'Detect.ps1' = 'x' } -AutoRun
$stopped = & $mod { @($script:StopCalls) }; $left = & $mod { @($script:FakeProcs) }
Test-Check 'close: after the verdict the sandbox PackTune started is closed, the result stays visible first' ($labClose.Verdict -eq 'Passed' -and (@($stopped) -join ',') -eq '222,223' -and (@($script:Logs | Where-Object { $_ -like '*sandbox closes in*' }).Count -eq 1) -and (@($script:Logs | Where-Object { $_ -like 'Windows Sandbox closed*' }).Count -eq 1))
Test-Check 'close: a sandbox process that was there before PackTune launched (the user''s) is never touched' ((@($left) -join ',') -eq '111' -and $stopped -notcontains 111)
& $mod { $script:StopCalls.Clear(); $script:FakeProcs = @() }
$script:Logs.Clear()
Set-PackTuneSandboxOption -Name KeepOpen -Value $true
$labKeep = Start-PackTuneWin32Lab -DisplayName 'Keep App' -Scripts @{ 'Install.ps1' = 'exit 0'; 'Uninstall.ps1' = 'exit 0'; 'Detect.ps1' = 'x' } -AutoRun
$stopped = & $mod { @($script:StopCalls) }
Test-Check 'keep open: with the option nothing is closed and the log says the user has to close it' ($labKeep.Verdict -eq 'Passed' -and @($stopped).Count -eq 0 -and (@($script:Logs | Where-Object { $_ -like '*stays open as you asked*' }).Count -eq 1) -and (@(& $mod { $script:FakeProcs }) -join ',') -eq '222,223')
Set-PackTuneSandboxOption -Name KeepOpen -Value $false
Set-PackTuneSandboxOption -Name KeepLabOpen -Value $true
& $mod { $script:FakeProcs = @() }
$env:PACKTUNE_SANDBOX_KEEPOPEN = '1'
$labEnv = Start-PackTuneWin32Lab -DisplayName 'Keep App 2' -Scripts @{ 'Install.ps1' = 'exit 0'; 'Uninstall.ps1' = 'exit 0'; 'Detect.ps1' = 'x' } -AutoRun
Test-Check 'keep open: the test menu item (PACKTUNE_SANDBOX_KEEPOPEN=1) keeps it open too' (@(& $mod { $script:StopCalls }).Count -eq 0)
$env:PACKTUNE_SANDBOX_KEEPOPEN = ''
# waiting for the sandbox to be gone: false while a process of PackTune's sandbox remains, true when it is gone
Set-PackTuneSandboxOption -Name PollSeconds -Value 0
& $mod { $script:SandboxOwned = @{ Before = @(); Started = Get-Date }; $script:FakeProcs = @(222) }
$stillThere = Wait-PackTuneSandboxClosed -Seconds 1
& $mod { $script:FakeProcs = @() }
Test-Check 'wait: reports a sandbox that is still open, and success when it exited' (-not $stillThere -and (Wait-PackTuneSandboxClosed -Seconds 1))
Set-PackTuneSandboxLog -Sink { param($Text, $Level) }
Set-PackTuneSandboxOption -Name CloseDelaySeconds -Value 10
$guiText = Get-Content (Join-Path $repo 'Start-PackTune.ps1') -Raw
Test-Check 'menu: Keep the sandbox open after the test is in the test menu, off by default' ($guiText -match "Keep the sandbox open after the test" -and $guiText -match "IsChecked = \(\`$env:PACKTUNE_SANDBOX_KEEPOPEN -eq '1'\)" -and (Get-Content (Join-Path $repo 'Modules\PackTune.Sandbox.psm1') -Raw) -match 'KeepOpen\s+= \$false' -and (Get-Content (Join-Path $repo 'Modules\PackTune.Sandbox.psm1') -Raw) -match 'CloseDelaySeconds = 10')
Set-PackTuneSandboxLauncher -Launcher $origLauncher
& $mod { $script:SandboxOwned = $null }
# previous version: its scripts and files are in the job, the job says so
$prev = Join-Path $work 'prev-source'; New-Item -ItemType Directory -Path $prev -Force | Out-Null; 'old payload' | Set-Content (Join-Path $prev 'choco-app.ps1')
$script:LabVerdict = 'Succeeded'
$null = Start-PackTuneWin32Lab -DisplayName 'Check App' -Version '2.0' -SourcePath $labSource -Scripts @{ 'Install.ps1' = 'new'; 'Uninstall.ps1' = 'u'; 'Detect.ps1' = 'newdetect' } `
    -PreviousScripts @{ 'Install.ps1' = 'old'; 'Uninstall.ps1' = 'u'; 'Detect.ps1' = 'olddetect' } -PreviousSourcePath $prev -PreviousVersion '1.0' -AutoRun
$prevDir = Join-Path $script:JobSeen.Path 'input\source-previous'
Test-Check 'lab with a previous version: the job says so, the previous scripts and files are their own folder' ($script:JobSeen.Info.HasPrevious -eq $true -and $script:JobSeen.Info.PreviousVersion -eq '1.0' -and (Get-Content (Join-Path $prevDir 'Detect.ps1')) -match 'olddetect' -and (Test-Path (Join-Path $prevDir 'choco-app.ps1')) -and (Get-Content (Join-Path $script:JobSeen.Path 'input\source\Detect.ps1')) -match 'newdetect')
$threw = $false; try { $null = Start-PackTuneWin32Lab -DisplayName 'x' -Scripts @{ 'Install.ps1' = ''; 'Uninstall.ps1' = ''; 'Detect.ps1' = '' } -PreviousScripts @{ 'Install.ps1' = '' } } catch { $threw = $_.Exception.Message -like '*previous version needs*' }
Test-Check 'lab: the previous version needs its three scripts too' $threw
Set-PackTuneSandboxLauncher -Launcher $null
# --- the dependency step: PackTune Runtime goes in first, like in Intune, and stops the run when it fails
$rtSource = Join-Path $work 'rt-source'; New-Item -ItemType Directory -Path $rtSource -Force | Out-Null; 'runtime install' | Set-Content (Join-Path $rtSource 'install.ps1'); 'runtime tray' | Set-Content (Join-Path $rtSource 'tray.ps1')
Set-PackTuneSandboxLauncher -Launcher {
    param($WsbPath)
    $job = Split-Path $WsbPath -Parent
    $script:JobSeen = @{ Path = $job; Info = (Get-Content (Join-Path $job 'job.json') -Raw | ConvertFrom-Json) }
    @{ State = 'Succeeded'; Step = 'Done'; Message = 'ok'; Result = @{ Verdict = 'Passed'; Notes = 'n' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $job 'status.json')
}
$null = Start-PackTuneWin32Lab -DisplayName 'Check App' -Version '1.0' -SourcePath $labSource -Scripts @{ 'Install.ps1' = 'exit 0'; 'Uninstall.ps1' = 'exit 0'; 'Detect.ps1' = 'x' } -RuntimeSourcePath $rtSource -RuntimeDetection 'Write-Output runtime-detect' -AutoRun
$rtDir = Join-Path $script:JobSeen.Path 'input\source-runtime'
Test-Check 'lab with the runtime: the job says so, install.ps1 and the other runtime files, its detection and the step script are their own folder' ($script:JobSeen.Info.HasRuntime -eq $true -and (Get-Content (Join-Path $rtDir 'install.ps1') -Raw) -match 'runtime install' -and (Test-Path (Join-Path $rtDir 'tray.ps1')) -and (Get-Content (Join-Path $rtDir 'Detect.ps1') -Raw) -match 'runtime-detect' -and (Get-Content (Join-Path $rtDir 'Runtime.ps1') -Raw) -match "'install.ps1'" -and (Get-Content (Join-Path $rtDir 'Runtime.ps1') -Raw) -match "'Detect.ps1'")
$stepText = Get-PackTuneLabRuntimeStep
$errs = $null; [void][Management.Automation.Language.Parser]::ParseInput($stepText, [ref]$null, [ref]$errs)
Test-Check 'the runtime step script is valid, ASCII, runs install.ps1 then Detect.ps1 and ends with the detection''s verdict' ($errs.Count -eq 0 -and $stepText -notmatch '[^\x00-\x7F]' -and $stepText.IndexOf("'install.ps1'") -lt $stepText.IndexOf("'Detect.ps1'") -and $stepText -match 'exit \$Code')
$threw = ''; try { $null = Start-PackTuneWin32Lab -DisplayName 'x' -Scripts @{ 'Install.ps1' = ''; 'Uninstall.ps1' = ''; 'Detect.ps1' = '' } -RuntimeSourcePath $work } catch { $threw = $_.Exception.Message }
Test-Check 'the runtime step needs install.ps1 and the detection' ($threw -like '*runtime step needs*') $threw
Set-PackTuneSandboxLauncher -Launcher $null

# --- the sequence of the lab and its verdict (Sandbox\LabShared.ps1, the same functions the lab panel uses)
. (Join-Path $repo 'Sandbox\LabShared.ps1')
$plain = @(New-LabPlan -Version '1.0')[0]
Test-Check 'plan without a previous version: detect, install, detect, uninstall, detect with the expected results' ((($plain | ForEach-Object { "$($_.Kind):$($_.Target)" }) -join ',') -eq 'Detect:new,Install:new,Detect:new,Uninstall:new,Detect:new' -and (($plain | ForEach-Object { $_.Expect }) -join ',') -eq 'not detected,success code,detected,success code,not detected')
$upd = @(New-LabPlan -Version '2.0' -PreviousVersion '1.0' -HasPrevious $true)[0]
Test-Check 'plan with a previous version: previous in and detected, then the update and its detection (new scripts), then uninstall' ((($upd | ForEach-Object { "$($_.Kind):$($_.Target)" }) -join ',') -eq 'Detect:previous,Install:previous,Detect:previous,Install:new,Detect:new,Uninstall:new,Detect:new' -and $upd[3].Title -like 'Update to 2.0*' -and $upd[1].Title -like '*previous version 1.0')
function New-FakeResult([int]$Exit = 0, [string]$StdOut = '') { [pscustomobject]@{ ExitCode = $Exit; Output = $StdOut; StdOut = $StdOut; Seconds = 1.5; User = 'SYSTEM' } }
# a runner that plays the lab: runs the steps in order and stops at the first one that is not as expected
function Invoke-FakeRun($Plan, [scriptblock]$Answer) {
    $ran = New-Object System.Collections.ArrayList
    foreach ($step in $Plan) {
        [void]$ran.Add($step.Index)
        [void](Set-LabStepResult -Step $step -Result (& $Answer $step))
        if ($step.State -eq 'Failed') { break }
    }
    $ran
}
$good = { param($s) switch ($s.Kind) { 'Detect' { if ($s.ExpectDetected) { New-FakeResult 0 'found' } else { New-FakeResult 1 '' } } default { New-FakeResult 0 } } }
$p = @(New-LabPlan -Version '1.0')[0]; $ran = Invoke-FakeRun $p $good; $sum = Get-LabSummary $p
Test-Check 'run: all steps as expected gives Passed with every step run' ($ran.Count -eq 5 -and $sum.Verdict -eq 'Passed' -and $sum.Message -like 'All 5 steps passed*' -and $p[0].Detail -like 'Expected: not detected. Actual: not detected*1.5 s*')
$p = @(New-LabPlan -Version '1.0')[0]
$already = { param($s) if ($s.Index -eq 1) { New-FakeResult 0 'found' } else { & $good $s } }
$ran = Invoke-FakeRun $p $already; $sum = Get-LabSummary $p
Test-Check 'run: detected before the install is a finding (Intune would skip the install) and stops the run' ($ran.Count -eq 1 -and $sum.Verdict -eq 'Failed' -and $sum.Message -like 'Failed at step 1 of 5*skip the install*' -and $p[0].Finding)
$p = @(New-LabPlan -Version '1.0')[0]
$badInstall = { param($s) if ($s.Kind -eq 'Install') { New-FakeResult 1603 } else { & $good $s } }
$ran = Invoke-FakeRun $p $badInstall; $sum = Get-LabSummary $p
Test-Check 'run: a failing install stops after that step, the summary names step and cause, the later steps stay not run' ($ran.Count -eq 2 -and $sum.Message -like 'Failed at step 2 of 5 (Install 1.0): Expected: success code. Actual: exit code 1603*' -and $p[4].State -eq 'NotRun')
$p = @(New-LabPlan -Version '1.0')[0]
$stillThere = { param($s) if ($s.Index -eq 5) { New-FakeResult 0 'found' } else { & $good $s } }
$ran = Invoke-FakeRun $p $stillThere; $sum = Get-LabSummary $p
Test-Check 'run: still detected after the uninstall fails the last step' ($sum.Verdict -eq 'Failed' -and $sum.Message -like 'Failed at step 5 of 5*Expected: not detected. Actual: detected*')
$p = @(New-LabPlan -Version '2.0' -PreviousVersion '1.0' -HasPrevious $true)[0]
$noUpdate = { param($s) if ($s.Index -eq 5) { New-FakeResult 1 '' } else { & $good $s } }
$ran = Invoke-FakeRun $p $noUpdate; $sum = Get-LabSummary $p
Test-Check 'run: the update path is judged too (not detected after the update fails step 5 of 7)' ($ran.Count -eq 5 -and $sum.Message -like 'Failed at step 5 of 7 (Detect after the update)*')
$p = @(New-LabPlan -Version '1.0')[0]; [void](Set-LabStepResult -Step $p[0] -Result (New-FakeResult 1 ''))
Test-Check 'summary: a run that stopped early without a failure is Failed, not Passed' ((Get-LabSummary $p).Verdict -eq 'Failed' -and (Get-LabSummary $p).Message -like 'Stopped before step 2*')
$p = @(New-LabPlan -Version '1.0')[0]; [void](Set-LabStepResult -Step $p[1] -Result ([pscustomobject]@{ ExitCode = $null; Output = ''; StdOut = ''; Seconds = 3; User = ''; Cancelled = $true }))
Test-Check 'a cancelled step is a failed step' ($p[1].State -eq 'Failed' -and $p[1].Detail -like '*cancelled*')
$p = @(New-LabPlan -Version '1.0')[0]; [void](Set-LabStepResult -Step $p[1] -Result (New-FakeResult 3010))
Test-Check 'a reboot code counts as success and is named' ($p[1].State -eq 'Passed' -and $p[1].Detail -like '*soft reboot*')

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

$withRt = @(New-LabPlan -Version '1.0' -HasRuntime $true)[0]
Test-Check 'plan with the runtime: its own visible first step "Dependency: PackTune Runtime", then detect, install, detect, uninstall, detect' ($withRt.Count -eq 6 -and $withRt[0].Title -eq 'Dependency: PackTune Runtime' -and $withRt[0].Kind -eq 'Runtime' -and $withRt[0].Target -eq 'runtime' -and $withRt[1].Title -eq 'Detect before the install' -and (@($withRt | ForEach-Object Index) -join ',') -eq '1,2,3,4,5,6')
$withRtUpd = @(New-LabPlan -Version '2.0' -PreviousVersion '1.0' -HasPrevious $true -HasRuntime $true)[0]
Test-Check 'plan with the runtime and a previous version: the runtime is still the first step only' ($withRtUpd.Count -eq 8 -and $withRtUpd[0].Kind -eq 'Runtime' -and @($withRtUpd | Where-Object Kind -eq 'Runtime').Count -eq 1)
$p = @(New-LabPlan -Version '1.0' -HasRuntime $true)[0]
$rtFail = [pscustomobject]@{ ExitCode = 61002; Output = "winget not found yet, waiting`nwinget.exe not found (App Installer is missing)`nPackTune Runtime install.ps1 exit code 61002"; StdOut = ''; Seconds = 12; User = 'SYSTEM' }
$ran = Invoke-FakeRun $p ({ param($s) $rtFail })
$sum = Get-LabSummary $p
Test-Check 'runtime fails: the run stops at once at step 1 with the exit code and the last output as the cause, no later step ran' ((@($ran) -join ',') -eq '1' -and $p[0].State -eq 'Failed' -and $p[1].State -eq 'NotRun' -and $sum.Verdict -eq 'Failed' -and $sum.Message -like 'Failed at step 1 of 6 (Dependency: PackTune Runtime)*61002*Last output:*exit code 61002*') $sum.Message
$p = @(New-LabPlan -Version '1.0' -HasRuntime $true)[0]
$ran = Invoke-FakeRun $p ({ param($s) switch ($s.Kind) { 'Detect' { if ($s.ExpectDetected) { New-FakeResult 0 'found' } else { New-FakeResult 1 '' } } default { New-FakeResult 0 'PackTune Runtime detection: ready' } } })
Test-Check 'runtime passes: all six steps run and the verdict is Passed' ((@($ran) -join ',') -eq '1,2,3,4,5,6' -and (Get-LabSummary $p).Verdict -eq 'Passed')
$p = @(New-LabPlan -Version '1.0' -HasRuntime $true)[0]; [void](Set-LabStepResult -Step $p[1] -Result (New-FakeResult 0 'found'))
Test-Check 'already detected before the install is still recognised with the runtime step in front' ($p[1].State -eq 'Failed' -and $p[1].Finding -like 'Already detected*')
# --- progress while a step runs: the last lines, the time, and "still working" instead of silence
$hd = Join-Path $work 'handle'; New-Item -ItemType Directory -Path $hd -Force | Out-Null
(1..12 | ForEach-Object { "line $_" }) | Set-Content (Join-Path $hd 'stdout.txt'); 'warn text' | Set-Content (Join-Path $hd 'stderr.txt')
$tail = @(Get-LabLastLines ([pscustomobject]@{ Dir = $hd }) 4)
Test-Check 'progress: the last lines of a running step come from its stdout and stderr files' ($tail.Count -eq 4 -and $tail[-1] -eq 'warn text' -and $tail[0] -eq 'line 10') ($tail -join '|')
Test-Check 'progress: no output files yet is an empty tail, no error' (@(Get-LabLastLines ([pscustomobject]@{ Dir = (Join-Path $work 'nothing') })).Count -eq 0)
$l1 = Get-LabProgressLine -Index 1 -Count 6 -Title 'Dependency: PackTune Runtime' -ElapsedSeconds 125 -LastLine '[10:00:01 +61s] AppInstaller.msixbundle: 12.0 MB of 27.0 MB (44%)'
Test-Check 'progress line: step, what it printed last, minutes and seconds' ($l1 -eq 'Step 1 of 6: Dependency: PackTune Runtime - [10:00:01 +61s] AppInstaller.msixbundle: 12.0 MB of 27.0 MB (44%) (02:05)') $l1
$l2 = Get-LabProgressLine -Index 1 -Count 6 -Title 'Dependency: PackTune Runtime' -ElapsedSeconds 400 -LastLine 'App Installer: provisioning it for all users' -QuietSeconds 200
Test-Check 'progress line: after 3 minutes without new output it says still working, since when, and the last thing it did' ($l2 -like '*still working, no new output for 3 min, last: App Installer: provisioning*(06:40)') $l2
$l3 = Get-LabProgressLine -Index 2 -Count 6 -Title 'Detect' -ElapsedSeconds 3
Test-Check 'progress line: a step that printed nothing yet says it is running, never nothing' ($l3 -eq 'Step 2 of 6: Detect - running (00:03)') $l3
Test-Check 'progress line: a very long last line is cut' ((Get-LabProgressLine -Index 1 -Count 1 -Title 't' -ElapsedSeconds 1 -LastLine ('x' * 400)).Length -lt 160)
$labText = Get-Content (Join-Path $repo 'Sandbox\Lab.ps1') -Raw
Test-Check 'lab panel: the running step updates the panel from its output and reports to PackTune through status.json' ($labText -match 'Update-StepProgress' -and $labText -match "Write-JobStatus 'Running' \`$line" -and $labText -match 'Get-LabLastLines')
$rtText = Get-Content (Join-Path $repo 'PackTune-Runtime.ps1') -Raw
Test-Check 'runtime install: every sub-step prints a timed line (Chocolatey, App Installer download with size, dependencies, signature check, provisioning, registering, tasks)' ($rtText -match 'function Write-Step' -and $rtText -match 'Save-Download' -and ([regex]::Matches($rtText, 'Write-Step "')).Count -ge 15 -and $rtText -match 'checking the Microsoft signature' -and $rtText -match 'registering it for the system context' -and $rtText -match 'N1\} MB')
Test-Check 'runtime install: no progress bar (ProgressPreference), and the random waits between attempts are short only in the lab (lab.flag)' ($rtText -match '\$ProgressPreference = "SilentlyContinue"' -and $rtText -match 'lab\.flag' -and $rtText -match 'if \(\$InLab\) \{ 5 \} else \{ Get-Random')
# --- the reusable test sandbox: heartbeat, own session only, reuse, New sandbox, foreign sandbox
Remove-Item (Join-Path $env:LOCALAPPDATA 'PackTune\Sandbox\lab-session.json') -Force -ErrorAction SilentlyContinue
$script:Launches = 0; $script:Requests = 0
Set-PackTuneSandboxLauncher -Launcher {
    param($Path)
    $dir = Split-Path $Path -Parent
    if ($Path -like '*.wsb') {
        $script:Launches++
        $j = Get-Content (Join-Path $dir 'job.json') -Raw | ConvertFrom-Json
        @{ Token = $j.SessionToken; Started = (Get-Date).ToString('o'); Updated = (Get-Date).ToString('o'); State = 'Idle'; Tests = 1 } | ConvertTo-Json | Set-Content (Join-Path $dir 'heartbeat.json')
    }
    else { $script:Requests++; $script:LastRequestDir = $dir }
    @{ State = 'Succeeded'; Step = 'Done'; Message = 'ok'; Result = @{ Verdict = 'Passed'; Notes = 'n' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'status.json')
}
$scr = @{ 'Install.ps1' = 'exit 0'; 'Uninstall.ps1' = 'exit 0'; 'Detect.ps1' = 'x' }
Test-Check 'reuse: without a lab sandbox there is no session' ($null -eq (Get-PackTuneLabSession))
$t1 = Start-PackTuneWin32Lab -DisplayName 'First App' -Scripts $scr -AutoRun
$s1 = Get-PackTuneLabSession
$j1 = Get-Content (Join-Path $t1.JobPath 'job.json') -Raw | ConvertFrom-Json
Test-Check 'reuse: the first test starts the sandbox, which is then alive (its heartbeat carries the token PackTune gave it) and stays open by default' ($script:Launches -eq 1 -and $s1 -and $s1.Tests -eq 1 -and $j1.Reusable -eq $true -and $j1.Reused -eq $false -and $j1.TestNumber -eq 1 -and $s1.Dir -eq $t1.JobPath)
$t2 = Start-PackTuneWin32Lab -DisplayName 'Second App' -Scripts $scr -AutoRun
$j2 = Get-Content (Join-Path $t2.JobPath 'job.json') -Raw | ConvertFrom-Json
Test-Check 'reuse: the next test (another app) runs in the open sandbox: no new launch, its own folder in the session with a request, the job says reused, test 2' ($script:Launches -eq 1 -and $script:Requests -eq 1 -and $t2.JobPath -eq (Join-Path $s1.Dir 'tests\2') -and (Test-Path (Join-Path $t2.JobPath 'request.json')) -and $j2.Reused -eq $true -and $j2.TestNumber -eq 2 -and $j2.SessionStarted -eq $j1.SessionStarted -and $t2.Verdict -eq 'Passed')
Test-Check 'reuse: the session counts the tests' ((Get-PackTuneLabSession).Tests -eq 2)
$req = Get-Content (Join-Path $t2.JobPath 'request.json') -Raw | ConvertFrom-Json
Test-Check 'reuse: the request names the test' ($req.Title -like 'Second App*')
$hb = Join-Path $s1.Dir 'heartbeat.json'
$beat = Get-Content $hb -Raw | ConvertFrom-Json; $beat.Updated = (Get-Date).AddMinutes(-5).ToString('o'); $beat | ConvertTo-Json | Set-Content $hb
Test-Check 'heartbeat: one older than 30 seconds means the sandbox is gone (never attached to)' ($null -eq (Get-PackTuneLabSession))
$t3 = Start-PackTuneWin32Lab -DisplayName 'Third App' -Scripts $scr -AutoRun
Test-Check 'heartbeat: after a dead sandbox the next test starts a new one (test 1 of the new session)' ($script:Launches -eq 2 -and (Get-PackTuneLabSession).Tests -eq 1)
$sf = Join-Path $env:LOCALAPPDATA 'PackTune\Sandbox\lab-session.json'
$rec = Get-Content $sf -Raw | ConvertFrom-Json; $rec.OwnerPid = 4; $rec | ConvertTo-Json | Set-Content $sf
Test-Check 'own sandbox only: a session of another process is not attached to' ($null -eq (Get-PackTuneLabSession))
$rec.OwnerPid = [Diagnostics.Process]::GetCurrentProcess().Id; $rec | ConvertTo-Json | Set-Content $sf
Test-Check 'own sandbox only: the same file with this process as owner is' ($null -ne (Get-PackTuneLabSession))
$goodToken = $rec.Token
$rec.Token = 'someone-elses-token'; $rec | ConvertTo-Json | Set-Content $sf
Test-Check 'own sandbox only: a heartbeat with another token (a sandbox PackTune did not start) is not attached to' ($null -eq (Get-PackTuneLabSession))
$rec.Token = $goodToken; $rec | ConvertTo-Json | Set-Content $sf
$ls = Get-PackTuneLabSession
Test-Check 'New sandbox: asks the lab sandbox of this PackTune to close and forgets it' ((Request-PackTuneNewLabSandbox) -and (Test-Path (Join-Path $ls.Dir 'newsandbox.request')) -and $null -eq (Get-PackTuneLabSession))
$before = $script:Launches
$t4 = Start-PackTuneWin32Lab -DisplayName 'Fourth App' -Scripts $scr -AutoRun
Test-Check 'New sandbox: the next test starts a clean one' ($script:Launches -eq $before + 1)
$env:PACKTUNE_SANDBOX_NEW = '1'
$before = $script:Launches
$t5 = Start-PackTuneWin32Lab -DisplayName 'Fifth App' -Scripts $scr -AutoRun
Test-Check 'New sandbox: the menu choice "start the next test in a new sandbox" asks for a clean sandbox once' ($script:Launches -eq $before + 1 -and -not $env:PACKTUNE_SANDBOX_NEW)
& $mod { $script:RealRunning = ${function:Test-PackTuneSandboxRunning}; function script:Test-PackTuneSandboxRunning { $true } }
Remove-Item $sf -Force
Test-Check 'foreign sandbox: one is open and PackTune has no live lab sandbox: it is foreign' (Test-PackTuneForeignSandbox)
$before = $script:Launches
$threw = ''; try { $null = Start-PackTuneWin32Lab -DisplayName 'Sixth App' -Scripts $scr -AutoRun } catch { $threw = $_.Exception.Message }
Test-Check 'foreign sandbox: a test request says so clearly, never uses or closes it, and starts nothing' ($threw -like '*PackTune did not start*maybe yours*close it yourself*' -and $script:Launches -eq $before) $threw
& $mod { Set-Item function:script:Test-PackTuneSandboxRunning $script:RealRunning }
Set-PackTuneSandboxLauncher -Launcher $null
Remove-Item $sf -Force -ErrorAction SilentlyContinue
$labText = Get-Content (Join-Path $repo 'Sandbox\Lab.ps1') -Raw; $hostText = Get-Content (Join-Path $repo 'Sandbox\LabHost.ps1') -Raw; $bootText = Get-Content (Join-Path $repo 'Sandbox\Bootstrap.ps1') -Raw
Test-Check 'lab inside: the host stays, writes the heartbeat with the token, takes requests, a New sandbox button and the request file shut the sandbox down' ($bootText -match 'LabHost.ps1' -and $hostText -match 'heartbeat.json' -and $hostText -match 'Token' -and $hostText -match 'request.json' -and $hostText -match 'newsandbox.request' -and $hostText -match 'shutdown.exe' -and $hostText -match 'New sandbox')
Test-Check 'lab inside: the panel says "reused sandbox, started .., test n", cleans up a leftover installation once before the test, and a reusable sandbox is not shut down at the end' ($labText -match 'reused sandbox, started' -and $labText -match 'CleanedOnce' -and $labText -match 'already installed from an earlier test' -and $labText -match 'if \(\$job.Reusable\) \{ \$form.Close\(\); return \}' -and $labText -match 'btnNew')
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
