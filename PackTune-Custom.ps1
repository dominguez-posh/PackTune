<#
    Custom applications: your own software next to the catalog apps (docs\plans\custom-applications.md).

    Phase 1, MSI: fully automatic. The properties of the MSI are read without installing it (Windows Installer API,
    read only), the package is a Win32 app (.intunewin) with PackTune's device scripts (silent install and uninstall
    with msiexec, inside the device lock, in protected folders) and a detection by product code and version. No
    capture, no dependency app (msiexec is part of Windows). A new version is a new app that supersedes the old one
    (type update), with the assignments of the old one, like a release of a catalog app.

    The notes of the Intune app: PoweredByPackTune;custom=msi;app=<id>;ver=<version>;product=<guid>;upgrade=<guid>
    Loaded by PackTune-Main.ps1.
#>

$script:CustomMarker = "PoweredByPackTune;custom="
# Return codes that count as success for msiexec: done, reboot initiated (1641), reboot required (3010)
$script:MsiSuccessCodes = 0, 1641, 3010

#region the MSI

function Get-PackTuneMsiProperties {
    <#
        The Property table of an MSI (ProductCode, ProductName, ProductVersion, Manufacturer, UpgradeCode, ...) through the
        Windows Installer API, opened read only: nothing is installed or changed. -Raw adds the ARPPRODUCTICON name.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $Full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $Properties = @{}
    $Database = $null; $View = $null
    try {
        $Database = $Installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $Installer, @($Full, 0))
        $View = $Database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $Database, @("SELECT Property, Value FROM Property"))
        [void]$View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
        while ($true) {
            $Record = $View.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $View, $null)
            if ($null -eq $Record) { break }
            $Properties[[string]$Record.GetType().InvokeMember("StringData", "GetProperty", $null, $Record, 1)] = [string]$Record.GetType().InvokeMember("StringData", "GetProperty", $null, $Record, 2)
        }
    }
    catch { throw "'$Path' is not a readable MSI package: $($_.Exception.Message)" }
    finally {
        if ($View) { try { [void]$View.GetType().InvokeMember("Close", "InvokeMethod", $null, $View, $null) } catch { } }
        foreach ($Object in $View, $Database, $Installer) { if ($Object) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Object) } }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
    return $Properties
}#Reads the properties of an MSI without installing it

function Save-PackTuneMsiIcon {
    # The icon the MSI shows in "Apps and features" (Icon table, named by ARPPRODUCTICON) as a file, or $null
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$IconName, [Parameter(Mandatory = $true)][string]$Destination)
    if ($IconName -notmatch '^[A-Za-z0-9._]+$') { return $null }
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $Database = $null; $View = $null
    try {
        $Database = $Installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $Installer, @((Resolve-Path -LiteralPath $Path).ProviderPath, 0))
        $View = $Database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $Database, @("SELECT Name, Data FROM Icon WHERE Name = '$IconName'"))
        [void]$View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
        $Record = $View.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $View, $null)
        if ($null -eq $Record) { return $null }
        $Size = [int]$Record.GetType().InvokeMember("DataSize", "GetProperty", $null, $Record, 2)
        if ($Size -le 0 -or $Size -gt 2MB) { return $null }
        $Text = [string]$Record.GetType().InvokeMember("ReadStream", "InvokeMethod", $null, $Record, @(2, $Size, 2))
        [IO.File]::WriteAllBytes($Destination, [Text.Encoding]::GetEncoding(28591).GetBytes($Text))
        return $Destination
    }
    catch { return $null }
    finally {
        foreach ($Object in $View, $Database, $Installer) { if ($Object) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Object) } }
    }
}

