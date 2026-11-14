# Win32 test lab: a small panel INSIDE the sandbox that tries a package the way Intune would.
#   Install -> Detect (expect detected) -> Uninstall -> Detect (expect not detected)
# Every step runs with one click as SYSTEM through a scheduled task (like the Intune Management Extension) and shows exit
# code or detection result and the output. "Finish: success" or "Report failure" ends the session, reports to the host
# and closes the sandbox. With AutoRun in job.json all steps run by themselves and the verdict follows from them.
# Plain ASCII: Windows PowerShell 5.1 reads scripts without a byte order mark in the local code page.
param(
    [string]$JobDir = 'C:\PackTuneSandbox\Job',
    [string]$LocalDir = 'C:\PackTuneSandboxLocal'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'LabShared.ps1')

$OutDir = Join-Path $JobDir 'out'
$LabOut = Join-Path $OutDir 'lab'
$Source = Join-Path $LocalDir 'input\source'
$PreviousSource = Join-Path $LocalDir 'input\source-previous'
$ShotDir = Join-Path $env:TEMP 'packtune\labshots'
New-Item -ItemType Directory $ShotDir -Force | Out-Null
$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Started = Get-Date
$script:Running = $null
$script:Closing = $false
$script:Queue = New-Object System.Collections.ArrayList

$hasPrevious = [bool]$job.HasPrevious
$steps = @(New-LabPlan -Version $job.Version -PreviousVersion $job.PreviousVersion -HasPrevious $hasPrevious)[0]
# Intune runs the commands from the package folder; detection scripts run 64-bit in the system context
$ps = '"%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File'
$commands = @{ Install = "$ps "".\Install.ps1"""; Uninstall = "$ps "".\Uninstall.ps1"""; Detect = "$ps "".\Detect.ps1""" }

# ---------------------------------------------------------------- panel
$C = @{
    Back = [System.Drawing.ColorTranslator]::FromHtml('#F6F7F9'); Text = [System.Drawing.ColorTranslator]::FromHtml('#1B1F23'); Muted = [System.Drawing.ColorTranslator]::FromHtml('#5F6B76')
    Primary = [System.Drawing.ColorTranslator]::FromHtml('#2563EB'); Success = [System.Drawing.ColorTranslator]::FromHtml('#16803C'); Danger = [System.Drawing.ColorTranslator]::FromHtml('#B42318')
    Idle = [System.Drawing.ColorTranslator]::FromHtml('#E5E8EC'); Ok = [System.Drawing.ColorTranslator]::FromHtml('#D7F0DF'); Bad = [System.Drawing.ColorTranslator]::FromHtml('#F8D7D3'); Run = [System.Drawing.ColorTranslator]::FromHtml('#DCE7FD')
}
function New-LabButton([string]$Text, $Color, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.BackColor = $Color; $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $b
}
function New-LabLabel([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [float]$Size = 9.5, $Color = $C.Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size); $l.ForeColor = $Color
    $l
}
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PackTune test lab'; $form.StartPosition = 'CenterScreen'; $form.ClientSize = New-Object System.Drawing.Size(780, 600); $form.BackColor = $C.Back
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Controls.Add((New-LabLabel "$($job.DisplayName) $($job.Version)" 16 12 740 28 14))
$info = New-LabLabel 'Run the steps one by one, or all at once. They run as SYSTEM, like on a managed device.' 16 44 740 22 9.5 $C.Muted
$form.Controls.Add($info)
$rows = @{}
foreach ($s in $steps) {
    $y = 74 + ($s.Index - 1) * 40
    $num = New-LabLabel "$($s.Index)" 16 $y 28 28 10 $C.Text
    $title = New-LabLabel $s.Title 52 ($y + 3) 330 24 10.5
    $chip = New-LabLabel 'not run' 390 ($y + 3) 220 24 9.5 $C.Text
    $chip.BackColor = $C.Idle; $chip.TextAlign = 'MiddleCenter'
    $run = New-LabButton 'Run' $C.Primary 630 ($y - 2) 120 30
    $form.Controls.AddRange(@($num, $title, $chip, $run))
    $rows[$s.Index] = @{ Chip = $chip; Run = $run }
}
$output = New-Object System.Windows.Forms.TextBox
$output.Multiline = $true; $output.ReadOnly = $true; $output.ScrollBars = 'Vertical'; $output.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$output.Location = New-Object System.Drawing.Point(16, 366); $output.Size = New-Object System.Drawing.Size(740, 160)
$form.Controls.Add($output)
$btnAll = New-LabButton 'Run all steps' $C.Primary 16 540 240 44
$btnFail = New-LabButton 'Report failure' $C.Danger 270 540 240 44
$btnOk = New-LabButton 'Finish: success' $C.Success 524 540 232 44
$form.Controls.AddRange(@($btnAll, $btnFail, $btnOk))

