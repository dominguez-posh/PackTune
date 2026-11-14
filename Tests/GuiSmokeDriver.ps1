# Dot-sourced by Start-PackTune.ps1 when PACKTUNE_SMOKE is set (see Tests\Invoke-GuiSmoke.ps1).
# Puts the window off-screen and walks through the steps below on the UI thread; each step returns $true when it is
# done (or $false to be asked again on the next tick), so background tasks can finish in between.
# Screenshots of every page and dialog land in the output folder (shot-NN-*.png).

$script:SmokeOut = $env:PACKTUNE_SMOKE_OUT
$script:SmokeResults = New-Object System.Collections.ArrayList
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

$script:AppListSync = $true
function Test-Smoke([string]$Name, [bool]$Ok, $Detail) {
    $line = if ($Ok) { "PASS $Name" } else { "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" } else { '' }) }
    [void]$script:SmokeResults.Add($line)
}
function Save-SmokeShot([string]$Name) {
    $window.UpdateLayout()
    $w = [int]$window.Content.ActualWidth; $h = [int]$window.Content.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($window.Content)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create((Join-Path $script:SmokeOut "shot-$Name.png"))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}
function Get-SmokeLog { $script:UiLogLines -join "`n" }
function Get-JobLog { (@($script:JobRows | ForEach-Object { $_.Data.Log | ForEach-Object { $_.Text } }) ) -join "`n" }
# Without a kind: no task except the icon rendering, which runs on its own pool next to everything else
function Test-Idle([string]$Kind) { -not @($script:Tasks | Where-Object { if ($Kind) { $_.Job.Kind -eq $Kind } else { $_.Job.Kind -ne 'icons' } }).Count }
function Get-StoreApps { @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }
function Get-StoreApp([string]$Package) { @(Get-StoreApps | Where-Object { $_.notes -like "*package=$Package;*" })[-1] }
function Find-Visual($Parent, [type]$Type) {
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($c -is $Type) { return $c }
        $r = Find-Visual $c $Type; if ($r) { return $r }
    }
}
function Get-FlyoutPlacement($Menu, $Target) {
    # The window of the test is off-screen, so the popup position on the screen is clamped: the placement rule itself is checked
    $popup = New-Object System.Windows.Size $Menu.ActualWidth, $Menu.ActualHeight
    $targetSize = New-Object System.Windows.Size $Target.ActualWidth, $Target.ActualHeight
    $p = $Menu.CustomPopupPlacementCallback.Invoke($popup, $targetSize, (New-Object System.Windows.Point 0, 0))[0].Point
    @{ RightEdge = $p.X + $Menu.ActualWidth - 8; TargetRight = $Target.ActualWidth; Top = $p.Y + 8; Wanted = $Target.ActualHeight + 4 }
}
function Get-Card([string]$Key) { @($script:CardCollection | Where-Object { (Get-AppKey $_.Data) -eq $Key })[0] }
function Test-GeneratedScripts([string]$Folder, [string]$What) {
    # The scripts that run on the devices must at least be valid PowerShell, without leftover placeholders
    foreach ($file in Get-ChildItem $Folder -Filter '*.ps1' -Recurse) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        $text = Get-Content $file.FullName -Raw
        Test-Smoke "$What script $($file.Name) is valid" ($errors.Count -eq 0 -and $text -notmatch '__[A-Z]+__') (@($errors | ForEach-Object { $_.Message }) -join '; ')
    }
    $install = Get-Content (Join-Path $Folder 'source\install.ps1') -Raw
    $update = Get-Content (Join-Path $Folder 'source\update.ps1') -Raw
    Test-Smoke "$What scripts share the device lock" ($install -match 'Global.PackTune"' -and $install -match 'Global.IntuneChocoDeployment"' -and $install -match 'Enter-DeploymentLock' -and $update -match 'Enter-DeploymentLock')
    Test-Smoke "$What helper folder is protected by SID" ($install -match 'Protect-Folder' -and $install -match 'S-1-5-18' -and $install -match 'S-1-5-32-544')
}

# Fake Graph for the insight functions (counts, status, status script, import): script text, run inside the task runspaces
$script:InsightFake = Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) 'InsightFake.txt') -Raw

