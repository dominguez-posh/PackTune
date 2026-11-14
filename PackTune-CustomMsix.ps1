<#
    Custom applications, "Other": anything that is not an MSI (EXE setups, scripts, several files). The user puts all
    installation files into one folder; PackTune captures an MSIX from it in Windows Sandbox (Modules\PackTune.Sandbox.psm1,
    built into PackTune), signs it on this machine with a certificate made for this version alone (non-exportable key, deleted
    right after signing) and delivers it as ONE Win32 app: the package holds the MSIX and the public certificate of the
    version; install.ps1 (SYSTEM) puts the certificate into LocalMachine\TrustedPeople and provisions the MSIX for all users.
    An update restores the previous MSIX in a fresh sandbox, runs the new installer and builds the next MSIX; a new app with
    supersedence carries it to the devices (docs\plans\custom-applications.md, sections 4, 5 and 10).
    Loaded by PackTune-Main.ps1.
#>

#region identity and device scripts

function Get-PackTuneCustomMsixIdentity {
    <#
        Identity of the MSIX of an app: package name PackTune.<Name> and the fixed publisher subject CN=PackTune <Name>. The
        subject stays the same for every version (updates need the same publisher), only the certificate is new each time.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $Clean = ($Name -replace '[,+="<>;\\#]', '' -replace '\s+', ' ').Trim()
    if (-not $Clean) { throw "The name '$Name' cannot be used for the package identity" }
    $Words = ($Clean -replace '[^A-Za-z0-9 ]', ' ' -split '\s+' | Where-Object { $_ })
    $Pascal = -join ($Words | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) })
    if (-not $Pascal) { throw "The name '$Name' has no letters or digits for the package identity" }
    if ($Pascal.Length -gt 40) { $Pascal = $Pascal.Substring(0, 40) }
    $Subject = "CN=PackTune $Clean"
    if ($Subject.Length -gt 67) { $Subject = $Subject.Substring(0, 67).TrimEnd() }
    [pscustomobject]@{ PackageName = "PackTune.$Pascal"; Subject = $Subject }
}

function Get-PackTuneCustomMsixScripts {
    <#
        Install (-Uninstall removes) and detection script of an MSIX delivered as a Win32 app. Plain ASCII, Windows PowerShell
        5.1, SYSTEM: 64-bit relaunch, the device lock, protected folders under %ProgramFiles%\PackTune, the device log.
        Install: the package must carry the signature of the certificate of this version, the certificate goes into
        LocalMachine\TrustedPeople, then the MSIX is provisioned for all users. A failed update puts the earlier version back
        (a failed provisioning removes it) and keeps its certificate. Uninstall removes the package and only the certificate of
        this version, and only when no other custom app of the tool needs it.
    #>
    param([Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)][string]$PackageName, [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$Thumbprint)
    $Install = @'
# Installs or removes a custom MSIX delivered as a Win32 app (runs as SYSTEM through Intune): the public certificate of this
# version goes into LocalMachine\TrustedPeople, the package is provisioned for all users.
param([switch]$Uninstall)

# The Intune Management Extension starts 32-bit PowerShell; provisioning needs the 64-bit DISM cmdlets
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$AppId = '__APPID__'
$Identity = '__IDENTITY__'
$Version = '__VERSION__'
$Thumbprint = '__THUMBPRINT__'
$LogId = "custom-$AppId"
$LogTag = if ($Uninstall) { "uninstall" } else { "install" }

__COMMON__

$CustomRoot = Join-Path $ToolRoot "Custom"
$AppRoot = Join-Path $CustomRoot $AppId
$Marker = Join-Path $AppRoot "version.txt"
$CurrentFolder = Join-Path $AppRoot "current"
try {
    Protect-Folder $ToolRoot
    Protect-Folder $CustomRoot
    Protect-Folder $AppRoot
}
catch { Write-Output "The folder $AppRoot could not be protected: $($_.Exception.Message)"; Write-DeviceLog "folder not protected: $($_.Exception.Message)"; exit 1 }

function Test-TrustedCert([string]$Thumb) {
    $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    $Store.Open("ReadOnly")
    try { return @($Store.Certificates | Where-Object { $_.Thumbprint -eq $Thumb }).Count -gt 0 } finally { $Store.Close() }
}
function Add-TrustedCert($Certificate) {
    $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    $Store.Open("ReadWrite")
    try { $Store.Add($Certificate) } finally { $Store.Close() }
}
function Remove-TrustedCert([string]$Thumb) {
    $Store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    $Store.Open("ReadWrite")
    try { foreach ($Found in @($Store.Certificates | Where-Object { $_.Thumbprint -eq $Thumb })) { $Store.Remove($Found) } } finally { $Store.Close() }
}
function Get-CertReferences([string]$Thumb) {
    # Other custom apps of this tool whose marker names the certificate (it stays while one still needs it)
    $Count = 0
    foreach ($Folder in @(Get-ChildItem -LiteralPath $CustomRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $AppId })) {
        $Other = Join-Path $Folder.FullName "version.txt"
        if (Test-Path -LiteralPath $Other) { if ((Get-Content -LiteralPath $Other -Raw).Trim().Split("|")[2] -eq $Thumb) { $Count++ } }
    }
    return $Count
}
function Get-Provisioned { @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $Identity }) }

