# Helpers of the Win32 test lab (inside the sandbox): run an Intune command line the way the Intune Management Extension
# does, as SYSTEM through a scheduled task. Plain ASCII: Windows PowerShell 5.1 reads scripts without a byte order mark
# in the local code page.

function ConvertTo-LabCommandLine {
    # Intune runs commands from a 32-bit process on 64-bit Windows, so packages use %SystemRoot%\sysnative to reach 64-bit
    # PowerShell. A 64-bit process has no sysnative folder: it becomes System32 there.
    param([Parameter(Mandatory = $true)][string]$CommandLine)
    $line = [Environment]::ExpandEnvironmentVariables($CommandLine)
    if ([Environment]::Is64BitProcess) { $line = $line -replace '(?i)\\sysnative\\', '\System32\' }
    $line
}

function Start-LabCommand {
    # Starts a command line in the background (working directory = package content, as in Intune); -AsSystem runs it as
    # SYSTEM through a scheduled task. Get-LabCommandResult returns $null while it runs, then ExitCode, Output, Seconds.
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [switch]$AsSystem,
        [string]$Root = (Join-Path $env:ProgramData 'PackTuneLab')
    )
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = Join-Path $Root $id
    New-Item -ItemType Directory $dir -Force | Out-Null
    $line = ConvertTo-LabCommandLine $CommandLine
    $wrapper = Join-Path $dir 'run.ps1'
    # The wrapper runs the command through cmd.exe (Intune command lines are cmd syntax) and records the result
    @"
`$ErrorActionPreference = 'Continue'
`$started = Get-Date
Set-Location -LiteralPath '$($WorkingDirectory.Replace("'", "''"))'
`$p = Start-Process cmd.exe -ArgumentList '/c "$($line.Replace("'", "''"))"' -Wait -PassThru -NoNewWindow ``
    -RedirectStandardOutput '$dir\stdout.txt' -RedirectStandardError '$dir\stderr.txt'
@{ ExitCode = `$p.ExitCode; Seconds = [math]::Round(((Get-Date) - `$started).TotalSeconds, 1); User = [Environment]::UserName } |
    ConvertTo-Json | Set-Content '$dir\result.json' -Encoding UTF8
"@ | Set-Content $wrapper -Encoding UTF8

    $handle = [pscustomobject]@{ Id = $id; Dir = $dir; CommandLine = $line; AsSystem = [bool]$AsSystem; Task = $null; Process = $null; Started = Get-Date }
    if ($AsSystem) {
        $name = "PackTuneLab_$id"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapper`""
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $name
        $handle.Task = $name
    }
    else {
        $handle.Process = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$wrapper`"" -PassThru
    }
    $handle
}

function Get-LabCommandResult {
    # $null while the command runs; afterwards ExitCode, Output (stdout and stderr), StdOut, Seconds, User. Removes the task.
    param([Parameter(Mandatory = $true)]$Handle)
    $resultFile = Join-Path $Handle.Dir 'result.json'
    if (-not (Test-Path $resultFile)) {
        # The wrapper itself failed (the task did not start): give up once the process or task is gone
        $gone = if ($Handle.Process) { $Handle.Process.HasExited } else {
            $t = Get-ScheduledTask -TaskName $Handle.Task -ErrorAction SilentlyContinue
            $t -and $t.State -ne 'Running' -and ((Get-Date) - $Handle.Started).TotalSeconds -gt 10
        }
        if (-not $gone) { return $null }
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $resultFile)) { return [pscustomobject]@{ ExitCode = -1; Output = 'The command could not be started.'; StdOut = ''; Seconds = 0; User = '' } }
    }
    $r = $null
    try { $r = Get-Content $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }   # still being written
    $read = {
        param($name)
        $p = Join-Path $Handle.Dir $name
        if (Test-Path $p) { "$(Get-Content $p -Raw -ErrorAction SilentlyContinue)".Trim() } else { '' }
    }
    $stdout = & $read 'stdout.txt'
    $stderr = & $read 'stderr.txt'
    if ($Handle.Task) { Unregister-ScheduledTask -TaskName $Handle.Task -Confirm:$false -ErrorAction SilentlyContinue }
    # StdOut separately: the script detection of Intune only counts output on STDOUT
    [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Output = (@($stdout, $stderr) | Where-Object { $_ }) -join "`n"; StdOut = $stdout; Seconds = $r.Seconds; User = $r.User }
}

function Stop-LabCommand {
    # Ends a running command with everything it started (a setup that waits for input in the invisible SYSTEM session)
    param([Parameter(Mandatory = $true)]$Handle)
    if ($Handle.Task) {
        $wrapper = Join-Path $Handle.Dir 'run.ps1'
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($wrapper, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
            ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
        Stop-ScheduledTask -TaskName $Handle.Task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Handle.Task -Confirm:$false -ErrorAction SilentlyContinue
    }
    elseif ($Handle.Process -and -not $Handle.Process.HasExited) { & taskkill.exe /PID $Handle.Process.Id /T /F 2>&1 | Out-Null }
}

function Test-LabSuccessCode {
    # The Intune default return codes: 0 and 1707 success, 3010 soft reboot, 1641 hard reboot (all count as installed)
    param([int]$ExitCode, [int[]]$SuccessCodes = @(0, 1707, 3010, 1641))
    $SuccessCodes -contains $ExitCode
}

# ---------------------------------------------------------------- the sequence and its verdict (also checked outside the sandbox)

function New-LabPlan {
    # The steps of a run, in the order Intune goes through them: detection before the install (a detected app is not installed
    # at all), install, detection, with a previous version the update path (previous version in, detected, update, detected),
    # uninstall, detection. Target tells which package folder the step uses: 'previous' or 'new'.
    param([string]$Version = '', [string]$PreviousVersion = '', [bool]$HasPrevious = $false)
    $steps = New-Object System.Collections.ArrayList
    $add = {
        param($Kind, $Target, $Title, $Expect, $ExpectDetected)
        [void]$steps.Add([pscustomobject]@{ Index = $steps.Count + 1; Kind = $Kind; Target = $Target; Title = $Title; Expect = $Expect; ExpectDetected = $ExpectDetected
            State = 'NotRun'; ExitCode = $null; Detected = $null; Detail = ''; Output = ''; Seconds = $null; User = ''; Screenshot = ''; Finding = '' })
    }
    $first = if ($HasPrevious) { 'previous' } else { 'new' }
    & $add 'Detect' $first 'Detect before the install' 'not detected' $false
    if ($HasPrevious) {
        & $add 'Install' 'previous' "Install the previous version$(if ($PreviousVersion) { " $PreviousVersion" })" 'success code' $null
        & $add 'Detect' 'previous' 'Detect the previous version' 'detected' $true
        & $add 'Install' 'new' "Update to $(if ($Version) { $Version } else { 'the new version' })" 'success code' $null
        & $add 'Detect' 'new' 'Detect after the update' 'detected' $true
    }
    else {
        & $add 'Install' 'new' "Install$(if ($Version) { " $Version" })" 'success code' $null
        & $add 'Detect' 'new' 'Detect after the install' 'detected' $true
    }
    & $add 'Uninstall' 'new' 'Uninstall' 'success code' $null
    & $add 'Detect' 'new' 'Detect after the uninstall' 'not detected' $false
    , @($steps)
}

function Set-LabStepResult {
    # Judges one finished step against what Intune expects: exit code of an install/uninstall, detection (script rule: exit code 0
    # and output on STDOUT). Detail always says expected and actual; a step that failed ends a run.
    param([Parameter(Mandatory = $true)]$Step, [Parameter(Mandatory = $true)]$Result)
    $Step.Seconds = $Result.Seconds; $Step.User = $Result.User; $Step.Output = $Result.Output; $Step.ExitCode = $Result.ExitCode
    $took = if ($null -ne $Result.Seconds) { " in $($Result.Seconds) s" } else { '' }
    if ($Result.PSObject.Properties['Cancelled'] -and $Result.Cancelled) {
        $Step.State = 'Failed'; $Step.Detail = "Expected: $($Step.Expect). Actual: cancelled$took."
    }
    elseif ($Step.Kind -eq 'Detect') {
        $stdout = if ($Result.PSObject.Properties['StdOut']) { $Result.StdOut } else { $Result.Output }
        $detected = ($Result.ExitCode -eq 0) -and [bool]$stdout
        $Step.Detected = $detected
        $Step.State = if ($detected -eq $Step.ExpectDetected) { 'Passed' } else { 'Failed' }
        $Step.Detail = "Expected: $($Step.Expect). Actual: $(if ($detected) { 'detected' } else { 'not detected' }) (exit code $($Result.ExitCode))$took."
        if ($Step.State -eq 'Failed' -and $Step.Index -eq 1 -and $detected) {
            $Step.Finding = 'Already detected before the install: Intune would skip the install.'
            $Step.Detail = "Expected: not detected. Actual: detected (exit code $($Result.ExitCode))$took. Already detected: Intune would skip the install."
        }
    }
    else {
        $Step.State = if (Test-LabSuccessCode $Result.ExitCode) { 'Passed' } else { 'Failed' }
        $Step.Detail = "Expected: $($Step.Expect). Actual: exit code $($Result.ExitCode)$took$(if ($Result.User) { " as $($Result.User)" })" + $(switch ($Result.ExitCode) { 3010 { ' (soft reboot required)' } 1641 { ' (hard reboot initiated)' } default { '' } }) + '.'
    }
    $Step
}

function Get-LabSummary {
    # Verdict of a run: Passed when every step passed; Failed at the first step that did not, with its cause; Failed when the run stopped early.
    param([Parameter(Mandatory = $true)]$Steps)
    $bad = @($Steps | Where-Object { $_.State -eq 'Failed' }) | Select-Object -First 1
    if ($bad) {
        $cause = if ($bad.Finding) { $bad.Finding } else { $bad.Detail }
        return [pscustomobject]@{ Verdict = 'Failed'; Message = "Failed at step $($bad.Index) of $(@($Steps).Count) ($($bad.Title)): $cause" }
    }
    $open = @($Steps | Where-Object { $_.State -ne 'Passed' }) | Select-Object -First 1
    if ($open) { return [pscustomobject]@{ Verdict = 'Failed'; Message = "Stopped before step $($open.Index) of $(@($Steps).Count) ($($open.Title))." } }
    [pscustomobject]@{ Verdict = 'Passed'; Message = "All $(@($Steps).Count) steps passed: $((@($Steps) | ForEach-Object { $_.Title.ToLower() }) -join ', ')." }
}
