<#
    The tray agent "PackTune Updates": one per user session, started at logon by a task of the Users group that the PackTune Runtime
    registers. A tray icon with three states (up to date / updates available / installing) and a popup in the PackTune look that lists
    the pending updates of apps in the mode "Ask the user, then install": per app Install now and Postpone 2 days, and Install all now.
    The popup opens by itself when a NEW update becomes pending.

    Read only from the protected per-app folders (%ProgramFiles%\PackTune\<Chocolatey|Winget>\<package>: config.json, state.json,
    last-result.json, icon.png). The agent runs as the user and never elevates. Its two actions are the existing, validated ones:
    "Install now" starts the SYSTEM task "Update <package> now" (the package must be installed with a policy in the protected folder
    and have a pending update), "Postpone" only writes a snooze file in the profile of the user. No network. Plain ASCII, Windows
    PowerShell 5.1. The notify.ps1 prompts stay as the fallback when the agent is not running (the agent owns the mutex
    Local\PackTuneTrayAgent). Loaded by PackTune-Main.ps1.
#>

function Get-UpdateTrayLibrary {
    $Library = @'
# ---------------------------------------------------------------- tray agent library
$TrayFolder = Join-Path $SnoozeFolder "tray"
$TrayStateFile = Join-Path $TrayFolder "state.json"
$TrayPostponeDays = 2
$TrayFinishedMinutes = 30

function Test-TrayTaskRunning([string]$TaskPath, [string]$TaskName) {
    # Replaceable in tests. Users may read the tasks of PackTune.
    try { return ([string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop).State -eq "Running") } catch { return $false }
}

function Read-TrayJson([string]$Path) {
    try { if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } } catch { }
    return $null
}

