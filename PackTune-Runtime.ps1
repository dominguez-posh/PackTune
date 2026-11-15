<#
    PackTune Runtime: the ONE dependency app of every app this tool deploys (Chocolatey and winget, AutoInstall).

    Its install script bootstraps Chocolatey (retry for the rate limit, download URL setting) and makes winget usable
    as SYSTEM (App Installer with its dependencies, Microsoft signature and root pinned), and registers one daily
    SYSTEM task that updates both. Detection: choco.exe and winget work, and the marker of the script revision is
    there; there is no time limit. Uninstall removes only the task and the marker of this tool, never Chocolatey or
    App Installer.

    Older tenants have two dependency apps instead: "Chocolatey" (marker FiredWithPowershell) and "winget runtime"
    (marker WingetRuntimeApp). They are recognized as old dependencies; Switch-PackTuneAppsToRuntime moves the
    apps of the tool over, Get-PackTuneUnusedDependencyApps lists the old ones nothing depends on any more (nothing
    is deleted automatically). Loaded by PackTune-Main.ps1.
#>

$script:RuntimeName = "PackTune Runtime"
$script:RuntimeMarker = "PackTuneRuntimeApp"
$script:OldWingetRuntimeName = "winget runtime"
$script:OldWingetRuntimeMarker = "WingetRuntimeApp"
# Raised when the install, update or detection script of the runtime app changes (part of its detection)
$script:RuntimeRevision = 6
# One line per revision: what changes on the devices (shown with "Update available"); add a line when the revision is raised
$script:RuntimeChanges = @{ 5 = "Tray agent for update notifications on the devices (one per user session); the logon task runs in parallel on multi-session hosts."
    6 = "Faster App Installer download (no progress bar slowing it down) and a log that shows every sub-step with its time." }

#region scripts

function Get-PackTuneRuntimeScripts {
    # Install, update and detection script of the runtime app (plain ASCII, Windows PowerShell 5.1, runs as SYSTEM)
    $GetWinget = @'
function Get-Winget {
    # winget.exe is not in the path of SYSTEM: take the newest App Installer for this processor. Only from the
    # WindowsApps folder (TrustedInstaller); never from PATH, where a user could have put another winget.exe.
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $Apps = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) "WindowsApps"
    $Folders = @(Get-ChildItem -Path $Apps -Filter "Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "winget.exe") })
    $Preferred = @($Folders | Where-Object { $_.Name -like "*_$($Arch)__*" })
    if ($Preferred.Count -gt 0) { $Folders = $Preferred }
    $Newest = $Folders | Sort-Object { try { [version](($_.Name -split "_")[1]) } catch { [version]"0.0" } } -Descending | Select-Object -First 1
    if ($Newest) { return Join-Path $Newest.FullName "winget.exe" }
    return $null
}
'@

    $Install = @'
# PackTune Runtime: makes Chocolatey and winget usable for SYSTEM and keeps both up to date with one daily task
# (runs as SYSTEM through Intune).
param([switch]$Uninstall)

# The Intune Management Extension starts 32-bit PowerShell; the App Installer lives in the 64-bit WindowsApps folder
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Uninstall) { $Arguments += "-Uninstall" }
    & "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    exit $LASTEXITCODE
}

$Revision = '__REVISION__'
$LogId = "_packtune-runtime"
$LogTag = if ($Uninstall) { "uninstall" } else { "install" }
# Windows PowerShell 5.1 draws a progress bar for Invoke-WebRequest and Expand-Archive that slows a download of 100 MB down by a factor of 10 or
# more: off. Every sub-step prints one line with the time (the lab and the log show what the script is doing and how long each part took).
$ProgressPreference = "SilentlyContinue"
$Clock = [Diagnostics.Stopwatch]::StartNew()
# lab.flag only exists in the sandbox test lab (put there by the lab): the random waits between download attempts are short there, the logic is the same
$InLab = Test-Path -LiteralPath "$PSScriptRoot\lab.flag"
function Write-Step([string]$Text) { Write-Output ("[{0:HH:mm:ss} +{1}s] {2}" -f (Get-Date), [int]$Clock.Elapsed.TotalSeconds, $Text) }
function Save-Download([string]$Url, [string]$Path) {
    # A download with its progress in the output: file name, size and percent every few seconds (Invoke-WebRequest says nothing until it is done)
    $Name = Split-Path -Path $Path -Leaf
    $Started = Get-Date
    $Request = [Net.HttpWebRequest]::Create($Url)
    $Request.UserAgent = "PackTune"; $Request.Timeout = 60000; $Request.ReadWriteTimeout = 60000
    if ($Request.Proxy) { $Request.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials }
    $Response = $Request.GetResponse()
    $In = $null; $Out = $null
    try {
        $Total = [int64]$Response.ContentLength
        $In = $Response.GetResponseStream(); $Out = [IO.File]::Create($Path)
        $Buffer = New-Object byte[] 1048576
        $Done = [int64]0; $Last = Get-Date
        Write-Step ("{0}: download starts{1}" -f $Name, $(if ($Total -gt 0) { " ({0:N1} MB)" -f ($Total / 1MB) } else { "" }))
        while (($Read = $In.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $Out.Write($Buffer, 0, $Read); $Done += $Read
            if (((Get-Date) - $Last).TotalSeconds -ge 5) {
                $Last = Get-Date
                Write-Step ("{0}: {1:N1} MB{2}" -f $Name, ($Done / 1MB), $(if ($Total -gt 0) { " of {0:N1} MB ({1}%)" -f ($Total / 1MB), [int](100 * $Done / $Total) } else { "" }))
            }
        }
    }
    finally { if ($Out) { $Out.Dispose() }; if ($In) { $In.Dispose() }; $Response.Close() }
    Write-Step ("{0}: downloaded {1:N1} MB in {2} s" -f $Name, ((Get-Item -LiteralPath $Path).Length / 1MB), [int]((Get-Date) - $Started).TotalSeconds)
}

__COMMON__

# %ProgramFiles%\PackTune\Runtime (see $ToolRoot); the folder of the earlier name is removed below
$RuntimeRoot = Join-Path $ToolRoot "Runtime"
$TaskPath = "\PackTune\Runtime\"
$OldTaskPath = "\Intune-Winget-Updates\"   # before the rename
$TaskName = "Update PackTune Runtime"
$TrayTaskName = "PackTune Updates tray"
# The task of the earlier "winget runtime" app does the same job: replaced by this one
$OldTaskName = "Update winget runtime"

# The folders hold what runs as SYSTEM: users must not be able to write there
try {
    Protect-Folder $ToolRoot
    Protect-Folder $RuntimeRoot
    Protect-Folder (Join-Path $RuntimeRoot "Logs")
}
catch { Write-Output "The folder $RuntimeRoot could not be protected: $($_.Exception.Message)"; exit $PTExit.FolderProtect }
Start-Transcript -Path (Join-Path $RuntimeRoot "Logs\runtime.log") -Append | Out-Null

__GETWINGET__

if ($Uninstall) {
    # Chocolatey and App Installer belong to the device: only the task and the marker of this tool go (detection fails again)
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TrayTaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $OldTaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Remove-OldTaskFolder $OldTaskPath
    Remove-OldToolFolder "Runtime"
    Remove-Item -LiteralPath (Join-Path $RuntimeRoot "ready.txt") -Force -ErrorAction SilentlyContinue
    Write-DeviceLog "uninstalled: task and marker removed, Chocolatey and App Installer stay"
    Write-Output "Chocolatey and winget stay installed"
    Stop-Transcript | Out-Null
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

### Part 1: Chocolatey. The community repository allows only a few downloads per minute and IP: retry with a random
### wait, the device lock is held per attempt only (not while waiting)
$Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
$DownloadUrl = '__DOWNLOADURL__'
Write-Step "Chocolatey: $(if (Test-Path -LiteralPath $Choco) { 'is there already' } else { 'not there, installing it' })"
if (-not (Test-Path -LiteralPath $Choco)) {
    if ($DownloadUrl) { $env:chocolateyDownloadUrl = $DownloadUrl }
    for ($Attempt = 1; $Attempt -le 4 -and -not (Test-Path -LiteralPath $Choco); $Attempt++) {
        Write-Step "Chocolatey: download and install, attempt $Attempt of 4"
        if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; Stop-Transcript | Out-Null; exit (Get-LockExitCode) }
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        }
        catch { Write-Output "Chocolatey attempt $Attempt failed: $($_.Exception.Message)" }
        finally { Exit-DeploymentLock }
        if (-not (Test-Path -LiteralPath $Choco) -and $Attempt -lt 4) {
            $Pause = if ($InLab) { 5 } else { Get-Random -Minimum 60 -Maximum 300 }
            Write-Step "Chocolatey: attempt $Attempt did not work (the community repository allows only a few downloads per minute), waiting $Pause s$(if ($InLab) { ' (short in the lab)' })"
            Start-Sleep -Seconds $Pause
        }
    }
}
if (-not (Test-Path -LiteralPath $Choco)) { Write-Output "Chocolatey installation failed"; Write-DeviceLog "Chocolatey installation failed"; Stop-Transcript | Out-Null; exit $PTExit.ChocoMissing }
Write-Step "Chocolatey: checking that it runs"
& $Choco --version | Out-Host
if ($LASTEXITCODE -ne 0) { Write-Output "choco.exe does not run (exit code $LASTEXITCODE)"; Write-DeviceLog "choco.exe does not run"; Stop-Transcript | Out-Null; exit $PTExit.RuntimeBroken }

