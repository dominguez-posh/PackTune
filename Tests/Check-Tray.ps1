<#
.SYNOPSIS
    Checks of the tray agent "PackTune Updates" (PackTune-Tray.ps1) without a device: the generated tray.ps1 parses and is plain ASCII,
    the library against a fake program folder (apps, status, popup items, the state machine: a new update opens the popup once, postponed
    and late ones do not, a newer target opens it again), the action mapping (unknown input is ignored, install starts only the validated
    task, postpone writes only a snooze), the fallback (notify.ps1 leaves the prompt to the agent only while it runs), the runtime
    package (tray.ps1, the logon task of the Users group, revision), the defaults, and the XAML of the popup.
    Nothing is shown, no task or registry is touched (schtasks.exe is replaced). No network.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Tray.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneTray-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')

# --- the generated script
$text = Get-UpdateTrayScript
$errors = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
Test-Check 'tray.ps1: valid PowerShell, plain ASCII, no placeholder left' (($errors.Count -eq 0) -and ($text -notmatch '[^\x00-\x7F]') -and ($text -notmatch '__[A-Z]+__')) (@($errors | ForEach-Object Message) -join '; ')
Test-Check 'tray.ps1: one instance per session (mutex), no network call, never elevates' (($text -match 'Local\\PackTuneTrayAgent') -and ($text -notmatch 'Invoke-WebRequest|Invoke-RestMethod|WebClient|Start-Process.*-Verb|RunAs') -and ($text -match 'STA|Dispatcher::Run'))
Test-Check 'tray.ps1: the popup and the three icon states are there' (($text -match 'Install all now') -and ($text -match 'Postpone 2 days') -and ($text -match 'uptodate') -and ($text -match 'installing'))

