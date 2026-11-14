# Dot-sourced by Start-PackTune.ps1 when PACKTUNE_SMOKE points here (see Tests\Capture-Docs.ps1).
# Fills the fake tenant with a few apps (demo data only) and renders the README screenshots of every page and
# dialog into PACKTUNE_SMOKE_OUT: start, apps, deploy, tenant, schedule, status, import, activity, settings.

$script:DocsOut = $env:PACKTUNE_SMOKE_OUT
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

# The demo environment has no WebView2 runtime: keep its "sign-in window not available" warning out of the pictures
$script:RealShowToast = ${function:Show-Toast}
function Show-Toast([string]$Text, [string]$Kind = 'info') { if ($Kind -eq 'warn' -and $Text -like 'The sign-in window*') { return }; & $script:RealShowToast $Text $Kind }
$script:InsightFake = Get-Content (Join-Path (Split-Path $env:PACKTUNE_SMOKE) 'InsightFake.txt') -Raw
$script:DocsLog = New-Object System.Collections.ArrayList

function Save-DocShot([string]$Name) {
    # No toast over the content
    $ui.ToastHost.Children.Clear(); $script:Toasts.Clear()
    $window.UpdateLayout()
    $w = [int]$window.Content.ActualWidth; $h = [int]$window.Content.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($window.Content)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create((Join-Path $script:DocsOut "$Name.png"))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    [void]$script:DocsLog.Add("shot $Name")
}
function Test-DocsIdle([string]$Kind) { -not @($script:Tasks | Where-Object { if ($Kind) { $_.Job.Kind -eq $Kind } else { $_.Job.Kind -ne 'icons' } }).Count }
function Select-Named([string]$Name) { Set-AppSelected (@($script:SourceRows | Where-Object { $_.Name -eq $Name })[0]) $true }
function Use-Source([string]$Source) { foreach ($e in $script:DeployCombos) { $i = [array]::IndexOf($e.Sources, $Source); if ($i -ge 0) { $e.Combo.SelectedIndex = $i } } }
function Get-TenantRow([string]$Title) { @($script:TenantRowList | Where-Object { $_['Title'] -eq $Title })[0] }