if (-not (Enter-DeploymentLock)) { Write-Output "Another installation is still running"; Write-DeviceLog "another installation is still running, Intune tries again"; exit 1618 }
try {
    $OldThumb = $null
    if (Test-Path -LiteralPath $Marker) { $OldThumb = (Get-Content -LiteralPath $Marker -Raw).Trim().Split("|")[2] }

    if ($Uninstall) {
        foreach ($Package in @(Get-Provisioned)) { Remove-AppxProvisionedPackage -Online -PackageName $Package.PackageName -ErrorAction Stop | Out-Null }
        foreach ($Package in @(Get-AppxPackage -AllUsers -Name $Identity -ErrorAction SilentlyContinue)) { Remove-AppxPackage -Package $Package.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        if (@(Get-Provisioned).Count -gt 0) { Write-DeviceLog "uninstall: the package is still provisioned"; exit 1 }
        # Only the certificate of this version, and only when no other custom app of the tool still needs it
        $Own = if ($OldThumb) { $OldThumb } else { $Thumbprint }
        if ((Get-CertReferences $Own) -eq 0) { Remove-TrustedCert $Own; Write-DeviceLog "certificate $Own removed" } else { Write-DeviceLog "certificate $Own is still used by another app, kept" }
        try { Remove-ItemSafely $CurrentFolder } catch { }
        Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
        Write-DeviceLog "uninstalled $Identity"
        exit 0
    }

    # Copy next to the protected folder first: the Intune cache folder is not ours
    $Staging = Join-Path $AppRoot "staging"
    Protect-Folder $Staging
    foreach ($Name in "package.msix", "signing.cer") { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination $Staging -Force }
    $Msix = Join-Path $Staging "package.msix"
    $Cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (Join-Path $Staging "signing.cer")
    if ($Cer.Thumbprint -ne $Thumbprint) { Write-Output "signing.cer is not the certificate of this version"; Write-DeviceLog "certificate file does not match the version, nothing installed"; exit 1 }
    # Only a certificate that is safe to trust goes into TrustedPeople: self-signed leaf, CA=false, Code Signing only, subject = publisher of the package
    $Why = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Zip = [System.IO.Compression.ZipFile]::OpenRead($Msix)
        try { $Reader = New-Object System.IO.StreamReader($Zip.GetEntry("AppxManifest.xml").Open()); try { [xml]$Manifest = $Reader.ReadToEnd() } finally { $Reader.Dispose() } } finally { $Zip.Dispose() }
        $Publisher = [string]$Manifest.Package.Identity.Publisher
        $Basic = @($Cer.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] })[0]
        $EkuExt = @($Cer.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })[0]
        $Oids = @(if ($EkuExt) { $EkuExt.EnhancedKeyUsages | ForEach-Object { $_.Value } })
        $KeyUse = @($Cer.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension] })[0]
        if ($Cer.Subject -cne $Publisher) { $Why = "subject is not the publisher of the package" }
        elseif ($Cer.Subject -ne $Cer.Issuer) { $Why = "not self-signed" }
        elseif (-not $Basic -or $Basic.CertificateAuthority) { $Why = "BasicConstraints CA is not false" }
        elseif ($Oids.Count -ne 1 -or $Oids[0] -ne "1.3.6.1.5.5.7.3.3") { $Why = "not for Code Signing only" }
        elseif ($KeyUse -and ($KeyUse.KeyUsages -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign)) { $Why = "may sign certificates" }
    }
    catch { $Why = "could not be checked: $($_.Exception.Message)" }
    if ($Why) { Write-Output "The certificate is not safe to trust ($Why)"; Write-DeviceLog "certificate refused: $Why, nothing installed"; exit 1 }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Msix
    if (-not $Signature.SignerCertificate -or $Signature.SignerCertificate.Thumbprint -ne $Thumbprint -or [string]$Signature.Status -in "HashMismatch", "NotSigned") {
        Write-Output "The package is not signed by the certificate of this version (status $($Signature.Status))"
        Write-DeviceLog "package signature does not match the version certificate, nothing installed"
        exit 1
    }

    $Had = Test-TrustedCert $Thumbprint
    if (-not $Had) { Add-TrustedCert $Cer; Write-DeviceLog "certificate $Thumbprint added to TrustedPeople" }
    $Installed = $false
    try { Add-AppxProvisionedPackage -Online -PackagePath $Msix -SkipLicense -ErrorAction Stop | Out-Null; $Installed = $true }
    catch {
        # A lower version may have to go first
        Write-DeviceLog "provisioning failed ($($_.Exception.Message)), removing the provisioned version and trying again"
        try {
            foreach ($Package in @(Get-Provisioned)) { Remove-AppxProvisionedPackage -Online -PackageName $Package.PackageName -ErrorAction Stop | Out-Null }
            Add-AppxProvisionedPackage -Online -PackagePath $Msix -SkipLicense -ErrorAction Stop | Out-Null
            $Installed = $true
        }
        catch { Write-Output "Provisioning failed: $($_.Exception.Message)"; Write-DeviceLog "provisioning failed: $($_.Exception.Message)" }
    }
    if (-not $Installed) {
        # A failed update removes the provisioning of the earlier version: put it back (its certificate was never removed)
        $Restored = $false
        $PreviousMsix = Join-Path $CurrentFolder "package.msix"
        if (Test-Path -LiteralPath $PreviousMsix) {
            try { Add-AppxProvisionedPackage -Online -PackagePath $PreviousMsix -SkipLicense -ErrorAction Stop | Out-Null; $Restored = $true }
            catch { Write-DeviceLog "the earlier version could not be restored: $($_.Exception.Message)" }
        }
        if (-not $Had -and (Get-CertReferences $Thumbprint) -eq 0 -and $OldThumb -ne $Thumbprint) { Remove-TrustedCert $Thumbprint }
        Write-DeviceLog "install of $Version failed, earlier version restored: $Restored"
        exit 1
    }
    # Kept for a restore after a later failed update
    try {
        Protect-Folder $CurrentFolder
        foreach ($Name in "package.msix", "signing.cer") { Copy-Item -LiteralPath (Join-Path $Staging $Name) -Destination $CurrentFolder -Force }
    }
    catch { Write-DeviceLog "the package could not be kept for a restore: $($_.Exception.Message)" }
    Write-ProtectedFile $Marker "$Identity|$Version|$Thumbprint"
    # An update leaves the earlier version's certificate behind: remove it when nothing needs it any more
    if ($OldThumb -and $OldThumb -ne $Thumbprint -and (Get-CertReferences $OldThumb) -eq 0) { Remove-TrustedCert $OldThumb; Write-DeviceLog "certificate $OldThumb of the earlier version removed" }
    try { Remove-ItemSafely $Staging } catch { }
    Write-DeviceLog "installed $Identity $Version"
    exit 0
}
finally { Exit-DeploymentLock }
'@
    $Detect = @'
