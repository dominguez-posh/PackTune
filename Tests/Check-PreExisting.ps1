# Checks of software that was on the device before PackTune: detection (machine-wide uninstall entries, per-user copies), the record in the
# protected app folder, adoption, the uninstall decision ("remove only what PackTune installed" vs "also a pre-existing installation"), the
# setting in policy, fingerprint and notes, and what the status script reports. No device, no tenant: the registry keys and folders of the
# detection are replaced by test keys under HKCU and a temp folder.
# Run in Windows PowerShell 5.1:  powershell -NoProfile -File Tests\Check-PreExisting.ps1
$ErrorActionPreference = 'Stop'
trap { "FAIL  the check stopped before the end: $($_.Exception.Message)"; exit 1 }
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ("preexisting-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$env:LOCALAPPDATA = $temp
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) {
    if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) }
}
. (Join-Path $repo 'PackTune-Main.ps1')

# ---- the device functions, as the install scripts get them
. ([scriptblock]::Create((Get-DevicePreExistingCommon)))
$commonAst = [Management.Automation.Language.Parser]::ParseInput((Get-DeviceScriptCommon), [ref]$null, [ref]$null)
foreach ($name in 'Get-PreExistingRecord', 'Test-KeepPreExisting', 'Save-LastResult') {
    $fn = $commonAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:DeviceLog = New-Object System.Collections.ArrayList
function Write-DeviceLog([string]$Text) { [void]$script:DeviceLog.Add($Text) }
function Write-ProtectedFile([string]$Path, [string]$Text) { Set-Content -LiteralPath $Path -Value $Text -Encoding ASCII }   # the real one only writes under %ProgramFiles%

$base = 'HKCU:\Software\PackTuneCheckPreExisting'
Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
function New-Arp([string]$Root, [string]$Key, [hashtable]$Values) {
    $path = Join-Path $Root $Key
    New-Item -Path $path -Force | Out-Null
    foreach ($k in $Values.Keys) { New-ItemProperty -Path $path -Name $k -Value $Values[$k] -Force | Out-Null }
}
try {
    # ---- machine-wide: an MSI of Chrome
    New-Arp "$base\Machine" '{CHROME-MSI}' @{ DisplayName = 'Google Chrome'; DisplayVersion = '131.0.1'; WindowsInstaller = 1 }
    New-Arp "$base\Machine" 'Other' @{ DisplayName = 'Chromium Extras'; DisplayVersion = '1.0' }
    New-Arp "$base\Machine" 'Hidden' @{ DisplayName = 'Google Chrome Helper'; SystemComponent = 1 }
    $probe = @{ MachineKeys = @("$base\Machine\*"); UserKeys = @("$base\NoUser\*"); ProgramsRoots = @((Join-Path $temp 'NoPrograms')) }
    $f = Get-PreExistingInstall -Names @('Google Chrome', 'Google Chrome', 'Chrome') @probe
    Test-Check 'detection: a machine-wide MSI is found by its display name, with version and origin' ($f.Machine -and $f.Version -eq '131.0.1' -and $f.Origin -eq 'MSI' -and $f.UserCopies -eq 0) ($f | ConvertTo-Json -Compress)
    $f = Get-PreExistingInstall -Names @('Chrome') @probe
    Test-Check 'detection: a short name does not match an unrelated product (Chrome vs Chromium Extras)' (-not $f.Machine) ($f | ConvertTo-Json -Compress)
    $f = Get-PreExistingInstall -Names @('Mozilla Firefox') @probe
    Test-Check 'detection: nothing there, nothing found' (-not $f.Machine -and $f.UserCopies -eq 0)

    # ---- an EXE installer
    New-Arp "$base\Machine" 'ExeApp' @{ DisplayName = '7-Zip 24.08 (x64)'; DisplayVersion = '24.08'; UninstallString = 'C:\Program Files\7-Zip\Uninstall.exe' }
    $f = Get-PreExistingInstall -Names @('7-Zip') @probe
    Test-Check 'detection: an EXE installer (name with a version after it) is found, origin EXE' ($f.Machine -and $f.Origin -eq 'EXE') ($f | ConvertTo-Json -Compress)

    # ---- per user: two profiles with a copy (one in its uninstall key, one in AppData\Local\Programs), machine-wide not there
    New-Arp "$base\User1" 'Chrome' @{ DisplayName = 'Google Chrome'; DisplayVersion = '130.0' }
    New-Item -ItemType Directory -Path (Join-Path $temp 'Users\bob\AppData\Local\Programs\Google Chrome') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $temp 'Users\ann\AppData\Local\Programs\Other') -Force | Out-Null
    $userProbe = @{ MachineKeys = @("$base\EmptyMachine\*"); UserKeys = @("$base\User1\*", "$base\User2\*"); ProgramsRoots = @((Join-Path $temp 'Users\bob\AppData\Local\Programs'), (Join-Path $temp 'Users\ann\AppData\Local\Programs')) }
    $f = Get-PreExistingInstall -Names @('Google Chrome') @userProbe
    Test-Check 'detection: per-user copies are counted (registry of loaded profiles and Local\Programs), not machine-wide' (-not $f.Machine -and $f.UserCopies -eq 1) ($f | ConvertTo-Json -Compress)
    New-Arp "$base\User2" 'Chrome' @{ DisplayName = 'Google Chrome'; DisplayVersion = '129.0' }
    $f = Get-PreExistingInstall -Names @('Google Chrome') @userProbe
    Test-Check 'detection: the larger count of the two places is the number of profiles' ($f.UserCopies -eq 2) ($f | ConvertTo-Json -Compress)

    # ---- the record (adopted machine install)
    $app = Join-Path $temp 'AppAdopt'; New-Item -ItemType Directory -Path $app | Out-Null
    $rec = Save-PreExistingRecord $app @('Google Chrome', 'Chrome') $false 'winget' '' $probe
    $file = Get-Content (Join-Path $app 'preexisting.json') -Raw | ConvertFrom-Json
    Test-Check 'adopted: machine-scope MSI recorded as preExisting with version, scope, origin and date, logged as adopted' ($file.preExisting -eq $true -and $file.scope -eq 'machine' -and $file.origin -eq 'MSI' -and $file.version -eq '131.0.1' -and $file.date -and (@($script:DeviceLog) -join '|') -match 'adopted: Google Chrome') ($file | ConvertTo-Json -Compress)
    $second = Save-PreExistingRecord $app @('Google Chrome') $false 'winget' '' $probe
    Test-Check 'the record is written once (a second run changes nothing)' ($null -eq $second)
    $appOld = Join-Path $temp 'AppOldInstall'; New-Item -ItemType Directory -Path $appOld | Out-Null
    Set-Content (Join-Path $appOld 'config.json') '{}'
    $none = Save-PreExistingRecord $appOld @('Google Chrome') $false 'winget' '' $probe
    Test-Check 'an app folder of an earlier PackTune install is ours: nothing is recorded, nothing is mistaken for pre-existing' ($null -eq $none -and -not (Test-Path (Join-Path $appOld 'preexisting.json')))
    # winget/choco outside PackTune (no ARP entry matched): origin is the tool
    $app2 = Join-Path $temp 'AppWingetOnly'; New-Item -ItemType Directory -Path $app2 | Out-Null
    $r2 = Save-PreExistingRecord $app2 @('Nothing Matching') $true 'winget' '' $probe
    Test-Check 'a product winget lists without a matching uninstall entry counts as pre-existing, origin winget' ($r2.preExisting -and $r2.origin -eq 'winget') ($r2 | ConvertTo-Json -Compress)

    # ---- user copy only: PackTune installs machine-wide, the user copy is reported and never touched
    $app3 = Join-Path $temp 'AppUserOnly'; New-Item -ItemType Directory -Path $app3 | Out-Null
    $script:DeviceLog.Clear()
    $r3 = Save-PreExistingRecord $app3 @('Google Chrome') $false 'winget' '' $userProbe
    Test-Check 'user-scope copy: not pre-existing (machine-wide install follows), reported as user copies in 2 profiles' (-not $r3.preExisting -and $r3.scope -eq 'user' -and $r3.userCopies -eq 2 -and (@($script:DeviceLog) -join '|') -match 'also installed per user for 2 profile') ($r3 | ConvertTo-Json -Compress)
    Test-Check 'user-scope copy: an uninstall removes PackTune''s machine copy (no pre-existing machine software)' (-not (Test-KeepPreExisting $app3 'PackTune'))

    # ---- uninstall decision
    Test-Check 'uninstall default (remove only what PackTune installed): a pre-existing installation is kept' (Test-KeepPreExisting $app 'PackTune')
    Test-Check 'uninstall with "also remove a pre-existing installation": it is removed' (-not (Test-KeepPreExisting $app 'All'))
    Test-Check 'uninstall: an app PackTune installed itself (no record) is removed' (-not (Test-KeepPreExisting (Join-Path $temp 'NoRecord') 'PackTune'))

    # ---- the result file carries it for the status script
    $ResultFile = Join-Path $app 'last-result.json'; $LogId = 'google.chrome'
    Save-LastResult 'adopt' 'ok' 0 'adopted' '131.0.1'
    $res = Get-Content $ResultFile -Raw | ConvertFrom-Json
    Test-Check 'last-result.json: preExisting, userCopies and origin are part of every result' ($res.preExisting -eq $true -and $res.userCopies -eq 0 -and $res.origin -eq 'MSI' -and $res.cause -eq 'adopted')
    $ResultFile = Join-Path $app3 'last-result.json'; $LogId = 'user.only'
    Save-LastResult 'install' 'ok' 0 'ok' '1.0'
    $res3 = Get-Content $ResultFile -Raw | ConvertFrom-Json
    Test-Check 'last-result.json: a user copy is reported with the number of profiles' ($res3.preExisting -eq $false -and $res3.userCopies -eq 2)
}
finally { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }

# ---- the status script (Remediations) and what PackTune reads from it
$chocoRoot = Join-Path $temp 'choco'; $wingetRoot = Join-Path $temp 'winget'
foreach ($case in @(@('adopted.app', $true, 0), @('usercopy.app', $false, 3), @('plain.app', $false, 0), @('both.app', $true, 2))) {
    $dir = Join-Path $chocoRoot $case[0]; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    @{ lastAttempt = '2026-11-14T07:00:00Z'; action = 'install'; status = 'ok'; exitCode = 0; cause = 'ok'; installedVersion = '1.2.3'; targetVersion = ''; preExisting = $case[1]; userCopies = $case[2] } | ConvertTo-Json | Set-Content (Join-Path $dir 'last-result.json')
}
$dir = Join-Path $wingetRoot 'bad.app'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
@{ lastAttempt = '2026-11-14T07:00:00Z'; action = 'upgrade'; status = 'failed'; exitCode = 1603; cause = 'failed: exit code 1603'; installedVersion = '1.0'; targetVersion = '2.0'; preExisting = $true; userCopies = 1 } | ConvertTo-Json | Set-Content (Join-Path $dir 'last-result.json')
$scriptFile = Join-Path $temp 'status.ps1'; Set-Content $scriptFile (Get-InsightStatusScriptText) -Encoding ASCII
$out = (& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $scriptFile -ChocoRoot $chocoRoot -WingetRoot $wingetRoot -OldChocoRoot (Join-Path $temp 'x1') -OldWingetRoot (Join-Path $temp 'x2') | Out-String).Trim()
$j = $out | ConvertFrom-Json
Test-Check 'status script: adopted and user copies are short flags on the good entries, below the output limit' ($out.Length -lt 2048 -and (@($j.o) -contains 'adopted.app=1.2.3~A') -and (@($j.o) -contains 'usercopy.app=1.2.3~U3') -and (@($j.o) -contains 'both.app=1.2.3~A~U2') -and (@($j.o) -contains 'plain.app=1.2.3')) $out
Test-Check 'status script: a failed app carries pe and uc' ((@($j.f)[0].pe -eq 1) -and (@($j.f)[0].uc -eq 1)) $out
$run = ConvertFrom-InsightRunState ([pscustomobject]@{ managedDevice = [pscustomobject]@{ deviceName = 'PC-1'; userPrincipalName = 'a@x.test'; id = 'm1' }; detectionState = 'success'; lastStateUpdateDateTime = '2026-11-14T08:00:00Z'; preRemediationDetectionScriptOutput = $out })
$ad = @($run.Apps | Where-Object Package -eq 'adopted.app')[0]; $uc = @($run.Apps | Where-Object Package -eq 'usercopy.app')[0]; $bo = @($run.Apps | Where-Object Package -eq 'both.app')[0]; $pl = @($run.Apps | Where-Object Package -eq 'plain.app')[0]; $bad = @($run.Apps | Where-Object Package -eq 'bad.app')[0]
Test-Check 'the device view reads it: pre-existing (adopted) and the number of user copies per app, version unchanged' ($ad.PreExisting -and $ad.InstalledVersion -eq '1.2.3' -and $uc.UserCopies -eq 3 -and -not $uc.PreExisting -and $bo.PreExisting -and $bo.UserCopies -eq 2 -and -not $pl.PreExisting -and $pl.UserCopies -eq 0 -and $bad.PreExisting -and $bad.UserCopies -eq 1)

