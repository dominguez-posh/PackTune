<#
.SYNOPSIS
    Live run of the Win32 test lab for ONE winget app (default 7zip.7zip) in Windows Sandbox: the lab installs the PackTune Runtime first (its own
    step "Dependency: PackTune Runtime": the real install.ps1 as SYSTEM, which provisions App Installer from Microsoft's signed msixbundle and
    dependencies, then its detection), then detect, install, detect, uninstall, detect of the app as deployed. Prints the steps with their result
    and exit code, and keeps results.json and the screenshots of the lab in -OutDir. Needs the internet inside the sandbox (community.chocolatey.org
    for Chocolatey; github.com and its release download host for the App Installer bundle and dependencies; the winget source and the download
    host of the app) and runs for several minutes. Windows allows only one sandbox: it stops with a message when one is open (it never closes one).
    PackTune's own data goes to a temporary folder, not to your profile. Nothing is installed on this computer.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Spike-LabRuntime.ps1 -OutDir $env:TEMP\labruntime
#>
[CmdletBinding()]
param([string]$WingetId = '7zip.7zip', [int]$TimeoutMinutes = 40, [string]$OutDir)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path "$env:SystemRoot\System32\WindowsSandbox.exe")) { throw 'Windows Sandbox is not available on this machine.' }
if (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) { throw 'A Windows Sandbox is already running; Windows allows only one. Close it yourself and run this again.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneLabRuntimeSpike-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PACKTUNE_SANDBOX_REAL = '1'   # a live run: the real Windows Sandbox processes count
. (Join-Path $repo 'PackTune-Main.ps1')
Set-PackTuneSandboxOption -Name JobTimeoutMinutes -Value $TimeoutMinutes
Set-PackTuneSandboxLog -Sink { param($Text, $Level) Write-Host $Text }
$result = Test-PackTunePackage -ChocoName $WingetId -Source Winget -Version latest -AutoRun
"`nVerdict: $($result.Verdict). $($result.Message)"
$resultsFile = Join-Path $result.JobPath 'out\lab\results.json'
if (Test-Path $resultsFile) {
    $r = Get-Content $resultsFile -Raw | ConvertFrom-Json
    foreach ($s in $r.Steps) { '{0}. {1,-34} {2,-7} {3}' -f $s.Index, $s.Title, $s.State, $s.Detail }
    if ($OutDir) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; Copy-Item (Join-Path $result.JobPath 'out\lab\*') $OutDir -Recurse -Force; "Results and screenshots: $OutDir" }
}
else { "No results.json (the sandbox was closed before the lab finished): $($result.JobPath)" }
if ($result.Verdict -ne 'Passed') { exit 1 }