# Detection: the package is provisioned with this version or newer (no time dependency)
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath"
    exit $LASTEXITCODE
}
$Identity = '__IDENTITY__'
$Version = '__VERSION__'
$Found = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $Identity }) | Select-Object -First 1
if (-not $Found) { exit 1 }
try { if ([version]$Found.Version -ge [version]$Version) { Write-Output "$Identity $($Found.Version) is provisioned"; exit 0 } } catch { }
exit 1
'@
    # Every baked value is checked against its strict form and quoted for a single-quoted string (they run as SYSTEM)
    if ($AppId -notmatch '^[a-z0-9][a-z0-9-]{0,79}$') { throw "The app id '$AppId' is not valid" }
    if ($PackageName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$') { throw "The package name '$PackageName' is not valid" }
    if ($Version -notmatch '^\d+(\.\d+){3}$') { throw "The package version '$Version' is not a version of four numbers" }
    if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw "The certificate thumbprint '$Thumbprint' is not valid" }
    $Quote = { param($Text) ([string]$Text -replace '[^\x20-\x7E]', '').Replace("'", "''") }
    $Common = Get-DeviceScriptCommon
    $Fill = { param($Text) $Text.Replace('__COMMON__', $Common).Replace('__APPID__', (& $Quote $AppId)).Replace('__IDENTITY__', (& $Quote $PackageName)).Replace('__VERSION__', (& $Quote $Version)).Replace('__THUMBPRINT__', (& $Quote $Thumbprint.ToUpper())) }
    [pscustomobject]@{ Install = (& $Fill $Install); Detection = (& $Fill $Detect) }
}#Install and detection script of an MSIX delivered as a Win32 app

#endregion

#region build and deploy

function Get-PackTuneNextVersion {
    # A version one higher than $Version (the last number), for the next MSIX of an app
    param([Parameter(Mandatory = $true)][string]$Version)
    $Parts = @($Version.Split(".") | ForEach-Object { [int]$_ })
    while ($Parts.Count -lt 4) { $Parts += 0 }
    $Parts[$Parts.Count - 1]++
    return ($Parts -join ".")
}