# ---- the setting: policy, fingerprint, notes
$p0 = New-PackTuneAppPolicy -Package 'googlechrome'
$p1 = New-PackTuneAppPolicy -Package 'googlechrome' -UninstallScope All
Test-Check 'setting: default is "remove only what PackTune installed", the other value changes the fingerprint' ($p0.UninstallScope -eq 'PackTune' -and $p1.UninstallScope -eq 'All' -and $p0.Fingerprint -ne $p1.Fingerprint)
$n0 = ConvertTo-PackTuneAppNotes -Policy $p0; $n1 = ConvertTo-PackTuneAppNotes -Policy $p1
Test-Check 'setting: only the non-default value is stored in the notes and read back' ($n0 -notlike '*uninstall=*' -and $n1 -like '*;uninstall=all*' -and (ConvertFrom-PackTuneAppNotes $n0).UninstallScope -eq 'PackTune' -and (ConvertFrom-PackTuneAppNotes $n1).UninstallScope -eq 'All' -and (ConvertFrom-PackTuneAppNotes 'PoweredByPackTune;from=winget;package=A.B;version=latest').UninstallScope -eq 'PackTune')
Test-Check 'setting: the device script revision was raised for it' ($script:DeviceScriptRevision -ge 12)
$bad = ''; try { $null = New-PackTuneAppPolicy -Package 'x' -UninstallScope 'Everything' } catch { $bad = $_.Exception.Message }
Test-Check 'setting: an unknown value is refused' ($bad -ne '')