function Get-PackTuneMsiInfo {
    <#
        What the tool needs to know about an MSI: name, version, manufacturer, product code, upgrade code and the SHA256
        of the file (baked into the install script, so a changed file is not installed). Throws when something that is
        needed is missing or not valid.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $Full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if ([IO.Path]::GetExtension($Full) -ne ".msi") { throw "'$([IO.Path]::GetFileName($Full))' is not an .msi file" }
    $P = Get-PackTuneMsiProperties -Path $Full
    $Guid = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
    $ProductCode = [string]$P["ProductCode"]
    if ($ProductCode -notmatch $Guid) { throw "The MSI has no valid ProductCode ('$ProductCode')" }
    $Name = ([string]$P["ProductName"]).Trim()
    if (-not $Name) { throw "The MSI has no ProductName" }
    $Version = ([string]$P["ProductVersion"]).Trim()
    if ($Version -notmatch '^\d+(\.\d+){0,3}$') { throw "The ProductVersion '$Version' of the MSI is not a version number (1.2.3.4)" }
    $Upgrade = [string]$P["UpgradeCode"]
    if ($Upgrade -and $Upgrade -notmatch $Guid) { $Upgrade = "" }
    [pscustomobject]@{
        Path = $Full; FileName = [IO.Path]::GetFileName($Full); Name = $Name; Version = $Version
        Manufacturer = ([string]$P["Manufacturer"]).Trim(); ProductCode = $ProductCode.ToUpper(); UpgradeCode = $Upgrade.ToUpper()
        IconName = [string]$P["ARPPRODUCTICON"]; AllUsers = [string]$P["ALLUSERS"]
        Sha256 = (Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash; SizeMB = [Math]::Round((Get-Item -LiteralPath $Full).Length / 1MB, 1)
    }
}#The facts about an MSI

function Get-PackTuneCustomAppId {
    # The id of the product in the tool: the same for every version of it (the upgrade code, else the product name)
    param([Parameter(Mandatory = $true)]$Info)
    $Slug = ($Info.Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $Slug) { $Slug = "app" }
    if ($Slug.Length -gt 40) { $Slug = $Slug.Substring(0, 40).Trim('-') }
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Hash = -join ($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($(if ($Info.UpgradeCode) { $Info.UpgradeCode } else { $Info.Name.ToLower() })))[0..3] | ForEach-Object { $_.ToString("x2") })
    $Sha.Dispose()
    return "$Slug-$Hash"
}

function ConvertTo-PackTuneMsiArguments {
    # Extra public properties for msiexec (NAME=value): names in capitals, values without quotes or control characters
    param($Properties)
    $Parts = foreach ($Key in @($Properties.Keys)) {
        $Value = [string]$Properties[$Key]
        if ($Key -cnotmatch '^[A-Z][A-Z0-9_]*$') { throw "'$Key' is not a public MSI property (capital letters, digits and _)" }
        if ($Value -match '["`\x00-\x1F]') { throw "The value of $Key contains characters that are not allowed (quotes, control characters)" }
        "$Key=`"$Value`""
    }
    return (@($Parts) -join " ")
}

#endregion

#region device scripts

function Get-PackTuneCustomMsiScripts {
    <#
        Install (with -Uninstall: remove) and detection script of an MSI app. Plain ASCII, Windows PowerShell 5.1, SYSTEM:
        64-bit relaunch, the device lock, protected folders under %ProgramFiles%\PackTune, the device log. The install
        copies the MSI into the protected folder and checks its SHA256 before msiexec runs it.
    #>
    param([Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)][string]$AppId, [string]$ExtraArguments = "")
    $Install = @'
# Installs or removes an MSI application (runs as SYSTEM through Intune): msiexec, silent, inside the device lock.
param([switch]$Uninstall)

# The Intune Management Extension starts 32-bit PowerShell
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$AppId = '__APPID__'
$ProductCode = '__PRODUCTCODE__'
$Version = '__VERSION__'
$MsiFile = '__MSIFILE__'
$Sha256 = '__SHA256__'
$ExtraArguments = '__EXTRA__'
$LogId = "custom-$AppId"
$LogTag = if ($Uninstall) { "uninstall" } else { "install" }

__COMMON__

$CustomRoot = Join-Path $ToolRoot "Custom"
$AppRoot = Join-Path $CustomRoot $AppId
try {
    Protect-Folder $ToolRoot
    Protect-Folder $CustomRoot
    Protect-Folder $AppRoot
}
catch { Write-Output "The folder $AppRoot could not be protected: $($_.Exception.Message)"; Write-DeviceLog "folder not protected: $($_.Exception.Message)"; exit 1 }

function Invoke-Msi([string]$Arguments) {
    $Process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\msiexec.exe") -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return $Process.ExitCode
}
$Success = 0, 1641, 3010

if (-not (Enter-DeploymentLock)) { Write-Output "Another installation is still running"; Write-DeviceLog "another installation is still running, Intune tries again"; exit 1618 }
try {
    $MsiLog = Join-Path $AppRoot "msi.log"
    if ($Uninstall) {
        $Code = Invoke-Msi "/x $ProductCode /qn /norestart /l*v `"$MsiLog`""
        Write-DeviceLog "msiexec /x $ProductCode exit code $Code"
        # Not installed (1605) or the product is unknown (1614) counts as removed
        if ($Code -in $Success -or $Code -in 1605, 1614) {
            try { Remove-ItemSafely $AppRoot } catch { Write-DeviceLog "$AppRoot could not be removed: $($_.Exception.Message)" }
            if ($Code -in 1641, 3010) { exit $Code }
            exit 0
        }
        Write-Output "msiexec failed with exit code $Code"
        exit $Code
    }

    # The MSI goes into the protected folder first (the Intune cache is not ours), and must be the one that was packaged
    $Msi = Join-Path $AppRoot $MsiFile
    if (Test-Path -LiteralPath $Msi) { Remove-ItemSafely $Msi }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $MsiFile) -Destination $Msi -Force
    if ((Get-FileHash -LiteralPath $Msi -Algorithm SHA256).Hash -ne $Sha256) {
        Write-Output "The MSI does not match the package (SHA256), nothing is installed"
        Write-DeviceLog "MSI hash mismatch, nothing installed"
        exit 1
    }
    $Code = Invoke-Msi "/i `"$Msi`" /qn /norestart /l*v `"$MsiLog`" $ExtraArguments"
    Write-DeviceLog "msiexec /i $MsiFile $Version exit code $Code"
    if ($Code -in $Success) {
        Write-ProtectedFile (Join-Path $AppRoot "version.txt") "$ProductCode|$Version"
        if ($Code -in 1641, 3010) { exit $Code }
        exit 0
    }
    Write-Output "msiexec failed with exit code $Code (log: $MsiLog)"
    exit $Code
}
finally { Exit-DeploymentLock }
'@
    $Detection = @'
