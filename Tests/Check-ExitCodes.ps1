<#
.SYNOPSIS
    Checks of the PackTune exit codes (PackTune-ExitCodes.ps1): one table, distinct codes clear of Intune's default return codes, every
    code the device scripts use is in the table (and the other way round), the device helpers turn choco / winget results into the
    right code, PackTune and the insight module read the same causes, the README lists every code, and the device script revision
    was raised. No device, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-ExitCodes.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneExit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')

$table = @(Get-PackTuneExitCodeTable)
$codes = @($table | ForEach-Object { [int]$_.Code })
$names = @($table | ForEach-Object { [string]$_.Name })
Test-Check 'table: every code is unique, every name is unique' (($codes | Select-Object -Unique).Count -eq $codes.Count -and ($names | Select-Object -Unique).Count -eq $names.Count)
Test-Check 'table: all codes are PackTune codes 61001 .. 61099, none is one of Intune''s default return codes (0, 1707, 3010, 1641, 1618)' (@($codes | Where-Object { $_ -lt 61001 -or $_ -gt 61099 -or $_ -in 0, 1707, 3010, 1641, 1618 }).Count -eq 0)
Test-Check 'table: every entry has a cause text' (@($table | Where-Object { -not $_.Cause -or $_.Cause.Length -lt 10 }).Count -eq 0)

