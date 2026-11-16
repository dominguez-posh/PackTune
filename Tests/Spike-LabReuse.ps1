<#
.SYNOPSIS
    Live run of the Win32 test lab for TWO winget apps in a row in ONE Windows Sandbox (default 7zip.7zip, then Notepad++.Notepad++): the first test
    starts the sandbox and installs the PackTune Runtime (slow, once); the second test reuses the open sandbox, the runtime step only checks what is
    there. Prints the steps with their times for both tests, then asks the sandbox PackTune started to close (New sandbox). Windows allows only one
    sandbox: it stops with a message when one is open (it never closes one it did not start). PackTune's own data goes to a temporary folder.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Spike-LabReuse.ps1 -OutDir $env:TEMP\labreuse
#>
[CmdletBinding()]
param([string[]]$WingetId = @('7zip.7zip', 'Notepad++.Notepad++'), [int]$TimeoutMinutes = 40, [string]$OutDir)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path "$env:SystemRoot\System32\WindowsSandbox.exe")) { throw 'Windows Sandbox is not available on this machine.' }
if (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) { throw 'A Windows Sandbox is already running; Windows allows only one. Close it yourself and run this again.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneLabReuseSpike-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PACKTUNE_SANDBOX_REAL = '1'   # a live run: the real Windows Sandbox processes count
. (Join-Path $repo 'PackTune-Main.ps1')
Set-PackTuneSandboxOption -Name JobTimeoutMinutes -Value $TimeoutMinutes
Set-PackTuneSandboxLog -Sink { param($Text, $Level) Write-Host $Text }
$failed = $false
$n = 0
foreach ($id in $WingetId) {
    $n++
    $started = Get-Date
    "`n===== Test $n of $($WingetId.Count): $id ====="
    $result = Test-PackTunePackage -ChocoName $id -Source Winget -Version latest -AutoRun
    "Verdict: $($result.Verdict). $($result.Message)  (total $([int]((Get-Date) - $started).TotalSeconds) s)"
    $resultsFile = Join-Path $result.JobPath 'out\lab\results.json'
    if (Test-Path $resultsFile) {
        $r = Get-Content $resultsFile -Raw | ConvertFrom-Json
        foreach ($s in $r.Steps) { '{0}. {1,-34} {2,-7} {3}' -f $s.Index, $s.Title, $s.State, $s.Detail }
        if ($OutDir) { $dest = Join-Path $OutDir "test$n"; New-Item -ItemType Directory -Path $dest -Force | Out-Null; Copy-Item (Join-Path $result.JobPath 'out\lab\*') $dest -Recurse -Force }
    }
    else { "No results.json: $($result.JobPath)" }
    if ($result.Verdict -ne 'Passed') { $failed = $true; break }
}
"`nSession after the tests: $(Get-PackTuneLabSession | ConvertTo-Json -Compress)"
[void](Request-PackTuneNewLabSandbox)
if ($failed) { exit 1 }
