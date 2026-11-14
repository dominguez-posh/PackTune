<#
    Device side prompts as Windows notifications: the library that goes into notify.ps1 (plain ASCII, Windows PowerShell 5.1, runs in the
    session of the signed-in user, no admin rights).
      - toast XML (escaped, with the app icon of the package, buttons, scenario "reminder" for deadline notices)
      - the registration of the app "PackTune Updates" (AppUserModelID) and of the protocol packtune-update: in HKCU
      - button activation: only the fixed actions install / later / restart / remind, each bound to a one-time token that notify.ps1
        wrote when it showed the toast (a web page can neither know a token nor reach more than these idempotent actions), and
        only for a package that is installed with a policy in the protected folder
      - the fallback: a small PackTune styled window when toasts are disabled or Focus assist hides them at the deadline
    Loaded by PackTune-Main.ps1; Get-UpdateNotifyScript puts the library into notify.ps1.
#>

function Get-UpdateToastLibrary {
    $Library = @'
# ---------------------------------------------------------------- notifications (toast library)
if (-not $ProgramRoot) { $ProgramRoot = Join-Path $env:ProgramFiles "PackTune" }
if (-not $SnoozeFolder) { $SnoozeFolder = Join-Path $env:LOCALAPPDATA "PackTune\Updates" }
$ToastFolder = Join-Path $SnoozeFolder "toasts"
$ToastAumid = "PackTune.Updates"
$ToastScheme = "packtune-update"

$TrayMutexName = "Local\PackTuneTrayAgent"
function Test-TrayAgentRunning {
    # Is the tray agent of this session there (then notify.ps1 leaves the update prompt to its popup)
    try { $Existing = [System.Threading.Mutex]::OpenExisting($TrayMutexName); $Existing.Dispose(); return $true } catch { return $false }
}

function Write-NotifyLog([string]$Text) {
    # What went wrong in the session of the user (notify.log next to the snooze files, kept small)
    try {
        New-Item -Path $SnoozeFolder -ItemType Directory -Force | Out-Null
        $Log = Join-Path $SnoozeFolder "notify.log"
        if ((Test-Path -LiteralPath $Log) -and (Get-Item -LiteralPath $Log).Length -gt 100KB) { Remove-Item -LiteralPath $Log -Force }
        Add-Content -Path $Log -Value ("{0:s}  {1}" -f (Get-Date), $Text)
    }
    catch { }
}

function ConvertTo-ToastText([string]$Text) {
    # XML text for elements and attributes: control characters out, & < > " ' escaped
    $Clean = [regex]::Replace([string]$Text, "[\x00-\x08\x0B\x0C\x0E-\x1F]", "")
    return [System.Security.SecurityElement]::Escape($Clean)
}

function New-ToastXml {
    # Buttons: @{ Text = ""; Uri = "packtune-update:..." } (protocol) or @{ Text = ""; System = "dismiss" }
    param([string]$Title, [string[]]$Lines, [string]$IconFile, $Buttons, [bool]$Reminder)
    $Sb = New-Object System.Text.StringBuilder
    [void]$Sb.Append($(if ($Reminder) { '<toast scenario="reminder">' } else { '<toast>' }))
    [void]$Sb.Append('<visual><binding template="ToastGeneric">')
    if ($IconFile -and (Test-Path -LiteralPath $IconFile)) { [void]$Sb.Append('<image placement="appLogoOverride" src="' + (ConvertTo-ToastText ([Uri]$IconFile).AbsoluteUri) + '"/>') }
    [void]$Sb.Append('<text>' + (ConvertTo-ToastText $Title) + '</text>')
    foreach ($Line in @($Lines)) { if ($Line) { [void]$Sb.Append('<text>' + (ConvertTo-ToastText $Line) + '</text>') } }
    [void]$Sb.Append('</binding></visual>')
    $Items = @($Buttons | Where-Object { $_ })
    # A reminder needs at least one button
    if ($Reminder -and $Items.Count -eq 0) { $Items = @(@{ Text = "OK"; System = "dismiss" }) }
    if ($Items.Count) {
        [void]$Sb.Append('<actions>')
        foreach ($Button in $Items) {
            if ($Button.System) { [void]$Sb.Append('<action content="' + (ConvertTo-ToastText $Button.Text) + '" arguments="' + (ConvertTo-ToastText $Button.System) + '" activationType="system"/>') }
            else { [void]$Sb.Append('<action content="' + (ConvertTo-ToastText $Button.Text) + '" arguments="' + (ConvertTo-ToastText $Button.Uri) + '" activationType="protocol"/>') }
        }
        [void]$Sb.Append('</actions>')
    }
    [void]$Sb.Append('</toast>')
    return $Sb.ToString()
}

function New-ToastToken {
    $Bytes = New-Object byte[] 16
    $Rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $Rng.GetBytes($Bytes); $Rng.Dispose()
    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Save-ToastToken([string]$Package, [string]$TaskPath, [string[]]$Verbs) {
    # One token per toast, valid for the actions of its buttons only; an older toast of the package stops working
    New-Item -Path $ToastFolder -ItemType Directory -Force | Out-Null
    foreach ($File in @(Get-ChildItem -LiteralPath $ToastFolder -Filter "*.json" -ErrorAction SilentlyContinue)) {
        $Old = $null
        try { $Old = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json } catch { }
        if (-not $Old -or $Old.Package -eq $Package -or $File.LastWriteTime -lt (Get-Date).AddDays(-2)) { Remove-Item -LiteralPath $File.FullName -Force -ErrorAction SilentlyContinue }
    }
    $Token = New-ToastToken
    $Entry = @{ Package = $Package; TaskPath = $TaskPath; Verbs = @($Verbs); Expires = (Get-Date).AddHours(24).ToString("o") }
    Set-Content -LiteralPath (Join-Path $ToastFolder "$Token.json") -Value ($Entry | ConvertTo-Json) -Encoding ASCII
    return $Token
}

function Get-ToastUri([string]$Verb, [string]$Token) { return ("{0}:{1}?t={2}" -f $ToastScheme, $Verb, $Token) }

function Register-ToastApp([string]$HandlerScript) {
    # HKCU only: the name in the Notification Center and the protocol the buttons use
    $Aumid = "HKCU:\Software\Classes\AppUserModelId\$ToastAumid"
    New-Item -Path $Aumid -Force | Out-Null
    Set-ItemProperty -Path $Aumid -Name "DisplayName" -Value "PackTune Updates"
    Set-ItemProperty -Path $Aumid -Name "IconBackgroundColor" -Value "FF005FB8"
    $Proto = "HKCU:\Software\Classes\$ToastScheme"
    New-Item -Path $Proto -Force | Out-Null
    Set-ItemProperty -Path $Proto -Name "(default)" -Value "URL:PackTune update"
    Set-ItemProperty -Path $Proto -Name "URL Protocol" -Value ""
    New-Item -Path "$Proto\shell\open\command" -Force | Out-Null
    $PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    Set-ItemProperty -Path "$Proto\shell\open\command" -Name "(default)" -Value ("`"{0}\System32\conhost.exe`" --headless `"{1}`" -NoProfile -ExecutionPolicy Bypass -File `"{2}`" -Activate `"%1`"" -f $env:SystemRoot, $PowerShell, $HandlerScript)
}

function Get-ToastRoute {
    # toast or window. Toasts that are off (settings, policy) always give the window; Focus assist, presentations and full screen
    # apps (shell state 2, 3, 4, 6) hide a toast, which is fine for a prompt but not for a deadline notice: that one gets the window.
    param([string]$Setting, [int]$UserState, [bool]$Deadline)
    if ($Setting -ne "Enabled") { return "window" }
    if ($Deadline -and $UserState -in 2, 3, 4, 6) { return "window" }
    return "toast"
}

function Get-ToastState {
    # The setting of the app and the notification state of the user: what Get-ToastRoute decides on
    $Setting = "Unavailable"; $UserState = 5
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $Setting = [string][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAumid).Setting
    }
    catch { }
    try {
        if (-not ("PackTuneNotify.Shell" -as [type])) { Add-Type -Namespace PackTuneNotify -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);' }
        $State = 5
        if ([PackTuneNotify.Shell]::SHQueryUserNotificationState([ref]$State) -eq 0) { $UserState = $State }
    }
    catch { }
    return @{ Setting = $Setting; UserState = $UserState }
}

function Show-ToastXml([string]$Package, [string]$Xml) {
    # $true when the toast was handed to Windows
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $Doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $Doc.LoadXml($Xml)
        $Toast = New-Object Windows.UI.Notifications.ToastNotification $Doc
        $Toast.Tag = $(if ($Package.Length -gt 60) { $Package.Substring(0, 60) } else { $Package })
        $Toast.Group = "PackTune"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAumid).Show($Toast)
        return $true
    }
    catch { Write-NotifyLog "toast not shown: $($_.Exception.Message)"; return $false }
}

$UpdateWindowBlock = {
    param($Title, $Message, $Buttons, $IconFile)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $Xaml = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="PackTune Updates" SizeToContent="WidthAndHeight" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Topmost="True" Background="White" FontFamily="Segoe UI" FontSize="13"><Border BorderBrush="#005FB8" BorderThickness="0,4,0,0" Padding="22,18,22,18" MinWidth="420" MaxWidth="540"><StackPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Border Width="44" Height="44" CornerRadius="8" Background="#E8F1FB" Margin="0,0,16,0" VerticalAlignment="Top"><Grid><TextBlock x:Name="Mono" Text="P" FontWeight="Bold" FontSize="17" Foreground="#003E92" HorizontalAlignment="Center" VerticalAlignment="Center"/><Image x:Name="Img" Margin="5"/></Grid></Border><StackPanel Grid.Column="1"><TextBlock x:Name="TitleText" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/><TextBlock x:Name="Body" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#3B3B3B"/></StackPanel></Grid><StackPanel x:Name="Row" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"/></StackPanel></Border></Window>'
    $Window = [System.Windows.Markup.XamlReader]::Parse($Xaml)
    $Window.FindName("TitleText").Text = [string]$Title
    $Window.FindName("Body").Text = [string]$Message
    if ($IconFile -and (Test-Path -LiteralPath $IconFile)) {
        try {
            $Bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $Bitmap.BeginInit(); $Bitmap.UriSource = New-Object Uri $IconFile; $Bitmap.CacheOption = "OnLoad"; $Bitmap.DecodePixelWidth = 64; $Bitmap.EndInit(); $Bitmap.Freeze()
            $Window.FindName("Img").Source = $Bitmap
            $Window.FindName("Mono").Visibility = "Collapsed"
        }
        catch { }
    }
    $Holder = @{ Choice = $null }
    foreach ($Item in @($Buttons)) {
        $Button = New-Object System.Windows.Controls.Button
        $Button.Content = [string]$Item.Text; $Button.Tag = [string]$Item.Result; $Button.MinWidth = 96
        $Button.Padding = New-Object System.Windows.Thickness 14, 6, 14, 6; $Button.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        if ($Item.Primary) {
            $Button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#005FB8"); $Button.Foreground = [System.Windows.Media.Brushes]::White; $Button.BorderThickness = New-Object System.Windows.Thickness 0
        }
        $Button.Add_Click({ param($Sender, $E) $Holder.Choice = [string]$Sender.Tag; $Window.Close() }.GetNewClosure())
        [void]$Window.FindName("Row").Children.Add($Button)
    }
    [void]$Window.ShowDialog()
    return $Holder.Choice
}

function Show-UpdateWindow {
    # The fallback: a small window instead of a message box; runs in its own STA runspace (WPF needs STA). Returns the result of the pressed button, or $null.
    param([string]$Title, [string]$Message, $Buttons, [string]$IconFile)
    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = "STA"; $Runspace.ThreadOptions = "ReuseThread"; $Runspace.Open()
    $Ps = [powershell]::Create()
    $Ps.Runspace = $Runspace
    try {
        [void]$Ps.AddScript($UpdateWindowBlock.ToString()).AddArgument($Title).AddArgument($Message).AddArgument(@($Buttons)).AddArgument($IconFile)
        return (@($Ps.Invoke()) | Select-Object -Last 1)
    }
    catch { return $null }
    finally { $Ps.Dispose(); $Runspace.Dispose() }
}

function Resolve-ToastActivation {
    # The only way a button press turns into an action: the address must be exactly packtune-update:<verb>?t=<token>, the token must be
    # one this machine wrote for that verb and still valid, and its package must be installed with a policy in the protected folder
    # (config.json, state.json or restart.json of the package). Everything else is ignored.
    param([string]$Uri)
    $Match = [regex]::Match([string]$Uri, '^packtune-update:(install|later|restart|remind)\?t=([0-9a-f]{32})/?$', "IgnoreCase")
    if (-not $Match.Success) { return $null }
    $Verb = $Match.Groups[1].Value.ToLower(); $Token = $Match.Groups[2].Value.ToLower()
    $TokenFile = Join-Path $ToastFolder "$Token.json"
    if (-not (Test-Path -LiteralPath $TokenFile)) { return $null }
    try { $Entry = Get-Content -LiteralPath $TokenFile -Raw | ConvertFrom-Json } catch { return $null }
    try { if ([datetime]$Entry.Expires -lt (Get-Date)) { Remove-Item -LiteralPath $TokenFile -Force -ErrorAction SilentlyContinue; return $null } } catch { return $null }
    if (@($Entry.Verbs) -notcontains $Verb) { return $null }
    $Package = [string]$Entry.Package
    if ($Package -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { return $null }
    $TaskMatch = [regex]::Match([string]$Entry.TaskPath, '^\\PackTune\\(Chocolatey|Winget)\\$')
    if (-not $TaskMatch.Success) { return $null }
    $Root = Join-Path (Join-Path $ProgramRoot $TaskMatch.Groups[1].Value) $Package
    try { $Config = Get-Content -LiteralPath (Join-Path $Root "config.json") -Raw | ConvertFrom-Json } catch { return $null }
    # The id of the package folder and task: TaskId for both sources (Chocolatey: the package, winget: the safe id); older config: Package
    $ConfigId = if ($Config.TaskId) { [string]$Config.TaskId } else { [string]$Config.Package }
    if ($ConfigId -cne $Package) { return $null }
    if ([string]$Config.TaskPath -cne [string]$Entry.TaskPath) { return $null }
    # The action only makes sense while the thing it answers is pending
    $Pending = if ($Verb -in "install", "later") { "state.json" } else { "restart.json" }
    if (-not (Test-Path -LiteralPath (Join-Path $Root $Pending))) { return $null }
    $Name = if ($Config.DisplayName) { [string]$Config.DisplayName } else { $Package }
    $Name = [regex]::Replace($Name, '[\x00-\x1F"]', "")
    return [pscustomobject]@{ Verb = $Verb; Package = $Package; TaskPath = [string]$Config.TaskPath; DisplayName = $Name; TokenFile = $TokenFile }
}

function Invoke-ToastAction {
    # The four actions, nothing else: start the SYSTEM task "Update <package> now", snooze the update prompt 4 hours, restart in 60
    # seconds, snooze the restart prompt 1 hour. Returns the text for the result notice, or "".
    param($Action)
    $Text = ""
    switch ($Action.Verb) {
        "install" {
            & schtasks.exe /run /tn ($Action.TaskPath + "Update " + $Action.Package + " now") | Out-Null
            $Text = if ($LASTEXITCODE -eq 0) { "The update of $($Action.DisplayName) is being installed now." } else { "The update could not be started. It is installed automatically at the deadline." }
        }
        "later" { New-Item -Path $SnoozeFolder -ItemType Directory -Force | Out-Null; Set-Content -Path (Join-Path $SnoozeFolder "$($Action.Package).snooze") -Value (Get-Date).AddHours(4).ToString("o") }
        "remind" { New-Item -Path $SnoozeFolder -ItemType Directory -Force | Out-Null; Set-Content -Path (Join-Path $SnoozeFolder "$($Action.Package).restart") -Value (Get-Date).AddHours(1).ToString("o") }
        "restart" {
            $Comment = [regex]::Replace([string]$Action.DisplayName, '[\x00-\x1F"]', "")
            if ($Comment.Length -gt 80) { $Comment = $Comment.Substring(0, 80) }
            & shutdown.exe /r /t 60 /c "Restart for the update of $Comment" | Out-Null
        }
    }
    if ($Action.TokenFile) { Remove-Item -LiteralPath $Action.TokenFile -Force -ErrorAction SilentlyContinue }
    return $Text
}

function Show-Notice {
    # One notice: as a toast with buttons (verbs: install, later, restart, remind), or in the window. The window route runs the
    # action of the pressed button here; the toast route runs it when a button is pressed (Resolve-ToastActivation, Invoke-ToastAction).
    # Returns "toast", "window" or "none".
    param(
        [Parameter(Mandatory = $true)][string]$Package, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$TaskPath, [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$Lines, $Buttons, [bool]$Deadline, [string]$IconFile, [string]$HandlerScript, [switch]$NoToast
    )
    # The app must be registered before Windows can tell whether its toasts are allowed
    if (-not $NoToast) { try { Register-ToastApp $HandlerScript } catch { Write-NotifyLog "registration failed: $($_.Exception.Message)" } }
    $State = Get-ToastState
    $Route = if ($NoToast) { "window" } else { Get-ToastRoute -Setting $State.Setting -UserState $State.UserState -Deadline $Deadline }
    if ($Route -eq "toast") {
        $Verbs = @(@($Buttons) | Where-Object { $_ -and $_.Verb } | ForEach-Object { $_.Verb })
        $Token = if ($Verbs.Count) { Save-ToastToken $Package $TaskPath $Verbs } else { "" }
        $Items = @(@($Buttons) | Where-Object { $_ } | ForEach-Object {
            if ($_.Verb) { @{ Text = $_.Text; Uri = (Get-ToastUri $_.Verb $Token) } } else { @{ Text = $_.Text; System = "dismiss" } }
        })
        if (Show-ToastXml $Package (New-ToastXml -Title $Title -Lines $Lines -IconFile $IconFile -Buttons $Items -Reminder $Deadline)) { return "toast" }
    }
    $WindowButtons = @(@($Buttons) | Where-Object { $_ } | ForEach-Object { @{ Text = $_.Text; Result = $(if ($_.Verb) { $_.Verb } else { "ack" }); Primary = [bool]$_.Primary } })
    if ($WindowButtons.Count -eq 0) { $WindowButtons = @(@{ Text = "OK"; Result = "ack"; Primary = $true }) }
    $Answer = Show-UpdateWindow -Title $Title -Message (@($Lines | Where-Object { $_ }) -join "`r`n`r`n") -Buttons $WindowButtons -IconFile $IconFile
    $Offered = @(@($Buttons) | Where-Object { $_ -and $_.Verb } | ForEach-Object { $_.Verb })
    if ($Answer -and $Offered -contains $Answer) {
        $Result = Invoke-ToastAction ([pscustomobject]@{ Verb = $Answer; Package = $Package; TaskPath = $TaskPath; DisplayName = $Name; TokenFile = $null })
        if ($Result) { [void](Show-Notice -Package $Package -Name $Name -TaskPath $TaskPath -Title "Software update: $Name" -Lines @($Result) -IconFile $IconFile -HandlerScript $HandlerScript) }
    }
    return "window"
}
'@
    return $Library
}#Library of the notifications for notify.ps1
