# PackTune.Sandbox: the Windows Sandbox functions PackTune needs, built into PackTune itself (no other tool required).
#   - toolchain: MSIX Packaging Tool, its driver and license, the SDK signing tools; downloaded on first use,
#     checked against Microsoft's signature and a SHA256 list
#   - capture: an installation FOLDER (installer, script, several files) becomes an MSIX in a fresh sandbox, unattended,
#     also as an update on top of a previous MSIX
#   - signing: single-use certificates with a non-exportable key, signing by thumbprint with a mandatory timestamp,
#     package identity reader
#   - Win32 test lab: Install, Detect, Uninstall as SYSTEM like Intune, with a verdict
# Parts of this code come from MSIX Sandbox Studio (same author, MIT license) and were adapted for PackTune.
# Everything lives below %LOCALAPPDATA%\PackTune\Sandbox (Toolchain, Jobs, Output); the scripts that run inside the
# sandbox are in the Sandbox folder next to Modules and are mapped read-only into it.

$script:SandboxScripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'Sandbox'
$script:SandboxRoot = 'C:\PackTuneSandbox'            # mapped host folders inside the sandbox
$script:SandboxLocal = 'C:\PackTuneSandboxLocal'      # local working copy inside the sandbox
$script:Launcher = $null                              # tests: script block that gets the .wsb path instead of starting a sandbox
$script:LogSink = $null
$script:LearnOfflinePage = 'https://learn.microsoft.com/en-us/windows/msix/packaging-tool/disconnected-environment'
$script:Options = @{
    MemoryMB          = 4096
    VGpu              = $true
    # Network of the test lab (it installs Chocolatey or winget from the internet); a capture has none unless -AllowNetwork
    Networking        = $true
    JobTimeoutMinutes = 45
    TimestampUrl      = 'http://timestamp.digicert.com'
    PollSeconds       = 3
    BootSeconds       = 90
    # After the verdict the result stays visible in the sandbox for this long, then PackTune closes the sandbox it started itself.
    # KeepOpen (or PACKTUNE_SANDBOX_KEEPOPEN=1, set by the "Keep the sandbox open" item of the test menu) leaves it open for manual checks.
    CloseDelaySeconds = 10
    ReleaseWaitSeconds = 60
    KeepOpen          = $false
}
$script:SandboxOwned = $null                         # what PackTune launched: the sandbox processes that existed before, and when
# The SDK signing tools: this NuGet package version and its SHA256 only (checked 2026-11-14: all 44 PE files of bin\*\x64
# carry a valid Microsoft signature). A newer version is a deliberate change here.
$script:SdkBuildTools = @{ Version = '10.0.28000.2957'; Sha256 = 'B7163FC6F636172726D0985963E4F7F11C41AFE1C7FDFE78F8051877360ED696' }
# Used when the Learn page cannot be read or its layout changed
$script:FallbackSource = [pscustomobject]@{
    Version    = '1.2024.405.0'
    BundleUrl  = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.msixbundle'
    LicenseUrl = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.License.xml'
    DriverUrl  = 'https://download.microsoft.com/download/6/c/7/6c7d654b-580b-40d4-8502-f8d435ca125a/Msix-PackagingTool-Driver-Package%7E31bf3856ad364e35%7Eamd64%7E%7E.cab'
}

#region helpers

function Set-PackTuneSandboxLog {
    <# Where progress lines go: a script block taking (text, level). $null = Write-Host. #>
    param([scriptblock]$Sink)
    $script:LogSink = $Sink
}

function Write-SandboxLog {
    param([Parameter(Mandatory = $true)][string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info')
    if ($script:LogSink) { & $script:LogSink $Message $Level; return }
    Write-Host $Message
}

function Set-PackTuneSandboxOption {
    <# Memory, vGPU, networking, timeouts, timestamp server (defaults are fine for normal use; tests change them). #>
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Value)
    if (-not $script:Options.ContainsKey($Name)) { throw "Unknown sandbox option: $Name" }
    $script:Options[$Name] = $Value
}

function Set-PackTuneSandboxLauncher {
    <# Tests: a script block that gets the .wsb path and plays the part of the sandbox. $null = the real Windows Sandbox. #>
    param([scriptblock]$Launcher)
    $script:Launcher = $Launcher
}

function Get-PackTuneSandboxWorkspace {
    <# The folders below %LOCALAPPDATA%\PackTune\Sandbox, created on first use. #>
    $Root = Join-Path $env:LOCALAPPDATA 'PackTune\Sandbox'
    $Workspace = [ordered]@{ Root = $Root; Toolchain = Join-Path $Root 'Toolchain'; Jobs = Join-Path $Root 'Jobs'; Output = Join-Path $Root 'Output' }
    foreach ($Folder in $Workspace.Values) { if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null } }
    [pscustomobject]$Workspace
}

function Get-FileSha256 {
    # Plain .NET instead of Get-FileHash (a script module that does not load in every background runspace)
    param([Parameter(Mandatory = $true)][string]$Path)
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { -join ($Sha.ComputeHash($Stream) | ForEach-Object { $_.ToString('X2') }) }
    finally { $Stream.Dispose(); $Sha.Dispose() }
}