# Detection: the product code is installed (64 or 32 bit view) with this version or newer
$ProductCode = '__PRODUCTCODE__'
$Version = '__VERSION__'
foreach ($View in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
    $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    $Key = $Base.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode")
    if ($Key) {
        $Installed = [string]$Key.GetValue("DisplayVersion")
        $Key.Close()
        try { if ([version]$Installed -lt [version]$Version) { continue } } catch { }
        Write-Output "$ProductCode $Installed is installed"
        exit 0
    }
}
exit 1
'@
    $Quote = { param($Text) ([string]$Text -replace '[^\x20-\x7E]', '').Replace("'", "''") }
    $Fill = {
        param($Text)
        $Text.Replace("__PRODUCTCODE__", $Info.ProductCode).Replace("__VERSION__", $Info.Version).Replace("__APPID__", $AppId).Replace("__MSIFILE__", (& $Quote $Info.FileName)).Replace("__SHA256__", $Info.Sha256).Replace("__EXTRA__", (& $Quote $ExtraArguments))
    }
    [pscustomobject]@{ Install = (& $Fill $Install.Replace("__COMMON__", (Get-DeviceScriptCommon))); Detection = (& $Fill $Detection) }
}#Install and detection script of an MSI app

#endregion

#region notes and the apps in the tenant

function ConvertTo-PackTuneCustomNotes {
    param([Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)][string]$AppId, [string]$Manifest)
    $Notes = "$($script:CustomMarker)msi;app=$AppId;ver=$($Info.Version);product=$($Info.ProductCode);upgrade=$($Info.UpgradeCode)"
    # The start of the manifest hash of the package store: Intune is the trust anchor for what the store holds
    if ($Manifest) { $Notes += ";manifest=$($Manifest.Substring(0, 16).ToLower())" }
    return $Notes
}

