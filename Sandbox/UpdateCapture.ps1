# The "installer" of an unattended capture that needs more than one command (Invoke-PackTuneMsixCapture): the MSIX
# Packaging Tool captures every change made while this process runs.
#   1. -Restore: put the content of the previous MSIX package in place (update capture)
#   2. run the entry point of the installation folder (command from -EntryFile) and wait for it
# Exit code 0 = the package is built; anything else makes the capture fail. Log in %TEMP% (excluded from the capture).
# Plain ASCII: Windows PowerShell 5.1 reads scripts without a byte order mark in the local code page.
param(
    [Parameter(Mandatory = $true)][string]$EntryFile,
    [string]$Restore,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory (Join-Path $env:TEMP 'packtune') -Force | Out-Null
$log = Join-Path $env:TEMP 'packtune\restore.log'
$entry = Get-Content -LiteralPath $EntryFile -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------- restore of a previous package
# The update capture starts with the content of the base .msix laid down as if it were installed classically (files to
# their real locations, registry imported, Start menu shortcut per app). This happens inside the capture, so the new
# package holds the old content plus everything the update changes.

function Invoke-Reg {
    # reg.exe with its output captured. In Windows PowerShell with $ErrorActionPreference = 'Stop' every line a native
    # tool writes to stderr ("Access denied" on one protected key) would end the whole restore: the call runs with
    # 'Continue' and the caller looks at the exit code instead.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $text = (& reg.exe @Arguments 2>&1 | ForEach-Object { "$_" }) -join ' ' }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Text = $text }
}

function Get-MsixVfsMap {
    # VFS folder names used in MSIX packages -> real locations
    [ordered]@{
        'ProgramFilesX64' = $env:ProgramFiles
        'ProgramFilesX86' = ${env:ProgramFiles(x86)}
        'ProgramFilesCommonX64' = $env:CommonProgramFiles
        'ProgramFilesCommonX86' = ${env:CommonProgramFiles(x86)}
        'SystemX64' = Join-Path $env:SystemRoot 'System32'
        'SystemX86' = Join-Path $env:SystemRoot 'SysWOW64'
        'Windows' = $env:SystemRoot
        'Fonts' = Join-Path $env:SystemRoot 'Fonts'
        'Common AppData' = $env:ProgramData
        'AppData' = $env:APPDATA
        'Local AppData' = $env:LOCALAPPDATA
        'LocalAppDataLow' = Join-Path $env:USERPROFILE 'AppData\LocalLow'
        'Profile' = $env:USERPROFILE
        'Common Desktop' = Join-Path $env:PUBLIC 'Desktop'
        'Common Documents' = Join-Path $env:PUBLIC 'Documents'
        'Common Programs' = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        'Common Start Menu' = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'
        'AppVPackageDrive' = $env:SystemDrive + '\'
    }
}

function Get-RegistrySubkey {
    # Direct subkeys of a key (reg.exe paths). Compared as plain text: package hives hold key names like
    # "[{AppVCurrentUserSID}]", which -like would read as a wildcard pattern.
    param([Parameter(Mandatory = $true)][string]$Key)
    $prefix = "$Key\"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& reg.exe query $Key 2>$null) } finally { $ErrorActionPreference = $previous }
    @($lines | Where-Object { $_ -and $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

function Get-MsixRestorePlan {
    # Maps every entry of an .msix to where it goes on a classic install. Kind: File, MachineHive, UserHive, Skip.
    # Package parts are percent-encoded in the zip ("Common%20AppData"); files outside VFS go to InstallRoot.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$InstallRoot)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $map = Get-MsixVfsMap
    $metadata = @('AppxManifest.xml', 'AppxBlockMap.xml', 'AppxSignature.p7x', '[Content_Types].xml', 'resources.pri')
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $name = [uri]::UnescapeDataString($e.FullName)
            $parts = @($name -split '/')
            $kind = 'File'; $target = $null
            if ($parts.Count -eq 1 -and $metadata -contains $name) { $kind = 'Skip' }
            elseif ($parts[0] -eq 'AppxMetadata' -or $parts[0] -eq 'Assets') { $kind = 'Skip' }
            elseif ($parts.Count -eq 1 -and $name -eq 'Registry.dat') { $kind = 'MachineHive' }
            elseif ($parts.Count -eq 1 -and ($name -eq 'User.dat' -or $name -eq 'UserClasses.dat')) { $kind = 'UserHive' }
            elseif ($parts[0] -eq 'VFS' -and $parts.Count -gt 2) {
                if ($map.Contains($parts[1])) { $target = Join-Path $map[$parts[1]] ($parts[2..($parts.Count - 1)] -join '\') }
                else { $kind = 'Skip' }
            }
            else { $target = Join-Path $InstallRoot ($parts -join '\') }
            [pscustomobject]@{ Entry = $e.FullName; Name = $name; Kind = $kind; Target = $target; Size = $e.Length }
        }
    }
    finally { $zip.Dispose() }
}

function Import-MsixHive {
    # Loads a package hive under HKU (not captured) and copies its keys to HKLM / HKCU. A key that cannot be written
    # (protected by the system) is logged and skipped: the restore goes on with the others.
    param([Parameter(Mandatory = $true)][string]$HiveFile, [string]$Log)
    $mount = 'HKU\PackTuneRestore'
    $load = Invoke-Reg load $mount $HiveFile
    if ($load.Exit -ne 0) { throw "reg load failed for ${HiveFile}: $($load.Text)" }
    try {
        $hku = 'HKEY_USERS\PackTuneRestore'
        $leafOf = { param($key) $key.Substring($key.LastIndexOf('\') + 1) }
        $copy = {
            param($key, $to)
            $r = Invoke-Reg copy $key $to /s /f
            if ($Log) { Add-Content $Log "registry: $key -> $to (exit $($r.Exit))$(if ($r.Exit -ne 0) { ' skipped: ' + $r.Text })" }
        }
        foreach ($k in (Get-RegistrySubkey "$hku\REGISTRY\MACHINE")) { & $copy $k ('HKLM\' + (& $leafOf $k)) }
        foreach ($sid in (Get-RegistrySubkey "$hku\REGISTRY\USER")) {
            # "<SID>_Classes" holds the class registrations of the user (HKCU\Software\Classes), "<SID>" the rest of HKCU
            $target = if ($sid -match '_Classes$') { 'HKCU\Software\Classes' } else { 'HKCU' }
            foreach ($k in (Get-RegistrySubkey $sid)) { & $copy $k ($target + '\' + (& $leafOf $k)) }
        }
    }
    finally {
        [GC]::Collect()
        $null = Invoke-Reg unload $mount
    }
}

function Restore-MsixPackageContent {
    # Lays down the content of an .msix classically. Temporary files go to %TEMP% (excluded from captures).
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$InstallRoot, [string]$Log)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $plan = @(Get-MsixRestorePlan -Path $Path -InstallRoot $InstallRoot)
    $temp = Join-Path $env:TEMP 'packtune\restore'
    New-Item -ItemType Directory $temp -Force | Out-Null
    $files = 0; $hives = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($p in $plan) {
            if ($p.Kind -eq 'Skip') { continue }
            $entry = $zip.GetEntry($p.Entry)
            if ($p.Kind -eq 'File') {
                $dir = Split-Path $p.Target -Parent
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $p.Target, $true)
                $files++
            }
            else {
                $hive = Join-Path $temp $p.Name
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $hive, $true)
                Import-MsixHive -HiveFile $hive -Log $Log
                $hives++
            }
        }
        $reader = New-Object IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }

    # A Start menu shortcut per application, so the new capture finds the same entry points
    $shortcuts = 0
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($app in @($manifest.Package.Applications.Application | Where-Object { $_ })) {
        $exe = [uri]::UnescapeDataString($app.Executable) -replace '/', '\'
        $target = ($plan | Where-Object { $_.Kind -eq 'File' -and ($_.Name -replace '/', '\') -eq $exe } | Select-Object -First 1).Target
        if (-not $target) { continue }
        $name = $app.VisualElements.DisplayName
        if (-not $name -or $name -like 'ms-resource:*') { $name = [IO.Path]::GetFileNameWithoutExtension($target) }
        $lnk = $shell.CreateShortcut((Join-Path $programs (($name -replace '[\\/:*?"<>|]', '') + '.lnk')))
        $lnk.TargetPath = $target
        $lnk.WorkingDirectory = Split-Path $target -Parent
        $lnk.Save()
        $shortcuts++
    }
    if ($Log) { Add-Content $Log "restored: $files files, $hives hives, $shortcuts shortcuts" }
}

# ---------------------------------------------------------------- run

if ($Restore) {
    try {
        Add-Content $log "restoring the previous package: $Restore"
        Restore-MsixPackageContent -Path $Restore -InstallRoot $InstallRoot -Log $log
    }
    catch {
        Add-Content $log "restore failed: $($_.Exception.Message)"
        exit 1603
    }
}

try {
    Add-Content $log "running: $($entry.FilePath) $($entry.ArgumentList)"
    $p = Start-Process -FilePath $entry.FilePath -ArgumentList $entry.ArgumentList -WorkingDirectory $entry.WorkingDirectory -PassThru
    $null = $p.Handle   # keeps the exit code readable after the process has ended
    $limit = [int]$entry.TimeoutMinutes
    if ($limit -lt 1) { $limit = 30 }
    if (-not $p.WaitForExit($limit * 60000)) {
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        Add-Content $log "timeout after $limit minutes"
        exit 1460
    }
    Add-Content $log "exit code $($p.ExitCode)"
    if ($p.ExitCode -in 0, 1707, 3010, 1641) { exit 0 }
    exit $p.ExitCode
}
catch {
    Add-Content $log "start failed: $($_.Exception.Message)"
    exit 1603
}