function Get-TrayApps {
    # Every app of PackTune on this device from its protected folder. Pending = a new version waits (state.json of the mode "Ask the user");
    # Installing = the task of the update runs; Finished = the last attempt installed an update within the last 30 minutes.
    param([datetime]$Now = (Get-Date))
    foreach ($Source in "Chocolatey", "Winget") {
        $Base = Join-Path $ProgramRoot $Source
        if (-not (Test-Path -LiteralPath $Base)) { continue }
        foreach ($Folder in @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue)) {
            $Package = $Folder.Name
            if ($Package -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { continue }
            $Config = Read-TrayJson (Join-Path $Folder.FullName "config.json")
            if (-not $Config) { continue }
            $ConfigId = if ($Config.TaskId) { [string]$Config.TaskId } else { [string]$Config.Package }
            if ($ConfigId -cne $Package -or [string]$Config.TaskPath -cne "\PackTune\$Source\") { continue }
            $State = Read-TrayJson (Join-Path $Folder.FullName "state.json")
            $Result = Read-TrayJson (Join-Path $Folder.FullName "last-result.json")
            $Deadline = $null
            if ($State -and $State.Deadline) { try { $Deadline = [datetime]$State.Deadline } catch { } }
            $Name = if ($State -and $State.DisplayName) { [string]$State.DisplayName } elseif ($Config.DisplayName) { [string]$Config.DisplayName } else { $Package }
            $Name = [regex]::Replace($Name, '[\x00-\x1F]', "")
            $Installing = (Test-TrayTaskRunning "\PackTune\$Source\" "Update $Package now") -or (Test-TrayTaskRunning "\PackTune\$Source\" "Update $Package on startup")
            $Finished = $false; $FinishedVersion = ""
            if ($Result -and [string]$Result.action -in "upgrade", "install" -and [string]$Result.status -eq "ok") {
                try { if (([datetime]$Result.lastAttempt) -gt $Now.AddMinutes(-$TrayFinishedMinutes)) { $Finished = $true; $FinishedVersion = [string]$Result.installedVersion } } catch { }
            }
            $Icon = Join-Path $Folder.FullName "icon.png"
            [pscustomobject]@{
                Source = $Source; Package = $Package; Name = $Name; Mode = [string]$Config.Mode; TaskPath = "\PackTune\$Source\"
                Pending = [bool]($State -and $Deadline); Installed = $(if ($State) { [string]$State.Installed } else { "" }); Target = $(if ($State) { [string]$State.Target } else { "" })
                Deadline = $Deadline; Installing = $Installing; Finished = $Finished; FinishedVersion = $FinishedVersion
                Icon = $(if (Test-Path -LiteralPath $Icon) { $Icon } else { "" })
            }
        }
    }
}

function Get-TrayState {
    $State = Read-TrayJson $TrayStateFile
    $Seen = @(); $Postponed = @{}
    if ($State) {
        $Seen = @($State.Seen | Where-Object { $_ })
        foreach ($P in $State.Postponed.PSObject.Properties) { try { $Postponed[$P.Name] = [datetime]$P.Value } catch { } }
    }
    return @{ Seen = $Seen; Postponed = $Postponed }
}

function Save-TrayState($State) {
    try {
        New-Item -Path $TrayFolder -ItemType Directory -Force | Out-Null
        $Out = @{ Seen = @($State.Seen | Select-Object -Last 200); Postponed = @{} }
        foreach ($K in $State.Postponed.Keys) { $Out.Postponed[$K] = $State.Postponed[$K].ToString("o") }
        Set-Content -LiteralPath $TrayStateFile -Value ($Out | ConvertTo-Json -Depth 4) -Encoding ASCII
    }
    catch { }
}

function Get-TrayKey($App) { return ("{0}|{1}|{2}" -f $App.Source, $App.Package, $App.Target) }

function Get-TrayStatus {
    # installing > updates (something waits) > uptodate
    param($Apps)
    if (@($Apps | Where-Object { $_.Installing }).Count) { return "installing" }
    if (@($Apps | Where-Object { $_.Pending }).Count) { return "updates" }
    return "uptodate"
}

function Get-TrayPostponeUntil {
    # Postpone 2 days, but never beyond one hour before the automatic installation (the deadline is the system's, the user cannot move it);
    # $null when there is nothing left to postpone
    param($App, [datetime]$Now = (Get-Date))
    if (-not $App.Deadline) { return $null }
    $Until = $Now.AddDays($TrayPostponeDays)
    $Latest = $App.Deadline.AddHours(-1)
    if ($Latest -lt $Until) { $Until = $Latest }
    if ($Until -le $Now.AddMinutes(1)) { return $null }
    return $Until
}

function Get-TrayItems {
    # What the popup lists, in the order of the deadline: pending updates (with the text under the name), installs that run, installs that finished
    param($Apps, $State, [datetime]$Now = (Get-Date))
    $Items = New-Object System.Collections.ArrayList
    foreach ($A in @($Apps | Where-Object { $_.Pending -and -not $_.Installing } | Sort-Object Deadline)) {
        $Until = if ($State.Postponed.ContainsKey((Get-TrayKey $A))) { $State.Postponed[(Get-TrayKey $A)] } else { $null }
        $Postponed = [bool]($Until -and $Until -gt $Now)
        $Text = "Installs automatically on $($A.Deadline.ToString('g'))"
        $CanPostpone = [bool](Get-TrayPostponeUntil $A $Now) -and -not $Postponed
        [void]$Items.Add([pscustomobject]@{ Kind = "pending"; App = $A; Text = $Text; Postponed = $Postponed; CanPostpone = $CanPostpone; Late = [bool]($A.Deadline -le $Now) })
    }
    foreach ($A in @($Apps | Where-Object { $_.Installing })) { [void]$Items.Add([pscustomobject]@{ Kind = "installing"; App = $A; Text = "Installing ..."; Postponed = $false; CanPostpone = $false; Late = $false }) }
    foreach ($A in @($Apps | Where-Object { $_.Finished -and -not $_.Installing -and -not $_.Pending })) { [void]$Items.Add([pscustomobject]@{ Kind = "finished"; App = $A; Text = "Updated$(if ($A.FinishedVersion) { " to $($A.FinishedVersion)" })"; Postponed = $false; CanPostpone = $false; Late = $false }) }
    return @($Items)
}

function Get-TrayPopupDecision {
    # Does the popup open by itself: only when an update is NEW (this app and this target version were not announced before), not
    # postponed and its deadline is not over. Returns Open and the keys to remember as announced.
    param($Apps, $State, [datetime]$Now = (Get-Date))
    $NewKeys = New-Object System.Collections.ArrayList
    foreach ($A in @($Apps | Where-Object { $_.Pending })) {
        $Key = Get-TrayKey $A
        if ($State.Seen -contains $Key) { continue }
        [void]$NewKeys.Add($Key)
    }
    $Open = $false
    foreach ($A in @($Apps | Where-Object { $_.Pending })) {
        $Key = Get-TrayKey $A
        if ($NewKeys -notcontains $Key) { continue }
        $Until = if ($State.Postponed.ContainsKey($Key)) { $State.Postponed[$Key] } else { $null }
        if ($Until -and $Until -gt $Now) { continue }
        if ($A.Deadline -and $A.Deadline -le $Now) { continue }
        $Open = $true
    }
    return @{ Open = $Open; NewKeys = @($NewKeys) }
}

function Resolve-TrayAction {
    # The only way a click turns into an action: source and package are checked again against the protected folder (config.json of that
    # source and package, and a pending update in state.json); everything else gives $null. Verb: install | postpone.
    param([string]$Verb, [string]$Source, [string]$Package)
    if ($Verb -notin "install", "postpone") { return $null }
    if ($Source -notin "Chocolatey", "Winget") { return $null }
    if ($Package -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { return $null }
    $Root = Join-Path (Join-Path $ProgramRoot $Source) $Package
    $Config = Read-TrayJson (Join-Path $Root "config.json")
    if (-not $Config) { return $null }
    $ConfigId = if ($Config.TaskId) { [string]$Config.TaskId } else { [string]$Config.Package }
    if ($ConfigId -cne $Package -or [string]$Config.TaskPath -cne "\PackTune\$Source\") { return $null }
    if (-not (Read-TrayJson (Join-Path $Root "state.json"))) { return $null }
    $Name = if ($Config.DisplayName) { [string]$Config.DisplayName } else { $Package }
    return [pscustomobject]@{ Verb = $Verb; Package = $Package; TaskPath = "\PackTune\$Source\"; DisplayName = $Name; TokenFile = $null; Source = $Source }
}

function Invoke-TrayAction {
    # Install now: the SYSTEM task through Invoke-ToastAction (the same code as the toast button). Postpone: snooze file of the user.
    # Returns a short text for the popup.
    param([string]$Verb, [string]$Source, [string]$Package, [datetime]$Now = (Get-Date))
    $Action = Resolve-TrayAction $Verb $Source $Package
    if (-not $Action) { return "" }
    if ($Verb -eq "install") { return (Invoke-ToastAction $Action) }
    $State = Get-TrayState
    $Pending = @(Get-TrayApps $Now | Where-Object { $_.Source -eq $Source -and $_.Package -eq $Package -and $_.Pending })
    if ($Pending.Count -eq 0) { return "" }
    $Until = Get-TrayPostponeUntil $Pending[0] $Now
    if (-not $Until) { return "This update cannot be postponed any more." }
    $State.Postponed[(Get-TrayKey $Pending[0])] = $Until
    Save-TrayState $State
    return "Installs automatically on $($Pending[0].Deadline.ToString('g'))"
}

function Invoke-TrayInstallAll {
    param([datetime]$Now = (Get-Date))
    foreach ($A in @(Get-TrayApps $Now | Where-Object { $_.Pending -and -not $_.Installing })) { [void](Invoke-TrayAction "install" $A.Source $A.Package $Now) }
}
'@
    return $Library
}#Library of the tray agent

function Get-UpdateTrayScript {
    # tray.ps1: the library of the toasts (for the install action and the package checks), the library of the agent, and the interface
    $Script = @'
# PackTune Updates: tray icon and popup for the signed-in user. Started at logon by the task "PackTune Updates tray" (Users group,
# hidden, no admin rights). One instance per session (mutex). Reads the protected folders of the apps, starts only the validated actions.
$SnoozeFolder = Join-Path $env:LOCALAPPDATA "PackTune\Updates"
__TOASTLIBRARY__
__TRAYLIBRARY__

# ---------------------------------------------------------------- interface
$Created = $false
$Mutex = New-Object System.Threading.Mutex($false, $TrayMutexName, [ref]$Created)
if (-not $Created) { exit 0 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

function New-TrayIcon([string]$Status) {
    # A small round icon in the blue of PackTune; updates: an orange dot, installing: a green one
    $Bitmap = New-Object System.Drawing.Bitmap 32, 32
    $G = [System.Drawing.Graphics]::FromImage($Bitmap)
    $G.SmoothingMode = "AntiAlias"
    $G.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#005FB8"))), 2, 2, 28, 28)
    $White = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 3
    $G.DrawLine($White, 16, 8, 16, 21); $G.DrawLine($White, 10, 16, 16, 22); $G.DrawLine($White, 22, 16, 16, 22)
    if ($Status -ne "uptodate") {
        $Dot = if ($Status -eq "installing") { "#16803C" } else { "#F7630C" }
        $G.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)), 17, 0, 15, 15)
        $G.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Dot))), 19, 2, 11, 11)
    }
    $G.Dispose()
    $Icon = [System.Drawing.Icon]::FromHandle($Bitmap.GetHicon())
    return $Icon
}

