<#
.SYNOPSIS
    Checks of the package store (PackTune-Store.ps1) against a fake SharePoint kept in memory: site and library state,
    upload (one request and upload session in chunks), manifest written last, hash verification (changed file, swapped
    manifest, manifest against the Intune notes), incomplete versions, zip slip, names, settings. No network, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Store.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneStore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
. (Join-Path $repo 'PackTune-Main.ps1')

# --- the fake SharePoint: files by path, sessions, a site and drives
$script:Fs = @{}                 # "app/version/name" -> bytes
$script:Drives = @(@{ id = 'drive-1'; name = 'Documents' })
$script:Requests = New-Object System.Collections.ArrayList
$script:Sessions = @{}
$script:SiteReachable = $true
$script:Links = @()
function Invoke-PackTuneStoreGraph {
    param([string]$Method = 'GET', [string]$Path, [string]$Absolute, $Body, [string]$InFile, [byte[]]$Bytes, [string]$OutFile, [hashtable]$Headers = @{})
    [void]$script:Requests.Add("$Method $(if ($Absolute) { 'ABS' } else { $Path })")
    if ($Absolute) {
        $range = $Headers['Content-Range']
        if ($range -notmatch '^bytes (\d+)-(\d+)/(\d+)$') { throw 'no range' }
        $s = $script:Sessions[$Absolute]
        if ([int64]$Matches[1] -ne $s.Bytes.Count) { throw "chunk out of order: $range, have $($s.Bytes.Count)" }
        if (($Bytes.Length % 327680) -ne 0 -and ([int64]$Matches[2] + 1) -ne [int64]$Matches[3]) { throw 'chunk size is not a multiple of 320 KiB' }
        $s.Bytes.AddRange($Bytes)
        if ($s.Bytes.Count -eq [int64]$Matches[3]) { $script:Fs[$s.Key] = $s.Bytes.ToArray() }
        return $null
    }
    if (-not $script:SiteReachable -and $Path -like '/sites/*') { throw 'SharePoint GET failed (403): Access denied' }
    switch -Regex ("$Method $Path") {
        '^GET /sites/contoso\.sharepoint\.com:/sites/PackTune\?' { return [pscustomobject]@{ id = 'site-1'; displayName = 'PackTune'; webUrl = 'https://contoso.sharepoint.com/sites/PackTune' } }
        '^GET /sites/site-1/drives' { return [pscustomobject]@{ value = @($script:Drives | ForEach-Object { [pscustomobject]$_ }) } }
        '^POST /sites/site-1/lists$' { $script:Drives += @{ id = 'drive-2'; name = $Body.displayName }; return [pscustomobject]@{ id = 'list-1' } }
        '^GET /sites/site-1/lists/list-1/drive' { return [pscustomobject]@{ id = 'drive-2'; name = 'PackTune Packages' } }
        '^GET /drives/[^/]+/root/permissions' { return [pscustomobject]@{ value = @($script:Links | ForEach-Object { [pscustomobject]@{ link = @{ type = 'view' } } }) } }
        '^PUT /drives/[^/]+/root:/(.+):/content$' { $script:Fs[[uri]::UnescapeDataString($Matches[1])] = $Bytes; return $null }
        '^POST /drives/[^/]+/root:/(.+):/createUploadSession$' { $url = "https://upload.example/$([guid]::NewGuid().ToString('N'))"; $script:Sessions[$url] = @{ Key = [uri]::UnescapeDataString($Matches[1]); Bytes = (New-Object System.Collections.Generic.List[byte]) }; return [pscustomobject]@{ uploadUrl = $url } }
        '^GET /drives/[^/]+/root:/(.+):/content$' { $k = [uri]::UnescapeDataString($Matches[1]); if (-not $script:Fs.ContainsKey($k)) { throw "SharePoint GET failed (404): not found $k" }; [IO.File]::WriteAllBytes($OutFile, $script:Fs[$k]); return $null }
        '^GET /drives/[^/]+/root(:/(.+):)?/children' {
            $prefix = if ($Matches[2]) { [uri]::UnescapeDataString($Matches[2]) + '/' } else { '' }
            $names = @{}
            foreach ($k in $script:Fs.Keys) { if ($k.StartsWith($prefix)) { $rest = $k.Substring($prefix.Length); $first = $rest.Split('/')[0]; $names[$first] = ($rest.Contains('/')) } }
            return [pscustomobject]@{ value = @($names.Keys | Sort-Object | ForEach-Object { if ($names[$_]) { [pscustomobject]@{ name = $_; folder = @{ childCount = 1 } } } else { [pscustomobject]@{ name = $_; size = 1 } } }) }
        }
        '^DELETE /drives/[^/]+/root:/(.+)$' { $k = [uri]::UnescapeDataString($Matches[1]); foreach ($key in @($script:Fs.Keys)) { if ($key -eq $k -or $key.StartsWith("$k/")) { $script:Fs.Remove($key) } }; return $null }
        default { throw "fake SharePoint: $Method $Path" }
    }
}

