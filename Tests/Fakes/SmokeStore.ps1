# The package store of the GUI smoke test: a fake SharePoint in memory with the library (every task runspace loads it, PACKTUNE_FAKE_STORE)
. (Join-Path $PSScriptRoot 'FakeSharePoint.ps1')
$script:Drives = @(@{ id = 'drive-1'; name = 'PackTune Packages' })