$script:DocSteps = [System.Collections.ArrayList]@(
    @{ Do = {
        param($s)
        $script:EmbeddedAvailableOverride = $false; $script:SandboxOverride = @{ Present = $true; Studio = $true }; Update-SandboxState
        $cfg = Get-PackTuneSettings; $cfg.ClientID = ''; [void](Save-PackTuneSettings -Settings $cfg); $script:Settings = Get-PackTuneSettings
        $script:SignInTest = @{ Authority = $env:PACKTUNE_SMOKE_AUTHORITY; GraphUrl = $env:PACKTUNE_SMOKE_AUTHORITY
            UrlHandler = 'param($Url) $global:DocsClient = New-Object System.Net.WebClient; [void]$global:DocsClient.DownloadStringTaskAsync([uri]$Url)' }
        Show-Page 'Start'; Start-CatalogPrefetch
        & $script:ClickActions[$ui.BtnSetupAll]
        $true } }
    @{ Do = { param($s) if ($script:SetupRunning -or -not (Test-DocsIdle)) { return $false }; Start-StatusScriptSetup; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle)) { return $false }; Show-Page 'Start'; Save-DocShot 'start'; $true } }
    @{ Do = { param($s) Show-Page 'Apps'; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle 'meta')) { return $false }; Update-CatalogRows; $ui.TxtFilter.Text = ''; foreach ($n in '7-Zip', 'Notepad++', 'VLC media player') { Select-Named $n }; $true } }
    @{ Do = { param($s) $s.N++; if ($s.N -lt 5 -or ($s.N -lt 20 -and -not (Test-DocsIdle 'icons'))) { return $false }; Show-AppDetails (@($script:SourceRows | Where-Object { $_.Name -eq '7-Zip' })[0]); $ui.AppsScroll.ScrollToVerticalOffset(235); $window.UpdateLayout(); Save-DocShot 'apps'; $script:DetailRow = $null; $ui.PanelDetails.Visibility = 'Collapsed'; Update-SelectionBar; $true } }
    @{ Do = { param($s) if (-not $s.Shown) { Show-DeployDialog; Use-Source 'Chocolatey'; $s.Shown = $true }; $s.N++; if ($s.N -lt 6 -or -not (Test-DocsIdle 'icons')) { return $false }; Save-DocShot 'deploy'; Close-Dialog; $true } }
    @{ Do = { param($s)
        Show-DeployDialog
        # the recommended source per app stays; Chocolatey for the app that has no recommendation
        Start-Deploy
        foreach ($n in 'PuTTY', 'Google Chrome', 'LibreOffice') { Select-Named $n }
        $s.Phase = 'second'; $true } }
    @{ Do = { param($s) Show-DeployDialog; Use-Source 'Chocolatey'; $ui.CmbDeployAssign.SelectedIndex = 0; Start-Deploy; $true } }
    @{ Do = { param($s)
        # while the first jobs run: the activity page with progress
        $running = @($script:JobRows | Where-Object { $_['Status'] -eq 'Running' })
        $waiting = @($script:JobRows | Where-Object { $_['Status'] -eq 'Waiting' })
        if (-not $running.Count -or -not $waiting.Count) { $s.N++; if ($s.N -lt 40) { return $false } }
        Show-Page 'Activity'; $script:JobRows[0].Data.LogOpen = $false; Save-DocShot 'activity'; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle)) { return $false }; Show-Page 'Tenant'; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle)) { return $false }; Update-TenantRows -Force; $ui.LstTenant.SelectedItem = Get-TenantRow '7-Zip'; Save-DocShot 'tenant'
        & $script:ClickActions[$ui.BtnTenantSchedule]; Save-DocShot 'schedule'; Close-Dialog
        Show-AppStatus (Get-TenantRow '7-Zip').Data; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle)) { return $false }; Save-DocShot 'status'
        Show-Page 'Tenant'; $script:ImportApps = $null; Show-ImportDialog; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle)) { return $false }; Update-ImportRows; Save-DocShot 'import'; Close-Dialog
        # custom applications: demo data (an MSI app with two versions and a captured MSIX app), the package store dialog
        $demo = Join-Path $env:LOCALAPPDATA 'fake-intune.json'
        $apps = @(Get-Content $demo -Raw | ConvertFrom-Json | ForEach-Object { $_ })
        $assign = @([pscustomobject]@{ Type = '#microsoft.graph.allLicensedUsersAssignmentTarget'; Intent = 'available' })
        $apps += [pscustomobject]@{ id = 'demo-msi-2'; displayName = 'Contoso Inventory Agent'; publisher = 'Contoso Ltd'; description = 'x'; createdDateTime = (Get-Date).ToString('o'); notes = 'PoweredByPackTune;custom=msi;app=contoso-inventory-agent-1a2b3c4d;ver=2.4.0;product={7D3C9B50-1111-4C2E-9A10-000000000240};upgrade={7D3C9B50-0000-4C2E-9A10-0000000000AA};manifest=3f9a1c0be27d4c11'; displayVersion = '2.4.0'; assignment = 'available'; assignments = $assign; dependencies = @(); supersedence = @([pscustomobject]@{ targetId = 'demo-msi-1'; supersedenceType = 'update' }) }
        $apps += [pscustomobject]@{ id = 'demo-msi-1'; displayName = 'Contoso Inventory Agent'; publisher = 'Contoso Ltd'; description = 'x'; createdDateTime = (Get-Date).AddDays(-30).ToString('o'); notes = 'PoweredByPackTune;custom=msi;app=contoso-inventory-agent-1a2b3c4d;ver=2.3.0;product={7D3C9B50-1111-4C2E-9A10-000000000230};upgrade={7D3C9B50-0000-4C2E-9A10-0000000000AA};manifest=aa00bb11cc22dd33'; displayVersion = '2.3.0'; assignment = 'available'; assignments = $assign; dependencies = @(); supersedence = @() }
        $apps += [pscustomobject]@{ id = 'demo-msix-1'; displayName = 'Fabrikam Label Printer'; publisher = 'Fabrikam'; description = 'x'; createdDateTime = (Get-Date).AddDays(-3).ToString('o'); notes = 'PoweredByPackTune;custom=msix;app=fabrikam-label-printer-5e6f7a8b;ver=1.2.0.0;identity=PackTune.FabrikamLabelPrinter;thumb=' + ('C3' * 20) + ';manifest=9d8c7b6a5f4e3d2c'; displayVersion = '1.2.0.0'; assignment = 'required'; assignments = @([pscustomobject]@{ Type = '#microsoft.graph.allDevicesAssignmentTarget'; Intent = 'required' }); dependencies = @(); supersedence = @() }
        ConvertTo-Json -InputObject @($apps) -Depth 6 | Set-Content $demo
        $script:CustomApps = $null; Show-Page 'Custom'; $true } }
    @{ Do = { param($s) if (-not (Test-DocsIdle 'customlist')) { return $false }; $ui.LstCustom.SelectedItem = @($script:CustomRows | Where-Object { $_['Title'] -eq 'Fabrikam Label Printer' })[0]; Save-DocShot 'custom'
        $demoFolder = Join-Path $env:LOCALAPPDATA 'Fabrikam Label Printer 1.3'; New-Item -ItemType Directory -Path $demoFolder -Force | Out-Null; 'x' | Set-Content (Join-Path $demoFolder 'setup.exe')
        & $script:ClickActions[$ui.BtnCustomNew]; $ui.RbCustomOther.IsChecked = $true; Set-OtherFolder $demoFolder; $ui.TxtOtherFolder.Text = 'C:\Installers\Fabrikam Label Printer 1.3'; $ui.TxtOtherArgs.Text = '/VERYSILENT /NORESTART'; $ui.TxtOtherPublisher.Text = 'Fabrikam'; $ui.TxtOtherName.Text = 'Fabrikam Label Printer'
        Save-DocShot 'custom-dialog'; Close-Dialog
        $cfg2 = Get-PackTuneSettings; $cfg2.StoreSiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; [void](Save-PackTuneSettings -Settings $cfg2); $script:Settings = Get-PackTuneSettings
        $script:StoreState = [pscustomobject]@{ State = 'Ready'; Message = 'The package store ''PackTune Packages'' on PackTune is ready.' }
        Show-StoreDialog; Save-DocShot 'package-store'; Close-Dialog
        Show-Page 'Settings'; Save-DocShot 'settings'; $true } }
)

$script:DocsTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DocsTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$script:DocsTimer.Add_Tick({
    try {
        if ($script:DocSteps.Count -eq 0) {
            $script:DocsTimer.Stop()
            $script:DocsLog | Set-Content (Join-Path $script:DocsOut 'results.txt')
            $window.Close()
            return
        }
        $step = $script:DocSteps[0]
        if (-not $step.N) { $step.N = 0 }
        if (& $step.Do $step) { $script:DocSteps.RemoveAt(0) }
    }
    catch {
        [void]$script:DocsLog.Add("FAIL docs: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)")
        $script:DocsLog | Set-Content (Join-Path $script:DocsOut 'results.txt')
        $script:DocsTimer.Stop()
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:DocsTimer.Start() })
