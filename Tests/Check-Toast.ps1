<#
.SYNOPSIS
    Checks of the device notifications (notify.ps1, library in PackTune-Toast.ps1) without a device: the generated scripts parse and are
    plain ASCII, the toast XML is well-formed and escaped, the button activation only maps to the fixed actions (unknown input,
    wrong or used tokens, packages that are not installed, tampered files are all ignored), the route decision (toast or the PackTune
    window when toasts are off or Focus assist hides the deadline notice), and the whole flow with stand-ins for Windows.
    Nothing is shown, no registry or task is touched, shutdown.exe and schtasks.exe are replaced.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Toast.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneToast-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')

# --- the generated scripts
foreach ($taskPath in '\PackTune\Chocolatey\', '\PackTune\Winget\') {
    $text = Get-UpdateNotifyScript -TaskPath $taskPath
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    Test-Check "notify.ps1 ($taskPath): valid PowerShell, plain ASCII, no placeholder left" (($errors.Count -eq 0) -and ($text -notmatch '[^\x00-\x7F]') -and ($text -notmatch '__[A-Z]+__') -and ($text -match [regex]::Escape("`$TaskPath = `"$taskPath`""))) (@($errors | ForEach-Object Message) -join '; ')
}
Test-Check 'the device scripts have a new revision (devices pick up the notifications)' ($script:DeviceScriptRevision -ge 9)
Test-Check 'no MessageBox is left in notify.ps1' ((Get-UpdateNotifyScript -TaskPath '\PackTune\Chocolatey\') -notmatch 'MessageBox')

# --- the library in a scope of its own, with a fake program folder
$ProgramRoot = Join-Path $work 'Program Files\PackTune'
$SnoozeFolder = Join-Path $work 'PackTune\Updates'
Invoke-Expression (Get-UpdateToastLibrary)

# --- toast XML: well formed, escaped
$icon = Join-Path $work 'icon dir\icon.png'; New-Item -ItemType Directory -Path (Split-Path $icon) -Force | Out-Null; [IO.File]::WriteAllBytes($icon, [byte[]](1, 2, 3))
$nasty = 'Tom & Jerry <Pro> "Edition" ''x'''
$xmlText = New-ToastXml -Title "Software update: $nasty" -Lines @("An update for $nasty is available (1.0 -> 2.0).", "Otherwise at 5 > 4 & 3 < 4") -IconFile $icon -Buttons @(@{ Text = 'Install now'; Uri = 'packtune-update:install?t=' + ('a' * 32) }, @{ Text = 'Later "soon"'; Uri = 'packtune-update:later?t=' + ('a' * 32) }) -Reminder $false
$doc = $null; try { $doc = [xml]$xmlText } catch { }
Test-Check 'toast xml: well-formed with & < > " and quote in the name' ($null -ne $doc) $xmlText
$texts = @($doc.toast.visual.binding.text)
Test-Check 'toast xml: the text comes back exactly (title and lines)' (($texts[0] -eq "Software update: $nasty") -and ($texts[1] -like "An update for $nasty is available*") -and ($texts[2] -eq 'Otherwise at 5 > 4 & 3 < 4')) ($texts -join ' | ')
Test-Check 'toast xml: app icon as file address (spaces encoded), two protocol buttons with their text, no reminder' (($doc.toast.visual.binding.image.src -like 'file:///*icon%20dir*icon.png') -and (@($doc.toast.actions.action).Count -eq 2) -and ($doc.toast.actions.action[1].content -eq 'Later "soon"') -and ($doc.toast.actions.action[0].activationType -eq 'protocol') -and -not $doc.toast.scenario)
$rem = [xml](New-ToastXml -Title 'T' -Lines @('x') -IconFile '' -Buttons @() -Reminder $true)
Test-Check 'toast xml: a reminder stays on screen and always has a button; no icon file means no image element' (($rem.toast.scenario -eq 'reminder') -and (@($rem.toast.actions.action).Count -eq 1) -and ($rem.toast.actions.action.activationType -eq 'system') -and -not $rem.toast.visual.binding.image)
$ctl = [xml](New-ToastXml -Title "a$([char]1)b$([char]27)c" -Lines @() -IconFile '' -Buttons @() -Reminder $false)
Test-Check 'toast xml: control characters that XML forbids are dropped' ($ctl.toast.visual.binding.text -eq 'abc')
$unicode = [xml](New-ToastXml -Title ("Caf" + [char]0xE9 + " " + [char]0x65E5) -Lines @() -IconFile '' -Buttons @() -Reminder $false)
Test-Check 'toast xml: other characters stay' ($unicode.toast.visual.binding.text -eq ("Caf" + [char]0xE9 + " " + [char]0x65E5))

# --- route: toast, or the window
$cases = @(
    @('Enabled', 5, $false, 'toast'), @('Enabled', 5, $true, 'toast'),
    @('DisabledForUser', 5, $false, 'window'), @('DisabledByGroupPolicy', 5, $true, 'window'), @('Unavailable', 5, $false, 'window'),
    @('Enabled', 6, $false, 'toast'), @('Enabled', 6, $true, 'window'), @('Enabled', 4, $true, 'window'), @('Enabled', 2, $true, 'window'), @('Enabled', 3, $true, 'window'), @('Enabled', 1, $true, 'toast')
)
foreach ($c in $cases) { Test-Check "route: setting $($c[0]), shell state $($c[1]), deadline $($c[2]) -> $($c[3])" ((Get-ToastRoute -Setting $c[0] -UserState $c[1] -Deadline $c[2]) -eq $c[3]) }

# --- an installed package with a pending update (protected folder as the install makes it), tokens, activation
function New-FakePackage([string]$Source, [string]$Package, [switch]$Update, [switch]$Restart, [switch]$Winget) {
    $root = Join-Path (Join-Path $ProgramRoot $Source) $Package
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    # the config.json of each source as install.ps1 writes it: winget has Id, SafeId, TaskId and no Package
    $cfg = if ($Winget) { @{ Id = "$Package.id"; SafeId = $Package; TaskId = $Package; TaskPath = "\PackTune\$Source\"; DisplayName = "$Package display" } } else { @{ Package = $Package; TaskId = $Package; TaskPath = "\PackTune\$Source\"; DisplayName = "$Package display" } }
    $cfg | ConvertTo-Json | Set-Content (Join-Path $root 'config.json')
    if ($Update) { '{}' | Set-Content (Join-Path $root 'state.json') }
    if ($Restart) { '{}' | Set-Content (Join-Path $root 'restart.json') }
}
New-FakePackage 'Chocolatey' 'contosoapp' -Update -Restart
New-FakePackage 'Winget' 'Contoso.Tool' -Update -Winget
New-FakePackage 'Chocolatey' 'idleapp'
$script:Schtasks = New-Object System.Collections.ArrayList; $script:Shutdowns = New-Object System.Collections.ArrayList; $script:SchtasksExit = 0
function schtasks.exe { [void]$script:Schtasks.Add(($args -join ' ')); $global:LASTEXITCODE = $script:SchtasksExit }
function shutdown.exe { [void]$script:Shutdowns.Add(($args -join ' ')); $global:LASTEXITCODE = 0 }

$t1 = Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('install', 'later')
$ok = Resolve-ToastActivation (Get-ToastUri 'install' $t1)
Test-Check 'activation: a valid address with its token resolves to the package, its task path and name' ($ok -and $ok.Verb -eq 'install' -and $ok.Package -eq 'contosoapp' -and $ok.TaskPath -eq '\PackTune\Chocolatey\' -and $ok.DisplayName -eq 'contosoapp display')
$rejected = @(
    @('unknown verb', "packtune-update:format?t=$t1"), @('verb not in the token', "packtune-update:restart?t=$t1"), @('no token', 'packtune-update:install'),
    @('empty', ''), @('other scheme', "http://evil.example/install?t=$t1"), @('extra parameter', "packtune-update:install?t=$t1&pkg=other"),
    @('extra path', "packtune-update:install/..\..?t=$t1"), @('short token', 'packtune-update:install?t=abc'), @('token with path', 'packtune-update:install?t=..\..\config'),
    @('guessed token', 'packtune-update:install?t=' + ('0' * 32)), @('trailing text', "packtune-update:install?t=$t1 -Command calc"), @('quotes', "packtune-update:install?t=$t1`" -Foo")
)
foreach ($r in $rejected) { Test-Check "activation ignores: $($r[0])" ($null -eq (Resolve-ToastActivation $r[1])) $r[1] }
Test-Check 'activation: the address is not case sensitive in scheme and verb' ($null -ne (Resolve-ToastActivation (Get-ToastUri 'install' $t1).ToUpper().Replace($t1.ToUpper(), $t1)))

# tampered or stale tokens
$tf = Join-Path $ToastFolder "$t1.json"
$saved = Get-Content $tf -Raw
$entry = $saved | ConvertFrom-Json
foreach ($case in @(
    @('expired', { $entry.Expires = (Get-Date).AddMinutes(-1).ToString('o') }),
    @('package id with a path', { $entry.Package = '..\..\Windows' }),
    @('package that is not installed', { $entry.Package = 'ghostapp' }),
    @('task path of another folder', { $entry.TaskPath = '\PackTune\Winget\' }),
    @('task path outside PackTune', { $entry.TaskPath = '\Microsoft\Windows\Defrag\' }),
    @('no pending update (idle package)', { $entry.Package = 'idleapp' }),
    @('verbs list emptied', { $entry.Verbs = @() })
)) {
    $entry = $saved | ConvertFrom-Json
    & $case[1]
    ($entry | ConvertTo-Json) | Set-Content $tf
    Test-Check "tampered token ($($case[0])) gives no action" ($null -eq (Resolve-ToastActivation (Get-ToastUri 'install' $t1)))
}
Set-Content $tf $saved
'not json' | Set-Content $tf
Test-Check 'a damaged token file gives no action' ($null -eq (Resolve-ToastActivation (Get-ToastUri 'install' $t1)))
Set-Content $tf $saved
$cfg = Join-Path $ProgramRoot 'Chocolatey\contosoapp\config.json'; $cfgSaved = Get-Content $cfg -Raw
@{ Package = 'ContosoApp'; TaskPath = '\PackTune\Chocolatey\' } | ConvertTo-Json | Set-Content $cfg
Test-Check 'a package id that differs in case from the installed policy is refused' ($null -eq (Resolve-ToastActivation (Get-ToastUri 'install' $t1)))
@{ Package = 'contosoapp'; TaskPath = '\Evil\' } | ConvertTo-Json | Set-Content $cfg
Test-Check 'a policy whose task path is not a PackTune folder is refused' ($null -eq (Resolve-ToastActivation (Get-ToastUri 'install' $t1)))
Set-Content $cfg $cfgSaved

# the actions
$act = Resolve-ToastActivation (Get-ToastUri 'install' $t1)
$msg = Invoke-ToastAction $act
Test-Check 'install: starts exactly the task "Update <package> now" in the folder of the package, says so, the token is used up' (($script:Schtasks.Count -eq 1) -and ($script:Schtasks[0] -eq '/run /tn \PackTune\Chocolatey\Update contosoapp now') -and ($msg -like '*being installed now*') -and -not (Test-Path $tf) -and ($null -eq (Resolve-ToastActivation (Get-ToastUri 'install' $t1)))) ($script:Schtasks -join ';')
$script:Schtasks.Clear(); $script:SchtasksExit = 1
$t2 = Save-ToastToken 'Contoso.Tool' '\PackTune\Winget\' @('install')
$msg = Invoke-ToastAction (Resolve-ToastActivation (Get-ToastUri 'install' $t2))
Test-Check 'install: a task that cannot start is reported, the winget task folder is used for a winget app' (($msg -like '*could not be started*') -and ($script:Schtasks[0] -eq '/run /tn \PackTune\Winget\Update Contoso.Tool now'))
$script:SchtasksExit = 0
$tw = Save-ToastToken 'Contoso.Tool' '\PackTune\Winget\' @('install')
$aw = Resolve-ToastActivation (Get-ToastUri 'install' $tw)
Test-Check 'activation: a winget app (config with TaskId and no Package field) resolves to its package and task folder' ($aw -and $aw.Package -eq 'Contoso.Tool' -and $aw.TaskPath -eq '\PackTune\Winget\')
Test-Check 'activation: a Chocolatey app (config with Package and TaskId) still resolves' ($null -ne (Resolve-ToastActivation (Get-ToastUri 'install' (Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('install')))))
$script:Shutdowns.Clear()
[void](Invoke-ToastAction ([pscustomobject]@{ Verb = 'restart'; Package = 'contosoapp'; TaskPath = '\PackTune\Chocolatey\'; DisplayName = ('Evil" /f ' + [char]10 + 'App'); TokenFile = $null }))
Test-Check 'restart: double quotes and control characters are stripped from the name in the shutdown comment' (($script:Shutdowns.Count -eq 1) -and ($script:Shutdowns[0] -notmatch '"') -and ($script:Shutdowns[0] -notmatch "`n") -and ($script:Shutdowns[0] -like '*Evil /f App'))
$script:Shutdowns.Clear()
$t3 = Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('later', 'install')
$before = Get-Date
[void](Invoke-ToastAction (Resolve-ToastActivation (Get-ToastUri 'later' $t3)))
$until = [datetime](Get-Content (Join-Path $SnoozeFolder 'contosoapp.snooze') -Raw).Trim()
Test-Check 'later: snoozes the update prompt for 4 hours' (($until -gt $before.AddHours(3.9)) -and ($until -lt $before.AddHours(4.1)))
$t4 = Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('restart', 'remind')
[void](Invoke-ToastAction (Resolve-ToastActivation (Get-ToastUri 'remind' $t4)))
$until = [datetime](Get-Content (Join-Path $SnoozeFolder 'contosoapp.restart') -Raw).Trim()
Test-Check 'remind: snoozes the restart prompt for 1 hour, no restart' (($until -gt $before.AddMinutes(55)) -and ($until -lt $before.AddMinutes(65)) -and $script:Shutdowns.Count -eq 0)
$t5 = Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('restart', 'remind')
[void](Invoke-ToastAction (Resolve-ToastActivation (Get-ToastUri 'restart' $t5)))
Test-Check 'restart: a restart in 60 seconds, named for the update' (($script:Shutdowns.Count -eq 1) -and ($script:Shutdowns[0] -like '/r /t 60 /c Restart for the update of contosoapp display'))
$t6 = Save-ToastToken 'Contoso.Tool' '\PackTune\Winget\' @('restart')
Test-Check 'restart: without a pending restart request the address does nothing' ($null -eq (Resolve-ToastActivation (Get-ToastUri 'restart' $t6)))
$t7 = Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('install')
$t8 = Save-ToastToken 'contosoapp' '\PackTune\Chocolatey\' @('install')
Test-Check 'a newer toast of the package makes the older one useless' (($null -eq (Resolve-ToastActivation (Get-ToastUri 'install' $t7))) -and ($null -ne (Resolve-ToastActivation (Get-ToastUri 'install' $t8))))

# --- the whole flow with stand-ins for Windows
$script:State = @{ Setting = 'Enabled'; UserState = 5 }
$script:Shown = New-Object System.Collections.ArrayList; $script:Windows = New-Object System.Collections.ArrayList; $script:Registered = 0
$script:ToastWorks = $true; $script:WindowAnswer = $null
function Get-ToastState { $script:State }
function Register-ToastApp([string]$HandlerScript) { $script:Registered++ }
function Show-ToastXml([string]$Package, [string]$Xml) { if ($script:ToastWorks) { [void]$script:Shown.Add($Xml); $true } else { $false } }
function Show-UpdateWindow { param([string]$Title, [string]$Message, $Buttons, [string]$IconFile) [void]$script:Windows.Add(@{ Title = $Title; Message = $Message; Buttons = @($Buttons) }); $script:WindowAnswer }
function Reset-Stand { $script:Shown.Clear(); $script:Windows.Clear(); $script:Schtasks.Clear(); $script:Shutdowns.Clear(); $script:Registered = 0; $script:State = @{ Setting = 'Enabled'; UserState = 5 }; $script:ToastWorks = $true; $script:WindowAnswer = $null }
$updateButtons = @(@{ Text = 'Install now'; Verb = 'install'; Primary = $true }, @{ Text = 'Later'; Verb = 'later' })
$common = @{ Package = 'contosoapp'; Name = 'Tom & Jerry <Pro>'; TaskPath = '\PackTune\Chocolatey\'; Title = 'Software update: Tom & Jerry <Pro>'; Lines = @('An update is available.'); IconFile = $icon; HandlerScript = 'C:\x\notify.ps1' }

Reset-Stand
$r = Show-Notice @common -Buttons $updateButtons
$x = [xml]$script:Shown[0]
$uri = $x.toast.actions.action[0].arguments
Test-Check 'flow: toast route shows one well-formed toast with the app registered, the window stays closed' (($r -eq 'toast') -and $script:Shown.Count -eq 1 -and $script:Windows.Count -eq 0 -and $script:Registered -eq 1 -and $x.toast.visual.binding.text[0] -eq 'Software update: Tom & Jerry <Pro>')
Test-Check 'flow: the buttons carry addresses that resolve to the fixed actions of the package' ((Resolve-ToastActivation $uri).Verb -eq 'install' -and (Resolve-ToastActivation $x.toast.actions.action[1].arguments).Verb -eq 'later' -and $null -eq $x.toast.scenario)
Reset-Stand
[void](Show-Notice @common -Buttons $updateButtons -Deadline $true)
Test-Check 'flow: a deadline notice is a reminder toast (stays on screen)' (([xml]$script:Shown[0]).toast.scenario -eq 'reminder')
Reset-Stand; $script:State = @{ Setting = 'DisabledForUser'; UserState = 5 }; $script:WindowAnswer = 'install'
$r = Show-Notice @common -Buttons $updateButtons
Test-Check 'flow: toasts off gives the window with both buttons; "Install now" there starts the task and a result notice follows' (($r -eq 'window') -and $script:Windows[0].Buttons.Count -eq 2 -and $script:Windows[0].Buttons[0].Primary -and $script:Schtasks[0] -eq '/run /tn \PackTune\Chocolatey\Update contosoapp now' -and $script:Windows.Count -eq 2 -and $script:Windows[1].Message -like '*being installed now*') ($script:Schtasks -join ';')
Reset-Stand; $script:State = @{ Setting = 'Enabled'; UserState = 6 }; $script:WindowAnswer = 'ack'
$r = Show-Notice @common -Deadline $true -Buttons @(@{ Text = 'OK'; Primary = $true })
Test-Check 'flow: Focus assist hides a deadline notice, so it comes as a window with an OK button' (($r -eq 'window') -and $script:Shown.Count -eq 0 -and $script:Windows[0].Buttons[0].Text -eq 'OK' -and $script:Schtasks.Count -eq 0)
Reset-Stand; $script:State = @{ Setting = 'Enabled'; UserState = 6 }
$r = Show-Notice @common -Buttons $updateButtons
Test-Check 'flow: Focus assist and an ordinary prompt: the toast goes quietly to the Notification Center' (($r -eq 'toast') -and $script:Windows.Count -eq 0)
Reset-Stand; $script:ToastWorks = $false; $script:WindowAnswer = 'later'
$r = Show-Notice @common -Buttons $updateButtons
Test-Check 'flow: a toast that cannot be shown falls back to the window; "Later" there snoozes' (($r -eq 'window') -and $script:Windows.Count -eq 1 -and (Test-Path (Join-Path $SnoozeFolder 'contosoapp.snooze')))
Reset-Stand; $script:WindowAnswer = $null
$r = Show-Notice @common -NoToast -Buttons $updateButtons
Test-Check 'flow: a closed window (no answer) does nothing' (($r -eq 'window') -and $script:Schtasks.Count -eq 0 -and $script:Shutdowns.Count -eq 0)
Reset-Stand
$c2 = $common.Clone(); $c2.Lines = @('The update needs a restart.')
$r = Show-Notice @c2 -Buttons @(@{ Text = 'Restart now'; Verb = 'restart'; Primary = $true }, @{ Text = 'Remind me in 1 hour'; Verb = 'remind' })
$x = [xml]$script:Shown[0]
Test-Check 'flow: the restart toast has "Restart now" and "Remind me in 1 hour"' (($x.toast.actions.action[0].content -eq 'Restart now') -and ($x.toast.actions.action[1].content -eq 'Remind me in 1 hour') -and (Resolve-ToastActivation $x.toast.actions.action[0].arguments).Verb -eq 'restart')
Reset-Stand
$c3 = $common.Clone(); $c3.Lines = @('Info only.')
[void](Show-Notice @c3)
Test-Check 'flow: a notice without buttons is a plain toast with no token and no actions' (([xml]$script:Shown[0]).toast.actions -eq $null)

# --- the window itself: its XAML is valid and has what the code looks for (parsed in an STA runspace)
$block = $UpdateWindowBlock.ToString()
$xaml = [regex]::Match($block, "\`$Xaml = '(.+?)'\r?\n").Groups[1].Value
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({ param($Xaml) Add-Type -AssemblyName PresentationFramework; $w = [System.Windows.Markup.XamlReader]::Parse($Xaml); (@('TitleText', 'Body', 'Row', 'Img', 'Mono') | Where-Object { $w.FindName($_) }) -join ',' }).AddArgument($xaml)
$found = ($ps.Invoke() | Select-Object -Last 1); $ps.Dispose(); $rs.Dispose()
Test-Check 'window: the XAML parses and holds title, text, button row, icon and letter tile' ($found -eq 'TitleText,Body,Row,Img,Mono') "$found"
$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($block, [ref]$null, [ref]$errors)
Test-Check 'window: the script block parses' ($errors.Count -eq 0)

# --- the icon of the package goes into the package and install.ps1 puts it into the protected folder
$policy = New-PackTuneAppPolicy -Package 'contosoapp'
$pngBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
$src = Join-Path $work 'pkg\source'; New-Item -ItemType Directory -Path $src -Force | Out-Null
$null = New-ChocoPackageScripts -ChocoName 'contosoapp' -SourcePath $src -Policy $policy -DisplayName 'Contoso' -IconBase64 ([Convert]::ToBase64String($pngBytes))
Test-Check 'package: icon.png is written next to the scripts when the package has an icon' ((Test-Path (Join-Path $src 'icon.png')) -and ([IO.File]::ReadAllBytes((Join-Path $src 'icon.png')).Length -eq 8))
$install = Get-Content (Join-Path $src 'install.ps1') -Raw
Test-Check 'package: install.ps1 copies icon.png into the protected folder (optional)' (($install -match 'icon\.png') -and ($install -match 'Test-Path -LiteralPath \(Join-Path \$PSScriptRoot "icon\.png"\)'))
$src2 = Join-Path $work 'pkg2\source'; New-Item -ItemType Directory -Path $src2 -Force | Out-Null
$null = New-ChocoPackageScripts -ChocoName 'contosoapp' -SourcePath $src2 -Policy $policy -DisplayName 'Contoso'
Test-Check 'package: no icon, no icon.png (the notice then shows the PackTune letter tile or the plain toast)' (-not (Test-Path (Join-Path $src2 'icon.png')))
$src3 = Join-Path $work 'pkg3\source'; New-Item -ItemType Directory -Path $src3 -Force | Out-Null
$null = New-WingetPackageScripts -WingetId 'Contoso.Tool' -SourcePath $src3 -Policy (New-PackTuneAppPolicy -Package 'Contoso.Tool') -DisplayName 'Contoso' -IconBase64 ([Convert]::ToBase64String($pngBytes))
Test-Check 'package (winget): the same, icon.png next to the scripts and copied by install.ps1' ((Test-Path (Join-Path $src3 'icon.png')) -and ((Get-Content (Join-Path $src3 'install.ps1') -Raw) -match 'icon\.png'))
$notify = Get-Content (Join-Path $src3 'notify.ps1') -Raw
Test-Check 'package (winget): notify.ps1 has the winget task folder' ($notify -match [regex]::Escape('$TaskPath = "\PackTune\Winget\"'))

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