### Part 2: winget (App Installer) for SYSTEM
Write-Step "App Installer (winget): looking at the device"
if (-not (Enter-DeploymentLock)) { Write-Output "Another choco or winget installation is still running"; Stop-Transcript | Out-Null; exit (Get-LockExitCode) }
try {
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    $Release = "https://github.com/microsoft/winget-cli/releases/latest/download"

    # Only packages signed by Microsoft are provisioned: the download is pinned to Microsoft's signature, not only to TLS
    $MicrosoftPublisher = "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
    # Microsoft Root Certificate Authority 2011
    $MicrosoftRoots = @("8F43288AD272F3103B6FB1428485EA3014C0BCFE")
    function Assert-MicrosoftSigned([string]$Path) {
        $Signature = Get-AuthenticodeSignature -LiteralPath $Path
        $Signer = if ($Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Subject } else { "" }
        if ([string]$Signature.Status -ne "Valid" -or $Signer -ne $MicrosoftPublisher) {
            throw "$(Split-Path -Path $Path -Leaf) is not validly signed by Microsoft (status $($Signature.Status), signer '$Signer'); nothing is installed"
        }
        # The chain must end in Microsoft's own root, not in a CA the enterprise trusts (TLS inspection could issue a
        # certificate with the Microsoft subject). Bundle and dependency packages all chain to this root (checked).
        $Chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        [void]$Chain.Build($Signature.SignerCertificate)
        $ChainRoot = if ($Chain.ChainElements.Count -gt 0) { [string]$Chain.ChainElements[$Chain.ChainElements.Count - 1].Certificate.Thumbprint } else { "" }
        if ($ChainRoot -notin $MicrosoftRoots) {
            throw "$(Split-Path -Path $Path -Leaf) does not chain to the Microsoft root (root '$ChainRoot'); nothing is installed"
        }
    }

    function Install-AppInstaller {
        # Provisions App Installer for all users with its dependencies, after checking their Microsoft signatures
        $Work = Join-Path $RuntimeRoot "download"
        if (Test-Path -LiteralPath $Work) { Remove-ItemSafely $Work }
        Protect-Folder $Work
        $Bundle = Join-Path $Work "AppInstaller.msixbundle"
        $Zip = Join-Path $Work "dependencies.zip"
        Write-Step "App Installer: downloading the bundle from $Release"
        Save-Download "$Release/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" $Bundle
        Write-Step "App Installer: downloading the dependencies"
        Save-Download "$Release/DesktopAppInstaller_Dependencies.zip" $Zip
        Write-Step "App Installer: unpacking the dependencies"
        Expand-Archive -LiteralPath $Zip -DestinationPath (Join-Path $Work "dependencies") -Force
        $Dependencies = @(Get-ChildItem -Path (Join-Path $Work "dependencies\$Arch") -Filter "*.appx" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        Write-Step "App Installer: checking the Microsoft signature of $(1 + $Dependencies.Count) files"
        foreach ($File in @($Bundle) + $Dependencies) { Assert-MicrosoftSigned $File }
        Write-Step "App Installer: provisioning it for all users with $($Dependencies.Count) dependencies"
        if ($Dependencies.Count -gt 0) { Add-AppxProvisionedPackage -Online -PackagePath $Bundle -DependencyPackagePath $Dependencies -SkipLicense | Out-Null }
        else { Add-AppxProvisionedPackage -Online -PackagePath $Bundle -SkipLicense | Out-Null }
        Remove-ItemSafely $Work
        Write-Step "App Installer: provisioned"
    }

    function Install-VcRedist {
        # winget.exe for SYSTEM needs the Visual C++ runtime in System32 (the packaged VCLibs are only visible to packaged apps): a device
        # that has none ("winget does not start", exit code 0xC0000135 = a DLL is missing) gets Microsoft's redistributable, signature checked
        $Work = Join-Path $RuntimeRoot "download-vc"
        if (Test-Path -LiteralPath $Work) { Remove-ItemSafely $Work }
        Protect-Folder $Work
        $Installer = Join-Path $Work $(if ($Arch -eq "arm64") { "vc_redist.arm64.exe" } else { "vc_redist.x64.exe" })
        Write-Step "Visual C++ runtime: downloading it from Microsoft (aka.ms/vs/17/release)"
        Save-Download "https://aka.ms/vs/17/release/$(Split-Path -Path $Installer -Leaf)" $Installer
        Write-Step "Visual C++ runtime: checking the Microsoft signature"
        Assert-MicrosoftSigned $Installer
        Write-Step "Visual C++ runtime: installing it silently (up to 10 minutes)"
        $Process = Start-Process -FilePath $Installer -ArgumentList "/install", "/quiet", "/norestart" -PassThru
        if (-not $Process.WaitForExit(600000)) { try { $Process.Kill() } catch { }; Write-Step "Visual C++ runtime: the installer did not finish in 10 minutes and was stopped" }
        else { Write-Step "Visual C++ runtime: installer exit code $($Process.ExitCode) after $([int]((Get-Date) - $Process.StartTime).TotalSeconds) s" }
        Remove-ItemSafely $Work
    }

    $Winget = Get-Winget
    if (-not $Winget) {
        Write-Step "App Installer not found, installing it"
        try { Install-AppInstaller } catch { Write-Step "App Installer could not be provisioned: $($_.Exception.Message)" }
        # Registered for the system context as well (no error when it already is)
        Write-Step "App Installer: registering it for the system context"
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction Stop }
        catch {
            $Reason = $_.Exception.Message
            Write-Step "Registration: $(($Reason -split "`r?`n")[0])"
            # The cause behind "Deployment operation failed": the log of the deployment (its ActivityId is in the message)
            if ($Reason -match "ActivityId\]?\s+([0-9a-fA-F-]{36})") {
                try { Get-AppPackageLog -ActivityID $Matches[1] -ErrorAction Stop | Where-Object { $_.Message } | Select-Object -First 4 | ForEach-Object { Write-Step ("  deployment log: " + (([string]$_.Message -replace "\s+", " ").Trim())) } }
                catch { Write-Step "  deployment log not available: $($_.Exception.Message)" }
            }
        }
        for ($Wait = 0; -not $Winget -and $Wait -lt 12; $Wait++) { Write-Step "App Installer: waiting for winget.exe to appear ($($Wait + 1) of 12, 10 s each)"; Start-Sleep -Seconds 10; $Winget = Get-Winget }
    }
    if (-not $Winget) { Write-Output "winget.exe not found (App Installer is missing)"; Write-DeviceLog "winget.exe not found"; Stop-Transcript | Out-Null; exit $PTExit.WingetMissing }
    Write-Step "Using $Winget"

    # winget must start for SYSTEM; if not, dependencies are missing
    Write-Step "winget: checking that it starts for SYSTEM"
    & $Winget --version | Out-Host
    if ($LASTEXITCODE -eq -1073741515) {
        Write-Step "winget does not start (exit code ${LASTEXITCODE}: a DLL is missing, the Visual C++ runtime)"
        try { Install-VcRedist } catch { Write-Step "Visual C++ runtime could not be installed: $($_.Exception.Message)" }
        Write-Step "winget: checking that it starts for SYSTEM"
        & $Winget --version | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Step "winget does not start (exit code $LASTEXITCODE), installing App Installer and its dependencies again"
        try { Install-AppInstaller } catch { Write-Step "App Installer could not be provisioned: $($_.Exception.Message)" }
        $Winget = Get-Winget
        Write-Step "winget: checking that it starts for SYSTEM"
        & $Winget --version | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Output "winget still does not start"; Write-DeviceLog "winget does not start"; Stop-Transcript | Out-Null; exit $PTExit.RuntimeBroken }
    }
}
finally { Exit-DeploymentLock }