# --- the library, against a fake program folder
$ProgramRoot = Join-Path $work 'Program Files\PackTune'
$SnoozeFolder = Join-Path $work 'PackTune\Updates'
Invoke-Expression (Get-UpdateToastLibrary)
Invoke-Expression (Get-UpdateTrayLibrary)
$script:Running = @{}
function Test-TrayTaskRunning([string]$TaskPath, [string]$TaskName) { $script:Running.ContainsKey("$TaskPath$TaskName") }
$now = [datetime]'2026-11-20T10:00:00'
function New-App([string]$Source, [string]$Package, $Deadline, [string]$Installed = '1.0', [string]$Target = '2.0', [string]$Mode = 'Custom', $Result, [switch]$NoState, [switch]$WingetConfig) {
    $dir = Join-Path (Join-Path $ProgramRoot $Source) $Package
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $cfg = if ($WingetConfig) { @{ Id = "$Package.id"; SafeId = $Package; TaskId = $Package; TaskPath = "\PackTune\$Source\"; Mode = $Mode; DisplayName = "$Package display" } } else { @{ Package = $Package; TaskId = $Package; TaskPath = "\PackTune\$Source\"; Mode = $Mode; DisplayName = "$Package display" } }
    $cfg | ConvertTo-Json | Set-Content (Join-Path $dir 'config.json')
    if (-not $NoState) { @{ Package = $Package; DisplayName = "$Package display"; Installed = $Installed; Target = $Target; FirstSeen = $now.ToString('o'); Deadline = ([datetime]$Deadline).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $dir 'state.json') }
    if ($Result) { $Result | ConvertTo-Json | Set-Content (Join-Path $dir 'last-result.json') }
    $dir
}
$null = New-App 'Chocolatey' 'vlc' '2026-11-22T10:00:00'
$null = New-App 'Winget' 'VideoLAN.Tool' '2026-11-21T09:00:00' -WingetConfig
$null = New-App 'Chocolatey' 'idleapp' $null -NoState -Mode 'Startup'
$null = New-App 'Chocolatey' 'doneapp' $null -NoState -Result @{ action = 'upgrade'; status = 'ok'; lastAttempt = $now.AddMinutes(-10).ToString('o'); installedVersion = '3.1' }
$null = New-App 'Chocolatey' 'oldresult' $null -NoState -Result @{ action = 'upgrade'; status = 'ok'; lastAttempt = $now.AddHours(-5).ToString('o'); installedVersion = '9.9' }
$null = New-App 'Chocolatey' 'running' $null -NoState
$script:Running['\PackTune\Chocolatey\Update running now'] = $true
$bad = Join-Path $ProgramRoot 'Chocolatey\bad name!'; New-Item -ItemType Directory -Path $bad -Force | Out-Null; '{}' | Set-Content (Join-Path $bad 'config.json')
$mis = Join-Path $ProgramRoot 'Chocolatey\mismatch'; New-Item -ItemType Directory -Path $mis -Force | Out-Null; @{ Package = 'other'; TaskPath = '\PackTune\Chocolatey\' } | ConvertTo-Json | Set-Content (Join-Path $mis 'config.json')
$evil = Join-Path $ProgramRoot 'Chocolatey\badtask'; New-Item -ItemType Directory -Path $evil -Force | Out-Null; @{ Package = 'badtask'; TaskPath = '\Microsoft\Windows\Defrag\' } | ConvertTo-Json | Set-Content (Join-Path $evil 'config.json')
$apps = @(Get-TrayApps $now)
Test-Check 'apps: every valid app of both sources, the invalid folders (bad name, id mismatch, foreign task folder) are left out' (($apps.Count -eq 6) -and (@($apps | Where-Object Package -in 'bad name!', 'mismatch', 'badtask').Count -eq 0)) (($apps | ForEach-Object Package) -join ',')
$vlc = $apps | Where-Object Package -eq 'vlc'
Test-Check 'apps: a pending update with versions, deadline and name' ($vlc.Pending -and $vlc.Installed -eq '1.0' -and $vlc.Target -eq '2.0' -and $vlc.Deadline -eq [datetime]'2026-11-22T10:00:00' -and $vlc.Name -eq 'vlc display')
Test-Check 'apps: a winget app (config with TaskId, no Package) is read too' (@($apps | Where-Object { $_.Source -eq 'Winget' -and $_.Pending }).Count -eq 1)
Test-Check 'apps: running task = installing; a recent successful upgrade = finished, an old one is not' ((($apps | Where-Object Package -eq 'running').Installing) -and (($apps | Where-Object Package -eq 'doneapp').Finished) -and (($apps | Where-Object Package -eq 'doneapp').FinishedVersion -eq '3.1') -and -not (($apps | Where-Object Package -eq 'oldresult').Finished))
Test-Check 'status: installing wins over updates, updates over up to date' ((Get-TrayStatus $apps) -eq 'installing' -and (Get-TrayStatus @($apps | Where-Object { -not $_.Installing })) -eq 'updates' -and (Get-TrayStatus @($apps | Where-Object { -not $_.Installing -and -not $_.Pending })) -eq 'uptodate')

# --- popup items and the state machine
$state = @{ Seen = @(); Postponed = @{} }
$items = @(Get-TrayItems $apps $state $now)
Test-Check 'items: pending updates in the order of their deadline with "Installs automatically on <date>", then the running install, then the finished one' ((($items | ForEach-Object Kind) -join ',') -eq 'pending,pending,installing,finished' -and $items[0].App.Package -eq 'VideoLAN.Tool' -and $items[0].Text -like 'Installs automatically on *' -and $items[0].CanPostpone)
$d = Get-TrayPopupDecision $apps $state $now
Test-Check 'state machine: new updates open the popup, both are remembered as announced' ($d.Open -and $d.NewKeys.Count -eq 2)
$state.Seen = @($d.NewKeys)
$d = Get-TrayPopupDecision $apps $state $now
Test-Check 'state machine: nothing new, the popup does not open again by itself' (-not $d.Open -and $d.NewKeys.Count -eq 0)
$apps2 = @($apps | ForEach-Object { if ($_.Package -eq 'vlc') { $c = $_ | Select-Object *; $c.Target = '3.0'; $c } else { $_ } })
$d = Get-TrayPopupDecision $apps2 $state $now
Test-Check 'state machine: a newer version of an app already announced opens it once more' ($d.Open -and $d.NewKeys.Count -eq 1 -and $d.NewKeys[0] -eq 'Chocolatey|vlc|3.0')
$stateP = @{ Seen = @(); Postponed = @{ 'Chocolatey|vlc|2.0' = $now.AddDays(1); 'Winget|VideoLAN.Tool|2.0' = $now.AddDays(1) } }
$d = Get-TrayPopupDecision $apps $stateP $now
Test-Check 'state machine: postponed updates do not open the popup (but are announced, so a later look does not either)' (-not $d.Open -and $d.NewKeys.Count -eq 2)
$late = @($apps | ForEach-Object { $c = $_ | Select-Object *; if ($c.Pending) { $c.Deadline = $now.AddHours(-1) }; $c })
$d = Get-TrayPopupDecision $late @{ Seen = @(); Postponed = @{} } $now
Test-Check 'state machine: past the deadline the system installs it, the popup stays shut' (-not $d.Open)
$itemsP = @(Get-TrayItems $apps $stateP $now)
Test-Check 'items: a postponed update says so and offers no second postponement' ($itemsP[0].Postponed -and -not $itemsP[0].CanPostpone -and $itemsP[0].Text -like 'Installs automatically on *')
Test-Check 'postpone: two days, but never later than one hour before the deadline; nothing when too close' (((Get-TrayPostponeUntil ($apps | Where-Object Package -eq 'VideoLAN.Tool') $now) -eq [datetime]'2026-11-21T08:00:00') -and ((Get-TrayPostponeUntil ([pscustomobject]@{ Deadline = $now.AddDays(10) }) $now) -eq $now.AddDays(2)) -and ($null -eq (Get-TrayPostponeUntil ([pscustomobject]@{ Deadline = $now.AddMinutes(30) }) $now)) -and ($null -eq (Get-TrayPostponeUntil ([pscustomobject]@{ Deadline = $null }) $now)))

# --- action mapping
foreach ($case in @(
    @('unknown verb', 'format', 'Chocolatey', 'vlc'), @('unknown source', 'install', 'Other', 'vlc'), @('path in the package', 'install', 'Chocolatey', '..\Winget\VideoLAN.Tool'),
    @('empty package', 'install', 'Chocolatey', ''), @('package with a quote', 'install', 'Chocolatey', 'vlc"'), @('not installed', 'install', 'Chocolatey', 'ghost'),
    @('id mismatch in the config', 'install', 'Chocolatey', 'mismatch'), @('foreign task folder in the config', 'install', 'Chocolatey', 'badtask'),
    @('no pending update', 'install', 'Chocolatey', 'idleapp'), @('postpone without a pending update', 'postpone', 'Chocolatey', 'idleapp'),
    @('the package of the other source', 'install', 'Winget', 'vlc')
)) { Test-Check "action: ignored ($($case[0]))" ($null -eq (Resolve-TrayAction $case[1] $case[2] $case[3])) }
$act = Resolve-TrayAction 'install' 'Winget' 'VideoLAN.Tool'
Test-Check 'action: a valid winget package resolves with its task folder and name' ($act -and $act.TaskPath -eq '\PackTune\Winget\' -and $act.DisplayName -eq 'VideoLAN.Tool display')
$script:Schtasks = New-Object System.Collections.ArrayList; $script:SchtasksExit = 0
function schtasks.exe { [void]$script:Schtasks.Add(($args -join ' ')); $global:LASTEXITCODE = $script:SchtasksExit }
$msg = Invoke-TrayAction 'install' 'Chocolatey' 'vlc' $now
Test-Check 'install now: starts exactly the SYSTEM task "Update <package> now" of that source, says so' (($script:Schtasks.Count -eq 1) -and ($script:Schtasks[0] -eq '/run /tn \PackTune\Chocolatey\Update vlc now') -and ($msg -like '*being installed now*')) ($script:Schtasks -join ';')
$script:Schtasks.Clear()
[void](Invoke-TrayAction 'install' 'Chocolatey' 'ghost' $now); [void](Invoke-TrayAction 'install' 'Chocolatey' '..\x' $now)
Test-Check 'install now: unknown packages start nothing' ($script:Schtasks.Count -eq 0)
$msg = Invoke-TrayAction 'postpone' 'Chocolatey' 'vlc' $now
$saved = Get-TrayState
Test-Check 'postpone: only a snooze file of the user changes, nothing is started; the text names the automatic date' (($script:Schtasks.Count -eq 0) -and $saved.Postponed.ContainsKey('Chocolatey|vlc|2.0') -and $saved.Postponed['Chocolatey|vlc|2.0'] -le $now.AddDays(2) -and $msg -like 'Installs automatically on *') $msg
Test-Check 'postpone: the files of the apps are untouched (read only), the deadline stays' ((Get-Content (Join-Path $ProgramRoot 'Chocolatey\vlc\state.json') -Raw | ConvertFrom-Json).Deadline -like '2026-11-22*')
$script:Schtasks.Clear()
Invoke-TrayInstallAll $now
Test-Check 'install all: starts the task of every pending update, not of the others' (($script:Schtasks.Count -eq 2) -and ($script:Schtasks -contains '/run /tn \PackTune\Chocolatey\Update vlc now') -and ($script:Schtasks -contains '/run /tn \PackTune\Winget\Update VideoLAN.Tool now'))
Test-Check 'state file: remembers announced updates and postponements across runs' ($(Save-TrayState @{ Seen = @('a|b|1'); Postponed = @{ 'a|b|1' = $now } }; $s = Get-TrayState; $s.Seen -contains 'a|b|1' -and $s.Postponed['a|b|1'] -eq $now))

# --- fallback: notify.ps1 leaves the prompt to the agent only while it runs
$notify = Get-UpdateNotifyScript -TaskPath '\PackTune\Chocolatey\'
Test-Check 'fallback: notify.ps1 asks whether the agent runs before it shows the update prompt, and still has its toast code' (($notify -match 'if \(Test-TrayAgentRunning\) \{ exit 0 \}') -and ($notify.LastIndexOf('Test-TrayAgentRunning') -lt $notify.LastIndexOf('Text = "Install now"')) -and ($notify -match 'Show-Notice'))
Test-Check 'fallback: no agent, no mutex -> not running' (-not (Test-TrayAgentRunning))
$held = New-Object System.Threading.Mutex($false, $TrayMutexName)
Test-Check 'fallback: while the agent holds the mutex of the session it counts as running' (Test-TrayAgentRunning)
$held.Dispose()

# --- the runtime package
$rt = Get-PackTuneRuntimeScripts
Test-Check 'runtime: revision raised (devices install the agent), the package carries tray.ps1' (($script:RuntimeRevision -ge 4) -and $rt.Tray -and ($rt.Detection -match "Revision = '$($script:RuntimeRevision)'"))
Test-Check 'runtime install: copies tray.ps1 into the protected folder and registers the logon task for the Users group, hidden, one instance, STA' (($rt.Install -match 'Copy-Item -LiteralPath \(Join-Path \$PSScriptRoot "tray.ps1"\)') -and ($rt.Install -match 'S-1-5-32-545') -and ($rt.Install -match 'New-ScheduledTaskTrigger -AtLogOn') -and ($rt.Install -match '--headless') -and ($rt.Install -match '-STA') -and ($rt.Install -match 'MultipleInstances IgnoreNew') -and ($rt.Install -match 'RunLevel Limited'))
Test-Check 'runtime uninstall: the tray task goes too' ($rt.Install -match 'Unregister-ScheduledTask -TaskName \$TrayTaskName')
$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($rt.Install, [ref]$null, [ref]$errors)
Test-Check 'runtime install script: still valid PowerShell and ASCII' ($errors.Count -eq 0 -and $rt.Install -notmatch '[^\x00-\x7F]')

# --- defaults
$def = Get-PackTuneSettings
Test-Check 'defaults: new apps ask the user, with the 2 day deadline' ($def.UpdateMode -eq 'Custom' -and $def.GraceHours -eq 48)
Test-Check 'defaults: the check task looks every hour' ((New-ChocoSchedule).CheckIntervalHours -eq 1)

# --- the XAML of the popup (parsed in an STA runspace)
$xaml = [regex]::Match($text, "\`$PopupXaml = '(.+?)'\r?\n").Groups[1].Value
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({ param($Xaml) Add-Type -AssemblyName PresentationFramework; $w = [System.Windows.Markup.XamlReader]::Parse($Xaml); (@('Head', 'List', 'Empty', 'InstallAll') | Where-Object { $w.FindName($_) }) -join ',' }).AddArgument($xaml)
$found = ($ps.Invoke() | Select-Object -Last 1); $ps.Dispose(); $rs.Dispose()
Test-Check 'popup: the XAML parses and has header, list, empty text and Install all now' ($found -eq 'Head,List,Empty,InstallAll') "$found"

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