$PopupXaml = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="PackTune Updates" Width="400" SizeToContent="Height" MaxHeight="620" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True" Background="White" FontFamily="Segoe UI" FontSize="13"><Border BorderBrush="#C8C8C8" BorderThickness="1"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Border Background="#005FB8" Padding="16,12"><TextBlock x:Name="Head" Foreground="White" FontSize="15" FontWeight="SemiBold" Text="PackTune Updates"/></Border><ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" MaxHeight="470"><StackPanel x:Name="List" Margin="0,4"/></ScrollViewer><Border Grid.Row="2" BorderBrush="#E5E5E5" BorderThickness="0,1,0,0" Padding="16,10"><Grid><TextBlock x:Name="Empty" Foreground="#5F5F5F" VerticalAlignment="Center" Text="Everything is up to date."/><Button x:Name="InstallAll" HorizontalAlignment="Right" Padding="14,6" Content="Install all now" Foreground="White" Background="#005FB8" BorderThickness="0"/></Grid></Border></Grid></Border></Window>'
$script:Popup = [System.Windows.Markup.XamlReader]::Parse($PopupXaml)
$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Visible = $true
$script:LastStatus = ""

function New-TrayBrush([string]$Hex) { return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex) }

function Update-Popup {
    $Apps = @(Get-TrayApps)
    $State = Get-TrayState
    $Items = @(Get-TrayItems $Apps $State)
    $script:Popup.FindName("List").Children.Clear()
    foreach ($Item in $Items) {
        $A = $Item.App
        $Row = New-Object System.Windows.Controls.Grid
        $Row.Margin = New-Object System.Windows.Thickness 16, 8, 16, 8
        foreach ($W in "Auto", "*") { $C = New-Object System.Windows.Controls.ColumnDefinition; $C.Width = [System.Windows.GridLength]::Auto; if ($W -eq "*") { $C.Width = New-Object System.Windows.GridLength 1, "Star" }; $Row.ColumnDefinitions.Add($C) }
        $Tile = New-Object System.Windows.Controls.Border
        $Tile.Width = 40; $Tile.Height = 40; $Tile.CornerRadius = New-Object System.Windows.CornerRadius 8; $Tile.Background = New-TrayBrush "#E8F1FB"; $Tile.Margin = New-Object System.Windows.Thickness 0, 0, 12, 0; $Tile.VerticalAlignment = "Top"
        $Mono = New-Object System.Windows.Controls.TextBlock; $Mono.Text = $A.Name.Substring(0, 1).ToUpper(); $Mono.FontWeight = "Bold"; $Mono.FontSize = 16; $Mono.Foreground = New-TrayBrush "#003E92"; $Mono.HorizontalAlignment = "Center"; $Mono.VerticalAlignment = "Center"
        if ($A.Icon) {
            try {
                $Bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $Bitmap.BeginInit(); $Bitmap.UriSource = New-Object Uri $A.Icon; $Bitmap.CacheOption = "OnLoad"; $Bitmap.DecodePixelWidth = 64; $Bitmap.EndInit(); $Bitmap.Freeze()
                $Image = New-Object System.Windows.Controls.Image; $Image.Source = $Bitmap; $Image.Margin = New-Object System.Windows.Thickness 5
                $Tile.Child = $Image
            }
            catch { $Tile.Child = $Mono }
        }
        else { $Tile.Child = $Mono }
        [System.Windows.Controls.Grid]::SetColumn($Tile, 0); [void]$Row.Children.Add($Tile)
        $Stack = New-Object System.Windows.Controls.StackPanel
        $Title = New-Object System.Windows.Controls.TextBlock; $Title.Text = $A.Name; $Title.FontWeight = "SemiBold"; $Title.TextTrimming = "CharacterEllipsis"; [void]$Stack.Children.Add($Title)
        $Versions = if ($Item.Kind -eq "pending" -and $A.Installed -and $A.Target) { "$($A.Installed) -> $($A.Target)" } elseif ($A.Target) { $A.Target } else { "" }
        if ($Versions) { $V = New-Object System.Windows.Controls.TextBlock; $V.Text = $Versions; $V.Foreground = New-TrayBrush "#3B3B3B"; [void]$Stack.Children.Add($V) }
        $Sub = New-Object System.Windows.Controls.TextBlock; $Sub.Text = $(if ($Item.Postponed) { "Postponed. " + $Item.Text } else { $Item.Text }); $Sub.Foreground = New-TrayBrush "#5F5F5F"; $Sub.FontSize = 12; $Sub.TextWrapping = "Wrap"; [void]$Stack.Children.Add($Sub)
        if ($Item.Kind -eq "installing") { $Bar = New-Object System.Windows.Controls.ProgressBar; $Bar.IsIndeterminate = $true; $Bar.Height = 4; $Bar.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0; [void]$Stack.Children.Add($Bar) }
        if ($Item.Kind -eq "pending") {
            $Buttons = New-Object System.Windows.Controls.StackPanel; $Buttons.Orientation = "Horizontal"; $Buttons.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
            $Install = New-Object System.Windows.Controls.Button; $Install.Content = "Install now"; $Install.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5; $Install.Foreground = [System.Windows.Media.Brushes]::White; $Install.Background = New-TrayBrush "#005FB8"; $Install.BorderThickness = New-Object System.Windows.Thickness 0
            $Install.Tag = "install|$($A.Source)|$($A.Package)"
            $Install.Add_Click({ param($S, $E) $P = ([string]$S.Tag).Split("|"); [void](Invoke-TrayAction $P[0] $P[1] $P[2]); Start-Sleep -Milliseconds 800; Update-Tray $true })
            [void]$Buttons.Children.Add($Install)
            if ($Item.CanPostpone) {
                $Later = New-Object System.Windows.Controls.Button; $Later.Content = "Postpone 2 days"; $Later.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5; $Later.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
                $Later.Tag = "postpone|$($A.Source)|$($A.Package)"
                $Later.Add_Click({ param($S, $E) $P = ([string]$S.Tag).Split("|"); [void](Invoke-TrayAction $P[0] $P[1] $P[2]); Update-Tray $true })
                [void]$Buttons.Children.Add($Later)
            }
            [void]$Stack.Children.Add($Buttons)
        }
        [System.Windows.Controls.Grid]::SetColumn($Stack, 1); [void]$Row.Children.Add($Stack)
        [void]$script:Popup.FindName("List").Children.Add($Row)
    }
    $Pending = @($Items | Where-Object { $_.Kind -eq "pending" })
    $script:Popup.FindName("Empty").Visibility = $(if ($Items.Count) { "Collapsed" } else { "Visible" })
    $script:Popup.FindName("InstallAll").Visibility = $(if ($Pending.Count -gt 1) { "Visible" } else { "Collapsed" })
    $script:Popup.FindName("Head").Text = $(if ($Pending.Count) { "$($Pending.Count) update$(if ($Pending.Count -ne 1) { 's' }) available" } else { "PackTune Updates" })
}