# --- address and settings
Test-Check 'site address: only https://<tenant>.sharepoint.com/sites/<name>' ((Test-PackTuneStoreSiteUrl 'https://contoso.sharepoint.com/sites/PackTune') -and (Test-PackTuneStoreSiteUrl 'https://contoso.sharepoint.com/teams/x/') -and -not (Test-PackTuneStoreSiteUrl 'http://contoso.sharepoint.com/sites/x') -and -not (Test-PackTuneStoreSiteUrl 'https://evil.example/sites/x') -and -not (Test-PackTuneStoreSiteUrl 'https://contoso.sharepoint.com/sites/x/../y') -and -not (Test-PackTuneStoreSiteUrl ''))
$s = Get-PackTuneSettings; $s.StoreSiteUrl = 'https://evil.example/x'
$threw = $false; try { Save-PackTuneSettings -Settings $s } catch { $threw = $_.Exception.Message -like '*SharePoint site*' }
Test-Check 'settings: an invalid site address is refused' $threw
$s.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Save-PackTuneSettings -Settings $s | Out-Null; $script:Settings = Get-PackTuneSettings
Test-Check 'settings: site and library are saved (library default PackTune Packages)' (($script:Settings.StoreSiteUrl -eq 'https://contoso.sharepoint.com/sites/PackTune') -and ($script:Settings.StoreLibrary -eq 'PackTune Packages'))
foreach ($bad in 'a/b', '..', 'a b', '-x', 'x;y') { $threw = $false; try { $null = ConvertTo-PackTuneStorePath @($bad) } catch { $threw = $true }; Test-Check "store path: '$bad' is refused" $threw }
Test-Check 'store path: names are encoded and joined' ((ConvertTo-PackTuneStorePath @('app-1', '1.0.0', 'package.msix')) -eq 'app-1/1.0.0/package.msix')

# --- state
$empty = Get-PackTuneStoreState -SiteUrl ''
Test-Check 'state: no address -> NotConfigured' ($empty.State -eq 'NotConfigured')
$script:SiteReachable = $false
$denied = Get-PackTuneStoreState
Test-Check 'state: site not readable (no access granted) -> NoAccess with the way out' (($denied.State -eq 'NoAccess') -and ($denied.Message -like '*Grant access*'))
$script:SiteReachable = $true
$noLib = Get-PackTuneStoreState
Test-Check 'state: site fine, library missing -> NoLibrary' ($noLib.State -eq 'NoLibrary')
$store = Initialize-PackTuneStore
Test-Check 'library is created when missing' (($store.DriveId -eq 'drive-2') -and ($script:Drives.name -contains 'PackTune Packages'))
$ready = Get-PackTuneStoreState
Test-Check 'state: Ready' (($ready.State -eq 'Ready') -and ($ready.Store.DriveId -eq 'drive-2'))
$again = Initialize-PackTuneStore
Test-Check 'creating the library again changes nothing' (@($script:Drives).Count -eq 2 -and ($again.DriveId -eq 'drive-2'))
Test-Check 'sharing links on the library are a warning' ((@(Get-PackTuneStoreWarnings -Store $ready.Store).Count -eq 0) -and ($script:Links = @(1)) -and (@(Get-PackTuneStoreWarnings -Store $ready.Store).Count -eq 1))
$script:Links = @()