function Save-SandboxDownload {
    param([Parameter(Mandatory = $true)][string]$Uri, [Parameter(Mandatory = $true)][string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Part = "$Destination.part"
    $Client = New-Object System.Net.WebClient
    try { $Client.DownloadFile($Uri, $Part) }
    catch { Remove-Item -LiteralPath $Part -Force -ErrorAction SilentlyContinue; throw }
    finally { $Client.Dispose() }
    Move-Item -LiteralPath $Part -Destination $Destination -Force
}

function ConvertTo-PackTuneMsixVersion {
    <# Any version string as the 4-part form MSIX requires (each part 0-65535). #>
    param([string]$Version)
    $Parts = @([regex]::Matches("$Version", '\d+') | Select-Object -First 4 | ForEach-Object { [Math]::Min([int64]$_.Value, 65535) })
    while ($Parts.Count -lt 4) { $Parts += 0 }
    $Parts -join '.'
}

function ConvertTo-PackTuneMsixPackageName {
    <# Package identity names allow letters, digits, dots and dashes (3-50 characters). #>
    param([string]$Name)
    $Clean = ($Name -replace '[^A-Za-z0-9\.\-]', '').Trim('.', '-')
    if ($Clean.Length -lt 3) { $Clean = "App$Clean" }
    if ($Clean.Length -gt 50) { $Clean = $Clean.Substring(0, 50) }
    $Clean
}

function Get-PackTuneNextMsixVersion {
    <# Last part + 1 (an update needs a higher version). #>
    param([Parameter(Mandatory = $true)][string]$Version)
    $V = [version](ConvertTo-PackTuneMsixVersion $Version)
    '{0}.{1}.{2}.{3}' -f $V.Major, $V.Minor, $V.Build, [Math]::Min(65535, $V.Revision + 1)
}

#endregion

#region Windows Sandbox

function Test-PackTuneSandboxAvailable {
    <# True when the Windows Sandbox feature is installed. #>
    Test-Path (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe')
}

function Test-SandboxIsolated {
    <#
        Tests never look at the real Windows Sandbox processes (a sandbox of the user or of another agent made the smoke and the checks wait for it).
        A run whose %LOCALAPPDATA% is not the real profile's (every check and the smoke set their own) is isolated: the process lookup answers from
        PACKTUNE_SANDBOX_FAKEIDS (a comma list of ids, empty = no sandbox) instead. The live spikes set PACKTUNE_SANDBOX_REAL=1 to look at the real ones.
    #>
    if ($env:PACKTUNE_SANDBOX_REAL -eq '1') { return $false }
    $Real = [Environment]::GetFolderPath('LocalApplicationData')
    [bool]($env:LOCALAPPDATA -and $Real -and ($env:LOCALAPPDATA.TrimEnd('\') -ne $Real.TrimEnd('\')))
}

function Test-PackTuneSandboxRunning {
    <# Windows Sandbox runs one instance at a time. #>
    if (Test-SandboxIsolated) { return [bool]@(Get-SandboxProcessIds).Count }
    [bool](Get-Process -Name 'WindowsSandboxRemoteSession', 'WindowsSandboxClient' -ErrorAction SilentlyContinue)
}

function New-SandboxJob {
    # A job folder with job.json (mapped into the sandbox); returns its path
    param([Parameter(Mandatory = $true)][ValidateSet('Package', 'Lab')][string]$Mode, [string]$Name = 'sandbox', [hashtable]$Data = @{})
    $Id = '{0:yyyyMMdd-HHmmss}-{1}-{2}' -f (Get-Date), $Mode.ToLower(), ($Name -replace '[^\w\.-]', '_')
    $Path = Join-Path (Get-PackTuneSandboxWorkspace).Jobs $Id
    New-Item -ItemType Directory -Path (Join-Path $Path 'input'), (Join-Path $Path 'out') -Force | Out-Null
    $Job = [ordered]@{ Id = $Id; Mode = $Mode; Created = (Get-Date).ToString('o') }
    foreach ($Key in $Data.Keys) { $Job[$Key] = $Data[$Key] }
    $Job | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Path 'job.json') -Encoding UTF8
    $Path
}

function New-SandboxConfig {
    # The .wsb file of a job: mapped folders, logon command, resources
    param(
        [Parameter(Mandatory = $true)][string]$JobPath, [bool]$Networking = $true, [string]$InputFolder, [switch]$NoToolchain
    )
    $Workspace = Get-PackTuneSandboxWorkspace
    $Maps = @(
        @{ Host = $JobPath; Sandbox = "$script:SandboxRoot\Job"; ReadOnly = $false }
        @{ Host = $script:SandboxScripts; Sandbox = "$script:SandboxRoot\Tools"; ReadOnly = $true }
    )
    if (-not $NoToolchain) { $Maps += @{ Host = $Workspace.Toolchain; Sandbox = "$script:SandboxRoot\Toolchain"; ReadOnly = $true } }
    if ($InputFolder) { $Maps += @{ Host = $InputFolder; Sandbox = "$script:SandboxRoot\Input"; ReadOnly = $true } }
    $Esc = { param($Text) [Security.SecurityElement]::Escape($Text) }
    $Folders = ($Maps | ForEach-Object {
        "    <MappedFolder>`r`n      <HostFolder>$(& $Esc $_.Host)</HostFolder>`r`n      <SandboxFolder>$(& $Esc $_.Sandbox)</SandboxFolder>`r`n      <ReadOnly>$($_.ReadOnly.ToString().ToLower())</ReadOnly>`r`n    </MappedFolder>"
    }) -join "`r`n"
    $Logon = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:SandboxRoot\Tools\Bootstrap.ps1"
    $Wsb = @"
<Configuration>
  <vGPU>$(if ($script:Options.VGpu) { 'Enable' } else { 'Disable' })</vGPU>
  <Networking>$(if ($Networking) { 'Enable' } else { 'Disable' })</Networking>
  <MemoryInMB>$($script:Options.MemoryMB)</MemoryInMB>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MappedFolders>
$Folders
  </MappedFolders>
  <LogonCommand>
    <Command>$(& $Esc $Logon)</Command>
  </LogonCommand>
</Configuration>
"@
    $Path = Join-Path $JobPath 'sandbox.wsb'
    Set-Content -Path $Path -Value $Wsb -Encoding UTF8
    $Path
}

function Test-FakeLauncher {
    # Tests: a launcher that plays the part of the sandbox (set with Set-PackTuneSandboxLauncher, or for background runspaces
    # of the GUI test through the environment variable PACKTUNE_SANDBOX_LAUNCHER, the path of a script that gets the .wsb path)
    [bool]($script:Launcher -or $env:PACKTUNE_SANDBOX_LAUNCHER)
}

function Get-SandboxProcessIds {
    # Ids of the Windows Sandbox processes that run now (replaceable in tests; isolated runs read PACKTUNE_SANDBOX_FAKEIDS, never the real processes)
    if (Test-SandboxIsolated) { return @(([string]$env:PACKTUNE_SANDBOX_FAKEIDS -split ',') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
    @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

function Stop-SandboxProcessId([int]$Id) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }

function Close-PackTuneOwnedSandbox {
    <#
        Closes the sandbox PackTune started for this job: only processes that did not exist when PackTune launched it (a sandbox the user
        started himself is never touched; PackTune does not launch while one is open). Returns the ids it closed.
    #>
    if (-not $script:SandboxOwned) { return @() }
    $Mine = @(Get-SandboxProcessIds | Where-Object { $_ -notin @($script:SandboxOwned.Before) })
    foreach ($Id in $Mine) { Stop-SandboxProcessId -Id $Id }
    $Mine
}

function Wait-PackTuneSandboxClosed {
    # Waits (does not close anything) until the sandbox processes PackTune started have exited; $true = gone
    param([int]$Seconds = $script:Options.ReleaseWaitSeconds)
    $Until = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        $Left = if ($script:SandboxOwned) { @(Get-SandboxProcessIds | Where-Object { $_ -notin @($script:SandboxOwned.Before) }) } else { @() }
        if (-not $Left.Count) { return $true }
        if ((Get-Date) -ge $Until) { return $false }
        Start-Sleep -Seconds ([Math]::Min(2, [Math]::Max(0, $script:Options.PollSeconds)))
    }
}

function Complete-SandboxJob {
    <#
        After the verdict: the result stays visible for CloseDelaySeconds, then the sandbox PackTune started is closed and its end is awaited,
        so the mapped folders are free before anything is packaged. With KeepOpen it stays open (the user closes it).
    #>
    $Keep = $script:Options.KeepOpen -or $env:PACKTUNE_SANDBOX_KEEPOPEN -eq '1'
    if (-not $script:SandboxOwned) { return }
    if ($Keep) { Write-SandboxLog 'The Windows Sandbox stays open as you asked: close it yourself before you deploy.'; return }
    Write-SandboxLog "Result received: the sandbox closes in $($script:Options.CloseDelaySeconds) seconds."
    if ($script:Options.CloseDelaySeconds -gt 0) { Start-Sleep -Seconds $script:Options.CloseDelaySeconds }
    $Closed = @(Close-PackTuneOwnedSandbox)
    if ($Closed.Count -and -not (Wait-PackTuneSandboxClosed)) { Write-SandboxLog 'The Windows Sandbox is still closing; packaging waits for it.' 'Warning' }
    else { Write-SandboxLog 'Windows Sandbox closed.' }
    $script:SandboxOwned = $null
}

function Start-SandboxProcess {
    param([Parameter(Mandatory = $true)][string]$WsbPath)
    $script:SandboxOwned = @{ Before = @(Get-SandboxProcessIds); Started = Get-Date }
    if ($script:Launcher) { & $script:Launcher $WsbPath; return }
    if ($env:PACKTUNE_SANDBOX_LAUNCHER) { & $env:PACKTUNE_SANDBOX_LAUNCHER $WsbPath; return }
    if (-not (Test-PackTuneSandboxAvailable)) { throw 'Windows Sandbox is not installed on this computer.' }
    # A sandbox that has just finished a job needs a few seconds to shut down; one that stays is open on purpose
    $Until = (Get-Date).AddSeconds(45)
    while ((Test-PackTuneSandboxRunning) -and (Get-Date) -lt $Until) { Start-Sleep -Seconds 2 }
    if (Test-PackTuneSandboxRunning) { throw 'A Windows Sandbox is already open. Windows runs only one at a time; close it first.' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe') -ArgumentList "`"$WsbPath`""
}

function Wait-SandboxJob {
    # Waits until the sandbox reports Succeeded or Failed in status.json; writes each new step to the log
    param([Parameter(Mandatory = $true)][string]$JobPath, [int]$TimeoutMinutes = 45)
    $StatusPath = Join-Path $JobPath 'status.json'
    $Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $Started = Get-Date
    $LastStep = ''
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds $script:Options.PollSeconds
        $Status = $null
        if (Test-Path $StatusPath) { try { $Status = Get-Content $StatusPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { } }
        if ($Status) {
            if ($Status.Step -and $Status.Step -ne $LastStep) { $LastStep = $Status.Step; Write-SandboxLog "  [sandbox] $($Status.Step)" }
            if ($Status.State -in 'Succeeded', 'Failed') { return $Status }
        }
        # The sandbox was closed without a final status (closed by hand, crash): it gets time to boot first
        if (((Get-Date) - $Started).TotalSeconds -gt $script:Options.BootSeconds -and -not (Test-FakeLauncher) -and -not (Test-PackTuneSandboxRunning)) {
            return [pscustomobject]@{ State = 'Failed'; Step = $LastStep; Message = 'The sandbox was closed before the job finished.' }
        }
    }
    [pscustomobject]@{ State = 'Failed'; Step = $LastStep; Message = "Timeout after $TimeoutMinutes minutes." }
}

#endregion

#region toolchain

function Get-PackTuneToolchainSource {
    <# The current offline download of the MSIX Packaging Tool on Microsoft Learn; the last known one if the page cannot be read. #>
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $Html = (Invoke-WebRequest -Uri $script:LearnOfflinePage -UseBasicParsing -TimeoutSec 20).Content
        $Bundle = [regex]::Match($Html, 'https://download\.microsoft\.com/[^"''\s]+?MSIXPackagingtoolv([\d\.]+?)\.msixbundle', 'IgnoreCase')
        $License = [regex]::Match($Html, 'https://download\.microsoft\.com/[^"''\s]+?\.License\.xml', 'IgnoreCase')
        $Driver = [regex]::Match($Html, 'href="(https://download\.microsoft\.com/[^"]+?amd64[^"]*?\.cab)"[^>]*>[^<]*Windows 11', 'IgnoreCase')
        if ($Bundle.Success -and $License.Success -and $Driver.Success) {
            return [pscustomobject]@{ Version = $Bundle.Groups[1].Value.TrimEnd('.'); BundleUrl = $Bundle.Value; LicenseUrl = $License.Value; DriverUrl = $Driver.Groups[1].Value }
        }
        Write-SandboxLog 'Learn page layout not recognized, using the last known download links.' 'Warning'
    }
    catch { Write-SandboxLog "Learn page not reachable ($($_.Exception.Message)), using the last known download links." 'Warning' }
    $script:FallbackSource
}

function Get-PackTuneToolchain {
    <# The cached toolchain (versions, file paths, IsComplete) or $null when nothing was downloaded yet. -VerifyHash checks every file. #>
    param([switch]$VerifyHash)
    $Dir = (Get-PackTuneSandboxWorkspace).Toolchain
    $ManifestPath = Join-Path $Dir 'toolchain.json'
    if (-not (Test-Path $ManifestPath)) { return $null }
    # A damaged manifest counts as not downloaded: the next run fetches the toolchain again
    try { $Manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $Manifest) { return $null }
    $Ok = $true
    foreach ($File in $Manifest.Files) {
        $Path = Join-Path $Dir $File.Name
        if (-not (Test-Path $Path)) { $Ok = $false; continue }
        if ($VerifyHash -and (Get-FileSha256 $Path) -ne $File.Sha256) { Write-SandboxLog "Hash mismatch: $($File.Name)" 'Error'; $Ok = $false }
    }
    $SignTool = Join-Path $Dir 'SdkTools\signtool.exe'
    [pscustomobject]@{
        Path = $Dir; Version = $Manifest.Version; SdkToolsVersion = $Manifest.SdkToolsVersion; Downloaded = [datetime]$Manifest.Downloaded
        Bundle = Join-Path $Dir 'MSIXPackagingTool.msixbundle'; License = Join-Path $Dir 'MSIXPackagingTool.License.xml'
        Driver = Join-Path $Dir 'Msix-PackagingTool-Driver-Package.cab'; SignTool = $SignTool; MakeAppx = Join-Path $Dir 'SdkTools\makeappx.exe'
        # Toolchains from before the pin (SDK tools not in the SHA256 list, other version) count as incomplete: downloaded again
        IsComplete = $Ok -and (Test-Path $SignTool) -and [string]$Manifest.SdkToolsVersion -eq $script:SdkBuildTools.Version -and @($Manifest.Files | Where-Object { [string]$_.Name -eq 'SdkTools\signtool.exe' }).Count -eq 1 -and @($Manifest.Files | Where-Object { [string]$_.Name -eq 'SdkTools\makeappx.exe' }).Count -eq 1
        Files = $Manifest.Files
    }
}

function Get-PackTuneToolchainState {
    <# For the readiness list: Missing (nothing downloaded yet), Damaged or Ready, with a message. #>
    $Toolchain = Get-PackTuneToolchain
    if (-not $Toolchain) { return [pscustomobject]@{ State = 'Missing'; Version = $null; Message = 'The capture tools (MSIX Packaging Tool, signing tools from Microsoft) are downloaded the first time they are needed.' } }
    if (-not $Toolchain.IsComplete) { return [pscustomobject]@{ State = 'Damaged'; Version = $Toolchain.Version; Message = 'The downloaded capture tools are incomplete and are downloaded again the next time they are needed.' } }
    [pscustomobject]@{ State = 'Ready'; Version = $Toolchain.Version; Message = "The capture tools are ready (MSIX Packaging Tool $($Toolchain.Version))." }
}

function Assert-MicrosoftSignature {
    # Downloaded tools run with administrator rights in the sandbox and sign packages here: they must be Microsoft's
    param([Parameter(Mandatory = $true)][string]$Path)
    $Signature = Get-AuthenticodeSignature -FilePath $Path
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "$(Split-Path $Path -Leaf) is not signed by Microsoft (signature: $($Signature.Status)). The download was removed."
    }
}

function Expand-PackTuneZip {
    # Unpacks a zip; refuses entries that would end up outside the destination (zip slip) before anything is written
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Root = [IO.Path]::GetFullPath($Destination).TrimEnd("\") + "\"
    $Zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Target = [IO.Path]::GetFullPath((Join-Path $Destination $Entry.FullName))
            if (-not $Target.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { throw "The archive contains a path outside the target folder ('$($Entry.FullName)'), nothing was unpacked." }
        }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        foreach ($Entry in $Zip.Entries) {
            $Target = [IO.Path]::GetFullPath((Join-Path $Destination $Entry.FullName))
            if ($Entry.FullName.EndsWith("/")) { New-Item -ItemType Directory -Path $Target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Target, $true)
        }
    }
    finally { $Zip.Dispose() }
}

function Update-SdkTools {
    <#
        signtool and makeappx (x64) from the Microsoft.Windows.SDK.BuildTools NuGet package; returns its version. The version
        and the SHA256 of the package are pinned ($script:SdkBuildTools; a newer one is a deliberate change of this file), the
        package is unpacked zip-slip safe, and every PE file (exe, dll, mui) must carry a valid Microsoft signature.
    #>
    param([Parameter(Mandatory = $true)][string]$Destination)
    $Version = $script:SdkBuildTools.Version
    Write-SandboxLog "Downloading the Windows SDK build tools $Version (signtool, makeappx) ..."
    $Work = Join-Path ([IO.Path]::GetTempPath()) ("packtune-sdkbuildtools-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $Work -Force | Out-Null
    try {
        $Package = Join-Path $Work "package.zip"
        Save-SandboxDownload -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/$Version/microsoft.windows.sdk.buildtools.$Version.nupkg" -Destination $Package
        $Hash = Get-FileSha256 $Package
        if ($Hash -ne $script:SdkBuildTools.Sha256) { throw "The SDK build tools package $Version does not have the pinned SHA256 (got $Hash). Nothing was installed." }
        Expand-PackTuneZip -Path $Package -Destination (Join-Path $Work "x")
        $X64 = @(Get-ChildItem -LiteralPath (Join-Path $Work "x\bin") -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "x64" } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
        if (-not $X64) { throw 'The SDK build tools package contains no x64 tools.' }
        foreach ($File in @(Get-ChildItem -LiteralPath $X64 -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll', '.mui' })) { Assert-MicrosoftSignature -Path $File.FullName }
        if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -Path (Join-Path $X64 '*') -Destination $Destination -Recurse -Force
    }
    finally { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
    $Version
}

function Update-PackTuneToolchain {
    <#
        Downloads the MSIX Packaging Tool, its license and driver and the SDK signing tools (once; -Force again). Microsoft's
        signature is checked on every file and the SHA256 of all files is written to toolchain.json (checked on use with
        Get-PackTuneToolchain -VerifyHash).
    #>
    param([switch]$Force)
    $Dir = (Get-PackTuneSandboxWorkspace).Toolchain
    $Source = Get-PackTuneToolchainSource
    $Current = Get-PackTuneToolchain
    if (-not $Force -and $Current -and $Current.IsComplete -and $Current.Version -eq $Source.Version) { return $Current }
    # The folder is mapped into every sandbox: replacing files under a running one breaks its job
    if (-not (Test-FakeLauncher) -and (Test-PackTuneSandboxRunning)) { throw 'Close the open Windows Sandbox before the capture tools are downloaded (their folder is in use there).' }
    $Files = @(
        @{ Name = 'MSIXPackagingTool.msixbundle'; Url = $Source.BundleUrl; Signed = $true }
        @{ Name = 'MSIXPackagingTool.License.xml'; Url = $Source.LicenseUrl; Signed = $false }
        @{ Name = 'Msix-PackagingTool-Driver-Package.cab'; Url = $Source.DriverUrl; Signed = $true }
    )
    $Step = 0
    foreach ($File in $Files) {
        $Step++
        Write-SandboxLog "Downloading the capture tools ($Step of $($Files.Count + 1)): $($File.Name) ..."
        $Target = Join-Path $Dir $File.Name
        Save-SandboxDownload -Uri $File.Url -Destination $Target
        if ($File.Signed) { Assert-MicrosoftSignature -Path $Target }
    }
    Write-SandboxLog "Downloading the capture tools ($($Files.Count + 1) of $($Files.Count + 1)): Windows SDK signing tools ..."
    $SdkVersion = Update-SdkTools -Destination (Join-Path $Dir 'SdkTools')
    # Every file of the SDK tools (signtool, makeappx and the DLLs they load) is in the SHA256 list, checked on every use
    $SdkFiles = @(Get-ChildItem -LiteralPath (Join-Path $Dir 'SdkTools') -Recurse -File | ForEach-Object { @{ Name = $_.FullName.Substring($Dir.TrimEnd('\').Length + 1); Url = 'nuget:microsoft.windows.sdk.buildtools/' + $SdkVersion } })
    $Manifest = [ordered]@{
        Version = $Source.Version; SdkToolsVersion = $SdkVersion; Downloaded = (Get-Date).ToString('o')
        Files = @(@($Files) + $SdkFiles | ForEach-Object { [ordered]@{ Name = $_.Name; Url = $_.Url; Sha256 = (Get-FileSha256 (Join-Path $Dir $_.Name)) } })
    }
    $Manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Dir 'toolchain.json') -Encoding UTF8
    Write-SandboxLog "The capture tools are ready: MSIX Packaging Tool $($Source.Version), SDK tools $SdkVersion." 'Success'
    Get-PackTuneToolchain
}

function Confirm-PackTuneToolchain {
    # The toolchain for a run: downloaded when missing, hashes checked when it is there
    $Toolchain = Get-PackTuneToolchain -VerifyHash
    if (-not ($Toolchain -and $Toolchain.IsComplete)) { $Toolchain = Update-PackTuneToolchain -Force }
    if (-not ($Toolchain -and $Toolchain.IsComplete)) { throw 'The capture tools could not be prepared.' }
    $Toolchain
}

#endregion

#region packages and signing

function Get-PackTuneMsixInfo {
    <# Identity, display names and applications from the AppxManifest.xml inside an .msix. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $Zip = [IO.Compression.ZipFile]::OpenRead($Full)
    try {
        $Entry = $Zip.GetEntry('AppxManifest.xml')
        if (-not $Entry) { throw 'AppxManifest.xml not found: is this an .msix package (not a bundle)?' }
        $Reader = New-Object IO.StreamReader($Entry.Open())
        try { [xml]$Manifest = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        $Signed = [bool]$Zip.GetEntry('AppxSignature.p7x')
    }
    finally { $Zip.Dispose() }
    $Id = $Manifest.Package.Identity
    [pscustomobject]@{
        Path = $Full; Name = $Id.Name; Publisher = $Id.Publisher; Version = $Id.Version
        Architecture = $(if ($Id.ProcessorArchitecture) { $Id.ProcessorArchitecture } else { 'neutral' })
        DisplayName = $Manifest.Package.Properties.DisplayName; PublisherDisplayName = $Manifest.Package.Properties.PublisherDisplayName
        Applications = @($Manifest.Package.Applications.Application | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Executable = $_.Executable } })
        IsSigned = $Signed; SizeBytes = (Get-Item -LiteralPath $Full).Length
    }
}

function Get-PackTunePublisherHash {
    # The 13 character publisher id of a package family name (SHA256 over UTF-16LE, first 64 bits, base32)
    param([Parameter(Mandatory = $true)][string]$Publisher)
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Hash = $Sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($Publisher))
    $Bits = (($Hash[0..7] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '') + '0'
    $Alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    -join (0..12 | ForEach-Object { $Alphabet[[Convert]::ToInt32($Bits.Substring($_ * 5, 5), 2)] })
}

function Get-PackTuneMsixIdentity {
    <# Name, publisher, version, architecture, family name and full name of a built .msix (full name = PackageName of Get-AppxProvisionedPackage). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $Info = Get-PackTuneMsixInfo -Path $Path
    $PublisherId = Get-PackTunePublisherHash -Publisher $Info.Publisher
    [pscustomobject]@{
        Name = $Info.Name; Publisher = $Info.Publisher; Version = $Info.Version; Architecture = $Info.Architecture; PublisherId = $PublisherId
        FamilyName = '{0}_{1}' -f $Info.Name, $PublisherId
        FullName = '{0}_{1}_{2}__{3}' -f $Info.Name, $Info.Version, $Info.Architecture, $PublisherId
        IsSigned = $Info.IsSigned; Path = $Info.Path
    }
}

function New-PackTuneSigningCertificate {
    <#
        A throw-away code signing certificate with a NON-exportable key in CurrentUser\My and its public .cer. For one package
        version: sign with Invoke-PackTuneSigning, then call Remove-PackTuneSigningCertificate, also on errors (try/finally).
        RSA 3072, SHA256, code signing only, not a CA. The subject becomes the publisher of the package.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^CN=[^,+="<>;\#]{1,64}$')][string]$Subject,
        [ValidateRange(1, 30)][int]$Years = 5,
        [string]$OutputFolder
    )
    if (-not $OutputFolder) { $OutputFolder = Join-Path ([IO.Path]::GetTempPath()) ('packtune-cert-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
    if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
    $Cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature -FriendlyName "PackTune (single use) - $Subject" `
        -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') `
        -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears($Years)
    try {
        $CerPath = Join-Path $OutputFolder ('{0}.cer' -f $Cert.Thumbprint)
        [IO.File]::WriteAllBytes($CerPath, $Cert.Export('Cert'))
    }
    catch {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($Cert.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue
        throw
    }
    Write-SandboxLog "Single-use signing certificate created: $Subject ($($Cert.Thumbprint))"
    [pscustomobject]@{ Thumbprint = $Cert.Thumbprint; Subject = $Cert.Subject; CerPath = $CerPath; NotAfter = $Cert.NotAfter }
}

function Remove-PackTuneSigningCertificate {
    <# Deletes the certificate and its key from CurrentUser\My and verifies that it is gone. $true = removed, $false = it was not there; throws if it is still there. #>
    param([Parameter(Mandatory = $true)][string]$Thumbprint)
    if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'The certificate thumbprint must be 40 hex characters.' }
    $Path = "Cert:\CurrentUser\My\$($Thumbprint.ToUpper())"
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Remove-Item -LiteralPath $Path -DeleteKey -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { throw "Certificate $Thumbprint could not be removed from CurrentUser\My." }
    Write-SandboxLog "Single-use signing certificate removed: $Thumbprint"
    $true
}

function Get-SigningCertificate {
    # A certificate with private key from CurrentUser\My by thumbprint (validated: no wildcards in the path)
    param([Parameter(Mandatory = $true)][string]$Thumbprint)
    if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'The certificate thumbprint must be 40 hex characters.' }
    $Cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($Thumbprint.ToUpper())" -ErrorAction SilentlyContinue
    if (-not $Cert) { throw "Certificate $Thumbprint not found in CurrentUser\My." }
    if (-not $Cert.HasPrivateKey) { throw "Certificate $Thumbprint has no private key." }
    $Cert
}

function Invoke-PackTuneSigning {
    <#
        Signs an .msix with a certificate from CurrentUser\My by thumbprint (signtool from the toolchain, SHA256). The publisher of
        the package must equal the certificate subject. The RFC 3161 timestamp is mandatory: without a reachable timestamp server
        signing fails and nothing is signed without it, unless -AllowNoTimestamp is given.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$CertificateThumbprint,
        [string]$TimestampUrl, [switch]$AllowNoTimestamp
    )
    $Toolchain = Get-PackTuneToolchain
    if (-not ($Toolchain -and (Test-Path -LiteralPath $Toolchain.SignTool))) { throw 'signtool was not found: the capture tools are not downloaded yet.' }
    $Package = Get-PackTuneMsixInfo -Path $Path
    $Cert = Get-SigningCertificate -Thumbprint $CertificateThumbprint
    if ($Package.Publisher -ne $Cert.Subject) { throw "Publisher mismatch: the package says '$($Package.Publisher)', the certificate is '$($Cert.Subject)'." }
    $Timestamp = if ($TimestampUrl) { $TimestampUrl } else { $script:Options.TimestampUrl }
    $Mandatory = -not $AllowNoTimestamp
    if ($Mandatory -and -not $Timestamp) { throw 'No timestamp server is set: the RFC 3161 timestamp is mandatory.' }
    $Base = @('sign', '/fd', 'SHA256', '/s', 'My', '/sha1', $Cert.Thumbprint)
    $Attempts = @()
    if ($Timestamp) { $Attempts += , @('/tr', $Timestamp, '/td', 'SHA256') }
    if (-not $Mandatory) { $Attempts += , @() }
    foreach ($Extra in $Attempts) {
        # Windows PowerShell turns a line on stderr of a native tool into an error when $ErrorActionPreference is Stop
        $Previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try { $Output = & $Toolchain.SignTool @($Base + $Extra + @($Package.Path)) 2>&1 | ForEach-Object { "$_" }; $Exit = $LASTEXITCODE }
        finally { $ErrorActionPreference = $Previous }
        if ($Exit -eq 0) {
            if (-not $Extra) { Write-SandboxLog 'Signed WITHOUT a timestamp (the timestamp server was not reachable): the signature ends with the certificate.' 'Warning' }
            Write-SandboxLog "Signed: $(Split-Path $Package.Path -Leaf)" 'Success'
            return (Get-PackTuneMsixInfo -Path $Package.Path)
        }
        Write-SandboxLog "signtool: $(($Output | Out-String).Trim())" 'Warning'
    }
    if ($Mandatory) { throw 'Signing with a timestamp failed (timestamp server not reachable?), see the signtool output above. Nothing was signed without a timestamp.' }
    throw 'Signing failed, see the signtool output above.'
}

#endregion

#region capture

function Get-EntryCommand {
    # EntryPoint (relative path inside Folder) as the commands for the sandbox's local copy of the folder.
    # .exe/.msi: the Packaging Tool can start it directly (IsDirect). .ps1/.cmd/.bat: through the interpreter, always by the wrapper script.
    param([Parameter(Mandatory = $true)][string]$Folder, [Parameter(Mandatory = $true)][string]$EntryPoint, [string]$Arguments = '', [Parameter(Mandatory = $true)][string]$SandboxFolder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Installation folder missing: $Folder" }
    $Root = (Resolve-Path -LiteralPath $Folder).ProviderPath.TrimEnd('\')
    if ([IO.Path]::IsPathRooted($EntryPoint)) { throw 'The entry point must be a path relative to the installation folder.' }
    $Full = [IO.Path]::GetFullPath((Join-Path $Root $EntryPoint))
    if (-not $Full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The entry point must be inside the installation folder.' }
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { throw "Entry point not found in the folder: $EntryPoint" }
    $Relative = $Full.Substring($Root.Length + 1)
    $Local = $SandboxFolder.TrimEnd('\') + '\' + $Relative
    $WorkDir = $Local.Substring(0, $Local.LastIndexOf('\'))
    $Sys = 'C:\Windows\System32'
    $Entry = [ordered]@{ Relative = $Relative; LocalPath = $Local; WorkingDirectory = $WorkDir; IsDirect = $false; DirectPath = $null; DirectArguments = $null; FilePath = $null; ArgumentList = $null }
    switch ([IO.Path]::GetExtension($Full).ToLowerInvariant()) {
        '.exe' { $Entry.IsDirect = $true; $Entry.DirectPath = $Local; $Entry.DirectArguments = $Arguments; $Entry.FilePath = $Local; $Entry.ArgumentList = $Arguments }
        '.msi' { $Entry.IsDirect = $true; $Entry.DirectPath = $Local; $Entry.DirectArguments = $Arguments; $Entry.FilePath = "$Sys\msiexec.exe"; $Entry.ArgumentList = ('/i "{0}" {1}' -f $Local, $Arguments).TrimEnd() }
        '.ps1' { $Entry.FilePath = "$Sys\WindowsPowerShell\v1.0\powershell.exe"; $Entry.ArgumentList = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $Local, $Arguments).TrimEnd() }
        { $_ -in '.cmd', '.bat' } { $Entry.FilePath = "$Sys\cmd.exe"; $Entry.ArgumentList = ('/s /c ""{0}" {1}"' -f $Local, $Arguments).TrimEnd() }
        default { throw "Entry point type not supported: $([IO.Path]::GetExtension($Full)) (use .exe, .msi, .ps1, .cmd or .bat)." }
    }
    [pscustomobject]$Entry
}

function New-ConversionTemplate {
    # The MSIX Packaging Tool conversion template (XML) with paths as seen inside the sandbox
    param(
        [Parameter(Mandatory = $true)]$Recipe, [Parameter(Mandatory = $true)][string]$Publisher, [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$PackagePath, [string]$TemplatePath, [string]$InstallerArguments
    )
    $Namespace = 'http://schemas.microsoft.com/appx/msixpackagingtool/template/2018'
    $NamespaceV4 = 'http://schemas.microsoft.com/msix/msixpackagingtool/template/1910'
    $Xml = New-Object System.Xml.XmlDocument
    $Root = $Xml.CreateElement('MsixPackagingToolTemplate', $Namespace)
    $Root.SetAttribute('xmlns:V4', $NamespaceV4)
    [void]$Xml.AppendChild($Root)
    $Settings = $Xml.CreateElement('Settings', $Namespace)
    $Settings.SetAttribute('AllowTelemetry', 'false')
    $Settings.SetAttribute('ApplyAllPrepareComputerFixes', 'true')
    $Settings.SetAttribute('GenerateCommandLineFile', 'true')
    $Settings.SetAttribute('AllowPromptForPassword', 'false')
    $Settings.SetAttribute('EnforceMicrosoftStoreVersioningRequirements', 'false')
    [void]$Root.AppendChild($Settings)
    $Save = $Xml.CreateElement('SaveLocation', $Namespace)
    $Save.SetAttribute('PackagePath', $PackagePath)
    if ($TemplatePath) { $Save.SetAttribute('TemplatePath', $TemplatePath) }
    [void]$Root.AppendChild($Save)
    $Installer = $Xml.CreateElement('Installer', $Namespace)
    $Installer.SetAttribute('Path', $InstallerPath)
    if ($InstallerArguments) { $Installer.SetAttribute('Arguments', $InstallerArguments) }
    if ($Recipe.InstallLocation) { $Installer.SetAttribute('InstallLocation', $Recipe.InstallLocation) }
    [void]$Root.AppendChild($Installer)
    $Info = $Xml.CreateElement('PackageInformation', $Namespace)
    $Info.SetAttribute('PackageName', $Recipe.PackageName)
    $Info.SetAttribute('PackageDisplayName', $Recipe.DisplayName)
    $Info.SetAttribute('PublisherName', $Publisher)
    $Info.SetAttribute('PublisherDisplayName', $Recipe.PublisherDisplayName)
    $Info.SetAttribute('Version', (ConvertTo-PackTuneMsixVersion $Recipe.Version))
    [void]$Root.AppendChild($Info)
    # No XML declaration: a StringWriter would declare utf-16, the file is written as UTF-8
    $WriterSettings = New-Object System.Xml.XmlWriterSettings
    $WriterSettings.OmitXmlDeclaration = $true
    $WriterSettings.Indent = $true
    $Text = New-Object IO.StringWriter
    $Writer = [System.Xml.XmlWriter]::Create($Text, $WriterSettings)
    $Xml.Save($Writer)
    $Writer.Dispose()
    $Text.ToString()
}

function New-CaptureDocumentation {
    # A small report next to the package: identity, files, the sandbox logs. Returns the folder.
    param([Parameter(Mandatory = $true)][string]$PackagePath, [Parameter(Mandatory = $true)][string]$JobPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Encode = { param($Text) [System.Net.WebUtility]::HtmlEncode("$Text") }
    $Info = Get-PackTuneMsixInfo -Path $PackagePath
    $Folder = [IO.Path]::ChangeExtension($PackagePath, $null).TrimEnd('.') + '_documentation'
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $Zip = [IO.Compression.ZipFile]::OpenRead($Info.Path)
    try { $Files = @($Zip.Entries | Where-Object { $_.Name -and $_.FullName -notmatch '^(AppxMetadata/|AppxBlockMap|AppxSignature|\[Content_Types\])' } | ForEach-Object { '{0}  ({1:N0} bytes)' -f [uri]::UnescapeDataString($_.FullName), $_.Length }) }
    finally { $Zip.Dispose() }
    $Logs = foreach ($Name in 'conversion.log', 'restore.log', 'bootstrap.log') {
        $Log = Join-Path $JobPath "out\$Name"
        if (Test-Path -LiteralPath $Log) { "<h2>$Name</h2><pre>$(& $Encode (Get-Content -LiteralPath $Log -Raw -ErrorAction SilentlyContinue))</pre>" }
    }
    $Html = "<!doctype html><html><head><meta charset=`"utf-8`"><title>$(& $Encode $Info.DisplayName)</title></head><body><h1>$(& $Encode $Info.DisplayName) $(& $Encode $Info.Version)</h1>" +
        "<table><tr><td>Package name</td><td>$(& $Encode $Info.Name)</td></tr><tr><td>Publisher</td><td>$(& $Encode $Info.Publisher)</td></tr><tr><td>Version</td><td>$(& $Encode $Info.Version)</td></tr>" +
        "<tr><td>Signed</td><td>$($Info.IsSigned)</td></tr><tr><td>Created</td><td>$((Get-Date).ToString('s'))</td></tr></table><h2>Files in the package</h2><pre>$(& $Encode ($Files -join "`n"))</pre>$($Logs -join '')</body></html>"
    [IO.File]::WriteAllText((Join-Path $Folder 'index.html'), $Html, (New-Object Text.UTF8Encoding $false))
    $Folder
}

function Invoke-PackTuneMsixCapture {
    <#
        Captures an installation folder to an MSIX package in a fresh sandbox, unattended, and signs it on this computer.
        The whole folder is mapped read-only into the sandbox. EntryPoint (relative path in the folder) is an installer (.exe, .msi)
        started with -Arguments, or a script (.ps1, .cmd, .bat). With -BasePackage (update capture) the content of the previous
        MSIX is restored in the sandbox first, then the entry point runs; the identity comes from the base and the version is
        raised by one unless -Version is given. The package publisher is the subject of the certificate (-CertificateThumbprint,
        see New-PackTuneSigningCertificate); -SkipSigning with -Publisher leaves it unsigned.
        Returns State, Message, PackagePath, JobPath, Identity and Documentation (a folder).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$InstallerFolder, [Parameter(Mandatory = $true)][string]$EntryPoint, [string]$Arguments = '',
        [string]$PackageName, [string]$DisplayName, [string]$Version = '1.0.0.0', [string]$PublisherDisplayName, [string]$InstallLocation = '',
        [string]$BasePackage, [string]$Publisher, [string]$CertificateThumbprint, [switch]$SkipSigning, [switch]$AllowNoTimestamp, [int]$TimeoutMinutes,
        # The installer runs without network unless this is given for this capture (some setups download content)
        [switch]$AllowNetwork
    )
    if (-not $TimeoutMinutes) { $TimeoutMinutes = [int]$script:Options.JobTimeoutMinutes }
    $Entry = Get-EntryCommand -Folder $InstallerFolder -EntryPoint $EntryPoint -Arguments $Arguments -SandboxFolder "$script:SandboxLocal\input\installer"
    if ($CertificateThumbprint) {
        $Cert = Get-SigningCertificate -Thumbprint $CertificateThumbprint
        if ($Publisher -and $Publisher -ne $Cert.Subject) { throw "Publisher mismatch: -Publisher is '$Publisher', the certificate subject is '$($Cert.Subject)'." }
        $Publisher = $Cert.Subject
    }
    elseif (-not ($SkipSigning -and $Publisher)) { throw 'Give -CertificateThumbprint, or -SkipSigning with -Publisher.' }
    $Base = $null
    if ($BasePackage) {
        $Base = Get-PackTuneMsixInfo -Path $BasePackage
        if (-not $DisplayName) { $DisplayName = $Base.DisplayName }
        if (-not $PackageName) { $PackageName = $Base.Name }
        if (-not $PublisherDisplayName) { $PublisherDisplayName = $Base.PublisherDisplayName }
        if ($Version -eq '1.0.0.0') { $Version = Get-PackTuneNextMsixVersion -Version $Base.Version }
        if ($Base.Publisher -ne $Publisher) { Write-SandboxLog "The base package was published by '$($Base.Publisher)', the update gets '$Publisher'. Devices treat it as a different app." 'Warning' }
    }
    if (-not $PackageName) { throw 'PackageName is required (without -BasePackage).' }
    $PackageName = ConvertTo-PackTuneMsixPackageName $PackageName
    if (-not $DisplayName) { $DisplayName = $PackageName }
    if (-not $PublisherDisplayName) { $PublisherDisplayName = $DisplayName }
    $Version = ConvertTo-PackTuneMsixVersion $Version
    $null = Confirm-PackTuneToolchain

    $MsixName = '{0}_{1}.msix' -f $PackageName, $Version
    $Data = @{ AutoClose = $true; PackageName = $PackageName; Installer = $Entry.Relative; PackageFile = $MsixName; InputFolder = $true }
    if ($Base) { $Data.BasePackage = Split-Path $Base.Path -Leaf; $Data.BaseDisplayName = $Base.DisplayName; $Data.BaseVersion = $Base.Version }
    $Job = New-SandboxJob -Mode Package -Name $PackageName -Data $Data
    $Recipe = [pscustomobject]@{ PackageName = $PackageName; DisplayName = $DisplayName; PublisherDisplayName = $PublisherDisplayName; Version = $Version; InstallLocation = $InstallLocation }
    $TemplateArgs = @{ Recipe = $Recipe; Publisher = $Publisher; PackagePath = "$script:SandboxLocal\out\$MsixName"; TemplatePath = "$script:SandboxLocal\out\template.xml" }
    if ($Entry.IsDirect -and -not $Base) {
        $TemplateArgs.InstallerPath = $Entry.DirectPath
        $TemplateArgs.InstallerArguments = $Entry.DirectArguments
    }
    else {
        # A wrapper restores the base (update) and runs the entry point; the command goes into a file (it has its own quotes)
        [ordered]@{ FilePath = $Entry.FilePath; ArgumentList = $Entry.ArgumentList; WorkingDirectory = $Entry.WorkingDirectory; TimeoutMinutes = $TimeoutMinutes } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Job 'input\entry.json') -Encoding UTF8
        $WrapperArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script:SandboxRoot\Tools\UpdateCapture.ps1`" -EntryFile `"$script:SandboxLocal\input\entry.json`""
        if ($Base) {
            New-Item -ItemType Directory (Join-Path $Job 'input\base') -Force | Out-Null
            Copy-Item -LiteralPath $Base.Path -Destination (Join-Path $Job 'input\base')
            $Root = if ($InstallLocation) { $InstallLocation } else { "C:\Program Files\$PackageName" }
            $WrapperArgs += " -Restore `"$script:SandboxLocal\input\base\$($Data.BasePackage)`" -InstallRoot `"$Root`""
        }
        $TemplateArgs.InstallerPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $TemplateArgs.InstallerArguments = $WrapperArgs
    }
    [IO.File]::WriteAllText((Join-Path $Job 'template.xml'), (New-ConversionTemplate @TemplateArgs), (New-Object Text.UTF8Encoding $false))

    $What = if ($Base) { "update of $($Base.DisplayName) $($Base.Version) to $Version" } else { "$DisplayName $Version" }
    Write-SandboxLog "Capturing $What from the folder (entry point $($Entry.Relative)) in a fresh sandbox ..."
    $Wsb = New-SandboxConfig -JobPath $Job -Networking ([bool]$AllowNetwork) -InputFolder (Resolve-Path -LiteralPath $InstallerFolder).ProviderPath
    Start-SandboxProcess -WsbPath $Wsb
    $Status = Wait-SandboxJob -JobPath $Job -TimeoutMinutes $TimeoutMinutes
    Complete-SandboxJob

    $Raw = Join-Path $Job "out\$MsixName"
    if ($Status.State -ne 'Succeeded' -or -not (Test-Path -LiteralPath $Raw)) {
        Write-SandboxLog "The capture failed: $($Status.Message) (logs: $Job)" 'Error'
        return [pscustomobject]@{ State = 'Failed'; Message = $Status.Message; PackagePath = $null; JobPath = $Job; Identity = $null; Documentation = $null }
    }
    $Target = Join-Path (Get-PackTuneSandboxWorkspace).Output $MsixName
    Copy-Item -LiteralPath $Raw -Destination $Target -Force
    if (-not $SkipSigning) { $null = Invoke-PackTuneSigning -Path $Target -CertificateThumbprint $CertificateThumbprint -AllowNoTimestamp:$AllowNoTimestamp }
    if (-not (Get-PackTuneMsixInfo -Path $Target).Applications) {
        Write-SandboxLog 'The package has no app entry: nothing creates a Start menu shortcut on devices (the software itself is installed).' 'Warning'
    }
    $Documentation = $null
    try { $Documentation = New-CaptureDocumentation -PackagePath $Target -JobPath $Job }
    catch { Write-SandboxLog "The documentation could not be written: $($_.Exception.Message)" 'Warning' }
    Write-SandboxLog "Package ready: $Target" 'Success'
    [pscustomobject]@{ State = 'Succeeded'; Message = $Status.Message; PackagePath = $Target; JobPath = $Job; Identity = (Get-PackTuneMsixIdentity -Path $Target); Documentation = $Documentation }
}

#endregion

#region Win32 test lab

function Get-PackTuneLabRuntimeStep {
    # The step "Dependency: PackTune Runtime" of the lab: the install.ps1 of the runtime app as Intune runs it (SYSTEM, 64-bit PowerShell), then its
    # detection script; the step passes when the install gives a success code and the detection says detected. It only sequences the two real scripts.
    return @'
# Lab step: install the PackTune Runtime like Intune (install.ps1 as SYSTEM), then run its detection rule. Every part prints a timed line, the
# detection is bounded (3 minutes) and says what is busy while it runs: the row never stays "running" without a word.
$ErrorActionPreference = 'Continue'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Write-LabLine([string]$Text) { Write-Output ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text) }
& $PowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1')
$Code = $LASTEXITCODE
Write-LabLine "PackTune Runtime install.ps1 exit code $Code"
if ($Code -notin 0, 1707, 3010, 1641) { exit $Code }
Write-LabLine 'Detecting the PackTune Runtime (its detection script) ...'
$Started = Get-Date
$OutFile = Join-Path $env:TEMP 'packtune-runtime-detect.txt'
$Process = Start-Process -FilePath $PowerShell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Detect.ps1') -PassThru -NoNewWindow -RedirectStandardOutput $OutFile
$null = $Process.Handle   # keeps the exit code readable after the wait (Start-Process -PassThru quirk)
while (-not $Process.WaitForExit(10000)) {
    $Seconds = [int]((Get-Date) - $Started).TotalSeconds
    $Busy = (@(Get-Process | Sort-Object CPU -Descending | Select-Object -First 3 | ForEach-Object { $_.ProcessName }) -join ', ')
    Write-LabLine "Detection still running ($Seconds s); busiest processes: $Busy"
    if ($Seconds -ge 180) { try { $Process.Kill() } catch { }; Write-LabLine 'PackTune Runtime detection: timed out after 3 minutes'; exit 1 }
}
$Process.WaitForExit()
$Detected = $Process.ExitCode
$Out = if (Test-Path -LiteralPath $OutFile) { (Get-Content -LiteralPath $OutFile -Raw) } else { '' }
Write-LabLine "Detection finished after $([int]((Get-Date) - $Started).TotalSeconds) s"
if ($Detected -ne 0 -or -not ([string]$Out).Trim()) { Write-LabLine "PackTune Runtime detection: not detected (exit code $Detected)"; exit 1 }
Write-LabLine "PackTune Runtime detection: $(([string]$Out).Trim())"
exit 0
'@
}

function Start-PackTuneWin32Lab {
    <#
        Opens the test lab in a fresh sandbox and plays the package through the paths Intune takes, as SYSTEM like the Intune
        Management Extension: detect before the install (expected: not detected; a detected app would not be installed), install,
        detect, and with a previous version (-PreviousScripts, -PreviousSourcePath) first that one in and detected, then the update
        and its detection, then uninstall and detect (expected: not detected). Every step shows exit code, duration, expected and
        actual. -Scripts holds Install.ps1, Uninstall.ps1 and Detect.ps1 (the commands the lab runs), -SourcePath a folder with the
        other package files; both end up in one folder in the sandbox. You run the steps there, or the lab runs them all with
        -AutoRun in order and stops at the first unexpected result. Returns Verdict (Passed, or Failed at step N with the cause),
        Message, Result and JobPath.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName, [string]$Version = '', [Parameter(Mandatory = $true)][hashtable]$Scripts,
        [string]$SourcePath, [hashtable]$PreviousScripts, [string]$PreviousSourcePath, [string]$PreviousVersion = '',
        # The dependency app (PackTune Runtime): its install.ps1 (and the other package files) in -RuntimeSourcePath, its detection as -RuntimeDetection.
        # The lab installs it first, as its own step, exactly like Intune does before the app; when it fails nothing else runs.
        [string]$RuntimeSourcePath, [string]$RuntimeDetection,
        [switch]$AutoRun, [Nullable[bool]]$Networking, [int]$TimeoutMinutes
    )
    foreach ($Required in 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1') { if (-not $Scripts.ContainsKey($Required)) { throw "The lab needs the script $Required." } }
    $HasPrevious = [bool]$PreviousScripts
    if ($HasPrevious) { foreach ($Required in 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1') { if (-not $PreviousScripts.ContainsKey($Required)) { throw "The previous version needs the script $Required." } } }
    if (-not $TimeoutMinutes) { $TimeoutMinutes = if ($AutoRun) { [int]$script:Options.JobTimeoutMinutes } else { 480 } }
    if ($null -eq $Networking) { $Networking = [bool]$script:Options.Networking }
    $HasRuntime = [bool]$RuntimeSourcePath
    if ($HasRuntime -and -not ($RuntimeDetection -and (Test-Path -LiteralPath (Join-Path $RuntimeSourcePath 'install.ps1')))) { throw 'The runtime step needs install.ps1 in the runtime folder and its detection script.' }
    Write-SandboxLog 'Step 1 of 4: preparing the test (creating the sandbox files).'
    $Job = New-SandboxJob -Mode Lab -Name $DisplayName -Data @{ AutoClose = $false; AutoRun = [bool]$AutoRun; DisplayName = $DisplayName; Version = $Version; HasPrevious = $HasPrevious; PreviousVersion = $PreviousVersion; HasRuntime = $HasRuntime }
    $Source = Join-Path $Job 'input\source'
    New-Item -ItemType Directory -Path $Source -Force | Out-Null
    if ($SourcePath) { Copy-Item -Path (Join-Path $SourcePath '*') -Destination $Source -Recurse -Force }
    foreach ($Name in $Scripts.Keys) { Set-Content -Path (Join-Path $Source $Name) -Value $Scripts[$Name] -Encoding UTF8 }
    if ($HasRuntime) {
        $Runtime = Join-Path $Job 'input\source-runtime'
        New-Item -ItemType Directory -Path $Runtime -Force | Out-Null
        Copy-Item -Path (Join-Path $RuntimeSourcePath '*') -Destination $Runtime -Recurse -Force
        Set-Content -Path (Join-Path $Runtime 'Detect.ps1') -Value $RuntimeDetection -Encoding UTF8
        Set-Content -Path (Join-Path $Runtime 'Runtime.ps1') -Value (Get-PackTuneLabRuntimeStep) -Encoding UTF8
    }
    if ($HasPrevious) {
        $Previous = Join-Path $Job 'input\source-previous'
        New-Item -ItemType Directory -Path $Previous -Force | Out-Null
        if ($PreviousSourcePath) { Copy-Item -Path (Join-Path $PreviousSourcePath '*') -Destination $Previous -Recurse -Force }
        foreach ($Name in $PreviousScripts.Keys) { Set-Content -Path (Join-Path $Previous $Name) -Value $PreviousScripts[$Name] -Encoding UTF8 }
    }
    Write-SandboxLog "Opening the test lab in Windows Sandbox for $DisplayName$(if ($Version) { " $Version" }): $(if ($HasRuntime) { 'dependency (PackTune Runtime), ' })detect, install$(if ($HasPrevious) { ' (previous version, then the update)' }), detect, uninstall, detect$(if (-not $AutoRun) { ', then report the result there' })."
    $Wsb = New-SandboxConfig -JobPath $Job -Networking ([bool]$Networking) -NoToolchain
    Write-SandboxLog 'Step 2 of 4: starting Windows Sandbox (the window opens in a moment).'
    Start-SandboxProcess -WsbPath $Wsb
    Write-SandboxLog "Step 3 of 4: $(if ($AutoRun) { 'installing as SYSTEM, detecting and uninstalling in the sandbox' } else { 'waiting for your result in the sandbox window (Install, Detect, Uninstall run there as SYSTEM)' })"
    $Status = Wait-SandboxJob -JobPath $Job -TimeoutMinutes $TimeoutMinutes
    Write-SandboxLog 'Step 4 of 4: result received.'
    Complete-SandboxJob
    $Verdict = if ($Status.State -eq 'Succeeded') { 'Passed' } else { 'Failed' }
    Write-SandboxLog "Test lab result: $Verdict. $($Status.Message)" $(if ($Verdict -eq 'Passed') { 'Success' } else { 'Error' })
    [pscustomobject]@{ State = $Status.State; Verdict = $Verdict; Message = $Status.Message; Result = $Status.Result; JobPath = $Job }
}

#endregion

Export-ModuleMember -Function Get-PackTuneLabRuntimeStep, Set-PackTuneSandboxLog, Set-PackTuneSandboxOption, Set-PackTuneSandboxLauncher, Get-PackTuneSandboxWorkspace, Test-PackTuneSandboxAvailable, Test-PackTuneSandboxRunning, Wait-PackTuneSandboxClosed,
    ConvertTo-PackTuneMsixVersion, ConvertTo-PackTuneMsixPackageName, Get-PackTuneNextMsixVersion,
    Get-PackTuneToolchain, Get-PackTuneToolchainState, Update-PackTuneToolchain,
    Get-PackTuneMsixInfo, Get-PackTuneMsixIdentity, New-PackTuneSigningCertificate, Remove-PackTuneSigningCertificate, Invoke-PackTuneSigning,
    Invoke-PackTuneMsixCapture, Start-PackTuneWin32Lab, Expand-PackTuneZip
