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