# --- publish a version: files, then the manifest last
$src = Join-Path $work 'src'; New-Item -ItemType Directory -Path (Join-Path $src 'installer\sub') -Force | Out-Null
'setup' | Set-Content (Join-Path $src 'installer\setup.exe'); 'data' | Set-Content (Join-Path $src 'installer\sub\a.txt')
$zip = New-PackTuneZip -Folder (Join-Path $src 'installer') -Path (Join-Path $src 'installer.zip')
$bigBytes = New-Object byte[] (2MB + 123); (New-Object Random 7).NextBytes($bigBytes)
[IO.File]::WriteAllBytes((Join-Path $src 'package.msix'), $bigBytes)
'{"name":"x"}' | Set-Content (Join-Path $src 'recipe.json'); 'cert' | Set-Content (Join-Path $src 'signing.cer')
$script:StoreSmallLimit = 100KB; $script:StoreChunk = 327680 * 2
$script:Requests.Clear()
$hash = Publish-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Store $ready.Store -Kind 'msix' -Files @{ 'package.msix' = (Join-Path $src 'package.msix'); 'installer.zip' = $zip; 'recipe.json' = (Join-Path $src 'recipe.json'); 'signing.cer' = (Join-Path $src 'signing.cer') }
$keys = @($script:Fs.Keys | Sort-Object)
Test-Check 'publish: one folder per app and version with the files and the manifest' ((($keys -join ',') -eq 'my-app-1a2b3c4d/1.0.0/installer.zip,my-app-1a2b3c4d/1.0.0/manifest.json,my-app-1a2b3c4d/1.0.0/package.msix,my-app-1a2b3c4d/1.0.0/recipe.json,my-app-1a2b3c4d/1.0.0/signing.cer')) ($keys -join ',')
Test-Check 'publish: the large file goes through an upload session in chunks, the small ones in one request' ((@($script:Requests | Where-Object { $_ -like 'POST *createUploadSession' }).Count -eq 1) -and (@($script:Requests | Where-Object { $_ -eq 'PUT ABS' }).Count -eq 4) -and ([BitConverter]::ToString($script:Fs['my-app-1a2b3c4d/1.0.0/package.msix']) -eq [BitConverter]::ToString($bigBytes)))
$lastPut = @($script:Requests | Where-Object { $_ -like 'PUT *' } | Select-Object -Last 1)
Test-Check 'publish: manifest.json is written last' ($lastPut[0] -like '*manifest.json*') ($lastPut -join ';')
$mf = [Text.Encoding]::UTF8.GetString($script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json']) | ConvertFrom-Json
Test-Check 'manifest: SHA256 and size of every file, app, version, kind' (($mf.format -eq 'PackTune.Store') -and ($mf.app -eq 'my-app-1a2b3c4d') -and ($mf.appVersion -eq '1.0.0') -and ($mf.kind -eq 'msix') -and (@($mf.files).Count -eq 4) -and ((@($mf.files | Where-Object name -eq 'package.msix').sha256) -eq (Get-FileHash (Join-Path $src 'package.msix') -Algorithm SHA256).Hash))
$manifestBytes = $script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json']
$sha = [Security.Cryptography.SHA256]::Create(); $expect = -join ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('X2') })
Test-Check 'the manifest hash that goes into the notes is the hash of the stored manifest' ($hash -eq $expect)
$bad = $false; try { Publish-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Store $ready.Store -Files @{ 'evil.exe' = (Join-Path $src 'recipe.json') } | Out-Null } catch { $bad = $true }
Test-Check 'publish: only the known file names' $bad
$bad = $false; try { Publish-PackTuneStoreVersion -AppId '..\x' -Version '1.0.0' -Store $ready.Store -Files @{ 'recipe.json' = (Join-Path $src 'recipe.json') } | Out-Null } catch { $bad = $true }
Test-Check 'publish: an app id with path characters is refused' $bad
$script:StoreSmallLimit = 4MB; $script:StoreChunk = 327680 * 32