function Get-PackTuneLongPath {
    # A path with the long names (a folder like C:\Users\LUCAS~1.DOM\... as 8.3 short names breaks the entry point check of
    # the capture, which compares the path as given with the one .NET expands)
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not ('PackTune.LongPath' -as [type])) {
        Add-Type -Namespace PackTune -Name LongPath -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] public static extern int GetLongPathName(string shortPath, System.Text.StringBuilder longPath, int bufferSize);'
    }
    $Full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $Buffer = New-Object System.Text.StringBuilder 1024
    $Length = [PackTune.LongPath]::GetLongPathName($Full, $Buffer, $Buffer.Capacity)
    if ($Length -gt 0 -and $Length -lt $Buffer.Capacity) { return $Buffer.ToString().TrimEnd('\') }
    return $Full.TrimEnd('\')
}

function Invoke-PackTuneCustomMsixBuild {
    <#
        Captures the folder to an MSIX in a fresh sandbox (unsigned, publisher = the fixed subject of the app), then makes a
        certificate for this version only (non-exportable key, deleted in finally, never stored) and signs the package with it.
        The identity is read again from the SIGNED package on this computer, never from what the sandbox reported (the
        installer runs there and can change the job folder): name, publisher and version must be the expected ones and the
        signer must be this certificate. -BasePackage: update capture (the previous MSIX is restored first). Returns the signed
        package, the public certificate, the thumbprint, the identity and the documentation.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Folder, [Parameter(Mandatory = $true)][string]$EntryPoint, [string]$Arguments = "",
        [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Version, [string]$PublisherDisplayName, [string]$BasePackage, [string]$CertFolder,
        # Network in the capture sandbox: off unless the person allows it for this capture (some setups download content)
        [switch]$AllowNetwork
    )
    if (-not (Test-PackTuneSandboxAvailable)) { throw "Windows Sandbox is not installed on this computer: custom applications of type Other are captured there." }
    $Folder = Get-PackTuneLongPath -Path $Folder
    if ($BasePackage) { $BasePackage = Get-PackTuneLongPath -Path $BasePackage }
    $Identity = Get-PackTuneCustomMsixIdentity -Name $Name
    $ExpectedVersion = ConvertTo-PackTuneMsixVersion $Version
    $Params = @{
        InstallerFolder = $Folder; EntryPoint = $EntryPoint; Arguments = $Arguments; PackageName = $Identity.PackageName; DisplayName = $Name
        Version = $ExpectedVersion; PublisherDisplayName = $(if ($PublisherDisplayName) { $PublisherDisplayName } else { $Name }); SkipSigning = $true; Publisher = $Identity.Subject
    }
    if ($BasePackage) { $Params.BasePackage = $BasePackage }
    if ($AllowNetwork) { $Params.AllowNetwork = $true }
    $Result = Invoke-PackTuneMsixCapture @Params
    if ($Result.State -ne "Succeeded" -or -not $Result.PackagePath) { throw "The capture failed: $($Result.Message) (logs: $($Result.JobPath))" }

    # The certificate exists only from here to the end of the signing
    if (-not $CertFolder) { $CertFolder = Join-Path $script:WorkRoot ("certs\" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
    New-Item -ItemType Directory -Path $CertFolder -Force | Out-Null
    $Cert = New-PackTuneSigningCertificate -Subject $Identity.Subject -OutputFolder $CertFolder
    try { $null = Invoke-PackTuneSigning -Path $Result.PackagePath -CertificateThumbprint $Cert.Thumbprint }
    finally { [void](Remove-PackTuneSigningCertificate -Thumbprint $Cert.Thumbprint) }

    $Signed = Assert-PackTuneSignedMsix -Path $Result.PackagePath -PackageName $Identity.PackageName -Publisher $Cert.Subject -Version $ExpectedVersion -Thumbprint $Cert.Thumbprint
    [pscustomobject]@{
        Msix = $Result.PackagePath; Cer = $Cert.CerPath; Thumbprint = $Cert.Thumbprint; Subject = $Cert.Subject; Identity = $Signed
        PackageName = [string]$Signed.Name; Version = [string]$Signed.Version; JobPath = $Result.JobPath; Documentation = $Result.Documentation
    }
}#Captures and signs one version

function Assert-PackTuneSignedMsix {
    <#
        The identity of a signed MSIX, read from the package itself on this computer: refused unless name, publisher and
        version are exactly the expected ones, the version has four numbers, and the signer is the certificate of this version.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$PackageName, [Parameter(Mandatory = $true)][string]$Publisher,
        [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$Thumbprint)
    $Found = Get-PackTuneMsixIdentity -Path $Path
    if ([string]$Found.Version -notmatch '^\d+(\.\d+){3}$') { throw "The package has an invalid version '$($Found.Version)': not used." }
    if ([string]$Found.Name -cne $PackageName) { throw "The package name is '$($Found.Name)', expected '$PackageName': not used." }
    if ([string]$Found.Publisher -ne $Publisher) { throw "The package publisher is '$($Found.Publisher)', expected '$Publisher': not used." }
    if ([string]$Found.Version -ne $Version) { throw "The package version is '$($Found.Version)', expected '$Version': not used." }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    if (-not $Signature.SignerCertificate -or $Signature.SignerCertificate.Thumbprint -ne $Thumbprint.ToUpper() -or [string]$Signature.Status -in "HashMismatch", "NotSigned") {
        throw "The package is not signed with the certificate of this version (status $($Signature.Status)): not used."
    }
    return $Found
}

function New-PackTuneCustomMsixPackage {
    # The Win32 package of one MSIX version: install.ps1, package.msix, signing.cer; the .intunewin and the detection rule file
    param([Parameter(Mandatory = $true)]$Build, [Parameter(Mandatory = $true)][string]$AppId)
    $WorkPath = New-PackTuneWorkFolder -Name "custom-$AppId"
    $SourcePath = Join-Path $WorkPath "source"
    $null = Assert-PackTuneTrustCertificate -CerPath $Build.Cer -Publisher $(if ($Build.Subject) { [string]$Build.Subject } else { [string](Get-PackTuneMsixInfo -Path $Build.Msix).Publisher })
    $Scripts = Get-PackTuneCustomMsixScripts -AppId $AppId -PackageName $Build.PackageName -Version $Build.Version -Thumbprint $Build.Thumbprint
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $Scripts.Install -Encoding ASCII
    Copy-Item -LiteralPath $Build.Msix -Destination (Join-Path $SourcePath "package.msix") -Force
    Copy-Item -LiteralPath $Build.Cer -Destination (Join-Path $SourcePath "signing.cer") -Force
    $DetectionFile = Join-Path $WorkPath "detection.ps1"
    Set-Content -Path $DetectionFile -Value $Scripts.Detection -Encoding ASCII
    $Package = New-PackTunePackage -WorkPath $WorkPath
    [pscustomobject]@{ WorkPath = $WorkPath; SourcePath = $SourcePath; DetectionFile = $DetectionFile; Package = $Package }
}

function Get-PackTuneMsixLogoBase64 {
    <#
        The logo of a captured MSIX as PNG (base64) for the Company Portal: the largest file of the Square150x150Logo (else
        Square44x44Logo) asset named in AppxManifest.xml (the package holds it per scale and target size). $null when
        there is none.
    #>
    param([Parameter(Mandatory = $true)][string]$MsixPath)
    $Temp = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Zip = [IO.Compression.ZipFile]::OpenRead($MsixPath)
        try {
            $Entry = $Zip.GetEntry('AppxManifest.xml')
            if (-not $Entry) { return $null }
            $Reader = New-Object IO.StreamReader($Entry.Open())
            try { $Xml = [xml]$Reader.ReadToEnd() } finally { $Reader.Dispose() }
            $Visual = @($Xml.SelectNodes("//*[local-name()='VisualElements']")) | Select-Object -First 1
            if (-not $Visual) { return $null }
            foreach ($Attribute in 'Square150x150Logo', 'Square44x44Logo') {
                $Path = ([string]$Visual.GetAttribute($Attribute)) -replace '\\', '/'
                if (-not $Path) { continue }
                $Folder = if ($Path.Contains('/')) { $Path.Substring(0, $Path.LastIndexOf('/')) + '/' } else { '' }
                $File = $Path.Substring($Folder.Length)
                $Base = [IO.Path]::GetFileNameWithoutExtension($File); $Ext = [IO.Path]::GetExtension($File)
                $Pattern = '^' + [regex]::Escape($Folder + $Base) + '(\.(scale|targetsize)-\d+)?(_altform-[A-Za-z-]+)?' + [regex]::Escape($Ext) + '$'
                $Best = @($Zip.Entries | Where-Object { $_.FullName -match $Pattern -and $_.Length -gt 0 }) | Sort-Object Length -Descending | Select-Object -First 1
                if (-not $Best) { continue }
                $Temp = Join-Path ([IO.Path]::GetTempPath()) ('packtune-msix-logo-' + [guid]::NewGuid().ToString('N') + $Ext)
                [IO.Compression.ZipFileExtensions]::ExtractToFile($Best, $Temp, $true)
                $Icon = Get-ChocoIconBase64 -ChocoName 'custom-msix-logo' -IconFile $Temp -NoIconPrompt -NoFeedLookup
                if ($Icon) { return $Icon }
            }
        }
        finally { $Zip.Dispose() }
    }
    catch { Write-Verbose "The logo of the MSIX could not be used: $($_.Exception.Message)" }
    finally { if ($Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue } }
    $null
}

function Add-PackTuneCustomMsixIntuneApp {
    param(
        [Parameter(Mandatory = $true)]$Build, [Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)]$Package, [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$Description, [string]$Publisher, [string]$IconBase64, [string]$Manifest, [string]$ExtraNotes, [string]$Architecture = $script:Settings.Architecture, [string]$MinimumWindows = "W10_1809"
    )
    $DetectionFile = $Package.DetectionFile
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease $MinimumWindows }
    $Notes = "$($script:CustomMarker)msix;app=$AppId;ver=$($Build.Version);identity=$($Build.PackageName);thumb=$($Build.Thumbprint)"
    if ($Manifest) { $Notes += ";manifest=$(ConvertTo-PackTuneManifestAnchor $Manifest)" }
    if ($ExtraNotes) { $Notes += ";$ExtraNotes" }
    $AppParams = @{
        FilePath = $Package.Package.Path; DisplayName = $DisplayName; Description = $(if ($Description) { $Description } else { $DisplayName }); Publisher = $(if ($Publisher) { $Publisher } else { "-" })
        AppVersion = $Build.Version; Notes = $Notes; InstallExperience = "system"; RestartBehavior = "suppress"; DetectionRule = $DetectionRule; RequirementRule = $RequirementRule
        InstallCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
        UninstallCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
    }
    if ($IconBase64) { $AppParams.Icon = $IconBase64 }
    $App = Invoke-IntuneModule { Add-IntuneWin32App @AppParams }
    if ($null -eq $App -or -not $App.id) { throw "Intune did not return the created app" }
    return $App
}

function Save-PackTuneCustomVersionToStore {
    <#
        The files of one version into the package store: package, original installer files (zip, always), recipe, certificate,
        documentation. Returns the manifest hash. -Package is the .intunewin of the Win32 app.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$InstallerFolder,
        [Parameter(Mandatory = $true)]$Recipe, [string]$IntuneWin, [string]$Msix, [string]$Cer, $Documentation, $Store = (Resolve-PackTuneStore)
    )
    $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-store-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $Temp -Force | Out-Null
    try {
        $Files = @{}
        $Files["installer.zip"] = New-PackTuneZip -Folder $InstallerFolder -Path (Join-Path $Temp "installer.zip")
        $RecipeFile = Join-Path $Temp "recipe.json"
        [IO.File]::WriteAllText($RecipeFile, ($Recipe | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
        $Files["recipe.json"] = $RecipeFile
        if ($IntuneWin -and (Test-Path -LiteralPath $IntuneWin)) { $Files["package.intunewin"] = $IntuneWin }
        if ($Msix -and (Test-Path -LiteralPath $Msix)) { $Files["package.msix"] = $Msix }
        if ($Cer -and (Test-Path -LiteralPath $Cer)) { $Files["signing.cer"] = $Cer }
        $DocPath = if ($Documentation -is [string]) { $Documentation } elseif ($Documentation) { [string]($Documentation.Path, $Documentation.Folder, $Documentation.IndexPath | Where-Object { $_ } | Select-Object -First 1) } else { $null }
        if ($DocPath -and (Test-Path -LiteralPath $DocPath)) {
            $DocFolder = if (Test-Path -LiteralPath $DocPath -PathType Container) { $DocPath } else { Split-Path -Path $DocPath -Parent }
            if ($DocFolder -and (Test-Path -LiteralPath $DocFolder)) { $Files["documentation.zip"] = New-PackTuneZip -Folder $DocFolder -Path (Join-Path $Temp "documentation.zip") }
        }
        return (Publish-PackTuneStoreVersion -AppId $AppId -Version $Version -Files $Files -Store $Store -Kind $Kind)
    }
    finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-PackTuneCustomOtherApp {
    <#
        "Other": captures the installation folder as MSIX (sandbox), signs it with a certificate of this version, keeps every
        file of the version in the package store, and deploys it as one Win32 app with the certificate inside. The store is
        required: without it the app could not be updated or edited later. Returns the Intune app id.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Folder, [Parameter(Mandatory = $true)][string]$EntryPoint, [string]$Arguments = "",
        [Parameter(Mandatory = $true)][string]$Name, [string]$Version = "1.0.0.0", [string]$Publisher, [string]$Description, [string]$IconBase64, [string]$FallbackIconBase64,
        [ValidateSet("Available", "Required", "None")][string]$Assignment = $script:Settings.Assignment, [switch]$AllowNetwork
    )
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "The folder $Folder does not exist" }
    $Entry = Join-Path $Folder $EntryPoint
    if (-not (Test-Path -LiteralPath $Entry -PathType Leaf)) { throw "The entry point '$EntryPoint' is not in the folder" }
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready") { throw "The package store is not ready: $($State.Message) It is needed to update and edit the app later." }
    $Identity = Get-PackTuneCustomMsixIdentity -Name $Name
    $AppId = Get-PackTuneCustomAppId ([pscustomobject]@{ Name = $Identity.PackageName; UpgradeCode = "" })
    if (@(Get-PackTuneCustomApps | Where-Object { $_.AppId -eq $AppId }).Count -gt 0) { throw "A custom application with this name exists already. Use New version on it." }

    Write-Host "Capturing $Name from the folder in a fresh Windows Sandbox (this takes a few minutes)"
    $Build = Invoke-PackTuneCustomMsixBuild -Folder $Folder -EntryPoint $EntryPoint -Arguments $Arguments -Name $Name -Version $Version -PublisherDisplayName $Publisher -AllowNetwork:$AllowNetwork
    Write-Host "Building the Win32 package"
    $Package = New-PackTuneCustomMsixPackage -Build $Build -AppId $AppId
    Write-Host "Keeping this version in the package store"
    $Recipe = [ordered]@{ format = "PackTune.Recipe"; kind = "msix"; app = $AppId; name = $Name; version = $Build.Version; publisher = $Publisher; entryPoint = $EntryPoint; arguments = $Arguments; subject = $Build.Subject; identity = $Build.PackageName; thumbprint = $Build.Thumbprint }
    $Manifest = Save-PackTuneCustomVersionToStore -AppId $AppId -Version $Build.Version -Kind "msix" -InstallerFolder $Folder -Recipe $Recipe -IntuneWin $Package.Package.Path -Msix $Build.Msix -Cer $Build.Cer -Documentation $Build.Documentation -Store $State.Store
    Write-Host "Creating and uploading $Name as win32 App to Intune"
    # Icon: the one chosen, else the logo of the captured package, else the fallback (icon of the entry point)
    if (-not $IconBase64) { $IconBase64 = Get-PackTuneMsixLogoBase64 -MsixPath $Build.Msix }
    if (-not $IconBase64) { $IconBase64 = $FallbackIconBase64 }
    $App = Add-PackTuneCustomMsixIntuneApp -Build $Build -AppId $AppId -Package $Package -DisplayName $Name -Description $Description -Publisher $Publisher -IconBase64 $IconBase64 -Manifest $Manifest
    Set-PackTuneAssignment -Id $App.id -Assignment $Assignment
    Write-Host "Deployment of $Name was successful"
    return $App.id
}#Deploys an installation folder as a custom MSIX application

function Update-PackTuneCustomOtherApp {
    <#
        A new version of a custom MSIX app: the previous MSIX and the installer files come from the package store (checked
        against the manifest in the Intune notes), the new installer (-InstallerFolder, else the stored one, which can have been
        edited) runs in a fresh sandbox on top of the restored previous version, the result is signed with a new certificate
        of the same subject and goes out as a new app that supersedes the old one. Returns the new app id.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [string]$InstallerFolder, [string]$EntryPoint, [string]$Arguments, [string]$Version, [switch]$AllowNetwork,
        # A new icon (base64 PNG); without it the icon of the installed version stays
        [string]$IconBase64
    )
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Old = Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId }
    if ($null -eq $Old) { throw "App $AppId was not found in Intune" }
    $OldNotes = ConvertFrom-PackTuneCustomNotes ([string]$Old.notes)
    if (-not $OldNotes -or $OldNotes.Kind -ne "msix") { throw "$($Old.displayName) is not a custom MSIX app of this tool" }
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready") { throw "The package store is not ready: $($State.Message)" }
    $Temp = Join-Path $script:WorkRoot ("update-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    try {
        Write-Host "Getting the previous version from the package store"
        $Prev = Save-PackTuneStoreVersion -AppId $OldNotes.AppId -Version $OldNotes.Version -Destination (Join-Path $Temp "previous") -ExpectedManifest $OldNotes.Manifest -Store $State.Store
        $Recipe = Get-Content -LiteralPath (Join-Path $Prev.Destination "recipe.json") -Raw | ConvertFrom-Json
        $Msix = Join-Path $Prev.Destination "package.msix"
        if (-not (Test-Path -LiteralPath $Msix)) { throw "The stored version has no package.msix" }
        $Folder = if ($InstallerFolder) { $InstallerFolder } else { $Prev.InstallerFolder }
        if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "There is no installer folder for the update" }
        $Entry = if ($EntryPoint) { $EntryPoint } else { [string]$Recipe.entryPoint }
        $Args = if ($PSBoundParameters.ContainsKey("Arguments")) { $Arguments } else { [string]$Recipe.arguments }
        if (-not (Test-Path -LiteralPath (Join-Path $Folder $Entry) -PathType Leaf)) { throw "The entry point '$Entry' is not in the installer folder" }
        $NewVersion = if ($Version) { $Version } else { Get-PackTuneNextVersion -Version $OldNotes.Version }
        if ((Compare-SourceVersion -A $NewVersion -B $OldNotes.Version) -ne 1) { throw "Version $NewVersion is not newer than $($OldNotes.Version)" }

        Write-Host "Capturing the update in a fresh Windows Sandbox on top of the previous version"
        $Build = Invoke-PackTuneCustomMsixBuild -Folder $Folder -EntryPoint $Entry -Arguments $Args -Name ([string]$Old.displayName) -Version $NewVersion -PublisherDisplayName ([string]$Old.publisher) -BasePackage $Msix -AllowNetwork:$AllowNetwork
        Write-Host "Building the Win32 package"
        $Package = New-PackTuneCustomMsixPackage -Build $Build -AppId $OldNotes.AppId
        Write-Host "Keeping the new version in the package store"
        $NewRecipe = [ordered]@{ format = "PackTune.Recipe"; kind = "msix"; app = $OldNotes.AppId; name = [string]$Old.displayName; version = $Build.Version; publisher = [string]$Old.publisher; entryPoint = $Entry; arguments = $Args; subject = $Build.Subject; identity = $Build.PackageName; thumbprint = $Build.Thumbprint }
        $Manifest = Save-PackTuneCustomVersionToStore -AppId $OldNotes.AppId -Version $Build.Version -Kind "msix" -InstallerFolder $Folder -Recipe $NewRecipe -IntuneWin $Package.Package.Path -Msix $Build.Msix -Cer $Build.Cer -Documentation $Build.Documentation -Store $State.Store
        $Icon = if ($IconBase64) { $IconBase64 } elseif ($Old.largeIcon -and $Old.largeIcon.value) { [string]$Old.largeIcon.value } else { Get-PackTuneMsixLogoBase64 -MsixPath $Build.Msix }
        $Architecture = ConvertTo-PackTuneArchitecture $Old
        if (-not $Architecture) { $Architecture = $script:Settings.Architecture }
        Write-Host "Creating and uploading the new app"
        $New = Add-PackTuneCustomMsixIntuneApp -Build $Build -AppId $OldNotes.AppId -Package $Package -DisplayName ([string]$Old.displayName) -Description ([string]$Old.description) -Publisher ([string]$Old.publisher) -IconBase64 $Icon -Manifest $Manifest -Architecture $Architecture
        Complete-PackTuneSupersedingApp -Old $Old -New $New
        return $New.id
    }
    finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}#New version of a custom MSIX application