### One daily task updates Chocolatey and App Installer (SYSTEM); detection does not depend on it
Write-Step "Tasks: registering the daily update and the tray agent"
try {
    Remove-Item -LiteralPath (Join-Path $RuntimeRoot "update.ps1") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "update.ps1") -Destination $RuntimeRoot -Force -ErrorAction Stop
    # The tray agent "PackTune Updates" (one per user session: the task runs in parallel for every user who signs in, e.g. on multi-session hosts; the agent's own Local\ mutex keeps it to one per session): a script in the protected folder (users read it, they cannot change it), started by a task of the Users group at every logon
    Remove-Item -LiteralPath (Join-Path $RuntimeRoot "tray.ps1") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "tray.ps1") -Destination $RuntimeRoot -Force -ErrorAction Stop
    $TrayPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $TrayAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless `"$TrayPowerShell`" -STA -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $RuntimeRoot 'tray.ps1')`""
    $TrayUsers = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
    $TraySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    Register-ScheduledTask -TaskName $TrayTaskName -TaskPath $TaskPath -Action $TrayAction -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $TrayUsers -Settings $TraySettings -Force -ErrorAction Stop | Out-Null
    foreach ($Name in $OldTaskName, $TaskName) { Unregister-ScheduledTask -TaskName $Name -TaskPath $OldTaskPath -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-OldTaskFolder $OldTaskPath
    $PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $Action = New-ScheduledTaskAction -Execute $PowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $RuntimeRoot 'update.ps1')`""
    $Triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(10).AddMinutes((Get-Random -Maximum 300)))))
    $System = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Triggers -Principal $System -Settings $Settings -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Output "The update task could not be registered: $($_.Exception.Message)"
    Write-DeviceLog "update task could not be registered: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit $PTExit.TaskRegister
}
# The folder of the earlier name (%ProgramFiles%\IntuneChocoDeployment\Runtime) is not needed any more
Remove-OldToolFolder "Runtime"
Remove-OldToolFolder "Winget\Runtime"
# The marker of this script version for the detection rule
Write-ProtectedFile (Join-Path $RuntimeRoot "ready.txt") $Revision
Write-DeviceLog "PackTune Runtime ready: choco $Choco, winget $Winget"
Write-Step "PackTune Runtime is ready (total $([int]$Clock.Elapsed.TotalSeconds) s)"
Stop-Transcript | Out-Null
exit 0
'@

    $Detection = @'
# choco.exe and winget work as SYSTEM and this script version has been installed (updates are a scheduled task)
$Revision = '__REVISION__'
$Marker = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) "PackTune\Runtime\ready.txt"
__GETWINGET__
if (-not (Test-Path -LiteralPath $Marker) -or (Get-Content -LiteralPath $Marker -Raw).Trim() -ne $Revision) { exit 1 }
$Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $Choco)) { exit 1 }
& $Choco --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
$Winget = Get-Winget
if (-not $Winget) { exit 1 }
& $Winget --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Output "PackTune Runtime is ready: $Choco, $Winget"
exit 0
'@

    $UpdateScript = @'
# Daily update of Chocolatey and App Installer (scheduled task, SYSTEM), at most every 20 hours, inside the device
# wide lock. Log: Intune Management Extension log folder (PackTune-_packtune-runtime.log).
$RuntimeRoot = $PSScriptRoot
$LogId = "_packtune-runtime"
$LogTag = "update"
$PackageSource = '__PACKAGESOURCE__'

__COMMON__

__GETWINGET__

try { if (Test-ForeignItem $RuntimeRoot) { Write-DeviceLog "folder is not protected, nothing done"; exit 1 } } catch { exit 1 }
$Stamp = Join-Path $RuntimeRoot "checked.txt"
if (Test-Path -LiteralPath $Stamp) {
    try {
        $Last = [datetime]::Parse((Get-Content -LiteralPath $Stamp -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if (([datetime]::UtcNow - $Last.ToUniversalTime()).TotalHours -lt 20) { Write-DeviceLog "checked less than 20 hours ago"; exit 0 }
    }
    catch { }
}
if (-not (Enter-DeploymentLock)) { Write-DeviceLog "another installation is still running, next run tries again"; exit 1618 }
$Failed = $false
try {
    $Choco = Join-Path $env:ProgramData "chocolatey\bin\choco.exe"
    if (Test-Path -LiteralPath $Choco) {
        $Arguments = @("upgrade", "chocolatey", "-y", "--no-progress", "--limit-output")
        if ($PackageSource) { $Arguments += @("--source", $PackageSource) }
        & $Choco @Arguments | Out-Null
        Write-DeviceLog "Chocolatey upgrade exit code $LASTEXITCODE"
        if ($LASTEXITCODE -notin 0, 1641, 3010) { $Failed = $true }
    }
    else { Write-DeviceLog "choco.exe not found"; $Failed = $true }

    $Winget = Get-Winget
    if ($Winget) {
        & $Winget upgrade --id Microsoft.AppInstaller --exact --source winget --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
        # No newer version is not an error
        Write-DeviceLog "App Installer upgrade exit code $LASTEXITCODE"
        if ($LASTEXITCODE -notin 0, -1978335189, -1978335135) { $Failed = $true }
    }
    else { Write-DeviceLog "winget.exe not found"; $Failed = $true }
    # The next run tries again after a failure
    if (-not $Failed) { Write-ProtectedFile $Stamp ([datetime]::UtcNow.ToString("o")) }
}
finally { Exit-DeploymentLock }
exit 0
'@

    $Revision = [string]$script:RuntimeRevision
    $Common = Get-DeviceScriptCommon
    $Quote = { param($Text) ([string]$Text -replace '[^\x20-\x7E]', '').Replace("'", "''") }
    return [pscustomobject]@{
        Install   = $Install.Replace("__COMMON__", $Common).Replace("__GETWINGET__", $GetWinget).Replace("__REVISION__", $Revision).Replace("__DOWNLOADURL__", (& $Quote $script:Settings.ChocolateyDownloadUrl))
        Detection = $Detection.Replace("__GETWINGET__", $GetWinget).Replace("__REVISION__", $Revision)
        Tray      = Get-UpdateTrayScript
        Update    = $UpdateScript.Replace("__COMMON__", $Common).Replace("__GETWINGET__", $GetWinget).Replace("__PACKAGESOURCE__", (& $Quote $script:Settings.PackageSource))
    }
}#Scripts of the PackTune Runtime app

#endregion

#region the app in the tenant

function Get-PackTuneRuntimeNotes {
    # The marker of the runtime app plus the revision of its scripts: the tool compares it with its own revision (apps without it count as older)
    "$($script:RuntimeMarker);runtimeRevision=$($script:RuntimeRevision)"
}
function Get-PackTuneRuntimeRevision([string]$Notes) {
    if ($Notes -match 'runtimeRevision=(\d+)') { return [int]$Matches[1] }
    return 0
}
function Write-PackTuneRuntimeFiles {
    # The content of the runtime app (install, update and tray script in <WorkPath>\source, the detection with the revision next to it): the one
    # source of the Intune package and of the sandbox test lab, so the lab runs exactly what goes to Intune. Returns the detection file.
    param([Parameter(Mandatory = $true)][string]$WorkPath)
    $SourcePath = Join-Path $WorkPath "source"
    $Scripts = Get-PackTuneRuntimeScripts
    Set-Content -Path (Join-Path $SourcePath "install.ps1") -Value $Scripts.Install -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "update.ps1") -Value $Scripts.Update -Encoding ASCII
    Set-Content -Path (Join-Path $SourcePath "tray.ps1") -Value $Scripts.Tray -Encoding ASCII
    $DetectionFile = Join-Path $WorkPath "detection.ps1"
    Set-Content -Path $DetectionFile -Value $Scripts.Detection -Encoding ASCII
    return $DetectionFile
}
function New-PackTuneRuntimePackage {
    # The package of the runtime app (install, update and tray script, detection with the revision): for the creation and the update
    $WorkPath = New-PackTuneWorkFolder -Name "_packtune-runtime"
    $DetectionFile = Write-PackTuneRuntimeFiles -WorkPath $WorkPath
    [pscustomobject]@{ Package = (New-PackTunePackage -WorkPath $WorkPath); DetectionFile = $DetectionFile }
}

function Install-PackTuneRuntime {
    # Creates the "PackTune Runtime" Win32 app in the tenant (once; see Get-PackTuneRuntimeWin32ID)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Write-Host "Starting to deploy the $($script:RuntimeName) as win32 app to Intune"

    $Built = New-PackTuneRuntimePackage
    $Package = $Built.Package
    $DetectionFile = $Built.DetectionFile
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionFile }
    $RequirementRule = Invoke-IntuneModule { New-IntuneWin32AppRequirementRule -Architecture "AllWithARM64" -MinimumSupportedWindowsRelease W10_1809 }

    $App = Invoke-IntuneModule {
        Add-IntuneWin32App -FilePath $Package.Path -DisplayName $script:RuntimeName -RequirementRule $RequirementRule -Notes (Get-PackTuneRuntimeNotes) `
            -Description "Makes Chocolatey and winget usable on the device and keeps both up to date. Dependency of every app deployed with PackTune." `
            -Publisher "PackTune" -RestartBehavior suppress -InstallExperience system `
            -InstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1" `
            -UninstallCommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall" -DetectionRule $DetectionRule
    }
    # The module may give up with only a warning and no object: that is a failure, never a success
    $AppId = if ($App) { [string]@($App)[0].id } else { "" }
    if ($AppId -notmatch '^[0-9a-fA-F-]{36}$') { throw "The $($script:RuntimeName) was not created in Intune: the IntuneWin32App module returned no app (see the warning above; often the sign-in lacks a permission or belongs to the wrong app)." }
    # Read back by its id before it counts as created (the list of the tenant can lag behind for a while)
    $Back = $null
    for ($Try = 1; $Try -le 6 -and -not $Back; $Try++) {
        $Back = @(Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId } | Where-Object { $_ -and [string]$_.id -eq $AppId }) | Select-Object -First 1
        if (-not $Back -and $Try -lt 6) { Start-Sleep -Seconds $script:RuntimeReadBackSeconds }
    }
    if (-not $Back) { throw "The $($script:RuntimeName) ($AppId) was reported as created but cannot be read back from Intune. Check Intune > Apps > Windows before you try again (no second app is created automatically)." }
    Save-PackTuneRuntimeIdMemory -AppId $AppId
    Invoke-IntuneModule { Add-IntuneWin32AppAssignmentAllUsers -ID $AppId -Intent available -Notification hideAll } | Out-Null
    Write-Host "$($script:RuntimeName) successfully deployed (app id $AppId, read back from Intune)"
    return $AppId
}#Deploys the PackTune Runtime app to the tenant

