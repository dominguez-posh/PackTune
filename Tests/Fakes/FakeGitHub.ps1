# A fake GitHub kept in memory for the checks of the custom repositories: replaces Invoke-PackTuneGitHub (dot-source after PackTune-Main.ps1).
# Repositories with commits (snapshots), blobs, trees, refs, releases and assets, auth (public / private / write), rate limit, ETags,
# verification flags. No network.
$script:Gh = @{
    Repos = @{}          # "owner/name" lower -> repo
    Blobs = @{}          # sha -> bytes
    Trees = @{}          # sha -> @{ path -> blobsha }
    Commits = @{}        # sha -> @{ Tree; Parent; Author; Message; Verified; Paths }
    Tokens = @{}         # token -> @{ Repos = @(...); Write = $bool }
    Requests = (New-Object System.Collections.ArrayList)
    RateRemaining = 1000
    Offline = $false
    Seq = 0
}
function New-GhSha { $script:Gh.Seq++; return ('{0:x40}' -f ($script:Gh.Seq * 7919 + 4096)) }
function New-FakeRepo {
    param([string]$FullName, [bool]$Private = $false, [int64]$Id = 1000, [string]$Branch = 'main', [bool]$Fork = $false)
    $c = New-GhSha
    $t = New-GhSha
    $script:Gh.Trees[$t] = @{}
    $script:Gh.Commits[$c] = @{ Tree = $t; Parent = $null; Author = 'Init'; Message = 'init'; Verified = $true; Paths = @() }
    $script:Gh.Repos[$FullName.ToLower()] = @{ Id = $Id; FullName = $FullName; Private = $Private; Fork = $Fork; Branch = $Branch; Head = $c; Releases = @{}; Protected = $true; Alias = @() }
}
function Get-FakeRepoFiles($Repo) { $script:Gh.Trees[$script:Gh.Commits[$Repo.Head].Tree] }
function Add-FakeCommit {
    # files: path -> bytes; adds one commit (path prefix list for the commits API)
    param($Repo, [hashtable]$Files, [string]$Author = 'Alice Admin', [bool]$Verified = $true, [string]$Message = 'commit')
    $tree = @{}; foreach ($k in (Get-FakeRepoFiles $Repo).Keys) { $tree[$k] = (Get-FakeRepoFiles $Repo)[$k] }
    foreach ($k in $Files.Keys) { $sha = New-GhSha; $script:Gh.Blobs[$sha] = [byte[]]$Files[$k]; $tree[$k] = $sha }
    $t = New-GhSha; $script:Gh.Trees[$t] = $tree
    $c = New-GhSha
    $script:Gh.Commits[$c] = @{ Tree = $t; Parent = $Repo.Head; Author = $Author; Message = $Message; Verified = $Verified; Paths = @($Files.Keys) }
    $Repo.Head = $c
    return $c
}
function Get-FakeAuth([string]$Token) { if ($Token -and $script:Gh.Tokens.ContainsKey($Token)) { $script:Gh.Tokens[$Token] } else { $null } }
function New-GhResponse($Status, $Body = $null, [hashtable]$Headers = @{}) {
    $h = @{ 'x-ratelimit-remaining' = [string]$script:Gh.RateRemaining; 'x-ratelimit-limit' = '5000' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    [pscustomobject]@{ Status = $Status; Body = $(if ($null -ne $Body) { [pscustomobject]$Body } else { $null }); Headers = $h }
}
function Invoke-PackTuneGitHub {
    param([string]$Method = 'GET', [string]$Path, [string]$Absolute, [string]$Token, $Body, [byte[]]$Bytes, [string]$InFile, [string]$OutFile, [string]$Accept, [string]$IfNoneMatch, [string]$ContentType)
    [void]$script:Gh.Requests.Add([pscustomobject]@{ Method = $Method; Path = $(if ($Absolute) { $Absolute } else { $Path }); Token = $Token; IfNoneMatch = $IfNoneMatch })
    if ($script:Gh.Offline) { throw 'GitHub could not be reached: offline' }
    $url = if ($Absolute) { $Absolute } else { $Path }
    if ($url -notmatch '^(https://(api|uploads)\.github\.com)?(/repos/(?<o>[^/]+)/(?<r>[^/?]+)|/repositories/\d+)') { return (New-GhResponse 404 @{ message = 'Not Found' }) }
    $full = "$($Matches['o'])/$($Matches['r'])"
    $repo = $script:Gh.Repos[$full.ToLower()]
    $auth = Get-FakeAuth $Token
    if (-not $Token) {
        $script:Gh.RateRemaining--
        if ($script:Gh.RateRemaining -lt 0) { return (New-GhResponse 403 @{ message = 'API rate limit exceeded' } @{ 'x-ratelimit-remaining' = '0'; 'retry-after' = '1' }) }
    }
    if ($Token -and -not $auth) { return (New-GhResponse 401 @{ message = 'Bad credentials' }) }
    if (-not $repo) { return (New-GhResponse 404 @{ message = 'Not Found' }) }
    if ($repo.Private -and (-not $auth -or $auth.Repos -notcontains $repo.FullName.ToLower())) { return (New-GhResponse 404 @{ message = 'Not Found' }) }
    $canWrite = $auth -and $auth.Write -and $auth.Repos -contains $repo.FullName.ToLower()
    if ($Method -ne 'GET' -and -not $canWrite) { return (New-GhResponse 403 @{ message = 'Resource not accessible by personal access token' }) }
    $rest = $url -replace '^https://[^/]+', ''
    $rest = $rest -replace "^/repos/[^/]+/[^/?]+", ''
    $owner = $repo.FullName.Split('/')[0]
    switch -Regex ("$Method $rest") {
        '^GET $' {
            return (New-GhResponse 200 @{ id = $repo.Id; name = $repo.FullName.Split('/')[1]; full_name = $repo.FullName; private = $repo.Private; fork = $repo.Fork; default_branch = $repo.Branch; owner = [pscustomobject]@{ login = $owner }; permissions = [pscustomobject]@{ push = [bool]$canWrite; pull = $true } } @{ 'content-type' = 'application/json' })
        }
        '^GET /branches/' { return (New-GhResponse 200 @{ name = $repo.Branch; protected = $repo.Protected }) }
        '^GET /contents/(?<p>[^?]+)\?' {
            $p = [uri]::UnescapeDataString($Matches['p'])
            $files = Get-FakeRepoFiles $repo
            if (-not $files.ContainsKey($p)) { return (New-GhResponse 404 @{ message = 'Not Found' }) }
            $bytes = $script:Gh.Blobs[$files[$p]]
            $etag = '"' + $files[$p] + '"'
            if ($IfNoneMatch -and $IfNoneMatch -eq $etag) { return (New-GhResponse 304 $null @{ etag = $etag }) }
            if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, $bytes) }
            return (New-GhResponse 200 $null @{ etag = $etag })
        }
        '^GET /commits\?path=(?<p>[^&]+)' {
            $p = [uri]::UnescapeDataString($Matches['p']); $sha = $repo.Head
            while ($sha) { $c = $script:Gh.Commits[$sha]; if (@($c.Paths | Where-Object { $_ -like "$p/*" -or $_ -eq $p }).Count) { break }; $sha = $c.Parent }
            if (-not $sha) { return (New-GhResponse 200 ([pscustomobject]@{}) ) }
            $c = $script:Gh.Commits[$sha]
            $one = [pscustomobject]@{ sha = $sha; commit = [pscustomobject]@{ author = [pscustomobject]@{ name = $c.Author; date = '2026-11-01T10:00:00Z' }; message = $c.Message; verification = [pscustomobject]@{ verified = $c.Verified; reason = $(if ($c.Verified) { 'valid' } else { 'unsigned' }) } }; author = [pscustomobject]@{ login = 'alice' } }
            return [pscustomobject]@{ Status = 200; Body = @($one); Headers = @{ 'x-ratelimit-remaining' = [string]$script:Gh.RateRemaining; 'x-ratelimit-limit' = '5000' } }
        }
        '^GET /git/ref/heads/' { return (New-GhResponse 200 @{ object = [pscustomobject]@{ sha = $repo.Head } }) }
        '^GET /git/commits/(?<s>\w+)' { $c = $script:Gh.Commits[$Matches['s']]; return (New-GhResponse 200 @{ tree = [pscustomobject]@{ sha = $c.Tree } }) }
        '^POST /git/blobs' {
            $sha = New-GhSha; $script:Gh.Blobs[$sha] = [Convert]::FromBase64String([string]$Body.content)
            return (New-GhResponse 201 @{ sha = $sha })
        }
        '^POST /git/trees' {
            $tree = @{}; foreach ($k in $script:Gh.Trees[[string]$Body.base_tree].Keys) { $tree[$k] = $script:Gh.Trees[[string]$Body.base_tree][$k] }
            foreach ($e in @($Body.tree)) { $tree[[string]$e.path] = [string]$e.sha }
            $t = New-GhSha; $script:Gh.Trees[$t] = $tree
            return (New-GhResponse 201 @{ sha = $t })
        }
        '^POST /git/commits' {
            $c = New-GhSha
            $base = $script:Gh.Trees[$script:Gh.Commits[[string]@($Body.parents)[0]].Tree]
            $changed = @($script:Gh.Trees[[string]$Body.tree].Keys | Where-Object { -not $base.ContainsKey($_) -or $base[$_] -ne $script:Gh.Trees[[string]$Body.tree][$_] })
            $script:Gh.Commits[$c] = @{ Tree = [string]$Body.tree; Parent = [string]@($Body.parents)[0]; Author = 'Writer'; Message = [string]$Body.message; Verified = $false; Paths = $changed }
            return (New-GhResponse 201 @{ sha = $c })
        }
        '^PATCH /git/refs/heads/' {
            if ($script:Gh.Commits[[string]$Body.sha].Parent -ne $repo.Head) { return (New-GhResponse 422 @{ message = 'Update is not a fast forward' }) }
            $repo.Head = [string]$Body.sha; return (New-GhResponse 200 @{ ok = $true })
        }
        '^GET /releases/tags/(?<t>.+)$' {
            $tag = [uri]::UnescapeDataString($Matches['t'])
            if (-not $repo.Releases.ContainsKey($tag)) { return (New-GhResponse 404 @{ message = 'Not Found' }) }
            $rel = $repo.Releases[$tag]
            return (New-GhResponse 200 @{ id = $rel.Id; assets = @($rel.Assets.Keys | ForEach-Object { [pscustomobject]@{ id = $rel.Assets[$_].Id; name = $_; size = $rel.Assets[$_].Bytes.Length } }) })
        }
        '^POST /releases$' {
            $rel = @{ Id = (1000 + $repo.Releases.Count + 1); Assets = @{} }; $repo.Releases[[string]$Body.tag_name] = $rel
            return (New-GhResponse 201 @{ id = $rel.Id; assets = @() })
        }
        '^POST /releases/(?<id>\d+)/assets\?name=(?<n>.+)$' {
            $name = [uri]::UnescapeDataString($Matches['n']); $rid = [int]$Matches['id']
            $rel = @($repo.Releases.Values | Where-Object { $_.Id -eq $rid })[0]
            $data = if ($InFile) { [IO.File]::ReadAllBytes($InFile) } else { $Bytes }
            $rel.Assets[$name] = @{ Id = (5000 + (++$script:Gh.Seq)); Bytes = $data }
            return (New-GhResponse 201 @{ id = $rel.Assets[$name].Id })
        }
        '^GET /releases/assets/(?<id>\d+)' {
            $aid = [int]$Matches['id']
            foreach ($rel in $repo.Releases.Values) { foreach ($n in $rel.Assets.Keys) { if ($rel.Assets[$n].Id -eq $aid) { [IO.File]::WriteAllBytes($OutFile, $rel.Assets[$n].Bytes); return (New-GhResponse 200) } } }
            return (New-GhResponse 404 @{ message = 'Not Found' })
        }
        default { throw "fake GitHub: $Method $url" }
    }
}
