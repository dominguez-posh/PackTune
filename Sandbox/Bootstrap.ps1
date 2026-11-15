# Runs INSIDE Windows Sandbox as the logon command (started by the .wsb file that Modules\PackTune.Sandbox.psm1 writes).
# Reads C:\PackTuneSandbox\Job\job.json, does the job and reports progress and result to status.json in the same
# (host-mapped) folder.
#   Package: install the MSIX Packaging Tool, run the conversion template unattended, close the sandbox
#   Lab:     open the Win32 test lab (Lab.ps1); it reports the verdict and closes the sandbox
# Plain ASCII: Windows PowerShell 5.1 reads scripts without a byte order mark in the local code page.

$ErrorActionPreference = 'Stop'
$JobDir = 'C:\PackTuneSandbox\Job'
$ToolchainDir = 'C:\PackTuneSandbox\Toolchain'
$OutDir = Join-Path $JobDir 'out'
$ToolFamily = 'Microsoft.MSIXPackagingTool_8wekyb3d8bbwe'
# Windows services (deployment, MSIX Packaging Tool) cannot use the mapped host folders ("Access denied"):
# the sandbox works on local copies; only results go back to the job folder.
$LocalDir = 'C:\PackTuneSandboxLocal'
$LocalInput = Join-Path $LocalDir 'input'
$LocalOut = Join-Path $LocalDir 'out'

# Logs go to %TEMP% while the sandbox works: the Packaging Tool excludes that folder from captures, a log file in the
# job folder could otherwise end up in the package. Copied to out\ at the end.
$TempLog = Join-Path $env:TEMP 'packtune'
New-Item -ItemType Directory $TempLog -Force | Out-Null
Start-Transcript -Path (Join-Path $TempLog 'bootstrap.log') -Force | Out-Null
$Host.UI.RawUI.WindowTitle = 'PackTune sandbox'
$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Set-JobStatus {
    param([string]$State, [string]$Step, [string]$Message = '', $Result = $null)
    Write-Host "[$State] $Step $Message" -ForegroundColor Cyan
    $status = [ordered]@{ State = $State; Step = $Step; Message = $Message; Result = $Result; Updated = (Get-Date).ToString('o') }
    # A temporary file first: the host never reads a half written status
    $tmp = Join-Path $JobDir 'status.tmp'
    $status | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp (Join-Path $JobDir 'status.json') -Force
}

function Copy-JobInput {
    # Local copy of the job input (installer folder, base package, package files) before any capture starts
    New-Item -ItemType Directory $LocalInput, $LocalOut -Force | Out-Null
    Copy-Item (Join-Path $JobDir 'input\*') $LocalInput -Recurse -Force
    # The installation folder is mapped read-only: the local copy gets all its files
    $folder = 'C:\PackTuneSandbox\Input'
    if ($job.InputFolder -and (Test-Path $folder)) {
        New-Item -ItemType Directory (Join-Path $LocalInput 'installer') -Force | Out-Null
        Copy-Item (Join-Path $folder '*') (Join-Path $LocalInput 'installer') -Recurse -Force
    }
}

function Install-PackagingTool {
    Set-JobStatus Running 'Installing the MSIX Packaging Tool driver'
    # DISM wants a local .cab with the right extension
    New-Item -ItemType Directory C:\Temp -Force | Out-Null
    $cab = 'C:\Temp\Msix-PackagingTool-Driver-Package.cab'
    Copy-Item (Join-Path $ToolchainDir 'Msix-PackagingTool-Driver-Package.cab') $cab -Force
    Add-WindowsPackage -Online -PackagePath $cab -NoRestart | Out-Null

    Set-JobStatus Running 'Installing the MSIX Packaging Tool'
    # Local copies: the deployment service cannot read from the mapped (host) folder ("Access denied")
    $bundle = 'C:\Temp\MSIXPackagingTool.msixbundle'
    $license = 'C:\Temp\MSIXPackagingTool.License.xml'
    Copy-Item (Join-Path $ToolchainDir 'MSIXPackagingTool.msixbundle') $bundle -Force
    Copy-Item (Join-Path $ToolchainDir 'MSIXPackagingTool.License.xml') $license -Force
    Add-AppxProvisionedPackage -Online -PackagePath $bundle -LicensePath $license | Out-Null
    # Provisioned packages register at the next logon: register for the logged-on user now
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage $ToolFamily }
    catch { Add-AppxPackage -Path $bundle }
    Get-AppxPackage -Name 'Microsoft.MSIXPackagingTool'
}

function Save-Logs {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    Copy-Item (Join-Path $TempLog '*') $OutDir -Force -ErrorAction SilentlyContinue
}

function Close-Sandbox {
    Save-Logs
    if ($job.AutoClose) {
        Start-Sleep -Seconds 3
        shutdown.exe /s /t 0
    }
}

try {
    switch ($job.Mode) {
        'Package' {
            Copy-JobInput
            Install-PackagingTool | Out-Null
            # No status writes from here until the tool is done: the installer runs while the tool captures
            Set-JobStatus Running "Converting $($job.Installer)"
            # App execution alias, created when the tool is registered for the user
            $cli = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\MsixPackagingTool.exe'
            if (-not (Test-Path $cli)) { throw "MSIX Packaging Tool command line not found ($cli)." }
            # Windows PowerShell turns stderr lines of native tools into errors; with 'Stop' the first one would abort.
            # The template is read from a local copy as well (mapped folders are not reliable for the tool).
            $template = Join-Path $LocalDir 'template.xml'
            Copy-Item (Join-Path $JobDir 'template.xml') $template -Force
            $ErrorActionPreference = 'Continue'
            & $cli create-package --template $template -v 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $TempLog 'conversion.log')
            $exit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'

            # The tool's own logs, for troubleshooting
            $logs = Join-Path $env:LOCALAPPDATA "Packages\$ToolFamily\LocalState\DiagOutputDir"
            if (Test-Path $logs) { Copy-Item $logs (Join-Path $OutDir 'PackagingToolLogs') -Recurse -Force -ErrorAction SilentlyContinue }

            # The template saves to the local folder: results go back to the job folder now
            Copy-Item (Join-Path $LocalOut '*') $OutDir -Force -ErrorAction SilentlyContinue
            $msix = Join-Path $OutDir $job.PackageFile
            if (Test-Path $msix) { Set-JobStatus Succeeded 'Done' "Package created ($([math]::Round((Get-Item $msix).Length / 1MB, 1)) MB)." }
            else { Set-JobStatus Failed 'Conversion' "No package was created (exit code $exit). See conversion.log." }
        }

        'Lab' {
            # The lab shows the progress and takes over once 'Ready'; no Packaging Tool needed
            Set-JobStatus Running 'Copying the package files'
            Copy-JobInput
            Save-Logs
            Set-JobStatus Running 'Ready'
            # The host stays running between tests (the next test reuses this sandbox) and starts the lab panel for each test
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', 'C:\PackTuneSandbox\Tools\LabHost.ps1'
        }
    }
}
catch {
    Set-JobStatus Failed 'Error' $_.Exception.Message
    if ($job.Mode -eq 'Lab') { Save-Logs }
}
finally {
    # In Lab mode the lab owns the sandbox from 'Ready' on; it closes it itself
    if ($job.Mode -ne 'Lab') { Close-Sandbox }
}