# Seconds between the read-back attempts after creating the runtime (tests set 0)
$script:RuntimeReadBackSeconds = 5

function Get-PackTuneRuntimeIdMemoryPath { Join-Path $script:WorkRoot "runtime-apps.json" }
function Save-PackTuneRuntimeIdMemory {
    # The id of a runtime this PackTune created, per tenant: found again even while the app list of the tenant lags behind
    param([Parameter(Mandatory = $true)][string]$AppId)
    $Path = Get-PackTuneRuntimeIdMemoryPath
    $Map = @{}
    try { if (Test-Path -LiteralPath $Path) { $J = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json; foreach ($P in $J.PSObject.Properties) { $Map[$P.Name] = @($P.Value) } } } catch { }
    $Key = ([string]$script:Settings.TenantID).ToLower()
    $Map[$Key] = @(@($Map[$Key]) + $AppId | Where-Object { $_ } | Select-Object -Unique)
    try { ($Map | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $Path -Encoding UTF8 } catch { }
}
function Get-PackTuneRuntimeIdMemory {
    $Path = Get-PackTuneRuntimeIdMemoryPath
    try { if (Test-Path -LiteralPath $Path) { return @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).(([string]$script:Settings.TenantID).ToLower()) | Where-Object { $_ }) } } catch { }
    return @()
}