function Export-PackTuneCustomApp {
    <#
        Downloads one version of a custom application from the package store to a local folder: the package, the original
        installer files (unpacked in <Destination>\installer), recipe, certificate and documentation. Everything is checked
        against the manifest, and the manifest against the notes of the Intune app of that version. Edit the installer
        files and use Update (New version ...) with that folder to replace the app.
    #>
    param([Parameter(Mandatory = $true)][string]$AppId, [string]$Version, [Parameter(Mandatory = $true)][string]$Destination)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Apps = @(Get-PackTuneCustomApps | Where-Object { $_.AppId -eq $AppId })
    $Repo = @($Apps | Where-Object { $_.Repo } | Select-Object -First 1).Repo
    $State = if ($Repo) { $null } else { Get-PackTuneStoreState }
    if (-not $Repo -and $State.State -ne "Ready") { throw "The package store is not ready: $($State.Message)" }
    if (-not $Version) {
        $Latest = @($Apps | Sort-Object { try { [version]$_.Version } catch { [version]"0.0" } } -Descending) | Select-Object -First 1
        $Version = if ($Latest) { $Latest.Version } else { (@(Get-PackTuneStoreVersions -AppId $AppId -Store $State.Store | Where-Object Complete | Sort-Object { try { [version]$_.Version } catch { [version]"0.0" } } -Descending) | Select-Object -First 1).Version }
    }
    if (-not $Version) { throw "No stored version of $AppId was found" }
    $Known = @($Apps | Where-Object { $_.Version -eq $Version }) | Select-Object -First 1
    # Fail closed: without the Intune app of this version (or without manifest= in its notes) nothing vouches for the store
    if (-not $Known) { throw "There is no Intune app of $AppId $Version, so the stored files cannot be checked against Intune: nothing was downloaded." }
    # An app moved to a repository is read from there (the notes say which one), with the same anchor
    if ($Known.Repo) { return (Save-PackTuneRepoVersion -Repository $Known.Repo -AppId $AppId -Version $Version -Destination $Destination -ExpectedManifest ([string]$Known.Manifest)) }
    Save-PackTuneStoreVersion -AppId $AppId -Version $Version -Destination $Destination -ExpectedManifest ([string]$Known.Manifest) -Store $State.Store
}#Downloads a stored version for editing

