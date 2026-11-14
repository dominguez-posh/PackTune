# A fake SharePoint kept in memory for the checks of the package store: replaces Invoke-PackTuneStoreGraph (dot-source it after PackTune-Main.ps1)
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