function Get-PackTuneRuntimeApps {
    <#
        Every PackTune Runtime app of the tenant, oldest first: from the full list of Win32 apps (notes marker or the exact name;
        no display name filter of the module) and the ids this PackTune created, each read back by id (the list can lag behind).
        More than one = duplicates: the interface lists them and offers to remove the extra ones (never automatically).
    #>
    $Found = @{}
    foreach ($A in @(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_ -and ([string]$_.notes -like "*$($script:RuntimeMarker)*" -or [string]$_.displayName -eq $script:RuntimeName) })) { $Found[[string]$A.id] = $A }
    foreach ($Id in @(Get-PackTuneRuntimeIdMemory)) {
        if ($Found.ContainsKey([string]$Id)) { continue }
        $A = @(Invoke-IntuneModule { Get-IntuneWin32App -ID $Id } | Where-Object { $_ -and [string]$_.id -eq $Id }) | Select-Object -First 1
        if ($A -and [string]$A.notes -like "*$($script:RuntimeMarker)*") { $Found[[string]$A.id] = $A }
    }
    @($Found.Values | Sort-Object { [string]$_.createdDateTime } | ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; DisplayName = [string]$_.displayName; Created = [string]$_.createdDateTime; Revision = (Get-PackTuneRuntimeRevision ([string]$_.notes)) } })
}

function Get-PackTuneRuntimeWin32ID {
    # The runtime app of the tenant (the oldest one when there are duplicates), created once when it does not exist
    param([switch]$NoCreate)
    $Apps = @(Get-PackTuneRuntimeApps)
    if ($Apps.Count -gt 1) { Write-Warning "$($Apps.Count) apps named $($script:RuntimeName) are in the tenant ($(@($Apps | ForEach-Object { "$($_.Id), created $($_.Created)" }) -join '; ')). The oldest one is used; remove the others on the start page (Clean up)." }
    if ($Apps.Count -gt 0) { return $Apps[0].Id }
    if ($NoCreate) { return $null }
    Write-Host "$($script:RuntimeName) is not in Intune, it will be deployed now"
    return Install-PackTuneRuntime
}#Returns the Intune ID of the PackTune Runtime app

function Update-PackTuneRuntime {
    <#
        Brings the PackTune Runtime app of the tenant to the revision of this tool, in place: the same app id, so every dependency and assignment
        stays. The new content first, then detection (marker of the new revision) and notes in one change; read back by id before it counts as
        done. Devices then fail the detection once and run the new install. No new app, no supersedence.
    #>
    param([string]$AppId)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    if (-not $AppId) { $AppId = [string](@(Get-PackTuneRuntimeApps) | Select-Object -First 1).Id }
    if ($AppId -notmatch '^[0-9a-fA-F-]{36}$') { throw "There is no $($script:RuntimeName) in the tenant to update." }
    $Own = @(Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId } | Where-Object { $_ -and [string]$_.id -eq $AppId }) | Select-Object -First 1
    if (-not $Own -or [string]$Own.notes -notlike "*$($script:RuntimeMarker)*") { throw "App $AppId is not a $($script:RuntimeName) of this tool. Nothing was changed." }
    $Old = Get-PackTuneRuntimeRevision ([string]$Own.notes)
    if ($Old -ge $script:RuntimeRevision) { Write-Host "$($script:RuntimeName) is at revision $Old already."; return $AppId }
    Write-Host "Updating $($script:RuntimeName) ($AppId) from revision $Old to $($script:RuntimeRevision) in place"
    $Built = New-PackTuneRuntimePackage
    Write-Host "Uploading the new content"
    Invoke-IntuneModule { Update-IntuneWin32AppPackageFile -ID $AppId -FilePath $Built.Package.Path } | Out-Null
    Write-Host "Updating detection rule and notes"
    $DetectionRule = Invoke-IntuneModule { New-IntuneWin32AppDetectionRuleScript -ScriptFile $Built.DetectionFile }
    Invoke-IntuneModule { Set-IntuneWin32App -ID $AppId -DetectionRule @($DetectionRule) -Notes (Get-PackTuneRuntimeNotes) } | Out-Null
    $Back = $null
    for ($Try = 1; $Try -le 6 -and -not $Back; $Try++) {
        $Read = @(Invoke-IntuneModule { Get-IntuneWin32App -ID $AppId } | Where-Object { $_ -and [string]$_.id -eq $AppId }) | Select-Object -First 1
        if ($Read -and (Get-PackTuneRuntimeRevision ([string]$Read.notes)) -ge $script:RuntimeRevision) { $Back = $Read }
        elseif ($Try -lt 6) { Start-Sleep -Seconds $script:RuntimeReadBackSeconds }
    }
    if (-not $Back) { throw "The $($script:RuntimeName) ($AppId) was changed, but Intune does not show revision $($script:RuntimeRevision) when read back. Check Intune > Apps > Windows; the update is tried again with the next start." }
    Write-Host "$($script:RuntimeName) is at revision $($script:RuntimeRevision) now (read back from Intune): devices install it at their next check."
    return $AppId
}#Updates the PackTune Runtime app in place to the revision of this tool

function Remove-PackTuneRuntimeDuplicates {
    <#
        Removes the extra PackTune Runtime apps (all but the oldest, or the ones in -AppId). Only on request (the interface asks
        first); an app another app depends on is not removed (Remove-PackTuneIntuneApp refuses it). Returns one row per app.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string[]]$AppId)
    $Apps = @(Get-PackTuneRuntimeApps)
    if ($Apps.Count -lt 2) { return @() }
    $Extra = @($Apps | Select-Object -Skip 1)
    if ($AppId) { $Extra = @($Extra | Where-Object { $_.Id -in $AppId }) }
    foreach ($A in $Extra) {
        if (-not $PSCmdlet.ShouldProcess("$($A.DisplayName) ($($A.Id))", "remove from Intune")) { continue }
        try { Remove-PackTuneIntuneApp -Id $A.Id -Name $A.DisplayName | Out-Null; [pscustomobject]@{ Id = $A.Id; Removed = $true; Message = 'removed' } }
        catch { [pscustomobject]@{ Id = $A.Id; Removed = $false; Message = $_.Exception.Message } }
    }
}#Removes duplicate runtime apps on request

# Names the interface and older code know: both dependency apps are now the one runtime
function get-ChocoWin32ID { Get-PackTuneRuntimeWin32ID }
function install-chocolatey { Install-PackTuneRuntime }
function Get-WingetRuntimeWin32ID { param([switch]$NoCreate) Get-PackTuneRuntimeWin32ID -NoCreate:$NoCreate }