function ConvertFrom-PackTuneCustomNotes {
    # Kind, app id, version, product code and upgrade code of a custom app from its notes; $null for anything else
    param([string]$Notes)
    if ($Notes -notlike "$($script:CustomMarker)*") { return $null }
    $Result = [ordered]@{ Kind = $null; AppId = $null; Version = ""; ProductCode = ""; UpgradeCode = ""; Manifest = ""; Identity = ""; Thumbprint = "" }
    if ($Notes -match '(?:^|;)custom=(msi|msix)(?:;|$)') { $Result.Kind = $Matches[1] } else { return $null }
    if ($Notes -match '(?:^|;)app=([a-z0-9-]+)(?:;|$)') { $Result.AppId = $Matches[1] }
    if ($Notes -match '(?:^|;)ver=([0-9.]+)(?:;|$)') { $Result.Version = $Matches[1] }
    if ($Notes -match '(?:^|;)product=(\{[0-9A-Fa-f-]{36}\})(?:;|$)') { $Result.ProductCode = $Matches[1].ToUpper() }
    if ($Notes -match '(?:^|;)upgrade=(\{[0-9A-Fa-f-]{36}\})(?:;|$)') { $Result.UpgradeCode = $Matches[1].ToUpper() }
    if ($Notes -match '(?:^|;)manifest=([0-9a-f]{16})(?:;|$)') { $Result.Manifest = $Matches[1] }
    if ($Notes -match '(?:^|;)identity=([A-Za-z0-9._-]+)(?:;|$)') { $Result.Identity = $Matches[1] }
    if ($Notes -match '(?:^|;)thumb=([0-9A-Fa-f]{40})(?:;|$)') { $Result.Thumbprint = $Matches[1].ToUpper() }
    return [pscustomobject]$Result
}

function Get-PackTuneCustomApps {
    <#
        The custom applications in the tenant, found by the marker in their notes. One row per Intune app (a product with
        older versions that are still superseded has more than one: the newest first). -WithAssignments reads the
        intents of each app (one more call per app).
    #>
    param([switch]$WithAssignments)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Rows = foreach ($App in @(Invoke-IntuneModule { Get-IntuneWin32App })) {
        $Notes = ConvertFrom-PackTuneCustomNotes ([string]$App.notes)
        if (-not $Notes) { continue }
        $Intents = if ($WithAssignments) { @(Get-PackTuneAppIntents -AppId $App.id | Select-Object -Unique) } else { @() }
        [pscustomobject]@{
            Id = [string]$App.id; DisplayName = [string]$App.displayName; Kind = $Notes.Kind; AppId = $Notes.AppId; Version = $Notes.Version
            ProductCode = $Notes.ProductCode; UpgradeCode = $Notes.UpgradeCode; Manifest = $Notes.Manifest; Identity = $Notes.Identity; Thumbprint = $Notes.Thumbprint
            Publisher = [string]$App.publisher; Created = $App.createdDateTime
            Intents = $Intents; Source = "Custom"; IsChocolatey = $false
        }
    }
    return @($Rows | Sort-Object -Property @{ Expression = { $_.DisplayName } }, @{ Expression = { $_.Created }; Descending = $true })
}#Custom applications found in the tenant

#endregion

#region deploy and update

function New-PackTuneCustomAppPackage {
    # Writes the package content (install.ps1, the MSI), builds the .intunewin and the detection rule of one MSI
    param([Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)][string]$AppId, [string]$ExtraArguments = "")
    $WorkPath = New-PackTuneWorkFolder -Name "custom-$AppId"
    $SourcePath = Join-Path $WorkPath "source"
    $Scripts = Get-PackTuneCustomMsiScripts -Info $Info -AppId $AppId -ExtraArguments $ExtraArguments
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $Scripts.Install -Encoding ASCII
    Copy-Item -LiteralPath $Info.Path -Destination (Join-Path $SourcePath $Info.FileName) -Force
    $DetectionFile = Join-Path $WorkPath "detection.ps1"
    Set-Content -Path $DetectionFile -Value $Scripts.Detection -Encoding ASCII
    $Package = New-PackTunePackage -WorkPath $WorkPath
    [pscustomobject]@{ WorkPath = $WorkPath; SourcePath = $SourcePath; DetectionFile = $DetectionFile; Package = $Package }
}

