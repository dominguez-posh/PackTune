# Counter-test for the scripts that run on devices and in the sandbox lab: they run in Windows PowerShell 5.1 as SYSTEM, so they must never call a
# cmdlet that only PowerShell 7 or a module without a Windows PowerShell version offers (the lab once called Repair-WinGetPackageManager of
# Microsoft.WinGet.Client: "This cmdlet is not supported in Windows PowerShell", and every winget test failed). Every generated script (runtime app,
# Chocolatey and winget packages with every helper, the lab's own scripts) is parsed; each command it calls must be defined in the script itself or
# resolve in Windows PowerShell 5.1, and a list of known PowerShell 7 only commands is refused by name. No device, no tenant.
# Run in Windows PowerShell 5.1:  powershell -NoProfile -File Tests\Check-DeviceScripts.ps1
$ErrorActionPreference = 'Stop'
trap { "FAIL  the check stopped before the end: $($_.Exception.Message)"; exit 1 }
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ("devicescripts-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:LOCALAPPDATA = $temp
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) {
    if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) }
}
Test-Check 'this check runs in Windows PowerShell 5.1 (the engine of the devices)' ($PSVersionTable.PSVersion.Major -eq 5) $PSVersionTable.PSVersion
. (Join-Path $repo 'PackTune-Main.ps1')
Import-Module (Join-Path $repo 'Modules\PackTune.Sandbox.psm1') -Force

# Microsoft.WinGet.Client and other commands that Windows PowerShell 5.1 cannot run (or that a device does not have)
$denied = '^(Repair-WinGetPackageManager|Assert-WinGetPackageManager|Get-WinGetPackage|Find-WinGetPackage|Install-WinGetPackage|Update-WinGetPackage|Uninstall-WinGetPackage|Get-WinGetVersion|Get-WinGetSource|Add-WinGetSource|Reset-WinGetSource|Set-WinGetUserSetting|Get-WinGetUserSetting|Test-WinGetUserSetting|Enable-WinGetSetting|Disable-WinGetSetting|Get-WinGetSetting|Install-Module|Install-PackageProvider|Import-Module Microsoft\.WinGet.*|ConvertFrom-Json -AsHashtable|Test-Json|Join-String|Get-Error|Remove-Alias)$'

function Get-ScriptCommands([string]$Text) {
    $errors = $null; $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errors)
    $defined = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $called = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
        $first = $_.CommandElements[0]
        if ($first -is [Management.Automation.Language.StringConstantExpressionAst]) { [string]$first.Value }
    } | Where-Object { $_ } | Select-Object -Unique)
    [pscustomobject]@{ Errors = $errors; Defined = $defined; Called = $called }
}
function Test-ScriptText([string]$Label, [string]$Text) {
    $c = Get-ScriptCommands $Text
    $bad = @($c.Called | Where-Object { $_ -match $denied })
    $unknown = @($c.Called | Where-Object { $_ -notin $c.Defined -and $_ -notmatch '^[A-Za-z]:|^\.|\\|/|\.exe$|^(if|foreach|exit|return|break|continue|throw|trap)$' -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    Test-Check "$Label`: no PowerShell 7 only command, every command resolves in Windows PowerShell 5.1" ($c.Errors.Count -eq 0 -and $bad.Count -eq 0 -and $unknown.Count -eq 0) ("denied: $($bad -join ', ') unknown: $($unknown -join ', ') parse: $(@($c.Errors | ForEach-Object Message) -join '; ')")
}

# ---- the scripts of the runtime app
$scripts = Get-PackTuneRuntimeScripts
foreach ($name in 'Install', 'Detection', 'Update', 'Tray') { Test-ScriptText "runtime $name" $scripts.$name }

# ---- both sources: install, update, notify, probe and detection of a generated package
foreach ($case in @(@('Chocolatey', 'googlechrome'), @('Winget', 'Google.Chrome'))) {
    $src = Join-Path $temp "src-$($case[0])"; New-Item -ItemType Directory -Path $src | Out-Null
    $policy = New-PackTuneAppPolicy -Package $case[1]
    $detection = if ($case[0] -eq 'Winget') { New-WingetPackageScripts -WingetId $case[1] -SourcePath $src -Policy $policy -DisplayName 'Google Chrome' } else { New-ChocoPackageScripts -ChocoName $case[1] -SourcePath $src -Policy $policy -DisplayName 'Google Chrome' }
    foreach ($file in Get-ChildItem $src -Filter '*.ps1') { Test-ScriptText "$($case[0]) $($file.Name)" (Get-Content $file.FullName -Raw) }
    Test-ScriptText "$($case[0]) detection" (Get-Content $detection -Raw)
}

# ---- the lab's own scripts (the Intune order: the runtime step, then the package as deployed)
Test-ScriptText 'lab runtime step' (Get-PackTuneLabRuntimeStep)
$mainAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'PackTune-Main.ps1'), [ref]$null, [ref]$null)
$labInstallSource = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PackTunePackage' }, $true).Extent.Text
Test-Check 'the lab has no script of its own that installs winget or Chocolatey (no bootstrap, no Repair-WinGetPackageManager, no Install-Module)' ($labInstallSource -notmatch 'Repair-WinGetPackageManager|Install-Module Microsoft\.WinGet\.Client|Install-PackageProvider')
Test-ScriptText 'sandbox Lab.ps1 with LabShared.ps1' ((Get-Content (Join-Path $repo 'Sandbox\Lab.ps1') -Raw) + "`n" + (Get-Content (Join-Path $repo 'Sandbox\LabShared.ps1') -Raw))
Test-ScriptText 'sandbox Bootstrap.ps1' (Get-Content (Join-Path $repo 'Sandbox\Bootstrap.ps1') -Raw)

# ---- the check itself finds the old mistake
$old = @'
Install-Module Microsoft.WinGet.Client -Force -Scope AllUsers
Import-Module Microsoft.WinGet.Client
Repair-WinGetPackageManager -AllUsers -Latest -Force
'@
$c = Get-ScriptCommands $old
Test-Check 'counter-test: the script of the old lab (Repair-WinGetPackageManager) is refused' (@($c.Called | Where-Object { $_ -match $denied }).Count -ge 2)

Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