# --- list
$versions = @(Get-PackTuneStoreVersions -AppId 'my-app-1a2b3c4d' -Store $ready.Store)
Test-Check 'list: the version is complete (has a manifest)' (($versions.Count -eq 1) -and ($versions[0].Version -eq '1.0.0') -and $versions[0].Complete)
$script:Fs['my-app-1a2b3c4d/1.1.0/package.msix'] = [byte[]](1, 2, 3)
$versions = @(Get-PackTuneStoreVersions -AppId 'my-app-1a2b3c4d' -Store $ready.Store)
Test-Check 'list: a version without manifest is shown as incomplete' ((@($versions | Where-Object { $_.Version -eq '1.1.0' -and -not $_.Complete }).Count -eq 1) -and (@($versions | Where-Object Complete).Count -eq 1))
Test-Check 'list: the apps of the store' ((@(Get-PackTuneStoreApps -Store $ready.Store) -join ',') -eq 'my-app-1a2b3c4d')
$script:Fs.Remove('my-app-1a2b3c4d/1.1.0/package.msix')

# --- export / download with verification
$out = Join-Path $work 'export1'
$saved = Save-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Destination $out -ExpectedManifest $hash.Substring(0, 16).ToLower() -Store $ready.Store
Test-Check 'export: all files verified and saved, the installer folder unpacked' ((Test-Path (Join-Path $out 'package.msix')) -and (Test-Path (Join-Path $out 'installer\setup.exe')) -and (Test-Path (Join-Path $out 'installer\sub\a.txt')) -and ($saved.Files.Count -eq 4) -and ($saved.ManifestHash -eq $hash) -and ($saved.Kind -eq 'msix'))
Test-Check 'export: the package is the one that was stored' ((Get-FileHash (Join-Path $out 'package.msix') -Algorithm SHA256).Hash -eq (Get-FileHash (Join-Path $src 'package.msix') -Algorithm SHA256).Hash)
# tampered file: one changed byte in installer.zip
$orig = $script:Fs['my-app-1a2b3c4d/1.0.0/installer.zip']
$tamper = $orig.Clone(); $tamper[10] = [byte](($tamper[10] + 1) % 256); $script:Fs['my-app-1a2b3c4d/1.0.0/installer.zip'] = $tamper
$out2 = Join-Path $work 'export2'
$threw = $false; $msg = ''; try { $null = Save-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Destination $out2 -Store $ready.Store } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'tamper: a changed byte in a stored file stops the export, nothing is unpacked' ($threw -and ($msg -like '*installer.zip*does not match*') -and -not (Test-Path (Join-Path $out2 'installer'))) $msg
$script:Fs['my-app-1a2b3c4d/1.0.0/installer.zip'] = $orig
# swapped manifest: a manifest that describes other files (made consistent) does not match the Intune notes
$evil = [Text.Encoding]::UTF8.GetString($script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json']).Replace('"appVersion":  "1.0.0"', '"appVersion":  "1.0.0" ')
$script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json'] = [Text.Encoding]::UTF8.GetBytes($evil)
$out3 = Join-Path $work 'export3'
$threw = $false; $msg = ''; try { $null = Save-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Destination $out3 -ExpectedManifest $hash.Substring(0, 16).ToLower() -Store $ready.Store } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Check 'tamper: a manifest that differs from the hash in the Intune notes is refused, nothing downloaded' ($threw -and ($msg -like '*does not match the one recorded in Intune*') -and -not (Test-Path (Join-Path $out3 'package.msix'))) $msg
$script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json'] = $manifestBytes
# manifest of another version copied here
$wrong = [Text.Encoding]::UTF8.GetString($manifestBytes).Replace('"appVersion":  "1.0.0"', '"appVersion":  "9.9.9"')
$script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json'] = [Text.Encoding]::UTF8.GetBytes($wrong)
$threw = $false; try { $null = Save-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Destination (Join-Path $work 'export4') -Store $ready.Store } catch { $threw = $_.Exception.Message -like '*does not belong*' }
Test-Check 'tamper: a manifest of another version is refused' $threw
$script:Fs['my-app-1a2b3c4d/1.0.0/manifest.json'] = $manifestBytes
$script:Fs.Remove('my-app-1a2b3c4d/1.0.0/recipe.json')
$threw = $false; try { $null = Save-PackTuneStoreVersion -AppId 'my-app-1a2b3c4d' -Version '1.0.0' -Destination (Join-Path $work 'export5') -Store $ready.Store } catch { $threw = $true }
Test-Check 'a file that is missing in the store stops the export' $threw
$script:Fs['my-app-1a2b3c4d/1.0.0/recipe.json'] = [IO.File]::ReadAllBytes((Join-Path $src 'recipe.json'))

# --- zip slip
Add-Type -AssemblyName System.IO.Compression.FileSystem
$evilZip = Join-Path $work 'evil.zip'
$z = [IO.Compression.ZipFile]::Open($evilZip, 'Create')
$e = $z.CreateEntry('fine.txt'); $w = New-Object IO.StreamWriter($e.Open()); $w.Write('ok'); $w.Dispose()
$e = $z.CreateEntry('../escaped.txt'); $w = New-Object IO.StreamWriter($e.Open()); $w.Write('bad'); $w.Dispose()
$z.Dispose()
$target = Join-Path $work 'unzip\inner'
$threw = $false; try { Expand-PackTuneZip -Path $evilZip -Destination $target } catch { $threw = $_.Exception.Message -like '*outside the target*' }
Test-Check 'zip slip: an entry outside the target refuses the whole archive, nothing written' ($threw -and -not (Test-Path (Join-Path $work 'unzip\escaped.txt')) -and -not (Test-Path (Join-Path $target 'fine.txt')))

# --- notes carry the manifest start, nothing more
$info = [pscustomobject]@{ Version = '1.0.0'; ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}'; UpgradeCode = '{11111111-2222-3333-4444-555555555555}' }
$notes = ConvertTo-PackTuneCustomNotes -Info $info -AppId 'my-app-1a2b3c4d' -Manifest $hash
$parsed = ConvertFrom-PackTuneCustomNotes $notes
Test-Check 'notes: the start of the manifest hash is recorded and read back' (($notes -like '*;manifest=????????????????') -and ($parsed.Manifest -eq $hash.Substring(0, 16).ToLower()))

# --- delete
Remove-PackTuneStoreApp -AppId 'my-app-1a2b3c4d' -Store $ready.Store
Test-Check 'delete: the folder of the app is gone from the store' (@(Get-PackTuneStoreApps -Store $ready.Store).Count -eq 0 -and $script:Fs.Count -eq 0)

# --- access grant: validated before any call
foreach ($case in @(@('http://x.sharepoint.com/sites/a', '11111111-2222-3333-4444-555555555555'), @('https://contoso.sharepoint.com/sites/a', 'not-a-guid'))) {
    $threw = $false; try { $null = Grant-PackTuneStoreAccess -SiteUrl $case[0] -ClientID $case[1] -Token 'x' } catch { $threw = $true }
    Test-Check "grant: refused before any request ($($case -join ' / '))" $threw
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