function Get-PackTuneCustomAnchorReport {
    <#
        Read only, for an administrator before Set-PackTuneCustomManifestAnchor: what the package store holds now for the
        version of one Intune custom app (the manifest, its SHA256, when it was made, every file with size and SHA256) next
        to the manifest hash recorded in the notes. Changed = the store differs from what Intune recorded.
    #>
    param([Parameter(Mandatory = $true)][string]$Id)
    # Read only: its temporary download also runs when the caller previews with -WhatIf
    $WhatIfPreference = $false
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $App = Invoke-IntuneModule { Get-IntuneWin32App -ID $Id }
    if ($null -eq $App) { throw "App $Id was not found in Intune" }
    $Notes = ConvertFrom-PackTuneCustomNotes ([string]$App.notes)
    if (-not $Notes -or -not $Notes.AppId -or -not $Notes.Version) { throw "$($App.displayName) is not a custom application of this tool" }
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready") { throw "The package store is not ready: $($State.Message)" }
    $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-anchor-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $Temp -Force | Out-Null
    try {
        $File = Join-Path $Temp "manifest.json"
        Receive-PackTuneStoreFile -DriveId $State.Store.DriveId -Segments @($Notes.AppId, $Notes.Version, "manifest.json") -Destination $File
        $Hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLower()
        $Manifest = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
    }
    finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
    $Recorded = [string]$Notes.Manifest
    [pscustomobject]@{
        Id = $Id; DisplayName = [string]$App.displayName; AppId = $Notes.AppId; Version = $Notes.Version
        Recorded = $Recorded; StoreManifest = $Hash; Changed = -not ($Recorded -and $Hash.StartsWith($Recorded)); Created = [string]$Manifest.created
        Files = @($Manifest.files | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Size = $_.size; Sha256 = [string]$_.sha256 } })
    }
}#What the store holds against the anchor in Intune