function Show-Popup {
    Update-Popup
    $Area = [System.Windows.SystemParameters]::WorkArea
    $script:Popup.Left = $Area.Right - $script:Popup.Width - 12
    $script:Popup.Top = $Area.Bottom - 12 - 200
    $script:Popup.Show()
    $script:Popup.UpdateLayout()
    $script:Popup.Top = $Area.Bottom - $script:Popup.ActualHeight - 12
    [void]$script:Popup.Activate()
    Write-NotifyLog "tray: popup shown at $($script:Popup.Left),$($script:Popup.Top) size $($script:Popup.ActualWidth)x$($script:Popup.ActualHeight), visible $($script:Popup.IsVisible)"
}

function Update-Tray([bool]$Quiet) {
    $Apps = @(Get-TrayApps)
    $State = Get-TrayState
    $Status = Get-TrayStatus $Apps
    if ($Status -ne $script:LastStatus) {
        $Old = $script:Notify.Icon
        $script:Notify.Icon = New-TrayIcon $Status
        if ($Old) { $Old.Dispose() }
        $script:LastStatus = $Status
    }
    $Count = @($Apps | Where-Object { $_.Pending }).Count
    $Text = switch ($Status) { "installing" { "PackTune Updates: installing ..." } "updates" { "PackTune Updates: $Count update(s) available" } default { "PackTune Updates: up to date" } }
    $script:Notify.Text = $Text.Substring(0, [Math]::Min(63, $Text.Length))
    if ($script:Popup.IsVisible) { Update-Popup }
    if (-not $Quiet) {
        $Decision = Get-TrayPopupDecision $Apps $State
        if ($Decision.NewKeys.Count) { $State.Seen = @($State.Seen) + @($Decision.NewKeys); Save-TrayState $State }
        if ($Decision.Open -and -not $script:Popup.IsVisible) { Show-Popup }
    }
}