function Add-PackTuneCustomIntuneApp {
    # Uploads the built package as a Win32 app; returns the Intune app
    param(
        [Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)]$Built,
        [Parameter(Mandatory = $true)][string]$DisplayName, [string]$Description, [string]$Publisher, [string]$IconBase64,
        [string]$Architecture = $script:Settings.Architecture, [string]$MinimumWindows = "W10_1607", [string]$Manifest
    )
    $DetectionFile = $Built.DetectionFile
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedWindowsRelease $MinimumWindows }
    $AppParams = @{
        FilePath             = $Built.Package.Path
        DisplayName          = $DisplayName
        Description          = $(if ($Description) { $Description } else { $DisplayName })
        Publisher            = $(if ($Publisher) { $Publisher } else { "-" })
        AppVersion           = $Info.Version
        Notes                = ConvertTo-PackTuneCustomNotes -Info $Info -AppId $AppId -Manifest $Manifest
        InstallExperience    = "system"
        RestartBehavior      = "suppress"
        DetectionRule        = $DetectionRule
        RequirementRule      = $RequirementRule
        InstallCommandLine   = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1"
        UninstallCommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall"
    }
    if ($IconBase64) { $AppParams.Icon = $IconBase64 }
    $App = Invoke-IntuneModule { Add-IntuneWin32App @AppParams }
    if ($null -eq $App -or -not $App.id) { throw "Intune did not return the created app" }
    return $App
}

function Get-PackTuneMsiIconBase64 {
    # The icon of the MSI as PNG (base64) for the Company Portal, or $null (no icon in the MSI, or not usable)
    param([Parameter(Mandatory = $true)]$Info, [string]$IconFile)
    $Temp = $null
    try {
        if (-not $IconFile -and $Info.IconName) {
            $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-msi-icon-" + [guid]::NewGuid().ToString("N") + ".ico")
            $IconFile = Save-PackTuneMsiIcon -Path $Info.Path -IconName $Info.IconName -Destination $Temp
        }
        if (-not $IconFile) { return $null }
        return Get-ChocoIconBase64 -ChocoName ("custom-" + (Get-PackTuneCustomAppId $Info)) -IconFile $IconFile -NoIconPrompt -NoFeedLookup
    }
    catch { Write-Verbose "The icon of the MSI could not be used: $($_.Exception.Message)"; return $null }
    finally { if ($Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue } }
}

function Save-PackTuneCustomMsiToStore {
    <#
        Keeps the MSI version in the package store when a store is set up (the MSI as the "installer files", the package, the
        recipe). No site set: nothing is stored (a warning). A site that is set but not ready is an error: the version
        could not be exported later. Returns the manifest hash or $null.
    #>
    param([Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)]$Built, [string]$Extra)
    if (-not $script:Settings.StoreSiteUrl) { Write-Warning "No package store is set up: this version cannot be exported or edited later (Start page, Package store)."; return $null }
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready") { throw "The package store is not ready: $($State.Message)" }
    $Folder = Join-Path ([IO.Path]::GetTempPath()) ("packtune-msi-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    try {
        Copy-Item -LiteralPath $Info.Path -Destination (Join-Path $Folder $Info.FileName)
        $Recipe = [ordered]@{ format = "PackTune.Recipe"; kind = "msi"; app = $AppId; name = $Info.Name; version = $Info.Version; publisher = $Info.Manufacturer; productCode = $Info.ProductCode; upgradeCode = $Info.UpgradeCode; msi = $Info.FileName; arguments = $Extra }
        Write-Host "Keeping this version in the package store"
        return (Save-PackTuneCustomVersionToStore -AppId $AppId -Version $Info.Version -Kind "msi" -InstallerFolder $Folder -Recipe $Recipe -IntuneWin $Built.Package.Path -Store $State.Store)
    }
    finally { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-PackTuneCustomMsiApp {
    <#
        Deploys an MSI as a Win32 app: reads it, builds the package, uploads it with the detection rule, assigns it.
        A product that is in the tenant already (same product code) is refused; for a newer version use
        Publish-PackTuneCustomVersion. Returns the Intune app id.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [ValidateSet("Available", "Required", "None")][string]$Assignment = $script:Settings.Assignment,
        [string]$DisplayName,
        [string]$Description,
        [string]$Publisher,
        # Extra public properties for msiexec, e.g. @{ ALLUSERS = "1"; INSTALLDIR = "C:\Tools\App" }
        [hashtable]$Properties = @{},
        [string]$IconFile,
        [ValidateSet("x64", "x86", "arm64", "x64x86", "AllWithARM64")][string]$Architecture = $script:Settings.Architecture
    )
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Info = Get-PackTuneMsiInfo -Path $MsiPath
    $AppId = Get-PackTuneCustomAppId $Info
    $Extra = ConvertTo-PackTuneMsiArguments $Properties
    $Name = if ($DisplayName) { $DisplayName.Trim() } else { $Info.Name }
    $Existing = @(Get-PackTuneCustomApps | Where-Object { $_.ProductCode -eq $Info.ProductCode -or ($_.AppId -eq $AppId -and $_.Version -eq $Info.Version) })
    if ($Existing.Count -gt 0) { throw "$($Info.Name) $($Info.Version) is deployed already ($($Existing[0].DisplayName)). Use a newer version (Publish-PackTuneCustomVersion) or remove it first." }

    Write-Host "Building the package for $($Info.Name) $($Info.Version)"
    $Built = New-PackTuneCustomAppPackage -Info $Info -AppId $AppId -ExtraArguments $Extra
    $Icon = Get-PackTuneMsiIconBase64 -Info $Info -IconFile $IconFile
    $Manifest = Save-PackTuneCustomMsiToStore -Info $Info -AppId $AppId -Built $Built -Extra $Extra
    Write-Host "Creating and uploading $Name as win32 App to Intune"
    $App = Add-PackTuneCustomIntuneApp -Info $Info -AppId $AppId -Built $Built -DisplayName $Name -Description $Description -Publisher $(if ($Publisher) { $Publisher } else { $Info.Manufacturer }) -IconBase64 $Icon -Architecture $Architecture -Manifest $Manifest
    Set-PackTuneAssignment -Id $App.id -Assignment $Assignment
    Write-Host "Deployment of $Name was successful"
    return $App.id
}#Deploys an MSI as a Win32 app

