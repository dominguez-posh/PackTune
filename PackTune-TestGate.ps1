# Sandbox test results of catalog apps (Chocolatey and winget) and the deploy gate built on them.
#
# One record per source + package + version + architecture (a newer version is "Not tested"): passed or failed, the date and the
# cause (the first failed step of the test lab). Kept locally (%LOCALAPPDATA%\PackTune\sandbox-tests.json) and, when the package
# store is set up, in the folder "SandboxTests" of its library (read when the tool starts). A deployment of a catalog app that is not
# tested or failed is refused by the backend (Assert-PackTuneCatalogTested) unless an explicit reason is given (-SkipTestReason): that
# override goes into the app notes (testOverride=<state>;<date>;<admin>) and is logged by the caller. Custom applications keep their
# own hard gate (Assert-PackTuneTestPassed, PackTune-Custom.ps1): there is no override there.

$script:CatalogTestFolder = "SandboxTests"

function Get-PackTuneCatalogTestFile { Join-Path $script:WorkRoot "sandbox-tests.json" }

function Get-PackTuneCatalogTestKey {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Package, [Parameter(Mandatory = $true)][string]$Version, [string]$Architecture = $script:Settings.Architecture)
    "$Source|$Package|$Version|$Architecture".ToLower()
}

function Read-PackTuneCatalogTests {
    # key -> record; an unreadable file is an empty list (everything then reads as not tested, which only blocks)
    $Result = @{}
    $File = Get-PackTuneCatalogTestFile
    if (Test-Path -LiteralPath $File) {
        try { foreach ($Record in @(Get-Content -LiteralPath $File -Raw | ConvertFrom-Json | ForEach-Object { $_ })) { if ($Record -and $Record.key) { $Result[[string]$Record.key] = $Record } } } catch { }
    }
    return $Result
}

function Write-PackTuneCatalogTests($Table) {
    $File = Get-PackTuneCatalogTestFile
    New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force | Out-Null
    $Temp = "$File.tmp"
    [IO.File]::WriteAllText($Temp, (ConvertTo-Json -InputObject @($Table.Values | Sort-Object { $_.key }) -Depth 4), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $Temp -Destination $File -Force
}

function Get-PackTuneCatalogTest {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Package, [Parameter(Mandatory = $true)][string]$Version, [string]$Architecture = $script:Settings.Architecture)
    $Table = Read-PackTuneCatalogTests
    $Key = Get-PackTuneCatalogTestKey -Source $Source -Package $Package -Version $Version -Architecture $Architecture
    if ($Table.ContainsKey($Key)) { return $Table[$Key] }
    return $null
}

function Get-PackTuneCatalogTestState {
    # "Passed", "Failed" or "Not tested" for exactly this version
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Package, [string]$Version, [string]$Architecture = $script:Settings.Architecture)
    if (-not $Version -or $Version -eq "latest") { return "Not tested" }
    $Record = Get-PackTuneCatalogTest -Source $Source -Package $Package -Version $Version -Architecture $Architecture
    if (-not $Record) { return "Not tested" }
    if ($Record.verdict -eq "Passed") { return "Passed" }
    return "Failed"
}

function Save-PackTuneCatalogTest {
    <#
        Keeps the outcome of a sandbox test. Verdict Passed or Failed; Cause is the first failed step (or why the test did not finish).
        Local first; with a ready package store the record goes there too (best effort: a store that cannot be reached never hides a result).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Package, [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][ValidateSet("Passed", "Failed")][string]$Verdict, [string]$Cause, [string]$Architecture = $script:Settings.Architecture, [bool]$UpdatePath
    )
    $Key = Get-PackTuneCatalogTestKey -Source $Source -Package $Package -Version $Version -Architecture $Architecture
    $Clean = { param($Text) $Short = ([string]$Text -replace '[^\x20-\x7E]', '?'); if ($Short.Length -gt 200) { $Short.Substring(0, 200) } else { $Short } }
    $Record = [pscustomobject][ordered]@{ key = $Key; source = $Source; package = $Package; version = $Version; architecture = $Architecture; verdict = $Verdict
        date = (Get-Date).ToUniversalTime().ToString("o"); cause = (& $Clean $Cause); updatePath = $UpdatePath }
    $Table = Read-PackTuneCatalogTests
    $Table[$Key] = $Record
    Write-PackTuneCatalogTests $Table
    try { Send-PackTuneCatalogTestToStore $Record } catch { Write-Verbose "The test result could not be kept in the package store: $($_.Exception.Message)" }
    return $Record
}

function Get-PackTuneCatalogTestStoreName([string]$Key) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key))).Replace("-", "").ToLower().Substring(0, 24)) + ".json" } finally { $Sha.Dispose() }
}