$script:Notify.Add_MouseClick({ param($S, $E) if ($E.Button -eq "Left") { if ($script:Popup.IsVisible) { $script:Popup.Hide() } else { Show-Popup } } })
$Menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$Menu.Items.Add("Open", $null, { Show-Popup })
[void]$Menu.Items.Add("Quit until the next sign-in", $null, { $script:Notify.Visible = $false; [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
$script:Notify.ContextMenuStrip = $Menu
$script:Popup.Add_Deactivated({ Write-NotifyLog "tray: popup lost the focus, hidden"; $script:Popup.Hide() })
$script:Popup.FindName("InstallAll").Add_Click({ Invoke-TrayInstallAll; Start-Sleep -Milliseconds 800; Update-Tray $true })

$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(30)
$Timer.Add_Tick({ try { Update-Tray $false } catch { Write-NotifyLog "tray: $($_.Exception.Message)" } })
$Timer.Start()
try { Update-Tray $false } catch { Write-NotifyLog "tray: $($_.Exception.Message)" }
[System.Windows.Threading.Dispatcher]::Run()
$script:Notify.Visible = $false
$script:Notify.Dispose()
'@
    return $Script.Replace("__TOASTLIBRARY__", (Get-UpdateToastLibrary)).Replace("__TRAYLIBRARY__", (Get-UpdateTrayLibrary))
}#tray.ps1, the agent in the session of the user