# ---------------------------------------------------------------- behavior
function Write-JobStatus([string]$State, [string]$Step, [string]$Message = '', $Result = $null) {
    $status = [ordered]@{ State = $State; Step = $Step; Message = $Message; Result = $Result; Updated = (Get-Date).ToString('o') }
    $tmp = Join-Path $JobDir 'status.tmp'
    $status | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp (Join-Path $JobDir 'status.json') -Force
}

function Set-StepView($s) {
    $r = $rows[$s.Index]
    $look = @{ NotRun = @('not run', $C.Idle); Running = @('running ...', $C.Run); Passed = @('passed', $C.Ok); Failed = @('failed', $C.Bad) }[$s.State]
    $text = $look[0]
    if ($s.State -in 'Passed', 'Failed') {
        $text = if ($s.Kind -eq 'Detect') { if ($s.Detected) { 'detected' } else { 'not detected' } } else { "exit $($s.ExitCode)" }
        if ($null -ne $s.Seconds) { $text += "  $($s.Seconds) s" }
    }
    $r.Chip.Text = $text; $r.Chip.BackColor = $look[1]
    $r.Run.Text = switch ($s.State) { 'NotRun' { 'Run' } 'Running' { 'Cancel' } default { 'Run again' } }
    $r.Run.BackColor = if ($s.State -eq 'Running') { $C.Danger } else { $C.Primary }
}

function Show-StepOutput($s) { $output.Text = "Step $($s.Index): $($s.Title)`r`n$($s.Detail)`r`n`r`n$($s.Output -replace "`r?`n", "`r`n")" }

function Update-Summary {
    $passed = @($steps | Where-Object State -eq 'Passed').Count
    $failed = @($steps | Where-Object State -eq 'Failed').Count
    $info.Text = "$passed of $($steps.Count) steps passed" + $(if ($failed) { ". $((Get-LabSummary $steps).Message)" } else { '.' })
}

function Complete-LabStep($s, $r) {
    [void](Set-LabStepResult -Step $s -Result $r)
    # A step that did not give the expected result ends the run
    if ($s.State -eq 'Failed') { $script:Queue.Clear() }
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $name = "step-$($s.Index)-$(Get-Date -Format 'HHmmss').png"
        $bmp.Save((Join-Path $ShotDir $name), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        $s.Screenshot = $name
    }
    catch { }
    Set-StepView $s
    Show-StepOutput $s
    Update-Summary
}

function Start-LabStep([int]$Index) {
    if ($script:Running) {
        if ($script:Running.Step.Index -eq $Index) { Stop-LabStep }
        return
    }
    $s = $steps[$Index - 1]
    $s.State = 'Running'; $s.Output = ''; $s.Detail = ''
    Set-StepView $s
    $info.Text = "Running step $($s.Index): $($s.Title) ..."
    try { $script:Running = @{ Step = $s; Handle = (Start-LabCommand -CommandLine $commands[$s.Kind] -WorkingDirectory $(if ($s.Target -eq 'previous') { $PreviousSource } else { $Source }) -AsSystem) } }
    catch {
        $script:Running = $null
        $s.State = 'Failed'; $s.Detail = 'The step could not be started'; $s.Output = $_.Exception.Message
        Set-StepView $s; Show-StepOutput $s; Update-Summary
    }
}