function Send-PackTuneCatalogTestToStore {
    param([Parameter(Mandatory = $true)]$Record)
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready" -or -not $State.Store.DriveId) { return }
    $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".json")
    try {
        [IO.File]::WriteAllText($Temp, ($Record | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
        Send-PackTuneStoreFile -DriveId $State.Store.DriveId -Segments @($script:CatalogTestFolder, (Get-PackTuneCatalogTestStoreName $Record.key)) -LocalPath $Temp
    }
    finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}

function Sync-PackTuneCatalogTests {
    # Reads the results other administrators (and earlier runs) kept in the package store; the newer record of a key wins. Returns the number taken over.
    $State = Get-PackTuneStoreState
    if ($State.State -ne "Ready" -or -not $State.Store.DriveId) { return 0 }
    $Taken = 0
    $Table = Read-PackTuneCatalogTests
    $Items = @(try { Get-PackTuneStoreChildren -DriveId $State.Store.DriveId -Segments @($script:CatalogTestFolder) } catch { @() })
    foreach ($Item in $Items) {
        if ($Item.folder -or [string]$Item.name -notlike "*.json") { continue }
        $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".json")
        try {
            Receive-PackTuneStoreFile -DriveId $State.Store.DriveId -Segments @($script:CatalogTestFolder, [string]$Item.name) -Destination $Temp
            $Record = Get-Content -LiteralPath $Temp -Raw | ConvertFrom-Json
            if (-not $Record.key -or $Record.verdict -notin "Passed", "Failed" -or [string]$Record.key -ne (Get-PackTuneCatalogTestKey -Source ([string]$Record.source) -Package ([string]$Record.package) -Version ([string]$Record.version) -Architecture ([string]$Record.architecture))) { continue }
            $Mine = $Table[[string]$Record.key]
            if (-not $Mine -or ([datetime]$Record.date) -gt ([datetime]$Mine.date)) { $Table[[string]$Record.key] = $Record; $Taken++ }
        }
        catch { }
        finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
    }
    if ($Taken) { Write-PackTuneCatalogTests $Table }
    return $Taken
}

function ConvertTo-PackTuneTestOverrideNote {
    # testOverride=<state>;<date>;<admin>: state without blanks (nottested / failed), date yyyyMMdd, the admin's sign-in name
    param([Parameter(Mandatory = $true)][string]$State, [string]$Admin)
    $Name = ([string]$Admin -replace '[^A-Za-z0-9@._-]', '')
    if (-not $Name) { $Name = "unknown" }
    "testOverride=$(($State -replace '\s', '').ToLower());$((Get-Date).ToString('yyyyMMdd'));$Name"
}

function Get-PackTuneAdminName {
    # Who is signed in (account name), for the override record
    $Upn = ""
    try { $Id = Get-PackTuneIdentity; if ($Id) { $Upn = [string]$Id.Account } } catch { }
    if (-not $Upn) { $Upn = [string]$env:USERNAME }
    return $Upn
}

function Assert-PackTuneCatalogTested {
    <#
        The deploy gate of catalog apps: passes only for a version with a passed sandbox test. Without one it throws, unless -SkipTestReason names
        a reason: then it returns the override (State, Reason, Note for the app notes, Text for the log) and the caller deploys and logs it.
        Returns $null when the test passed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Package, [Parameter(Mandatory = $true)][string]$Version,
        [string]$Architecture = $script:Settings.Architecture, [string]$SkipTestReason
    )
    $State = Get-PackTuneCatalogTestState -Source $Source -Package $Package -Version $Version -Architecture $Architecture
    if ($State -eq "Passed") { return $null }
    $Reason = ([string]$SkipTestReason).Trim()
    if (-not $Reason) {
        $Record = if ($Version -and $Version -ne "latest") { Get-PackTuneCatalogTest -Source $Source -Package $Package -Version $Version -Architecture $Architecture }
        $Why = if ($State -eq "Failed") { "its sandbox test failed ($($Record.cause))" } else { "it was not tested in the sandbox" }
        throw "$Package $Version cannot be deployed: $Why. Run the sandbox test first, or give a reason with -SkipTestReason to deploy without a passed test (it is logged and written to the app notes)."
    }
    $Admin = Get-PackTuneAdminName
    [pscustomobject]@{
        State = $State; Reason = $Reason; Admin = $Admin; Note = (ConvertTo-PackTuneTestOverrideNote -State $State -Admin $Admin)
        Text = "deployed without passed sandbox test: $Package $Version ($State), reason: $Reason, admin: $Admin"
    }
}