function Set-PackTuneRuntimeDependency {
    # Gives one app the runtime as its AutoInstall dependency. The relationships are replaced as a whole through Graph (updateRelationships):
    # what the app has (other dependencies, supersedence), without the old dependency apps, plus the runtime. Then read back.
    # Returns Before (old dependencies found), Verified.
    param([Parameter(Mandatory = $true)][string]$AppId, [Parameter(Mandatory = $true)][string]$RuntimeId, [string[]]$OldIds = @())
    $Own = @(Get-PackTuneAppRelationships -AppId $AppId | Where-Object { $_.Direction -eq "Own" })
    $Old = @($Own | Where-Object { $_.Kind -eq "Dependency" -and $_.TargetId -in $OldIds })
    $Keep = @($Own | Where-Object { -not ($_.Kind -eq "Dependency" -and ($_.TargetId -eq $RuntimeId -or $_.TargetId -in $OldIds)) })
    $Runtime = [pscustomobject]@{ Kind = "Dependency"; Direction = "Own"; TargetId = $RuntimeId; TargetName = ""; DependencyType = "autoInstall"; SupersedenceType = "" }
    Set-PackTuneAppRelationships -AppId $AppId -Own (@($Keep) + $Runtime)
    $After = @(Get-PackTuneAppRelationships -AppId $AppId | Where-Object { $_.Direction -eq "Own" -and $_.Kind -eq "Dependency" })
    $Problems = New-Object System.Collections.ArrayList
    if (@($After | Where-Object { $_.TargetId -eq $RuntimeId }).Count -eq 0) { [void]$Problems.Add("the runtime is not a dependency after the change") }
    foreach ($Still in @($After | Where-Object { $_.TargetId -in $OldIds })) { [void]$Problems.Add("still depends on the old dependency app $($Still.TargetName) ($($Still.TargetId))") }
    $Lost = @($Keep | Where-Object { $K = $_; @(Get-PackTuneAppRelationships -AppId $AppId | Where-Object { $_.Direction -eq "Own" -and $_.Kind -eq $K.Kind -and $_.TargetId -eq $K.TargetId }).Count -eq 0 })
    foreach ($L in $Lost) { [void]$Problems.Add("lost $($L.Kind) -> $($L.TargetId) by the change") }
    [pscustomobject]@{ Old = $Old; Problems = @($Problems); Verified = ($Problems.Count -eq 0) }
}
#endregion

#region app relationships (Microsoft Graph, beta)

function Invoke-PackTuneIntuneGraph {
    <#
        One request to deviceAppManagement of Microsoft Graph (beta) with the token of the session, for what the IntuneWin32App
        module cannot do reliably: reading all relationships of an app and replacing them in one call. Returns the parsed answer.
        Tests: the fake module answers through Invoke-FakeIntuneGraph.
    #>
    param([string]$Method = "GET", [Parameter(Mandatory = $true)][string]$Path, $Body)
    if (Get-Command Invoke-FakeIntuneGraph -ErrorAction SilentlyContinue) { return (Invoke-IntuneModule { Invoke-FakeIntuneGraph -Method $Method -Path $Path -Body $Body }) }
    Assert-PackTuneConnection
    Update-PackTuneToken
    # A path that starts with deviceManagement/ is relative to the beta root, every other one to deviceAppManagement
    $Url = if ($Path -like "deviceManagement/*") { "https://graph.microsoft.com/beta/$Path" } else { "https://graph.microsoft.com/beta/deviceAppManagement/$Path" }
    $Params = @{ Method = $Method; Uri = $Url; Headers = $Global:AuthenticationHeader; ErrorAction = "Stop" }
    if ($null -ne $Body) { $Params.Body = ($Body | ConvertTo-Json -Depth 8); $Params.ContentType = "application/json" }
    try { return (Invoke-RestMethod @Params) }
    catch {
        $Detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { [string]$_.ErrorDetails.Message } else { $_.Exception.Message }
        try { $Parsed = $Detail | ConvertFrom-Json; if ($Parsed.error.message) { $Detail = [string]$Parsed.error.message } } catch { }
        throw "Graph $Method $Path failed: $Detail"
    }
}#One Graph request of the app relationships

function Get-PackTuneAppRelationships {
    <#
        All relationships of an app: Direction "Own" (the app depends on / supersedes the target) or "Incoming" (the target depends on /
        supersedes this app). Kind: Dependency, Supersedence. One row each, with the name of the other app.
    #>
    param([Parameter(Mandatory = $true)][string]$AppId)
    $Answer = Invoke-PackTuneIntuneGraph -Path "mobileApps/$AppId/relationships"
    foreach ($Entry in @($Answer.value | Where-Object { $_ })) {
        $Type = [string]$Entry.'@odata.type'
        $Kind = if ($Type -like "*mobileAppDependency") { "Dependency" } elseif ($Type -like "*mobileAppSupersedence") { "Supersedence" } else { continue }
        [pscustomobject]@{
            Kind = $Kind; Direction = $(if ([string]$Entry.targetType -eq "parent") { "Incoming" } else { "Own" })
            TargetId = [string]$Entry.targetId; TargetName = [string]$Entry.targetDisplayName
            DependencyType = [string]$Entry.dependencyType; SupersedenceType = [string]$Entry.supersedenceType
        }
    }
}#Relationships of an app (own and incoming)

function Set-PackTuneAppRelationships {
    # Replaces ALL relationships of the app (dependencies and supersedence) with the rows given (Get-PackTuneAppRelationships rows, Direction Own)
    param([Parameter(Mandatory = $true)][string]$AppId, $Own)
    $List = @(foreach ($Row in @($Own | Where-Object { $_ })) {
            if ($Row.Kind -eq "Dependency") { [ordered]@{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $Row.TargetId; dependencyType = $(if ([string]$Row.DependencyType -ieq "detect") { "detect" } else { "autoInstall" }) } }
            elseif ($Row.Kind -eq "Supersedence") { [ordered]@{ "@odata.type" = "#microsoft.graph.mobileAppSupersedence"; targetId = $Row.TargetId; supersedenceType = $(if ([string]$Row.SupersedenceType -ieq "replace") { "replace" } else { "update" }) } }
        })
    [void](Invoke-PackTuneIntuneGraph -Method POST -Path "mobileApps/$AppId/updateRelationships" -Body @{ relationships = $List })
}#Replaces the relationships of an app

