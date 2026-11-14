<#
.SYNOPSIS
    Live check of the tray agent in Windows Sandbox: tray.ps1 as PackTune generates it runs as the sandbox user with two fake apps in a
    fake protected folder (a Chocolatey and a winget app with pending updates, one with an icon). The popup opens by itself (new update),
    a screenshot shows it above the tray; a second agent must not start (one per session); a fake SYSTEM task "Update <pkg> now" proves
    that the agent starts the install through the validated mapping (the script calls the same function the button calls). Screenshots
    and results.json land in -OutDir. Nothing runs on this computer.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Spike-Tray.ps1 -OutDir $env:TEMP\trayshots
#>
[CmdletBinding()]
param([int]$TimeoutMinutes = 8, [string]$OutDir)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path "$env:SystemRoot\System32\WindowsSandbox.exe")) { throw 'Windows Sandbox is not available on this machine.' }
if (Get-Process -Name WindowsSandbox, WindowsSandboxClient, WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) { throw 'A Windows Sandbox is already running; Windows allows only one.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneTraySpike-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
. (Join-Path $repo 'PackTune-Main.ps1')
$job = Join-Path $work 'job'
New-Item -ItemType Directory -Path (Join-Path $job 'out') -Force | Out-Null
Set-Content -Path (Join-Path $job 'tray.ps1') -Value (Get-UpdateTrayScript) -Encoding ASCII

$run = @'
$ErrorActionPreference = 'Continue'
$Job = 'C:\Job'; $Out = "$Job\out"
$R = [ordered]@{}
function Shot($Name) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save("$Out\$Name.png", [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
function Save-Result { $R | ConvertTo-Json | Set-Content "$Job\result.json" -Encoding UTF8 }
try {
    Add-Type -Name Win -Namespace PackTuneSpike -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][PackTuneSpike.Win]::ShowWindow([PackTuneSpike.Win]::GetConsoleWindow(), 6); [void][PackTuneSpike.Win]::SetProcessDPIAware()
    $R.Started = $true; Save-Result
    Add-Type -AssemblyName System.Drawing
    $Base = "$env:ProgramFiles\PackTune"
    function New-FakeApp($Source, $Package, $Name, $Letter, $Hours) {
        $dir = "$Base\$Source\$Package"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @{ Package = $Package; TaskId = $Package; TaskPath = "\PackTune\$Source\"; Mode = 'Custom'; DisplayName = $Name } | ConvertTo-Json | Set-Content "$dir\config.json"
        @{ Package = $Package; DisplayName = $Name; Installed = '1.0'; Target = '2.0'; FirstSeen = (Get-Date).ToString('o'); Deadline = (Get-Date).AddHours($Hours).ToString('o') } | ConvertTo-Json | Set-Content "$dir\state.json"
        if ($Letter) {
            $bmp = New-Object System.Drawing.Bitmap 96, 96
            $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#005FB8'))
            $g.DrawString($Letter, (New-Object System.Drawing.Font('Segoe UI', 44, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 12, 6)
            $bmp.Save("$dir\icon.png", [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
        }
        $action = New-ScheduledTaskAction -Execute cmd.exe -Argument "/c echo ran > C:\Job\ran-$Package.txt"
        Register-ScheduledTask -TaskName "Update $Package now" -TaskPath "\PackTune\$Source\" -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    }
    New-FakeApp 'Chocolatey' 'contosoapp' 'Contoso & Co <Pro>' 'C' 46
    New-FakeApp 'Winget' 'Fabrikam.Tool' 'Fabrikam Tool' '' 20
    Start-Sleep -Seconds 20
    # the agent as the task starts it (conhost --headless, STA), here from this session
    $p = Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList '--headless', "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '"C:\Job\tray.ps1"' -PassThru
    Start-Sleep -Seconds 30
    $R.AgentRunning = -not $p.HasExited
    Shot '1-popup-opened-by-itself'
    # a second agent in the same session must leave at once
    $p2 = Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList '--headless', "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '"C:\Job\tray.ps1"' -PassThru
    Start-Sleep -Seconds 12
    $R.SecondAgentExited = $p2.HasExited
    $R.StateFile = Test-Path "$env:LOCALAPPDATA\PackTune\Updates\tray\state.json"
    $R.Announced = (Get-Content "$env:LOCALAPPDATA\PackTune\Updates\tray\state.json" -Raw -ErrorAction SilentlyContinue)
    # the install action through the library of the agent (the code the button runs)
    $src = Get-Content 'C:\Job\tray.ps1' -Raw
    $lib = $src.Substring($src.IndexOf('# ---------------------------------------------------------------- notifications'), $src.IndexOf('# ---------------------------------------------------------------- interface') - $src.IndexOf('# ---------------------------------------------------------------- notifications'))
    $SnoozeFolder = "$env:LOCALAPPDATA\PackTune\Updates"
    Invoke-Expression $lib
    $R.ActionText = Invoke-TrayAction 'install' 'Chocolatey' 'contosoapp'
    $R.BogusActionText = Invoke-TrayAction 'install' 'Chocolatey' '..\x'
    for ($i = 0; $i -lt 40 -and -not (Test-Path "$Job\ran-contosoapp.txt"); $i++) { Start-Sleep -Seconds 1 }
    $R.InstallStartedTask = Test-Path "$Job\ran-contosoapp.txt"
    $R.BogusStartedNothing = -not (Test-Path "$Job\ran-x.txt")
    $R.PostponeText = Invoke-TrayAction 'postpone' 'Winget' 'Fabrikam.Tool'
    Start-Sleep -Seconds 40
    Shot '2-after-install-and-postpone'
    $R.NotifyLog = (Get-Content "$env:LOCALAPPDATA\PackTune\Updates\notify.log" -ErrorAction SilentlyContinue) -join ' | '
    $R.Status = 'done'
}
catch { $R.Error = $_.Exception.Message }
$R | ConvertTo-Json | Set-Content "$Job\result.json" -Encoding UTF8
Start-Sleep -Seconds 2
shutdown.exe /s /t 0
'@
Set-Content -Path (Join-Path $job 'run.ps1') -Value $run -Encoding ASCII
$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$wsb = @"
<Configuration>
  <vGPU>Enable</vGPU>
  <Networking>Disable</Networking>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$(& $esc $job)</HostFolder><SandboxFolder>C:\Job</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Job\run.ps1</Command></LogonCommand>
</Configuration>
"@
Set-Content -Path (Join-Path $work 'tray.wsb') -Value $wsb -Encoding UTF8
Start-Process -FilePath "$env:SystemRoot\System32\WindowsSandbox.exe" -ArgumentList "`"$(Join-Path $work 'tray.wsb')`""
$resultFile = Join-Path $job 'result.json'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
while ((-not (Test-Path $resultFile) -or (Get-Content $resultFile -Raw -ErrorAction SilentlyContinue) -notmatch '"Status"') -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
if ($OutDir) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; Copy-Item (Join-Path $job 'out\*') $OutDir -Force -ErrorAction SilentlyContinue; Copy-Item $resultFile $OutDir -Force -ErrorAction SilentlyContinue }
if (-not (Test-Path $resultFile) -or (Get-Content $resultFile -Raw) -notmatch '"Status"') { throw "No result after $TimeoutMinutes minutes (job folder: $job)" }
$result = Get-Content $resultFile -Raw | ConvertFrom-Json
$result | Format-List | Out-String
$checks = @(
    @('the agent runs (hidden, STA)', ($result.AgentRunning -eq $true)),
    @('a second agent in the same session leaves at once (one instance)', ($result.SecondAgentExited -eq $true)),
    @('the new updates were announced once (state file of the user)', [bool]($result.Announced -like '*Chocolatey|contosoapp|2.0*' -and $result.Announced -like '*Winget|Fabrikam.Tool|2.0*')),
    @('Install now starts the SYSTEM task of that app', ($result.InstallStartedTask -eq $true)),
    @('an invalid package starts nothing and says nothing', ($result.BogusStartedNothing -eq $true -and -not $result.BogusActionText)),
    @('Postpone says when it installs automatically', [bool]($result.PostponeText -like 'Installs automatically on *'))
)
$failed = 0
foreach ($c in $checks) { if ($c[1]) { "PASS  $($c[0])" } else { $failed++; "FAIL  $($c[0])" } }
if ($result.Error) { "ERROR in the sandbox: $($result.Error)"; $failed++ }
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($failed) { throw "$failed check(s) failed" }
'SPIKE PASSED'
