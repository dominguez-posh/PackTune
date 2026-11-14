# The exit codes of the PackTune device scripts (install.ps1 of every app) and what they mean. ONE table for both sides:
# the device scripts get it as text (Get-DeviceExitCodeBlock, baked into the common part of every script), PackTune and the
# tenant insight module (Modules\TenantInsight.psm1 loads this file as well) read the cause of a code from it. The README lists
# the same table; Tests\Check-ExitCodes.ps1 checks that table, device scripts and README agree.
#
# Intune shows the exit code of install.ps1 per device and app (Win32 install status). Codes 61001 .. 61099 are PackTune's.
# They are kept clear of Intune's default return codes (0 success, 1707 success, 3010 soft reboot, 1641 hard reboot, 1618 retry),
# and none of them is ever added to the return code list of an app, so Intune treats each as a failure. 1618 stays the code
# for "another installation runs on the device, try again" (the mutex wait). Everything else a script exits with is the real
# exit code of the installer, choco or winget (see Get-PackTuneCodeCause for the common ones).

$script:PackTuneExitCodes = @(
    # Code, Name (the variable name on the device: $PTExit.<Name>), Cause (short, shown in PackTune)
    @{ Code = 61001; Name = 'ChocoMissing'; Cause = 'Chocolatey is not installed on the device' }
    @{ Code = 61002; Name = 'WingetMissing'; Cause = 'winget (App Installer) is not installed on the device' }
    @{ Code = 61003; Name = 'RuntimeBroken'; Cause = 'choco or winget is installed but does not run' }
    @{ Code = 61010; Name = 'SourceNotFound'; Cause = 'the package was not found in the package source' }
    @{ Code = 61011; Name = 'SourceUnreachable'; Cause = 'the package source cannot be reached from the device' }
    @{ Code = 61012; Name = 'DownloadFailed'; Cause = 'the download of the installer failed' }
    @{ Code = 61013; Name = 'HashMismatch'; Cause = 'the installer does not match its checksum or signature' }
    @{ Code = 61014; Name = 'DiskFull'; Cause = 'not enough free disk space' }
    @{ Code = 61015; Name = 'PackageManagerFailed'; Cause = 'choco reported a failure without a more specific cause (see the device log)' }
    @{ Code = 61016; Name = 'NoMachineInstaller'; Cause = 'the package has no installer for all users of the device (machine scope)' }
    @{ Code = 61020; Name = 'FolderProtect'; Cause = 'the PackTune folder on the device could not be protected' }
    @{ Code = 61021; Name = 'HelpersCopy'; Cause = 'the update helpers could not be copied on the device' }
    @{ Code = 61022; Name = 'TaskRegister'; Cause = 'the update tasks could not be registered on the device' }
    @{ Code = 61023; Name = 'PolicyWrite'; Cause = 'the policy marker could not be written on the device' }
    @{ Code = 61030; Name = 'LockForeign'; Cause = 'the PackTune lock on the device belongs to someone else, nothing was installed' }
)

function Get-PackTuneExitCodeTable { $script:PackTuneExitCodes | ForEach-Object { [pscustomobject]$_ } }

function Get-DeviceExitCodeBlock {
    # Text for the device scripts: the codes by name and the helper that turns what choco / winget did into one of them
    $Lines = foreach ($Entry in $script:PackTuneExitCodes) { "    $($Entry.Name) = $($Entry.Code)" }
    $Block = @'
# Exit codes of PackTune (README: Exit codes). Intune shows them per device; PackTune reads the cause from the same table.
$PTExit = @{
__CODES__
}
function Get-LockExitCode {
    # A lock that belongs to someone else is a finding of its own; otherwise another installation runs: Intune retries (1618)
    if ($script:LockError) { return $PTExit.LockForeign }
    return 1618
}
function Resolve-PackageFailure([int]$Code, [string]$Text) {
    # What choco did, as a PackTune code when the output says why; otherwise the exit code of choco or the installer itself
    if ($Code -in 0, 1641, 3010) { return $Code }
    if (($Code -in 112, -2147024784) -or ($Text -match '(?i)not enough space|disk is full|There is not enough space on the disk')) { return $PTExit.DiskFull }
    if ($Text -match '(?i)Unable to find package|was not found with the source|package was not found|No packages found') { return $PTExit.SourceNotFound }
    if ($Text -match '(?i)checksum|hash does not match|hash mismatch|signature is invalid|not signed|certificate chain') { return $PTExit.HashMismatch }
    if ($Text -match '(?i)Unable to connect|remote name could not be resolved|actively refused|operation has timed out|No such host is known|Unable to load the service index|Failed to fetch results') { return $PTExit.SourceUnreachable }
    if ($Text -match '(?i)Download of .* failed|Error retrieving|Error while downloading|downloading .* failed') { return $PTExit.DownloadFailed }
    if ($Code -in 1, -1) { return $PTExit.PackageManagerFailed }
    return $Code
}
function Resolve-WingetFailure([int]$Code) {
    # The documented winget results (winget-cli returnCodes.md) that have a PackTune code; everything else stays as winget returned it
    switch ($Code) {
        -1978335224 { return $PTExit.DownloadFailed }          # 0x8A150008 download failed
        -1978335217 { return $PTExit.SourceUnreachable }       # 0x8A15000F source data missing
        -1978335216 { return $PTExit.NoMachineInstaller }      # 0x8A150010 no applicable installer
        -1978335215 { return $PTExit.HashMismatch }            # 0x8A150011 installer hash mismatch
        -1978335212 { return $PTExit.SourceNotFound }          # 0x8A150014 no package found
        default { if ($Code -in 112, -2147024784) { return $PTExit.DiskFull }; return $Code }
    }
}
'@
    return $Block.Replace('__CODES__', ($Lines -join "`r`n"))
}

