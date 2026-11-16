# The host of the Win32 test lab INSIDE the sandbox: it stays running between tests, so the next test (also for another app) reuses this sandbox
# instead of starting a new one. It plays the first test (the job at the root of the mapped folder) and then waits for more:
# <Job>\tests\<n>\request.json is a new test (its input and job.json are next to it). Every few seconds it writes <Job>\heartbeat.json, which
# PackTune reads to know that this sandbox is alive; <Job>\newsandbox.request makes it shut the sandbox down (the next test starts clean).
# Plain ASCII: Windows PowerShell 5.1 reads scripts without a byte order mark in the local code page.
param(
    [string]$JobDir = 'C:\PackTuneSandbox\Job',
    [string]$LocalDir = 'C:\PackTuneSandboxLocal'
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Started = Get-Date
$Token = [string]$job.SessionToken
$script:Tests = 0
$script:Current = $null          # @{ Process; Dir; Title }
$script:Closing = $false
$HeartbeatFile = Join-Path $JobDir 'heartbeat.json'
$NewSandboxFile = Join-Path $JobDir 'newsandbox.request'
$Tools = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Heartbeat {
    $state = [ordered]@{ Token = $Token; Started = $Started.ToString('o'); Updated = (Get-Date).ToString('o'); State = $(if ($script:Current) { 'Running' } else { 'Idle' })
        Tests = $script:Tests; Current = $(if ($script:Current) { [string]$script:Current.Title } else { '' }) }
    $tmp = Join-Path $JobDir 'heartbeat.tmp'
    try { $state | ConvertTo-Json | Set-Content $tmp -Encoding UTF8; Move-Item $tmp $HeartbeatFile -Force } catch { }
}

function Start-LabTest([string]$Dir, [string]$Local, [string]$Title) {
    $script:Tests++
    $script:Current = @{ Dir = $Dir; Title = $Title; Process = (Start-Process powershell.exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Tools 'Lab.ps1')`"", '-JobDir', "`"$Dir`"", '-LocalDir', "`"$Local`"", '-SessionDir', "`"$JobDir`"" -PassThru) }
    Write-Heartbeat
}

function Get-NextRequest {
    $root = Join-Path $JobDir 'tests'
    if (-not (Test-Path $root)) { return $null }
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object { [int]($_.Name -replace '\D', '0') })) {
        if ((Test-Path (Join-Path $d.FullName 'request.json')) -and -not (Test-Path (Join-Path $d.FullName 'taken.flag'))) { return $d }
    }
    $null
}

# ---------------------------------------------------------------- the small window between tests
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PackTune test lab (sandbox)'; $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(40, 40)
$form.ClientSize = New-Object System.Drawing.Size(520, 130); $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false; $form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F6F7F9')
$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(16, 14); $label.Size = New-Object System.Drawing.Size(488, 70); $label.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$button = New-Object System.Windows.Forms.Button
$button.Text = 'New sandbox'; $button.Location = New-Object System.Drawing.Point(16, 88); $button.Size = New-Object System.Drawing.Size(150, 30)
$button.Add_Click({ New-Item -ItemType File -Path $NewSandboxFile -Force | Out-Null })
$form.Controls.AddRange(@($label, $button))
$form.Add_FormClosing({ param($s, $e) if (-not $script:Closing) { $e.Cancel = $true } })   # the window stays: PackTune closes the sandbox when it is done with it

function Update-IdleText {
    $label.Text = "Test lab sandbox, started $($Started.ToString('HH:mm')), $($script:Tests) test$(if ($script:Tests -ne 1) { 's' }) so far.`r`n" +
        $(if ($script:Current) { "Running: $($script:Current.Title)" } else { 'Waiting for the next test (it reuses this sandbox). Use New sandbox to start clean.' })
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    if (Test-Path $NewSandboxFile) { $script:Closing = $true; $timer.Stop(); Write-Heartbeat; Start-Sleep -Seconds 1; Remove-Item $HeartbeatFile -Force -ErrorAction SilentlyContinue; shutdown.exe /s /t 0; return }
    if ($script:Current -and $script:Current.Process.HasExited) { $script:Current = $null; $form.Show() }
    if (-not $script:Current) {
        $next = Get-NextRequest
        if ($next) {
            $req = Get-Content (Join-Path $next.FullName 'request.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Set-Content (Join-Path $next.FullName 'taken.flag') (Get-Date).ToString('o')
            $local = Join-Path $LocalDir ('t' + $next.Name)
            New-Item -ItemType Directory $local -Force | Out-Null
            Copy-Item (Join-Path $next.FullName 'input') $local -Recurse -Force
            $form.Hide()
            Start-LabTest $next.FullName $local ([string]$req.Title)
        }
    }
    Write-Heartbeat
    Update-IdleText
})

# The first test: the job at the root, input already copied by the bootstrap
Start-LabTest $JobDir $LocalDir ([string]$job.DisplayName)
Update-IdleText
$form.Add_Shown({ $form.Hide(); $timer.Start() })
# Application.Run keeps the loop alive while the form is hidden (a hidden ShowDialog would end the host)
[System.Windows.Forms.Application]::Run($form)
