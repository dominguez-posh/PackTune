<#
.SYNOPSIS
    Crash "Collection was modified; enumeration operation may not execute" in Complete-MetaPrefetch: the UI thread enumerated
    the shared package infos (Shared.Meta) while the background version refresh kept writing to them. The UI now enumerates
    a snapshot taken under the writers' lock (Get-MetaSnapshot). A background runspace writes while the UI side enumerates.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-MetaSnapshot.ps1
#>
$ErrorActionPreference = 'Stop'
trap { "FAIL  the check stopped before the end: $($_.Exception.Message)"; exit 1 }
$repo = Split-Path $PSScriptRoot -Parent
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }

# Get-MetaSnapshot exactly as in Start-PackTune.ps1 (taken from its source)
$gui = Get-Content (Join-Path $repo 'Start-PackTune.ps1') -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($gui, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-MetaSnapshot' }, $true)
Test-Check 'Start-PackTune.ps1 has Get-MetaSnapshot' ([bool]$fn)
. ([scriptblock]::Create($fn.Extent.Text))

$script:Shared = [hashtable]::Synchronized(@{ Meta = [hashtable]::Synchronized(@{}) })
for ($i = 0; $i -lt 300; $i++) { $script:Shared.Meta["k$i"] = [pscustomobject]@{ Found = $true; NotFound = $false; IconUrl = '' } }
# The background refresh: writes new and changed entries as fast as it can
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({ param($m) $i = 0; while ($true) { $i++; $m["n$($i % 5000)"] = [pscustomobject]@{ Found = $false; NotFound = $false; IconUrl = '' } } }).AddArgument($script:Shared.Meta)
$handle = $ps.BeginInvoke()
Start-Sleep -Milliseconds 200
try {
    # The old way (enumerating the live table) fails under these writes: shows the check reproduces the crash
    $oldErrors = 0
    for ($n = 0; $n -lt 200 -and $oldErrors -eq 0; $n++) { try { $null = @($script:Shared.Meta.Values | Where-Object { -not $_.Found -and -not $_.NotFound }) } catch { $oldErrors++ } }
    $newErrors = 0; $lastCount = 0
    for ($n = 0; $n -lt 200; $n++) { try { $lastCount = @((Get-MetaSnapshot).Values | Where-Object { -not $_.Found -and -not $_.NotFound }).Count } catch { $newErrors++ } }
}
finally { $ps.Stop(); $ps.Dispose(); $rs.Dispose() }
Test-Check 'reproduced: enumerating the live package infos while the refresh writes throws "Collection was modified"' ($oldErrors -gt 0) "errors=$oldErrors"
Test-Check 'snapshot: 200 enumerations during the writes, no error, entries of the background seen' ($newErrors -eq 0 -and $lastCount -gt 0) "errors=$newErrors count=$lastCount"
# No other enumeration of the live table on the UI thread
$live = [regex]::Matches($gui, 'Shared\.Meta\.(Keys|Values|GetEnumerator)') | ForEach-Object { $_.Value }
Test-Check 'the interface enumerates Shared.Meta only through Get-MetaSnapshot' (@($live).Count -eq 0) ($live -join ', ')

if ($script:Failed) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
