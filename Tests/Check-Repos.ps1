<#
.SYNOPSIS
    Checks of the custom repositories (PackTune-Repos.ps1) against a fake GitHub kept in memory: connecting public and private
    repositories, pinning (rename, other repository, fork), the index (damaged, oversized, ETag cache, stale), verification
    (changed file, manifest against index, zip slip, size), approval of every new version, signed commits, rate limits,
    token handling, deployment of a repository MSI through the fake Intune module (notes carry repo and commit), Move to
    repository (write grant, copy, verify, idempotence, release assets, confirmed removal, export from the repository), the
    template and the clone check. No network, no GitHub account, no tenant.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Check-Repos.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([IO.Path]::GetTempPath()) ('PackTuneRepos-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'PackTune') -Force | Out-Null
$env:LOCALAPPDATA = $work
$env:PSModulePath = (Join-Path $PSScriptRoot 'Fakes') + ';' + $env:PSModulePath
$script:Failed = 0
function Test-Check([string]$Name, $Ok, $Detail) { if ($Ok) { "PASS  $Name" } else { $script:Failed++; "FAIL  $Name  $Detail" } }
function Test-Throws([scriptblock]$Block, [string]$Like) { try { & $Block | Out-Null; return $false } catch { return ($Like -eq '' -or $_.Exception.Message -like $Like) } }
function Get-Message([scriptblock]$Block) { try { & $Block | Out-Null; return '' } catch { return $_.Exception.Message } }

. (Join-Path $repo 'PackTune-Main.ps1')
Import-Module IntuneWin32App -Force
$Global:AccessToken = [pscustomobject]@{ ExpiresOn = (Get-Date).AddHours(2).ToUniversalTime(); access_token = 'x.e30.y' }
$Global:AuthenticationHeader = @{ Authorization = 'Bearer x'; ExpiresOn = $Global:AccessToken.ExpiresOn }
$Global:AccessTokenTenantID = 'contoso.onmicrosoft.com'
. (Join-Path $PSScriptRoot 'Fakes\FakeSharePoint.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeGitHub.ps1')
function Get-Store { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }
$script:Waited = 0
function Wait-PackTuneGitHub([int]$Seconds) { $script:Waited += $Seconds; $script:Gh.RateRemaining = 100 }


# The sandbox lab is faked: the verdict is set per check, every call is kept (scripts, previous version)
$script:LabVerdict = 'Passed'; $script:LabCalls = New-Object System.Collections.ArrayList
function Start-PackTuneWin32Lab {
    param([string]$DisplayName, [string]$Version, [hashtable]$Scripts, [string]$SourcePath, [hashtable]$PreviousScripts, [string]$PreviousSourcePath, [string]$PreviousVersion, [switch]$AutoRun)
    [void]$script:LabCalls.Add(@{ Name = $DisplayName; Previous = [bool]$PreviousScripts; AutoRun = [bool]$AutoRun })
    $steps = @(@{ Name = 'Detect before'; Status = 'Passed' }, @{ Name = 'Install'; Status = $(if ($script:LabVerdict -eq 'Passed') { 'Passed' } else { 'Failed' }) })
    [pscustomobject]@{ State = $(if ($script:LabVerdict -eq 'Passed') { 'Succeeded' } else { 'Failed' }); Verdict = $script:LabVerdict; Message = $(if ($script:LabVerdict -eq 'Passed') { 'All 5 steps passed' } else { 'Failed at step 2 of 5: Install exited with 1603' }); Result = $steps; JobPath = 'x' }
}

function New-TestMsi {
    param([string]$Path, [hashtable]$Properties)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 3))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(255) NOT NULL PRIMARY KEY `Property`)'))
    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    foreach ($key in $Properties.Keys) {
        $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('$key', '$($Properties[$key])')"))
        [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
        [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    }
    [void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
    foreach ($o in $v, $view, $db, $installer) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
function Get-Sha([byte[]]$Bytes) { $s = [Security.Cryptography.SHA256]::Create(); try { -join ($s.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() } }

$upgrade = '{11111111-2222-3333-4444-555555555555}'
$msi1 = Join-Path $work 'contoso-tool-1.0.msi'; $msi2 = Join-Path $work 'contoso-tool-2.0.msi'
New-TestMsi $msi1 @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000001}'; ProductName = 'Contoso Tool'; ProductVersion = '1.0.0'; Manufacturer = 'Contoso Ltd'; UpgradeCode = $upgrade }
New-TestMsi $msi2 @{ ProductCode = '{AAAAAAAA-0000-0000-0000-000000000002}'; ProductName = 'Contoso Tool'; ProductVersion = '2.0.0'; Manufacturer = 'Contoso Ltd'; UpgradeCode = $upgrade }
$appId = Get-PackTuneCustomAppId (Get-PackTuneMsiInfo -Path $msi1)

# A version in the store layout: files, manifest (written like Publish-PackTuneStoreVersion). Returns files by repository path and the manifest hash.
function New-TestVersionFiles {
    param([string]$AppId, [string]$Version, [string]$Msi, [string]$Arguments = '', [switch]$EvilZip, [string]$Kind = 'msi')
    $dir = Join-Path $work "ver-$AppId-$Version-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
    New-Item -ItemType Directory -Path (Join-Path $dir 'installer') -Force | Out-Null
    Copy-Item $Msi (Join-Path $dir 'installer\setup.msi')
    $zip = Join-Path $dir 'installer.zip'
    if ($EvilZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::Open($zip, 'Create'); $e = $z.CreateEntry('../escaped.txt'); $w = New-Object IO.StreamWriter($e.Open()); $w.Write('bad'); $w.Dispose(); $z.Dispose()
    } else { New-PackTuneZip -Folder (Join-Path $dir 'installer') -Path $zip | Out-Null }
    $pkg = New-Object byte[] 5000; (New-Object Random ([int]$Version.Replace('.', '').PadRight(3, '0'))).NextBytes($pkg)
    [IO.File]::WriteAllBytes((Join-Path $dir 'package.intunewin'), $pkg)
    [IO.File]::WriteAllText((Join-Path $dir 'recipe.json'), (([ordered]@{ format = 'PackTune.Recipe'; kind = $Kind; app = $AppId; name = 'Contoso Tool'; version = $Version; publisher = 'Contoso Ltd'; msi = 'setup.msi'; arguments = $Arguments }) | ConvertTo-Json))
    $entries = foreach ($n in 'installer.zip', 'package.intunewin', 'recipe.json') { $i = Get-Item (Join-Path $dir $n); [ordered]@{ name = $n; sha256 = (Get-FileHash $i.FullName -Algorithm SHA256).Hash; size = $i.Length } }
    $manifest = [ordered]@{ format = 'PackTune.Store'; version = 1; app = $AppId; appVersion = $Version; kind = $Kind; created = '2026-11-01T00:00:00Z'; files = @($entries) }
    [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    $files = @{}
    foreach ($n in 'installer.zip', 'package.intunewin', 'recipe.json', 'manifest.json') { $files["apps/$AppId/$Version/$n"] = [IO.File]::ReadAllBytes((Join-Path $dir $n)) }
    [pscustomobject]@{ Files = $files; Manifest = (Get-FileHash (Join-Path $dir 'manifest.json') -Algorithm SHA256).Hash.ToLower(); Dir = $dir }
}
function New-TestIndex($Versions, [string]$Id = $appId, [string]$Name = 'Contoso packages') {
    $json = [ordered]@{ format = 1; name = $Name; apps = @([ordered]@{ id = $Id; name = 'Contoso Tool'; publisher = 'Contoso Ltd'; kind = 'msi'; versions = @($Versions | ForEach-Object { [ordered]@{ version = $_.Version; path = "apps/$Id/$($_.Version)"; manifest = $_.Hash; released = '2026-11-01' } }) }) }
    [Text.Encoding]::UTF8.GetBytes(($json | ConvertTo-Json -Depth 8))
}
function Publish-TestVersion($Repo, $V, [string]$Version, [bool]$Verified = $true, $Existing = @()) {
    $files = @{}; foreach ($k in $V.Files.Keys) { $files[$k] = $V.Files[$k] }
    $all = @($Existing) + @([pscustomobject]@{ Version = $Version; Hash = $V.Manifest })
    $files['packtune.json'] = New-TestIndex $all
    Add-FakeCommit -Repo $Repo -Files $files -Verified $Verified -Message "Add Contoso Tool $Version" | Out-Null
}

# ---------------------------------------------------------------- names, addresses, transport rules
Test-Check 'repository: owner/name and github.com URLs are accepted' ((ConvertTo-PackTuneRepoKey 'contoso/packages') -eq 'contoso/packages' -and (ConvertTo-PackTuneRepoKey 'https://github.com/contoso/packages.git') -eq 'contoso/packages' -and (ConvertTo-PackTuneRepoKey 'https://github.com/contoso/packages/') -eq 'contoso/packages')
foreach ($bad in 'contoso', 'a/b/c', '../x', 'contoso/..', 'https://evil.example/contoso/packages', 'con toso/x', '-x/y', 'x/y;z') { Test-Check "repository: '$bad' is refused" (Test-Throws { ConvertTo-PackTuneRepoKey $bad } '') }
Test-Check 'transport: only https to the GitHub hosts' ((Test-PackTuneGitHubUrl 'https://api.github.com/repos/a/b') -and (Test-PackTuneGitHubUrl 'https://objects.githubusercontent.com/x') -and -not (Test-PackTuneGitHubUrl 'http://api.github.com/x') -and -not (Test-PackTuneGitHubUrl 'https://api.github.com.evil.example/x') -and -not (Test-PackTuneGitHubUrl 'https://evil.example/x') -and -not (Test-PackTuneGitHubUrl 'not a url'))

# ---------------------------------------------------------------- public repository: connect, list
$v1 = New-TestVersionFiles -AppId $appId -Version '1.0.0' -Msi $msi1
$v2 = New-TestVersionFiles -AppId $appId -Version '2.0.0' -Msi $msi2
New-FakeRepo -FullName 'thirdparty/tools' -Id 11
$pub = $script:Gh.Repos['thirdparty/tools']
Publish-TestVersion $pub $v1 '1.0.0'
$e = Add-PackTuneRepository -Repository 'https://github.com/thirdparty/tools' -DisplayName 'Third party tools'
Test-Check 'public: connected without a token, pinned by owner/name and id, labelled third party' ($e.RepoId -eq 11 -and $e.ThirdParty -and -not $e.Private -and $e.Owner -eq 'thirdparty' -and $null -eq (Get-PackTuneRepoToken 'thirdparty/tools'))
Test-Check 'public: connecting it twice is refused' (Test-Throws { Add-PackTuneRepository -Repository 'thirdparty/tools' } '*connected already*')
$rows = @(Get-PackTuneRepositoryApps -Repository 'thirdparty/tools')
Test-Check 'list: source label, version, third-party flag, not approved yet' ($rows.Count -eq 1 -and $rows[0].Source -eq 'Repository: Third party tools' -and $rows[0].Latest -eq '1.0.0' -and $rows[0].ThirdParty -and -not $rows[0].Approved -and $rows[0].Name -eq 'Contoso Tool')
Test-Check 'public: the requests went without a token' (@($script:Gh.Requests | Where-Object { $_.Token }).Count -eq 0)
$w1 = @(Get-PackTuneRepoWarnings 'thirdparty/tools') -join ' '; $pub.Protected = $false; $w2 = @(Get-PackTuneRepoWarnings 'thirdparty/tools') -join ' '
Test-Check 'public: a third-party source is labelled, a branch that is not protected is warned about' ($w1 -like '*Third-party source*' -and $w1 -notlike '*not protected*' -and $w2 -like '*not protected*') "$w1 | $w2"
$pub.Protected = $true

# ---------------------------------------------------------------- index: etag cache, damaged, oversized, stale
$n = $script:Gh.Requests.Count
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools'
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools'
$withEtag = @($script:Gh.Requests | Select-Object -Skip $n | Where-Object { $_.IfNoneMatch })
Test-Check 'index: the second read sends the ETag and uses the cache on 304' ($withEtag.Count -eq 2 -and (Get-PackTuneRepoIndex -Repository 'thirdparty/tools').Apps.Count -eq 1) "etags=$($withEtag.Count)"
New-FakeRepo -FullName 'thirdparty/broken' -Id 12
$broken = $script:Gh.Repos['thirdparty/broken']
$badIndex = '{"format":1,"name":"x","apps":[{"id":"..","name":"x","kind":"msi","versions":[{"version":"1.0","path":"apps/../1.0","manifest":"abc"}]}]}'
Add-FakeCommit -Repo $broken -Files @{ 'packtune.json' = [Text.Encoding]::UTF8.GetBytes($badIndex) } | Out-Null
$null = Add-PackTuneRepository -Repository 'thirdparty/broken' 3>$null
$idx = Get-PackTuneRepoIndex -Repository 'thirdparty/broken'
Test-Check 'index: path traversal in app id and path, a bad manifest hash: damaged, nothing listed' ($idx.Damaged -and $idx.Problems.Count -ge 1 -and @($idx.Apps).Count -eq 0)
Test-Check 'index: a damaged repository cannot be listed for deployment' (Test-Throws { Get-PackTuneRepositoryApps -Repository 'thirdparty/broken' } '*damaged*')
New-FakeRepo -FullName 'thirdparty/empty' -Id 13
$null = Add-PackTuneRepository -Repository 'thirdparty/empty' 3>$null
Test-Check 'index: a repository without packtune.json is damaged with a clear message' ((Get-PackTuneRepoIndex -Repository 'thirdparty/empty').Problems[0] -like '*no packtune.json*')
New-FakeRepo -FullName 'thirdparty/huge' -Id 14
Add-FakeCommit -Repo $script:Gh.Repos['thirdparty/huge'] -Files @{ 'packtune.json' = (New-Object byte[] (1MB + 10)) } | Out-Null
$huge = Add-PackTuneRepository -Repository 'thirdparty/huge' -DisplayName huge 3>$null
Test-Check 'index: an index above the size cap is refused' (Test-Throws { Get-PackTuneRepoIndex -Repository 'thirdparty/huge' -Refresh } '*larger than*')
$script:Gh.Offline = $true
$stale = Get-PackTuneRepoIndex -Repository 'thirdparty/tools'
Test-Check 'offline: the last known index is shown as stale' ($stale.Stale -and $stale.Apps.Count -eq 1)
Test-Check 'offline: nothing is deployed from a stale repository' (Test-Throws { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Destination (Join-Path $work 'stale') -ExpectedManifest $v1.Manifest } '*')
$script:Gh.Offline = $false

# ---------------------------------------------------------------- approval
$req = Get-PackTuneRepoApprovalRequest -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0'
Test-Check 'approval: shows repository label, third-party, commit (sha, author, message, signature), files with hashes' ($req.Label -eq 'Repository: Third party tools' -and $req.ThirdParty -and $req.Commit.Sha.Length -eq 40 -and $req.Commit.Author -eq 'Alice Admin' -and $req.Commit.Verified -and $req.Commit.Message -like 'Add Contoso Tool*' -and $req.Files.Count -eq 3 -and ($req.Files | Where-Object Status -ne 'new').Count -eq 0 -and $req.Manifest -eq $v1.Manifest -and -not $req.Blocked)
Test-Check 'approval: a version is not deployable before it is approved' (-not (Test-PackTuneRepoApproved -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Manifest $v1.Manifest))
Test-Check 'approval: downloading needs the manifest hash (fail closed)' (Test-Throws { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Destination (Join-Path $work 'nohash') -ExpectedManifest '' } '*No approved manifest*')
$rec = Approve-PackTuneRepoVersion -Request $req
Test-Check 'approval: recorded with commit, author, who and when' ($rec.Commit -eq $req.Commit.Sha -and $rec.Manifest -eq $v1.Manifest -and $rec.ApprovedBy -and (Test-PackTuneRepoApproved -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Manifest $v1.Manifest))
# a new version: shown against the approved one
Publish-TestVersion $pub $v2 '2.0.0' $true @([pscustomobject]@{ Version = '1.0.0'; Hash = $v1.Manifest })
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools' -Refresh
$req2 = Get-PackTuneRepoApprovalRequest -Repository 'thirdparty/tools' -AppId $appId -Version '2.0.0'
Test-Check 'approval: a new version needs its own approval and shows what changed against the approved one' ($req2.PreviousVersion -eq '1.0.0' -and (-not (Test-PackTuneRepoApproved -Repository 'thirdparty/tools' -AppId $appId -Version '2.0.0' -Manifest $v2.Manifest)) -and (@($req2.Files | Where-Object { $_.Name -eq 'installer.zip' -and $_.Status -eq 'changed' }).Count -eq 1))
Test-Check 'approval: the list shows the newest version as not approved' (@(Get-PackTuneRepositoryApps -Repository 'thirdparty/tools')[0].Latest -eq '2.0.0' -and -not @(Get-PackTuneRepositoryApps -Repository 'thirdparty/tools')[0].Approved)
# a request that is out of date is refused
Test-Check 'approval: a blocked request cannot be approved' (Test-Throws { Approve-PackTuneRepoVersion -Request ([pscustomobject]@{ Blocked = 'x'; Repository = 'thirdparty/tools'; AppId = $appId; Version = '2.0.0' }) } '*Cannot be approved*')
Add-FakeCommit -Repo $pub -Files @{ 'unrelated.txt' = [byte[]](1) } | Out-Null
$rec2 = Approve-PackTuneRepoVersion -Request $req2
Test-Check 'approval: an unrelated later commit does not change what was approved' ($rec2.Version -eq '2.0.0')
# a changed manifest after approval is not approved any more
$v2b = New-TestVersionFiles -AppId $appId -Version '2.0.0' -Msi $msi2 -Arguments 'ALLUSERS=1'
Publish-TestVersion $pub $v2b '2.0.0' $true @([pscustomobject]@{ Version = '1.0.0'; Hash = $v1.Manifest })
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools' -Refresh
Test-Check 'approval: a changed manifest of an approved version needs a new approval' (-not (Test-PackTuneRepoApproved -Repository 'thirdparty/tools' -AppId $appId -Version '2.0.0' -Manifest $v2b.Manifest) -and (Test-PackTuneRepoApproved -Repository 'thirdparty/tools' -AppId $appId -Version '2.0.0' -Manifest $v2.Manifest))
Test-Check 'approval: the old approval does not unlock the changed manifest for download' (Test-Throws { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '2.0.0' -Destination (Join-Path $work 'changed') -ExpectedManifest $v2.Manifest } '*not the one that was approved*')
# restore the approved content
Publish-TestVersion $pub $v2 '2.0.0' $true @([pscustomobject]@{ Version = '1.0.0'; Hash = $v1.Manifest })
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools' -Refresh

# ---------------------------------------------------------------- download and verification
$dest = Join-Path $work 'save1'
$saved = Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Destination $dest -ExpectedManifest $v1.Manifest
Test-Check 'download: every file verified, installer.zip unpacked, manifest hash returned' ($saved.Files.Count -eq 3 -and (Test-Path (Join-Path $dest 'installer\setup.msi')) -and $saved.ManifestHash -eq $v1.Manifest -and $saved.Kind -eq 'msi')
$key = "apps/$appId/1.0.0/package.intunewin"
$treeOf = { $script:Gh.Trees[$script:Gh.Commits[$pub.Head].Tree] }
$orig = (& $treeOf)[$key]
$t = $script:Gh.Blobs[$orig].Clone(); $t[7] = [byte](($t[7] + 1) % 256); $newBlob = New-GhSha; $script:Gh.Blobs[$newBlob] = $t
(& $treeOf)[$key] = $newBlob
$m = Get-Message { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Destination (Join-Path $work 'save2') -ExpectedManifest $v1.Manifest }
Test-Check 'tamper: a changed byte in a file stops the download, nothing unpacked' ($m -like '*package.intunewin*does not match the manifest*' -and -not (Test-Path (Join-Path $work 'save2\installer')))
$short = New-GhSha; $script:Gh.Blobs[$short] = [byte[]](1, 2, 3); (& $treeOf)[$key] = $short
Test-Check 'tamper: a file of another size is refused before hashing it' (Test-Throws { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Destination (Join-Path $work 'save3') -ExpectedManifest $v1.Manifest } '*another size*')
(& $treeOf)[$key] = $orig
$mk = "apps/$appId/1.0.0/manifest.json"; $origM = (& $treeOf)[$mk]
$evilM = New-GhSha; $script:Gh.Blobs[$evilM] = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($script:Gh.Blobs[$origM]).Replace('"kind":  "msi"', '"kind":  "msi" '))
(& $treeOf)[$mk] = $evilM
Test-Check 'tamper: a manifest that differs from the index hash is refused (damaged repository)' (Test-Throws { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Destination (Join-Path $work 'save4') -ExpectedManifest $v1.Manifest } '*does not match the hash in the index*')
(& $treeOf)[$mk] = $origM
foreach ($badId in '..', 'a/b', '..\x') { Test-Check "path: app id '$badId' never reaches a request" (Test-Throws { Save-PackTuneRepoVersion -Repository 'thirdparty/tools' -AppId $badId -Version '1.0.0' -Destination (Join-Path $work 'x') -ExpectedManifest $v1.Manifest } '*') }
# zip slip: installer.zip with a ../ entry whose hashes are right
$evil = New-TestVersionFiles -AppId 'evil-1' -Version '1.0.0' -Msi $msi1 -EvilZip
New-FakeRepo -FullName 'thirdparty/evil' -Id 15
Add-FakeCommit -Repo $script:Gh.Repos['thirdparty/evil'] -Files (@{ 'packtune.json' = (New-TestIndex @([pscustomobject]@{ Version = '1.0.0'; Hash = $evil.Manifest }) 'evil-1') } + $evil.Files) | Out-Null
$null = Add-PackTuneRepository -Repository 'thirdparty/evil' 3>$null
Test-Check 'zip slip: an installer.zip entry outside the target refuses the version, nothing written outside' (((Get-Message { Save-PackTuneRepoVersion -Repository 'thirdparty/evil' -AppId 'evil-1' -Version '1.0.0' -Destination (Join-Path $work 'zs\inner') -ExpectedManifest $evil.Manifest }) -like '*outside the target*') -and -not (Test-Path (Join-Path $work 'zs\escaped.txt')))
Test-Check 'recipe: msiexec arguments must be simple PROPERTY=value pairs' ((Test-PackTuneRepoRecipeArguments 'ALLUSERS=1 INSTALLDIR="C:\Tools\App"') -and -not (Test-PackTuneRepoRecipeArguments 'ALLUSERS=1 & calc') -and -not (Test-PackTuneRepoRecipeArguments 'X="a";b') -and -not (Test-PackTuneRepoRecipeArguments 'x=1') -and (Test-PackTuneRepoRecipeArguments ''))

# ---------------------------------------------------------------- pinning
New-FakeRepo -FullName 'contoso/pinned' -Id 21
Publish-TestVersion $script:Gh.Repos['contoso/pinned'] $v1 '1.0.0'
$null = Add-PackTuneRepository -Repository 'contoso/pinned' -Own
$pr = $script:Gh.Repos['contoso/pinned']
$pr.FullName = 'contoso/pinned-renamed'
$st = Get-PackTuneRepoState 'contoso/pinned'
Test-Check 'pin: a renamed repository needs a confirmation and is not read meanwhile' ($st.State -eq 'NeedsConfirmation' -and (Test-Throws { Get-PackTuneRepositoryApps -Repository 'contoso/pinned' } '*NeedsConfirmation*'))
$script:Gh.Repos['contoso/pinned-renamed'] = $pr
Confirm-PackTuneRepositoryIdentity 'contoso/pinned'
Test-Check 'pin: after the confirmation the new name is pinned (same id)' ((Get-PackTuneRepoState 'contoso/pinned-renamed').State -eq 'Ready' -and (Get-PackTuneRepository 'contoso/pinned-renamed').RepoId -eq 21)
$script:Gh.Repos.Remove('contoso/pinned')
New-FakeRepo -FullName 'contoso/pinned-renamed' -Id 99
Test-Check 'pin: another repository with the same name (other id) is refused, no confirmation possible' ((Get-PackTuneRepoState 'contoso/pinned-renamed').State -eq 'Mismatch' -and (Test-Throws { Confirm-PackTuneRepositoryIdentity 'contoso/pinned-renamed' } '*Nothing to confirm*') -and (Test-Throws { Get-PackTuneRepositoryApps -Repository 'contoso/pinned-renamed' } '*Mismatch*'))
$script:Gh.Repos['contoso/pinned-renamed'] = $pr
$pr.Fork = $true
Test-Check 'pin: a repository that became a fork needs a confirmation' ((Get-PackTuneRepoState 'contoso/pinned-renamed').State -eq 'NeedsConfirmation')
$pr.Fork = $false

# ---------------------------------------------------------------- signed commits (per repository)
New-FakeRepo -FullName 'contoso/signed' -Id 31
Publish-TestVersion $script:Gh.Repos['contoso/signed'] $v1 '1.0.0' $false
$null = Add-PackTuneRepository -Repository 'contoso/signed' -Own -RequireSignedCommits
$rs = Get-PackTuneRepoApprovalRequest -Repository 'contoso/signed' -AppId $appId -Version '1.0.0'
Test-Check 'signed: an unverified commit is blocked in the approval request and cannot be approved' ($rs.Blocked -like '*requires verified commits*' -and (Test-Throws { Approve-PackTuneRepoVersion -Request $rs } '*Cannot be approved*'))
Publish-TestVersion $script:Gh.Repos['contoso/signed'] $v1 '1.0.0' $true
Test-Check 'signed: a verified commit can be approved' (-not (Get-PackTuneRepoApprovalRequest -Repository 'contoso/signed' -AppId $appId -Version '1.0.0').Blocked)
Test-Check 'signed: without the switch an unverified commit is only shown as not verified' ((Publish-TestVersion $pub $v1 '1.0.0' $false) -eq $null -and -not (Get-PackTuneRepoApprovalRequest -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0').Commit.Verified)
Publish-TestVersion $pub $v1 '1.0.0' $true @()
Publish-TestVersion $pub $v2 '2.0.0' $true @([pscustomobject]@{ Version = '1.0.0'; Hash = $v1.Manifest })

# ---------------------------------------------------------------- private repository, token handling, rate limits
$secret = 'github_pat_SECRETSECRET0123456789'
New-FakeRepo -FullName 'contoso/private' -Id 41 -Private $true
Publish-TestVersion $script:Gh.Repos['contoso/private'] $v1 '1.0.0'
$script:Gh.Tokens[$secret] = @{ Repos = @('contoso/private'); Write = $false }
$m = Get-Message { Add-PackTuneRepository -Repository 'contoso/private' }
Test-Check 'private: without a token the cause says a token is needed' ($m -like '*private repository needs a token*')
$m = Get-Message { Add-PackTuneRepository -Repository 'contoso/private' -Token 'github_pat_WRONGTOKEN0123456789' }
Test-Check 'token: a rejected token gives a clear message that does not contain it' ($m -like '*rejected the token*' -and $m -notlike '*WRONGTOKEN*')
$pe = Add-PackTuneRepository -Repository 'contoso/private' -Token $secret -DisplayName 'Contoso private' -Own
Test-Check 'private: connected with the token, private flag, not third party' ($pe.Private -and -not $pe.ThirdParty -and (Get-PackTuneRepoToken 'contoso/private') -eq $secret)
Test-Check 'private: the token is sent as authorization on API calls' (@($script:Gh.Requests | Where-Object { $_.Token -eq $secret }).Count -gt 0)
$tokenFile = Get-Content (Join-Path $work 'PackTune\repo-tokens.json') -Raw
Test-Check 'token: stored DPAPI-protected (no plain text), per repository' ($tokenFile -notmatch 'SECRET' -and $tokenFile -match 'contoso/private' -and ((ConvertFrom-Json $tokenFile).'contoso/private'.read.Length -gt 100))
$leaks = @(Get-ChildItem $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.json' -or $_.Name -like '*.etag' -or $_.Name -like '*.log' } | Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'SECRETSECRET' })
Test-Check 'token: not in settings, repository list, approvals, caches or logs' ($leaks.Count -eq 0) ($leaks.FullName -join ',')
Test-Check 'token: error messages and the redaction helper never contain a token' ((Protect-PackTuneGitHubText "failed with $secret and ghp_abcdefghijklmnop1234") -notmatch 'SECRET|abcdefghijklmnop')
Test-Check 'private: another token (no access to it) sees nothing' (Test-Throws { Add-PackTuneRepository -Repository 'contoso/private2' -Token $secret } '*')
Remove-PackTuneRepoToken 'contoso/private'
Test-Check 'token: sign-out removes it' ($null -eq (Get-PackTuneRepoToken 'contoso/private'))
Set-PackTuneRepoToken -Repository 'contoso/private' -Token $secret
# rate limit
$script:Gh.RateRemaining = 0; $script:Waited = 0
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools' -Refresh
Test-Check 'rate limit: a used-up limit waits for Retry-After and goes on' ($script:Waited -ge 1)
$script:Gh.RateRemaining = 0
function Wait-PackTuneGitHub([int]$Seconds) { $script:Waited += $Seconds }
$m = (Get-PackTuneRepoState 'thirdparty/tools').Message
Test-Check 'rate limit: when it stays used up, a clear message with the hint to add a token' ($m -like '*rate limit is used up*' -and $m -like '*60 requests per hour*')
function Wait-PackTuneGitHub([int]$Seconds) { $script:Waited += $Seconds; $script:Gh.RateRemaining = 100 }
$script:Gh.RateRemaining = 1000
Test-Check 'rate limit: the remaining budget is kept for the interface' ($null -ne (Get-PackTuneGitHubBudget) -and (Get-PackTuneGitHubBudget).Remaining -le 1000)

# ---------------------------------------------------------------- deploy a repository MSI app
$null = Approve-PackTuneRepoVersion -Request (Get-PackTuneRepoApprovalRequest -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0')
$null = Approve-PackTuneRepoVersion -Request (Get-PackTuneRepoApprovalRequest -Repository 'thirdparty/tools' -AppId $appId -Version '2.0.0')
$null = Get-PackTuneRepoIndex -Repository 'thirdparty/tools' -Refresh
Test-Check 'deploy: an unapproved version is refused' (Test-Throws { New-PackTuneRepoApp -Repository 'contoso/private' -AppId $appId -Version '1.0.0' } '*is not approved*')
$id1 = New-PackTuneRepoApp -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' -Assignment Available
$a1 = Get-Store | Where-Object id -eq $id1
$p1 = ConvertFrom-PackTuneCustomNotes ([string]$a1.notes)
Test-Check 'deploy: a Win32 app whose notes carry repo, commit, approver and the full manifest anchor' ($a1.displayName -eq 'Contoso Tool' -and $a1.displayVersion -eq '1.0.0' -and $p1.Repo -eq 'thirdparty/tools' -and $p1.Commit -eq $rec.Commit.Substring(0, 12) -and $p1.ApprovedBy -and $p1.Manifest -eq $v1.Manifest -and $a1.notes.Length -lt $script:NotesMaxLength) $a1.notes
Test-Check 'deploy: the tenant list shows repo and commit' (@(Get-PackTuneCustomApps)[0].Repo -eq 'thirdparty/tools')
Test-Check 'deploy: the same version again is refused' (Test-Throws { New-PackTuneRepoApp -Repository 'thirdparty/tools' -AppId $appId -Version '1.0.0' } '*deployed already*')
Test-Check 'deploy: no work files are left in temp' (@(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'packtune-repo-*' -ErrorAction SilentlyContinue).Count -eq 0)
Remove-PackTuneCustomApp -Id $id1

# ---------------------------------------------------------------- Move to repository
$s = Get-PackTuneSettings; $s.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Save-PackTuneSettings -Settings $s | Out-Null
$null = Initialize-PackTuneStore
$null = Test-PackTuneCustomApp -MsiPath $msi1 -AutoRun
$mid1 = New-PackTuneCustomMsiApp -MsiPath $msi1 -Assignment None
$null = Test-PackTuneCustomApp -MsiPath $msi2 -PreviousMsiPath $msi1 -AutoRun
$mid2 = Publish-PackTuneCustomVersion -AppId $mid1 -MsiPath $msi2
Test-Check 'move: setup, two versions kept in the store with Intune anchors' (@($script:Fs.Keys | Where-Object { $_ -like "$appId/*/manifest.json" }).Count -eq 2)
$writeTok = 'github_pat_WRITEWRITE0123456789'; $roTok = 'github_pat_READONLY0123456789'
New-FakeRepo -FullName 'contoso/target' -Id 51 -Private $true
$script:Gh.Tokens[$writeTok] = @{ Repos = @('contoso/target'); Write = $true }
$script:Gh.Tokens[$roTok] = @{ Repos = @('contoso/target'); Write = $false }
$null = Add-PackTuneRepository -Repository 'contoso/target' -Token $roTok -DisplayName 'Contoso packages' -Own
Test-Check 'move: refused without the separate write grant' (Test-Throws { Move-PackTuneCustomAppToRepository -AppId $appId -Repository 'contoso/target' } '*write grant*')
Test-Check 'move: a read-only token is not accepted as the write grant' (Test-Throws { Grant-PackTuneRepoWrite -Repository 'contoso/target' -Token $roTok } '*no write access*')
Test-Check 'move: a third-party source is never a target' (Test-Throws { Grant-PackTuneRepoWrite -Repository 'thirdparty/tools' -Token $writeTok } '*third-party*')
Grant-PackTuneRepoWrite -Repository 'contoso/target' -Token $writeTok
Test-Check 'move: the write token is stored separately from the read token' ((Get-PackTuneRepoToken 'contoso/target') -eq $roTok -and (Get-PackTuneRepoToken 'contoso/target' -Write) -eq $writeTok)
$asked = $null
$mv = Move-PackTuneCustomAppToRepository -AppId $appId -Repository 'contoso/target' -ConfirmRemoval { param($Plan) $script:asked = $Plan; $false }
Test-Check 'move: both versions copied (one commit each), verified, SharePoint kept after "no"' (@($mv.Copied).Count -eq 2 -and @($mv.Verified).Count -eq 2 -and -not $mv.RemovedFromStore -and @($script:Fs.Keys | Where-Object { $_ -like "$appId/*" }).Count -gt 0 -and $asked.Versions.Count -eq 2 -and $asked.Where -like '*recycle bin*')
$ti = Get-PackTuneRepoIndex -Repository 'contoso/target' -Refresh
Test-Check 'move: the repository has the index with both versions and the store manifest hashes' (-not $ti.Damaged -and @($ti.Apps[0].versions).Count -eq 2 -and (@($ti.Apps[0].versions | Where-Object { $_.version -eq '1.0.0' }).manifest -eq (@(Get-Store | Where-Object id -eq $mid1)[0].notes -replace '.*manifest=([0-9a-f]{64}).*', '$1')))
Test-Check 'move: the commits were written with the write token, the store manifest is byte-identical' (@($script:Gh.Requests | Where-Object { $_.Method -eq 'PATCH' -and $_.Token -eq $writeTok }).Count -eq 2 -and (Get-Sha $script:Gh.Blobs[(Get-FakeRepoFiles $script:Gh.Repos['contoso/target'])["apps/$appId/1.0.0/manifest.json"]]) -eq (Get-Sha $script:Fs["$appId/1.0.0/manifest.json"]))
$sw = @(Get-Store | ForEach-Object { ConvertFrom-PackTuneCustomNotes ([string]$_.notes) })
Test-Check 'move: the Intune notes keep the anchor and now carry repo and commit' (@($sw | Where-Object { $_.Repo -eq 'contoso/target' -and $_.Commit -and $_.Manifest.Length -eq 64 }).Count -eq 2)
$before = @($script:Gh.Requests | Where-Object { $_.Method -eq 'PATCH' }).Count
$mv2 = Move-PackTuneCustomAppToRepository -AppId $appId -Repository 'contoso/target'
Test-Check 'move: running it again is idempotent (nothing copied, all skipped, no new commit)' (@($mv2.Copied).Count -eq 0 -and @($mv2.Skipped).Count -eq 2 -and @($script:Gh.Requests | Where-Object { $_.Method -eq 'PATCH' }).Count -eq $before)
# a mismatch in the repository stops before any removal
$tgt = $script:Gh.Repos['contoso/target']; $tk = "apps/$appId/2.0.0/installer.zip"; $tt = $script:Gh.Trees[$script:Gh.Commits[$tgt.Head].Tree]; $keep = $tt[$tk]
$flip = $script:Gh.Blobs[$keep].Clone(); $flip[3] = [byte](($flip[3] + 1) % 256); $fb = New-GhSha; $script:Gh.Blobs[$fb] = $flip; $tt[$tk] = $fb
$called = $false
$m = Get-Message { Move-PackTuneCustomAppToRepository -AppId $appId -Repository 'contoso/target' -ConfirmRemoval { $script:called = $true; $true } }
Test-Check 'move: a hash mismatch on read-back stops it, nothing is removed, the confirmation is never asked' ($m -like '*does not match the manifest*' -and -not $called -and @($script:Fs.Keys | Where-Object { $_ -like "$appId/*" }).Count -gt 0)
$tt[$tk] = $keep
# export reads from the repository once the notes say so; the store is not needed
$exp = Export-PackTuneCustomApp -AppId $appId -Version '1.0.0' -Destination (Join-Path $work 'export-repo')
Test-Check 'export: an app with repo= in its notes is exported from the repository, verified against the Intune anchor' ($exp.Repository -eq 'contoso/target' -and (Test-Path (Join-Path $work 'export-repo\installer\contoso-tool-1.0.msi'))) "repo=$($exp.Repository) files=$((Get-ChildItem (Join-Path $work 'export-repo') -Recurse -Name) -join ',')"
# confirmed removal
$mv3 = Move-PackTuneCustomAppToRepository -AppId $appId -Repository 'contoso/target' -ConfirmRemoval { param($Plan) $true }
Test-Check 'move: after a confirmation the store folder is removed (and only then)' ($mv3.RemovedFromStore -and @($script:Fs.Keys | Where-Object { $_ -like "$appId/*" }).Count -eq 0)
$exp2 = Export-PackTuneCustomApp -AppId $appId -Version '2.0.0' -Destination (Join-Path $work 'export-repo2')
Test-Check 'export: still works after SharePoint was cleaned, from the repository' ($exp2.Version -eq '2.0.0' -and (Test-Path (Join-Path $work 'export-repo2\package.intunewin')))
# large files as release assets
$script:RepoAssetThreshold = 100
New-FakeRepo -FullName 'contoso/target-big' -Id 52 -Private $true
$script:Gh.Tokens[$writeTok].Repos = @('contoso/target', 'contoso/target-big'); $script:Gh.Tokens[$roTok].Repos = @('contoso/target', 'contoso/target-big')
$null = Add-PackTuneRepository -Repository 'contoso/target-big' -Token $roTok -Own
Grant-PackTuneRepoWrite -Repository 'contoso/target-big' -Token $writeTok
# put the versions back into the store from the first repository, as a fresh store
$state = Get-PackTuneStoreState
foreach ($ver in '1.0.0', '2.0.0') {
    $tmp = Join-Path $work "restore-$ver"
    $notes = ConvertFrom-PackTuneCustomNotes ([string]((Get-Store | Where-Object { (ConvertFrom-PackTuneCustomNotes ([string]$_.notes)).Version -eq $ver })[0].notes))
    $null = Save-PackTuneRepoVersion -Repository 'contoso/target' -AppId $appId -Version $ver -Destination $tmp -ExpectedManifest $notes.Manifest
    foreach ($f in Get-ChildItem $tmp -File) { $script:Fs["$appId/$ver/$($f.Name)"] = [IO.File]::ReadAllBytes($f.FullName) }
}
$mvb = Move-PackTuneCustomAppToRepository -AppId $appId -Repository 'contoso/target-big'
$big = $script:Gh.Repos['contoso/target-big']
$bt = Get-FakeRepoFiles $big
$bi = Get-PackTuneRepoIndex -Repository 'contoso/target-big' -Refresh
Test-Check 'large files: over the threshold they are release assets <app id>/<version> with the same name, listed in the index' (@($mvb.Copied).Count -eq 2 -and $big.Releases.ContainsKey("$appId/1.0.0") -and $big.Releases["$appId/1.0.0"].Assets.ContainsKey('installer.zip') -and -not $bt.ContainsKey("apps/$appId/1.0.0/installer.zip") -and $bt.ContainsKey("apps/$appId/1.0.0/manifest.json") -and (@($bi.Apps[0].versions[0].assets) -contains 'installer.zip') -and @($mvb.Verified).Count -eq 2) "copied=$(@($mvb.Copied).Count) rel=$(($big.Releases.Keys) -join ',') files=$(($bt.Keys) -join ',') assets=$($bi.Apps[0].versions | ConvertTo-Json -Compress)"
$dst = Join-Path $work 'big-save'
$null = Save-PackTuneRepoVersion -Repository 'contoso/target-big' -AppId $appId -Version '1.0.0' -Destination $dst -ExpectedManifest ($bi.Apps[0].versions | Where-Object { $_.version -eq '1.0.0' }).manifest
Test-Check 'large files: downloaded from the asset and verified like any other file' (Test-Path (Join-Path $dst 'installer\contoso-tool-1.0.msi'))
$script:RepoAssetThreshold = 90MB

# ---------------------------------------------------------------- remove, template, clone check
Remove-PackTuneRepository 'contoso/target-big'
Test-Check 'remove: the connection, the tokens and the cache are gone, the approvals stay' (-not @(Get-PackTuneRepositories | Where-Object Repo -eq 'target-big').Count -and $null -eq (Get-PackTuneRepoToken 'contoso/target-big') -and @(Get-PackTuneRepoApprovals).Count -ge 2)
$tpl = Join-Path $work 'template-out'
$null = New-PackTuneRepositoryTemplate -Destination $tpl -Name 'Contoso packages' 6>$null
Test-Check 'template: index, apps folder, README, gitattributes, validation workflow, code owners and the checker are copied' ((Test-Path "$tpl\packtune.json") -and (Test-Path "$tpl\apps") -and (Test-Path "$tpl\README.md") -and (Test-Path "$tpl\.gitattributes") -and (Test-Path "$tpl\.github\workflows\validate.yml") -and (Test-Path "$tpl\.github\CODEOWNERS") -and (Test-Path "$tpl\tools\Check-PackTuneRepository.ps1") -and ((Get-Content "$tpl\packtune.json" -Raw | ConvertFrom-Json).name -eq 'Contoso packages'))
Test-Check 'template: the workflow only reads (contents: read) and runs the checker' ((Get-Content "$tpl\.github\workflows\validate.yml" -Raw) -match 'contents: read' -and (Get-Content "$tpl\.github\workflows\validate.yml" -Raw) -match 'Check-PackTuneRepository')
Test-Check 'template: an empty repository is valid' (@(Test-PackTuneRepositoryClone $tpl).Count -eq 0)
foreach ($k in $v1.Files.Keys) { $p = Join-Path $tpl $k; New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null; [IO.File]::WriteAllBytes($p, $v1.Files[$k]) }
[IO.File]::WriteAllBytes((Join-Path $tpl 'packtune.json'), (New-TestIndex @([pscustomobject]@{ Version = '1.0.0'; Hash = $v1.Manifest })))
$outModule = @(Test-PackTuneRepositoryClone $tpl)
$outScript = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$tpl\tools\Check-PackTuneRepository.ps1" -Path $tpl; $codeOk = $LASTEXITCODE
Test-Check 'clone check: a correct clone passes in the module and in the template script' ($outModule.Count -eq 0 -and $codeOk -eq 0) ($outModule -join ';')
$f = Join-Path $tpl "apps\$appId\1.0.0\recipe.json"; [IO.File]::WriteAllText($f, 'changed')
$outModule = @(Test-PackTuneRepositoryClone $tpl)
$outScript = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$tpl\tools\Check-PackTuneRepository.ps1" -Path $tpl; $codeBad = $LASTEXITCODE
Test-Check 'clone check: a changed file is found in the module and the template script fails the build' ($outModule.Count -ge 1 -and $outModule[0] -like '*recipe.json*' -and $codeBad -eq 1) ($outScript -join ';')

# ---------------------------------------------------------------- code rules
$src = Get-Content (Join-Path $repo 'PackTune-Repos.ps1') -Raw
Test-Check 'rules: nothing from a repository is executed (no Invoke-Expression, no dot-sourcing or starting of downloaded files)' ($src -notmatch 'Invoke-Expression|\biex\b|Start-Process|\. \(Join-Path \$Temp|\. \$Saved')
Test-Check 'rules: the token is only used as a bearer header inside the transport, never written to the host' ($src -notmatch 'Write-Host[^\r\n]*\$Token' -and $src -notmatch 'Write-Verbose[^\r\n]*\$Token' -and $src -notmatch 'Write-Warning[^\r\n]*\$Token')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed -gt 0) { "$script:Failed check(s) failed."; exit 1 }
'All checks passed.'