function Remove-PackTuneIntuneApp {
    <#
        Deletes one app from the tenant the way the service allows it: an app that other apps depend on is refused (they are named);
        a superseding app that points at it gets that supersedence taken off; the relationships of the app itself are cleared first
        (Intune refuses to delete a "parent of another app"); then the delete, and a read back that the app is gone. Every step is logged.
    #>
    param([Parameter(Mandatory = $true)][string]$Id, [string]$Name, [switch]$AllowInstalled)
    if (-not $Name) { $Name = $Id }
    # Never while a device still reports the app as installed (the count is read again right now; when it cannot be read, nothing is deleted).
    # -AllowInstalled is for the old dependency apps only: Chocolatey and winget stay on the devices whatever happens to the app in Intune.
    if (-not $AllowInstalled) {
        $Installed = $null
        try { $Installed = Get-PackTuneAppInstalledCount -AppId $Id } catch { throw "$Name ($Id) is kept: the install count cannot be read ($($_.Exception.Message)). Nothing is deleted without it." }
        if ($Installed -gt 0) { throw "$Name ($Id) is kept: still installed on $Installed device(s). Set the assignment to Uninstall first and remove the app when no device reports it any more." }
    }
    $Relations = @(Get-PackTuneAppRelationships -AppId $Id)
    $Dependents = @($Relations | Where-Object { $_.Direction -eq "Incoming" -and $_.Kind -eq "Dependency" })
    if ($Dependents.Count) { throw "$Name ($Id) is kept: $($Dependents.Count) app(s) still depend on it: $((($Dependents | ForEach-Object { "$($_.TargetName) ($($_.TargetId))" }) -join ', ')). Switch or remove those first." }
    foreach ($Superseding in @($Relations | Where-Object { $_.Direction -eq "Incoming" -and $_.Kind -eq "Supersedence" })) {
        $Others = @(Get-PackTuneAppRelationships -AppId $Superseding.TargetId | Where-Object { $_.Direction -eq "Own" -and -not ($_.Kind -eq "Supersedence" -and $_.TargetId -eq $Id) })
        Write-Host "$($Superseding.TargetName) ($($Superseding.TargetId)) supersedes $Name ($Id): taking that supersedence off"
        Set-PackTuneAppRelationships -AppId $Superseding.TargetId -Own $Others
    }
    $Own = @($Relations | Where-Object { $_.Direction -eq "Own" })
    if ($Own.Count) {
        Write-Host "$Name ($Id) has $($Own.Count) relationship(s) of its own, clearing them first: $((($Own | ForEach-Object { "$($_.Kind) -> $($_.TargetName) ($($_.TargetId))" }) -join '; '))"
        Set-PackTuneAppRelationships -AppId $Id -Own @()
        $Left = @(Get-PackTuneAppRelationships -AppId $Id | Where-Object { $_.Direction -eq "Own" })
        if ($Left.Count) { throw "The relationships of $Name ($Id) could not be cleared ($($Left.Count) left), the app was not deleted" }
    }
    [void](Invoke-PackTuneIntuneGraph -Method DELETE -Path "mobileApps/$Id")
    if (@(Invoke-IntuneModule { Get-IntuneWin32App } | Where-Object { $_.id -eq $Id }).Count -gt 0) { throw "Intune still lists $Name ($Id), it was not removed" }
    Write-Host "Deleted $Name ($Id)"
}#Deletes an app, relationships first

function Get-PackTuneAppRemovalInfo {
    # For the confirmation before a removal: what the app depends on / supersedes, and who depends on it (the removal is refused then)
    param([Parameter(Mandatory = $true)][string]$AppId)
    $Relations = @(Get-PackTuneAppRelationships -AppId $AppId)
    [pscustomobject]@{
        Own = @($Relations | Where-Object { $_.Direction -eq "Own" })
        Dependents = @($Relations | Where-Object { $_.Direction -eq "Incoming" -and $_.Kind -eq "Dependency" })
        Superseding = @($Relations | Where-Object { $_.Direction -eq "Incoming" -and $_.Kind -eq "Supersedence" })
    }
}#What removing an app touches

#endregion
#region old dependency apps, migration, state

function Get-PackTuneOldDependencyApps {
    # The two dependency apps of earlier versions: the Chocolatey app and the winget runtime app
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    foreach ($App in @(Invoke-IntuneModule { Get-IntuneWin32App })) {
        $Notes = [string]$App.notes
        if ($Notes -like "*$($script:ChocoAppMarker)*" -and $App.displayName -eq "Chocolatey") { [pscustomobject]@{ Id = $App.id; DisplayName = $App.displayName; Kind = "Chocolatey" } }
        elseif ($Notes -like "*$($script:OldWingetRuntimeMarker)*" -and $App.displayName -eq $script:OldWingetRuntimeName) { [pscustomobject]@{ Id = $App.id; DisplayName = $App.displayName; Kind = "WingetRuntime" } }
    }
}#Old Chocolatey app and old winget runtime app

function Get-PackTuneAppsWithRuntimeState {
    # Per app of the tool: does it depend on the runtime, and on which old dependency apps (read from the relationships in Graph)
    param([string]$RuntimeId, [string[]]$OldIds = @())
    foreach ($App in @(Get-PackTuneTenantApps | Where-Object { -not $_.IsChocolatey })) {
        $Targets = @(Get-PackTuneAppRelationships -AppId $App.Id | Where-Object { $_.Direction -eq "Own" -and $_.Kind -eq "Dependency" } | ForEach-Object { $_.TargetId })
        [pscustomobject]@{
            Id = $App.Id; DisplayName = $App.DisplayName; Source = $App.Source
            HasRuntime = [bool]($RuntimeId -and $Targets -contains $RuntimeId)
            OldDependencies = @($Targets | Where-Object { $_ -in $OldIds })
        }
    }
}
function Get-PackTuneRuntimeState {
    <#
        What the interface shows under readiness: State is "Missing" (no PackTune Runtime in the tenant), "Migrate"
        (runtime there, but apps still depend on the old dependency apps or have no runtime dependency), "Ready", or "Outdated" (the
        runtime of the tenant has an older revision than this tool: RuntimeRevision < ToolRevision, Update-PackTuneRuntime brings it up).
        UnusedOld = old dependency apps nothing depends on (can be removed, see Remove-PackTuneUnusedDependencyApps).
    #>
    $RuntimeApps = @(Get-PackTuneRuntimeApps)
    $RuntimeId = if ($RuntimeApps.Count) { $RuntimeApps[0].Id } else { $null }
    $Old = @(Get-PackTuneOldDependencyApps)
    $Apps = @(Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds @($Old.Id))
    $OnOld = @($Apps | Where-Object { $_.OldDependencies.Count -gt 0 })
    $Without = @($Apps | Where-Object { -not $_.HasRuntime })
    $Unused = @(Get-PackTuneUnusedDependencyApps -OldApps $Old)
    $Revision = if ($RuntimeApps.Count) { [int]$RuntimeApps[0].Revision } else { 0 }
    $Outdated = [bool]($RuntimeId -and $Revision -lt $script:RuntimeRevision)
    $Change = [string]$script:RuntimeChanges[[int]$script:RuntimeRevision]
    $State = if (-not $RuntimeId) { "Missing" } elseif ($Outdated) { "Outdated" } elseif ($OnOld.Count -gt 0 -or $Without.Count -gt 0) { "Migrate" } else { "Ready" }
    [pscustomobject]@{
        State = $State; RuntimePresent = [bool]$RuntimeId; RuntimeId = $RuntimeId
        RuntimeRevision = $Revision; ToolRevision = [int]$script:RuntimeRevision; Outdated = $Outdated; Change = $Change
        OldDependencyApps = $Old; AppsOnOldDependencies = $OnOld; AppsWithoutRuntime = $Without; UnusedOld = $Unused
        # More than one runtime app: the extra ones (all but the oldest), listed for a cleanup on request
        RuntimeDuplicates = @($RuntimeApps | Select-Object -Skip 1)
    }
}#Runtime present / old dependencies in use, for the readiness list

