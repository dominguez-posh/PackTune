<#
.SYNOPSIS
    Validates a PackTune repository clone: packtune.json, every manifest.json (against the index) and the SHA256 and size of
    every file (against the manifest). Files that are release assets (listed in "assets" of the index) are skipped.
    Reads only, no network. Exit code 1 when anything is wrong.
.EXAMPLE
    ./tools/Check-PackTuneRepository.ps1 -Path .
#>
param([string]$Path = ".")
$ErrorActionPreference = "Stop"
$Segment = '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
$Names = "package.intunewin", "package.msix", "installer.zip", "recipe.json", "signing.cer", "documentation.zip"
$Problems = New-Object System.Collections.ArrayList
$IndexFile = Join-Path $Path "packtune.json"
if (-not (Test-Path -LiteralPath $IndexFile)) { Write-Error "No packtune.json in $Path"; exit 1 }
$Index = Get-Content -LiteralPath $IndexFile -Raw | ConvertFrom-Json
if ($Index.format -ne 1) { [void]$Problems.Add("packtune.json: format must be 1") }
$Seen = @{}
foreach ($App in @($Index.apps)) {
    $Id = [string]$App.id
    if ($Id -notmatch $Segment) { [void]$Problems.Add("app id '$Id' is not valid"); continue }
    if ($Seen[$Id]) { [void]$Problems.Add("app id '$Id' is listed twice"); continue }
    $Seen[$Id] = $true
    if ([string]$App.kind -notin "msi", "msix") { [void]$Problems.Add("$Id has an unknown kind '$($App.kind)'") }
    foreach ($V in @($App.versions)) {
        $Version = [string]$V.version
        if ($Version -notmatch $Segment) { [void]$Problems.Add("$Id version '$Version' is not valid"); continue }
        if ([string]$V.path -cne "apps/$Id/$Version") { [void]$Problems.Add("$Id ${Version}: path must be apps/$Id/$Version") }
        $Dir = Join-Path $Path "apps/$Id/$Version"
        $ManifestFile = Join-Path $Dir "manifest.json"
        if (-not (Test-Path -LiteralPath $ManifestFile)) { [void]$Problems.Add("$Id ${Version}: manifest.json is missing"); continue }
        if ((Get-FileHash -LiteralPath $ManifestFile -Algorithm SHA256).Hash.ToLower() -ne ([string]$V.manifest).ToLower()) { [void]$Problems.Add("$Id ${Version}: manifest.json does not match the hash in packtune.json"); continue }
        $Manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
        if ($Manifest.format -ne "PackTune.Store" -or $Manifest.app -ne $Id -or $Manifest.appVersion -ne $Version) { [void]$Problems.Add("$Id ${Version}: manifest.json belongs to another app or version"); continue }
        $Assets = @($V.assets | Where-Object { $_ })
        foreach ($F in @($Manifest.files)) {
            $Name = [string]$F.name
            if ($Name -notin $Names) { [void]$Problems.Add("$Id ${Version}: unexpected file name '$Name'"); continue }
            if ($Name -in $Assets) { continue }
            $File = Join-Path $Dir $Name
            if (-not (Test-Path -LiteralPath $File)) { [void]$Problems.Add("$Id ${Version}: $Name is missing"); continue }
            if ((Get-Item -LiteralPath $File).Length -ne [int64]$F.size) { [void]$Problems.Add("$Id ${Version}: $Name has another size than the manifest") }
            if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLower() -ne ([string]$F.sha256).ToLower()) { [void]$Problems.Add("$Id ${Version}: $Name does not match the manifest (SHA256)") }
        }
    }
}
if ($Problems.Count) { $Problems | ForEach-Object { Write-Host "FAIL  $_" }; exit 1 }
Write-Host "OK: $(@($Index.apps).Count) app(s) verified."