function Get-PackTuneCodeCause {
    <#
        Short cause of an exit code that Intune reports for install.ps1: PackTune's own codes (the table above) first, then the common
        codes of Intune, the Windows installer, Chocolatey and winget. $null for no code. Unknown codes return the hex value only.
        Sources: winget return codes (github.com/microsoft/winget-cli, doc/windows/package-manager/winget/returnCodes.md), Windows
        Installer error codes and Intune Win32 return codes (learn.microsoft.com). Not verified against a live tenant.
    #>
    param($Code)
    if ($null -eq $Code -or "$Code" -eq '') { return $null }
    $Number = try { if ("$Code" -match '^0x[0-9a-fA-F]+$') { [Convert]::ToInt64("$Code".Substring(2), 16) } else { [int64]$Code } } catch { return $null }
    if ($Number -lt 0) { $Number += 4294967296 }
    $Own = @($script:PackTuneExitCodes | Where-Object { $_.Code -eq $Number }) | Select-Object -First 1
    if ($Own) { return [string]$Own.Cause }
    $Hex = '0x{0:X8}' -f $Number
    $Table = @{
        '1' = 'the installer or choco reported a general error (see the device log)'
        '112' = 'not enough free disk space'
        '1601' = 'Windows Installer service not accessible'
        '1602' = 'the installation was cancelled'
        '1603' = 'fatal error during installation'
        '1605' = 'the product is not installed'
        '1618' = 'another installation is already running, retry later'
        '1619' = 'installer package could not be opened'
        '1620' = 'installer package is not a valid package'
        '1625' = 'installation blocked by policy'
        '1638' = 'another version of the product is already installed'
        '1641' = 'success, the installer started a restart'
        '1707' = 'success'
        '3010' = 'success, a restart is required'
        '80004005' = 'unspecified error (0x80004005)'
        '80070002' = 'file not found (0x80070002)'
        '80070005' = 'access denied (0x80070005)'
        '80070070' = 'not enough free disk space (0x80070070)'
        '80070643' = 'fatal error during installation (0x80070643)'
        '80070652' = 'another installation is in progress (0x80070652)'
        '87D1041C' = 'installed, but the detection rule does not find the app (0x87D1041C)'
        '8A150001' = 'winget: internal error (0x8A150001)'
        '8A150002' = 'winget: invalid command line arguments (0x8A150002)'
        '8A150008' = 'winget: download of the installer failed (0x8A150008)'
        '8A15000F' = 'winget: the package source data is missing (0x8A15000F)'
        '8A150010' = 'winget: no applicable installer for this device (0x8A150010)'
        '8A150011' = 'winget: installer hash does not match (0x8A150011)'
        '8A150014' = 'winget: no package found (0x8A150014)'
    }
    foreach ($Key in $Table.Keys) {
        # up to 5 characters are decimal exit codes, longer ones hexadecimal
        $Value = if ($Key.Length -le 5) { [int64]$Key } else { [Convert]::ToInt64($Key, 16) }
        if ($Value -eq $Number) { return $Table[$Key] }
    }
    if ($Hex -like '0x8A15*') { return "winget error $Hex (see the winget return codes)" }
    if ($Hex -like '0x87D*') { return "Intune Management Extension error $Hex" }
    if ($Number -eq 4294967295) { return 'the installer or choco failed (-1)' }
    return "error $Hex"
}