function Switch-PackTuneAppsToRuntime {
    <#
        Moves the apps of the tool (both sources) to the PackTune Runtime: it becomes their dependency, the old
        dependency apps (Chocolatey, winget runtime) are taken away. Creates the runtime when it is missing. Without
        -AppId all apps of the tool; one row per app that changed. The old apps stay (Get-PackTuneUnusedDependencyApps).
        Every app is logged (old dependencies found, runtime added, old ones removed) and read back from the tenant; an app whose
        change is not confirmed fails the run (an error at the end, with the cause per app), so a job never ends as done on a change
        that did not happen.
    #>
    param([string[]]$AppId)
    Assert-PackTunePrerequisites
    Assert-PackTuneConnection
    Update-PackTuneToken
    $RuntimeId = Get-PackTuneRuntimeWin32ID
    $OldApps = @(Get-PackTuneOldDependencyApps)
    $OldIds = @($OldApps | ForEach-Object { $_.Id })
    $Names = @{}; foreach ($Old in $OldApps) { $Names[[string]$Old.Id] = "$($Old.DisplayName) ($($Old.Id))" }
    $Apps = @(Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds $OldIds)
    if ($AppId) { $Apps = @($Apps | Where-Object { $_.Id -in $AppId }) }
    $Todo = @($Apps | Where-Object { -not ($_.HasRuntime -and $_.OldDependencies.Count -eq 0) })
    Write-Host "PackTune Runtime is $RuntimeId; $($Todo.Count) of $($Apps.Count) app(s) have to be switched"
    $Failed = New-Object System.Collections.ArrayList
    foreach ($App in $Todo) {
        $Found = if ($App.OldDependencies.Count) { (($App.OldDependencies | ForEach-Object { if ($Names.ContainsKey($_)) { $Names[$_] } else { $_ } }) -join ", ") } else { "none" }
        Write-Host "$($App.DisplayName) ($($App.Id)): old dependencies found: $Found; runtime $(if ($App.HasRuntime) { 'already there' } else { 'to add' })"
        try {
            $Result = Set-PackTuneRuntimeDependency -AppId $App.Id -RuntimeId $RuntimeId -OldIds $OldIds
            if (-not $Result.Verified) { throw ($Result.Problems -join "; ") }
            Write-Host "$($App.DisplayName): $(if (-not $App.HasRuntime) { 'PackTune Runtime added, ' })$($App.OldDependencies.Count) old dependency(ies) removed, confirmed in the tenant"
            [pscustomobject]@{ Id = $App.Id; DisplayName = $App.DisplayName; Source = $App.Source; Added = (-not $App.HasRuntime); OldRemoved = $App.OldDependencies.Count }
        }
        catch {
            [void]$Failed.Add("$($App.DisplayName) ($($App.Id)): $($_.Exception.Message)")
            Write-Error "$($App.DisplayName) ($($App.Id)) was not switched: $($_.Exception.Message)" -ErrorAction Continue
        }
    }
    if ($Failed.Count) { throw "$($Failed.Count) of $($Todo.Count) app(s) could not be switched to PackTune Runtime:`n$($Failed -join "`n")" }
    # The tenant has the last word: nothing of the processed apps may still depend on an old dependency app or miss the runtime
    $Check = @(Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds $OldIds | Where-Object { $_.Id -in @($Todo | ForEach-Object { $_.Id }) -and (-not $_.HasRuntime -or $_.OldDependencies.Count -gt 0) })
    if ($Check.Count) { throw "The tenant still shows $($Check.Count) app(s) without the runtime or on an old dependency app: $((($Check | ForEach-Object { "$($_.DisplayName) ($($_.Id))" }) -join ', '))" }
    Write-Host "Summary: $($Todo.Count) app(s) switched to PackTune Runtime and confirmed in the tenant."
}#Switches the apps of the tool to the one runtime dependency
function Get-PackTuneUnusedDependencyApps {
    # Old dependency apps that no app in the tenant depends on any more (so they can be removed). Nothing is deleted.
    # Per old app the apps that still depend on it come along (UsedBy), read from its relationships in Graph.
    param($OldApps)
    if ($null -eq $OldApps) { $OldApps = @(Get-PackTuneOldDependencyApps) }
    $OldApps = @($OldApps | Where-Object { $_ })
    if ($OldApps.Count -eq 0) { return @() }
    foreach ($Old in $OldApps) {
        $UsedBy = @(Get-PackTuneAppRelationships -AppId $Old.Id | Where-Object { $_.Direction -eq "Incoming" -and $_.Kind -eq "Dependency" })
        $Old | Add-Member -NotePropertyName UsedBy -NotePropertyValue $UsedBy -Force
    }
    @($OldApps | Where-Object { @($_.UsedBy).Count -eq 0 })
}#Old dependency apps nothing depends on

function Remove-PackTuneUnusedDependencyApps {
    # Removes the old dependency apps nothing depends on (on request, never automatic). -WhatIf only lists them. Every app is logged
    # with name and id (deleted, or kept with the apps that still depend on it); a delete that does not hold fails the run.
    param([switch]$WhatIf)
    $All = @(Get-PackTuneOldDependencyApps)
    $Unused = @(Get-PackTuneUnusedDependencyApps -OldApps $All)
    foreach ($Old in @($All | Where-Object { $_.Id -notin @($Unused | ForEach-Object { $_.Id }) })) {
        Write-Host "Kept $($Old.DisplayName) ($($Old.Id)): still used by $((@($Old.UsedBy) | ForEach-Object { "$($_.TargetName) ($($_.TargetId))" }) -join ', ')"
    }
    if ($Unused.Count -eq 0) { Write-Host "No old dependency app is unused: nothing to remove." }
    $Failed = New-Object System.Collections.ArrayList
    foreach ($Old in $Unused) {
        $Removed = $false
        if ($WhatIf) { Write-Host "Would delete $($Old.DisplayName) ($($Old.Id)): nothing depends on it" }
        else {
            try { Remove-PackTuneIntuneApp -Id $Old.Id -Name $Old.DisplayName -AllowInstalled; $Removed = $true }
            catch { [void]$Failed.Add("$($Old.DisplayName) ($($Old.Id)): $($_.Exception.Message)"); Write-Error "$($Old.DisplayName) ($($Old.Id)) was not deleted: $($_.Exception.Message)" -ErrorAction Continue }
        }
        [pscustomobject]@{ Id = $Old.Id; DisplayName = $Old.DisplayName; Kind = $Old.Kind; Removed = $Removed }
    }
    if ($Failed.Count) { throw "$($Failed.Count) old dependency app(s) could not be removed:`n$($Failed -join "`n")" }
}#Removes unused old dependency apps
# What the interface already calls: apps without the runtime dependency / adding it. Now for both sources; the old
# dependency apps are switched over at the same time.
function Get-PackTuneAppsWithoutRuntime {
    $RuntimeId = Get-PackTuneRuntimeWin32ID -NoCreate
    $OldIds = @(Get-PackTuneOldDependencyApps | ForEach-Object { $_.Id })
    Get-PackTuneAppsWithRuntimeState -RuntimeId $RuntimeId -OldIds $OldIds | Where-Object { -not $_.HasRuntime -or $_.OldDependencies.Count -gt 0 }
}
function Add-PackTuneRuntimeDependency { param([string[]]$AppId) Switch-PackTuneAppsToRuntime -AppId $AppId | ForEach-Object { $_ | Add-Member -NotePropertyName AlreadyThere -NotePropertyValue (-not $_.Added) -PassThru } }

#endregion