# ---- the generated install scripts
foreach ($case in @(@('Chocolatey', 'googlechrome'), @('Winget', 'Google.Chrome'))) {
    foreach ($scope in 'PackTune', 'All') {
        $src = Join-Path $temp "src-$($case[0])-$scope"; New-Item -ItemType Directory -Path $src | Out-Null
        $policy = New-PackTuneAppPolicy -Package $case[1] -UninstallScope $scope
        if ($case[0] -eq 'Winget') { $null = New-WingetPackageScripts -WingetId $case[1] -SourcePath $src -Policy $policy -DisplayName 'Google Chrome' }
        else { $null = New-ChocoPackageScripts -ChocoName $case[1] -SourcePath $src -Policy $policy -DisplayName 'Google Chrome' }
        $text = Get-Content (Join-Path $src 'install.ps1') -Raw
        $errors = $null; [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $ok = ($errors.Count -eq 0) -and $text -notmatch '[^\x00-\x7F]' -and $text -notmatch '__[A-Z]+__' -and $text -match "\[string\]\`$UninstallScope = '$scope'" -and $text -match 'function Save-PreExistingRecord' -and $text -match 'Test-KeepPreExisting \$AppRoot \$UninstallScope' -and $text -match 'Save-PreExistingRecord \$AppRoot'
        Test-Check "$($case[0]) install.ps1 with On uninstall = ${scope}: valid, ASCII, no placeholder, checks before the first install and decides on uninstall" $ok ($errors | ForEach-Object Message)
    }
}

Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