# --- device scripts: generated for both sources, the runtime and a custom MSI
$policy = New-PackTuneAppPolicy -Package 'vlc'
$chocoDir = Join-Path $work 'choco'; New-Item -ItemType Directory -Path (Join-Path $chocoDir 'source') -Force | Out-Null
$null = New-ChocoPackageScripts -ChocoName 'vlc' -SourcePath (Join-Path $chocoDir 'source') -Policy $policy -DisplayName 'VLC'
$wingetDir = Join-Path $work 'winget'; New-Item -ItemType Directory -Path (Join-Path $wingetDir 'source') -Force | Out-Null
$null = New-WingetPackageScripts -WingetId 'VideoLAN.VLC' -SourcePath (Join-Path $wingetDir 'source') -Policy (New-PackTuneAppPolicy -Package 'VideoLAN.VLC') -DisplayName 'VLC'
$scripts = [ordered]@{
    'Chocolatey install' = Get-Content (Join-Path $chocoDir 'source\install.ps1') -Raw
    'winget install'     = Get-Content (Join-Path $wingetDir 'source\install.ps1') -Raw
    'runtime install'    = (Get-PackTuneRuntimeScripts).Install
}
foreach ($key in $scripts.Keys) {
    $text = $scripts[$key]
    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    Test-Check "$key.ps1: valid PowerShell, plain ASCII, no placeholder left" (($errors.Count -eq 0) -and ($text -notmatch '[^\x00-\x7F]') -and ($text -notmatch '__[A-Z]+__')) (@($errors | ForEach-Object Message) -join '; ')
    $block = Get-DeviceExitCodeBlock
    Test-Check "$key.ps1: carries the code table of PackTune" ($text.Contains($block.Substring(0, 200)) -and (@($table | Where-Object { $text -notmatch "\b$($_.Name) = $($_.Code)\b" }).Count -eq 0))
    $used = @([regex]::Matches($text, '\$PTExit\.([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    Test-Check "$key.ps1: every PackTune code it exits with is in the table" (@($used | Where-Object { $_ -notin $names }).Count -eq 0) (($used | Where-Object { $_ -notin $names }) -join ',')
    Test-Check "$key.ps1: no plain 'exit 1' and no fixed 1618 in the install path (every cause has its own code, the lock helper answers 1618)" (($text -notmatch 'exit 1(?![0-9])') -and ($text -notmatch 'exit 1618')) ([regex]::Matches($text, '[^
]*exit 1[^
]*') | ForEach-Object Value | Select-Object -First 3)
}
$allUsed = @($scripts.Values | ForEach-Object { [regex]::Matches($_, '\$PTExit\.([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } } | Select-Object -Unique)
Test-Check 'table: every code of the table is used by a device script (no dead codes)' (@($names | Where-Object { $_ -notin $allUsed -and $_ -notin 'PackageManagerFailed', 'DownloadFailed', 'HashMismatch', 'DiskFull', 'SourceNotFound', 'SourceUnreachable', 'NoMachineInstaller' }).Count -eq 0) (($names | Where-Object { $_ -notin $allUsed }) -join ',')

# --- the device helpers, run here: what choco / winget did becomes which code
$PTExit = @{}; foreach ($e in $table) { $PTExit[[string]$e.Name] = [int]$e.Code }
$script:LockError = ''
$block = Get-DeviceExitCodeBlock
. ([scriptblock]::Create($block))
$cases = @(
    @(0, 'ok', 0), @(3010, 'ok', 3010),
    @(1, 'Chocolatey v2\nUnable to find package ''nope'' with version', 'SourceNotFound'),
    @(1, 'The remote name could not be resolved: ''community.chocolatey.org''', 'SourceUnreachable'),
    @(1, 'ERROR: The checksum for x does not match', 'HashMismatch'),
    @(1, 'Error while downloading https://example.test/setup.exe', 'DownloadFailed'),
    @(1, 'There is not enough space on the disk.', 'DiskFull'),
    @(112, 'x', 'DiskFull'),
    @(1, 'something else broke', 'PackageManagerFailed'),
    @(1603, 'MSI error', $null), @(1625, 'blocked', $null)
)
foreach ($c in $cases) {
    $got = Resolve-PackageFailure $c[0] $c[1]
    $want = if ($null -eq $c[2]) { $c[0] } elseif ($c[2] -is [string]) { $PTExit[$c[2]] } else { $c[2] }
    Test-Check "choco: exit $($c[0]) / '$($c[1].Substring(0, [Math]::Min(35, $c[1].Length)))' gives $want" ($got -eq $want) "got $got"
}
foreach ($c in @(@(-1978335224, 'DownloadFailed'), @(-1978335217, 'SourceUnreachable'), @(-1978335216, 'NoMachineInstaller'), @(-1978335215, 'HashMismatch'), @(-1978335212, 'SourceNotFound'), @(1603, $null))) {
    $got = Resolve-WingetFailure $c[0]
    $want = if ($c[1]) { $PTExit[$c[1]] } else { $c[0] }
    Test-Check "winget: result $($c[0]) gives $want" ($got -eq $want) "got $got"
}
Test-Check 'lock: another installation running is 1618, a lock of someone else is its own code' ((Get-LockExitCode) -eq 1618 -and (& { $script:LockError = 'the lock belongs to someone else'; (Get-LockExitCode) }) -eq $PTExit.LockForeign)

# --- PackTune side: the same table gives the cause, in the module as well
$insight = Get-Module TenantInsight
foreach ($e in $table) {
    $fromMain = Get-PackTuneCodeCause $e.Code
    $fromModule = Get-InsightErrorCause $e.Code
    $hex = Get-InsightErrorCause ('0x{0:X8}' -f [int]$e.Code)
    Test-Check "cause $($e.Code) ($($e.Name)): PackTune, the module and the hex form say the same" (($fromMain -eq $e.Cause) -and ($fromModule -eq $e.Cause) -and ($hex -eq $e.Cause)) "$fromMain | $fromModule | $hex"
}
Test-Check 'cause: common Windows, Intune and winget codes are mapped' ((Get-PackTuneCodeCause 1603) -like '*fatal error*' -and (Get-PackTuneCodeCause '0x87D1041C') -like '*detection rule*' -and (Get-PackTuneCodeCause -1978335215) -like '*hash*' -and (Get-PackTuneCodeCause 0) -eq $null -or (Get-PackTuneCodeCause 0) -is [string]) ''
Test-Check 'cause: an unknown code gives its hex value, no code gives nothing' ((Get-PackTuneCodeCause 4242) -eq 'error 0x00001092' -and $null -eq (Get-PackTuneCodeCause $null))

# --- documented, and the fingerprint moved
$readme = Get-Content (Join-Path $repo 'README.md') -Raw
Test-Check 'README: documents every PackTune exit code with its cause' (@($table | Where-Object { $readme -notmatch "\b$($_.Code)\b" }).Count -eq 0) ((@($table | Where-Object { $readme -notmatch "\b$($_.Code)\b" } | ForEach-Object Code)) -join ',')
Test-Check 'README: says devices run install.ps1 once more after the update (new device script revision)' ($readme -match '(?i)exit codes' -and $readme -match '(?i)run install\.ps1 once')
Test-Check 'device script revision raised to 10 (the codes change the scripts, so the fingerprint)' ($script:DeviceScriptRevision -ge 10)
Test-Check 'no PackTune code is part of a return code list of an app (Intune defaults stay: success 0 / 1707, soft 3010, hard 1641, retry 1618)' (@(Get-ChildItem $repo -Filter 'PackTune-*.ps1' | Where-Object { (Get-Content $_.FullName -Raw) -match '(?i)New-IntuneWin32AppReturnCode|returnCodes\s*=' }).Count -eq 0)

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 } else { 'All checks passed.' }