function Publish-PackTuneCustomVersion {
    <#
        A newer version of a custom MSI app: a new app for the new MSI (name, publisher, description and icon of the old
        one) that supersedes the old app (type update) and gets its assignments, Available ones with auto-update.
        The old app stays until no device has it (Remove-PackTuneSupersededApps). Returns the id of the new app.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [hashtable]$Properties = @{}
    )
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $Old = Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId }
    if ($null -eq $Old) { throw "App $AppId was not found in Intune" }
    $OldNotes = ConvertFrom-PackTuneCustomNotes ([string]$Old.notes)
    if (-not $OldNotes -or $OldNotes.Kind -ne "msi") { throw "$($Old.displayName) is not a custom MSI app of this tool" }
    $Info = Get-PackTuneMsiInfo -Path $MsiPath
    if ($OldNotes.UpgradeCode -and $Info.UpgradeCode -and $OldNotes.UpgradeCode -ne $Info.UpgradeCode) {
        throw "This MSI belongs to another product (upgrade code $($Info.UpgradeCode), the app has $($OldNotes.UpgradeCode))"
    }
    if ($Info.ProductCode -eq $OldNotes.ProductCode) { throw "This MSI has the same product code as the installed version: devices could not tell it from the old one. Build a major upgrade with a new product code." }
    $Compare = Compare-SourceVersion -A $Info.Version -B $OldNotes.Version
    if ($Compare -ne 1) { throw "Version $($Info.Version) is not newer than $($OldNotes.Version)" }
    $AppKey = if ($OldNotes.AppId) { $OldNotes.AppId } else { Get-PackTuneCustomAppId $Info }
    $Extra = ConvertTo-PackTuneMsiArguments $Properties

    Write-Host "Building the package for $($Info.Name) $($Info.Version)"
    $Built = New-PackTuneCustomAppPackage -Info $Info -AppId $AppKey -ExtraArguments $Extra
    $Icon = if ($Old.largeIcon -and $Old.largeIcon.value) { [string]$Old.largeIcon.value } else { Get-PackTuneMsiIconBase64 -Info $Info }
    $Architecture = ConvertTo-PackTuneArchitecture $Old
    if (-not $Architecture) { $Architecture = $script:Settings.Architecture }
    $Windows = Get-PackTuneMinimumWindows $Old
    if (-not $Windows) { $Windows = "W10_1607" }
    $Manifest = Save-PackTuneCustomMsiToStore -Info $Info -AppId $AppKey -Built $Built -Extra $Extra
    Write-Host "Creating and uploading the new app"
    $New = Add-PackTuneCustomIntuneApp -Info $Info -AppId $AppKey -Built $Built -DisplayName ([string]$Old.displayName) -Description ([string]$Old.description) -Publisher ([string]$Old.publisher) -IconBase64 $Icon -Architecture $Architecture -MinimumWindows $Windows -Manifest $Manifest
    Complete-PackTuneSupersedingApp -Old $Old -New $New
    return $New.id
}#New version of a custom MSI app through supersedence