function Set-PackTuneCustomManifestAnchor {
    <#
        Re-anchor (administrator, after Get-PackTuneCustomAnchorReport): records the manifest that is in the store NOW as the
        trusted one in the notes of the Intune app. -StoreManifest must be the hash shown in the report: when the store
        changed again since, nothing is written. Every file is downloaded and checked against that manifest first.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$StoreManifest)
    $Report = Get-PackTuneCustomAnchorReport -Id $Id
    $Wanted = ConvertTo-PackTuneManifestAnchor $StoreManifest
    if ($Report.StoreManifest -ne $Wanted) { throw "The manifest in the store is $($Report.StoreManifest) now, not the $Wanted that was shown: the store changed again. Nothing was recorded; look at the report again." }
    if (-not $PSCmdlet.ShouldProcess($Report.DisplayName, "record the store manifest $Wanted (recorded so far: '$($Report.Recorded)')")) { return $Report }
    # Every file must match the manifest before it becomes the trusted one
    $State = Get-PackTuneStoreState
    $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-anchor-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    try { $null = Save-PackTuneStoreVersion -AppId $Report.AppId -Version $Report.Version -Destination $Temp -ExpectedManifest $Wanted -Store $State.Store }
    finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
    $App = Invoke-IntuneModule { Get-IntuneWin32App -ID $Id }
    $Old = [string]$App.notes
    $New = if ($Old -match '(?:^|;)manifest=[0-9a-f]+(?=;|$)') { $Old -replace '(^|;)manifest=[0-9a-f]+(?=;|$)', "`${1}manifest=$Wanted" } else { "$Old;manifest=$Wanted" }
    Invoke-IntuneModule { Set-IntuneWin32App -ID $Id -Notes $New } | Out-Null
    Write-Host "$($Report.DisplayName) $($Report.Version): the manifest $Wanted is recorded as the trusted one."
    return $Report
}#Records the current store manifest in the notes (after the report)

function Remove-PackTuneCustomStore {
    # Deletes the stored files of an app (all versions). Only when no Intune app of it is left.
    param([Parameter(Mandatory = $true)][string]$AppId)
    $Left = @(Get-PackTuneCustomApps | Where-Object { $_.AppId -eq $AppId })
    if ($Left.Count -gt 0) { throw "$($Left.Count) Intune app(s) of this application are still in the tenant: remove them first" }
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready") { throw "The package store is not ready: $($State.Message)" }
    Remove-PackTuneStoreApp -AppId $AppId -Store $State.Store
}

#endregion