function Stop-LabStep {
    $running = $script:Running
    if (-not $running) { return }
    $script:Running = $null
    $script:Queue.Clear()
    Stop-LabCommand $running.Handle
    Complete-LabStep $running.Step ([pscustomobject]@{ ExitCode = $null; Output = 'Cancelled in the test lab.'; StdOut = ''; Seconds = [math]::Round(((Get-Date) - $running.Handle.Started).TotalSeconds, 1); User = ''; Cancelled = $true })
}

function Save-LabResults([string]$Verdict, [string]$Notes) {
    New-Item -ItemType Directory $LabOut -Force | Out-Null
    if (Test-Path $ShotDir) { Copy-Item $ShotDir (Join-Path $LabOut 'shots') -Recurse -Force }
    [ordered]@{ Verdict = $Verdict; Notes = $Notes; Started = $script:Started.ToString('o'); Finished = (Get-Date).ToString('o'); Steps = @($steps) } |
        ConvertTo-Json -Depth 6 | Set-Content (Join-Path $LabOut 'results.json') -Encoding UTF8
}

function Close-Lab([string]$Verdict, [string]$Message) {
    if ($script:Running) { return }
    $script:Closing = $true
    $timer.Stop()
    Save-LabResults $Verdict $Message
    $result = [ordered]@{ Verdict = $Verdict; Notes = $Message; Steps = @($steps | ForEach-Object { [ordered]@{ Title = $_.Title; State = $_.State; ExitCode = $_.ExitCode; Detected = $_.Detected } }) }
    Write-JobStatus $(if ($Verdict -eq 'Passed') { 'Succeeded' } else { 'Failed' }) 'Done' $Message $result
    $form.Hide()
    Start-Sleep -Seconds 2
    shutdown.exe /s /t 0
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:Running) {
        $result = Get-LabCommandResult $script:Running.Handle
        if ($result) { $step = $script:Running.Step; $script:Running = $null; Complete-LabStep $step $result }
    }
    if (-not $script:Running -and $script:Queue.Count -gt 0) {
        $next = $script:Queue[0]; $script:Queue.RemoveAt(0)
        Start-LabStep $next
        return
    }
    $ended = @($steps | Where-Object State -eq 'NotRun').Count -eq 0 -or @($steps | Where-Object State -eq 'Failed').Count -gt 0
    if (-not $script:Running -and $job.AutoRun -and $script:Queue.Count -eq 0 -and -not $script:Closing -and $ended) {
        $v = Get-LabSummary $steps
        Close-Lab $v.Verdict $v.Message
    }
})

foreach ($s in $steps) { $idx = $s.Index; $rows[$idx].Run.Add_Click({ Start-LabStep $idx }.GetNewClosure()) }
$btnAll.Add_Click({ if (-not $script:Running) { $script:Queue.Clear(); 1..$steps.Count | ForEach-Object { [void]$script:Queue.Add($_) } } })
$btnOk.Add_Click({
    if ($script:Running) { [void][System.Windows.Forms.MessageBox]::Show($form, 'A step is still running.', 'PackTune test lab'); return }
    Close-Lab 'Passed' 'Reported as successful in the test lab.'
})
$btnFail.Add_Click({
    if ($script:Running) { [void][System.Windows.Forms.MessageBox]::Show($form, 'A step is still running.', 'PackTune test lab'); return }
    $reason = [Microsoft.VisualBasic.Interaction]::InputBox('What went wrong?', 'Report failure', '')
    Close-Lab 'Failed' $(if ($reason) { "Reported as failed: $reason" } else { 'Reported as failed in the test lab.' })
})
$form.Add_FormClosing({
    param($sender, $e)
    # Closing the window without a report: the host learns that the test was not finished
    if (-not $script:Closing) { $script:Closing = $true; $timer.Stop(); Save-LabResults 'Failed' 'The lab was closed without a report.'; Write-JobStatus 'Failed' 'Done' 'The lab was closed without a report.' }
})
$form.Add_Shown({
    $timer.Start()
    if ($job.AutoRun) { 1..$steps.Count | ForEach-Object { [void]$script:Queue.Add($_) } }
})
Add-Type -AssemblyName Microsoft.VisualBasic
[void]$form.ShowDialog()