function Remove-PackTuneCustomApp {
    # Removes a custom app from the tenant (only apps with the custom marker); devices keep the installed software.
    # -DeleteStore also deletes the stored files when this was the last Intune app of the application (SharePoint keeps them in its recycle bin).
    param([Parameter(Mandatory = $true)][string]$Id, [switch]$DeleteStore)
    $App = @(Get-PackTuneCustomApps | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $App) { throw "App $Id is not a custom application of this tool or does not exist any more, nothing was removed" }
    Write-Host "Removing $($App.DisplayName) from Intune"
    Invoke-IntuneModule { Remove-IntuneWin32App -ID $Id } | Out-Null
    if (@(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_.id -eq $Id }).Count -gt 0) { throw "Intune still lists $($App.DisplayName), it was not removed" }
    Write-Host "$($App.DisplayName) was removed from Intune. Devices keep the installed software."
    if ($DeleteStore -and $App.AppId -and @(Get-PackTuneCustomApps | Where-Object { $_.AppId -eq $App.AppId }).Count -eq 0) {
        Remove-PackTuneCustomStore -AppId $App.AppId
        Write-Host "The stored files of $($App.DisplayName) were deleted from the package store."
    }
}#Removes a custom application from the tenant

function Test-PackTuneCustomApp {
    <#
        Tests an MSI app in Windows Sandbox with the test lab of PackTune: the package scripts exactly as deployed (Install,
        Detect, Uninstall with one click each, as SYSTEM). Returns the verdict.
    #>
    param([Parameter(Mandatory = $true)][string]$MsiPath, [hashtable]$Properties = @{}, [switch]$AutoRun)
    $Info = Get-PackTuneMsiInfo -Path $MsiPath
    $AppId = Get-PackTuneCustomAppId $Info
    $Scripts = Get-PackTuneCustomMsiScripts -Info $Info -AppId $AppId -ExtraArguments (ConvertTo-PackTuneMsiArguments $Properties)
    $WorkPath = New-PackTuneWorkFolder -Name "test-custom-$AppId"
    $SourcePath = Join-Path $WorkPath "source"
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $Scripts.Install -Encoding ASCII
    Copy-Item -LiteralPath $Info.Path -Destination (Join-Path $SourcePath $Info.FileName) -Force
    $LabInstall = "& `"`$PSScriptRoot\choco-app.ps1`"`r`nexit `$LASTEXITCODE"
    $LabUninstall = "& `"`$PSScriptRoot\choco-app.ps1`" -Uninstall`r`nexit `$LASTEXITCODE"
    $LabFiles = Join-Path $WorkPath "lab"
    New-Item -ItemType Directory -Path $LabFiles -Force | Out-Null
    Copy-LabPackageFiles -SourcePath $SourcePath -Destination $LabFiles
    Write-Host "Opening the test lab in Windows Sandbox for $($Info.Name): run Install, Detect, Uninstall there, then report the result"
    $Result = Start-PackTuneWin32Lab -DisplayName "$($Info.Name) (custom MSI)" -Version $Info.Version -SourcePath $LabFiles -AutoRun:$AutoRun `
        -Scripts @{ "Install.ps1" = $LabInstall; "Uninstall.ps1" = $LabUninstall; "Detect.ps1" = $Scripts.Detection }
    Write-Host "Test result: $($Result.Verdict). $($Result.Message)"
    [pscustomobject]@{ Package = $Info.Name; Verdict = $Result.Verdict; Message = $Result.Message; JobPath = $Result.JobPath }
}#Tests an MSI app in Windows Sandbox

#endregion
