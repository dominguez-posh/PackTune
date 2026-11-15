# Plays the part of Windows Sandbox for the GUI smoke test (PACKTUNE_SANDBOX_LAUNCHER): keeps the job input (the lab scripts)
# in %LOCALAPPDATA%\fake-sandbox\<number>-<mode> and reports a passed test. No sandbox opens.
param([Parameter(Mandatory = $true)][string]$WsbPath)
$job = Split-Path $WsbPath -Parent
$lab = Join-Path $env:LOCALAPPDATA 'fake-sandbox'
$n = @(Get-ChildItem $lab -Directory -ErrorAction SilentlyContinue).Count + 1
$info = Get-Content (Join-Path $job 'job.json') -Raw | ConvertFrom-Json
$dest = Join-Path $lab ('{0:D2}-{1}' -f $n, $info.Mode)
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item (Join-Path $job 'job.json') $dest
if (Test-Path (Join-Path $job 'input\source')) { Copy-Item (Join-Path $job 'input\source') (Join-Path $dest 'source') -Recurse }
if (Test-Path (Join-Path $job 'input\source-runtime')) { Copy-Item (Join-Path $job 'input\source-runtime') (Join-Path $dest 'source-runtime') -Recurse }
Set-Content -Path (Join-Path $dest 'started.txt') -Value (Get-Date).ToString('o')
# A check can make the next tests fail: %LOCALAPPDATA%\fake-sandbox-verdict.txt holds Failed
$fail = (Test-Path (Join-Path $env:LOCALAPPDATA 'fake-sandbox-verdict.txt')) -and ((Get-Content (Join-Path $env:LOCALAPPDATA 'fake-sandbox-verdict.txt') -Raw).Trim() -eq 'Failed')
if ($fail) { @{ State = 'Failed'; Step = 'Done'; Message = 'Failed at step 2 of 5: Install exited with 1603'; Result = @{ Verdict = 'Failed'; Notes = 'fake' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $job 'status.json') }
else { @{ State = 'Succeeded'; Step = 'Done'; Message = 'Fake test lab'; Result = @{ Verdict = 'Passed'; Notes = 'fake' } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $job 'status.json') }