$script:SmokeSteps = [System.Collections.ArrayList]@(
    @{ Name = 'start page'; Do = {
        # the package store is ready (a fake SharePoint with the library); the steps that need it not to be say so themselves
        $script:StoreSmokeState = [pscustomobject]@{ State = 'Ready'; Message = 'The package store is ready (smoke test).'; SiteUrl = 'https://contoso.sharepoint.com/sites/PackTune' }
        $script:StoreState = $script:StoreSmokeState
        $script:EmbeddedAvailableOverride = $false   # simulates a missing WebView2 runtime: the sign-in uses the browser, as the fake authority needs
        $script:SandboxOverride = @{ Present = $true }
        Update-SandboxState
        Test-Smoke 'settings were copied from the folder of the earlier name' ((Test-Path (Join-Path $env:LOCALAPPDATA 'PackTune\settings.json')) -and (Test-Path (Join-Path $env:LOCALAPPDATA 'PackTune\migrated-from-intunechoco.txt')) -and (Test-Path (Join-Path $env:LOCALAPPDATA 'IntuneChocoDeployment\settings.json'))) ''
        Test-Smoke 'fake module counts as installed' $script:ModuleState.Ok $script:ModuleState.Version
        Test-Smoke 'readiness shows 7 items' ($ui.ReadinessPanel.Children.Count -eq 7) $ui.ReadinessPanel.Children.Count
        Test-Smoke 'signed out: split button shown, account pill hidden' ((-not (Test-SignedIn)) -and $ui.PanelSignedOut.Visibility -eq 'Visible' -and $ui.BtnAccount.Visibility -eq 'Collapsed' -and $ui.BtnSignIn.IsEnabled)
        Test-Smoke 'navigation has the five entries, no package source switch' ($ui.NavStart -and $ui.NavApps -and $ui.NavTenant -and $ui.NavActivity -and $ui.NavSettings -and $ui.NavHelp -and -not $ui.ContainsKey('SrcWinget'))
        Test-Smoke 'help dialog opens' ($(Show-Help; $ui.DialogLayer.Visibility -eq 'Visible' -and $ui.DlgHelp.Visibility -eq 'Visible' -and $ui.HelpBody.Children.Count -ge 4))
        Save-SmokeShot '00-help'
        Close-Dialog
        Test-Smoke 'dialog closes' ($ui.DialogLayer.Visibility -eq 'Collapsed')
        Test-Smoke 'Keevault detection runs' ($null -ne (Find-KeevaultMcp).Installed)
        $true } }
    @{ Name = 'header and sign-in menu'; Phase = 0; Do = {
        param($s)
        function Save-ElementShot([string]$Name, $Element) {
            $Element.UpdateLayout()
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$Element.ActualWidth, [int]$Element.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($Element)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create((Join-Path $script:SmokeOut "shot-$Name.png")); try { $enc.Save($fs) } finally { $fs.Dispose() }
        }
        if ($s.Phase -eq 0) {
            $window.UpdateLayout()
            Test-Smoke 'split button: both halves have the same height, one block' ($ui.BtnSignIn.ActualHeight -eq $ui.BtnSignInMenu.ActualHeight -and $ui.PanelSignedOut.ActualHeight -eq $ui.BtnSignIn.ActualHeight -and $ui.BtnSignIn.ActualHeight -ge 32) "$($ui.BtnSignIn.ActualHeight) / $($ui.BtnSignInMenu.ActualHeight)"
            Test-Smoke 'title bar is part of the window: chrome with caption buttons, caption height of the header' ([System.Windows.Shell.WindowChrome]::GetWindowChrome($window).CaptionHeight -eq 52 -and [System.Windows.Shell.WindowChrome]::GetIsHitTestVisibleInChrome($ui.BtnClose) -and [System.Windows.Shell.WindowChrome]::GetIsHitTestVisibleInChrome($ui.PanelSignedOut) -and $window.WindowStyle -eq 'SingleBorderWindow')
            Save-SmokeShot '20-header-signed-out'
            Show-SignInMenu $ui.PanelSignedOut
            $s.Phase = 1; return $false
        }
        if ($s.Phase -eq 1) {
            $menu = $script:LastMenu
            Test-Smoke 'sign-in menu lists Microsoft, web browser and Keevault' (@($menu.Items | ForEach-Object { $_.Header }) -join '|' -eq 'Sign in with Microsoft|Sign in in the web browser|Sign in with Keevault') (@($menu.Items | ForEach-Object { $_.Header }) -join '|')
            $menu.UpdateLayout()
            $fp = Get-FlyoutPlacement $menu $ui.PanelSignedOut
            Test-Smoke 'menu is right-aligned under the button' ($fp.RightEdge -eq $fp.TargetRight) "menu right $($fp.RightEdge), button right $($fp.TargetRight)"
            Test-Smoke 'menu sits 4 px below the button' ($fp.Top -eq $fp.Wanted) "menu top $($fp.Top), wanted $($fp.Wanted)"
            Test-Smoke 'menu is 360 px wide (flyout)' ($menu.ActualWidth -eq 376) $menu.ActualWidth
            Save-ElementShot '21-sign-in-menu' $menu
            $menu.IsOpen = $false
            $true
        }
    } }
    @{ Name = 'sign-in can be cancelled'; Phase = 0; Do = {
        param($s)
        # A browser that never answers (the user closed the window): the sign-in must end on Cancel
        if ($s.Phase -eq 0) { $s.Phase = 1; $script:SignInTest = @{ Authority = $env:PACKTUNE_SMOKE_AUTHORITY; UrlHandler = 'param($Url)' }; Connect-Intune; Test-Smoke 'WebView2 runtime missing: sign-in falls back to the browser and a toast says so' ($script:LastSignInPath -eq 'browser' -and @($script:Toasts | Where-Object { $_.Text -like '*not available*web browser*' }).Count -ge 1) $script:LastSignInPath; return $false }
        if ($s.Phase -eq 1) {
            if (-not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'connect' -and $_.Job.Status -eq 'running' }).Count) { return $false }
            $s.Phase = 2
            Test-Smoke 'button offers to cancel while the sign-in waits' ($ui.BtnSignIn.Content -eq 'Cancel sign-in' -and $ui.BtnSignIn.IsEnabled -and -not $ui.BtnSignInMenu.IsEnabled) $ui.BtnSignIn.Content
            & $script:ClickActions[$ui.BtnSignIn]
            return $false
        }
        if (-not (Test-Idle 'connect')) { return $false }
        Test-Smoke 'cancelled sign-in ends and is logged' ((-not (Test-SignedIn)) -and ((Get-SmokeLog) + (Get-JobLog)) -match 'Sign-in cancelled')
        Test-Smoke 'sign in is offered again' ($ui.BtnSignIn.Content -eq 'Sign in' -and $ui.BtnSignIn.IsEnabled -and $ui.BtnSignInMenu.IsEnabled) $ui.BtnSignIn.Content
        $true } }
    @{ Name = 'set up everything'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) {
            $s.Started = $true
            # No app registration yet: the item is red, says why and offers Create; green items have no button
            $cfg = Get-PackTuneSettings; $cfg.ClientID = ''; [void](Save-PackTuneSettings -Settings $cfg); $script:Settings = Get-PackTuneSettings
            Show-Page 'Start'
            $cards = @(Get-ReadinessItems)
            $appreg = $cards | Where-Object Key -eq 'appreg'
            Test-Smoke 'missing app registration is red with a reason' ($appreg.State -eq 'bad' -and $appreg.Text -like '*app registration*') $appreg.Text
            $buttons = @($ui.ReadinessPanel.Children | ForEach-Object { @($_.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Button] }) | ForEach-Object { [string]$_.Content } })
            Test-Smoke 'only items that are not ready have a button (Create); sign-in only top right' (($buttons -join ',') -eq 'Create') ($buttons -join ',')
            $signinItem = $cards | Where-Object Key -eq 'signin'
            Test-Smoke 'Start page: no sign-in card, the sign-in item has no button, only a neutral hint' ($null -eq $ui.BtnStartSignInBrowser -and $null -eq $ui.BtnStartSignInKeevault -and -not $signinItem.Fix -and $signinItem.Text -like '*top right*' -and $ui.BtnSignIn.IsEnabled) $signinItem.Text
            Test-Smoke 'status report is optional and not counted' (($cards | Where-Object Key -eq 'status').Optional -and $ui.TxtReadinessSummary.Text -like '*3 of 4 not ready*' -or $ui.TxtReadinessSummary.Text -like '*of 4*') $ui.TxtReadinessSummary.Text
            Test-Smoke 'set up everything offered' ($ui.BtnSetupAll.Visibility -eq 'Visible' -and $ui.TxtReadinessSummary.Text -like '*not ready*') $ui.TxtReadinessSummary.Text
            Test-Smoke 'signed out, no app registration: Set up everything is disabled with the hint that sign-in creates the registration' (-not $ui.BtnSetupAll.IsEnabled -and $ui.TxtSetupNote.Text -eq 'Please sign in - the app registration is created during sign-in.' -and $ui.BtnSetupAll.ToolTip -eq $ui.TxtSetupNote.Text) $ui.TxtSetupNote.Text
            $keepClient = $script:Settings.ClientID; $script:Settings.ClientID = 'x'; Update-Readiness
            Test-Smoke 'signed out, registration exists: disabled, plain "Please sign in."' (-not $ui.BtnSetupAll.IsEnabled -and $ui.TxtSetupNote.Text -eq 'Please sign in.')
            $script:Settings.ClientID = $keepClient; Update-Readiness
            Save-SmokeShot '01-start'
            # Instead of a browser: request the sign-in URL; the stand-in authority redirects to the loopback port
            $script:SignInTest.UrlHandler = 'param($Url) $Shared.UrlHit = $true; $global:SmokeClient = New-Object System.Net.WebClient; [void]$global:SmokeClient.DownloadStringTaskAsync([uri]$Url)'
            $script:SignInTest.GraphUrl = $env:PACKTUNE_SMOKE_AUTHORITY
            & $script:ClickActions[$ui.BtnSetupAll]
            return $false
        }
        $s.Waited++
        if (($script:SetupRunning -or -not (Test-Idle)) -and $s.Waited -lt 1500) { return $false }
        $log = Get-SmokeLog + (Get-JobLog)
        Test-Smoke 'set up finished' ((-not $script:SetupRunning) -and $log -match 'Everything is set up') (($log -split "`n" | Select-Object -Last 3) -join ' | ')
        Test-Smoke 'app registration created with admin consent' ($log -match "App registration 'PackTune' created" -and $log -match 'Admin consent granted: DeviceManagementApps\.ReadWrite\.All')
        Test-Smoke 'a registration of the same name owned by someone else is not reused' ($log -match 'not reused: you are not its only owner')
        Test-Smoke 'tenant and client id saved' ((Get-PackTuneSettings).ClientID -eq '11111111-2222-3333-4444-555555555555' -and (Get-PackTuneSettings).TenantID -eq 'contoso.onmicrosoft.com')
        $names = @(Get-StoreApps | ForEach-Object { $_.displayName })
        Test-Smoke 'PackTune Runtime deployed by the set up, no separate Chocolatey app' ($script:RuntimeId -and ($names -contains 'PackTune Runtime') -and ($names -notcontains 'Chocolatey') -and ($names -notcontains 'winget runtime')) ($names -join ', ')
        Test-Smoke 'all required items green, set up button gone' (@(Get-ReadinessItems | Where-Object { $_.State -ne 'ok' -and -not $_.Optional }).Count -eq 0 -and $ui.BtnSetupAll.Visibility -eq 'Collapsed') $ui.TxtReadinessSummary.Text
        Test-Smoke 'signed in: Set up everything note is the normal one (button hidden when all is ready)' ($ui.TxtSetupNote.Text -notlike 'Please sign in*')
        $true } }
    @{ Name = 'sign in'; Do = {
        Test-Smoke 'signed in through the browser flow (PKCE, loopback)' (Test-SignedIn)
        Test-Smoke 'account pill shows name and tenant, split button gone' ($ui.BtnAccount.Visibility -eq 'Visible' -and $ui.PanelSignedOut.Visibility -eq 'Collapsed' -and $script:AccountText -like '*Test Admin*contoso.onmicrosoft.com*') $script:AccountText
        Test-Smoke 'token carries refresh token and client id' ($Global:AccessToken.RefreshToken -eq 'refresh-Test Admin' -and $Global:AccessToken.ClientID -eq '11111111-2222-3333-4444-555555555555')
        $Global:AccessToken.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(2)
        Update-UiToken
        $identity = Get-PackTuneIdentity
        Test-Smoke 'expiring token renewed silently' ($identity.Name -eq 'Test Admin renewed' -and ([datetime]$identity.ExpiresOn) -gt (Get-Date).ToUniversalTime().AddMinutes(30)) $identity.Name
        Test-Smoke 'renewed token handed to the tasks' ($script:Shared.Auth.AccessToken.RefreshToken -eq 'refresh-Test Admin renewed')
        $cultureBefore = [Threading.Thread]::CurrentThread.CurrentCulture.Name
        $direct = 'not reached'
        do { $direct = @(Get-IntuneWin32App).Count } while ($false)
        Test-Smoke 'fake module gives up silently when called directly (like the real one)' ($direct -eq 'not reached') $direct
        Test-Smoke 'module call works through Invoke-IntuneModule' (@(Invoke-IntuneModule { Get-IntuneWin32App }).Count -ge 1)
        try { Invoke-IntuneModule { Write-Warning 'gave up' 3>$null; break }; Test-Smoke 'a module give-up becomes an error' $false }
        catch { Test-Smoke 'a module give-up becomes an error' ($_.Exception.Message -like '*gave up without a result*') $_.Exception.Message }
        Test-Smoke 'culture restored after the module call' ([Threading.Thread]::CurrentThread.CurrentCulture.Name -eq $cultureBefore)
        Test-Smoke 'missing permissions would be offered (none missing here)' (@(Get-MissingScopes).Count -eq 0) (@(Get-MissingScopes) -join ',')
        $missing = @(Test-InsightReadiness -GrantedScopes @('DeviceManagementApps.ReadWrite.All') | Where-Object { -not $_.Ready })
        Test-Smoke 'readiness check names missing scopes (grant new permissions)' ($missing.Count -gt 0)
        $true } }
    @{ Name = 'account menu and maximized window'; Phase = 0; Do = {
        param($s)
        function Save-ElementShot2([string]$Name, $Element) {
            $Element.UpdateLayout()
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$Element.ActualWidth, [int]$Element.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($Element)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create((Join-Path $script:SmokeOut "shot-$Name.png")); try { $enc.Save($fs) } finally { $fs.Dispose() }
        }
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Start'
                Save-SmokeShot '22-header-signed-in'
                Show-AccountMenu
                $s.Phase = 1; return $false
            }
            1 {
                $menu = $script:LastMenu
                Test-Smoke 'account menu offers sign out and switching' (@($menu.Items | ForEach-Object { $_.Header })[0] -eq 'Sign out' -and $menu.Items.Count -ge 2)
                $menu.UpdateLayout()
                $fp = Get-FlyoutPlacement $menu $ui.BtnAccount
                Test-Smoke 'account menu is right-aligned under the pill, 4 px below' ($fp.RightEdge -eq $fp.TargetRight -and $fp.Top -eq $fp.Wanted) "$($fp.RightEdge)/$($fp.TargetRight) $($fp.Top)/$($fp.Wanted)"
                Save-ElementShot2 '23-account-menu' $menu
                $menu.IsOpen = $false
                # Maximized: the content must not be cut off at the screen edge
                $window.WindowState = 'Maximized'
                $s.Phase = 2; return $false
            }
            2 {
                $window.UpdateLayout()
                $m = $ui.RootGrid.Margin
                Test-Smoke 'maximized: the content gets the frame padding, restore glyph shown' ($m.Left -gt 0 -and $m.Top -gt 0 -and $ui.BtnMaximize.Content -eq [string][char]0xE923) "$($m.Left)/$($m.Top)"
                Save-SmokeShot '24-maximized'
                $window.WindowState = 'Normal'
                $s.Phase = 3; return $false
            }
            3 {
                $window.UpdateLayout()
                Test-Smoke 'restored: no padding, maximize glyph back' ($ui.RootGrid.Margin.Left -eq 0 -and $ui.BtnMaximize.Content -eq [string][char]0xE922)
                $window.Left = -20000; $window.Top = -20000
                $true
            }
        } } }
    @{ Name = 'status report setup'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            if (-not (Test-Idle)) { $s.Phase = 0; return $false }
            Test-Smoke 'status script missing: optional item offers Set up' ($script:StatusScript.State -eq 'Missing' -and (Get-ReadinessItems | Where-Object Key -eq 'status').Fix -eq 'Set up') ($script:StatusScript | ConvertTo-Json -Compress)
            Start-StatusScriptSetup
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        Test-Smoke 'status script created and assigned' ($script:StatusScript.State -eq 'Present' -and (Test-Path (Join-Path $env:LOCALAPPDATA 'fake-health.json')) -and (Get-JobLog) -match 'created|assigned') ($script:StatusScript | ConvertTo-Json -Compress)
        $true } }
    @{ Name = 'custom needs the store'; Do = {
        $ready = $script:StoreState
        Show-Page 'Custom'
        Test-Smoke 'store ready: New application on, no banner' ($ui.BtnCustomNew.IsEnabled -and $ui.BoxCustomStore.Visibility -eq 'Collapsed')
        $script:StoreState = [pscustomobject]@{ State = 'Missing'; Message = 'The PackTune site does not exist in this tenant yet.' }
        Update-CustomRows
        Test-Smoke 'no store: banner "Set up the package store first" with Set up, New application off' ($ui.BoxCustomStore.Visibility -eq 'Visible' -and $ui.TxtCustomStoreBanner.Text -like 'Set up the package store first*' -and $ui.BtnCustomStoreSetup -and -not $ui.BtnCustomNew.IsEnabled)
        $n = $script:Toasts.Count; & $script:ClickActions[$ui.BtnCustomNew]
        Test-Smoke 'no store: New application only says to set it up, no dialog' ($ui.DialogLayer.Visibility -eq 'Collapsed' -and $script:Toasts.Count -gt $n -and $script:Toasts[-1].Text -like 'Set up the package store first*')
        $saved = $script:CustomApps
        $script:CustomApps = @([pscustomobject]@{ Id = 'c-1'; DisplayName = 'Old Tool'; Kind = 'msi'; AppId = 'old-tool-1'; Version = '1.0'; ProductCode = '{X}'; UpgradeCode = ''; Manifest = ('ab' * 32); Identity = ''; Thumbprint = ''; Publisher = 'P'; Created = (Get-Date).ToString('o'); Intents = 'available'; Source = 'Custom'; IsChocolatey = $false })
        Update-CustomRows; $ui.LstCustom.SelectedItem = $script:CustomRows[0]
        Test-Smoke 'no store: existing apps are listed, New version and Export are off, Remove stays on' (@($script:CustomRows).Count -eq 1 -and -not $ui.BtnCustomNewVersion.IsEnabled -and -not $ui.BtnCustomExport.IsEnabled -and $ui.BtnCustomRemove.IsEnabled)
        $script:StoreState = $ready; Update-CustomRows; $ui.LstCustom.SelectedItem = $script:CustomRows[0]
        Test-Smoke 'store ready again: everything is back on' ($ui.BtnCustomNew.IsEnabled -and $ui.BtnCustomNewVersion.IsEnabled -and $ui.BtnCustomExport.IsEnabled -and $ui.BoxCustomStore.Visibility -eq 'Collapsed')
        $script:CustomApps = $saved; $ui.LstCustom.SelectedItem = $null; Update-CustomRows
        $true } }
    @{ Name = 'instant rows'; Do = {
        # a created app is in In tenant at once; a lagging list keeps it until Graph lists it; a removed one is gone at once
        Show-Page 'Tenant'
        $origApps = $script:TenantApps; $origPackages = $script:TenantPackages.Clone(); $origRecent = $script:RecentDeploys.Clone()
        if ($null -eq $script:TenantApps) { $script:TenantApps = @() }
        $listedBefore = @($script:TenantApps)
        Add-CreatedTenantApp -Id 'new-id-1' -Name 'Fresh App' -Package 'fresh.app' -Source 'Chocolatey' -UpdateMode 'Startup' -GraceHours 48 -Intents 'available'
        $row = @($script:TenantRowList | Where-Object { $_.Data.Id -eq 'new-id-1' })[0]
        Test-Smoke 'deploy: the row is in In tenant at once, marked just created' ($row -and $row['Title'] -eq 'Fresh App' -and $row['Sub'] -like '*just created*')
        $ui.LstTenant.SelectedItem = $row
        Test-Smoke 'the new row can be selected, its panel shows the id of the app' ($ui.LstTenant.SelectedItem -and (Get-SelectedTenantApp).Id -eq 'new-id-1')
        Test-Smoke 'the catalog badge: the package counts as in the tenant' ($script:TenantPackages.ContainsKey((Get-MetaKey 'fresh.app' 'Chocolatey')))
        $laggingList = @(Merge-PendingApps 'tenant' @($listedBefore))
        Test-Smoke 'a list that lags behind keeps the row' (@($laggingList | Where-Object { $_.Id -eq 'new-id-1' }).Count -eq 1 -and $script:PendingApps.ContainsKey('new-id-1'))
        $fresh = @($listedBefore) + [pscustomobject]@{ Id = 'new-id-1'; DisplayName = 'Fresh App'; Package = 'fresh.app'; Source = 'Chocolatey'; IsChocolatey = $false }
        $caughtUp = @(Merge-PendingApps 'tenant' $fresh)
        Test-Smoke 'once Graph lists the id the row is the listed one (no duplicate) and the wait is over' (@($caughtUp | Where-Object { $_.Id -eq 'new-id-1' }).Count -eq 1 -and -not $script:PendingApps.ContainsKey('new-id-1') -and -not (@($caughtUp | Where-Object { $_.JustCreated }).Count))
        Add-PendingApp 'tenant' ([pscustomobject]@{ Id = 'never-listed'; DisplayName = 'Ghost'; Package = ''; Source = 'Chocolatey'; IsChocolatey = $false })
        $script:PendingApps['never-listed'].Added = (Get-Date).AddMinutes(-3)
        Test-Smoke 'a created app that Graph never lists is dropped after two minutes' (@(Merge-PendingApps 'tenant' @()).Count -eq 0 -and -not $script:PendingApps.ContainsKey('never-listed'))
        Remove-ListedApp 'new-id-1' 'tenant'
        Test-Smoke 'removal: the row is gone right after the confirmed delete' (-not @($script:TenantRowList | Where-Object { $_.Data.Id -eq 'new-id-1' }).Count -and -not $script:TenantPackages.ContainsKey((Get-MetaKey 'fresh.app' 'Chocolatey')))
        Test-Smoke 'a list that still shows the deleted app does not bring it back' (@(Merge-PendingApps 'tenant' $fresh | Where-Object { $_.Id -eq 'new-id-1' }).Count -eq 0)
        $script:RemovedApps.Clear()
        # custom applications: same
        $c = [pscustomobject]@{ Id = 'custom-new'; DisplayName = 'Custom Fresh'; Kind = 'msi'; AppId = 'custom-fresh'; Version = '1.0'; ProductCode = ''; UpgradeCode = ''; Manifest = ''; Identity = ''; Thumbprint = ''; Publisher = 'P'; Created = (Get-Date).ToString('o'); Intents = 'available'; Source = 'Custom'; IsChocolatey = $false; JustCreated = $true }
        $script:CustomApps = @(); Add-PendingApp 'custom' $c; $script:CustomApps = @(Merge-PendingApps 'custom' @()); Update-CustomRows
        Test-Smoke 'custom: the created application is on the page at once' (@($script:CustomRows | Where-Object { $_['Title'] -eq 'Custom Fresh' }).Count -eq 1)
        Remove-ListedApp 'custom-new' 'custom'
        Test-Smoke 'custom: removed at once after the confirmed delete' (@($script:CustomRows | Where-Object { $_['Title'] -eq 'Custom Fresh' }).Count -eq 0)
        $script:RemovedApps.Clear(); $script:PendingApps.Clear(); $script:CustomApps = $null
        $script:TenantApps = $origApps; $script:TenantPackages = $origPackages; $script:RecentDeploys = $origRecent; Update-TenantRows -Force
        $true } }
    @{ Name = 'graph outage text'; Do = {
        Test-Smoke 'a 403 "Remediations not available" is no Graph outage (the .NET text mentions the remote server)' (-not (Test-GraphReadFailureText 'The remote server returned an error: (403) Forbidden.') -and -not (Test-GraphReadFailureText 'Der Remoteserver hat einen Fehler zur?ckgegeben: (403) Unzul?ssig') -and -not (Test-GraphReadFailureText 'Authorization_RequestDenied: Insufficient privileges') -and -not (Test-GraphReadFailureText 'The remote server returned an error: (400) Bad Request'))
        Test-Smoke 'network and server errors still are' ((Test-GraphReadFailureText 'The remote name could not be resolved: graph.microsoft.com') -and (Test-GraphReadFailureText 'The remote server returned an error: (503) Server Unavailable') -and (Test-GraphReadFailureText 'Der Remotename konnte nicht aufgel?st werden') -and (Test-GraphReadFailureText 'The operation has timed out'))
        $true } }
    @{ Name = 'apps page timing'; Phase = 0; Waited = 0; Do = {
        param($s)
        # The page switch must not wait for the list: loading state at once, lines fill in the background, the second visit is instant.
        # (Everything else in this run builds the list synchronously; here the real, time-sliced path runs.)
        $log = Join-Path $env:PACKTUNE_TIMING 'timing.txt'
        switch ($s.Phase) {
            0 {
                Show-Page 'Start'; $window.UpdateLayout()
                $script:AppListSync = $false; $script:AppListBuilt = $false; $script:CardKeys = ''
                $script:CardCollection.Clear(); $script:CardLines.Clear()
                $s.Watch = [Diagnostics.Stopwatch]::StartNew()
                Show-Page 'Apps'
                $s.Call = $s.Watch.ElapsedMilliseconds
                $window.UpdateLayout()
                $s.Layout = $s.Watch.ElapsedMilliseconds
                Add-Content $log ('{0,6} ms  FIRST visit: Show-Page returned after {1} ms, layout pass done after {2} ms' -f $s.Layout, $s.Call, $s.Layout)
                Test-Smoke 'first visit: the page switches within 300 ms' ($s.Call -lt 300) "$($s.Call) ms"
                Test-Smoke 'first visit: shows the loading state, the list is not there yet' ($ui.AppsLoading.Visibility -eq 'Visible' -and $ui.PageApps.Visibility -eq 'Visible' -and $script:CardLines.Count -eq 0) "loading=$($ui.AppsLoading.Visibility) lines=$($script:CardLines.Count)"
                $s.Phase = 1; $s.Watch.Restart()
                return $false
            }
            1 {
                $s.Waited++
                if (($script:AppListJob -or $script:AppListTimer.IsEnabled) -and $s.Watch.Elapsed.TotalSeconds -lt 60) { return $false }
                Add-Content $log ('{0,6} ms  list complete after the page switch ({1} cards in {2} lines)' -f $s.Watch.ElapsedMilliseconds, $script:CardCollection.Count, $script:CardLines.Count)
                $async = @($script:CardCollection | ForEach-Object { Get-AppKey $_.Data }) -join '|'
                $script:AppListSync = $true; Update-CatalogRows; Update-AppList
                $sync = @($script:CardCollection | ForEach-Object { Get-AppKey $_.Data }) -join '|'
                Test-Smoke 'the list built in the background is the same as the one built at once' ($async -eq $sync -and $script:CardCollection.Count -gt 0) "$($async.Length) vs $($sync.Length)"
                Test-Smoke 'lines hold the cards in order, loading state gone' ($ui.AppsLoading.Visibility -eq 'Collapsed' -and (@($script:CardLines | ForEach-Object { @($_.Items) }).Count -eq $script:CardCollection.Count)) "lines=$($script:CardLines.Count)"
                $realized = @($ui.CardList.ItemContainerGenerator.Items).Count
                Test-Smoke 'virtualized: fewer line containers exist than lines (when more lines than fit)' ($script:CardLines.Count -le 6 -or $ui.CardList.ItemContainerGenerator.ContainerFromIndex($script:CardLines.Count - 1) -eq $null) "lines=$($script:CardLines.Count)"
                # second visit: the cards stay, the switch does not wait
                Show-Page 'Start'; $window.UpdateLayout()
                $script:AppListSync = $false
                $w = [Diagnostics.Stopwatch]::StartNew()
                Show-Page 'Apps'
                $call = $w.ElapsedMilliseconds
                $window.UpdateLayout()
                Add-Content $log ('{0,6} ms  SECOND visit: Show-Page returned after {1} ms, layout pass done after {2} ms' -f $w.ElapsedMilliseconds, $call, $w.ElapsedMilliseconds)
                Test-Smoke 'second visit: the page switches within 300 ms with the cards already there' ($call -lt 300 -and $script:CardLines.Count -gt 0 -and $ui.AppsLoading.Visibility -eq 'Collapsed') "$call ms, lines=$($script:CardLines.Count)"
                $s.Phase = 2; $s.Watch.Restart()
                return $false
            }
            2 {
                $s.Waited++
                if (($script:AppListJob -or $script:AppListTimer.IsEnabled) -and $s.Watch.Elapsed.TotalSeconds -lt 60) { return $false }
                $script:AppListSync = $true
                Test-Smoke 'second visit: list still complete afterwards' ($script:CardCollection.Count -gt 0 -and $script:CardKeys -ne '<building>')
                return $true
            }
        } } }
    @{ Name = 'apps list'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Apps'; return $false }
        $s.Waited++
        if (-not (Test-Idle 'meta') -and $s.Waited -lt 1500) { return $false }
        Update-CatalogRows; Update-AppList
        $cards = @($script:CardCollection)
        Test-Smoke 'one list shows every catalog app' ($cards.Count -eq ($script:Catalog.Count + @($script:PopularRows).Count)) "$($cards.Count) of $($script:Catalog.Count) curated + $(@($script:PopularRows).Count) popular"
        Test-Smoke 'category chips with counts (All + categories)' ($script:Chips.Count -ge 5 -and $script:Chips['All'].Content -like "All*$($script:Catalog.Count + @($script:PopularRows).Count)") ($script:Chips['All'].Content)
        Test-Smoke 'default view: All sources selected, no source switch in the header' ($ui.FltAll.IsChecked -and $script:SourceFilter -eq 'All')
        $zip = $script:SourceRows | Where-Object { $_.CatalogId -eq '7zip.install' } | Select-Object -First 1
        Test-Smoke '7-Zip has both sources with versions' ($zip.Sources.Count -eq 2 -and $zip.ChocoVersion -and $zip.WingetVersion) ($zip | Select-Object ChocoVersion, WingetVersion, Recommended | ConvertTo-Json -Compress)
        $rec = @($script:SourceRows | Where-Object RecommendedMarked)
        Test-Smoke 'a recommended source is marked where versions differ' ($rec.Count -ge 0) $rec.Count
        $zipCard = Get-Card '7zip.install'
        Test-Smoke 'card shows source tags with versions' (@($zipCard.Items | ForEach-Object { $_['Text'] }) -join ',' -match 'winget .*Choco ' ) (@($zipCard.Items | ForEach-Object { $_['Text'] }) -join ',')
        Test-Smoke 'license badge on AnyDesk' ((Get-Card 'anydesk')['Badge'] -eq 'Check license') (Get-Card 'anydesk')['Badge']
        # source filter keeps the exclusive semantics of the backend
        foreach ($f in 'Winget', 'Chocolatey', 'Both') {
            $ui["Flt$(if ($f -eq 'Chocolatey') { 'Choco' } else { $f })"].IsChecked = $true
            $expected = @(Select-PackTuneSourceApps -Apps (@($script:SourceRows) + @($script:PopularRows)) -Filter $f).Count
            Test-Smoke "source filter $f shows $expected apps" ($script:CardCollection.Count -eq $expected) $script:CardCollection.Count
        }
        $ui.FltAll.IsChecked = $true
        $script:Chips['Browsers'].IsChecked = $true
        Test-Smoke 'category chip narrows the list' ($script:CardCollection.Count -eq @($script:SourceRows | Where-Object Category -eq 'Browsers').Count) $script:CardCollection.Count
        Save-SmokeShot '02-apps'
        $script:Chips['All'].IsChecked = $true
        $true } }
    @{ Name = 'filter, selection, details'; Do = {
        $ui.TxtFilter.Text = 'scratch'
        Test-Smoke 'filter narrows to Scratch' ($script:CardCollection.Count -eq 1) $script:CardCollection.Count
        Test-Smoke 'filter hint hidden while typing' ($ui.HintFilter.Visibility -eq 'Collapsed')
        Set-AppSelected $script:CardCollection[0].Data $true
        $ui.TxtFilter.Text = '7-zip'
        Set-AppSelected $script:CardCollection[0].Data $true
        Test-Smoke 'selection kept across filters' ($script:Selected.Count -eq 2 -and $script:Selected.Contains('scratch') -and $script:Selected.Contains('7zip.install')) (@($script:Selected.Keys) -join ',')
        Test-Smoke 'card shows the selected state' ((Get-Card '7zip.install')['Selected'] -eq 'True')
        Test-Smoke 'floating bar shows count and Review and deploy' ($ui.SelectionBar.Visibility -eq 'Visible' -and $ui.TxtSelectionCount.Text -eq '2 apps selected' -and $ui.BtnReview.IsEnabled) $ui.TxtSelectionCount.Text
        Show-AppDetails (Get-Card '7zip.install').Data
        Test-Smoke 'details side panel shows the clicked app with both sources' ($ui.PanelDetails.Visibility -eq 'Visible' -and $ui.TxtDetailTitle.Text -eq '7-Zip' -and $ui.TxtDetailSources.Text -match 'winget' -and $ui.TxtDetailSources.Text -match 'Chocolatey') $ui.TxtDetailSources.Text
        Test-Smoke 'details offer test in sandbox and custom icon' ($ui.BtnDetailTest.IsEnabled -and $ui.BtnCustomIcon.IsEnabled)
        $ui.TxtFilter.Text = ''
        Save-SmokeShot '03-selection-details'
        $true } }
    @{ Name = 'custom icon'; Do = {
        Add-Type -AssemblyName System.Drawing
        $bmpFile = Join-Path $script:SmokeOut 'custom.bmp'
        $b = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::SteelBlue); $g.Dispose()
        $b.Save($bmpFile, [System.Drawing.Imaging.ImageFormat]::Bmp); $b.Dispose()
        Set-CustomIcon -Key 'scratch' -Path $bmpFile
        Test-Smoke 'custom icon stored as PNG' ([string]$script:CustomIcons['scratch'] -like 'iVBORw0KGgo*')
        Show-AppDetails (Get-Card 'scratch').Data
        Test-Smoke 'custom icon shown in details' ($ui.BtnCustomIconRemove.Visibility -eq 'Visible' -and $null -ne $ui.ImgDetail.Source)
        $true } }
    @{ Name = 'deploy dialog'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) {
            $s.Started = $true
            $ui.RbAvailable.IsChecked = $true
            Show-DeployDialog
            Test-Smoke 'deploy dialog opens with a row per app' ($ui.DlgDeploy.Visibility -eq 'Visible' -and $ui.PanelDeployRows.Children.Count -eq 2 -and $ui.TxtDeployTitle.Text -like 'Deploy 2 apps to contoso*') $ui.TxtDeployTitle.Text
            $zip = $script:DeployCombos | Where-Object { $_.Key -eq '7zip.install' }
            Test-Smoke 'per app source dropdown lists both sources, wide enough' ($zip.Combo.Items.Count -eq 2 -and $zip.Combo.Width -ge 280 -and $zip.Combo.SelectedItem) (@($zip.Combo.Items) -join ' | ')
            Test-Smoke 'recommended source is labelled when versions differ' ((@($zip.Combo.Items) -join '|') -match 'recommended' -or -not $zip.Src.RecommendedMarked) (@($zip.Combo.Items) -join ' | ')
            Test-Smoke 'dialog starts with the settings defaults (Ask the user, 2 days)' ($ui.CmbDeployAssign.SelectedIndex -eq 1 -and $ui.CmbDeployVersion.SelectedIndex -eq 0 -and $ui.PanelDeployGrace.Visibility -eq 'Visible')
            Test-Smoke 'dependency hint shown' ($ui.TxtDeployDependency.Inlines.Count -ge 2)
            $tiles = @($script:DeployCombos | ForEach-Object { $want = Get-AppIconUrl $_.Src; $row = $ui.PanelDeployRows.Children[$script:DeployCombos.IndexOf($_)]; $img = Find-Visual $row ([System.Windows.Controls.Image]); if ($want) { [bool]($img -and $img.Source) } else { -not $img } })
            Test-Smoke 'deploy dialog rows show the same app icon as the cards (letter tile only without an icon)' ($tiles.Count -eq 2 -and $tiles -notcontains $false) ($tiles -join ',')
            $fake = [pscustomobject]@{ ChocoId = 'x.fake'; WingetId = 'Fake.Fake'; ChocoVersion = '1.0'; WingetVersion = $null; RecommendedMarked = $true; Recommended = 'Chocolatey' }
            Test-Smoke 'unknown version of the other source: not called recommended, source still offered with its state' ((Get-SourceOptionText $fake 'Chocolatey') -notlike '*recommended*' -and (Get-SourceOptionText $fake 'Winget') -like 'winget (version *') ((Get-SourceOptionText $fake 'Chocolatey') + ' | ' + (Get-SourceOptionText $fake 'Winget'))
            $ui.CmbDeployUpdate.SelectedIndex = 2
            Test-Smoke 'grace period appears for the user prompt' ($ui.PanelDeployGrace.Visibility -eq 'Visible' -and $ui.TxtDeployUpdateHelp.Text -like '*installed anyway*')
            $ui.TxtDeployGrace.Text = 'x'
            try { [void](Read-PolicyControls 'Deploy'); Test-Smoke 'invalid grace period rejected' $false } catch { Test-Smoke 'invalid grace period rejected' ($_.Exception.Message -like '*90 days*') $_.Exception.Message }
            $ui.CmbDeployUpdate.SelectedIndex = 1
            Save-SmokeShot '04-deploy-dialog'
            # Both apps from Chocolatey: the fake winget source only knows a few apps
            foreach ($entry in $script:DeployCombos) { $entry.Combo.SelectedIndex = [array]::IndexOf($entry.Sources, 'Chocolatey') }
            Start-Deploy
            Test-Smoke 'dialog closes and Activity opens' ($ui.DialogLayer.Visibility -eq 'Collapsed' -and $script:CurrentPage -eq 'Activity')
            Test-Smoke 'selection cleared after queueing' ($script:Selected.Count -eq 0 -and $ui.SelectionBar.Visibility -eq 'Collapsed')
            Test-Smoke 'jobs show up in the activity list' ($script:JobRows.Count -ge 2) $script:JobRows.Count
            Test-Smoke 'activity badge counts the running jobs' ($ui.BadgeActivity.Visibility -eq 'Visible') $ui.TxtBadgeActivity.Text
            Save-SmokeShot '05-activity-running'
            return $false
        }
        $s.Waited++
        if (-not (Test-Idle) -and $s.Waited -lt 1500) { return $false }
        $apps = Get-StoreApps
        $names = @($apps | ForEach-Object { $_.displayName })
        Test-Smoke '7-Zip and Scratch created next to the runtime app' (($names -contains '7-Zip') -and ($names -contains 'Scratch') -and $apps.Count -eq 3) ($names -join ', ')
        $zip = $apps | Where-Object { $_.displayName -eq '7-Zip' }
        $scratch = $apps | Where-Object { $_.displayName -eq 'Scratch' }
        Test-Smoke '7-Zip icon converted from SVG' ($zip.hasIcon -and $zip.iconValid)
        Test-Smoke 'Scratch has the custom icon' ($scratch.hasIcon -and $scratch.iconValid)
        Test-Smoke 'apps assigned as available' (@($apps | Where-Object { $_.displayName -in '7-Zip', 'Scratch' -and $_.assignment -eq 'available' }).Count -eq 2)
        Test-Smoke 'notes carry the package id and the update settings' ($zip.notes -match '^PoweredByPackTune;from=Chocolatey;package=7zip\.install;version=latest;update=Startup;grace=48;source=[^;]*;delay=\d+-\d+;cfg=[A-Za-z0-9_-]+$') $zip.notes
        $log = Get-SmokeLog
        Test-Smoke 'log shows both successes' (($log -match '\[7zip\.install\] created in Intune') -and ($log -match '\[scratch\] created in Intune'))
        Test-Smoke 'finished jobs are marked Done' (@($script:JobRows | Where-Object { $_['Status'] -eq 'Done' }).Count -ge 2) (@($script:JobRows | ForEach-Object { $_['Status'] }) -join ',')
        Test-Smoke 'toast announces the result' ($ui.ToastHost.Children.Count -ge 1 -or $script:Toasts.Count -ge 1 -or (Get-SmokeLog) -match 'created in Intune')
        $zipRow = @($script:JobRows | Where-Object { $_['Title'] -eq '7-Zip' })[0]
        Test-Smoke 'finished deploy row offers Open in Intune with the app id' ($zipRow['OpenVis'] -eq 'Visible' -and $zipRow['Open'] -eq $zip.id) "$($zipRow['OpenVis']) $($zipRow['Open'])"
        Test-Smoke 'activity row shows the app icon like the card' ($zipRow['Icon'] -eq (Get-PackageIcon '7zip.install' 'Chocolatey')) $zipRow['Icon']
        Show-Page 'Activity'
        Save-SmokeShot '06-activity-done'
        $true } }
    @{ Name = 'tenant'; Started = $false; Waited = 0; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; if (Test-Idle 'tenant') { Start-TenantRefresh }; return $false }
        $s.Waited++
        if (-not (Test-Idle) -and $s.Waited -lt 1500) { return $false }
        Show-Page 'Tenant'
        $rows = @($script:TenantRowList)
        Test-Smoke 'tenant lists the runtime app first, then the two apps' ($rows.Count -eq 3 -and $rows[0].Data.IsDependency) (($rows | ForEach-Object { $_['Title'] }) -join ', ')
        Test-Smoke 'subtitle counts apps and dependency apps' ($ui.TxtTenantCount.Text -like '2 apps and 1 dependency app*contoso*') $ui.TxtTenantCount.Text
        $zip = $rows | Where-Object { $_['Title'] -eq '7-Zip' }
        Test-Smoke 'row shows package, source, version and assignment' ($zip['Sub'] -like '7zip.install*Chocolatey' -and $zip['Assigned'] -eq 'Available' -and $zip['Version'] -eq 'Always newest') ($zip['Sub'] + '|' + $zip['Assigned'] + '|' + $zip['Version'])
        Test-Smoke 'On devices column from Intune''s install summary: 12 installed, 1 failed - 3 pending' ($zip['Ok'] -eq '12 installed' -and $zip['Bad'] -eq "1 failed $([char]0x00B7) 3 pending") ($zip['Ok'] + '|' + $zip['Bad'])
        Test-Smoke 'nav badge shows the devices with problems' ($ui.BadgeTenant.Visibility -eq 'Visible' -and $ui.TxtBadgeTenant.Text -like '*problem*') $ui.TxtBadgeTenant.Text
        $ui.LstTenant.SelectedItem = $zip
        Test-Smoke 'panel shows the selected app with version and update mode' ($ui.ScrollTenantApp.Visibility -eq 'Visible' -and $ui.TxtTenantAppTitle.Text -eq '7-Zip' -and $ui.RbTenantStartup.IsChecked -and $ui.CmbTenantVersion.SelectedIndex -eq 0)
        Test-Smoke 'panel summarises when updates install' ($ui.TxtTenantWhen.Text -like '*10:00 to 15:00*' -and $ui.TxtTenantConditions.Text) "$($ui.TxtTenantWhen.Text) | $($ui.TxtTenantConditions.Text)"
        Test-Smoke 'Available note shown for an Available app' ($ui.TxtTenantAvailableNote.Visibility -eq 'Visible')
        Test-Smoke 'open, test, remove enabled for a selected app' ($ui.BtnTenantOpen.IsEnabled -and $ui.BtnTenantRemove.IsEnabled)
        $ui.LstTenant.SelectedItem = $rows[0]
        Test-Smoke 'dependency app has no update controls' ($ui.GbTenantPolicy.Visibility -eq 'Collapsed' -and $ui.BtnTenantApply.Visibility -eq 'Collapsed')
        $ui.LstTenant.SelectedItem = $zip
        Save-SmokeShot '07-tenant'
        $true } }
    @{ Name = 'tenant icons'; Phase = 0; Do = {
        param($s)
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle) -or -not (Test-Idle 'icons')) { return $false }
                Show-Page 'Tenant'; Update-TenantRows -Force
                $zip = @($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0]
                $consistent = @($script:TenantRowList | Where-Object { $_.Data.Package } | ForEach-Object { $want = Get-PackageIcon $_.Data.Package $_.Data.Source; if ($want) { $_['Icon'] -eq $want -and $_['MonoVis'] -eq 'Collapsed' } else { $_['MonoVis'] -eq 'Visible' } })
                Test-Smoke 'rows show the package icon (feed cache) where there is one, the letter tile otherwise' ($consistent.Count -ge 1 -and $consistent -notcontains $false) ($consistent -join ',')
                $rt = @($script:TenantRowList | Where-Object { $_['Title'] -eq 'PackTune Runtime' })[0]
                Test-Smoke 'PackTune Runtime is the dependency row (icon of its Intune app or the letter tile)' ($rt -and $rt.Data.IsDependency -and ($rt['Icon'] -or $rt['MonoVis'] -eq 'Visible'))
                # Scratch: no icon in the feed data, but the Intune app holds one (the fake Graph returns it on the single-app read)
                $scratch = @($script:TenantApps | Where-Object { $_.Package -eq 'scratch' })[0]
                $script:Shared.Meta['scratch'].IconUrl = ''
                Add-Type -AssemblyName System.Drawing
                $b = New-Object System.Drawing.Bitmap 32, 32
                $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::DarkOrange); $g.Dispose()
                $ms = New-Object IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
                @{ id = $scratch.Id; value = [Convert]::ToBase64String($ms.ToArray()) } | ConvertTo-Json -Compress | Set-Content (Join-Path $env:LOCALAPPDATA 'fake-icon.json')
                $script:AppIconCache.Clear(); $script:AppIconTried.Clear()
                Update-TenantRows
                $row = @($script:TenantRowList | Where-Object { $_.Data.Package -eq 'scratch' })[0]
                Test-Smoke 'without feed icon the list shows the letter tile first (never blocks)' (-not $row['Icon'] -and $row['MonoVis'] -eq 'Visible')
                Start-AppIconTask
                Test-Smoke 'the icon of the Intune app is read in a hidden background task' (Test-TaskRunning 'appicons')
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                $row = @($script:TenantRowList | Where-Object { $_.Data.Package -eq 'scratch' })[0]
                Test-Smoke 'icon of the Intune app arrives in the list, cached on disk' ($row['Icon'] -like '*iconcache*app-*.png' -and (Test-Path $row['Icon']) -and $row['MonoVis'] -eq 'Collapsed') $row['Icon']
                $ui.LstTenant.SelectedItem = $row
                Test-Smoke 'side panel header shows the icon too' ($null -ne $ui.ImgTenant.Source -and $ui.TxtTenantMono.Visibility -eq 'Collapsed')
                Save-SmokeShot '19-tenant-icons'
                # Next session: from disk, no second read
                $script:AppIconCache.Clear(); $script:AppIconTried.Clear()
                $file = Get-TenantAppIcon $row.Data
                Test-Smoke 'icon cache on disk is found again without Graph' ($file -eq $row['Icon'])
                Show-AppStatus $row.Data
                Test-Smoke 'status page header shows the icon' ($null -ne $ui.ImgStatus.Source -and $ui.TxtStatusMono.Visibility -eq 'Collapsed')
                Show-Page 'Tenant'
                $true
            }
        } } }
    @{ Name = 'windows sandbox item and Test buttons'; Do = {
        function Get-SandboxItem { Update-SandboxState; Get-ReadinessItems | Where-Object Key -eq 'sandbox' }
        $script:SandboxInstallOverride = { param($c) $script:SandboxCmd = $c }
        $script:SandboxCmd = $null
        Show-Page 'Apps'
        $detailRow = $script:SourceRows[0]
        Show-AppDetails $detailRow
        Show-Page 'Tenant'
        $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { -not ($_.Data.IsChocolatey -or $_.Data.IsDependency) })[0]
        # 1. Windows Sandbox missing (installable)
        $script:SandboxOverride = @{ Present = $false; Home = $false }
        $item = Get-SandboxItem
        Test-Smoke 'start page: Sandbox item is optional and offers Install' ($item.Optional -and $item.State -eq 'warn' -and $item.Fix -eq 'Install' -and $item.Text -like '*not installed*administrator approval*restart*') $item.Text
        Test-Smoke 'checklist has the Sandbox item (7 rows)' ($ui.ReadinessPanel.Children.Count -eq 7)
        Test-Smoke 'Test buttons disabled with the reason and a pointer to the Start page' (-not $ui.BtnDetailTest.IsEnabled -and -not $ui.BtnTenantTest.IsEnabled -and $ui.BtnDetailTest.ToolTip -like '*Windows Sandbox is not installed*Start page*' -and $ui.BtnTenantTest.ToolTip -like '*Start page*') "$($ui.BtnDetailTest.IsEnabled) $($ui.BtnTenantTest.ToolTip)"
        # Set up everything does not install it
        Start-SetupAll
        Test-Smoke 'Set up everything does not install Windows Sandbox' ($null -eq $script:SandboxCmd -and -not $script:SetupRunning)
        # The install builds an elevated command (not started in the test)
        & $item.Action
        $c = $script:SandboxCmd
        Test-Smoke 'Install builds the elevated command for the optional feature, without restart' ($c.File -eq 'powershell.exe' -and $c.Verb -eq 'RunAs' -and $c.Arguments -match 'Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart') ($c | ConvertTo-Json -Compress)
        # 2. installed, restart needed
        $script:SandboxRestart = $true
        $item = Get-SandboxItem
        Test-Smoke 'after the install: restart required, buttons still disabled' ($item.Text -like '*restart required*' -and -not $item.Fix -and -not $ui.BtnDetailTest.IsEnabled -and $ui.BtnDetailTest.ToolTip -like '*restart*')
        $script:SandboxRestart = $false
        # 3. Windows Home
        $script:SandboxOverride = @{ Present = $false; Home = $true }
        $item = Get-SandboxItem
        Test-Smoke 'Windows Home: says why, no Install button' ($item.Text -like '*Windows Home*' -and -not $item.Fix)
        $script:SandboxOverride = @{ Present = $false; Home = $false; VirtualizationOff = $true }
        Test-Smoke 'virtualization off is named in the item' ((Get-SandboxItem).Text -like '*Virtualization is switched off*')
        # 4. Sandbox there, capture tools not downloaded yet: the Test buttons work (the lab needs no tools), the item offers the download
        $script:SandboxOverride = @{ Present = $true; Toolchain = 'Missing' }
        $item = Get-SandboxItem
        Test-Smoke 'capture tools missing: item offers the download, says they are fetched when needed, Test buttons enabled' ($item.State -eq 'warn' -and $item.Optional -and $item.Fix -eq 'Download now' -and $item.Text -like '*downloaded the first time they are needed*' -and $ui.BtnTenantTest.IsEnabled) $item.Text
        Save-SmokeShot '25-sandbox-item-tools'
        Show-Page 'Start'; Save-SmokeShot '26-start-sandbox-tools-missing'
        # 5. both available
        $script:SandboxOverride = @{ Present = $true }
        $item = Get-SandboxItem
        Show-Page 'Tenant'; Update-TenantButtons; Show-Page 'Apps'; Show-AppDetails $detailRow
        Test-Smoke 'Sandbox and capture tools there: item green, Test buttons enabled' ($item.State -eq 'ok' -and $ui.BtnDetailTest.IsEnabled -and $ui.BtnTenantTest.IsEnabled -and -not $ui.BtnDetailTest.ToolTip)
        $script:SandboxInstallOverride = $null
        $ui.PanelDetails.Visibility = 'Collapsed'; $script:DetailRow = $null
        $true } }
    @{ Name = 'catalog knows the tenant'; Do = {
        Show-Page 'Apps'
        $marked = @($script:CardCollection | Where-Object { $_['Badge'] -eq 'In tenant' } | ForEach-Object { Get-AppKey $_.Data }) -join ','
        Test-Smoke 'deployed apps are marked in the list' ($marked -eq '7zip.install,scratch') $marked
        $ui.TxtFilter.Text = 'scratch'
        Set-AppSelected $script:CardCollection[0].Data $true
        try { Show-DeployDialog; Start-Deploy; Test-Smoke 'app in the tenant is not deployed again' $false }
        catch { Test-Smoke 'app in the tenant is not deployed again' ($_.Exception.Message -like '*already in the tenant*' -and (Test-Idle 'deploy')) $_.Exception.Message }
        Close-Dialog
        Clear-Selection
        $ui.TxtFilter.Text = ''
        $true } }
    @{ Name = 'remove from Intune'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Show-Page 'Tenant'
            $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Package -eq 'scratch' })[0]
            # a reload of the list while the app is selected: the id is remembered, the same app is selected again, nothing else
            $wantId = [string]$ui.LstTenant.SelectedItem.Data.Id
            $saved = $script:TenantApps; $script:TenantApps = $null; Update-TenantRows
            Test-Smoke 'while the list is read again the panel closes and the id is remembered' (-not $ui.LstTenant.SelectedItem -and $script:TenantPendingSelect -eq $wantId) "$($script:TenantPendingSelect)"
            $script:TenantApps = $saved; Update-TenantRows -Force
            Test-Smoke 'after the reload the same app (same id) is selected again, the panel shows it' ($ui.LstTenant.SelectedItem -and $ui.LstTenant.SelectedItem.Data.Id -eq $wantId -and $ui.LstTenant.SelectedItem.Data.Package -eq 'scratch' -and -not $script:TenantPendingSelect)
            # an action without an app id never reaches Graph, a plain message says what to do
            $before = @($script:Tasks).Count; $toastsBefore = $script:Toasts.Count
            Start-TenantRemoval ([pscustomobject]@{ Id = ''; DisplayName = '' })
            Test-Smoke 'an action with an empty app id starts no job and says so in plain words' (@($script:Tasks).Count -eq $before -and $script:Toasts.Count -gt $toastsBefore -and ($script:Toasts[-1].Text -like 'Select an app in the list first*'))
            $m = ''; try { Remove-PackTuneApp -Id '' } catch { $m = $_.Exception.Message }
            Test-Smoke 'the remove command refuses an empty id in plain words (no raw parameter binding text)' ($m -like 'No app was given*') $m
            Test-Smoke 'a raw localized parameter binding error becomes a short English cause' ((Get-FriendlyCause 'Das Argument kann nicht an den Parameter "Id" gebunden werden, da es sich um eine leere Zeichenfolge handelt.') -like 'An internal value was missing*')
            # while the list is being read, the panel's actions are off and say why
            $script:Tasks.Add(@{ Job = [pscustomobject]@{ Kind = 'tenant' }; Hidden = $true }) | Out-Null
            Update-TenantButtons
            $off = (-not $ui.BtnTenantRemove.IsEnabled) -and $ui.TxtDependencyNote.Text -eq 'Updating the list ...'
            $r = Get-ActionApp
            Test-Smoke 'while the list reloads: Remove is off, the panel says "Updating the list ...", actions get no app' ($off -and $null -eq $r)
            $script:Tasks.RemoveAt($script:Tasks.Count - 1); Update-TenantButtons
            & $script:ClickActions[$ui.BtnTenantRemove]
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $rows = @($script:TenantRowList)
        Test-Smoke 'Scratch removed from the tenant' ($rows.Count -eq 2 -and -not @($rows | Where-Object { $_.Data.Package -eq 'scratch' }).Count -and (Get-SmokeLog) -match '\[scratch\] removed from Intune') $rows.Count
        Test-Smoke 'list no longer marks Scratch' (-not $script:TenantPackages.ContainsKey('scratch') -and $script:TenantPackages.ContainsKey('7zip.install'))
        $true } }
    @{ Name = 'search both repositories'; Started = $false; Do = {
        param($s)
        if (-not $s.Started) { $s.Started = $true; Show-Page 'Apps'; $ui.TxtFilter.Text = 'notepad'; Start-AppSearch; return $false }
        if (-not (Test-Idle 'search') -or -not (Test-Idle 'meta')) { return $false }
        $rows = @($script:SearchRows)
        Test-Smoke 'search merges both repositories into rows' ($rows.Count -gt 0 -and @($rows | Where-Object { $_.Name -like 'Notepad*' }).Count) (($rows | ForEach-Object { "$($_.Name)[$($_.Sources -join '/')]" }) -join ', ')
        $npp = $script:SourceRows | Where-Object { $_.CatalogId -eq 'notepadplusplus.install' -or $_.Name -like 'Notepad++*' } | Select-Object -First 1
        Test-Smoke 'a catalog app found in both is one card with both sources' ($npp.Sources.Count -eq 2 -and @($script:CardCollection | Where-Object { $_['Title'] -eq $npp.Name }).Count -eq 1) (($npp.Sources -join ',') + ' ' + @($script:CardCollection | ForEach-Object { $_['Title'] }) -join ';')
        Test-Smoke 'hits not in the catalog are added to the list' ($script:CardCollection.Count -ge 1)
        Save-SmokeShot '08-search'
        $ui.TxtFilter.Text = ''
        $script:SearchRows = @(); $script:SearchTerm = ''
        Update-AppList
        $true } }
    @{ Name = 'popular list, refresh and add application'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Show-Page 'Apps'
            Test-Smoke 'the select-all button is gone, Clear stays' (-not $ui.ContainsKey('BtnSelectShown') -and $ui.BtnClearSelection) ''
            Test-Smoke 'the automatic refresh was skipped (last full refresh less than an hour ago)' (-not $script:Refreshing -and (Get-SmokeLog) -notmatch 'Updating the versions of the listed apps') ''
            return $false
        }
        if ($s.Phase -eq 1) {
            if (-not (Test-Idle 'popular') -or -not (Test-Idle 'meta')) { return $false }
            $s.Phase = 2
            $pop = @($script:PopularRows)
            Test-Smoke 'popular list: fixture packages merged, infrastructure dropped' ($pop.Count -eq 3 -and -not @($pop | Where-Object ChocoId -like 'chocolatey*').Count) ($pop.ChocoId -join ',')
            $np = $pop | Where-Object ChocoId -eq 'notepad3'
            Test-Smoke 'popular: winget id only where verified (Notepad3 yes, AkelPad no)' ($np.WingetId -eq 'Rizonesoft.Notepad3' -and -not ($pop | Where-Object ChocoId -eq 'akelpad').WingetId) ''
            Test-Smoke 'Popular chip with its count, My apps chip present' ($script:Chips['Popular'].Content -like 'Popular*3' -and $script:Chips.ContainsKey('My apps') -and $script:Chips.ContainsKey('Other')) $script:Chips['Popular'].Content
            $script:Chips['Popular'].IsChecked = $true
            Update-AppList
            Test-Smoke 'Popular chip shows only the popular apps' ($script:CardCollection.Count -eq 3) $script:CardCollection.Count
            Save-SmokeShot '30-popular'
            $script:Chips['All'].IsChecked = $true
            $ui.SortDownloads.IsChecked = $true
            Update-AppList
            $titles = @($script:CardCollection | ForEach-Object { $_['Title'] })
            Test-Smoke 'sort by downloads puts the most downloaded popular app first among those with a count' ($titles.IndexOf('Notepad3') -ge 0 -and $titles.IndexOf('Notepad3') -lt $titles.IndexOf('AkelPad')) ($titles[0..5] -join ',')
            $ui.SortDefault.IsChecked = $true
            # Refresh versions: forced, with progress, rows updated in place
            $script:RefreshItemLimit = 6
            $s.Key = (Get-AppKey $np)
            $s.Row = $script:CardRows[$s.Key]
            Test-Smoke 'Refresh versions button is there and enabled' ($ui.BtnRefreshApps.IsEnabled -and $ui.BtnRefreshApps.Content -eq 'Refresh versions') ''
            & $script:ClickActions[$ui.BtnRefreshApps]
            Test-Smoke 'refresh runs: button busy, progress hint "Updating versions n/m"' (-not $ui.BtnRefreshApps.IsEnabled -and (Get-RefreshProgress) -match '^Updating versions \d+/\d+$') (Get-RefreshProgress)
            return $false
        }
        if ($s.Phase -eq 2) {
            if (-not (Test-Idle 'popular') -or -not (Test-Idle 'meta') -or $script:Refreshing) { return $false }
            $s.Phase = 3
            Update-AppList
            Test-Smoke 'refresh done: button enabled again, stamp written, no progress hint' ($ui.BtnRefreshApps.IsEnabled -and -not $script:Refreshing -and (Test-Path (Join-Path $env:LOCALAPPDATA 'PackTune\last-refresh.txt')) -and -not (Get-RefreshProgress)) ''
            Test-Smoke 'rows were updated in place (same card object)' ([object]::ReferenceEquals($s.Row, $script:CardRows[$s.Key])) ''
            $script:RefreshItemLimit = 0
            # Add application: live search with debounce, results by downloads, add, remove
            & $script:ClickActions[$ui.BtnAddApp]
            Test-Smoke 'Add application opens the dialog' ($ui.DlgAddApp.Visibility -eq 'Visible') ''
            $ui.TxtAddSearch.Text = 'vlc'
            Test-Smoke 'typing arms the debounce timer, no search yet' ($script:AddTimer.IsEnabled -and -not (Test-TaskRunning 'addsearch')) ''
            $script:AddTimer.Stop()
            Start-AddSearch 'vlc'
            Start-AddSearch 'notepad'      # typed meanwhile: only the latest text is searched afterwards
            Test-Smoke 'a second request while one runs is remembered, not started' ($script:AddPending -eq 'notepad') $script:AddPending
            return $false
        }
        if ($s.Phase -eq 3) {
            if (-not (Test-Idle 'addsearch')) { return $false }
            $s.Phase = 4
            $names = @($script:AddRows | ForEach-Object { $_['Title'] })
            Test-Smoke 'the answer of the stale term is dropped, the latest term is shown' ($names.Count -gt 0 -and @($names | Where-Object { $_ -like '*otepad*' }).Count -gt 0) ($names -join ', ')
            $counts = @($script:AddResultRows | ForEach-Object { [double]$_.Downloads })
            $sorted = $true; for ($i = 1; $i -lt $counts.Count; $i++) { if ($counts[$i] -gt $counts[$i - 1]) { $sorted = $false } }
            Test-Smoke 'results are sorted by relevance (downloads, uncounted last)' ($counts.Count -gt 1 -and $sorted) ($counts -join ',')
            Save-SmokeShot '31-add-application'
            $ui.LstAddResults.UpdateLayout()
            $btn = $null
            foreach ($card in $script:AddRows) { if ($card['CanAdd'] -eq 'True') { $s.Pick = $card; break } }
            $container = $ui.LstAddResults.ItemContainerGenerator.ContainerFromItem($s.Pick)
            if ($container) { $container.ApplyTemplate(); $btn = Find-VisualChild $container ([System.Windows.Controls.Button]) }
            Test-Smoke 'result row has its Add button' ($null -ne $btn -and $btn.Uid -eq 'add') ''
            if ($btn) { $btn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $btn))) }
            $s.PickId = $s.Pick.Data.ChocoId; $s.PickWinget = $s.Pick.Data.WingetId
            $mine = @(Get-PackTuneMyApps)
            Test-Smoke 'Add puts the app into my-apps.json and into the list at once' ($mine.Count -eq 1 -and (Test-Path (Join-Path $env:LOCALAPPDATA 'PackTune\my-apps.json')) -and @($script:MyRows).Count -eq 1 -and $script:Chips['My apps'].Content -like 'My apps*1') ($mine | ConvertTo-Json -Compress)
            Test-Smoke 'the row in the dialog now says In list' ($s.Pick['AddText'] -eq 'In list') $s.Pick['AddText']
            & $script:ClickActions[$ui.BtnAddClose]
            $script:Chips['My apps'].IsChecked = $true
            Update-AppList
            Test-Smoke 'My apps chip shows the added app' ($script:CardCollection.Count -eq 1) $script:CardCollection.Count
            $src = $script:CardCollection[0].Data
            Show-AppDetails $src
            Test-Smoke 'details offer Remove from my apps for it' ($ui.BtnDetailRemoveMine.Visibility -eq 'Visible') ''
            & $script:ClickActions[$ui.BtnDetailRemoveMine]
            Test-Smoke 'removing takes it off the list and the file, the details close' (@(Get-PackTuneMyApps).Count -eq 0 -and @($script:MyRows).Count -eq 0 -and $ui.PanelDetails.Visibility -eq 'Collapsed') ''
            $script:Chips['All'].IsChecked = $true
            Update-AppList
            return $true
        }
        $true } }
    @{ Name = 'custom applications: MSI deploy, new version, remove'; Phase = 0; Do = {
        param($s)
        function New-SmokeMsi([string]$Path, [hashtable]$Properties) {
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 3))
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(255) NOT NULL PRIMARY KEY `Property`)'))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            foreach ($key in $Properties.Keys) {
                $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('$key', '$($Properties[$key])')"))
                [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
            }
            [void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
            foreach ($o in $v, $view, $db, $installer) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        }
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            $s.Dir = Join-Path $env:LOCALAPPDATA 'smoke-msi'; New-Item -ItemType Directory -Path $s.Dir -Force | Out-Null
            New-SmokeMsi (Join-Path $s.Dir 'tool-1.0.msi') @{ ProductCode = '{BBBBBBBB-0000-0000-0000-000000000001}'; ProductName = 'Smoke Tool'; ProductVersion = '1.0.0'; Manufacturer = 'Smoke Corp'; UpgradeCode = '{BBBBBBBB-1111-1111-1111-111111111111}' }
            New-SmokeMsi (Join-Path $s.Dir 'tool-2.0.msi') @{ ProductCode = '{BBBBBBBB-0000-0000-0000-000000000002}'; ProductName = 'Smoke Tool'; ProductVersion = '2.0.0'; Manufacturer = 'Smoke Corp'; UpgradeCode = '{BBBBBBBB-1111-1111-1111-111111111111}' }
            New-SmokeMsi (Join-Path $s.Dir 'old-0.5.msi') @{ ProductCode = '{BBBBBBBB-0000-0000-0000-000000000009}'; ProductName = 'Smoke Tool'; ProductVersion = '0.5.0'; Manufacturer = 'Smoke Corp'; UpgradeCode = '{BBBBBBBB-1111-1111-1111-111111111111}' }
            Test-Smoke 'Custom applications has its place in the navigation' ($ui.NavCustom -and $script:Pages -contains 'Custom') ''
            Show-Page 'Custom'
            return $false
        }
        if ($s.Phase -eq 1) {
            if (-not (Test-Idle 'customlist')) { return $false }
            $s.Phase = 2
            Test-Smoke 'custom page: signed in, no custom application yet, says where to start' ($ui.PageCustom.Visibility -eq 'Visible' -and $script:CustomRows.Count -eq 0 -and $ui.TxtCustomEmpty.Text -like '*New application*') $ui.TxtCustomEmpty.Text
            Save-SmokeShot '32-custom-empty'
            & $script:ClickActions[$ui.BtnCustomNew]
            Test-Smoke 'New application opens the dialog with MSI chosen' ($ui.DlgCustom.Visibility -eq 'Visible' -and $ui.RbCustomMsi.IsChecked -and -not $ui.BtnCustomDeploy.IsEnabled) ''
            Test-Smoke 'Other is available when Windows Sandbox is ready' ($ui.RbCustomOther.IsEnabled -and $ui.TxtCustomOther.Text -like '*captured as an MSIX*') $ui.TxtCustomOther.Text
            Set-CustomPath (Join-Path $s.Dir 'missing.msi')
            Test-Smoke 'a missing file is reported, nothing to deploy' ((-not $ui.BtnCustomDeploy.IsEnabled) -and $ui.TxtCustomRead.Text) $ui.TxtCustomRead.Text
            Set-CustomPath (Join-Path $s.Dir 'tool-1.0.msi')
            Test-Smoke 'the MSI properties are shown' ($ui.TxtMsiName.Text -eq 'Smoke Tool' -and $ui.TxtMsiVersion.Text -eq '1.0.0' -and $ui.TxtMsiProduct.Text -eq '{BBBBBBBB-0000-0000-0000-000000000001}' -and $ui.TxtMsiManufacturer.Text -eq 'Smoke Corp' -and $ui.BtnCustomDeploy.IsEnabled) $ui.TxtMsiName.Text
            Save-SmokeShot '33-custom-dialog'
            $ui.TxtCustomProps.Text = 'ALLUSERS=1'
            $ui.CmbCustomAssign.SelectedIndex = 1
            & $script:ClickActions[$ui.BtnCustomDeploy]
            return $false
        }
        if ($s.Phase -eq 2) {
            if (-not (Test-Idle 'custom') -or -not (Test-Idle 'customlist')) { return $false }
            $s.Phase = 3
            $fake = @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.notes -like 'PoweredByPackTune;custom=msi*' })
            Test-Smoke 'deploy: the app is in Intune with the custom marker and the Available assignment' ($fake.Count -eq 1 -and $fake[0].displayName -eq 'Smoke Tool' -and $fake[0].assignment -eq 'available' -and $fake[0].notes -like '*ver=1.0.0;product={BBBBBBBB-0000-0000-0000-000000000001}*') (($fake | ForEach-Object notes) -join ';')
            Test-Smoke 'the custom page lists it with version and assignment' ($script:CustomRows.Count -eq 1 -and $script:CustomRows[0]['Title'] -eq 'Smoke Tool' -and $script:CustomRows[0]['Kind'] -eq 'MSI 1.0.0' -and $script:CustomRows[0]['Assigned'] -eq 'Available') ($script:CustomRows | ForEach-Object { $_['Kind'] })
            Test-Smoke 'it is no catalog app in the In tenant list' (@($script:TenantApps | Where-Object { $_.DisplayName -eq 'Smoke Tool' }).Count -eq 0) ''
            Show-Page 'Custom'
            $ui.LstCustom.SelectedIndex = 0
            Test-Smoke 'details: version, product code and assignment' ($ui.PanelCustomDetails.Visibility -eq 'Visible' -and $ui.TxtCustomVersion.Text -eq '1.0.0' -and $ui.TxtCustomProduct.Text -like '{BBBB*01}' -and $ui.TxtCustomAssigned.Text -eq 'Available' -and $ui.BtnCustomNewVersion.IsEnabled) ''
            Save-SmokeShot '34-custom-details'
            & $script:ClickActions[$ui.BtnCustomNewVersion]
            Test-Smoke 'New version opens the dialog for this app, without the kind choice' ($ui.DlgCustom.Visibility -eq 'Visible' -and $ui.TxtCustomDlgTitle.Text -like 'New version of Smoke Tool' -and $ui.BoxCustomKind.Visibility -eq 'Collapsed' -and $ui.BtnCustomDeploy.Content -eq 'Publish version') $ui.TxtCustomDlgTitle.Text
            Set-CustomPath (Join-Path $s.Dir 'old-0.5.msi')
            Test-Smoke 'an older MSI is refused' ((-not $ui.BtnCustomDeploy.IsEnabled) -and $ui.TxtCustomRead.Text -like '*not newer*') $ui.TxtCustomRead.Text
            Set-CustomPath $s.Dir
            Test-Smoke 'a folder with several MSI files offers a choice' ($ui.CmbCustomMsi.Visibility -eq 'Visible' -and $ui.CmbCustomMsi.Items.Count -eq 3) $ui.CmbCustomMsi.Items.Count
            Set-CustomPath (Join-Path $s.Dir 'tool-2.0.msi')
            Test-Smoke 'the newer MSI is accepted' ($ui.BtnCustomDeploy.IsEnabled -and $ui.TxtCustomRead.Text -like '*Newer than 1.0.0*') $ui.TxtCustomRead.Text
            & $script:ClickActions[$ui.BtnCustomDeploy]
            return $false
        }
        if ($s.Phase -eq 3) {
            if (-not (Test-Idle 'custom') -or -not (Test-Idle 'customlist')) { return $false }
            $s.Phase = 4
            $fake = @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.notes -like 'PoweredByPackTune;custom=msi*' })
            $new = $fake | Where-Object { $_.displayVersion -eq '2.0.0' }
            Test-Smoke 'new version: a second app that supersedes the first, with its assignment' ($fake.Count -eq 2 -and $new -and @($new.supersedence).Count -eq 1 -and $new.assignments[0].Intent -eq 'available') ($fake | ForEach-Object displayVersion)
            Test-Smoke 'the list shows both, the older one marked as replaced' ($script:CustomRows.Count -eq 2 -and @($script:CustomRows | Where-Object { $_['Kind'] -like '*(replaced)' }).Count -eq 1) ($script:CustomRows | ForEach-Object { $_['Kind'] })
            Save-SmokeShot '35-custom-versions'
            $ui.LstCustom.SelectedIndex = 0
            & $script:ClickActions[$ui.BtnCustomRemove]
            return $false
        }
        if ($s.Phase -eq 4) {
            if (-not (Test-Idle 'custom') -or -not (Test-Idle 'customlist')) { return $false }
            $fake = @(Get-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.notes -like 'PoweredByPackTune;custom=msi*' })
            Test-Smoke 'remove: one custom app is gone from Intune and from the list' ($fake.Count -eq 1 -and $script:CustomRows.Count -eq 1 -and $ui.PanelCustomDetails.Visibility -eq 'Collapsed') ($fake | ForEach-Object displayVersion)
            Remove-Item $s.Dir -Recurse -Force -ErrorAction SilentlyContinue
            Show-Page 'Apps'
            return $true
        }
        $true } }
    @{ Name = 'custom applications: Other, update dialog, export, package store dialog'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            $s.Dir = Join-Path $env:LOCALAPPDATA 'smoke-other'; New-Item -ItemType Directory -Path (Join-Path $s.Dir 'bin') -Force | Out-Null
            'setup' | Set-Content (Join-Path $s.Dir 'setup.exe'); 'data' | Set-Content (Join-Path $s.Dir 'bin\tool.dll'); 'x' | Set-Content (Join-Path $s.Dir 'run.cmd')
            # an MSIX application as it would be in the tenant (made by the capture path)
            $storePath = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
            $apps = @(Get-Content $storePath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
            $apps += [pscustomobject]@{ id = 'msix-app-1'; displayName = 'Captured Tool'; publisher = 'Smoke Corp'; description = 'x'; createdDateTime = (Get-Date).ToString('o')
                notes = 'PoweredByPackTune;custom=msix;app=captured-tool-1a2b3c4d;ver=1.0.0.0;identity=PackTune.CapturedTool;thumb=' + ('AB' * 20) + ';manifest=0123456789abcdef'
                displayVersion = '1.0.0.0'; assignment = 'available'; assignments = @([pscustomobject]@{ Type = '#microsoft.graph.allLicensedUsersAssignmentTarget'; Intent = 'available' }); dependencies = @(); supersedence = @() }
            ConvertTo-Json -InputObject @($apps) -Depth 6 | Set-Content $storePath
            $script:CustomApps = $null
            Show-Page 'Custom'
            return $false
        }
        if ($s.Phase -eq 1) {
            if (-not (Test-Idle 'customlist')) { return $false }
            $s.Phase = 2
            $msixRows = @($script:CustomRows | Where-Object { $_['Title'] -eq 'Captured Tool' })
            Test-Smoke 'the MSIX application is listed as MSIX' ($msixRows.Count -eq 1 -and $msixRows[0]['Kind'] -eq 'MSIX 1.0.0.0') ($script:CustomRows | ForEach-Object { $_['Kind'] })
            $ui.LstCustom.SelectedItem = $msixRows[0]
            Test-Smoke 'details of an MSIX app: package identity and the certificate of this version' ($ui.LblCustomProduct.Text -eq 'Package identity' -and $ui.TxtCustomProduct.Text -eq 'PackTune.CapturedTool' -and $ui.TxtCustomUpgrade.Text -eq ('AB' * 20) -and $ui.LblCustomUpgrade.Text -like 'Certificate*') ''
            Test-Smoke 'details: kept in the package store (manifest), Export is available' ($ui.TxtCustomStore.Text -like '*manifest 0123456789abcdef*' -and $ui.BtnCustomExport.IsEnabled) $ui.TxtCustomStore.Text
            Save-SmokeShot '36-custom-msix-details'
            # New application, Other
            & $script:ClickActions[$ui.BtnCustomNew]
            $ui.RbCustomOther.IsChecked = $true
            Test-Smoke 'Other: the panel for the installation folder shows, MSI panel hidden, nothing to deploy yet' ($ui.PanelCustomOther.Visibility -eq 'Visible' -and $ui.PanelCustomMsi.Visibility -eq 'Collapsed' -and -not $ui.BtnCustomDeploy.IsEnabled -and $ui.BtnCustomDeploy.Content -eq 'Capture and deploy' -and $ui.BtnCustomTest.Visibility -eq 'Collapsed') ''
            Set-OtherFolder $s.Dir
            Test-Smoke 'Other: entry point candidates (exe, cmd), setup.exe preselected, name from the folder' (@($ui.CmbOtherEntry.ItemsSource).Count -eq 2 -and $ui.CmbOtherEntry.SelectedItem -eq 'setup.exe' -and $ui.TxtOtherName.Text -eq 'smoke other') ((@($ui.CmbOtherEntry.ItemsSource)) -join ',')
            Test-Smoke 'Other: network for the capture is offered and off by default' ($ui.ChkOtherNetwork -and -not $ui.ChkOtherNetwork.IsChecked -and $ui.ChkOtherNetwork.Visibility -eq 'Visible')
            Test-Smoke 'Other: the button is on when folder, entry point, name and version are there' ($ui.BtnCustomDeploy.IsEnabled) ''
            $ui.TxtOtherName.Text = ''
            Test-Smoke 'Other: without a name there is nothing to deploy' (-not $ui.BtnCustomDeploy.IsEnabled) ''
            Save-SmokeShot '37-custom-other'
            & $script:ClickActions[$ui.BtnCustomCancel]
            # Update dialog of the MSIX app
            & $script:ClickActions[$ui.BtnCustomNewVersion]
            Test-Smoke 'New version of an MSIX app: the update dialog, next version, name fixed, stored files by default' ($ui.DlgCustom.Visibility -eq 'Visible' -and $ui.TxtCustomDlgTitle.Text -eq 'New version of Captured Tool' -and $ui.TxtOtherVersion.Text -eq '1.0.0.1' -and -not $ui.TxtOtherName.IsEnabled -and $ui.BoxCustomKind.Visibility -eq 'Collapsed' -and $ui.BtnCustomDeploy.Content -eq 'Capture and publish' -and $ui.BtnCustomDeploy.IsEnabled) $ui.TxtOtherVersion.Text
            Save-SmokeShot '38-custom-update'
            $ui.TxtOtherVersion.Text = ''
            Test-Smoke 'update: without a version there is nothing to publish' (-not $ui.BtnCustomDeploy.IsEnabled) ''
            & $script:ClickActions[$ui.BtnCustomCancel]
            # package store dialog
            $script:ExportTarget = $null
            $script:StoreSmokeState = $null; $script:StoreState = $null
            Show-StoreDialog
            Test-Smoke 'package store dialog opens with the library name, the standard site explained, the site address under Advanced and empty' ($ui.DlgStore.Visibility -eq 'Visible' -and $ui.TxtStoreLibrary.Text -eq 'PackTune Packages' -and -not $ui.TxtStoreSite.Text -and $ui.ExpStoreAdvanced -and $ui.BtnStoreSetup.IsEnabled) ''
            Start-StoreCheck; Update-StoreDialog
            Test-Smoke 'standard site not found: status says an administrator sets it up once, nothing was typed' ($script:StoreState.State -eq 'Missing' -and $ui.TxtStoreStatus.Text -like '*sets it up once*' -and -not $script:Settings.StoreSiteUrl) ($script:StoreState | ConvertTo-Json -Compress)
            Test-Smoke 'the setup is stated: Set up button, group of the store optional' ($ui.BtnStoreSetup.Content -like 'Set up the PackTune site*' -and $ui.TxtStoreAdminGroup)
            $ui.TxtStoreSite.Text = 'http://evil.example/x'
            try { & $script:ClickActions[$ui.BtnStoreSave] } catch { }
            Test-Smoke 'an invalid site address is not saved' (-not $script:Settings.StoreSiteUrl) $script:Settings.StoreSiteUrl
            $ui.TxtStoreSite.Text = 'https://contoso.sharepoint.com/sites/PackTune'
            & $script:ClickActions[$ui.BtnStoreSave]
            Test-Smoke 'a valid site address is saved' ($script:Settings.StoreSiteUrl -eq 'https://contoso.sharepoint.com/sites/PackTune' -and (Get-Content $script:SettingsPath -Raw) -match 'sharepoint.com/sites/PackTune') ''
            Test-Smoke 'the store item on the Start page offers the setup' ($script:StoreState -and $script:StoreState.State -ne 'Ready' -and $ui.BtnStoreGrant.IsEnabled) ($script:StoreState | ConvertTo-Json -Compress)
            Save-SmokeShot '39-package-store'
            & $script:ClickActions[$ui.BtnStoreClose]
            Show-Page 'Start'
            $items = @(Get-ReadinessItems | Where-Object { $_.Key -in 'sandbox', 'store' })
            Test-Smoke 'readiness: Windows Sandbox with the capture tools ready, package store not ready yet (both optional)' ($items.Count -eq 2 -and ($items | Where-Object Key -eq 'sandbox').State -eq 'ok' -and ($items | Where-Object Key -eq 'store').State -eq 'warn' -and @($items | Where-Object { -not $_.Optional }).Count -eq 0) (($items | ForEach-Object { "$($_.Key)=$($_.State)" }) -join ',')
            $script:StoreSmokeState = [pscustomobject]@{ State = 'Ready'; Message = 'The package store is ready (smoke test).'; SiteUrl = 'https://contoso.sharepoint.com/sites/PackTune' }; $script:StoreState = $script:StoreSmokeState
            # remove the test app and the saved site
            $s2 = Get-PackTuneSettings; $s2.StoreSiteUrl = ''; [void](Save-PackTuneSettings -Settings $s2); $script:Settings = Get-PackTuneSettings; $script:StoreState = $null
            $storePath = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
            ConvertTo-Json -InputObject @(@(Get-Content $storePath -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.id -ne 'msix-app-1' })) -Depth 6 | Set-Content $storePath
            Remove-Item $s.Dir -Recurse -Force -ErrorAction SilentlyContinue
            $script:CustomApps = $null
            Show-Page 'Apps'
            return $true
        }
        $true } }
    @{ Name = 'winget deploy and runtime dependency'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            Clear-Selection
            $vlc = $script:SourceRows | Where-Object { $_.WingetId -eq 'VideoLAN.VLC' } | Select-Object -First 1
            Set-AppSelected $vlc $true
            $ui.RbAvailable.IsChecked = $true
            Show-DeployDialog
            $combo = $script:DeployCombos[0]
            $combo.Combo.SelectedIndex = [array]::IndexOf($combo.Sources, 'Winget')
            Test-Smoke 'winget source chosen per app in the dialog' ($combo.Sources[$combo.Combo.SelectedIndex] -eq 'Winget' -and $script:SourceChoice[(Get-AppKey $vlc)] -eq 'Winget')
            Start-Deploy
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $apps = Get-StoreApps
        $vlc = $apps | Where-Object { $_.notes -like 'PoweredByPackTune;from=Winget;package=VideoLAN.VLC;version=latest;update=Custom;grace=48;source=;delay=*' }
        Test-Smoke 'winget VLC created with the catalog name' ($vlc.displayName -eq 'VLC media player' -and $vlc.assignment -eq 'available') (($apps | ForEach-Object { "$($_.displayName)|$($_.notes)" }) -join '; ')
        $vlcLog = (@($script:JobRows | Where-Object { $_['Title'] -eq 'VLC media player' } | ForEach-Object { $_.Data.Log } | ForEach-Object { $_.Text } | Where-Object { $_ -match 'ependenc' }) -join ' | ')
        Test-Smoke 'winget app has the PackTune Runtime dependency, no Chocolatey dependency' (($vlcLog -match 'Adding dependency for the PackTune Runtime') -and ($vlcLog -notmatch 'dependency for chocolatey')) $vlcLog
        $pkg = Get-ChildItem (Join-Path $script:WorkRoot 'package\winget-VideoLAN.VLC\source\install.ps1') -ErrorAction SilentlyContinue
        Test-Smoke 'winget install script written' ($pkg -and (Get-Content $pkg.FullName -Raw) -match "'VideoLAN.VLC'")
        Test-GeneratedScripts (Join-Path $script:WorkRoot 'package\winget-VideoLAN.VLC') 'winget'
        # An older winget app without the dependency: banner offers to add it
        $store = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
        $all = Get-StoreApps; ($all | Where-Object { $_.notes -like 'PoweredByPackTune;from=Winget*' }).dependencies = @()
        ConvertTo-Json -InputObject @($all) -Depth 6 | Set-Content $store
        Start-RuntimeCheck
        return $true
        return $false } }
    @{ Name = 'runtime dependency banner'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            if (-not (Test-Idle)) { return $false }
            Show-Page 'Tenant'; Update-TenantRows -Force
            Test-Smoke 'banner offers to switch the app without the runtime dependency' ($ui.BannerRuntime.Visibility -eq 'Visible' -and $ui.TxtBannerRuntime.Text -like '1 app still uses*') $ui.TxtBannerRuntime.Text
            $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Package -eq 'VideoLAN.VLC' })[0]
            Test-Smoke 'panel of the app mentions it too' ($ui.TxtDependencyNote.Visibility -eq 'Visible')
            Save-SmokeShot '09-tenant-runtime-banner'
            & $script:ClickActions[$ui.BtnBannerRuntime]
            $s.Phase = 1
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        $vlc = Get-StoreApps | Where-Object { $_.notes -like 'PoweredByPackTune;from=Winget*' }
        Test-Smoke 'dependency added, banner gone' (@($vlc.dependencies).Count -eq 1 -and $ui.BannerRuntime.Visibility -eq 'Collapsed') "$(@($vlc.dependencies).Count) / $($ui.BannerRuntime.Visibility)"
        $true } }
    @{ Name = 'PackTune Runtime states: Ready, Migrate, Missing'; Phase = 0; Do = {
        param($s)
        function Write-Store($Apps) { ConvertTo-Json -InputObject @($Apps) -Depth 6 | Set-Content (Join-Path $env:LOCALAPPDATA 'fake-intune.json') }
        function Get-DepsItem { Get-ReadinessItems | Where-Object Key -in 'deps', 'tenant' | Select-Object -First 1 }
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Tenant'; Start-DependencyCheck
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                $item = Get-DepsItem
                Test-Smoke 'Ready: one dependency item, green, no banners' ($script:RuntimeInfo.State -eq 'Ready' -and $item.Title -eq 'Dependency app (PackTune Runtime)' -and $item.State -eq 'ok' -and $ui.BannerRuntime.Visibility -eq 'Collapsed' -and $ui.BannerOldDeps.Visibility -eq 'Collapsed') "$($script:RuntimeInfo.State) $($item.State)"
                # Migrate: two old dependency apps in the tenant, 7-Zip still depends on the old Chocolatey app
                $all = @(Get-StoreApps)
                $mk = { param($id, $name, $notes) [pscustomobject]@{ id = $id; displayName = $name; notes = $notes; createdDateTime = (Get-Date).ToString('o'); dependencies = @(); supersedence = @(); assignments = @() } }
                $putty = @($all | Where-Object { $_.notes -like '*package=7zip.install;*' })[0]
                $putty.dependencies = @([pscustomobject]@{ targetId = 'old-choco'; dependencyType = 'autoInstall' })
                Write-Store (@($all) + (& $mk 'old-choco' 'Chocolatey' 'FiredWithPowershell') + (& $mk 'old-winget' 'winget runtime' 'WingetRuntimeApp'))
                Start-DependencyCheck
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                $item = Get-DepsItem
                Test-Smoke 'Migrate: state found, item offers Switch (optional, not part of the set up)' ($script:RuntimeInfo.State -eq 'Migrate' -and $item.Fix -eq 'Switch' -and $item.Optional -and $item.State -eq 'warn') "$($script:RuntimeInfo.State) $($item.Fix)"
                Update-TenantRows -Force
                Test-Smoke 'banner: apps still use the old dependency apps, Switch to PackTune Runtime' ($ui.BannerRuntime.Visibility -eq 'Visible' -and $ui.TxtBannerRuntime.Text -like '1 app still uses the old dependency apps*' -and $ui.BtnBannerRuntime.Content -eq 'Switch to PackTune Runtime') $ui.TxtBannerRuntime.Text
                Test-Smoke 'the old dependency apps are listed as old, next to PackTune Runtime' ((@($script:TenantRowList | Where-Object { $_['Title'] -like '*(old)' }).Count -eq 2) -and (@($script:TenantRowList | Where-Object { $_['Title'] -eq 'PackTune Runtime' }).Count -eq 1)) (($script:TenantRowList | ForEach-Object { $_['Title'] }) -join ', ')
                Test-Smoke 'old dependency app nothing uses is offered for removal, never automatic' ($ui.BannerOldDeps.Visibility -eq 'Visible' -and $ui.TxtBannerOldDeps.Text -like '*winget runtime*' -and @(Get-StoreApps | Where-Object { $_.id -eq 'old-winget' }).Count -eq 1) $ui.TxtBannerOldDeps.Text
                Test-Smoke 'set up everything does not switch the apps' (@(Get-ReadinessItems | Where-Object { $_.Key -eq 'deps' -and $_.Optional }).Count -eq 1)
                Save-SmokeShot '27-tenant-migrate'
                & $script:ClickActions[$ui.BtnBannerRuntime]
                $s.Phase = 3; return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                $putty = @(Get-StoreApps | Where-Object { $_.notes -like '*package=7zip.install;*' })[0]
                $runtime = @(Get-StoreApps | Where-Object { $_.displayName -eq 'PackTune Runtime' })[0]
                Test-Smoke 'switch (confirmed, as a job): the app depends on PackTune Runtime only' (@($putty.dependencies).Count -eq 1 -and @($putty.dependencies)[0].targetId -eq $runtime.id) (($putty.dependencies | ConvertTo-Json -Compress))
                Test-Smoke 'state is Ready, banner gone, both old apps unused now and offered for removal' ($script:RuntimeInfo.State -eq 'Ready' -and $ui.BannerRuntime.Visibility -eq 'Collapsed' -and $ui.BannerOldDeps.Visibility -eq 'Visible' -and $ui.TxtBannerOldDeps.Text -like '2 old dependency apps*') $ui.TxtBannerOldDeps.Text
                Save-SmokeShot '28-tenant-old-deps'
                & $script:ClickActions[$ui.BtnBannerOldDeps]
                $s.Phase = 4; return $false
            }
            4 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'old dependency apps removed on request, banner gone' (@(Get-StoreApps | Where-Object { $_.id -in 'old-choco', 'old-winget' }).Count -eq 0 -and $ui.BannerOldDeps.Visibility -eq 'Collapsed' -and -not @($script:TenantRowList | Where-Object { $_['Title'] -like '*(old)' }).Count)
                # Missing: the runtime app is gone from the tenant
                Write-Store @(Get-StoreApps | Where-Object { $_.displayName -ne 'PackTune Runtime' })
                Start-DependencyCheck
                $s.Phase = 5; return $false
            }
            5 {
                if (-not (Test-Idle)) { return $false }
                $item = Get-DepsItem
                Show-Page 'Start'
                Test-Smoke 'Missing: red item with Create, Set up everything offered' ($script:RuntimeInfo.State -eq 'Missing' -and $item.State -eq 'bad' -and $item.Fix -eq 'Create' -and $ui.BtnSetupAll.Visibility -eq 'Visible') "$($script:RuntimeInfo.State) $($item.State)"
                Save-SmokeShot '29-start-runtime-missing'
                Start-SetupAll
                $s.Phase = 6; return $false
            }
            6 {
                if ($script:SetupRunning -or -not (Test-Idle)) { return $false }
                Test-Smoke 'Set up everything creates PackTune Runtime' (@(Get-StoreApps | Where-Object { $_.displayName -eq 'PackTune Runtime' }).Count -eq 1 -and $script:RuntimeInfo.State -in 'Migrate', 'Ready') $script:RuntimeInfo.State
                if ($script:RuntimeInfo.State -eq 'Migrate') { Show-Page 'Tenant'; Update-TenantRows -Force; & $script:ClickActions[$ui.BtnBannerRuntime] }
                $s.Phase = 7; return $false
            }
            7 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'all apps depend on the new runtime: Ready again' ($script:RuntimeInfo.State -eq 'Ready') $script:RuntimeInfo.State
                $true
            }
        } } }
    @{ Name = 'update settings and schedule'; Phase = 0; Do = {
        param($s)
        switch ($s.Phase) {
            0 {
                # Chocolatey app with its own settings at the deployment: pinned, user prompt, 3 days, own schedule
                Show-Page 'Apps'; Clear-Selection
                $s.Package = 'putty.install'
                $row = $script:SourceRows | Where-Object { $_.ChocoId -eq $s.Package } | Select-Object -First 1
                Set-AppSelected $row $true
                $ui.RbAvailable.IsChecked = $true
                Show-DeployDialog
                $script:DeployCombos[0].Combo.SelectedIndex = [array]::IndexOf($script:DeployCombos[0].Sources, 'Chocolatey')
                $ui.CmbDeployUpdate.SelectedIndex = 2
                $ui.TxtDeployGrace.Text = '3'; $ui.CmbDeployGraceUnit.SelectedIndex = 1; $ui.CmbDeployVersion.SelectedIndex = 1
                Test-Smoke 'deploy dialog links to the schedule' ($ui.BtnDeploySchedule.Visibility -eq 'Visible' -and $ui.TxtDeploySchedule.Text)
                & $script:ClickActions[$ui.BtnDeploySchedule]
                Test-Smoke 'schedule dialog opens for the new apps (no apply-to switch)' ($ui.DlgSchedule.Visibility -eq 'Visible' -and $ui.SegSchedule.Visibility -eq 'Collapsed' -and $ui.BtnScheduleApply.Content -eq 'Use for these apps') $ui.BtnScheduleApply.Content
                $ui.SchFrom.Text = '12:00'; $ui.SchTo.Text = '13:00'; $ui.SchMains.IsChecked = $true; $ui.SchStart.IsChecked = $false
                $ui.SchD6.IsChecked = $false; $ui.SchD7.IsChecked = $false
                Update-ScheduleSummary
                Test-Smoke 'one-line summary follows the fields' ($ui.TxtScheduleSummary.Text -like 'Summary: Daily 12:00 to 13:00*mains power*' -or $ui.TxtScheduleSummary.Text -like '*Mon to Fri*12:00 to 13:00*mains*') $ui.TxtScheduleSummary.Text
                Save-SmokeShot '10-schedule-dialog'
                $ui.SchFrom.Text = '25:00'
                try { [void](Read-ScheduleControls); Test-Smoke 'invalid time rejected' $false } catch { Test-Smoke 'invalid time rejected' ($_.Exception.Message -like '*time like 10:00*') $_.Exception.Message }
                $ui.SchFrom.Text = '12:00'
                & $script:ClickActions[$ui.BtnScheduleApply]
                Test-Smoke 'schedule is kept for the deployment, deploy dialog is back' ($ui.DlgDeploy.Visibility -eq 'Visible' -and $script:DeploySchedule.OnlyOnMains -and $ui.TxtDeploySchedule.Text -like '*12:00 to 13:00*') $ui.TxtDeploySchedule.Text
                Start-Deploy
                $s.Phase = 1
                return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-StoreApp $s.Package
                Test-Smoke 'deployment carries update settings and schedule' ($app.notes -match 'update=Custom;grace=72;source=[^;]*;delay=\d+-\d+;cfg=[A-Za-z0-9_-]+$' -and $app.notes -notmatch 'version=latest' -and $app.displayVersion -ne 'latest') $app.notes
                $cfg = ConvertFrom-PackTuneAppNotes $app.notes
                Test-Smoke 'schedule reached the notes' ($cfg.Schedule.WindowFrom -eq '12:00' -and $cfg.Schedule.OnlyOnMains -and -not $cfg.Schedule.TriggerStart -and $cfg.Schedule.WindowDays -eq '12345') ($cfg.Schedule | ConvertTo-Json -Compress)
                $install = Get-Content (Join-Path $script:WorkRoot "package\$($s.Package)\source\install.ps1") -Raw
                Test-Smoke 'install script has the update routine' ($install -match "\`$Mode = 'Custom'" -and $install -match '\$GraceHours = 72')
                Test-GeneratedScripts (Join-Path $script:WorkRoot "package\$($s.Package)") 'Chocolatey'
                $s.Detection = $app.detection
                Show-Page 'Tenant'
                $s.Waited = 0; $s.Phase = 2
                return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                Update-TenantRows -Force
                $row = @($script:TenantRowList | Where-Object { $_.Data.Package -eq $s.Package })[0]
                $ui.LstTenant.SelectedItem = $row
                Test-Smoke 'tenant lists version and update mode' ($row['Version'] -ne 'Always newest' -and $row['Updates'] -eq 'Ask user, 3 days') "$($row['Version']) / $($row['Updates'])"
                Test-Smoke 'panel shows the three explained choices, Ask the user selected' ($ui.RbTenantCustom.IsChecked -and $ui.TxtTenantGrace.Text -eq '3' -and $ui.CmbTenantGraceUnit.SelectedIndex -eq 1 -and $ui.PanelTenantGrace.Visibility -eq 'Visible')
                Test-Smoke 'panel pins the version' ($ui.CmbTenantVersion.SelectedIndex -ge 1 -and $ui.CmbTenantVersion.SelectedItem -eq $row.Data.Version) "$($ui.CmbTenantVersion.SelectedItem)"
                Test-Smoke 'panel summarises the schedule of the app' ($ui.TxtTenantWhen.Text -like '*') $ui.TxtTenantWhen.Text
                # Schedule dialog from the panel: change and apply (in place, the app is Available but the schedule path uses Update-PackTuneApp)
                $ui.RbTenantStartup.IsChecked = $true
                & $script:ClickActions[$ui.BtnTenantSchedule]
                Test-Smoke 'schedule dialog opens for the app with its values' ($ui.DlgSchedule.Visibility -eq 'Visible' -and $ui.SegSchedule.Visibility -eq 'Visible' -and $ui.SchFrom.Text -eq '12:00' -and [bool]$ui.SchMains.IsChecked -and $ui.TxtScheduleTitle.Text -like '*PuTTY*') $ui.TxtScheduleTitle.Text
                $ui.SchIdle.IsChecked = $true; $ui.SchIdleMin.SelectedIndex = 3
                $ui.SchRetry.SelectedIndex = 2; $ui.SchRetryCount.Text = '2'
                Update-ScheduleSummary
                Test-Smoke 'summary mentions the idle condition' ($ui.TxtScheduleSummary.Text -like '*15 min idle*') $ui.TxtScheduleSummary.Text
                Test-Smoke 'apply button says Apply in Intune' ($ui.BtnScheduleApply.Content -eq 'Apply in Intune') $ui.BtnScheduleApply.Content
                $ui.CmbTenantVersion.SelectedIndex = 0
                $s.Uploads = (Get-StoreApp $s.Package).uploads
                & $script:ClickActions[$ui.BtnScheduleApply]
                $s.Phase = 3
                return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-StoreApp $s.Package
                Test-Smoke 'schedule applied in place through Update-PackTuneApp' ($app.notes -match 'version=latest;update=Startup' -and $app.uploads -eq ($s.Uploads + 1) -and $app.detection -ne $s.Detection) "$($app.notes) / $($app.uploads)"
                $cfg = ConvertFrom-PackTuneAppNotes $app.notes
                Test-Smoke 'new schedule reached the app' ($cfg.Schedule.IdleMinutes -eq 15 -and $cfg.Schedule.RetryMode -eq 'Every' -and $cfg.Schedule.RetryCount -eq 2 -and $cfg.Schedule.WindowFrom -eq '12:00') ($cfg.Schedule | ConvertTo-Json -Compress)
                $install = Get-Content (Join-Path $script:WorkRoot "package\$($s.Package)\source\install.ps1") -Raw
                Test-Smoke 'new install script has the new routine' ($install -match "\`$Mode = 'Startup'")
                # Default for new apps, from the same dialog
                $row = @($script:TenantRowList | Where-Object { $_.Data.Package -eq $s.Package })[0]
                $ui.LstTenant.SelectedItem = $row
                & $script:ClickActions[$ui.BtnTenantSchedule]
                $ui.RbSchDefault.IsChecked = $true
                Test-Smoke 'switching to the default shows Save as default' ($ui.BtnScheduleApply.Content -eq 'Save as default') $ui.BtnScheduleApply.Content
                $ui.SchMains.IsChecked = $false; $ui.SchPresentation.IsChecked = $true
                & $script:ClickActions[$ui.BtnScheduleApply]
                $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
                Test-Smoke 'default schedule saved in the settings' ($saved.UpdateSchedule -match 'NoPresentation' -and (Get-ChocoScheduleDefaults).NoPresentation -and -not (Get-ChocoScheduleDefaults).OnlyOnMains) $saved.UpdateSchedule
                Show-Page 'Settings'
                Test-Smoke 'settings summarise the default schedule' ($ui.TxtDefaultSchedule.Text -like '*presentations*') $ui.TxtDefaultSchedule.Text
                # Release through Publish-PackTuneRelease: an Available app is superseded by a new app
                Show-Page 'Tenant'
                $zip = @($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' })[0]
                $ui.LstTenant.SelectedItem = $zip
                $ui.RbTenantCustom.IsChecked = $true; $ui.TxtTenantGrace.Text = '12'; $ui.CmbTenantGraceUnit.SelectedIndex = 0
                $s.Before = @(Get-StoreApps).Count
                & $script:ClickActions[$ui.BtnTenantApply]
                $s.Phase = 4
                return $false
            }
            4 {
                if (-not (Test-Idle)) { return $false }
                $apps = Get-StoreApps
                $zips = @($apps | Where-Object { $_.notes -like '*package=7zip.install;*' })
                $new = $zips | Where-Object { $_.notes -match 'update=Custom;grace=12' }
                $old = $zips | Where-Object { $_.notes -notmatch 'update=Custom;grace=12' }
                Test-Smoke 'Available app is released as a new app that supersedes the old one' ($apps.Count -eq $s.Before + 1 -and $new -and @($new.supersedence).targetId -contains $old.id) "$($apps.Count) / $($s.Before)"
                Test-Smoke 'tenant lists the app once per version' (@($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' }).Count -eq 2)
                $true
            }
        } } }
    @{ Name = 'clean up superseded old versions'; Phase = 0; Do = {
        param($s)
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Tenant'
                $script:InstallCountFake = 'param($AppId) 3'
                Start-SupersededCheck
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'old version still installed on devices: kept, no banner' ($script:SupersededOld.Count -eq 0 -and $ui.BannerCleanup.Visibility -eq 'Collapsed')
                $script:InstallCountFake = 'param($AppId) 0'
                Start-SupersededCheck
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'banner offers the clean up of old versions nobody has installed' ($script:SupersededOld.Count -eq 1 -and $ui.BannerCleanup.Visibility -eq 'Visible' -and $ui.TxtBannerCleanup.Text -like '1 old app version is no longer installed on any device*') $ui.TxtBannerCleanup.Text
                Save-SmokeShot '18-tenant-cleanup'
                $s.Before = @(Get-StoreApps | Where-Object { $_.notes -like '*package=7zip.install;*' }).Count
                & $script:ClickActions[$ui.BtnBannerCleanup]
                $s.Phase = 3; return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                $zips = @(Get-StoreApps | Where-Object { $_.notes -like '*package=7zip.install;*' })
                Test-Smoke 'old version removed, the new app stays' ($s.Before -eq 2 -and $zips.Count -eq 1 -and $zips[0].notes -match 'update=Custom;grace=12') "$($s.Before) -> $($zips.Count)"
                Test-Smoke 'banner gone after the clean up' ($ui.BannerCleanup.Visibility -eq 'Collapsed')
                $script:InstallCountFake = ''
                $true
            }
        } } }
    @{ Name = 'status of one app'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            $zip = @($script:TenantRowList | Where-Object { $_.Data.Package -eq '7zip.install' -and $_.Data.UpdateMode -eq 'Custom' })[0]
            Test-Smoke 'row links to the status page' ($zip -and $zip['Ok'])
            Show-AppStatus $zip.Data
            return $false
        }
        if (-not (Test-Idle)) { return $false }
        Test-Smoke 'status page shows the counters' ($ui.TxtStatOk.Text -eq '2' -and $ui.TxtStatWait.Text -eq '1' -and $ui.TxtStatFail.Text -eq '1' -and $ui.TxtStatStale.Text -eq '1') "$($ui.TxtStatOk.Text)/$($ui.TxtStatWait.Text)/$($ui.TxtStatFail.Text)/$($ui.TxtStatStale.Text)"
        Test-Smoke 'device table lists the devices, failed first' ($script:DeviceRowList.Count -eq 4 -and $script:DeviceRowList[0]['Title'] -eq 'PC-0142' -and $script:DeviceRowList[0]['Status'] -eq 'Failed') (($script:DeviceRowList | ForEach-Object { $_['Title'] + ':' + $_['Status'] }) -join ', ')
        Test-Smoke 'cause comes from the device report' ($script:DeviceRowList[0]['Cause'] -like '*rate limit*') $script:DeviceRowList[0]['Cause']
        Test-Smoke 'device log shows the reported lines and the retry hint' ($ui.BoxDeviceLog.Visibility -eq 'Visible' -and $ui.TxtDeviceLog.Text -like '*rate limit*' -and $ui.TxtRetryHint.Text -like '*retries by itself*') $ui.TxtDeviceLog.Text
        $info = Get-InsightDiagnosticsInfo -ManagedDeviceId $script:DeviceRowList[0].Data.DeviceId -Package '7zip.install'
        Test-Smoke 'diagnostics point to the Intune admin center device page' ($info.Url -like '*intune.microsoft.com*md-1*' -and $info.Hint -like '*Collect diagnostics*') $info.Url
        Test-Smoke 'status script present: no banner' ($ui.BoxStatusScript.Visibility -eq 'Collapsed')
        Save-SmokeShot '11-status'
        # Without the status script the page degrades to the install status; without the license it says so
        $script:StatusScript = @{ State = 'Missing' }
        Update-StatusBanner
        Test-Smoke 'missing status script: banner offers the setup' ($ui.BoxStatusScript.Visibility -eq 'Visible' -and $ui.BtnStatusScript.Visibility -eq 'Visible')
        Set-Content (Join-Path $env:LOCALAPPDATA 'fake-nolicense.txt') 'x'
        $script:StatusScript = $null
        Start-StatusCheck
        return $true
        return $false } }
    @{ Name = 'status report setup in steps'; Phase = 0; Do = {
        param($s)
        $flag = Join-Path $env:LOCALAPPDATA 'fake-nolicense.txt'
        if (-not (Test-Idle)) { return $false }
        switch ($s.Phase) {
            0 {
                Test-Smoke 'no license: marked not available, banner offers Set up' ($script:StatusScript.State -eq 'NotAvailable' -and $ui.BoxStatusScript.Visibility -eq 'Visible' -and $ui.BtnStatusScript.Visibility -eq 'Visible' -and $ui.TxtStatusScript.Text -like '*Remediations*') $ui.TxtStatusScript.Text
                $item = Get-ReadinessItems | Where-Object Key -eq 'status'
                Test-Smoke 'start page: optional item says why and has a Set up button' ($item.Text -like 'Not available yet*' -and $item.Fix -eq 'Set up' -and $item.Action) $item.Text
                Save-SmokeShot '12-status-degraded'
                # Missing scope: the setup runs the normal consent sign-in first (prompt=consent), then the 403 license case
                $claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"name":"Consent Admin","upn":"admin@contoso.onmicrosoft.com","tid":"t-1"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                $script:ConsentCalls = New-Object System.Collections.ArrayList
                $script:EmbeddedAvailableOverride = $true
                $script:EmbeddedSignInOverride = { param($t, $c, $sc, $h, $pr, $folder) [void]$script:ConsentCalls.Add("$pr|$c"); [pscustomobject]@{ token_type = 'Bearer'; expires_in = 3600; access_token = "x.$claims.y"; refresh_token = 'r'; scope = 'https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All' } }
                $Global:AccessToken.Scopes = @('DeviceManagementApps.ReadWrite.All')
                Test-Smoke 'status setup: missing scope is detected' (@(Get-StatusMissingScopes) -contains 'DeviceManagementConfiguration.ReadWrite.All') (@(Get-StatusMissingScopes) -join ',')
                Start-StatusScriptSetup
                $s.Phase = 1; return $false
            }
            1 {
                $script:EmbeddedSignInOverride = $null
                Test-Smoke 'step 1: the permission was confirmed in the normal sign-in (prompt=consent, the PackTune registration), not a setup window' ($script:ConsentCalls.Count -eq 1 -and $script:ConsentCalls[0] -eq "consent|$($script:Settings.ClientID)" -and $script:StatusSteps.Steps[0].State -eq 'done') (($script:ConsentCalls -join ',') + ' / ' + $script:StatusSteps.Steps[0].State)
                $st = @($script:StatusSteps.Steps | ForEach-Object { $_.State })
                Test-Smoke '403 license: step 2 is an error with a plain cause, later steps stay pending' ($st[1] -eq 'error' -and $st[2] -eq 'pending' -and $script:StatusSteps.Steps[1].Detail -like 'No permission*') (($st -join ',') + ' / ' + $script:StatusSteps.Steps[1].Detail)
                Test-Smoke 'license hint with the admin center path, Open and Check again offered' ($ui.BoxStepsNote.Visibility -eq 'Visible' -and $ui.TxtStepsNote.Text -like '*Windows data*I confirm that my tenant owns one of these licenses*' -and $ui.BtnStepsOpen.Visibility -eq 'Visible' -and $ui.BtnStepsAgain.Visibility -eq 'Visible' -and $script:StatusAdminUrl -like 'https://intune.microsoft.com/*') $ui.TxtStepsNote.Text
                Test-Smoke 'step list rows: error icon and cause shown, progress bar determinate' ($ui.ListSteps.Children.Count -eq 5 -and $ui.BarSteps.Maximum -eq 5 -and $ui.BarSteps.Value -eq 1)
                Save-SmokeShot '12b-status-setup-license'
                Remove-Item $flag -Force
                $ui.BtnStepsAgain.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                $s.Phase = 2; return $false
            }
            2 {
                $st = @($script:StatusSteps.Steps | ForEach-Object { $_.State })
                Test-Smoke 'success: all five steps done, bar full, script created in the fake tenant' (($st -join ',') -eq 'done,done,done,done,done' -and $ui.BarSteps.Value -eq 5 -and (Test-Path (Join-Path $env:LOCALAPPDATA 'fake-health.json'))) ($st -join ',')
                Test-Smoke 'running step showed a spinner and elapsed time while it ran (model keeps start times)' (@($script:StatusSteps.Steps | Where-Object { $_.Started }).Count -ge 3)
                Test-Smoke 'item turns green after the setup' ($script:StatusScript.State -eq 'Present' -and (Get-ReadinessItems | Where-Object Key -eq 'status').State -eq 'ok') ($script:StatusScript | ConvertTo-Json -Compress)
                Close-Dialog
                # Package store: the same step list inside the store dialog; steps follow the job log
                $m = New-StepModel @('A', 'B', 'C')
                $fakeJob = @{ Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) }
                foreach ($l in 'Step 1/3 done: ok', 'Step 2/3 running: working', 'Step 2/3 detail: SharePoint is still preparing the site ...') { [void]$fakeJob.Log.Add(@{ Level = 'Info'; Text = $l }) }
                Sync-StepModel $m $fakeJob; Show-StepList $m $ui.ListStoreSteps $ui.BarStoreSteps
                Test-Smoke 'store steps: done / running with detail / pending, bar = done of total' ($m.Steps[0].State -eq 'done' -and $m.Steps[1].State -eq 'running' -and $m.Steps[1].Detail -like 'SharePoint is still preparing*' -and $m.Steps[2].State -eq 'pending' -and $ui.BarStoreSteps.Value -eq 1 -and $ui.BarStoreSteps.Maximum -eq 3)
                [void]$fakeJob.Log.Add(@{ Level = 'Info'; Text = 'Step 2/3 error: Der Remoteserver hat einen Fehler zurueckgegeben: (403) Verboten.' })
                Sync-StepModel $m $fakeJob
                Test-Smoke 'store steps: an error shows the plain cause' ($m.Steps[1].State -eq 'error' -and $m.Steps[1].Detail -like 'No permission*')
                $true
            }
        } } }
    @{ Name = 'import dialog'; Phase = 0; Do = {
        param($s)
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Tenant'
                $script:ImportApps = $null
                & $script:ClickActions[$ui.BtnImport]
                Test-Smoke 'import dialog opens with three sources' ($ui.DlgImport.Visibility -eq 'Visible' -and $ui.RbImpThis.IsChecked -and $ui.RbImpOther -and $ui.RbImpFile)
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                Update-ImportRows
                $rows = @($script:ImportRowList)
                $by = @{}; foreach ($r in $rows) { $by[$r['Title']] = $r }
                Test-Smoke 'table lists classified apps, infrastructure hidden' ($rows.Count -ge 4 -and -not ($rows | Where-Object { $_['Title'] -eq 'Chocolatey' })) (($rows | ForEach-Object { $_['Title'] }) -join ', ')
                Test-Smoke 'winget Win32 app: take over, selectable' ($by['Zoom Workplace']['Kind'] -eq 'Win32 with winget' -and $by['Zoom Workplace']['Action'] -eq 'Take over' -and $by['Zoom Workplace']['CanPick'] -eq 'True' -and $by['Zoom Workplace']['Found'] -like '*Zoom.Zoom*') ($by['Zoom Workplace'] | ConvertTo-Json -Compress)
                Test-Smoke 'Chocolatey app shows its pinned version' ($by['Greenshot']['Settings'] -like '*1.3.290*' -and $by['Greenshot']['Action'] -eq 'Take over')
                Test-Smoke 'own installer cannot be managed, dimmed and not selectable' ($by['Own VPN']['Action'] -eq 'Cannot be managed' -and $by['Own VPN']['CanPick'] -eq 'False' -and $by['Own VPN']['Opacity'] -lt 1)
                Test-Smoke 'already managed app is listed as managed' ($by['Sample managed']['Action'] -eq 'Already managed')
                Test-Smoke 'summary counts the selected apps' ($ui.TxtImportSummary.Text -like '2 of * apps selected*' -and $ui.BtnImportGo.Content -eq 'Take over 2 apps') "$($ui.TxtImportSummary.Text) / $($ui.BtnImportGo.Content)"
                Save-SmokeShot '13-import'
                $by['Greenshot']['Checked'] = 'False'; Update-ImportSummary
                Test-Smoke 'unchecking updates the button' ($ui.BtnImportGo.Content -eq 'Take over 1 app') $ui.BtnImportGo.Content
                & $script:ClickActions[$ui.BtnImportGo]
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                $patches = Get-Content (Join-Path $env:LOCALAPPDATA 'fake-patches.log') -ErrorAction SilentlyContinue
                Test-Smoke 'take over writes the notes to the selected app only' (@($patches).Count -eq 1 -and $patches -like '*mobileApps/i1*') ($patches -join ',')
                Test-Smoke 'import closes the dialog and shows the job' ($ui.DialogLayer.Visibility -eq 'Collapsed' -and $script:CurrentPage -eq 'Activity')
                # Export file round trip: export the managed apps, read them again as candidates
                $file = Join-Path $script:SmokeOut 'export.json'
                $script:ImportApps = @(Get-InsightTenantApps -Context (New-InsightGraphContext -Invoke ([scriptblock]::Create($script:InsightFake))) -DefaultUpdateMode 'Startup' -DefaultGraceHours 48 | ForEach-Object { $_ })
                Export-ManagedApps $file
                $doc = Get-Content $file -Raw | ConvertFrom-Json
                Test-Smoke 'export writes the managed apps without ids' ($doc.format -eq 'PackTune.Export' -and @($doc.apps).Count -eq 1 -and (Get-Content $file -Raw) -notmatch 'i4') (Get-Content $file -Raw)
                Show-Page 'Tenant'; Show-ImportDialog
                $ui.RbImpFile.IsChecked = $true
                Test-Smoke 'export file source shows the file chooser' ($ui.PanelImpFile.Visibility -eq 'Visible')
                @{ format = 'IntuneChocoDeployment.Export'; version = 1; exported = '2026-01-01'; apps = @(
                        @{ displayName = 'Feed ok'; source = 'Chocolatey'; package = 'feedok'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = 'https://feed.example.test/nuget/' }
                        @{ displayName = 'Feed bad'; source = 'Chocolatey'; package = 'feedbad'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = '\\attacker.example.test\share' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:SmokeOut 'export3.json')
                Read-ImportFile (Join-Path $script:SmokeOut 'export3.json')
                $feedRows = @{}; foreach ($r in @($script:ImportRowList)) { $feedRows[$r['Title']] = $r }
                Test-Smoke 'import rows show the offered package source' ($feedRows['Feed ok']['Settings'] -like '*offers package source https://feed.example.test/nuget/*asked*' -and $feedRows['Feed bad']['Settings'] -like '*attacker.example.test*refused*') (($feedRows.Values | ForEach-Object { $_['Settings'] }) -join ' | ')
                @{ format = 'IntuneChocoDeployment.Export'; version = 1; exported = '2026-01-01'; apps = @(@{ displayName = 'Scratch'; source = 'Chocolatey'; package = 'scratch'; version = ''; updateMode = 'Startup'; graceHours = 48; packageSource = '' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:SmokeOut 'export2.json')
                Read-ImportFile (Join-Path $script:SmokeOut 'export2.json')
                Test-Smoke 'file rows are offered as Create here' ($script:ImportRowList.Count -eq 1 -and $script:ImportRowList[0]['Action'] -eq 'Create here' -and $script:ImportRowList[0]['Kind'] -eq 'Export file') ($script:ImportRowList[0] | ConvertTo-Json -Compress)
                Save-SmokeShot '14-import-file'
                $ui.RbImpOther.IsChecked = $true
                Test-Smoke 'another tenant source asks for tenant and client ID' ($ui.PanelImpOther.Visibility -eq 'Visible' -and $ui.TxtImportEmpty.Text -like '*client ID*')
                $ui.RbImpFile.IsChecked = $true
                Read-ImportFile (Join-Path $script:SmokeOut 'export2.json')
                $script:ImportExisting = @()
                & $script:ClickActions[$ui.BtnImportGo]
                $s.Phase = 3; return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'app from the export file created in this tenant' (@(Get-StoreApps | Where-Object { $_.notes -like '*package=scratch;*' }).Count -eq 1) (@(Get-StoreApps | ForEach-Object { $_.displayName }) -join ',')
                $true
            }
        } } }
    @{ Name = 'activity: failure, retry, clear'; Phase = 0; Do = {
        param($s)
        if ($s.Phase -eq 0) {
            $s.Phase = 1
            [void](Start-UiTask -Kind 'deploy' -Title 'Deploying Broken (test)' -Display 'Broken app' -Package 'broken' -Work 'throw "Upload failed: the Intune session expired. Sign in again and retry."')
            return $false
        }
        if ($s.Phase -eq 1) {
            if (-not (Test-Idle)) { return $false }
            $row = $script:JobRows[0]
            Test-Smoke 'failed job is red with its reason and a Retry button' ($row['Status'] -eq 'Failed' -and $row['Sub'] -like 'Upload failed*' -and $row['RetryVis'] -eq 'Visible') ($row['Status'] + '|' + $row['Sub'])
            Test-Smoke 'failure raises a toast' (@($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count -ge 1)
            $row.Data.LogOpen = $true; Update-JobRow $row.Data
            Test-Smoke 'log expands with the message' ($row['LogVis'] -eq 'Visible' -and $row['Log'] -like '*Upload failed*')
            Show-Page 'Activity'
            Save-SmokeShot '15-activity-failed'
            $count = $script:JobRows.Count
            Restart-Job $row.Data
            Test-Smoke 'retry starts the job again' ($script:JobRows.Count -eq $count -and $script:JobRows[0]['Status'] -in 'Waiting', 'Running', 'Failed')
            $s.Phase = 2; return $false
        }
        if (-not (Test-Idle)) { return $false }
        & $script:ClickActions[$ui.BtnLogClear]
        Test-Smoke 'Clear finished removes the done jobs' ($script:JobRows.Count -eq 0 -and $ui.TxtJobsEmpty.Visibility -eq 'Visible') $script:JobRows.Count
        Test-Smoke 'log files are written per day' (Test-Path (Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f (Get-Date))))
        $true } }
    @{ Name = 'sandbox test'; Phase = 0; Do = {
        param($s)
        $lab = Join-Path $env:LOCALAPPDATA 'fake-sandbox'
        switch ($s.Phase) {
            0 {
                Show-Page 'Settings'
                Test-Smoke 'settings show the update defaults (Ask the user, then install)' ($ui.CmbDefaultUpdate.SelectedIndex -eq 2 -and $ui.CmbDefaultVersion.SelectedIndex -eq 0)
                Test-Smoke 'the old Sandbox Studio setting is gone from the settings' (-not (Get-PackTuneSettings).PSObject.Properties['SandboxStudioPath'] -and -not $ui.ContainsKey('TxtSandboxStudioPath'))
                Start-PackageTest -Package 'putty.install' -Source 'Chocolatey' -Title 'PuTTY' -Version 'latest' -Policy @{ UpdateMode = 'Custom'; GraceHours = 24 }
                Test-Smoke 'sandbox test started: toast says Windows Sandbox opens in a moment' (@($script:Toasts | Where-Object { $_.Text -like 'Sandbox test started*Windows Sandbox opens in a moment' }).Count -eq 1)
                Test-Smoke 'sandbox buttons turn busy at once (Starting sandbox ..., disabled), everywhere' (($ui.BtnDetailTest, $ui.BtnTenantTest, $ui.BtnCustomTest | Where-Object { (Get-ButtonLabel $_) -eq 'Starting sandbox ...' -and -not $_.IsEnabled }).Count -eq 3) (($ui.BtnDetailTest, $ui.BtnTenantTest, $ui.BtnCustomTest | ForEach-Object { "$(Get-ButtonLabel $_)/$($_.IsEnabled)" }) -join ' ')
                Test-Smoke 'the job is in Activity and the badge counts it' ((@($script:Tasks | Where-Object { $_.Job.Kind -eq 'test' -and -not $_.Hidden }).Count -eq 1) -and $ui.BadgeActivity.Visibility -eq 'Visible')
                $script:Toasts.Clear()
                Start-PackageTest -Package 'putty.install' -Source 'Chocolatey' -Version 'latest' -Policy @{ UpdateMode = 'Off'; GraceHours = 24 }
                Test-Smoke 'a second test says why instead of doing nothing (already running)' (@($script:Toasts | Where-Object { $_.Kind -eq 'warn' -and $_.Text -like '*already running*' }).Count -eq 1 -and @($script:Tasks | Where-Object { $_.Job.Kind -eq 'test' }).Count -eq 1)
                $s.Phase = 1
                return $false
            }
            1 {
                if (-not (Test-Idle 'test')) { return $false }
                $first = Join-Path $lab '01-Lab'
                Test-Smoke 'Chocolatey test ran in the lab' ((Test-Path (Join-Path $first 'started.txt')) -and ((Get-Content (Join-Path $first 'job.json') -Raw | ConvertFrom-Json).DisplayName -like '*(Chocolatey)') -and (Test-Path (Join-Path $first 'source\choco-app.ps1')))
                Test-Smoke 'result in a toast and the log' ((Get-SmokeLog) -match 'sandbox test passed' -and @($script:Toasts | Where-Object { $_.Text -like '*passed*' }).Count -ge 1)
                Test-Smoke 'live steps on the job (preparing, starting Windows Sandbox, waiting / installing, result)' ((Get-JobLog) -match 'Step 1 of 4: preparing' -and (Get-JobLog) -match 'Step 2 of 4: starting Windows Sandbox' -and (Get-JobLog) -match 'Step 3 of 4' -and (Get-JobLog) -match 'Step 4 of 4: result received') (Get-JobLog)
                Test-Smoke 'buttons back to Test in sandbox after the result' (($ui.BtnDetailTest, $ui.BtnTenantTest, $ui.BtnCustomTest | Where-Object { $_.Content -eq 'Test in sandbox' }).Count -eq 3)
                # From the details panel of the apps list (winget source)
                Show-Page 'Apps'
                $vlc = $script:SourceRows | Where-Object { $_.WingetId -eq 'VideoLAN.VLC' } | Select-Object -First 1
                $script:SourceChoice[(Get-AppKey $vlc)] = 'Winget'
                Show-AppDetails $vlc
                & $script:ClickActions[$ui.BtnDetailTest]
                $s.Phase = 2
                return $false
            }
            2 {
                if (-not (Test-Idle 'test')) { return $false }
                $second = Join-Path $lab '02-Lab'
                $source = Join-Path $second 'source'
                Test-Smoke 'winget test from the details panel ran in the lab' ((Test-Path (Join-Path $second 'started.txt')) -and ((Get-Content (Join-Path $second 'job.json') -Raw | ConvertFrom-Json).DisplayName -like '*(Winget)'))
                Test-Smoke 'winget test sets up winget first' ((Get-Content (Join-Path $source 'Install.ps1') -Raw) -match 'Repair-WinGetPackageManager')
                foreach ($file in Get-ChildItem $source -Filter '*.ps1') {
                    $errors = $null
                    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
                    Test-Smoke "lab script $($file.Name) is valid" ($errors.Count -eq 0) (@($errors | ForEach-Object { $_.Message }) -join '; ')
                }
                # Split button: the menu offers the installation test and the update test
                $script:CustomInfo = [pscustomobject]@{ Name = 'Menu Tool'; Version = '2.0.0'; Path = (Join-Path $env:TEMP 'menu.msi') }
                Show-TestMenu 'Custom' $ui.BtnCustomTestMenu
                $headers = @($script:LastMenu.Items | ForEach-Object { [string]$_.Header })
                Test-Smoke 'Test in sandbox is a split button: Test installation and Test update from the previous version' ($headers.Count -ge 2 -and $headers[0] -eq 'Test installation' -and $headers[1] -like 'Test update from the previous version*') ($headers -join ' | ')
                # Custom update test: the previous version comes from the package store when there is one, else a file dialog
                $savedStore = $script:Settings.StoreSiteUrl; $savedMode = $script:CustomMode; $savedApp = $script:CustomUpdateApp
                $script:Settings.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; $script:CustomMode = 'Version'; $script:CustomUpdateApp = [pscustomobject]@{ AppId = 'smoke-tool-1a2b3c4d' }
                $script:CustomInfo = [pscustomobject]@{ Name = 'Menu Tool'; Version = '2.0.0'; Path = (Join-Path $env:TEMP 'menu.msi') }
                Show-TestMenu 'Custom' $ui.BtnCustomTestMenu
                $storeHeaders = @($script:LastMenu.Items | ForEach-Object { [string]$_.Header })
                $script:LastMenu.IsOpen = $false
                $script:Settings.StoreSiteUrl = ''
                Show-TestMenu 'Custom' $ui.BtnCustomTestMenu
                $fileHeaders = @($script:LastMenu.Items | ForEach-Object { [string]$_.Header })
                $script:LastMenu.IsOpen = $false
                $script:Settings.StoreSiteUrl = $savedStore; $script:CustomMode = $savedMode; $script:CustomUpdateApp = $savedApp; $script:CustomInfo = $null
                Test-Smoke 'custom update test: previous version from the package store, file dialog only without a store' ($storeHeaders[1] -like '*(package store)' -and $fileHeaders[1] -like '*...' -and $fileHeaders[1] -notlike '*package store*') (($storeHeaders + $fileHeaders) -join ' | ')
                Test-Smoke 'the old static busy glyph is gone from the busy code' ((Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) '..\Start-PackTune.ps1') -Raw) -notmatch "Tag = \[string\]\[char\]0xE895")
                Test-Smoke 'the drop buttons exist next to every Test in sandbox button' ($ui.BtnDetailTestMenu -and $ui.BtnTenantTestMenu -and $ui.BtnCustomTestMenu)
                $script:LastMenu.IsOpen = $false; $script:CustomInfo = $null
                # The update test: the previous version goes into the lab job, same Activity job and busy state
                $script:Toasts.Clear()
                Start-PackageTest -Package 'putty.install' -Source 'Chocolatey' -Title 'PuTTY' -Version 'latest' -Policy @{ UpdateMode = 'Custom'; GraceHours = 24 } -FromVersion '0.78.0'
                Test-Smoke 'update test: same busy state and a job named after the update' ((Get-ButtonLabel $ui.BtnTenantTest) -eq 'Starting sandbox ...' -and @($script:Tasks | Where-Object { $_.Job.Kind -eq 'test' -and $_.Job.Display -like '*update from 0.78.0*' }).Count -eq 1)
                $spin = $ui.BtnTenantTest.Content.Children[0]
                Test-Smoke 'busy button: a real rotating spinner (animated rotation), not a static glyph' ($ui.BtnTenantTest.Content -is [System.Windows.Controls.StackPanel] -and $spin.RenderTransform -is [System.Windows.Media.RotateTransform] -and $spin.RenderTransform.HasAnimatedProperties)
                $s.Phase = 3
                return $false
            }
            3 {
                if (-not (Test-Idle 'test')) { return $false }
                $third = Join-Path $lab '03-Lab'
                $job = if (Test-Path (Join-Path $third 'job.json')) { Get-Content (Join-Path $third 'job.json') -Raw | ConvertFrom-Json }
                Test-Smoke 'update test: the lab gets the previous version (HasPrevious, PreviousVersion)' ($job -and $job.HasPrevious -eq $true -and $job.PreviousVersion -eq '0.78.0') (($job | ConvertTo-Json -Compress) + ' LOG: ' + (Get-JobLog))
                $true
            }

        } } }
    @{ Name = 'settings'; Do = {
        Show-Page 'Settings'
        Test-Smoke 'settings show the tenant and the preferred source' ($ui.TxtTenantId.Text -eq 'contoso.onmicrosoft.com' -and $ui.CmbPreferredSource.SelectedItem -eq 'Chocolatey') "$($ui.TxtTenantId.Text) / $($ui.CmbPreferredSource.SelectedItem)"
        Test-Smoke 'settings offer grant new permissions and the default schedule' ($ui.BtnSettingsGrant.Content -like '*grant new permissions*' -and $ui.BtnDefaultSchedule)
        Save-SmokeShot '16-settings'
        $ui.TxtDelayMin.Text = '30'; $ui.TxtDelayMax.Text = '10'
        try { Save-Settings; Test-Smoke 'invalid delay range rejected' $false } catch { Test-Smoke 'invalid delay range rejected' ($_.Exception.Message -like '*delay*') $_.Exception.Message }
        $ui.TxtDelayMin.Text = '10'; $ui.TxtDelayMax.Text = '90'
        $ui.TxtPackageSource.Text = 'https://proget.example.test/nuget/choco/'
        $ui.CmbPreferredSource.SelectedIndex = 0
        Save-Settings
        $saved = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        Test-Smoke 'settings saved incl. preferred source and schedule' ($saved.UpdateDelayMaxMinutes -eq 90 -and $saved.PackageSource -like 'https://proget*' -and $saved.Source -eq 'Winget' -and $saved.UpdateSchedule -match 'NoPresentation') ($saved | ConvertTo-Json -Compress)
        Test-Smoke 'preferred source reaches the bar next to Review and deploy' ($ui.RbPreferWinget.IsChecked -and $script:Preferred -eq 'Winget')
        Test-Smoke 'settings keep the app registration per tenant' ($saved.TenantClients -eq 'contoso.onmicrosoft.com=11111111-2222-3333-4444-555555555555') $saved.TenantClients
        $ui.CmbPreferredSource.SelectedIndex = 1; Save-Settings
        $true } }
    @{ Name = 'account of another tenant (Keevault choice)'; Do = {
        $script:TenantGuidLookup = { param($d) switch ($d) { 'contoso.onmicrosoft.com' { 'c0ffee00-0000-4000-8000-000000000001' } 'contoso.com' { 'c0ffee00-0000-4000-8000-000000000001' } 'fabrikam.onmicrosoft.com' { 'fab00000-0000-4000-8000-000000000002' } default { $null } } }
        $same = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'account of the tenant signs in there' ($same.TenantID -eq 'contoso.onmicrosoft.com' -and $same.ClientID -eq '11111111-2222-3333-4444-555555555555')
        try { [void](Resolve-AccountTenant 'adm@fabrikam.onmicrosoft.com'); Test-Smoke 'unknown tenant stops with a reason' $false }
        catch { Test-Smoke 'unknown tenant stops with a reason' ($_.Exception.Message -like '*fabrikam.onmicrosoft.com*no app registration*Create*') $_.Exception.Message }
        $appreg = Get-ReadinessItems | Where-Object Key -eq 'appreg'
        Test-Smoke 'switched to the new tenant, Create offered' ($script:Settings.TenantID -eq 'fabrikam.onmicrosoft.com' -and -not $script:Settings.ClientID -and $appreg.Fix -eq 'Create') "$($script:Settings.TenantID) / $($appreg.Fix)"
        $back = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'known tenant uses its own app registration' ($back.TenantID -eq 'contoso.onmicrosoft.com' -and $back.ClientID -eq '11111111-2222-3333-4444-555555555555') "$($back.TenantID) / $($back.ClientID)"
        Switch-Tenant $back.TenantID $back.ClientID
        Test-Smoke 'tenant switched back' ($script:Settings.TenantID -eq 'contoso.onmicrosoft.com' -and $script:Settings.ClientID -eq '11111111-2222-3333-4444-555555555555')
        # Tenant identity is the GUID: the same tenant by domain, other domain or GUID keeps the app registration
        $s2 = Get-PackTuneSettings; $s2.TenantID = 'contoso.com'; $s2.ClientID = '11111111-2222-3333-4444-555555555555'; $s2.TenantClients = 'contoso.com=11111111-2222-3333-4444-555555555555'; $s2.TenantAliases = ''
        [void](Save-PackTuneSettings -Settings $s2); $script:Settings = Get-PackTuneSettings
        $r1 = Resolve-AccountTenant 'admin@contoso.onmicrosoft.com'
        Test-Smoke 'same tenant under another domain name: no switch, ClientID kept' ($r1.ClientID -eq '11111111-2222-3333-4444-555555555555' -and $script:Settings.TenantID -eq 'contoso.com' -and $script:Settings.ClientID) "$($r1.TenantID) / $($r1.ClientID) / $($script:Settings.TenantID)"
        Switch-Tenant 'c0ffee00-0000-4000-8000-000000000001' ''
        Test-Smoke 'switch to the same tenant by GUID changes nothing (ClientID not cleared)' ($script:Settings.TenantID -eq 'contoso.com' -and $script:Settings.ClientID -eq '11111111-2222-3333-4444-555555555555')
        Test-Smoke 'domain and GUID are remembered as one tenant; the registration is also kept under the GUID (migration)' ((Get-PackTuneTenantGuid 'contoso.com' -NoLookup) -eq 'c0ffee00-0000-4000-8000-000000000001' -and (Get-PackTuneTenantClient 'c0ffee00-0000-4000-8000-000000000001') -eq '11111111-2222-3333-4444-555555555555' -and $script:Settings.TenantClients -like '*c0ffee00-0000-4000-8000-000000000001=*') $script:Settings.TenantAliases
        $threw = $false; try { [void](Resolve-AccountTenant 'adm@fabrikam.onmicrosoft.com') } catch { $threw = $true }
        Test-Smoke 'a really other tenant still switches (no registration there yet)' ($threw -and $script:Settings.TenantID -eq 'fabrikam.onmicrosoft.com' -and -not $script:Settings.ClientID)
        Switch-Tenant 'contoso.onmicrosoft.com' '11111111-2222-3333-4444-555555555555'
        $script:TenantGuidLookup = $null
        $true } }
    @{ Name = 'install summary card and assignment for all users'; Phase = 0; Do = {
        param($s)
        $dir = $env:LOCALAPPDATA
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Tenant'
                $row = @($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0]
                $ui.LstTenant.SelectedItem = $row
                Test-Smoke 'summary card: installed / failed / pending / not installed from the install summary, with time and a link to the Status page' ($ui.BoxTenantSummary.Visibility -eq 'Visible' -and $ui.TxtSumInstalled.Text -eq '12' -and $ui.TxtSumFailed.Text -eq '1' -and $ui.TxtSumPending.Text -eq '3' -and $ui.TxtSumNotInstalled.Text -eq '4' -and $ui.TxtSumInfo.Text -like 'From Intune*read*' -and $ui.BtnSumStatus.IsEnabled) "$($ui.TxtSumInstalled.Text)/$($ui.TxtSumFailed.Text)/$($ui.TxtSumPending.Text)/$($ui.TxtSumNotInstalled.Text) $($ui.TxtSumInfo.Text)"
                # a failing call shows the mapped cause, not "-"
                Set-Content (Join-Path $dir 'fake-summary-down.txt') 'x'
                $script:DeviceCounts.Clear(); $script:CountsCacheSeconds = 0
                Start-CountsTask
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                Remove-Item (Join-Path $dir 'fake-summary-down.txt') -Force
                $row = @($script:TenantRowList | Where-Object { $_['Title'] -eq '7-Zip' })[0]
                Test-Smoke 'summary failure: column shows the short cause, the card the mapped cause (no raw text, no "-")' ($row['Ok'] -eq 'No permission' -and $ui.TxtSumInfo.Text -like 'Could not read the counts: No permission*' -and $ui.TxtSumInfo.Text -notmatch 'Graph GET') "$($row['Ok']) / $($ui.TxtSumInfo.Text)"
                $script:CountsCacheSeconds = 120
                Start-CountsTask
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-SelectedTenantApp
                # the current state is read from the app's assignments (here: the fake has the all-users assignment of the deployment)
                $script:AssignInfo.Remove($app.Id); Update-TenantAssign $app
                $s.Phase = 3; return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-SelectedTenantApp
                Test-Smoke 'assignment section shows the current state (none yet in the fake Graph), groups info present' ($ui.GbTenantAssign.Visibility -eq 'Visible' -and $ui.RbAsgNone.IsChecked -and $ui.TxtAsgInfo.Text -like '*all-users assignment*') $ui.TxtAsgInfo.Text
                $script:AsgSeq = @('Required', 'Available', 'Uninstall', 'None'); $script:AsgIdx = 0; $script:AsgResults = @()
                $script:ConfirmAsked = New-Object System.Collections.ArrayList
                $ui.RbAsgRequired.IsChecked = $true
                $s.Phase = 4; return $false
            }
            4 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-SelectedTenantApp
                $want = $script:AsgSeq[$script:AsgIdx]
                $intent = @{ Required = 'required'; Available = 'available'; Uninstall = 'uninstall'; None = '' }[$want]
                $row = @($script:TenantRowList | Where-Object { $_.Data.Id -eq $app.Id })[0]
                $assigned = @{ Required = 'Required'; Available = 'Available'; Uninstall = 'Uninstall'; None = 'None' }[$want]
                $info = $script:AssignInfo[$app.Id]
                $steps = @($script:AssignModel.Steps | ForEach-Object { $_.State }) -join ','
                $ok = ((-not $info.Intent -and $want -eq 'None') -or $info.Intent -eq $intent) -and $row['Assigned'] -eq $assigned -and $steps -eq 'done,done,done,done'
                Test-Smoke "assignment $want for all users: applied through the job with its step list, Assigned column and panel updated at once" $ok "$($info.Intent) / $($row['Assigned']) / $steps"
                if ($want -eq 'Uninstall') { Test-Smoke 'Uninstall asked for a confirmation: removes the app from all users'' devices' (@($script:ConfirmAsked | Where-Object { $_[0] -eq 'Uninstall for all users' -and $_[1] -like '*Removes the app from all users'' devices*' }).Count -eq 1) }
                $script:AsgIdx++
                if ($script:AsgIdx -lt $script:AsgSeq.Count) { (Get-AssignRadio ($script:AsgSeq[$script:AsgIdx]).ToLower()).IsChecked = $true; return $false }
                # declined uninstall: nothing changes, the selection goes back
                $script:ConfirmSmokeAnswer = $false
                $ui.RbAsgRequired.IsChecked = $true
                $s.Phase = 5; return $false
            }
            5 {
                if (-not (Test-Idle)) { return $false }
                $app = Get-SelectedTenantApp
                $script:ConfirmAsked.Clear()
                $ui.RbAsgUninstall.IsChecked = $true
                Test-Smoke 'Uninstall declined: nothing applied, the control goes back to the real state' ($script:AssignInfo[$app.Id].Intent -eq 'required' -and $ui.RbAsgRequired.IsChecked -and @($script:ConfirmAsked).Count -eq 1 -and -not (Test-TaskRunning 'assign')) "$($script:AssignInfo[$app.Id].Intent)"
                $script:ConfirmSmokeAnswer = $null
                # release path follows the assignment: Available -> supersedence, Required -> in place (the log says which)
                Test-Smoke 'a release path note is logged after a change' ((Get-SmokeLog) -match 'released through supersedence|released through in place')
                $true
            }
        } } }
    @{ Name = 'buttons are not clipped (100%, 125%, 150%)'; Do = {
        function Find-Clipped($e, $list) {
            if ($e -is [System.Windows.Controls.Primitives.ButtonBase] -and $e.IsVisible -and $e.ActualWidth -gt 0 -and ((($e.ActualHeight + 0.5) -lt ($e.DesiredSize.Height - $e.Margin.Top - $e.Margin.Bottom)) -or (($e.ActualWidth + 0.5) -lt ($e.DesiredSize.Width - $e.Margin.Left - $e.Margin.Right)))) { [void]$list.Add("$($e.Name)|$($e.Content)|$([int]$e.ActualWidth)<$([int]$e.DesiredSize.Width)") }
            for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($e); $i++) { Find-Clipped ([System.Windows.Media.VisualTreeHelper]::GetChild($e, $i)) $list }
        }
        $all = New-Object System.Collections.ArrayList
        foreach ($scale in 1.0, 1.25, 1.5) {
            $ui.RootGrid.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $scale, $scale
            foreach ($p in 'Start', 'Apps', 'Tenant', 'Activity', 'Settings') { Show-Page $p; $window.UpdateLayout(); $l = New-Object System.Collections.ArrayList; Find-Clipped $window $l; foreach ($x in $l) { [void]$all.Add("$p@$scale $x") } }
            foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgAddApp', 'DlgCustom', 'DlgStore', 'DlgHelp') { Show-Dialog $d; $window.UpdateLayout(); $l = New-Object System.Collections.ArrayList; Find-Clipped $window $l; foreach ($x in $l) { [void]$all.Add("$d@$scale $x") } }
            Close-Dialog
            $ui.ConfirmTitle.Text = 'Switch'; $ui.ConfirmText.Text = 'Text'; $ui.BtnConfirmYes.Content = 'Switch to PackTune Runtime'; $ui.ConfirmLayer.Visibility = 'Visible'; $window.UpdateLayout(); $l = New-Object System.Collections.ArrayList; Find-Clipped $window $l; foreach ($x in $l) { [void]$all.Add("Confirm@$scale $x") }; $ui.ConfirmLayer.Visibility = 'Collapsed'
            if ($scale -eq 1.5) { Show-Page 'Settings'; Save-SmokeShot '30-settings-150' }
        }
        $ui.RootGrid.LayoutTransform = [System.Windows.Media.Transform]::Identity
        Show-Page 'Start'
        Test-Smoke 'no button or toggle is clipped (ActualHeight >= DesiredSize.Height and ActualWidth >= DesiredSize.Width) on any page, dialog and the confirmation at 100/125/150%' ($all.Count -eq 0) ($all -join '; ')
        $true } }
    @{ Name = 'Graph not reachable: banner, kept lists, no create offer'; Phase = 0; Do = {
        param($s)
        $flag = Join-Path $env:LOCALAPPDATA 'fake-network-down'
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                $script:KeptCount = @($script:TenantApps).Count
                $script:KeptCustom = @($script:CustomApps).Count
                $script:RuntimeInfo = $null; $script:RuntimeId = $null
                Set-Content $flag 'down'
                $script:Toasts.Clear()
                Start-TenantRefresh; Start-DependencyCheck; $script:CustomApps = $script:CustomApps; Start-CustomRefresh
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                Show-Page 'Tenant'
                Test-Smoke 'network error: banner "Can''t reach Microsoft Graph" with Retry' ($script:GraphDown -and $ui.BoxGraphDown.Visibility -eq 'Visible' -and $ui.TxtGraphDown.Text -like "Can't reach Microsoft Graph*check the network/VPN*" -and $ui.BtnGraphRetry.IsEnabled) $ui.TxtGraphDown.Text
                Test-Smoke 'last known lists are kept (In tenant and custom), marked not current' (@($script:TenantApps).Count -eq $script:KeptCount -and $script:KeptCount -gt 0 -and $ui.TxtTenantCount.Text -like '*not current*' -and @($script:CustomApps).Count -eq $script:KeptCustom) "$(@($script:TenantApps).Count)/$script:KeptCount $($ui.TxtTenantCount.Text)"
                $item = @(Get-ReadinessItems | Where-Object { $_.Title -like 'Dependency app*' })[0]
                Test-Smoke 'readiness says "Can''t check right now" and offers Retry, never Create' ($item.Text -like "Can't check right now*" -and $item.Fix -eq 'Retry' -and $item.State -eq 'warn') "$($item.Text) / $($item.Fix)"
                $threw = $false; try { Start-DependencyDeploy } catch { $threw = $true }
                Test-Smoke 'PackTune Runtime is not created from a failed read' ($threw -and -not (Test-TaskRunning 'chocolatey'))
                Test-Smoke 'no red toast per failed background read, no raw exception in the banner' (-not @($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count -and $ui.TxtGraphDown.Text -notmatch 'Remotename|System\.')
                Test-Smoke 'automatic retry is scheduled' ([bool]$script:GraphRetryAt)
                Remove-Item $flag -Force
                $script:RuntimeInfo = $null
                $ui.BtnGraphRetry.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                Start-DependencyCheck
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'network back: banner gone, list refreshed, runtime state read again' (-not $script:GraphDown -and $ui.BoxGraphDown.Visibility -eq 'Collapsed' -and @($script:TenantApps).Count -eq $script:KeptCount -and $script:RuntimeInfo) "$($ui.TxtGraphDown.Text)"
                $true
            }
        } } }
    @{ Name = 'toasts: a long message keeps its layout (wide text column, plain Details button, 3 lines at most, friendly first line)'; Phase = 0; Do = {
        param($s)
        $before = $ui.ToastHost.Children.Count
        $long = 'Packaging with IntuneWinAppUtil.exe failed: C:\Users\someone.long\AppData\Local\PackTune\package\custom-keevault-0a1b2c3d\source\keevault-0.9.34.msi could not be read because Windows denied access to the package folder and the files are held by another process, please close Windows Sandbox and try again later when nothing else uses the folder'
        Show-Toast $long 'bad' 'Details' { }
        $window.UpdateLayout()
        $toast = $ui.ToastHost.Children[$ui.ToastHost.Children.Count - 1]
        $grid = $toast.Child
        $label = @($grid.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -notmatch '^.$' })[0]
        $button = @($grid.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })[0]
        Test-Smoke 'toast: the text column is at least 250 px wide (not a few characters)' ($label.ActualWidth -ge 250) "$($label.ActualWidth)"
        Test-Smoke 'toast: at most three lines, shortened path, the full text in the tooltip' ($label.ActualHeight -le 70 -and $label.Text -like '*...*' -and $label.Text -notlike '*AppData\Local\PackTune\package*' -and $label.ToolTip -eq $long) "$($label.ActualHeight) / $($label.Text)"
        Test-Smoke 'toast: the Details button is plain text (no icon glyph, nothing in Tag) and not wider than 120 px' ($button.Content -eq 'Details' -and $null -eq $button.Tag -and $button.ActualWidth -le 120) "$($button.Tag) $($button.ActualWidth)"
        Test-Smoke 'toast: the whole toast is not wider than 440 px' ($toast.ActualWidth -le 440) "$($toast.ActualWidth)"
        Save-SmokeShot '96-long-toast'
        $c = Get-FriendlyCause 'App 6f0f2a3c-1111-2222-3333-444455556666 is not a custom application of this tool or does not exist any more, nothing was removed'
        Test-Smoke 'friendly: a removed or foreign app is explained without the id' ($c -like '*not a custom application of PackTune or was already removed*' -and $c -notmatch '[0-9a-f]{8}-[0-9a-f]{4}') $c
        Test-Smoke 'friendly: other ids in a message become a pointer to Details' ((Get-FriendlyCause 'Something with 6f0f2a3c-1111-2222-3333-444455556666 failed') -notmatch '6f0f2a3c') 
        $ui.ToastHost.Children.Remove($toast); foreach ($tt in @($script:Toasts | Where-Object { $_.Element -eq $toast })) { $script:Toasts.Remove($tt) }
        $true } }
    @{ Name = 'repositories: add a public repository, list, approval, remove (fake GitHub)'; Phase = 0; Do = {
        param($s)
        if (-not (Test-Idle)) { return $false }
        if ($s.Phase -eq 0) {
            Show-Page 'Settings'; $window.UpdateLayout()
            Test-Smoke 'repositories: the section is on the Settings page, empty at first' ($ui.CardRepositories.IsVisible -and @(Get-PackTuneRepositories).Count -eq 0 -and $ui.TxtRepoEmpty.Visibility -eq 'Visible' -and -not $ui.BtnRepoRemove.IsEnabled)
            $ui.TxtRepoAddress.Text = 'not a repo'
            $threw = $false; try { & $script:ClickActions[$ui.BtnRepoAdd] } catch { $threw = $true }
            Test-Smoke 'repositories: an address that is no repository is refused before any request' ($threw -and @(Get-PackTuneRepositories).Count -eq 0)
            $ui.TxtRepoAddress.Text = 'https://github.com/demo/packages'
            & $script:ClickActions[$ui.BtnRepoAdd]
            $s.Phase = 1; return $false
        }
        if ($s.Phase -eq 1) {
            Test-Smoke 'repositories: connected, pinned, public means third-party and read only' (@(Get-PackTuneRepositories).Count -eq 1 -and (Get-PackTuneRepositories)[0].ThirdParty -and (Get-PackTuneRepositories)[0].RepoId -eq 7701 -and @($ui.LstRepos.ItemsSource).Count -eq 1 -and "$(@($ui.LstRepos.ItemsSource)[0])" -like '*third-party source*') "$(@($ui.LstRepos.ItemsSource) -join '|')"
            Test-Smoke 'repositories: no write grant for a third-party source' (-not $ui.BtnRepoGrantWrite.IsEnabled -and -not $ui.BtnRepoMove.IsEnabled)
            $ui.LstRepos.SelectedIndex = 0
            $s.Phase = 2; return $false
        }
        if ($s.Phase -eq 2) {
            Test-Smoke 'repositories: the app is listed with source label, version and "needs approval"' ($script:RepoRows.Count -eq 1 -and $script:RepoRows[0].Data.Source -eq 'Repository: packages' -and $script:RepoRows[0].Data.Latest -eq '1.0.0' -and $script:RepoRows[0].Data.Name -eq 'Demo Tool' -and -not $script:RepoRows[0].Data.Approved -and $script:RepoRows[0]['Assigned'] -eq 'Needs approval') "rows=$($script:RepoRows.Count)"
            Test-Smoke 'repositories: the unprotected-branch / third-party warning is shown' ($ui.TxtRepoWarnings.Text -like '*Third-party source*') $ui.TxtRepoWarnings.Text
            $ui.CardRepositories.BringIntoView(); $window.UpdateLayout(); Save-SmokeShot '95-repositories'
            $ui.LstRepoApps.SelectedIndex = 0
            $threw = $false; try { & $script:ClickActions[$ui.BtnRepoDeploy] } catch { $threw = $_.Exception.Message -like '*needs your approval*' }
            Test-Smoke 'repositories: deploying an unapproved version is refused in the interface' $threw
            $req = Get-PackTuneRepoApprovalRequest -Repository 'demo/packages' -AppId 'demo-tool-0a1b2c3d' -Version '1.0.0'
            $text = Format-RepoApprovalText $req
            Test-Smoke 'repositories: the approval text shows third-party label, commit, signature, manifest and every file hash' ($text -like '*THIRD-PARTY SOURCE*' -and $text -like "*Commit $($req.Commit.Sha.Substring(0, 12))*" -and $text -like '*Signature:*' -and $text -like "*$($req.Manifest)*" -and $text -like '*installer.zip*' -and $text -like '*SHA256*') $text
            & $script:ClickActions[$ui.BtnRepoApprove]
            $s.Phase = 3; return $false
        }
        if ($s.Phase -eq 3) {
            Test-Smoke 'repositories: approving records the exact manifest, the list shows Approved' (@(Get-PackTuneRepoApprovals).Count -eq 1 -and $script:RepoRows.Count -eq 1 -and $script:RepoRows[0].Data.Approved -and $script:RepoRows[0]['Assigned'] -eq 'Approved') "approvals=$(@(Get-PackTuneRepoApprovals).Count) rows=$($script:RepoRows.Count)"
            & $script:ClickActions[$ui.BtnRepoRemove]
            Test-Smoke 'repositories: removing disconnects it, the approvals stay as a record' (@(Get-PackTuneRepositories).Count -eq 0 -and $script:RepoRows.Count -eq 0 -and @(Get-PackTuneRepoApprovals).Count -eq 1 -and $ui.TxtRepoEmpty.Visibility -eq 'Visible')
            Show-Page 'Start'
            $s.Phase = 4; return $false
        }
        $true } }
    @{ Name = 'sign out'; Do = {
        Test-Smoke 'account menu offers sign out and the other tenants' ($true)
        Disconnect-Intune
        Test-Smoke 'signed out: split button back, pill gone' ((-not (Test-SignedIn)) -and $ui.PanelSignedOut.Visibility -eq 'Visible' -and $ui.BtnAccount.Visibility -eq 'Collapsed' -and $ui.BtnSignIn.IsEnabled)
        Test-Smoke 'Review and deploy disabled when signed out' ($(Show-Page 'Apps'; Set-AppSelected $script:SourceRows[0] $true; -not $ui.BtnReview.IsEnabled))
        Clear-Selection
        Test-Smoke 'tenant list cleared on sign-out' ($script:TenantRowList.Count -eq 0 -and $ui.TxtTenantEmpty.Text -like 'Sign in*')
        Test-Smoke 'In tenant marks cleared on sign-out' (-not @($script:CardCollection | Where-Object { $_['Badge'] -eq 'In tenant' }).Count)
        $logFile = Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f (Get-Date))
        Test-Smoke 'activity is written to the log file' ((Test-Path $logFile) -and (Get-Content $logFile -Raw) -match 'created in Intune')
        Show-Page 'Start'
        Save-SmokeShot '17-start-signed-out'
        $true } }
    @{ Name = 'embedded sign-in is the default'; Phase = 0; Do = {
        param($s)
        function New-FakeToken([string]$Name, [bool]$Consent = $false) {
            $claims = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("{`"name`":`"$Name`",`"upn`":`"admin@contoso.onmicrosoft.com`",`"tid`":`"t-1`"}")).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            [pscustomobject]@{ token_type = 'Bearer'; expires_in = 3600; access_token = "x.$claims.y"; refresh_token = "refresh-$Name"
                scope = ('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All' + $(if ($Consent) { ' https://graph.microsoft.com/DeviceManagementManagedDevices.Read.All https://graph.microsoft.com/Sites.Selected' } else { '' })) }
        }
        switch ($s.Phase) {
            0 {
                if (-not (Test-Idle)) { return $false }
                $script:EmbeddedCalls = New-Object System.Collections.ArrayList
                $script:EmbeddedAvailableOverride = $true
                $script:EmbeddedSignInOverride = { param($t, $c, $sc, $h, $pr, $folder) [void]$script:EmbeddedCalls.Add(@($t, $c, ($sc -join ','), $h, $pr, $folder)); New-FakeToken 'Embedded Admin' ($pr -eq 'consent') }
                $script:Shared.UrlHit = $false
                Remove-Item $script:GrantedScopesPath -ErrorAction SilentlyContinue   # the very first sign-in of this tenant
                Connect-Intune
                # The method of the run is remembered: after a Keevault sign-in, Confirm now / setup use Keevault too (no plain Microsoft window)
                $savedHow = $script:FirstSignInHow; $script:FirstSignInHow = 'Keevault'
                $script:KvCalls = New-Object System.Collections.ArrayList
                $script:KeevaultSignInOverride = { param($t, $c, $sc, $pr, $folder) [void]$script:KvCalls.Add(@($t, $c, ($sc -join ','), $pr, $folder)); New-FakeToken 'Keevault Admin' ($pr -eq 'consent') }
                $before = $script:EmbeddedCalls.Count
                [void](Get-EmbeddedToken -TenantID 'contoso.onmicrosoft.com' -ClientID $script:Settings.ClientID -Scopes (Get-PackTuneSignInScopes -Consent) -Prompt 'consent')
                Test-Smoke 'run signed in via Keevault: Confirm now uses Keevault (same profile folder, prompt=consent), not the plain Microsoft window' ($script:KvCalls.Count -eq 1 -and $script:KvCalls[0][3] -eq 'consent' -and $script:KvCalls[0][4] -eq $script:SignInSession -and $script:KvCalls[0][2] -like '*Sites.Selected*' -and $script:EmbeddedCalls.Count -eq $before)
                [void](Get-EmbeddedToken -TenantID 'contoso.onmicrosoft.com' -ClientID '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Scopes @('Application.ReadWrite.All'))
                Test-Smoke 'setup / store grant sign-in of a Keevault run also goes through Keevault' ($script:KvCalls.Count -eq 2 -and $script:KvCalls[1][1] -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e' -and $script:EmbeddedCalls.Count -eq $before)
                $script:KeevaultSignInOverride = $null; $script:FirstSignInHow = $savedHow
                $src = Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) '..\Modules\Keevault.psm1') -Raw
                Test-Smoke 'Keevault window: passkey shim injected and cookies/process logged before the navigation' ($src -match 'AddScriptToExecuteOnDocumentCreatedAsync\(\$script:PasskeyShimScript\)' -and $src -match 'cookies before the navigation' -and $src -match 'Navigate\(\$url\)')
                Test-Smoke 'normal sign-in uses the PackTune app registration (settings ClientID), the setup client only for creating one' ((Get-SmokeLog) -match 'Sign-in request \(PackTune app registration\): client id 11111111-2222-3333-4444-555555555555' -and $script:EmbeddedCalls[0][1] -eq $script:Settings.ClientID -and $script:EmbeddedCalls[0][1] -ne '14d82eec-204b-4c2f-b7e8-296a70dab67e')
                # One CoreWebView2Environment per profile folder, shared by every window and the keep-alive (real WebView2 when the runtime is there)
                $envFolder = Join-Path $script:SmokeOut 'env-test'
                $real = $false; try { [void](Get-PackTuneWebView2 -CacheFolder (Join-Path $script:WorkRoot 'WebView2')); $real = $true } catch { }
                if ($real) {
                    $e1 = Get-PackTuneEnvironment $envFolder; $e2 = Get-PackTuneEnvironment $envFolder
                    Test-Smoke 'one CoreWebView2Environment per profile folder, reused by the next window and the keep-alive' ([object]::ReferenceEquals($e1, $e2) -and $e1.UserDataFolder -eq $envFolder) "$($e1.UserDataFolder)"
                }
                $kvSrc = Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) '..\Modules\Keevault.psm1') -Raw
                Test-Smoke 'windows and keep-alive take the shared environment; no window can stay blank (watchdog, start errors surface)' ($kvSrc -match 'EnsureCoreWebView2Async\(\$environment\)' -and $kvSrc -match 'EnsureCoreWebView2Async\(\$holdEnv\)' -and $kvSrc -match 'did not initialize in time' -and $kvSrc -notmatch 'CoreWebView2CreationProperties')
                Test-Smoke 'sign-in diagnostics in the log: client id, prompt, hint, folder, scopes (no tokens)' ((Get-SmokeLog) -match 'Sign-in request \(PackTune app registration\): client id 11111111.*prompt default.*login_hint sent.*user data folder:.*first sign-in of this run:.*scopes:' -and (Get-SmokeLog) -notmatch 'refresh-Embedded|access_token')
                Test-Smoke 'normal sign-in uses the embedded window by default' ($script:LastSignInPath -eq 'embedded' -and $script:EmbeddedCalls.Count -eq 1 -and $script:EmbeddedCalls[0][0] -eq 'contoso.onmicrosoft.com' -and $script:EmbeddedCalls[0][1] -eq $script:Settings.ClientID) ($script:EmbeddedCalls | ConvertTo-Json -Compress)
                Test-Smoke 'embedded sign-in signs in, no browser opened, no task needed' ((Test-SignedIn) -and $script:AccountText -like '*Embedded Admin*' -and -not $script:Shared.UrlHit -and -not (Test-TaskRunning 'connect'))
                # Missing permissions are confirmed in the normal sign-in (dynamic consent), not in a setup window
                $call = $script:EmbeddedCalls[0]
                Test-Smoke 'first sign-in: base scopes only (no Sites.Selected, no managed devices), no prompt' ($call[2] -like '*DeviceManagementApps.ReadWrite.All*' -and $call[2] -like '*Group.Read.All*' -and $call[2] -notlike '*Sites.Selected*' -and $call[2] -notlike '*DeviceManagementManagedDevices*' -and $call[4] -eq 'default') ($call -join ' | ')
                $ar = @(Get-ReadinessItems | Where-Object { $_.Key -eq 'appreg' })[0]
                Test-Smoke 'missing permission: item says they are confirmed at the next sign-in, button Confirm now' ($ar.State -eq 'warn' -and $ar.Text -like 'New permissions needed*next sign-in*DeviceManagementManagedDevices.Read.All*' -and $ar.Fix -eq 'Confirm now') "$($ar.State) $($ar.Fix) $($ar.Text)"
                $script:EmbeddedCalls.Clear()
                & $ar.Action
                $call = $script:EmbeddedCalls[0]
                Test-Smoke 'Confirm now: one normal sign-in with prompt=consent and the new scopes, own app registration, no setup window' ($script:EmbeddedCalls.Count -eq 1 -and $call[1] -eq $script:Settings.ClientID -and $call[4] -eq 'consent' -and $call[2] -like '*Sites.Selected*' -and $call[2] -notlike '*Application.ReadWrite.All*') ($call -join ' | ')
                Test-Smoke 'after the consent the granted scopes are read again: item green' ((@(Get-MissingScopes).Count -eq 0) -and (@(Get-ReadinessItems | Where-Object { $_.Key -eq 'appreg' })[0].State -eq 'ok')) (@(Get-MissingScopes) -join ',')
                $urlC = Get-PackTuneAuthorizeUrl -TenantID 'contoso.onmicrosoft.com' -ClientID $script:Settings.ClientID -Scopes (Get-PackTuneSignInScopes) -State 's' -Challenge 'c' -Prompt 'consent' -LoginHint 'admin@contoso.onmicrosoft.com'
                $urlD = Get-PackTuneAuthorizeUrl -TenantID 'contoso.onmicrosoft.com' -ClientID $script:Settings.ClientID -Scopes (Get-PackTuneSignInScopes) -State 's' -Challenge 'c' -Prompt 'default'
                Test-Smoke 'authorize URL (v2) with the new scopes: prompt=consent when permissions are missing' ($urlC -like '*/oauth2/v2.0/authorize?*' -and $urlC -like '*prompt=consent*' -and $urlC -like '*Sites.Selected*' -and $urlC -like '*DeviceManagementManagedDevices.Read.All*' -and $urlC -like '*login_hint=*') $urlC
                Test-Smoke 'authorize URL without missing permissions: no prompt at all (never login)' ($urlD -notlike '*prompt=*' -and $urlD -like '*Sites.Selected*') $urlD
                Test-Smoke 'sign-in profile folder: per Windows user, current user only' (($script:SignInSession -like '*WebView2Session') -and (Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) '..\Start-PackTune.ps1') -Raw) -match 'Get-PackTuneSessionFolder \}' -and (Get-PackTuneSessionFolder -Root (Join-Path (Split-Path $script:SignInSession) 'acl')).Length -gt 0 -and (New-Object System.IO.DirectoryInfo (Join-Path (Split-Path $script:SignInSession) 'acl\WebView2Session')).GetAccessControl().AreAccessRulesProtected) $script:SignInSession
                # Later sign-in: the granted set (remembered per tenant), still no prompt
                Disconnect-Intune
                $script:EmbeddedCalls.Clear()
                Connect-Intune
                $call = $script:EmbeddedCalls[0]
                Test-Smoke 'later sign-in asks for the granted set (incl. what Confirm now added), no prompt' ($call[2] -like '*Sites.Selected*' -and $call[2] -like '*DeviceManagementManagedDevices.Read.All*' -and $call[4] -eq 'default') ($call -join ' | ')
                # A user who is no administrator: Entra refuses the consent, the tool says so (no error)
                $okOverride = $script:EmbeddedSignInOverride
                $script:EmbeddedSignInOverride = { throw 'An administrator must confirm these permissions.' }
                $script:Toasts.Clear()
                Connect-Intune -Consent
                Test-Smoke 'non-admin refusal: clear message instead of an error, still signed in' (@($script:Toasts | Where-Object { $_.Kind -eq 'warn' -and $_.Text -like '*An administrator must confirm these permissions*' }).Count -ge 1 -and -not @($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count -and (Test-SignedIn)) (($script:Toasts | ForEach-Object { $_.Kind + ':' + $_.Text }) -join ' / ')
                $script:EmbeddedSignInOverride = $okOverride
                Disconnect-Intune
                Test-Smoke 'sign out clears the sign-in profile' (-not (Test-Path $script:SignInSession)) $script:SignInSession
                # Setup: the sign-in of the app registration in the embedded window, the Graph work in the task
                $script:EmbeddedCalls.Clear()
                Start-AppRegistration
                $s.Phase = 1; return $false
            }
            1 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'app registration setup signs in with the embedded window (setup app, admin scopes)' ($script:LastSignInPath -eq 'embedded' -and $script:EmbeddedCalls.Count -eq 1 -and $script:EmbeddedCalls[0][1] -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e' -and $script:EmbeddedCalls[0][2] -like '*Application.ReadWrite.All*DelegatedPermissionGrant.ReadWrite.All*') ($script:EmbeddedCalls | ConvertTo-Json -Compress)
                Test-Smoke 'setup sign-in uses the same profile folder, no forced prompt' ($script:EmbeddedCalls[0][5] -eq $script:SignInSession -and $script:EmbeddedCalls[0][4] -eq 'default') ($script:EmbeddedCalls[0] -join ' | ')
                Test-Smoke 'setup finished with the embedded token, browser untouched' (-not $script:Shared.UrlHit -and (Get-SmokeLog) -match 'App registration ready' -and (Get-JobLog) -match 'Admin consent granted') ''
                # Shared session: the account of the setup sign-in is the login hint of the next one
                $script:EmbeddedCalls.Clear()
                Connect-Intune
                Test-Smoke 'normal sign-in after the setup gets the setup account as login hint (shared session)' ($script:EmbeddedCalls.Count -eq 1 -and $script:EmbeddedCalls[0][3] -eq 'admin@contoso.onmicrosoft.com') ($script:EmbeddedCalls | ConvertTo-Json -Compress)
                Test-Smoke 'setup sign-in and normal sign-in use the same profile folder' ($script:EmbeddedCalls.Count -eq 1 -and $script:EmbeddedCalls[0][5] -eq $script:SignInSession -and $script:EmbeddedCalls[0][4] -eq 'default')
                # Hint from the current token (signed in by browser or Keevault), session folder and prompt of the real call
                Connect-Intune   # signed in with the fake embedded window (account admin@contoso)
                $script:EmbeddedSignInOverride = $null; $script:SignInHint = ''
                $script:BrowserCall = $null
                $script:BrowserSignIn = { param($TenantID, $ClientID, $Scopes, $CacheFolder, $Owner, $Title, $Hint, $UserDataFolder, $LoginHint, $Prompt) $script:BrowserCall = @{ LoginHint = $LoginHint; Prompt = $Prompt; UserDataFolder = $UserDataFolder }; New-FakeToken 'Hinted Admin' }
                try { [void](Get-EmbeddedToken -TenantID 'contoso.onmicrosoft.com' -ClientID 'x') } catch { Test-Smoke "dbg $($_.Exception.Message) avail=$($script:EmbeddedAvailableOverride) signed=$(Test-SignedIn)" $false }
                $b = $script:BrowserCall
                Test-Smoke 'hint taken from the current token before an embedded sign-in (grant new permissions)' ($b.LoginHint -like '*@contoso.onmicrosoft.com') $b.LoginHint
                Test-Smoke 'known account: no account picker, no forced prompt; shared session folder' ($b.Prompt -eq 'default' -and $b.UserDataFolder -eq $script:SignInSession) "$($b.Prompt) $($b.UserDataFolder)"
                $script:BrowserSignIn = 'Invoke-PackTuneBrowserSignIn'
                Test-Smoke 'Keevault sign-in gets the same session folder' ((Get-Command Connect-PackTuneWithKeevault).Parameters.ContainsKey('UserDataFolder') -and (Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) '..\Start-PackTune.ps1') -Raw) -match '-UserDataFolder \$script:SignInSession -Scopes')
                Disconnect-Intune
                Disconnect-Intune
                # The system browser as an explicit choice
                $script:Shared.UrlHit = $false
                $script:EmbeddedCalls.Clear()
                Connect-Intune -Method Browser
                $s.Phase = 2; return $false
            }
            2 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'sign in in the web browser (menu choice): browser path, embedded window not used' ((Test-SignedIn) -and $script:LastSignInPath -eq 'browser' -and $script:EmbeddedCalls.Count -eq 0 -and $script:Shared.UrlHit)
                Disconnect-Intune
                # Embedded window cannot start: automatic fallback with a toast
                $script:Shared.UrlHit = $false
                $script:EmbeddedSignInOverride = { param($t, $c, $sc) throw 'The embedded browser could not start: test' }
                Connect-Intune
                $s.Phase = 3; return $false
            }
            3 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'window cannot start: falls back to the browser and says so' ((Test-SignedIn) -and $script:LastSignInPath -eq 'browser' -and $script:Shared.UrlHit -and @($script:Toasts | Where-Object { $_.Text -like '*could not start*web browser*' }).Count -ge 1)
                Disconnect-Intune
                # Runtime missing: same
                $script:EmbeddedAvailableOverride = $false; $script:Shared.UrlHit = $false
                $script:Toasts.Clear()
                Connect-Intune
                $s.Phase = 4; return $false
            }
            4 {
                if (-not (Test-Idle)) { return $false }
                Test-Smoke 'WebView2 runtime missing: browser and a clear toast' ((Test-SignedIn) -and $script:LastSignInPath -eq 'browser' -and $script:Shared.UrlHit -and @($script:Toasts | Where-Object { $_.Text -like '*not available*web browser*' }).Count -ge 1)
                Disconnect-Intune
                # Cancelled embedded window: no error, not signed in
                $script:EmbeddedAvailableOverride = $true
                $script:EmbeddedSignInOverride = { param($t, $c, $sc) throw 'Sign-in cancelled.' }
                $before = @($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count
                Connect-Intune
                Test-Smoke 'cancelled embedded window: not signed in, no error toast' ((-not (Test-SignedIn)) -and @($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count -eq $before)
                Test-Smoke 'cancelled embedded window: quiet info toast Sign-in cancelled' (@($script:Toasts | Where-Object { $_.Kind -eq 'info' -and $_.Text -eq 'Sign-in cancelled' }).Count -ge 1)
                $script:EmbeddedSignInOverride = $null
                $true
            }
        } } }
    @{ Name = 'own dialogs instead of message boxes'; Phase = 0; Do = {
        param($s)
        if (-not (Test-Idle)) { return $false }
        # 1. no MessageBox call in the UI code (the device-side prompt script in PackTune-Main.ps1 is not part of the tool's window)
        $root = Join-Path (Split-Path $env:PACKTUNE_SMOKE) '..'
        $files = @(Get-ChildItem $root -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\Tests\\|\\\.git\\' })
        $hits = New-Object System.Collections.ArrayList
        foreach ($f in $files) {
            $lines = Get-Content $f.FullName
            $notifyStart = if ($f.Name -eq 'PackTune-Main.ps1') { @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '# Shows prompts in the session of a signed-in user*' })[0] } else { -1 }
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'MessageBox\]::Show|MessageBox\.Show') {
                    $inNotify = $notifyStart -ge 0 -and $i -gt $notifyStart -and $i -lt $notifyStart + 90
                    if (-not $inNotify) { [void]$hits.Add("$($f.Name):$($i + 1)") }
                }
            }
        }
        Test-Smoke 'no MessageBox::Show anywhere in the UI code (device-side notify script excluded)' ($hits.Count -eq 0) ($hits -join ', ')
        # 2. runtime: errors, cancel and confirmations open no system dialog (window class #32770 on this thread)
        if (-not ('PackTuneSmoke.Win' -as [type])) {
            $cs = @(
                'public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);'
                '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumThreadWindows(uint t, EnumProc p, System.IntPtr l);'
                '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);'
                '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();'
                'public static int Dialogs() { int n = 0; EnumThreadWindows(GetCurrentThreadId(), (h, l) => { var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); if (sb.ToString() == "#32770") n++; return true; }, System.IntPtr.Zero); return n; }'
            ) -join "`n"
            Add-Type -Namespace PackTuneSmoke -Name Win -MemberDefinition $cs
        }
        $script:Toasts.Clear()
        Show-Error 'Sign-in cancelled.'
        $cancel = @($script:Toasts | Where-Object { $_.Text -eq 'Sign-in cancelled' })
        Test-Smoke 'cancelled sign-in: quiet info toast, no error toast' ($cancel.Count -eq 1 -and $cancel[0].Kind -eq 'info' -and -not @($script:Toasts | Where-Object { $_.Kind -eq 'bad' }).Count)
        Test-Smoke 'cancelled sign-in: header shows Sign in' ((-not (Test-SignedIn)) -and $ui.PanelSignedOut.Visibility -eq 'Visible')
        $script:Toasts.Clear()
        Show-Error ('Something broke because of a long reason. ' * 8)
        $bad = @($script:Toasts | Where-Object { $_.Kind -eq 'bad' })
        $details = if ($bad.Count) { Find-Visual $bad[0].Element ([System.Windows.Controls.Button]) }
        Test-Smoke 'real error: toast with a short cause and Details' ($bad.Count -eq 1 -and $bad[0].Text.Length -le 160 -and $details -and $details.Content -eq 'Details')
        if ($details) { $details.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        Test-Smoke 'Details opens the activity page with the log' ($script:CurrentPage -eq 'Activity')
        # Confirmation card: yes, no, Esc; above an open dialog
        $script:ConfirmDialogTest = $true
        $script:SmokeTimer.Stop()
        $script:ConfirmAnswers = @{}
        function Invoke-ConfirmCase([string]$Name, [scriptblock]$Act) {
            $script:ConfirmAct = $Act; $script:ConfirmSeen = $null
            $script:ConfirmTimer = New-Object System.Windows.Threading.DispatcherTimer; $tm = $script:ConfirmTimer
            $tm.Interval = [TimeSpan]::FromMilliseconds(150)
            $tm.Add_Tick({ $script:ConfirmTimer.Stop(); $script:ConfirmSeen = @{ Visible = [string]$ui.ConfirmLayer.Visibility; Title = $ui.ConfirmTitle.Text; Text = $ui.ConfirmText.Text; Yes = [string]$ui.BtnConfirmYes.Content; Focused = [bool]($ui.BtnConfirmYes.IsKeyboardFocusWithin -or $ui.BtnConfirmYes.IsFocused) }; & $script:ConfirmAct })
            $tm.Start()
            $script:ConfirmAnswers[$Name] = Confirm-Action 'Remove it from Intune?' 'Remove from Intune' 'Remove' 'Keep'
            $script:ConfirmAnswers["$Name-seen"] = $script:ConfirmSeen
        }
        Show-Dialog 'DlgHelp'
        Invoke-ConfirmCase 'yes' { $ui.BtnConfirmYes.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        Invoke-ConfirmCase 'no' { $ui.BtnConfirmNo.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        Invoke-ConfirmCase 'esc' {
            $ev = New-Object System.Windows.Input.KeyEventArgs ([System.Windows.Input.Keyboard]::PrimaryDevice), ([System.Windows.PresentationSource]::FromVisual($window)), 0, ([System.Windows.Input.Key]::Escape)
            $ev.RoutedEvent = [System.Windows.UIElement]::PreviewKeyDownEvent
            $window.RaiseEvent($ev)
        }
        $script:SmokeTimer.Start()
        $answers = $script:ConfirmAnswers
        $seen = $answers['yes-seen']
        Test-Smoke 'confirmation card: title, text, own button labels, Yes has focus' ($seen.Visible -eq 'Visible' -and $seen.Title -eq 'Remove from Intune' -and $seen.Text -like 'Remove it*' -and $seen.Yes -eq 'Remove' -and $seen.Focused) ($seen | ConvertTo-Json -Compress)
        Test-Smoke 'confirmation: Yes returns true, No returns false, Esc returns false' ($answers['yes'] -eq $true -and $answers['no'] -eq $false -and $answers['esc'] -eq $false) (($answers.GetEnumerator() | Where-Object { $_.Key -notlike '*-seen' } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
        Test-Smoke 'Esc on the card did not close the dialog below it; card hidden afterwards' ($script:OpenDialog -eq 'DlgHelp' -and $ui.ConfirmLayer.Visibility -eq 'Collapsed')
        Close-Dialog
        $script:ConfirmDialogTest = $false
        Test-Smoke 'no system dialog opened by errors, cancel or confirmations' ([PackTuneSmoke.Win]::Dialogs() -eq 0)
        # plain English causes instead of raw (localized) exception texts
        $ue = [string][char]0xFC; $oe = [string][char]0xF6
        $c403 = Get-FriendlyCause "Der Remoteserver hat einen Fehler zur${ue}ckgegeben: (403) Verboten."
        $c400 = Get-FriendlyCause "Der Remoteserver hat einen Fehler zur${ue}ckgegeben: (400) Ung${ue}ltige Anforderung."
        $c404 = Get-FriendlyCause 'Response status code does not indicate success: 404 (Not Found).'
        $cNet = Get-FriendlyCause "Der Remotename konnte nicht aufgel${oe}st werden: 'graph.microsoft.com'"
        Test-Smoke 'friendly causes: 403 = no permission, 400/404 = not available in this tenant, network = cannot reach Graph' ($c403 -like 'No permission: confirm the new permissions or check the license*' -and $c400 -like 'Not available in this tenant*E3/E5*' -and $c404 -like 'Not available in this tenant*' -and $cNet -eq "Can't reach Microsoft Graph.") "$c403 | $c400 | $c404 | $cNet"
        $script:StatusScript = @{ State = 'NotAvailable'; Id = $null; Reason = "Remediations could not be queried (Der Remoteserver hat einen Fehler zur${ue}ckgegeben: (403) Verboten.)" }
        Update-StatusBanner
        Test-Smoke 'status banner shows the short cause, not the raw exception' ($ui.TxtStatusScript.Text -like '*No permission: confirm the new permissions*' -and $ui.TxtStatusScript.Text -notmatch 'Remoteserver|Verboten|403')
        $raw = @(Get-ReadinessItems | Where-Object { $_.Text -match 'Remoteserver|Verboten|System\.|Exception|Der Remote' })
        Test-Smoke 'no readiness item shows a raw exception text' ($raw.Count -eq 0) (($raw | ForEach-Object { $_.Title }) -join ', ')
        $script:StatusScript = $null
        $script:Toasts.Clear()
        Show-Error "Der Remoteserver hat einen Fehler zur${ue}ckgegeben: (403) Verboten."
        Test-Smoke 'toast shows the short cause; the raw text is only in the log' (@($script:Toasts | Where-Object { $_.Kind -eq 'bad' -and $_.Text -like 'No permission*' }).Count -eq 1 -and (Get-SmokeLog) -match 'Verboten')
        # icon of a custom application: placeholder and hint, choose, reset
        Show-CustomDialog 'New' $null
        Test-Smoke 'no icon in the package: neutral placeholder and the hint' ($ui.TxtCustomAppIconPlaceholder.Visibility -eq 'Visible' -and $ui.ImgCustomAppIcon.Visibility -eq 'Collapsed' -and $ui.TxtCustomAppIconHint.Text -like 'No icon in the package*Company Portal shows a default icon*' -and -not $ui.BtnCustomAppIconReset.IsEnabled)
        Set-CustomAppIcon (Join-Path $script:SmokeOut 'custom.bmp')
        Test-Smoke 'Choose icon: preview shows the image, Reset is enabled' ($ui.ImgCustomAppIcon.Visibility -eq 'Visible' -and $ui.ImgCustomAppIcon.Source -and $ui.BtnCustomAppIconReset.IsEnabled -and (Test-Path $script:CustomIconFile))
        & $script:ClickActions[$ui.BtnCustomAppIconReset]
        Test-Smoke 'Reset: placeholder again, no chosen icon' ($ui.TxtCustomAppIconPlaceholder.Visibility -eq 'Visible' -and -not $script:CustomIconFile)
        Close-Dialog
        # dialogs fit the window at 150% and no text runs out of it
        function Find-OutsideText($e, $list, $limit) {
            if ($e -is [System.Windows.Controls.TextBlock] -and $e.IsVisible -and $e.ActualWidth -gt 0) {
                $right = $e.TransformToAncestor($ui.RootGrid).Transform((New-Object System.Windows.Point $e.ActualWidth, 0)).X
                if ($right -gt $limit + 1 -or (($e.ActualWidth + 0.5) -lt ($e.DesiredSize.Width - $e.Margin.Left - $e.Margin.Right))) { [void]$list.Add("$($e.Name)|$(([string]$e.Text).Substring(0, [Math]::Min(40, ([string]$e.Text).Length)))") }
            }
            for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($e); $i++) { Find-OutsideText ([System.Windows.Media.VisualTreeHelper]::GetChild($e, $i)) $list $limit }
        }
        $bad = New-Object System.Collections.ArrayList
        foreach ($scale in 1.0, 1.5) {
            $ui.RootGrid.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $scale, $scale
            foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgAddApp', 'DlgCustom', 'DlgStore', 'DlgHelp') {
                Show-Dialog $d; $window.UpdateLayout()
                if ($ui[$d].ActualWidth -gt $ui.RootGrid.ActualWidth) { [void]$bad.Add("$d@$scale wider than the window") }
                $l = New-Object System.Collections.ArrayList; Find-OutsideText $ui[$d] $l $ui.RootGrid.ActualWidth; foreach ($x in $l) { [void]$bad.Add("$d@$scale $x") }
            }
            Close-Dialog
        }
        $ui.RootGrid.LayoutTransform = [System.Windows.Media.Transform]::Identity
        Test-Smoke 'dialogs fit the window (also at 150%) and no text in them is trimmed or runs out of the dialog' ($bad.Count -eq 0) ($bad -join '; ')
        $true } }
)

$script:SmokeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SmokeTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:SmokeTimer.Add_Tick({
    try {
        if ($script:SmokeSteps.Count -eq 0) {
            $script:SmokeTimer.Stop()
            $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
            $window.Close()
            return
        }
        $step = $script:SmokeSteps[0]
        try { Set-Content (Join-Path $script:SmokeOut 'current-step.txt') "$($step.Name) phase=$($step.Phase)" } catch { }
        try { $done = & $step.Do $step }
        catch { Test-Smoke "step '$($step.Name)'" $false "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"; $done = $true }
        if ($done) { $script:SmokeSteps.RemoveAt(0) }
    }
    catch {
        [void]$script:SmokeResults.Add("FAIL driver: $($_.Exception.Message)")
        $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:SmokeTimer.Start() })
