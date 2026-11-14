#requires -Version 5.1
<#
.SYNOPSIS
    PackTune (winget and Chocolatey apps for Intune) - graphical interface for PackTune-Main.ps1.
.DESCRIPTION
    Look and window technique of the M365 MFA Administration tool and MSIX Sandbox Studio: shared UI\Theme.xaml,
    slate header with connection state, Start.cmd starts the console hidden. Sign in opens the Microsoft sign-in in
    the browser (IntuneWin32App module); the arrow next to it offers the sign-in with an account from Keevault
    (embedded browser, filled in from the password manager).
    Deployments, feed lookups and tenant reads run in background runspaces; their log lines show up live in the
    activity panel, so the window never freezes. Deployments run one after another.
.PARAMETER HideConsole
    Set by Start.cmd: hides the console window of this process.
#>
[CmdletBinding()]
param([switch]$HideConsole)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This WPF tool requires Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot = $PSScriptRoot
$script:ToolVersion = '2.2.0'
$script:RepoUrl = 'https://github.com/dominguez-posh/PackTune'
$script:CorePath = Join-Path $PSScriptRoot 'PackTune-Main.ps1'
. $script:CorePath
Import-Module (Join-Path $PSScriptRoot 'Modules\Keevault.psm1') -Force

# ---------------------------------------------------------------- console window (M365 MFA tool technique)
if (-not ('PackTune.NativeWindow' -as [type])) {
    Add-Type -Namespace PackTune -Name NativeWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}

function Hide-ConsoleWindow {
    # The console is looked up again each time: Windows Terminal may take it over when it becomes visible.
    param([IntPtr]$Window = [IntPtr]::Zero)
    $native = [PackTune.NativeWindow]
    if ($Window -ne [IntPtr]::Zero) { [void]$native::ShowWindow($Window, 0) }
    # GA_ROOTOWNER (3): with Windows Terminal, the console window is a hidden pseudo window owned by the terminal.
    $current = $native::GetAncestor($native::GetConsoleWindow(), 3)
    if ($current -ne [IntPtr]::Zero -and $current -ne $Window) { [void]$native::ShowWindow($current, 0) }
}

function Invoke-InteractiveSignIn {
    <#
    A sign-in dialog that belongs to the console window (Web Account Manager) stays invisible while the console is
    hidden. The console is shown centered over the tool while signing in and hidden again afterwards; then the tool
    is activated again. The IntuneWin32App module signs in through the browser, so this is only used for sign-ins
    that open a Windows dialog.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    $native = [PackTune.NativeWindow]
    $active = $native::GetForegroundWindow()
    $console = $native::GetAncestor($native::GetConsoleWindow(), 3)
    $state = if ($console -eq [IntPtr]::Zero) { 'None' }
             elseif ($native::IsIconic($console)) { 'Minimized' }
             elseif (-not $native::IsWindowVisible($console)) { 'Hidden' }
             else { 'Visible' }
    if ($state -in 'Minimized', 'Hidden') {
        [void]$native::ShowWindow($console, 9)   # SW_RESTORE
        $toolRect = New-Object PackTune.NativeWindow+RECT
        $consoleRect = New-Object PackTune.NativeWindow+RECT
        if ($active -ne [IntPtr]::Zero -and $native::GetWindowRect($active, [ref]$toolRect) -and $native::GetWindowRect($console, [ref]$consoleRect)) {
            $x = [int](($toolRect.Left + $toolRect.Right - ($consoleRect.Right - $consoleRect.Left)) / 2)
            $y = [int](($toolRect.Top + $toolRect.Bottom - ($consoleRect.Bottom - $consoleRect.Top)) / 2)
            [void]$native::SetWindowPos($console, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001 -bor 0x0004)   # SWP_NOSIZE | SWP_NOZORDER
        }
    }
    if ($state -ne 'None') { [void]$native::SetForegroundWindow($console) }
    try { & $Action }
    finally {
        switch ($state) {
            'Minimized' { [void]$native::ShowWindow($console, 6) }   # SW_MINIMIZE
            'Hidden'    { Hide-ConsoleWindow -Window $console }
        }
        if ($active -ne [IntPtr]::Zero) { [void]$native::SetForegroundWindow($active) }
    }
}

if ($HideConsole) { Hide-ConsoleWindow }

# ---------------------------------------------------------------- window
if (-not [System.Windows.Application]::Current) { [void](New-Object System.Windows.Application) }
[System.Windows.Application]::Current.ShutdownMode = 'OnExplicitShutdown'
[xml]$themeXml = Get-Content (Join-Path $PSScriptRoot 'UI\Theme.xaml') -Raw -Encoding UTF8
[System.Windows.Application]::Current.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($themeXml)))
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $window.FindName($name)
}
$window.Title = "PackTune $script:ToolVersion"

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Key) { [System.Windows.Application]::Current.Resources[$Key] }
function ConvertTo-Brush([string]$Hex) { $script:BrushConverter.ConvertFrom($Hex) }

# ---------------------------------------------------------------- rows for the lists
# One generic row object for every list of the window (cards, tenant table, jobs, import and device tables). The
# templates in MainWindow.xaml bind to its indexer ({Binding [Title]}); values are text, so flags are 'True'/'False'
# and visibilities 'Visible'/'Collapsed'. Data holds the object behind the row.
if (-not ('PackTune.Row' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
using System.ComponentModel;
namespace PackTune {
    public class Row : INotifyPropertyChanged {
        private Dictionary<string, object> values = new Dictionary<string, object>();
        private object items;
        public event PropertyChangedEventHandler PropertyChanged;
        public object Data { get; set; }
        public object Items { get { return items; } set { items = value; Raise("Items"); } }
        public object this[string key] {
            get { object v; return values.TryGetValue(key, out v) ? v : null; }
            set { values[key] = value; Raise("Item[]"); }
        }
        private void Raise(string name) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(name)); }
    }
}
'@ -ReferencedAssemblies System.dll
}
function Set-Row($Row, [hashtable]$Values) {
    foreach ($key in $Values.Keys) {
        if ($key -eq 'Items') { $Row.Items = $Values[$key] }
        elseif ($key -eq 'Data') { $Row.Data = $Values[$key] }
        else { $Row[$key] = $(if ($null -eq $Values[$key]) { $null } else { [string]$Values[$key] }) }
    }
    $Row
}
function New-Row([hashtable]$Values) { Set-Row (New-Object PackTune.Row) $Values }
function ConvertTo-Vis([bool]$On) { if ($On) { 'Visible' } else { 'Collapsed' } }

# Tile colors (background, letter) as in the mockups; a name always gets the same pair
$script:TilePalette = @(@('#E8F0FE', '#1A56C4'), @('#FDEBDD', '#A3450C'), @('#DDF1F7', '#0B5F75'), @('#FDE6E1', '#A6301A'), @('#E5F3E2', '#2E6B1F'),
    @('#EDEDED', '#1B1B1B'), @('#FBE3E3', '#A11D1D'), @('#FFEBD6', '#9A4A00'), @('#E3EEF9', '#1F4E8C'), @('#E9EEF3', '#2F4A63'))
function Get-TileStyle([string]$Name) {
    $sum = 0; foreach ($c in $Name.ToCharArray()) { $sum += [int]$c }
    $pair = $script:TilePalette[$sum % $script:TilePalette.Count]
    @{ TileBg = $pair[0]; TileFg = $pair[1]; Mono = $(if ($Name) { $Name.Substring(0, 1).ToUpper() } else { '?' }) }
}

# Pills: kind -> background, text
$script:PillColors = @{
    ok = @('#DFF6DD', '#0E5C0E'); warn = @('#FFF4CE', '#7A4A00'); bad = @('#FDE7E9', '#A11D1D'); info = @('#E8F1FB', '#003E92'); gray = @('#F0F0F0', '#3B3B3B')
}

# ---------------------------------------------------------------- log file, toasts
$script:UiLogLines = New-Object System.Collections.ArrayList
$script:LogFolder = Join-Path $script:WorkRoot 'logs'
function Write-UiLog([string]$Text, [string]$Level = 'Info') {
    # Messages of the window itself (tasks keep their own log in the activity list). Also into a log file per day.
    $now = Get-Date
    [void]$script:UiLogLines.Add($Text)
    while ($script:UiLogLines.Count -gt 500) { $script:UiLogLines.RemoveAt(0) }
    try {
        if (-not (Test-Path $script:LogFolder)) { New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null }
        Add-Content -Path (Join-Path $script:LogFolder ('{0:yyyy-MM-dd}.log' -f $now)) -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1,-7}  {2}' -f $now, $Level, $Text) -Encoding UTF8
    }
    catch { }
}
Set-PackTuneSignInLog { param($Text, $Level) Write-UiLog $Text $(if ($Level) { $Level } else { 'Info' }) }

$script:Toasts = New-Object System.Collections.ArrayList
function Show-Toast([string]$Text, [string]$Kind = 'info', [string]$ActionLabel, [scriptblock]$Action) {
    <# Short message in the corner: what a job did, or what went wrong. Success and info vanish after 6 s, problems after 12 s. #>
    $pill = $script:PillColors[$Kind]; if (-not $pill) { $pill = @('#FFFFFF', '#1B1B1B') }
    $glyph = @{ ok = [char]0xE73E; warn = [char]0xE7BA; bad = [char]0xEA39; info = [char]0xE946 }[$Kind]
    $border = New-Object System.Windows.Controls.Border
    $border.Background = ConvertTo-Brush $(if ($Kind -eq 'info') { '#FFFFFF' } else { $pill[0] })
    $border.BorderBrush = ConvertTo-Brush '#D1D1D1'; $border.BorderThickness = 1; $border.CornerRadius = 8; $border.Padding = '14,10'; $border.Margin = '0,8,0,0'
    $border.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 16; ShadowDepth = 3; Opacity = 0.18 }
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }; [void]$grid.ColumnDefinitions.Add($c) }
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = [string]$glyph; $icon.FontFamily = $window.FindResource('IconFont'); $icon.FontSize = 15; $icon.Margin = '0,1,10,0'; $icon.VerticalAlignment = 'Top'
    $icon.Foreground = ConvertTo-Brush $pill[1]
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text; $label.TextWrapping = 'Wrap'; $label.Foreground = ConvertTo-Brush $(if ($Kind -eq 'info') { '#1B1B1B' } else { $pill[1] })
    [System.Windows.Controls.Grid]::SetColumn($label, 1)
    [void]$grid.Children.Add($icon); [void]$grid.Children.Add($label)
    if ($ActionLabel -and $Action) {
        $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = [System.Windows.GridLength]::Auto; [void]$grid.ColumnDefinitions.Add($c)
        $link = New-Object System.Windows.Controls.Button
        $link.Content = $ActionLabel; $link.Padding = '10,2'; $link.Margin = '10,0,0,0'; $link.MinHeight = 0; $link.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetColumn($link, 2)
        $link.Add_Click({ param($b, $a) try { & $b.Tag } catch { } }.GetNewClosure())
        $link.Tag = $Action
        [void]$grid.Children.Add($link)
    }
    $border.Child = $grid
    [void]$ui.ToastHost.Children.Add($border)
    [void]$script:Toasts.Add(@{ Element = $border; Expires = (Get-Date).AddSeconds($(if ($Kind -in 'bad', 'warn') { 12 } else { 6 })); Text = $Text; Kind = $Kind })
    while ($ui.ToastHost.Children.Count -gt 4) { $first = $ui.ToastHost.Children[0]; $ui.ToastHost.Children.RemoveAt(0); foreach ($old in @($script:Toasts | Where-Object { $_.Element -eq $first })) { $script:Toasts.Remove($old) } }
}
function Update-Toasts {
    foreach ($toast in @($script:Toasts)) {
        if ($toast.Expires -lt (Get-Date)) { $ui.ToastHost.Children.Remove($toast.Element); $script:Toasts.Remove($toast) }
    }
}

function Get-FriendlyCause([string]$Raw) {
    <# A short English cause in plain words for what Graph, the network or .NET reported (often localized and technical).
       The raw text stays in the log and behind Details. #>
    $text = [string]$Raw
    if (-not $text) { return 'Something went wrong.' }
    if ($text -match '(?i)\b403\b|forbidden|verboten|insufficient privileges|Authorization_RequestDenied|access is denied|zugriff verweigert') { return 'No permission: confirm the new permissions or check the license.' }
    if ($text -match '(?i)\b401\b|unauthorized|nicht autorisiert|token.*expired|InvalidAuthenticationToken') { return 'The sign-in expired or is not accepted: sign in again.' }
    if ($text -match '(?i)\b50[0234]\b|service unavailable|bad gateway|gateway time|internal server error|serverfehler') { return 'Microsoft Graph has a problem right now (server error). Try again in a moment.' }
    if ($text -match '(?i)\b40[04]\b|bad request|not found|nicht gefunden|ung(Ã¼|u|ue)ltige anforderung|BadRequest|ResourceNotFound') { return 'Not available in this tenant (Remediations need Windows Enterprise E3/E5 licensing).' }
    if ($text -match '(?i)remoteserver|remote server|remotename|could not be resolved|unable to connect|no such host|timed out|timeout|zeit(Ã¼|u|ue)berschreitung|network|netzwerk|connection (was )?(closed|refused|reset)|Verbindung|name or service not known|SSL|TLS') { return "Can't reach Microsoft Graph." }
    $one = ($text -replace '\s+', ' ').Trim()
    if ($one.Length -gt 140) { $one = $one.Substring(0, 137) + '...' }
    $one
}

# ---- Graph not reachable (network, VPN, 5xx, expired sign-in): lists stay, a banner says why, retries run by themselves
$script:GraphDown = $null            # @{ Since; Cause; Raw } while the last read of the tenant failed that way
$script:GraphReadKinds = @('tenant', 'deps', 'customlist', 'counts', 'supercheck')
$script:GraphRetryDelay = 15
$script:GraphRetryAt = $null
function Test-GraphClientError([string]$Text) {
    # The service answered and said no (permission, not found, bad request): Graph is reachable, so this is no outage. The .NET text
    # "The remote server returned an error: (403) Forbidden" contains "remote server" and must not look like a network problem.
    $Text -match '(?i)\(40[0345]\)|\b40[0345]\b|forbidden|verboten|bad request|ltige anforderung|not found|nicht gefunden|Authorization_RequestDenied|insufficient privileges'
}
function Test-GraphReadFailureText([string]$Text) {
    if (Test-GraphClientError $Text) { return $false }
    $Text -match '(?i)remoteserver|remotename|remote name|remote server|could not be resolved|unable to connect|no such host|name or service not known|timed out|timeout|zeit(ue|Ã¼)berschreitung|network|netzwerk|connection (was )?(closed|refused|reset)|\b50[0234]\b|service unavailable|bad gateway|\b401\b|unauthorized|InvalidAuthenticationToken'
}
function Update-GraphDownBanner {
    $d = $script:GraphDown
    $ui.BoxGraphDown.Visibility = ConvertTo-Vis ([bool]$d -and (Test-SignedIn))
    if ($d) {
        $known = @($script:TenantApps).Count -or @($script:CustomApps).Count
        $cause = if ($d.Cause -like "Can't reach*") { "Can't reach Microsoft Graph - check the network/VPN." } else { $d.Cause }
        $ui.TxtGraphDown.Text = "$cause$(if ($known) { ' The lists show the last known state and are not current.' }) Trying again automatically."
    }
}
function Set-GraphDown([string]$Raw) {
    $script:GraphDown = @{ Since = $(if ($script:GraphDown) { $script:GraphDown.Since } else { Get-Date }); Cause = (Get-FriendlyCause $Raw); Raw = $Raw }
    if (-not $script:GraphRetryAt) { $script:GraphRetryDelay = 15; $script:GraphRetryAt = (Get-Date).AddSeconds($script:GraphRetryDelay) }
    Write-UiLog "Microsoft Graph could not be read: $Raw" 'Warning'
    Update-GraphDownBanner
}
function Clear-GraphDown {
    if (-not $script:GraphDown) { return }
    $script:GraphDown = $null; $script:GraphRetryAt = $null; $script:GraphRetryDelay = 15
    Write-UiLog 'Microsoft Graph is reachable again.' 'Success'
    Update-GraphDownBanner
    try { Update-TenantRows } catch { }; try { Update-CustomRows } catch { }; try { Update-Readiness } catch { }
}
function Invoke-GraphRetry {
    $script:GraphRetryAt = (Get-Date).AddSeconds($script:GraphRetryDelay)
    if (-not (Test-SignedIn)) { return }
    try { Start-TenantRefresh } catch { }
    try { $script:CustomApps = $script:CustomApps; Start-CustomRefresh } catch { }
}
function Step-GraphRetry {
    # Backoff 15 s, 30 s, 60 s ... up to 2 minutes, while Graph is down
    if (-not $script:GraphDown -or -not $script:GraphRetryAt -or (Get-Date) -lt $script:GraphRetryAt) { return }
    if (Test-TaskRunning 'tenant') { return }
    $script:GraphRetryDelay = [Math]::Min(120, $script:GraphRetryDelay * 2)
    Invoke-GraphRetry
}
$ui.BtnGraphRetry.Add_Click({ try { $script:GraphRetryDelay = 15; Invoke-GraphRetry; Show-Toast 'Trying again ...' 'info' } catch { Show-Error $_.Exception.Message } })

function Show-SignInCancelled {
    # A cancelled sign-in is no error: a quiet note, and the header shows Sign in again
    Write-UiLog 'Sign-in cancelled.'
    Show-Toast 'Sign-in cancelled' 'info'
    try { Update-ConnectionStatus } catch { }
}

function Show-Error([string]$Message) {
    # No system dialog: the cause as a toast with Details (the activity page with the log); a cancelled sign-in only a note
    if ($Message -like 'Sign-in cancelled*') { Show-SignInCancelled; return }
    Write-UiLog $Message 'Error'
    $short = Get-FriendlyCause $Message
    Show-Toast $short 'bad' 'Details' { Show-Page 'Activity' }
}

$script:ConfirmFrame = $null
$script:ConfirmAnswer = $false
function Confirm-Action([string]$Message, [string]$Title = 'PackTune', [string]$YesLabel = 'Continue', [string]$NoLabel = 'Cancel') {
    # The app's own confirmation (card above everything, Enter = yes, Esc = no). Returns the answer; the window keeps running meanwhile.
    if ($env:PACKTUNE_SMOKE -and -not $script:ConfirmDialogTest) { return $true }
    if ($script:ConfirmFrame) { return $false }
    $ui.ConfirmTitle.Text = $Title
    $ui.ConfirmText.Text = $Message
    $ui.BtnConfirmYes.Content = $YesLabel; $ui.BtnConfirmNo.Content = $NoLabel
    $script:ConfirmAnswer = $false
    $script:ConfirmFrame = New-Object System.Windows.Threading.DispatcherFrame
    $ui.ConfirmLayer.Visibility = 'Visible'
    [void]$ui.BtnConfirmYes.Focus()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($script:ConfirmFrame) }
    finally { $ui.ConfirmLayer.Visibility = 'Collapsed'; $script:ConfirmFrame = $null }
    return $script:ConfirmAnswer
}
function Complete-Confirm([bool]$Answer) {
    if (-not $script:ConfirmFrame) { return }
    $script:ConfirmAnswer = $Answer
    $script:ConfirmFrame.Continue = $false
}
$ui.BtnConfirmYes.Add_Click({ Complete-Confirm $true })
$ui.BtnConfirmNo.Add_Click({ Complete-Confirm $false })
$script:ClickActions = @{}
function Add-Click {
    # Click handler with error handling: an exception shows a message instead of killing the window.
    # Actions are looked up by sender (no GetNewClosure: that would hide this script's functions and variables).
    param($Control, [scriptblock]$Action)
    $script:ClickActions[$Control] = $Action
    $Control.Add_Click({
        param($src)
        try { & $script:ClickActions[$src] } catch { Show-Error $_.Exception.Message }
    })
}


# ---------------------------------------------------------------- background tasks
# Shared with the task runspaces: the sign-in and the package infos from the feed
$script:Shared = [hashtable]::Synchronized(@{
    Auth         = $null
    Meta         = [hashtable]::Synchronized(@{})
    CancelSignIn = $false
})
# Deployments and tenant changes one after another; what the user starts (sign-in, search, module installation)
# next to them; feed lookups and icon rendering on their own pool, so they never hold up a click
$script:WorkPool = [runspacefactory]::CreateRunspacePool(1, 1)
$script:WorkPool.Open()
$script:UserPool = [runspacefactory]::CreateRunspacePool(1, 3)
$script:UserPool.Open()
$script:MetaPool = [runspacefactory]::CreateRunspacePool(1, 4)
$script:MetaPool.Open()
# A sandbox test waits until you report its result (Windows Sandbox runs one at a time): it must not hold up anything else
$script:TestPool = [runspacefactory]::CreateRunspacePool(1, 1)
$script:TestPool.Open()
$script:Tasks = New-Object System.Collections.ArrayList
$script:TaskCounter = 0
$script:MetaDirty = $false
$script:MetaCachePath = Join-Path $script:WorkRoot 'feedcache.json'
$script:MetaCacheHours = 24
# Tests only: script text of a fake Graph call (see New-InsightGraphContext -Invoke); empty = the real tenant
$script:InsightFake = ''

# Runs inside a pool runspace: loads the core script, takes over the sign-in, captures every stream into the job log
$script:TaskBody = {
    param($CorePath, $Shared, $Job, $Work, $WorkArguments)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $Job.Status = 'running'
    $Job.Started = Get-Date
    $Output = New-Object System.Collections.ArrayList
    function Add-JobLog([string]$Level, [string]$Text) {
        if ($Text) { [void]$Job.Log.Add(@{ Level = $Level; Text = $Text; Time = (Get-Date).ToString('HH:mm:ss') }) }
    }
    try {
        . $CorePath
        if ($Shared.Auth) { Set-PackTuneAuthState $Shared.Auth }
        $WorkScript = [scriptblock]::Create($Work)
        & $WorkScript @WorkArguments *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Add-JobLog 'Error' $_.Exception.Message; $Job.HadError = $true }
            elseif ($_ -is [System.Management.Automation.WarningRecord]) { Add-JobLog 'Warning' $_.Message }
            elseif ($_ -is [System.Management.Automation.InformationRecord]) { Add-JobLog 'Info' ([string]$_.MessageData) }
            elseif ($_ -is [System.Management.Automation.VerboseRecord] -or $_ -is [System.Management.Automation.DebugRecord]) { }
            else { [void]$Output.Add($_) }
        }
        # A token refreshed during a long run is handed back to everyone else
        if ($Shared.Auth -and $Global:AccessToken) { $Shared.Auth = Get-PackTuneAuthState }
    }
    catch {
        Add-JobLog 'Error' $_.Exception.Message
        $Job.HadError = $true
    }
    $Job.Result = @($Output)
    $Job.Finished = Get-Date
    if ($Job.HadError) { $Job.Status = 'failed' }
    elseif ($Job.Kind -eq 'deploy' -and $Output.Count -eq 0) { $Job.Status = 'skipped' }
    else { $Job.Status = 'succeeded' }
}.ToString()

$script:JobRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstJobs.ItemsSource = $script:JobRows
$script:JobNouns = @{ deploy = 'Deployment'; policy = 'Update settings'; release = 'Release'; remove = 'Removal'; test = 'Sandbox test'; components = 'Components'
    chocolatey = 'Dependency apps'; appreg = 'App registration'; connect = 'Sign-in'; runtime = 'Dependency'; cleanupdeps = 'Dependency'; takeover = 'Import'; statusscript = 'Status report'; export = 'Export' }

function Start-UiTask {
    <#
    Runs $Work (text, with the core script loaded) in a background runspace. $OnDone gets ($Result, $Job) on the
    UI thread when it finishes. Tasks on the same pool queue up and run one after another. Tasks that are not Hidden
    show up in the activity list (-Display = the name shown there); a failed one can be started again with Retry.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Work,
        [hashtable]$Arguments = @{},
        [string]$Package,
        [string]$Display,
        [scriptblock]$OnDone,
        [switch]$NeedsAuth,
        [switch]$Hidden,
        $Pool = $script:WorkPool
    )
    if ($NeedsAuth -and -not $script:Shared.Auth) { throw 'Sign in to Intune first (Sign in, top right).' }
    $spec = @{}
    foreach ($key in $PSBoundParameters.Keys) { $spec[$key] = $PSBoundParameters[$key] }
    $script:TaskCounter++
    $job = [hashtable]::Synchronized(@{
        Id       = $script:TaskCounter
        Kind     = $Kind
        Title    = $Title
        Display  = $(if ($Display) { $Display } elseif ($Package) { $Package } else { $Title })
        Package  = $Package
        Source   = $Arguments['Source']
        Status   = 'queued'
        HadError = $false
        Log      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Result   = $null
        Spec     = $spec
        Queued   = (Get-Date)
        Started  = $null
        Finished = $null
        LogOpen  = $false
        Row      = $null
    })
    # Work is passed as text: script blocks are bound to the runspace that created them
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($script:TaskBody).AddArgument($script:CorePath).AddArgument($script:Shared).AddArgument($job).AddArgument($Work).AddArgument($Arguments)
    $task = @{ Job = $job; PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Hidden = [bool]$Hidden }
    [void]$script:Tasks.Add($task)
    if (-not $Hidden) {
        $job.Row = New-Row (@{ Data = $job; Title = $job.Display } + (Get-TileStyle $job.Display))
        $script:JobRows.Insert(0, $job.Row)
        Update-JobRow $job
        Write-UiLog "$Title ..."
    }
    Update-Busy
    return $job
}

function Update-JobRow($Job) {
    # The row of the activity list follows the job: status pill, progress, last message, log text
    $row = $Job.Row
    if (-not $row) { return }
    $noun = $script:JobNouns[$Job.Kind]; if (-not $noun) { $noun = 'Task' }
    $entries = @($Job.Log.ToArray())
    $last = if ($entries.Count) { [string]$entries[-1].Text } else { '' }
    $status = [string]$Job.Status
    $pillName, $label = switch ($status) {
        'queued' { 'gray', 'Waiting' } 'running' { 'info', 'Running' } 'succeeded' { 'ok', 'Done' } 'skipped' { 'gray', 'Skipped' } default { 'bad', 'Failed' }
    }
    $took = if ($Job.Started -and $Job.Finished) { $span = $Job.Finished - $Job.Started; if ($span.TotalMinutes -ge 1) { '{0} min {1} s' -f [int][math]::Floor($span.TotalMinutes), $span.Seconds } else { '{0} s' -f [int]$span.TotalSeconds } } else { $null }
    $errors = @($entries | Where-Object Level -eq 'Error')
    $sub = switch ($status) {
        'queued' { "$noun $([char]0x00B7) waiting" }
        'running' { "$noun $([char]0x00B7) $(if ($last) { $last } else { 'starting' })" }
        'failed' { if ($errors.Count) { [string]$errors[-1].Text } else { "$noun failed" } }
        'skipped' { if ($last) { $last } else { "$noun skipped" } }
        default { "$noun $([char]0x00B7) $took$(if ($last) { ' ' + [char]0x00B7 + ' ' + $last })" }
    }
    $progress = switch ($status) { 'running' { [math]::Min(95, [math]::Max(8, [int]($entries.Count * 100 / 9))) } 'queued' { 0 } default { 100 } }
    $logText = (@($entries | ForEach-Object { '{0}  {1}' -f $_.Time, $_.Text }) -join "`n")
    $jobIcon = if ($Job.Package) { Get-PackageIcon ([string]$Job.Package) $(if ($Job.Source) { [string]$Job.Source } else { 'Chocolatey' }) }
    $open = [bool]$Job.LogOpen -and $entries.Count -gt 0
    Set-Row $row @{
        Sub = $sub; SubFg = $(if ($status -eq 'failed') { '#A11D1D' } else { '#5F5F5F' }); Status = $label
        StatusBg = $script:PillColors[$pillName][0]; StatusFg = $script:PillColors[$pillName][1]
        Progress = $progress; ProgressVis = (ConvertTo-Vis ($status -in 'queued', 'running'))
        Log = $logText; LogVis = (ConvertTo-Vis $open); LogToggle = $(if ($entries.Count) { if ($open) { 'Hide log' } else { 'Show log' } } else { '' })
        RetryVis = (ConvertTo-Vis ($status -eq 'failed' -and $Job.Spec -and $Job.Kind -ne 'test')); OpenVis = (ConvertTo-Vis ($status -eq 'succeeded' -and [bool]$row['Open'])); Icon = $jobIcon; MonoVis = (ConvertTo-Vis (-not $jobIcon))
    }
}

function Test-TaskRunning([string]$Kind) { @($script:Tasks | Where-Object { $_.Job.Kind -eq $Kind }).Count -gt 0 }

function Complete-UiTask($Task) {
    $job = $Task.Job
    try { [void]$Task.PS.EndInvoke($Task.Handle) }
    catch { $job.Log.Add(@{ Level = 'Error'; Text = $_.Exception.Message; Time = (Get-Date).ToString('HH:mm:ss') }) | Out-Null; $job.Status = 'failed'; $job.HadError = $true }
    $Task.PS.Dispose()
    $script:Tasks.Remove($Task)
    if (-not $job.Finished) { $job.Finished = Get-Date }
    Update-JobRow $job
    # The task may have renewed the token: the UI thread uses the same sign-in
    if ($script:Shared.Auth) { Set-PackTuneAuthState $script:Shared.Auth }
    $errors = @($job.Log.ToArray() | Where-Object Level -eq 'Error')
    foreach ($entry in @($job.Log.ToArray())) { Write-UiLog ("[{0}] {1}" -f $job.Display, $entry.Text) $entry.Level }
    if ($job.Status -eq 'failed' -and $job.Kind -notin 'meta', 'icons' -and -not ($job.Kind -in $script:GraphReadKinds -and @($errors | Where-Object { Test-GraphReadFailureText ([string]$_.Text) }).Count)) {
        Show-Toast ("{0}: {1}" -f $job.Display, $(if ($errors.Count) { $errors[-1].Text } else { 'failed' })) 'bad'
    }
    if ($job.Kind -in $script:GraphReadKinds) {
        # A read that hit the network (or an expired sign-in) must never look like an empty tenant: the module only warns and returns nothing
        $bad = @($job.Log.ToArray() | Where-Object { Test-GraphReadFailureText ([string]$_.Text) }) | Select-Object -First 1
        if ($bad) {
            if ($job.Status -eq 'succeeded') { $job.Status = 'failed'; $job.HadError = $true; Update-JobRow $job }
            Set-GraphDown ([string]$bad.Text)
        }
        elseif ($job.Status -eq 'succeeded') { Clear-GraphDown }
    }
    if ($Task.OnDone) {
        try { & $Task.OnDone $job.Result $job } catch { Show-Error $_.Exception.Message }
    }
    Update-Busy
}

function Update-Busy {
    $running = @($script:Tasks | Where-Object { -not $_.Hidden -and $_.Job.Status -in 'queued', 'running' })
    $ui.TxtBadgeActivity.Text = [string]$running.Count
    $ui.BadgeActivity.Visibility = ConvertTo-Vis ($running.Count -gt 0)
    $ui.BtnInstallModule.IsEnabled = -not (Test-TaskRunning 'components')
    Update-SignInButton
    Update-SelectionBar
    Update-TenantButtons
    # The readiness items show running steps ("Installing ...") instead of their button
    if ($script:CurrentPage -eq 'Start' -and ($running.Count -or $running.Count -ne $script:LastVisibleTasks)) { Update-Readiness }
    $script:LastVisibleTasks = $running.Count
}
$script:LastVisibleTasks = 0

function Update-SignInButton {
    # While the browser sign-in waits, the button cancels it; only the button that applies is enabled
    $connecting = (Test-TaskRunning 'connect') -or (Test-TaskRunning 'appreg')
    $signedIn = [bool]$script:Shared.Auth
    $ui.BtnSignIn.Content = if ($connecting) { 'Cancel sign-in' } else { 'Sign in' }
    $ui.BtnSignIn.IsEnabled = $connecting -or -not $signedIn
    $ui.BtnSignInMenu.IsEnabled = -not $connecting -and -not $signedIn
    $ui.PanelSignedOut.Visibility = ConvertTo-Vis (-not $signedIn)
    $ui.BtnAccount.Visibility = ConvertTo-Vis $signedIn
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Tick = 0
$timer.Add_Tick({
    try {
        $script:Tick++
        foreach ($task in @($script:Tasks)) {
            if ($task.Handle.IsCompleted) { Complete-UiTask $task } else { Update-JobRow $task.Job }
        }
        Update-Toasts
        if ($script:Tick % 8 -eq 0) { Step-GraphRetry }
        # App cards fill up while the feed lookups run
        if ($script:Refreshing -and $script:Tick % 4 -eq 0) { Update-RefreshButton }
        if ($script:Refreshing -and $script:Tick % 8 -eq 0 -and $script:CurrentPage -eq 'Apps') { Update-AppList -Reload }
        if ($script:MetaRefreshPending -and $script:Tick % 4 -eq 0) {
            $script:MetaRefreshPending = $false
            if ($script:CurrentPage -eq 'Apps') { Update-AppList }
            if (-not (Test-TaskRunning 'meta')) { Complete-MetaPrefetch }
        }
        if ($script:Tick % 240 -eq 0 -and $script:Shared.Auth) { Update-ConnectionStatus }
    }
    catch { Write-UiLog $_.Exception.Message 'Error' }
})

# ---------------------------------------------------------------- package infos (feed cache, 24 hours)
if (Test-Path $script:MetaCachePath) {
    try {
        $cache = Get-Content -Path $script:MetaCachePath -Raw | ConvertFrom-Json
        foreach ($property in $cache.PSObject.Properties) {
            if (([datetime]$property.Value.Fetched) -gt (Get-Date).AddHours(-$script:MetaCacheHours)) { $script:Shared.Meta[$property.Name] = $property.Value }
        }
    }
    catch { }
}

function Save-MetaCache {
    if (-not $script:MetaDirty) { return }
    try {
        $copy = @{}
        # A lookup that failed (offline, rate limit) is not remembered, only a real "not found"
        foreach ($key in @($script:Shared.Meta.Keys)) { $entry = $script:Shared.Meta[$key]; if ($entry.Found -or $entry.NotFound) { $copy[$key] = $entry } }
        New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null
        $copy | ConvertTo-Json -Depth 4 | Set-Content -Path $script:MetaCachePath -Encoding UTF8
        $script:MetaDirty = $false
    }
    catch { Write-UiLog "Feed cache could not be saved: $($_.Exception.Message)" 'Warning' }
}

# ---------------------------------------------------------------- icon previews
# WPF shows PNG, JPEG and ICO directly, but most Chocolatey icons are SVG: they are rendered once with headless Edge
# (the same conversion the deployment uses) into a PNG per icon URL and kept in the work folder.
$script:IconCacheDir = Join-Path $script:WorkRoot 'iconcache'
$script:IconsQueued = @{}

function Get-IconCacheFile([string]$Url) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') })
    Join-Path $script:IconCacheDir "$hash.png"
}

function Get-IconPreview([string]$Url) {
    # What the grid can show for an icon URL: the URL itself, a rendered PNG, or nothing (yet)
    # Plain strings only: WPF's image converter fails on a PSObject-wrapped string (as Join-Path returns it)
    if (-not $Url -or $Url -notmatch '^https?://') { return $null }
    if ($Url -notmatch '\.svg(\?|#|$)') { return [string]$Url }
    $file = [string](Get-IconCacheFile $Url)
    if (Test-Path $file) { return $file }
    return $null
}

$script:IconWork = @'
param($Items, $CacheDir)
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
$work = Join-Path $CacheDir 'render'
foreach ($item in $Items) {
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $download = Join-Path $work 'icon.svg'
        Invoke-WebRequest -Uri $item.Url -OutFile $download -UseBasicParsing -TimeoutSec 30
        $png = ConvertTo-PngBytes -Bytes ([IO.File]::ReadAllBytes($download)) -WorkPath $work
        [IO.File]::WriteAllBytes($item.File, $png)
    }
    catch {
        # Hidden task: failures go to a log in the cache folder (the package simply shows no icon in the list)
        Add-Content -Path (Join-Path $CacheDir 'failed.log') -Value ('{0:s}  {1}  {2}' -f (Get-Date), $item.Url, $_.Exception.Message)
    }
    finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
'@

function Start-IconRender {
    # One background task renders the missing SVG icons of all known packages, one after another
    if (@($script:Tasks | Where-Object { $_.Job.Kind -eq 'icons' }).Count -gt 0) { return }
    $items = foreach ($key in @($script:Shared.Meta.Keys)) {
        $url = [string]$script:Shared.Meta[$key].IconUrl
        if ($url -notmatch '^https?://.*\.svg(\?|#|$)' -or $script:IconsQueued.ContainsKey($url)) { continue }
        $file = Get-IconCacheFile $url
        if (Test-Path $file) { continue }
        $script:IconsQueued[$url] = $true
        @{ Url = $url; File = $file }
    }
    $items = @($items)
    if ($items.Count -eq 0) { return }
    [void](Start-UiTask -Kind 'icons' -Title 'Rendering SVG icons' -Work $script:IconWork -Arguments @{ Items = $items; CacheDir = $script:IconCacheDir } -Pool $script:MetaPool -Hidden -OnDone {
        if ($script:CurrentPage -eq 'Apps') { Update-AppList }
        Update-DetailIcon
        Start-IconRender   # packages that came in meanwhile
    })
}

# Package infos of both sources live in one cache: Chocolatey under the id, winget under "winget:<id>" (all lower case)
function Get-MetaKey([string]$Id, [string]$Source = 'Chocolatey') { Get-SourceCacheKey $Source $Id }

$script:MetaWork = @'
param($Items)
foreach ($Item in $Items) {
    $Id = $Item.Id; $Source = $Item.Source
    $Key = Get-SourceCacheKey $Source $Id
    try {
        $Info = if ($Source -eq 'Winget') { Get-WingetInfo -WingetId $Id } else { Get-ChocoInfo -ChocoName $Id }
        $Shared.Meta[$Key] = [pscustomobject]@{
            Fetched = (Get-Date).ToString('o'); Found = $true; Name = $Info.Name; Title = $Info.Title; Version = $Info.Version
            Summary = $Info.Summary; Description = $Info.Description; Authors = $Info.Authors; IconUrl = $Info.IconUrl
            ProjectUrl = $Info.SoftwareSite; LicenseUrl = $Info.SoftwareLicense; Downloads = $Info.Downloads; LicenseNote = $Info.LicenseNote
            License = $Info.License; Partial = $false
        }
    }
    catch {
        # "Not found" is an answer of the source; anything else (offline, rate limit) is tried again next time
        $Shared.Meta[$Key] = [pscustomobject]@{
            Fetched = (Get-Date).ToString('o'); Found = $false; NotFound = ($_.Exception.Message -like '*was not found*'); Name = $Id; Error = $_.Exception.Message
        }
    }
}
'@

function Test-MetaMissing([string]$Id, [string]$Source = 'Chocolatey') {
    $entry = $script:Shared.Meta[(Get-MetaKey $Id $Source)]
    return (-not $entry -or $entry.Partial -or (-not $entry.Found -and -not $entry.NotFound))
}

$script:MetaInFlight = @{}
$script:MetaRefreshPending = $false
function Start-MetaPrefetch {
    # Items: @{ Source = 'Chocolatey' | 'Winget'; Id = ... }. Reads what is not cached yet, three lookups in parallel.
    param([object[]]$Items, [switch]$Force)
    $missing = @($Items | Where-Object {
        $_ -and $_.Id -and -not $script:MetaInFlight.ContainsKey((Get-MetaKey $_.Id $_.Source)) -and ($_.Source -ne 'Winget' -or $script:ModuleState.Winget) -and ($Force -or (Test-MetaMissing $_.Id $_.Source))
    })
    if ($missing.Count -eq 0) { return }
    $script:MetaDirty = $true
    foreach ($item in $missing) { $script:MetaInFlight[(Get-MetaKey $item.Id $item.Source)] = $true }
    for ($i = 0; $i -lt 4; $i++) {
        $chunk = @(for ($j = $i; $j -lt $missing.Count; $j += 4) { @{ Source = $missing[$j].Source; Id = $missing[$j].Id } })
        if ($chunk.Count -gt 0) {
            [void](Start-UiTask -Kind 'meta' -Title 'Reading package infos' -Work $script:MetaWork -Arguments @{ Items = $chunk } -Pool $script:MetaPool -Hidden -OnDone {
                param($Result, $Job)
                foreach ($item in $Job.Spec.Arguments.Items) { $script:MetaInFlight.Remove((Get-MetaKey $item.Id $item.Source)) }
                $script:MetaRefreshPending = $true
            })
        }
    }
    Write-UiLog "Reading infos for $($missing.Count) packages from the Chocolatey feed and the winget source ..."
}

function Complete-MetaPrefetch {
    # All lookups are done: show the result, remember it, and say so when a source could not be reached
    Update-CatalogRows
    Update-AppList
    Update-TenantRows
    Update-DetailIcon
    Start-AppIconTask
    Save-MetaCache
    # The interface started while lookups were still running: the automatic refresh follows now
    if ($script:AutoRefreshPending -and -not (Test-TaskRunning 'popular')) { $script:AutoRefreshPending = $false; Start-AppsRefresh -Auto }
    Update-RefreshButton
    $failed = @($script:Shared.Meta.Values | Where-Object { -not $_.Found -and -not $_.NotFound })
    if ($failed.Count -gt 0 -and -not $script:MetaWarned) {
        $script:MetaWarned = $true
        Write-UiLog "Infos for $($failed.Count) package(s) could not be read ($($failed[0].Error)). Refresh in the Apps list tries again." 'Warning'
    }
    Start-IconRender
}
$script:MetaWarned = $false


# ---------------------------------------------------------------- module and connection state
function Get-ModuleState {
    $module = Get-Module -ListAvailable IntuneWin32App | Sort-Object Version -Descending | Select-Object -First 1
    $winget = Get-Module -ListAvailable Microsoft.WinGet.Client | Sort-Object Version -Descending | Select-Object -First 1
    [pscustomobject]@{
        Version       = $(if ($module) { $module.Version.ToString() } else { $null })
        Ok            = ($null -ne $module -and $module.Version -ge $script:MinimumModuleVersion)
        Winget        = ($null -ne $winget)
        WingetVersion = $(if ($winget) { $winget.Version.ToString() } else { $null })
    }
}

function Update-ModuleState {
    $script:ModuleState = Get-ModuleState
    $m = $script:ModuleState
    $intune = if ($m.Ok) { "IntuneWin32App $($m.Version) is installed (minimum $($script:MinimumModuleVersion)). It packages the .intunewin files and talks to Microsoft Graph." }
              elseif ($m.Version) { "IntuneWin32App $($m.Version) is installed, but $($script:MinimumModuleVersion) or newer is required: older versions break packaging and dependencies." }
              else { "The IntuneWin32App module is not installed." }
    $wingetText = if ($m.Winget) { "Microsoft.WinGet.Client $($m.WingetVersion) is installed (winget package infos and search)." }
                  else { "Microsoft.WinGet.Client is not installed; it is needed for winget packages only." }
    $ui.TxtModuleInfo.Text = "$intune`n$wingetText`nBoth are installed for the current user from the PowerShell Gallery (no admin rights needed)."
}

function Test-SignedIn { [bool]$script:Shared.Auth }

function Get-AccountInfo {
    $identity = if (Test-SignedIn) { Get-PackTuneIdentity } else { $null }
    if (-not $identity) { return $null }
    $name = if ($identity.Name) { [string]$identity.Name } elseif ($identity.Account) { [string]$identity.Account } else { 'Intune administrator' }
    $initials = (@($name -split '[\s@.]+' | Where-Object { $_ } | Select-Object -First 2 | ForEach-Object { $_.Substring(0, 1).ToUpper() }) -join '')
    [pscustomobject]@{ Name = $name; Account = [string]$identity.Account; Initials = $initials; Tenant = $(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { [string]$identity.TenantId }); ExpiresOn = $identity.ExpiresOn }
}

function Update-ConnectionStatus {
    $info = Get-AccountInfo
    if ($info) {
        $ui.TxtInitials.Text = $info.Initials
        $ui.TxtAccountName.Text = $info.Name
        $ui.TxtAccountTenant.Text = $info.Tenant
        $ui.BtnAccount.ToolTip = "$($info.Account), $($info.Tenant)"
        $script:AccountText = "$($info.Name) $($info.Account) $($info.Tenant)"
    }
    else { $script:AccountText = '' }
    Update-SignInButton
    $ui.BtnTenantRefresh.IsEnabled = (Test-SignedIn)
    Update-SelectionBar
    Update-Readiness
}
$script:AccountText = ''

# ---------------------------------------------------------------- navigation, dialogs, help
$script:Pages = @('Start', 'Apps', 'Custom', 'Tenant', 'Status', 'Activity', 'Settings')
$script:CurrentPage = 'Start'
function Measure-Ui([string]$Step, [scriptblock]$Do) {
    # Timing for the page switches: with PACKTUNE_TIMING set, every step is appended to timing.txt in that folder
    if (-not $env:PACKTUNE_TIMING) { & $Do; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Do
    Add-Content -Path (Join-Path $env:PACKTUNE_TIMING 'timing.txt') -Value ('{0,6} ms  {1}' -f $sw.ElapsedMilliseconds, $Step)
}
function Show-Page([string]$Name) {
    $pageWatch = [Diagnostics.Stopwatch]::StartNew()
    Close-Dialog
    $script:CurrentPage = $Name
    foreach ($p in $script:Pages) { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $navName = if ($Name -eq 'Status') { 'Tenant' } else { $Name }
    $ui["Nav$navName"].IsChecked = $true
    switch ($Name) {
        'Start'    { $script:SandboxState = $null; Update-Readiness; if (-not $script:StoreState) { Start-StoreCheck } }
        'Apps'     { if (-not $script:AppListBuilt) { Set-AppsLoading $true }; $script:PrefetchPending = $true; Update-AppList -Reload }
        'Custom'   { if ((Test-SignedIn) -and $null -eq $script:CustomApps) { Start-CustomRefresh } else { Update-CustomRows } }
        'Tenant'   { if ((Test-SignedIn) -and $null -eq $script:TenantApps -and -not (Test-TaskRunning 'tenant')) { Start-TenantRefresh } else { Update-TenantRows } }
        'Settings' { Update-SettingsView }
    }
    Update-SelectionBar
    if ($env:PACKTUNE_TIMING) { Add-Content -Path (Join-Path $env:PACKTUNE_TIMING 'timing.txt') -Value ('{0,6} ms  Show-Page {1} (total)' -f $pageWatch.ElapsedMilliseconds, $Name) }
}
foreach ($p in 'Start', 'Apps', 'Custom', 'Tenant', 'Activity', 'Settings') {
    $ui["Nav$p"].Add_Checked({
        param($src)
        $name = $src.Name -replace '^Nav', ''
        $current = if ($script:CurrentPage -eq 'Status') { 'Tenant' } else { $script:CurrentPage }
        if ($current -ne $name) { try { Show-Page $name } catch { Show-Error $_.Exception.Message } }
    })
}

$script:DialogWidths = @{}
function Update-DialogWidths {
    # Dialogs have a design width, but never more than the room in the window (scaling makes the window narrower for the layout)
    $room = [Math]::Max(320, $ui.RootGrid.ActualWidth - 56)
    foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgAddApp', 'DlgCustom', 'DlgStore', 'DlgHelp', 'DlgConfirm') {
        $el = $ui[$d]
        if (-not $script:DialogWidths.ContainsKey($d)) { $script:DialogWidths[$d] = $el.Width }
        $el.Width = [Math]::Min($script:DialogWidths[$d], $room)
    }
}
$ui.RootGrid.Add_SizeChanged({ try { Update-DialogWidths } catch { } })
function Show-Dialog([string]$Name) {
    Update-DialogWidths
    foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgAddApp', 'DlgCustom', 'DlgStore', 'DlgHelp') { $ui[$d].Visibility = if ($d -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $ui.DialogLayer.Visibility = 'Visible'
    $script:OpenDialog = $Name
}
function Close-Dialog {
    $ui.DialogLayer.Visibility = 'Collapsed'
    foreach ($d in 'DlgDeploy', 'DlgSchedule', 'DlgImport', 'DlgAddApp', 'DlgCustom', 'DlgStore', 'DlgHelp') { $ui[$d].Visibility = 'Collapsed' }
    $script:OpenDialog = $null
}
$script:OpenDialog = $null
$window.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -and $script:ConfirmFrame) { Complete-Confirm $false; $e.Handled = $true; return }; if ($e.Key -eq 'Escape' -and $script:OpenDialog) { Close-Dialog; $e.Handled = $true } })

$script:HelpTexts = @{
    Start    = @(
        @('What it does', 'Deploys Chocolatey or winget packages as Win32 apps to Microsoft Intune. Every app gets an install script that runs as SYSTEM, a detection rule and an update routine. Every app depends on one dependency app in the tenant, PackTune Runtime, created once: it puts Chocolatey and winget on the devices and keeps both up to date.'),
        @('Get ready', 'All items should be green before the first deployment. A red item says why and has the button that fixes it. Set up everything runs the fixes one after another: modules, app registration (one sign-in with a Global Administrator, admin consent included), sign-in, PackTune Runtime. The status report, the sandbox test and moving older apps to PackTune Runtime are optional.'),
        @('Sign in', 'Microsoft sign-in opens in your browser. The Sign in button at the top right is the only sign-in control; its arrow offers the web browser and the sign-in with an account from Keevault: you pick the account there, user name, password and one-time code are filled in, the passkey is confirmed in Keevault.'),
        @('Requirements', 'The IntuneWin32App module 1.5.0 or newer and an Entra ID app registration with redirect URI http://localhost. Chocolatey and winget are not needed on this computer.'))
    Apps     = @(
        @('One list', 'Chocolatey and winget packages in one list. Each card shows the version of every source and marks the source with the newer version as recommended. Type to filter, or search both repositories for apps that are not in the list.'),
        @('Sources', 'All sources shows everything, winget and Chocolatey the apps that only that source has, Both the apps that are available from both. Install with sets the source for apps without a recommendation; you can change it per app when you review.'),
        @('Deploy', 'Select apps, then Review and deploy: choose the source per app, the version, the assignment and how devices update. Deployments run one after another under Activity.'),
        @('Test in sandbox', 'The details panel tests one app in a fresh Windows Sandbox before it goes to Intune. Needs Windows Sandbox (the test lab is part of PackTune), no sign-in.'),
        @('License notes', 'Apps whose license restricts business use carry a Check license note. They are deployed only after a confirmation; the license is still yours to clear.'))
    Tenant   = @(
        @('In tenant', 'The apps this tool created in the tenant, from both sources, with the dependency app PackTune Runtime (and the two older dependency apps until you remove them). Everything is read from Intune; there is no local database.'),
        @('Update settings', 'Select an app: the panel on the right sets the version and how devices update (off, automatic per schedule, ask the user). Apply in Intune rebuilds the package and changes the app.'),
        @('Release an update', 'A pinned app whose package has a newer version shows a banner. Release moves devices to it. Apps that are only Available are updated through a new app that supersedes the old one; Required apps are changed in place.'),
        @('On devices', 'Click the counts to see the install status per device, with the cause of a failure and the log the device reports through the status script (Remediations).'))
    Activity = @(
        @('Activity', 'Every deployment, release and check that runs in the background. Show log reveals the messages, Retry starts a failed job again, Clear finished removes the done ones. Log files are written per day in the work folder.'))
    Settings = @(
        @('Tenant and app registration', 'The tenant (domain or ID) and the client ID of your app registration. Grant new permissions runs the app registration setup again (admin sign-in), which adds missing permissions and the admin consent. New permissions of the tool itself are confirmed at the next normal sign-in.'),
        @('Deployment defaults', 'What the deploy dialog starts with: assignment, preferred source, architecture, version and update mode. Schedule and conditions for new apps opens the schedule dialog.'),
        @('Package sources', 'The metadata feed is read on this computer. The package source is what choco uses on the devices (--source); the download URL is where the Chocolatey bootstrap gets its nupkg. Both empty = community repository. Chocolatey rate limits downloads from its community repository; for larger environments put an internal repository or caching proxy in front.'))
}
function Show-Help {
    $page = if ($script:CurrentPage -eq 'Status') { 'Tenant' } else { $script:CurrentPage }
    $ui.HelpTitle.Text = "Help: $page"
    $ui.HelpBody.Children.Clear()
    foreach ($entry in $script:HelpTexts[$page]) {
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $entry[0]; $l.FontWeight = 'SemiBold'; $l.Margin = '0,12,0,3'
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $entry[1]; $t.TextWrapping = 'Wrap'; $t.Foreground = Get-Brush 'Text2'
        [void]$ui.HelpBody.Children.Add($l); [void]$ui.HelpBody.Children.Add($t)
    }
    Show-Dialog 'DlgHelp'
}
Add-Click $ui.NavHelp { Show-Help }
Add-Click $ui.BtnHelpClose { Close-Dialog }

# ---------------------------------------------------------------- start page: readiness
$script:ReadinessActions = @{}
$script:RuntimeId = $null          # PackTune Runtime app: $null = not read yet, '' = not in the tenant
$script:SignInAfterRegistration = $false
$script:RuntimeInfo = $null        # Get-PackTuneRuntimeState: State Missing | Migrate | Ready, apps on the old dependency apps, unused old apps
$script:StatusScript = $null       # @{ State = 'Present' | 'Missing' | 'NotAvailable'; Id; Reason }

function New-ReadinessCard {
    param([int]$Number, [string]$Title, [ValidateSet('ok', 'warn', 'bad')][string]$State, [string]$Text, [string]$ActionText, [scriptblock]$Action, [bool]$Last, [bool]$Wait)
    # One row: state dot | title and text | action button (a running step: spinner in the dot)
    $border = New-Object System.Windows.Controls.Border
    $border.Padding = '16,14'; $border.BorderBrush = Get-Brush 'Divider'; $border.BorderThickness = $(if ($Last) { '0' } else { '0,0,0,1' })
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $c = New-Object System.Windows.Controls.ColumnDefinition
        $c.Width = if ($w -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        [void]$grid.ColumnDefinitions.Add($c)
    }
    $dot = New-Object System.Windows.Controls.Border
    $dot.Width = 26; $dot.Height = 26; $dot.CornerRadius = 13; $dot.Margin = '0,0,14,0'; $dot.VerticalAlignment = 'Center'
    $mark = New-Object System.Windows.Controls.TextBlock
    $mark.HorizontalAlignment = 'Center'; $mark.VerticalAlignment = 'Center'; $mark.FontWeight = 'Bold'; $mark.FontSize = 13
    switch ($State) {
        'ok'   { $dot.Background = Get-Brush 'SuccessBg'; $mark.Foreground = Get-Brush 'Success'; $mark.Text = [string][char]0x2713 }
        'warn' { $dot.Background = Get-Brush 'WarningBg'; $mark.Foreground = Get-Brush 'Warning'; $mark.Text = '!' }
        default { $dot.Background = Get-Brush 'Card'; $dot.BorderBrush = ConvertTo-Brush '#8A8A8A'; $dot.BorderThickness = 1.5; $mark.Foreground = Get-Brush 'MutedText'; $mark.Text = [string]$Number }
    }
    $dot.Child = if ($Wait) { New-Spinner 14 (Get-Brush 'Warning') } else { $mark }
    [void]$grid.Children.Add($dot)
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Title; $t.FontWeight = 'SemiBold'
    $s = New-Object System.Windows.Controls.TextBlock; $s.Text = $Text; $s.Style = $window.FindResource('Hint'); $s.FontSize = 13
    [void]$stack.Children.Add($t); [void]$stack.Children.Add($s)
    [System.Windows.Controls.Grid]::SetColumn($stack, 1)
    [void]$grid.Children.Add($stack)
    if ($ActionText -and $Action) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $ActionText; $b.Margin = '12,0,0,0'; $b.Padding = '16,6'; $b.MinWidth = 84; $b.VerticalAlignment = 'Center'
        $b.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "${ActionText}: $Title")
        $script:ReadinessActions[$b] = $Action
        $b.Add_Click({ param($src) try { & $script:ReadinessActions[$src] } catch { Show-Error $_.Exception.Message } })
        [System.Windows.Controls.Grid]::SetColumn($b, 2)
        [void]$grid.Children.Add($b)
    }
    $border.Child = $grid
    $border
}

function Get-MissingScopes {
    # Insight permissions the sign-in does not carry yet (Test-InsightReadiness); empty while signed out
    if (-not (Test-SignedIn) -or -not $Global:AccessToken -or -not $Global:AccessToken.Scopes) { return @() }
    $missing = @(Test-InsightReadiness -GrantedScopes @($Global:AccessToken.Scopes) | Where-Object { -not $_.Ready } | ForEach-Object { $_.Missing } | Select-Object -Unique)
    # The package store reads its site with Sites.Selected (confirmed in the sign-in, then granted to the one site by an administrator)
    if ($script:Settings.StoreSiteUrl -and @($Global:AccessToken.Scopes | Where-Object { $_ -like '*Sites.Selected' }).Count -eq 0) { $missing += 'Sites.Selected' }
    $missing
}

function Get-ReadinessItems {
    <#
    Everything the tool needs, in the order it is set up. Each item: state, the reason when it is not ok, and the fix
    (Key names the step for "Set up everything"; Wait = a task for it is running; Optional = not part of the setup).
    #>
    $m = $script:ModuleState
    $busyModules = Test-TaskRunning 'components'
    $busyAppReg = Test-TaskRunning 'appreg'
    $busyConnect = Test-TaskRunning 'connect'
    $busyDeps = Test-TaskRunning 'chocolatey'
    $moduleOk = $m.Ok -and $m.Winget
    $items = @(
        $(if ($moduleOk) { @{ Key = 'module'; Title = 'IntuneWin32App module'; State = 'ok'; Text = "Version $($m.Version) installed, with the winget client module." } }
          else { @{ Key = 'module'; Title = 'IntuneWin32App module'; State = 'bad'; Wait = $busyModules
                    Text = $(if ($busyModules) { 'Installing from the PowerShell Gallery ...' } elseif ($m.Version -and -not $m.Ok) { "Version $($m.Version) is installed, but $($script:MinimumModuleVersion) or newer is needed." } elseif (-not $m.Version) { 'Not installed. It packages the apps and talks to Intune; installed for your user, no admin rights needed.' } else { 'The winget client module is missing; winget package infos and search need it.' })
                    Fix = 'Install'; Action = { Start-ModuleInstall } } })
        $(if ($script:Settings.TenantID -and $script:Settings.ClientID) {
              $missing = @(Get-MissingScopes)
              if ($missing.Count) { @{ Key = 'appreg'; Title = 'App registration'; State = 'warn'; Wait = ($busyAppReg -or $busyConnect)
                    Text = $(if ($busyConnect) { 'Waiting for the sign-in ...' } else { "New permissions needed - you'll confirm them at your next sign-in ($($missing -join ', ')). An administrator sees the consent page in the sign-in window." })
                    Fix = 'Confirm now'; Action = { Connect-Intune -Consent } } }
              else { @{ Key = 'appreg'; Title = 'App registration'; State = 'ok'; Text = "$($script:Settings.TenantID), client ID $($script:Settings.ClientID)." } } }
          else { @{ Key = 'appreg'; Title = 'App registration'; State = 'bad'; Wait = $busyAppReg
                    Text = $(if ($busyAppReg) { 'Waiting for the administrator sign-in in your browser ...' } elseif (-not $script:Settings.ClientID) { "$(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'This tenant' }) has no app registration yet. Created with admin consent." } else { 'The tenant is missing (Settings).' })
                    Fix = $(if ($script:Settings.ClientID) { 'Settings' } else { 'Create' }); Action = $(if ($script:Settings.ClientID) { { Show-Page 'Settings' } } else { { Start-AppRegistration } }) } })
        $(if (Test-SignedIn) { @{ Key = 'signin'; Title = 'Signed in to Intune'; State = 'ok'; Text = $(if ($script:AccountText) { "Signed in as $((Get-AccountInfo).Account)" } else { 'Signed in' }) } }
          else { @{ Key = 'signin'; Title = 'Signed in to Intune'; State = 'bad'; Wait = $busyConnect
                    Text = $(if ($busyConnect) { 'Waiting for the sign-in ...' } else { 'Not signed in. Use Sign in at the top right.' })
                    Action = { Connect-Intune } } })
    )
    $depsText = 'PackTune Runtime puts Chocolatey and winget on the devices (for SYSTEM) and keeps both up to date. Created once per tenant; every app depends on it'
    $info = $script:RuntimeInfo
    $items += $(if (-not (Test-SignedIn)) { @{ Key = 'deps'; Title = 'Dependency app (PackTune Runtime)'; State = 'warn'; Text = $depsText } }
                elseif ($null -eq $info -and $script:GraphDown) {
                    @{ Key = 'tenant'; Title = 'Dependency app (PackTune Runtime)'; State = 'warn'; Text = "Can't check right now: $($script:GraphDown.Cause)"; Fix = 'Retry'; Action = { Invoke-GraphRetry } } }
                elseif ($null -eq $info) {
                    $reading = (Test-TaskRunning 'tenant') -or (Test-TaskRunning 'deps') -or $busyDeps
                    @{ Key = 'tenant'; Title = 'Dependency app (PackTune Runtime)'; State = 'warn'; Wait = $reading
                       Text = $(if ($busyDeps) { 'Deploying PackTune Runtime to Intune ...' } elseif ($reading) { 'Reading the apps in the tenant ...' } else { 'The apps in the tenant could not be read yet.' }); Fix = 'Check'; Action = { Start-TenantRefresh } } }
                elseif ($info.State -eq 'Missing') {
                    @{ Key = 'deps'; Title = 'Dependency app (PackTune Runtime)'; State = 'bad'; Wait = $busyDeps
                       Text = $(if ($busyDeps) { 'Deploying PackTune Runtime to Intune ...' } else { "Not in the tenant yet. $depsText." })
                       Fix = 'Create'; Action = { Start-DependencyDeploy } } }
                elseif ($info.State -eq 'Migrate') {
                    $n = @($script:WingetNoRuntime).Count
                    @{ Key = 'deps'; Title = 'Dependency app (PackTune Runtime)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'runtime')
                       Text = "PackTune Runtime is in the tenant. $n app$(if ($n -ne 1) { 's' }) still use$(if ($n -eq 1) { 's' }) the old dependency apps (Chocolatey, winget runtime): switch them over, nothing is removed."
                       Fix = 'Switch'; Action = { Start-RuntimeSwitch } } }
                else { @{ Key = 'deps'; Title = 'Dependency app (PackTune Runtime)'; State = 'ok'; Text = 'PackTune Runtime is in the tenant; every app depends on it.' } })
    $items += $(if (-not (Test-SignedIn)) { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Text = 'Devices report their update log to Intune, so failures show up under In tenant. Needs Remediations (Windows Enterprise E3/E5).' } }
                elseif ($script:GraphDown -and -not $script:StatusScript) { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Text = "Can't check right now: $($script:GraphDown.Cause)" } }
                elseif (-not $script:StatusScript) { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'statuscheck'); Text = 'Checking ...' } }
                elseif ($script:StatusScript.State -eq 'Present') { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'ok'; Optional = $true; Text = 'The status script is in Intune; devices report their update log hourly.' } }
                elseif ($script:StatusScript.State -eq 'NotAvailable') { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Text = "Not available in this tenant. The install status still works; the device log needs Remediations. $(Get-FriendlyCause $script:StatusScript.Reason)" } }
                else { @{ Key = 'status'; Title = 'Status report (optional)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'statusscript')
                          Text = 'Devices report their update log to Intune, so failures show up with their cause. Needs Remediations (Windows Enterprise E3/E5).'
                          Fix = 'Set up'; Action = { Start-StatusScriptSetup } } })
    $sb = Get-CachedSandboxState
    $busyInstall = Test-TaskRunning 'sandboxinstall'
    $items += $(
        if ($busyInstall) { @{ Key = 'sandbox'; Title = 'Sandbox test (optional)'; State = 'warn'; Optional = $true; Wait = $true; Text = 'Installing Windows Sandbox, waiting for the administrator approval ...' } }
        elseif ($sb.RestartPending) { @{ Key = 'sandbox'; Title = 'Sandbox test (optional)'; State = 'warn'; Optional = $true; Text = 'Windows Sandbox is installed: restart required. Restart Windows to finish.' } }
        elseif (-not $sb.Present -and -not $sb.Installable) { @{ Key = 'sandbox'; Title = 'Sandbox test (optional)'; State = 'warn'; Optional = $true; Text = "Windows Sandbox is not available on this computer. $($sb.Reason)" } }
        elseif (-not $sb.Present) { @{ Key = 'sandbox'; Title = 'Sandbox test (optional)'; State = 'warn'; Optional = $true
                                       Text = "Windows Sandbox is not installed. It tests an app in a throw-away Windows before it goes to Intune. Installing needs administrator approval and a restart.$(if ($sb.Reason) { ' ' + $sb.Reason })"
                                       Fix = 'Install'; Action = { Start-SandboxInstall } } }
        elseif ($sb.Toolchain -ne 'Ready') { @{ Key = 'sandbox'; Title = 'Sandbox test (optional)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'toolchain')
                                      Text = 'Windows Sandbox is ready for the Test buttons. Custom applications of type Other also need Microsoft''s capture tools (MSIX Packaging Tool, signing tools; about 150 MB). They are downloaded the first time they are needed, or now.'
                                      Fix = 'Download now'; Action = { Start-ToolchainDownload } } }
        else { @{ Key = 'sandbox'; Title = 'Sandbox test (optional)'; State = 'ok'; Optional = $true; Text = 'Windows Sandbox and the capture tools are ready for the Test buttons and custom applications.' } }
    )
    $items += Get-StoreReadinessItems
    $items
}

function Update-Readiness {
    if (-not $ui.ReadinessPanel) { return }
    $ui.ReadinessPanel.Children.Clear()
    $script:ReadinessActions.Clear()
    $items = @(Get-ReadinessItems)
    $n = 0
    foreach ($i in $items) {
        $n++
        $action = if ($i.State -ne 'ok' -and $i.Action -and -not $i.Wait) { $i.Action } else { $null }
        [void]$ui.ReadinessPanel.Children.Add((New-ReadinessCard $n $i.Title $i.State $i.Text $i.Fix $action ($n -eq $items.Count) ([bool]$i.Wait)))
    }
    $open = @($items | Where-Object { $_.State -ne 'ok' -and -not $_.Optional })
    $ui.TxtReadinessSummary.Text = if ($script:SetupRunning) { 'Setting up, step by step ...' }
                                   elseif ($open.Count -eq 0) { 'Everything is set up.' }
                                   else { "$($open.Count) of $(@($items | Where-Object { -not $_.Optional }).Count) not ready: $(($open | ForEach-Object { $_.Title }) -join ', ')." }
    $ui.BtnSetupAll.Visibility = ConvertTo-Vis ($open.Count -gt 0)
    $ui.TxtSetupNote.Visibility = ConvertTo-Vis ($open.Count -gt 0)
    $ready = (Test-SignedIn) -and -not $script:SetupRunning
    $ui.BtnSetupAll.IsEnabled = $ready
    $hint = if (Test-SignedIn) { 'About 2 minutes. Needs a Global Administrator once for the consent.' } elseif (-not $script:Settings.ClientID) { 'Please sign in - the app registration is created during sign-in.' } else { 'Please sign in.' }
    $ui.TxtSetupNote.Text = $hint; $ui.BtnSetupAll.ToolTip = $(if (Test-SignedIn) { $null } else { $hint })
}

# ---------------------------------------------------------------- set up everything
# Runs the fixes of the readiness items one after another; each task calls Complete-SetupStep when it is done.
$script:SetupRunning = $false
$script:SetupDone = @{}
function Start-SetupAll {
    $script:SetupRunning = $true
    $script:SetupDone = @{}
    Write-UiLog 'Setting up everything that is not ready yet ...'
    Step-Setup
}
function Stop-Setup([string]$Message, [string]$Level = 'Warning') {
    $script:SetupRunning = $false
    if ($Message) { Write-UiLog $Message $Level; Show-Toast $Message $(if ($Level -eq 'Success') { 'ok' } else { 'warn' }) }
    Update-Readiness
}
function Step-Setup {
    if (-not $script:SetupRunning) { return }
    $items = @(Get-ReadinessItems | Where-Object { -not $_.Optional })
    if (@($items | Where-Object Wait).Count) { Update-Readiness; return }   # a step is still running
    $next = $items | Where-Object { $_.State -ne 'ok' -and $_.Action } | Select-Object -First 1
    if (-not $next) {
        if (@($items | Where-Object { $_.State -ne 'ok' }).Count) { Stop-Setup 'Set up stopped: an item is left that has no automatic fix.' }
        else { Stop-Setup 'Everything is set up.' 'Success' }
        return
    }
    if ($script:SetupDone[$next.Key]) { Stop-Setup "Set up stopped at '$($next.Title)': $($next.Text)"; return }   # tried once, it did not help
    $script:SetupDone[$next.Key] = $true
    try { & $next.Action } catch { Stop-Setup "Set up stopped at '$($next.Title)': $($_.Exception.Message)"; return }
    Update-Readiness
    if (-not @(Get-ReadinessItems | Where-Object Wait).Count) { Step-Setup }   # the fix was immediate
}
function Complete-SetupStep([bool]$Ok, [string]$What) {
    if (-not $script:SetupRunning) { Update-Readiness; return }
    if (-not $Ok) { Stop-Setup "Set up stopped: $What did not work, see the messages under Activity."; return }
    Step-Setup
}
Add-Click $ui.BtnSetupAll { Start-SetupAll }

function Start-AppRegistration {
    if (Test-TaskRunning 'appreg') { return }
    if (Test-TaskRunning 'connect') { throw 'A sign-in is waiting in the browser. Finish or cancel it first.' }
    $script:Shared.CancelSignIn = $false
    # The setup sign-in (Microsoft Graph Command Line Tools app, admin consent) in the window of this app; the browser as fallback
    $setupToken = $null
    try {
        $setupToken = Get-EmbeddedToken -TenantID $(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'organizations' }) -ClientID '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Scopes @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'User.Read') -Hint 'Sign in with an administrator account: this creates the app registration and grants the admin consent.'
    }
    catch {
        if ($_.Exception.Message -ne 'Sign-in cancelled.') { Show-Error $_.Exception.Message } else { Show-SignInCancelled }
        $script:SignInAfterRegistration = $false; Complete-SetupStep $false 'creating the app registration'
        return
    }
    $script:LastSignInPath = if ($setupToken) { 'embedded' } else { 'browser' }
    $work = @'
param($TenantID, $Authority, $UrlHandler, $GraphUrl, $Token)
$Params = @{ ShouldCancel = { $Shared.CancelSignIn } }
if ($TenantID) { $Params.TenantID = $TenantID }
if ($Authority) { $Params.Authority = $Authority }
if ($GraphUrl) { $Params.GraphUrl = $GraphUrl }
if ($Token) { $Params.Token = $Token }
if ($UrlHandler) { $Params.UrlHandler = [scriptblock]::Create($UrlHandler) }
New-PackTuneAppRegistration @Params
'@
    $arguments = @{ TenantID = $script:Settings.TenantID; Authority = $script:SignInTest.Authority; UrlHandler = $script:SignInTest.UrlHandler; GraphUrl = $script:SignInTest.GraphUrl; Token = $setupToken }
    [void](Start-UiTask -Kind 'appreg' -Title 'Creating the app registration with admin consent' -Display 'App registration' -Pool $script:UserPool -Work $work -Arguments $arguments -OnDone {
        param($Result, $Job)
        $reg = @($Result | Where-Object { $_ -and $_.ClientID }) | Select-Object -First 1
        if ($Job.Status -eq 'succeeded' -and $reg) {
            $s = Get-PackTuneSettings; $s.TenantID = $reg.TenantID; $s.ClientID = $reg.ClientID
            [void](Save-PackTuneSettings -Settings $s); $script:Settings = Get-PackTuneSettings
            Update-SettingsView
            Write-UiLog "App registration ready: tenant $($reg.TenantID), client ID $($reg.ClientID). Saved in the settings." 'Success'
            Show-Toast 'App registration is ready, with admin consent.' 'ok'
            Update-ConnectionStatus
            Complete-SetupStep $true
            if ($script:SignInAfterRegistration) { $script:SignInAfterRegistration = $false; if (-not (Test-SignedIn)) { try { Connect-Intune } catch { Show-Error $_.Exception.Message } } }
        }
        else { $script:SignInAfterRegistration = $false; Update-ConnectionStatus; Complete-SetupStep $false 'creating the app registration' }
    })
    Update-SignInButton
    Update-Readiness
}

function Start-DependencyDeploy {
    if ($script:GraphDown) { throw "Can't check the tenant right now ($($script:GraphDown.Cause)). PackTune Runtime is not created from a failed read." }
    # Chocolatey app and winget runtime app, once per tenant (each is created only when it is missing)
    if (Test-TaskRunning 'chocolatey') { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'chocolatey' -Title 'Deploying the PackTune Runtime to Intune' -Display 'PackTune Runtime' -NeedsAuth -Work 'Get-PackTuneRuntimeWin32ID | Out-Null' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') { Write-UiLog 'The PackTune Runtime is in the tenant.' 'Success'; Show-Toast 'PackTune Runtime is in the tenant.' 'ok' }
        $script:TenantApps = $null; $script:RuntimeId = $null; $script:RuntimeInfo = $null
        if ($Job.Status -eq 'succeeded') { Start-TenantRefresh } else { Update-Readiness; Complete-SetupStep $false 'deploying the dependency apps' }
    })
    Update-Readiness
}

function Start-StatusScriptSetup {
    if (Test-TaskRunning 'statusscript') { return }
    Update-UiToken
    $work = 'param($Fake) $Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }; Set-InsightStatusScript -Context $Ctx'
    [void](Start-UiTask -Kind 'statusscript' -Title 'Setting up the status script (Remediations) in Intune' -Display 'Status report' -NeedsAuth -Arguments @{ Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $null -ne $_.Created }) | Select-Object -First 1
        if ($r -and $r.Created) { Show-Toast "Status report: $($r.Message)." 'ok' } elseif ($r) { Write-UiLog "Status report: $($r.Message)" 'Warning'; Show-Toast (Get-FriendlyCause $r.Message) 'warn' 'Details' { Show-Page 'Activity' } }
        $script:StatusScript = $null
        Start-StatusCheck
        Update-Readiness
    })
    Update-Readiness
}

function Start-StatusCheck {
    # Is the status script there, and does the tenant allow it (hidden)
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'statuscheck') -or $script:StatusScript) { return }
    $work = @'
param($Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
$Avail = Test-InsightRemediationsAvailable -Context $Ctx
$State = if ($Avail.Available) { try { Get-InsightStatusScriptState -Context $Ctx } catch { $null } } else { $null }
[pscustomobject]@{ Available = $Avail.Available; Reason = $Avail.Reason; Id = $(if ($State) { $State.id } else { $null }) }
'@
    [void](Start-UiTask -Kind 'statuscheck' -Title 'Checking the status script' -Hidden -Arguments @{ Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $null -ne $_.Available }) | Select-Object -First 1
        if ($r -and -not $r.Available -and -not (Test-GraphClientError ([string]$r.Reason)) -and ([string]$r.Reason -match '(?i)remote|network|netzwerk|timed out|timeout|resolved|\b50[0234]\b')) { Set-GraphDown ([string]$r.Reason); $script:StatusScript = $null; Update-Readiness; return }
        if ($Job.Status -ne 'succeeded' -or -not $r) { $script:StatusScript = @{ State = 'NotAvailable'; Id = $null; Reason = 'It could not be checked.' } }
        else { $script:StatusScript = @{ State = $(if (-not $r.Available) { 'NotAvailable' } elseif ($r.Id) { 'Present' } else { 'Missing' }); Id = $r.Id; Reason = $r.Reason }; if (-not $r.Available) { Write-UiLog "Status report check: $($r.Reason)" 'Warning' } }
        Update-Readiness
        if ($script:CurrentPage -eq 'Status') { Update-StatusBanner }
    })
}

function Start-DependencyCheck {
    # PackTune Runtime state (Missing / Migrate / Ready), the apps on the old dependency apps and the old apps nothing uses (hidden)
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'deps')) { return }
    [void](Start-UiTask -Kind 'deps' -Title 'Checking PackTune Runtime' -Hidden -NeedsAuth -Work 'Get-PackTuneRuntimeState' -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['State'] }) | Select-Object -First 1
        if ($Job.Status -eq 'succeeded' -and $r) {
            $script:RuntimeInfo = $r
            $script:RuntimeId = [string]$r.RuntimeId
            $script:WingetNoRuntime = @(@($r.AppsOnOldDependencies) + @($r.AppsWithoutRuntime) | Where-Object { $_ } | Group-Object Id | ForEach-Object { $_.Group[0] })
        }
        elseif (-not $script:GraphDown) { $script:RuntimeInfo = $null; $script:RuntimeId = $null }   # a failed read keeps what was known
        Start-AppIconTask
        Update-TenantRows
        Update-Readiness
        Complete-SetupStep ($Job.Status -eq 'succeeded') 'reading the tenant'
    })
}


# ---------------------------------------------------------------- apps: one list for both sources
$script:Catalog = @(Get-PackTuneCatalog)
$script:Preferred = if ($script:Settings.Source -eq 'Winget') { 'Winget' } else { 'Chocolatey' }
$script:Selected = [ordered]@{}      # app key -> source row (Get-PackTuneSourceApps)
$script:SourceChoice = @{}           # app key -> 'Chocolatey' | 'Winget' chosen in the deploy dialog
$script:CustomIcons = @{}            # app key -> PNG/JPEG base64
$script:SourceRows = @()             # the curated catalog
$script:MyRows = @()                 # apps the user added (my-apps.json)
$script:PopularRows = @()            # the top Chocolatey packages by downloads that the catalog does not have
$script:PopularLoaded = $false
$script:PopularCachePath = Join-Path $script:WorkRoot 'popular.json'
$script:SearchRows = @()             # hits of the last repository search
$script:SearchTerm = ''
$script:SourceFilter = 'All'
$script:Category = 'All'
$script:DetailRow = $null
$script:CardRows = @{}
$script:CardKeys = ''
$script:TenantApps = $null
$script:TenantPackages = @{}         # meta key of the apps already in the tenant
$script:RecentDeploys = @{}          # meta key -> time it was created by this window
$script:CardCollection = New-Object System.Collections.ObjectModel.ObservableCollection[object]

function Get-AppKey($Row) {
    if ($Row.CatalogId) { return ([string]$Row.CatalogId).ToLower() }
    if ($Row.ChocoId) { return ('choco:' + $Row.ChocoId).ToLower() }
    return ('winget:' + $Row.WingetId).ToLower()
}
function Get-AppId($Row, [string]$Source) { if ($Source -eq 'Winget') { $Row.WingetId } else { $Row.ChocoId } }
function Get-AppSource($Row, [string]$Prefer = $script:Preferred) {
    if ($script:SourceChoice.ContainsKey((Get-AppKey $Row)) -and $script:SourceChoice[(Get-AppKey $Row)] -in $Row.Sources) { return $script:SourceChoice[(Get-AppKey $Row)] }
    Get-PackTuneDefaultSource -Row $Row -Preferred $Prefer
}
function Get-AppMeta($Row, [string]$Source) {
    $id = Get-AppId $Row $Source
    if ($id) { $script:Shared.Meta[(Get-MetaKey $id $Source)] }
}
function Get-SourceLabel([string]$Source) { if ($Source -eq 'Winget') { 'winget' } else { 'Chocolatey' } }

function Update-CatalogRows {
    $script:SourceRows = @(Get-PackTuneSourceApps -Cache $script:Shared.Meta -NoFetch)
    $script:MyRows = @(Get-PackTuneMyAppRows -Cache $script:Shared.Meta -NoFetch)
}

function New-TagRow([string]$Text, [string]$Kind) {
    switch ($Kind) {
        'rec'    { New-Row @{ Text = $Text; Bg = '#005FB8'; Line = '#005FB8'; Fg = '#FFFFFF' } }
        'recsrc' { New-Row @{ Text = $Text; Bg = '#E8F1FB'; Line = '#005FB8'; Fg = '#003E92' } }
        default  { New-Row @{ Text = $Text; Bg = '#FFFFFF'; Line = '#D1D1D1'; Fg = '#3B3B3B' } }
    }
}

function Get-AppIconUrl($Src) {
    # The icon of an app in the list: from the package infos of either source (same for cards, deploy dialog, details)
    foreach ($source in 'Chocolatey', 'Winget') {
        $meta = Get-AppMeta $Src $source
        if ($meta -and $meta.Found -and $meta.IconUrl) { $p = Get-IconPreview ([string]$meta.IconUrl); if ($p) { return [string]$p } }
    }
}

function Set-CardRow($Card, $Src) {
    $key = Get-AppKey $Src
    $tags = New-Object System.Collections.ArrayList
    foreach ($source in 'Winget', 'Chocolatey') {
        if ($Src.Sources -notcontains $source) { continue }
        $version = if ($source -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
        $label = if ($source -eq 'Winget') { 'winget' } else { 'Choco' }
        $rec = $Src.RecommendedMarked -and $Src.Recommended -eq $source
        [void]$tags.Add((New-TagRow ("$label $version").Trim() $(if ($rec) { 'recsrc' } else { 'plain' })))
        if ($rec) { [void]$tags.Add((New-TagRow 'Recommended' 'rec')) }
    }
    $inTenant = (@($Src.Sources | Where-Object { $id = Get-AppId $Src $_; $id -and $script:TenantPackages.ContainsKey((Get-MetaKey $id $_)) }).Count -gt 0)
    $note = @($Src.Sources | ForEach-Object { $id = Get-AppId $Src $_; $meta = Get-AppMeta $Src $_; if ($meta -and $meta.LicenseNote) { $meta.LicenseNote } else { Get-ChocoLicenseNote $id } } | Where-Object { $_ }) | Select-Object -First 1
    $badge, $kind = if ($inTenant) { 'In tenant', 'ok' } elseif ($note) { 'Check license', 'warn' } else { '', 'ok' }
    $iconUrl = Get-AppIconUrl $Src
    $custom = $script:CustomIcons[$key]
    Set-Row $Card (@{
        Data = $Src; Title = $Src.Name; Items = $tags.ToArray(); Selected = [bool]$script:Selected.Contains($key)
        Badge = $badge; BadgeVis = (ConvertTo-Vis ([bool]$badge)); BadgeBg = $script:PillColors[$kind][0]; BadgeFg = $script:PillColors[$kind][1]
        Icon = $iconUrl; MonoVis = (ConvertTo-Vis (-not $iconUrl)); License = $note; InTenant = $inTenant
    } + (Get-TileStyle $Src.Name))
}

function Get-AppListRows {
    # Phase 1: the apps of the current view in display order (merge of the lists, source filter, text filter, chips, category, sort)
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in @($script:SourceRows) + @($script:MyRows) + @($script:PopularRows) + @($script:SearchRows)) { $k = Get-AppKey $r; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$rows.Add($r) } }
    $rows = @(Select-PackTuneSourceApps -Apps @($rows) -Filter $script:SourceFilter)
    $text = $ui.TxtFilter.Text.Trim()
    $searching = $script:SearchTerm -and $script:SearchTerm -eq $text
    $rows = @($rows | Where-Object {
        if (-not $text) { return $true }
        if ($searching -and $script:SearchKeys.ContainsKey((Get-AppKey $_))) { return $true }
        $_.Name -like "*$text*" -or $_.ChocoId -like "*$text*" -or $_.WingetId -like "*$text*"
    })
    Update-Chips $rows
    if ($script:Category -eq 'Popular') { $rows = @($rows | Where-Object { $_.Popular }) }
    elseif ($script:Category -eq 'My apps') { $rows = @($rows | Where-Object { $_.Mine }) }
    elseif ($script:Category -ne 'All') { $rows = @($rows | Where-Object { $_.Category -eq $script:Category }) }
    if ($script:SortMode -eq 'Downloads') { $rows = @($rows | Sort-Object -Property @{ Expression = { Get-AppDownloads $_ }; Descending = $true }, @{ Expression = { $_.Name } }) }
    return @($rows)
}

# The grid shows LINES of cards in a virtualizing list: only the lines on screen exist as visuals (a window of ~300 cards at once
# took seconds to lay out). The flat card list stays the model (CardCollection); the lines are what the interface binds to.
$script:AppListSync = $false         # tests: build everything at once instead of in time slices
$script:AppListGen = 0               # raised by every request: a build in progress starts over
$script:AppListJob = $null
$script:AppListBuilt = $false
$script:CatalogDirty = $false
$script:PrefetchPending = $false
$script:CardColumns = 3
$script:CardLines = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.CardList.ItemsSource = $script:CardLines

function Add-CardLine($Cards) {
    $line = New-Object PackTune.Row
    $line.Items = @($Cards)
    $line['Cols'] = [string]$script:CardColumns
    [void]$script:CardLines.Add($line)
}
function Sync-CardLines {
    # All lines again from the card list (the number of cards per line changed)
    $script:CardLines.Clear()
    $all = @($script:CardCollection)
    for ($i = 0; $i -lt $all.Count; $i += $script:CardColumns) { Add-CardLine @($all[$i..([Math]::Min($i + $script:CardColumns, $all.Count) - 1)]) }
}
function Set-AppsLoading([bool]$On, [string]$Text = 'Loading apps ...') {
    $ui.AppsLoading.Visibility = ConvertTo-Vis $On
    if ($On) { $ui.TxtAppsLoading.Text = $Text }
}

function Step-AppList($Job, [int]$BudgetMs) {
    # One time slice of a build; true when the list is complete. Phase 1 (rows) is one slice, then cards in batches within the budget.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $Job.Rows) {
        if ($script:CatalogDirty) { $script:CatalogDirty = $false; Update-CatalogRows }
        $Job.Rows = @(Get-AppListRows)
        $Job.Keys = ($Job.Rows | ForEach-Object { Get-AppKey $_ }) -join '|'
        $Job.Index = 0
        $Job.Pending = New-Object System.Collections.ArrayList
        $Job.Changed = $Job.Keys -ne $script:CardKeys
        if ($Job.Changed) {
            # The marker keeps a build that is cut short from passing as the finished list
            $script:CardKeys = '<building>'
            $script:CardCollection.Clear(); $script:CardLines.Clear()
        }
        if (-not $script:AppListSync -and $Job.Rows.Count -gt 0 -and $script:CardLines.Count -eq 0) { Set-AppsLoading $true }
        if ($env:PACKTUNE_TIMING) { Add-Content (Join-Path $env:PACKTUNE_TIMING 'timing.txt') ('{0,6} ms    list: rows ({1}) incl. chips' -f $sw.ElapsedMilliseconds, $Job.Rows.Count) }
        if (-not $script:AppListSync) { return $false }
    }
    while ($Job.Index -lt $Job.Rows.Count) {
        $r = $Job.Rows[$Job.Index]; $Job.Index++
        $k = Get-AppKey $r
        if (-not $script:CardRows.ContainsKey($k)) { $script:CardRows[$k] = New-Object PackTune.Row }
        $card = $script:CardRows[$k]
        [void](Set-CardRow $card $r)
        if ($Job.Changed) {
            $script:CardCollection.Add($card)
            [void]$Job.Pending.Add($card)
            if ($Job.Pending.Count -ge $script:CardColumns) { Add-CardLine $Job.Pending; $Job.Pending.Clear(); Set-AppsLoading $false }
        }
        if ($sw.ElapsedMilliseconds -ge $BudgetMs) {
            if (-not $script:AppListSync) { $ui.TxtAppsCount.Text = "Loading apps $($Job.Index)/$($Job.Rows.Count) ..." }
            return $false
        }
    }
    if ($Job.Changed -and $Job.Pending.Count) { Add-CardLine $Job.Pending; $Job.Pending.Clear() }
    $script:CardKeys = $Job.Keys
    $script:AppListBuilt = $true
    Set-AppsLoading $false
    $cards = $Job.Rows.Count
    $filterText = $ui.TxtFilter.Text.Trim()
    $searching = $script:SearchTerm -and $script:SearchTerm -eq $filterText
    $ui.TxtAppsCount.Text = "$cards shown" + $(if (Get-RefreshProgress) { ', ' + (Get-RefreshProgress) } elseif (Test-TaskRunning 'popular') { ', popular apps loading' } elseif (Test-TaskRunning 'meta') { ', versions still loading' } elseif ($searching) { ", $(@($script:SearchRows).Count) from the repositories" } else { '' })
    $curated = $script:SourceRows.Count
    $ui.TxtAppsSubtitle.Text = "$curated curated apps$(if (@($script:PopularRows).Count) { " and the $(@($script:PopularRows).Count) most popular Chocolatey packages" }) from winget and Chocolatey in one list. Type to filter, or search both repositories."
    if ($script:DetailRow) { Show-AppDetails $script:DetailRow -Keep }
    if ($script:PrefetchPending) { $script:PrefetchPending = $false; Start-CatalogPrefetch }
    if ($env:PACKTUNE_TIMING) { Add-Content (Join-Path $env:PACKTUNE_TIMING 'timing.txt') ('{0,6} ms    list: complete ({1} cards, {2} lines)' -f ([int]((Get-Date) - $Job.Started).TotalMilliseconds), $cards, $script:CardLines.Count) }
    return $true
}

$script:AppListTimer = New-Object System.Windows.Threading.DispatcherTimer ([System.Windows.Threading.DispatcherPriority]::Background)
$script:AppListTimer.Interval = [TimeSpan]::FromMilliseconds(10)
$script:AppListTimer.Add_Tick({
    try {
        $job = $script:AppListJob
        if (-not $job -or $job.Gen -ne $script:AppListGen) { $job = $script:AppListJob = @{ Gen = $script:AppListGen; Rows = $null; Started = Get-Date } }
        if ((Step-AppList $job 30) -eq $true) { $script:AppListTimer.Stop(); $script:AppListJob = $null }
    }
    catch { $script:AppListTimer.Stop(); $script:AppListJob = $null; Set-AppsLoading $false; if ($env:PACKTUNE_TIMING) { Add-Content (Join-Path $env:PACKTUNE_TIMING 'timing.txt') ("ERROR in the list build: " + $_.Exception.Message + " @ " + $_.InvocationInfo.ScriptLineNumber) }; Show-Error $_.Exception.Message }
})

function Update-AppList {
    # Rebuilds the card list. In the interface it runs in time slices at background priority (the window stays usable, the
    # lines appear as they are ready); a new request starts over. -Reload reads the catalog rows again first.
    param([switch]$Reload)
    if ($Reload) { $script:CatalogDirty = $true }
    $script:AppListGen++
    if ($script:AppListSync) {
        $job = @{ Gen = $script:AppListGen; Rows = $null; Started = Get-Date }
        while ((Step-AppList $job 1000000) -ne $true) { }
        $script:AppListJob = $null
        return
    }
    $script:AppListJob = $null
    if (-not $script:AppListTimer.IsEnabled) { $script:AppListTimer.Start() }
}
$script:SearchKeys = @{}

$script:Chips = @{}
function Update-Chips($Rows) {
    # Category chips with the number of apps each one has in the current view; built once, counted on every change
    $cats = @($script:Catalog | ForEach-Object { $_.Category } | Where-Object { $_ } | Sort-Object -Unique)
    $cats = @('Popular', 'My apps') + $cats + @('Other')
    if ($script:Chips.Count -eq 0) {
        foreach ($cat in @('All') + $cats) {
            $chip = New-Object System.Windows.Controls.RadioButton
            $chip.Style = $window.FindResource('ChipItem'); $chip.GroupName = 'Chips'; $chip.Tag = $cat; $chip.IsChecked = ($cat -eq $script:Category)
            $chip.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "Category $cat")
            $chip.Add_Checked({ param($s) if ($script:Category -ne $s.Tag) { $script:Category = [string]$s.Tag; try { Update-AppList } catch { Show-Error $_.Exception.Message } } })
            $script:Chips[$cat] = $chip
            [void]$ui.PanelChips.Children.Add($chip)
        }
    }
    foreach ($cat in $script:Chips.Keys) {
        $count = if ($cat -eq 'All') { @($Rows).Count } elseif ($cat -eq 'Popular') { @($Rows | Where-Object { $_.Popular }).Count } elseif ($cat -eq 'My apps') { @($Rows | Where-Object { $_.Mine }).Count } else { @($Rows | Where-Object { $_.Category -eq $cat }).Count }
        $script:Chips[$cat].Content = "$cat  $count"
    }
}

function Get-RefreshItems {
    # Every listed app that needs a package lookup: the curated catalog and my apps (the popular list brings its own
    # versions with the one feed query, no lookup per package). -OlderThan leaves out infos read just now.
    param($OlderThan)
    $items = New-Object System.Collections.ArrayList
    foreach ($e in $script:Catalog) {
        if ($e.Id) { [void]$items.Add(@{ Source = 'Chocolatey'; Id = $e.Id }) }
        if ($e.WingetId) { [void]$items.Add(@{ Source = 'Winget'; Id = $e.WingetId }) }
    }
    foreach ($a in @(Get-PackTuneMyApps)) {
        if ($a.ChocoId) { [void]$items.Add(@{ Source = 'Chocolatey'; Id = $a.ChocoId }) }
        if ($a.WingetId) { [void]$items.Add(@{ Source = 'Winget'; Id = $a.WingetId }) }
    }
    $list = @($items | Where-Object { $_.Source -ne 'Winget' -or $script:ModuleState.Winget })
    if ($null -ne $OlderThan) {
        $list = @($list | Where-Object { $m = $script:Shared.Meta[(Get-MetaKey $_.Id $_.Source)]; -not ($m -and $m.Fetched -and ([datetime]$m.Fetched) -ge $OlderThan) })
    }
    if ($script:RefreshItemLimit -gt 0) { $list = @($list | Select-Object -First $script:RefreshItemLimit) }   # tests only
    return $list
}
$script:RefreshItemLimit = 0
function Start-CatalogPrefetch {
    param([switch]$Force)
    Start-MetaPrefetch -Items @(Get-RefreshItems) -Force:$Force
}
$script:PopularWork = @'
param($Force, $Stale, $Path, $Fixture)
$Params = @{ CachePath = $Path; Cache = $Shared.Meta; Force = [bool]$Force; AllowStale = [bool]$Stale }
# Test hook: a file with feed packages instead of the community feed
if ($Fixture -and (Test-Path -LiteralPath $Fixture)) { $Params.FeedPackages = @(Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json) }
Get-PackTunePopularApps @Params
'@
$script:Refreshing = $false
$script:RefreshStart = $null
$script:RefreshKeys = @()
$script:AutoRefreshPending = $false
function Get-RefreshProgress {
    # "Updating versions 120/290" while a refresh runs (infos read since it started, plus the popular list when it is in)
    if (-not $script:Refreshing) { return $null }
    $done = 0
    foreach ($k in $script:RefreshKeys) { $m = $script:Shared.Meta[$k]; if ($m -and $m.Fetched -and ([datetime]$m.Fetched) -ge $script:RefreshStart) { $done++ } }
    $pop = @($script:PopularRows).Count
    if (-not (Test-TaskRunning 'popular')) { $done += $pop }
    "Updating versions $done/$($script:RefreshKeys.Count + $pop)"
}
function Update-RefreshButton {
    $busy = (Test-TaskRunning 'popular') -or (Test-TaskRunning 'meta')
    $ui.BtnRefreshApps.IsEnabled = -not $busy
    Set-ButtonBusy $ui.BtnRefreshApps ([bool]($busy -and $script:Refreshing)) 'Refreshing ...'
    if (-not $busy -and $script:Refreshing) {
        # A full refresh is done: the next automatic one waits an hour (the Chocolatey feed limits the requests)
        $script:Refreshing = $false
        try { Set-PackTuneRefreshStamp } catch { }
        Update-CatalogRows
        Update-AppList
    }
}
function Start-PopularLoad {
    # The top Chocolatey packages by downloads (24 hour cache; -AllowStale shows an older cache at once; -Force reads the
    # feed now), merged into the app list
    param([switch]$Force, [switch]$AllowStale)
    if (Test-TaskRunning 'popular') { return }
    [void](Start-UiTask -Kind 'popular' -Title 'Reading the popular apps' -Display 'Popular apps' -Pool $script:UserPool -Hidden -Arguments @{ Force = [bool]$Force; Stale = [bool]$AllowStale; Path = $script:PopularCachePath; Fixture = $env:PACKTUNE_POPULAR_FIXTURE } -Work $script:PopularWork -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'failed') { Write-UiLog 'The popular apps could not be read, the curated list stays (see Activity).' 'Warning' }
        else {
            $script:PopularRows = @($Result | Where-Object { $_ -and $_.ChocoId -and $_.Popular })
            $script:PopularLoaded = $true
            Write-UiLog "Popular apps: $(@($script:PopularRows).Count) packages, $(@($script:PopularRows | Where-Object { $_.WingetId }).Count) with a verified winget package."
        }
        $script:MetaDirty = $true
        Update-AppList
        Start-AppIconTask
        Save-MetaCache
        Start-IconRender
        # Start of the interface: the list is on screen from the cache, now the versions are refreshed in the background
        if ($script:AutoRefreshPending -and -not (Test-TaskRunning 'meta')) { $script:AutoRefreshPending = $false; Start-AppsRefresh -Auto }
        Update-RefreshButton
    })
    Update-AppList
}
function Start-AppsRefresh {
    # Refresh versions: the package infos of all listed apps and the popular list, read again now (no cache). With -Auto
    # (start of the interface) what was read a moment ago is left out. The feed retries with a wait when it limits the requests.
    param([switch]$Auto)
    if ((Test-TaskRunning 'popular') -or (Test-TaskRunning 'meta')) { return }
    $script:Refreshing = $true
    $script:RefreshStart = Get-Date
    $script:MetaWarned = $false
    $items = @(Get-RefreshItems -OlderThan $(if ($Auto) { (Get-Date).AddMinutes(-2) }))
    $script:RefreshKeys = @($items | ForEach-Object { Get-MetaKey $_.Id $_.Source })
    Write-UiLog $(if ($Auto) { 'Updating the versions of the listed apps in the background ...' } else { 'Refreshing the package infos and the popular apps, ignoring the cache ...' })
    $fresh = $Auto -and (Test-Path -LiteralPath $script:PopularCachePath) -and ((Get-Item -LiteralPath $script:PopularCachePath).LastWriteTime -gt (Get-Date).AddMinutes(-2))
    if (-not $fresh) { Start-PopularLoad -Force }
    Start-MetaPrefetch -Items $items -Force
    Update-RefreshButton
}
Add-Click $ui.BtnRefreshApps { try { Start-AppsRefresh } catch { Show-Error $_.Exception.Message } }
function Update-CatalogRowsAndList { Update-CatalogRows; Update-AppList }

function Find-VisualChild($Parent, [type]$Type) {
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child -is $Type) { return $child }
        $found = Find-VisualChild $child $Type
        if ($found) { return $found }
    }
}
function Set-CardWidth {
    # As many cards per line as fit (at least 300 px each); the cards of a line share the width
    $width = $ui.CardList.ActualWidth - 4
    if ($width -lt 100) { return }
    $columns = [int][Math]::Max(1, [Math]::Floor($width / 300))
    if ($columns -eq $script:CardColumns) { return }
    $script:CardColumns = $columns
    if ($script:AppListJob) { $script:AppListGen++ } else { Sync-CardLines }
}
$ui.CardList.Add_SizeChanged({ try { Set-CardWidth } catch { } })
$ui.TxtFilter.Add_TextChanged({
    $ui.HintFilter.Visibility = ConvertTo-Vis (-not $ui.TxtFilter.Text)
    try { Update-AppList } catch { Show-Error $_.Exception.Message }
})
$ui.TxtFilter.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { try { Start-AppSearch } catch { Show-Error $_.Exception.Message } } })
$script:SortMode = 'Default'
foreach ($pair in @(@('SortDefault', 'Default'), @('SortDownloads', 'Downloads'))) {
    $ui[$pair[0]].Tag = $pair[1]
    $ui[$pair[0]].Add_Checked({ param($s) $script:SortMode = [string]$s.Tag; try { Update-AppList } catch { Show-Error $_.Exception.Message } })
}
function Get-AppDownloads($Row) {
    # Relevance: the Chocolatey download count (from the popular list or the package infos); unknown counts last
    if ($null -ne $Row.Downloads) { return [double]$Row.Downloads }
    $meta = Get-AppMeta $Row 'Chocolatey'
    $n = 0.0
    if ($meta -and $meta.Found -and [double]::TryParse([string]$meta.Downloads, [ref]$n)) { return $n }
    return -1.0
}
foreach ($pair in @(@('FltAll', 'All'), @('FltWinget', 'Winget'), @('FltChoco', 'Chocolatey'), @('FltBoth', 'Both'))) {
    $ui[$pair[0]].Tag = $pair[1]
    $ui[$pair[0]].Add_Checked({ param($s) $script:SourceFilter = [string]$s.Tag; try { Update-AppList } catch { Show-Error $_.Exception.Message } })
}

function Start-AppSearch {
    $term = $ui.TxtFilter.Text.Trim()
    if ($term.Length -lt 2) { throw 'Enter at least two characters.' }
    if (Test-TaskRunning 'search') { return }
    $ui.TxtAppsCount.Text = 'Searching both repositories ...'
    $work = 'param($Term) Search-PackTuneApps -SearchPattern $Term -Top 30 -Cache $Shared.Meta'
    [void](Start-UiTask -Kind 'search' -Title "Searching Chocolatey and winget for '$term'" -Display "Search: $term" -Pool $script:UserPool -Arguments @{ Term = $term } -Work $work -OnDone {
        param($Result, $Job)
        $script:SearchTerm = $Job.Spec.Arguments.Term
        $script:SearchRows = @($Result | Where-Object { $_ -and $_.Name })
        $script:SearchKeys = @{}
        foreach ($r in $script:SearchRows) { $script:SearchKeys[(Get-AppKey $r)] = $true }
        $script:MetaDirty = $true
        Update-AppList
        if ($Job.Status -eq 'failed') { $ui.TxtAppsCount.Text = 'Search failed, see Activity' }
        $ids = foreach ($r in $script:SearchRows) { foreach ($s in $r.Sources) { @{ Source = $s; Id = (Get-AppId $r $s) } } }
        Start-MetaPrefetch -Items @($ids)
        Start-IconRender
    } -Hidden)
}
Add-Click $ui.BtnSearchRepos { Start-AppSearch }

# ---------------------------------------------------------------- custom applications (MSI; Other follows with the MSIX capture)
$script:CustomApps = $null           # the custom applications of the tenant, $null = not read yet
$script:CustomMode = 'New'           # New | Version
$script:CustomUpdateApp = $null
$script:CustomInfo = $null
$script:CustomRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstCustom.ItemsSource = $script:CustomRows
$ui.CmbCustomAssign.ItemsSource = @('Required (installed on all devices)', 'Available in the Company Portal', 'None (assign in Intune yourself)')
$ui.CmbCustomAssign.SelectedIndex = [Math]::Max(0, [Array]::IndexOf(@('Required', 'Available', 'None'), [string]$script:Settings.Assignment))

function Get-IntentsText($Intents) {
    $i = @($Intents | Where-Object { $_ })
    if (-not $i.Count) { return 'Not assigned' }
    (@($i | ForEach-Object { switch ($_) { 'required' { 'Required' } 'available' { 'Available' } default { $_ } } }) -join ', ')
}
function Update-CustomRows {
    $script:CustomRows.Clear()
    $apps = @($script:CustomApps | Where-Object { $_ })
    foreach ($a in $apps) {
        $newer = @($apps | Where-Object { $_.AppId -eq $a.AppId -and $_.Id -ne $a.Id -and (Compare-SourceVersion $_.Version $a.Version) -eq 1 }).Count -gt 0
        $kind = "$($a.Kind.ToUpper()) $($a.Version)"
        if ($newer) { $kind += ' (replaced)' }
        $colors = if ($newer) { $script:PillColors['gray'] } else { $script:PillColors['info'] }
        $row = New-Row (@{
            Data = $a; Title = $a.DisplayName; Sub = "$($a.Publisher)  $([char]0x00B7)  $($a.ProductCode)"; Kind = $kind; KindBg = $colors[0]; KindFg = $colors[1]
            Assigned = (Get-IntentsText $a.Intents)
        } + (Get-TileStyle $a.DisplayName))
        $script:CustomRows.Add($row)
    }
    $count = @($apps | Where-Object { $a = $_; -not (@($apps | Where-Object { $_.AppId -eq $a.AppId -and $_.Id -ne $a.Id -and (Compare-SourceVersion $_.Version $a.Version) -eq 1 }).Count) }).Count
    $ui.TxtCustomSubtitle.Text = if (-not (Test-SignedIn)) { 'Your own software as Win32 apps: an MSI is read, packaged and deployed automatically. Sign in to see the custom applications in your tenant.' }
    elseif ($null -eq $script:CustomApps) { 'Reading the custom applications of your tenant ...' }
    else { "$count custom application(s) in your tenant.$(if ($script:GraphDown) { ' Last known list, not current.' }) An MSI is read, packaged and deployed automatically." }
    $ui.TxtCustomEmpty.Text = if (-not (Test-SignedIn)) { 'Sign in first.' } elseif ($null -eq $script:CustomApps) { '' } elseif (-not $apps.Count) { 'No custom applications yet. New application starts with an MSI.' } else { '' }
    $ui.BtnCustomRefresh.IsEnabled = (Test-SignedIn)
}
function Start-CustomRefresh {
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'customlist')) { Update-CustomRows; return }
    Update-UiToken
    [void](Start-UiTask -Kind 'customlist' -Title 'Reading the custom applications' -Display 'Custom applications' -Hidden -NeedsAuth -Pool $script:UserPool -Work 'Get-PackTuneCustomApps -WithAssignments' -OnDone {
        param($Result, $Job)
        # (an if-expression would turn an empty list into $null)
        if ($Job.Status -eq 'succeeded') { $script:CustomApps = @($Result | Where-Object { $_ -and $_.Id }) } elseif (-not $script:GraphDown) { $script:CustomApps = $null }   # a failed read keeps the last list
        if ($Job.Status -eq 'failed') { Write-UiLog 'The custom applications could not be read, see above.' 'Warning' }
        Update-CustomRows
    })
    Update-CustomRows
}
Add-Click $ui.BtnCustomRefresh { $script:CustomApps = $null; Start-CustomRefresh }
function Show-CustomDetails($App) {
    $ui.PanelCustomDetails.Visibility = if ($App) { 'Visible' } else { 'Collapsed' }
    if (-not $App) { return }
    $isMsix = $App.Kind -eq 'msix'
    $ui.TxtCustomTitle.Text = $App.DisplayName
    $ui.TxtCustomMeta.Text = "$(if ($isMsix) { 'MSIX (captured)' } else { 'MSI' }) application, $($App.Publisher)"
    $ui.TxtCustomVersion.Text = $App.Version
    $ui.LblCustomProduct.Text = if ($isMsix) { 'Package identity' } else { 'Product code' }
    $ui.LblCustomUpgrade.Text = if ($isMsix) { 'Certificate of this version' } else { 'Upgrade code' }
    $ui.TxtCustomProduct.Text = if ($isMsix) { $App.Identity } else { $App.ProductCode }
    $ui.TxtCustomUpgrade.Text = if ($isMsix) { $App.Thumbprint } else { $App.UpgradeCode }
    $ui.TxtCustomAssigned.Text = Get-IntentsText $App.Intents
    $ui.BtnCustomNewVersion.IsEnabled = $true
    $ui.TxtCustomVersionHint.Text = if ($isMsix) { 'Rebuilds the package on top of the previous version (restored from the package store) with a new installer: a new app supersedes this one on the devices.' } else { 'Pick a newer MSI: a new app is created that supersedes this one on the devices.' }
    $ui.TxtCustomStore.Text = if ($App.Manifest) { "Kept in the package store (manifest $($App.Manifest.Substring(0, 16))...$(if ($App.Manifest.Length -lt 64) { ', short anchor of the first release: record the full one with Set-PackTuneCustomManifestAnchor' }))." } elseif ($isMsix) { 'No manifest in the notes: not kept in the package store.' } else { 'Not kept in the package store (none was set up when it was deployed).' }
    $ui.BtnCustomExport.IsEnabled = [bool]$App.Manifest
}
$ui.LstCustom.Add_SelectionChanged({
    $row = $ui.LstCustom.SelectedItem
    try { Show-CustomDetails $(if ($row) { $row.Data }) } catch { Show-Error $_.Exception.Message }
})
function Get-SelectedCustomApp { $row = $ui.LstCustom.SelectedItem; if ($row) { $row.Data } }

function ConvertFrom-CustomProps([string]$Text) {
    # "ALLUSERS=1 INSTALLDIR=C:\Tools" or NAME="a value": public MSI properties; anything else is refused
    $result = @{}
    $rest = $Text.Trim()
    while ($rest) {
        if ($rest -notmatch '^([A-Z][A-Z0-9_]*)=("([^"]*)"|\S*)\s*') { throw "'$rest' is not a public MSI property (NAME=value, name in capitals)." }
        $result[$Matches[1]] = if ($Matches[3] -ne $null -and $Matches[2].StartsWith('"')) { $Matches[3] } else { $Matches[2] }
        $rest = $rest.Substring($Matches[0].Length)
    }
    return $result
}
# ---- icon of a custom application (Company Portal): from the package, or chosen
$script:CustomIconFile = $null      # PNG the person chose (converted like the catalog custom icon)
$script:CustomIconAuto = $null      # icon found in the package (file)
function Get-CustomPackageIconFile {
    # MSI: the icon of the Icon table (ARPPRODUCTICON). Other: the icon of the entry point when it is an .exe (the logo of the captured MSIX comes with the capture).
    try {
        $dir = Join-Path $script:WorkRoot 'icons\customdialog'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        if ($script:CustomKind -eq 'Msi') {
            if ($script:CustomInfo -and $script:CustomInfo.IconName) {
                $f = Join-Path $dir 'msi-icon.ico'
                if (Save-PackTuneMsiIcon -Path $script:CustomInfo.Path -IconName $script:CustomInfo.IconName -Destination $f) { return $f }
            }
            return $null
        }
        $entry = $ui.CmbOtherEntry.Text.Trim(); $folder = $ui.TxtOtherFolder.Text.Trim().Trim('"')
        if ($entry -like '*.exe' -and $folder) {
            $exe = if ([IO.Path]::IsPathRooted($entry)) { $entry } else { Join-Path $folder $entry }
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                Add-Type -AssemblyName System.Drawing
                $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
                if ($ico) { $f = Join-Path $dir 'exe-icon.png'; $bmp = $ico.ToBitmap(); $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); return $f }
            }
        }
    }
    catch { }
    $null
}
function Update-CustomIconPreview {
    $script:CustomIconAuto = Get-CustomPackageIconFile
    $src = $null
    $hint = ''
    if ($script:CustomIconFile) { $src = $script:CustomIconFile; $hint = 'The icon you chose.' }
    elseif ($script:CustomIconAuto) { $src = $script:CustomIconAuto; $hint = $(if ($script:CustomKind -eq 'Msi') { 'The icon of the MSI.' } else { 'The icon of the entry point (the logo of the captured package is used when it has one).' }) }
    elseif ($script:CustomMode -in 'Version', 'Update' -and $script:CustomUpdateApp) {
        $cur = Get-TenantAppIcon $script:CustomUpdateApp
        if ($cur) { $src = $cur; $hint = 'The current icon in Intune stays unless you choose another.' }
    }
    $image = $null
    if ($src) { $image = if ($src -is [string]) { ConvertTo-ImageSource $src } else { $src } }
    $ui.ImgCustomAppIcon.Source = $image
    $ui.ImgCustomAppIcon.Visibility = ConvertTo-Vis ([bool]$image)
    $ui.TxtCustomAppIconPlaceholder.Visibility = ConvertTo-Vis (-not $image)
    $ui.TxtCustomAppIconHint.Text = if ($image) { $hint } else { 'No icon in the package - choose one, otherwise the Company Portal shows a default icon.' }
    $ui.BtnCustomAppIconReset.IsEnabled = [bool]$script:CustomIconFile
}
function Set-CustomAppIcon([string]$Path) {
    $window.Cursor = 'Wait'
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 5MB) { throw 'The icon file is larger than 5 MB.' }
        $dir = Join-Path $script:WorkRoot 'icons\customdialog'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        $png = ConvertTo-PngBytes -Bytes $bytes -WorkPath $dir
        $file = Join-Path $dir 'chosen.png'
        [IO.File]::WriteAllBytes($file, $png)
        $script:CustomIconFile = $file
    }
    finally { $window.Cursor = $null }
    Update-CustomIconPreview
}
Add-Click $ui.BtnCustomAppIconPick {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Icon for the Company Portal'
    $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg;*.svg;*.ico)|*.png;*.jpg;*.jpeg;*.svg;*.ico|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    Set-CustomAppIcon $dlg.FileName
}
Add-Click $ui.BtnCustomAppIconReset { $script:CustomIconFile = $null; Update-CustomIconPreview }
$ui.CmbOtherEntry.Add_LostFocus({ try { Update-CustomIconPreview } catch { } })
$ui.CmbOtherEntry.Add_SelectionChanged({ try { Update-CustomIconPreview } catch { } })

function Set-CustomInfo($Info, [string]$Message) {
    $script:CustomInfo = $Info
    $ui.TxtCustomRead.Text = $Message
    $ui.BoxCustomProps.Visibility = ConvertTo-Vis ([bool]$Info)
    if ($Info) {
        $ui.TxtMsiName.Text = $Info.Name; $ui.TxtMsiVersion.Text = $Info.Version; $ui.TxtMsiManufacturer.Text = $Info.Manufacturer
        $ui.TxtMsiProduct.Text = $Info.ProductCode; $ui.TxtMsiUpgrade.Text = $(if ($Info.UpgradeCode) { $Info.UpgradeCode } else { '(none)' }); $ui.TxtMsiSize.Text = "$($Info.SizeMB) MB"
    }
    $ui.BtnCustomDeploy.IsEnabled = [bool]$Info
    $ui.BtnCustomTest.IsEnabled = [bool]$Info
    Update-CustomIconPreview
}
function Read-CustomMsi([string]$Path) {
    try {
        $info = Get-PackTuneMsiInfo -Path $Path
        $message = "Read from the MSI, nothing was installed."
        if ($script:CustomMode -eq 'Version' -and $script:CustomUpdateApp) {
            $old = $script:CustomUpdateApp
            if ($old.UpgradeCode -and $info.UpgradeCode -and $old.UpgradeCode -ne $info.UpgradeCode) { Set-CustomInfo $null "This MSI belongs to another product (upgrade code $($info.UpgradeCode))."; return }
            if ($info.ProductCode -eq $old.ProductCode) { Set-CustomInfo $null 'Same product code as the installed version: devices could not tell the versions apart. Build a major upgrade with a new product code.'; return }
            if ((Compare-SourceVersion $info.Version $old.Version) -ne 1) { Set-CustomInfo $null "Version $($info.Version) is not newer than $($old.Version)."; return }
            $message = "Newer than $($old.Version): the new app supersedes the old one on the devices."
        }
        Set-CustomInfo $info $message
    }
    catch { Set-CustomInfo $null $_.Exception.Message }
}
function Set-CustomPath([string]$Path) {
    $ui.TxtCustomPath.Text = $Path
    $ui.CmbCustomMsi.Visibility = 'Collapsed'
    $script:CustomMsiFiles = @()
    if (-not $Path) { Set-CustomInfo $null ''; return }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.msi' -File | Sort-Object Name)
        if (-not $files.Count) { Set-CustomInfo $null 'There is no .msi file in this folder.'; return }
        $script:CustomMsiFiles = $files
        if ($files.Count -gt 1) {
            $ui.CmbCustomMsi.ItemsSource = @($files | ForEach-Object { $_.Name })
            $ui.CmbCustomMsi.Visibility = 'Visible'
            $ui.CmbCustomMsi.SelectedIndex = 0   # reads the first one
            return
        }
        $Path = $files[0].FullName
    }
    Read-CustomMsi $Path
}
$ui.CmbCustomMsi.Add_SelectionChanged({
    $i = $ui.CmbCustomMsi.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:CustomMsiFiles.Count) { Read-CustomMsi $script:CustomMsiFiles[$i].FullName }
})
$ui.TxtCustomPath.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { try { Set-CustomPath $ui.TxtCustomPath.Text.Trim().Trim('"') } catch { Show-Error $_.Exception.Message } } })
$ui.TxtCustomPath.Add_LostFocus({ if ($ui.TxtCustomPath.Text.Trim() -and -not $script:CustomInfo) { try { Set-CustomPath $ui.TxtCustomPath.Text.Trim().Trim('"') } catch { } } })
Add-Click $ui.BtnCustomFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose the MSI'; $dlg.Filter = 'Windows Installer (*.msi)|*.msi'
    if ($dlg.ShowDialog($window)) { Set-CustomPath $dlg.FileName }
}
Add-Click $ui.BtnCustomFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Folder with the MSI (several MSI files: you choose one)'
    if ($dlg.ShowDialog() -eq 'OK') { Set-CustomPath $dlg.SelectedPath }
}
function Get-CustomEntryCandidates([string]$Folder) {
    # Files that can start an installation: installers and scripts (relative paths, the shortest first)
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    $root = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.msi', '.ps1', '.cmd', '.bat' } | Select-Object -First 300 |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) } | Sort-Object { $_.Length }, { $_ })
}
function Set-OtherFolder([string]$Folder) {
    $ui.TxtOtherFolder.Text = $Folder
    $entries = Get-CustomEntryCandidates $Folder
    $ui.CmbOtherEntry.ItemsSource = $entries
    if ($entries.Count) {
        $ui.CmbOtherEntry.SelectedIndex = 0
        $setup = @($entries | Where-Object { $_ -match '(?i)(^|\\)(setup|install)[^\\]*\.(exe|msi)$' } | Select-Object -First 1)
        if ($setup.Count) { $ui.CmbOtherEntry.SelectedItem = $setup[0] }
        $ui.CmbOtherEntry.Text = [string]$ui.CmbOtherEntry.SelectedItem
    }
    if ($Folder -and -not $ui.TxtOtherName.Text -and $script:CustomMode -eq 'New') { $ui.TxtOtherName.Text = (Split-Path $Folder -Leaf) -replace '[-_.]+', ' ' }
    $ui.TxtCustomDlgStatus.Text = if ($Folder -and -not $entries.Count) { 'No .exe, .msi, .ps1, .cmd or .bat file in this folder.' } else { '' }
    Update-OtherDeploy
}
function Update-OtherDeploy {
    # The button is on when everything that is needed is filled in
    if ($script:CustomMode -notin 'New', 'Update' -or $script:CustomKind -ne 'Other') { return }
    $folderOk = $ui.TxtOtherFolder.Text.Trim() -and (Test-Path -LiteralPath $ui.TxtOtherFolder.Text.Trim() -PathType Container)
    if ($script:CustomMode -eq 'Update') { $ok = ($folderOk -or -not $ui.TxtOtherFolder.Text.Trim()) -and $ui.TxtOtherVersion.Text.Trim() }
    else { $ok = $folderOk -and [string]$ui.CmbOtherEntry.Text -and $ui.TxtOtherName.Text.Trim() -and $ui.TxtOtherVersion.Text.Trim() }
    $ui.BtnCustomDeploy.IsEnabled = [bool]$ok
}
function Set-CustomKind([string]$Kind) {
    $script:CustomKind = $Kind
    try { Update-CustomIconPreview } catch { }
    $ui.PanelCustomMsi.Visibility = ConvertTo-Vis ($Kind -eq 'Msi')
    $ui.PanelCustomOther.Visibility = ConvertTo-Vis ($Kind -eq 'Other')
    $ui.TxtCustomOther.Visibility = ConvertTo-Vis ($Kind -eq 'Msi' -and $script:CustomMode -eq 'New' -and -not $ui.RbCustomOther.IsEnabled)
    if ($Kind -eq 'Other') { $ui.BtnCustomDeploy.IsEnabled = $false; $ui.BtnCustomTest.Visibility = 'Collapsed'; $ui.BtnCustomDeploy.Content = if ($script:CustomMode -eq 'Update') { 'Capture and publish' } else { 'Capture and deploy' }; Update-OtherDeploy }
    else { $ui.BtnCustomTest.Visibility = 'Visible'; $ui.BtnCustomDeploy.Content = if ($script:CustomMode -eq 'Version') { 'Publish version' } else { 'Deploy' }; $ui.BtnCustomDeploy.IsEnabled = [bool]$script:CustomInfo }
}
$script:CustomKind = 'Msi'
$ui.CmbOtherAssign.ItemsSource = @('Required (installed on all devices)', 'Available in the Company Portal', 'None (assign in Intune yourself)')
$ui.CmbOtherAssign.SelectedIndex = $ui.CmbCustomAssign.SelectedIndex
$ui.RbCustomMsi.Add_Checked({ if ($script:OpenDialog -eq 'DlgCustom') { Set-CustomKind 'Msi' } })
$ui.RbCustomOther.Add_Checked({ if ($script:OpenDialog -eq 'DlgCustom') { Set-CustomKind 'Other' } })
foreach ($c in $ui.TxtOtherName, $ui.TxtOtherVersion, $ui.TxtOtherArgs) { $c.Add_TextChanged({ try { Update-OtherDeploy } catch { } }) }
$ui.CmbOtherEntry.Add_SelectionChanged({ try { Update-OtherDeploy } catch { } })
$ui.CmbOtherEntry.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.RoutedEventHandler] { try { Update-OtherDeploy } catch { } })
$ui.TxtOtherFolder.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { try { Set-OtherFolder $ui.TxtOtherFolder.Text.Trim().Trim('"') } catch { Show-Error $_.Exception.Message } } })
$ui.TxtOtherFolder.Add_LostFocus({ try { Set-OtherFolder $ui.TxtOtherFolder.Text.Trim().Trim('"') } catch { } })
Add-Click $ui.BtnOtherFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Folder with ALL files of the installation (setup, data, scripts)'
    if ($dlg.ShowDialog() -eq 'OK') { Set-OtherFolder $dlg.SelectedPath }
}
function Show-CustomDialog([string]$Mode, $App) {
    # New: new application (MSI or Other) | Version: new MSI version | Update: new capture of an MSIX application
    $script:CustomMode = $Mode
    $script:CustomUpdateApp = $App
    $script:CustomInfo = $null
    $script:CustomIconFile = $null
    $isNew = $Mode -eq 'New'
    $studio = Get-CustomCaptureState
    $ui.RbCustomOther.IsEnabled = ($studio.State -eq 'Ready')
    $ui.RbCustomOther.ToolTip = if ($studio.State -eq 'Ready') { 'Installers, scripts and several files: captured as MSIX in Windows Sandbox' } else { $studio.Message }
    $ui.TxtCustomOther.Text = if ($studio.State -eq 'Ready') { 'Other: installers, scripts and several files are captured as an MSIX in Windows Sandbox.' } else { "Other (EXE setups, scripts, several files) is not available: $($studio.Message)" }
    $ui.TxtCustomDlgTitle.Text = switch ($Mode) { 'Version' { "New version of $($App.DisplayName)" } 'Update' { "New version of $($App.DisplayName)" } default { 'New application' } }
    $ui.TxtCustomDlgSub.Text = switch ($Mode) {
        'Version' { "Installed version: $($App.Version). Pick the newer MSI of the same product." }
        'Update' { "Installed version: $($App.Version). The previous package is restored from the package store in a fresh sandbox, the new installer runs on top of it, and the result goes out as a new version." }
        default { 'Choose how the software is packaged.' }
    }
    $ui.BoxCustomKind.Visibility = ConvertTo-Vis $isNew
    $ui.PanelCustomAssign.Visibility = ConvertTo-Vis $isNew
    $ui.PanelOtherAssign.Visibility = ConvertTo-Vis $isNew
    $ui.GridOtherIdentity.Visibility = ConvertTo-Vis $true
    $ui.TxtCustomProps.Text = ''
    $ui.TxtCustomDlgStatus.Text = ''
    $ui.CmbCustomMsi.Visibility = 'Collapsed'
    Set-CustomPath ''
    foreach ($c in $ui.TxtOtherFolder, $ui.TxtOtherArgs, $ui.TxtOtherName, $ui.TxtOtherPublisher) { $c.Text = '' }
    # Network in the capture sandbox: off unless the person turns it on for this capture
    $ui.ChkOtherNetwork.IsChecked = $false
    $ui.CmbOtherEntry.ItemsSource = @(); $ui.CmbOtherEntry.Text = ''
    $ui.TxtOtherVersion.Text = if ($Mode -eq 'Update') { Get-PackTuneNextVersion $App.Version } else { '1.0.0.0' }
    $ui.TxtOtherName.IsEnabled = $isNew; $ui.TxtOtherPublisher.IsEnabled = $isNew
    if ($Mode -eq 'Update') {
        $ui.TxtOtherName.Text = $App.DisplayName; $ui.TxtOtherPublisher.Text = $App.Publisher
        $ui.LblOtherFolder.Text = 'New installer folder (empty: the stored installer files are used again)'
        $ui.TxtOtherInfo.Text = 'Leave the folder empty to rebuild from the stored installer files, or point to a folder with the new files (for example an export that you edited). Entry point and arguments are taken from the stored recipe when left empty.'
    }
    else {
        $ui.LblOtherFolder.Text = 'Folder with all installation files'
        $ui.TxtOtherInfo.Text = 'The capture runs unattended in a fresh Windows Sandbox and takes a few minutes. The original files are kept with every version in the package store, signed with a certificate made for this version alone.'
    }
    $ui.RbCustomMsi.IsChecked = $true
    Set-CustomKind $(if ($Mode -eq 'Update') { 'Other' } else { 'Msi' })
    Show-Dialog 'DlgCustom'
}
Add-Click $ui.BtnCustomNew { Show-CustomDialog 'New' $null }
Add-Click $ui.BtnCustomNewVersion {
    $app = Get-SelectedCustomApp
    if (-not $app) { return }
    if ($app.Kind -eq 'msix') {
        $studio = Get-CustomCaptureState
        if ($studio.State -ne 'Ready') { throw $studio.Message }
        Show-CustomDialog 'Update' $app
    }
    else { Show-CustomDialog 'Version' $app }
}
Add-Click $ui.BtnCustomCancel { Close-Dialog }
Add-Click $ui.BtnCustomDeploy {
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first (Sign in, top right).' }
    if ($script:CustomKind -eq 'Other') {
        $folder = $ui.TxtOtherFolder.Text.Trim().Trim('"')
        $entry = [string]$ui.CmbOtherEntry.Text
        $name = $ui.TxtOtherName.Text.Trim()
        $version = $ui.TxtOtherVersion.Text.Trim()
        if ($version -notmatch '^\d+(\.\d+){0,3}$') { throw "The version '$version' must be a number like 1.0.0.0." }
        if ($script:CustomMode -eq 'Update') {
            $old = $script:CustomUpdateApp
            $arguments = @{ Id = $old.Id; Version = $version; Network = [bool]$ui.ChkOtherNetwork.IsChecked; Icon = $(if ($script:CustomIconFile) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:CustomIconFile)) } else { '' }) }
            if ($folder) { $arguments.Folder = $folder }
            if ($entry) { $arguments.Entry = $entry }
            if ($ui.TxtOtherArgs.Text.Trim()) { $arguments.Args = $ui.TxtOtherArgs.Text.Trim() }
            Close-Dialog
            Update-UiToken
            $work = 'param($Id, $Version, $Folder, $Entry, $Args, $Network, $Icon) $p = @{ AppId = $Id; Version = $Version; AllowNetwork = [bool]$Network }; if ($Icon) { $p.IconBase64 = $Icon }; if ($Folder) { $p.InstallerFolder = $Folder }; if ($Entry) { $p.EntryPoint = $Entry }; if ($Args) { $p.Arguments = $Args }; Update-PackTuneCustomOtherApp @p'
            [void](Start-UiTask -Kind 'custom' -Title "Capturing version $version of $($old.DisplayName) in Windows Sandbox (a few minutes)" -Display "$($old.DisplayName) $version" -NeedsAuth -Pool $script:TestPool -Arguments $arguments -Work $work -OnDone {
                param($Result, $Job)
                if ($Job.Status -eq 'succeeded') { Write-UiLog "[$($Job.Display)] published: devices with the old version get it through supersedence." 'Success'; Show-Toast "$($Job.Display) was published." 'ok' }
                $script:CustomApps = $null; Start-CustomRefresh
            })
        }
        else {
            $assign = $script:AssignValues[[Math]::Max(0, $ui.CmbOtherAssign.SelectedIndex)]
            Close-Dialog
            Update-UiToken
            $arguments = @{ Folder = $folder; Entry = $entry; Args = $ui.TxtOtherArgs.Text.Trim(); Name = $name; Version = $version; Publisher = $ui.TxtOtherPublisher.Text.Trim(); Assignment = $assign; Network = [bool]$ui.ChkOtherNetwork.IsChecked
                Icon = $(if ($script:CustomIconFile) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:CustomIconFile)) } else { '' })
                Fallback = $(if ($script:CustomIconAuto) { try { Get-ChocoIconBase64 -ChocoName 'custom-other' -IconFile $script:CustomIconAuto -NoIconPrompt -NoFeedLookup } catch { '' } } else { '' }) }
            $work = 'param($Folder, $Entry, $Args, $Name, $Version, $Publisher, $Assignment, $Network, $Icon, $Fallback) $p = @{ Folder = $Folder; EntryPoint = $Entry; Arguments = $Args; Name = $Name; Version = $Version; Publisher = $Publisher; Assignment = $Assignment; AllowNetwork = [bool]$Network }; if ($Icon) { $p.IconBase64 = $Icon }; if ($Fallback) { $p.FallbackIconBase64 = $Fallback }; New-PackTuneCustomOtherApp @p'
            [void](Start-UiTask -Kind 'custom' -Title "Capturing $name in Windows Sandbox (a few minutes), then deploying" -Display "$name $version" -NeedsAuth -Pool $script:TestPool -Arguments $arguments -Work $work -OnDone {
                param($Result, $Job)
                if ($Job.Status -eq 'succeeded') { Write-UiLog "[$($Job.Display)] captured, stored and created in Intune." 'Success'; Show-Toast "$($Job.Display) is in Intune." 'ok' }
                $script:CustomApps = $null; Start-CustomRefresh
            })
        }
        Show-Page 'Activity'
        return
    }
    if (-not $script:CustomInfo) { throw 'Choose an MSI first.' }
    $props = ConvertFrom-CustomProps $ui.TxtCustomProps.Text
    $msi = $script:CustomInfo.Path
    $name = $script:CustomInfo.Name
    if ($script:CustomMode -eq 'Version') {
        $old = $script:CustomUpdateApp
        Close-Dialog
        Update-UiToken
        [void](Start-UiTask -Kind 'custom' -Title "New version $($script:CustomInfo.Version) of $($old.DisplayName)" -Display "$name $($script:CustomInfo.Version)" -NeedsAuth -Arguments @{ Id = $old.Id; Msi = $msi; Props = $props; Icon = $script:CustomIconFile } `
            -Work 'param($Id, $Msi, $Props, $Icon) $p = @{ AppId = $Id; MsiPath = $Msi; Properties = $Props }; if ($Icon) { $p.IconFile = $Icon }; Publish-PackTuneCustomVersion @p' -OnDone {
            param($Result, $Job)
            if ($Job.Status -eq 'succeeded') { Write-UiLog "[$($Job.Display)] published: devices with the old version get it through supersedence." 'Success'; Show-Toast "$($Job.Display) was published." 'ok' }
            $script:CustomApps = $null; Start-CustomRefresh
        })
    }
    else {
        $assign = $script:AssignValues[[Math]::Max(0, $ui.CmbCustomAssign.SelectedIndex)]
        Close-Dialog
        Update-UiToken
        [void](Start-UiTask -Kind 'custom' -Title "Deploying $name ($($script:CustomInfo.Version)) from the MSI" -Display "$name $($script:CustomInfo.Version)" -NeedsAuth -Arguments @{ Msi = $msi; Assignment = $assign; Props = $props; Icon = $script:CustomIconFile } `
            -Work 'param($Msi, $Assignment, $Props, $Icon) $p = @{ MsiPath = $Msi; Assignment = $Assignment; Properties = $Props }; if ($Icon) { $p.IconFile = $Icon }; New-PackTuneCustomMsiApp @p' -OnDone {
            param($Result, $Job)
            if ($Job.Status -eq 'succeeded') { Write-UiLog "[$($Job.Display)] created in Intune." 'Success'; Show-Toast "$($Job.Display) is in Intune." 'ok' }
            $script:CustomApps = $null; Start-CustomRefresh
        })
    }
    Show-Page 'Activity'
}
function Start-CustomTest([string]$PreviousMsi, [string]$PreviousStoreAppId) {
    if (-not $script:CustomInfo) { return }
    if (Block-SandboxStart) { return }
    $props = ConvertFrom-CustomProps $ui.TxtCustomProps.Text
    $name = $script:CustomInfo.Name
    $authArgs = if ($PreviousStoreAppId) { @{ NeedsAuth = $true } } else { @{} }   # the package store needs the sign-in
    [void](Start-UiTask -Kind 'test' -Title "Sandbox test of ${name}: the lab plays detect, install, detect, uninstall, detect in the sandbox and reports the result" -Display "Sandbox: $name$(if ($PreviousMsi -or $PreviousStoreAppId) { " (update from the previous version)" })" -Pool $script:TestPool -Arguments @{ Msi = $script:CustomInfo.Path; Props = $props; Previous = $PreviousMsi; StoreApp = $PreviousStoreAppId } @authArgs `
        -Work 'param($Msi, $Props, $Previous, $StoreApp) $p = @{ MsiPath = $Msi; Properties = $Props }; if ($Previous) { $p.PreviousMsiPath = $Previous }; if ($StoreApp) { $p.PreviousStoreAppId = $StoreApp }; Test-PackTuneCustomApp @p -AutoRun' -OnDone {
        param($Result, $Job)
        $outcome = @($Result | Where-Object { $_.Verdict }) | Select-Object -First 1
        if ($Job.Status -eq 'failed' -or -not $outcome) { Write-UiLog "[$($Job.Display)] the sandbox test could not run, see above." 'Error'; Show-Toast "Sandbox test of $($Job.Display) could not run: $(Get-FriendlyCause (@($Job.Log | Where-Object { $_.Level -eq 'Error' } | Select-Object -Last 1 | ForEach-Object { $_.Text })[0]))" 'bad' 'Details' { Show-Page 'Activity' } }
        elseif ($outcome.Verdict -eq 'Passed') { Write-UiLog "[$($Job.Display)] sandbox test passed." 'Success'; Show-Toast "$($Job.Display) passed." 'ok' }
        else { Write-UiLog "[$($Job.Display)] sandbox test failed: $($outcome.Message)" 'Warning'; Show-Toast "Sandbox test failed: $($outcome.Message)" 'warn' }
        Update-SandboxButtons
    })
    Show-SandboxStarted
}
Add-Click $ui.BtnCustomTest { Start-CustomTest }
Add-Click $ui.BtnCustomOpen {
    $app = Get-SelectedCustomApp
    if ($app) { Start-Process "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($app.Id)" }
}
function Confirm-AppRemoval {
    # Reads the relationships of the app in the background, then asks (naming what is cleared first); apps that depend on it stop the removal.
    # $Proceed gets called after the yes. In the smoke test the question is answered at once.
    param([Parameter(Mandatory = $true)]$App, [Parameter(Mandatory = $true)][string]$Question, [Parameter(Mandatory = $true)][scriptblock]$Proceed)
    if ($env:PACKTUNE_SMOKE) { if (Confirm-Action $Question 'Remove from Intune' 'Remove' 'Cancel') { & $Proceed }; return }
    $script:RemovalPending = @{ Question = $Question; Proceed = $Proceed; Name = $App.DisplayName }
    Update-UiToken
    [void](Start-UiTask -Kind 'removeinfo' -Title "Checking what $($App.DisplayName) is connected to" -Display $App.DisplayName -Hidden -NeedsAuth -Pool $script:UserPool -Arguments @{ Id = $App.Id } -Work 'param($Id) Get-PackTuneAppRemovalInfo -AppId $Id' -OnDone {
        param($Result, $Job)
        $pending = $script:RemovalPending; $script:RemovalPending = $null
        if (-not $pending) { return }
        $info = @($Result | Where-Object { $_ -and $null -ne $_.Own }) | Select-Object -First 1
        if ($Job.Status -eq 'failed' -or -not $info) { Show-Toast "Could not check what $($pending.Name) is connected to, see Activity." 'bad'; return }
        $deps = @($info.Dependents)
        if ($deps.Count) {
            $names = ($deps | ForEach-Object { "$($_.TargetName) ($($_.TargetId))" }) -join ", "
            Write-UiLog "[$($pending.Name)] not removed: $($deps.Count) app(s) depend on it: $names" 'Warning'
            Show-Toast "$($pending.Name) is kept: $($deps.Count) app(s) depend on it ($(($deps | Select-Object -First 3 | ForEach-Object { $_.TargetName }) -join ', ')). Switch or remove those first."  'warn'
            return
        }
        $extra = ""
        $own = @($info.Own); $sup = @($info.Superseding)
        if ($own.Count) { $extra += "`n`nIntune only deletes it after its own relationships are cleared. They are cleared first:`n" + (($own | Select-Object -First 8 | ForEach-Object { "- $($_.Kind) -> $($_.TargetName)" }) -join "`n") }
        if ($sup.Count) { $extra += "`n`nThese apps supersede it, the supersedence is taken off them:`n" + (($sup | Select-Object -First 8 | ForEach-Object { "- $($_.TargetName)" }) -join "`n") }
        if (Confirm-Action ($pending.Question + $extra) 'Remove from Intune' 'Remove' 'Cancel') { & $pending.Proceed }
    })
}
Add-Click $ui.BtnCustomRemove {
    $app = Get-SelectedCustomApp
    if (-not $app) { return }
    Confirm-AppRemoval $app "Remove '$($app.DisplayName) $($app.Version)' from Intune?`n`nThe app and its assignments are deleted in the tenant. Devices keep the installed software." { Start-CustomRemoval $app }
}
function Start-CustomRemoval($app) {
    $deleteStore = $false
    if ($script:Settings.StoreSiteUrl -and $app.AppId -and @($script:CustomApps | Where-Object { $_.AppId -eq $app.AppId }).Count -le 1) {
        $deleteStore = Confirm-Action "This is the last Intune app of '$($app.DisplayName)'.`n`nAlso delete its stored files (packages, original installer files, certificates) from the package store?`n`nDelete files: delete them (SharePoint keeps them in its recycle bin).`nKeep files: keep them, so the application can still be exported." 'Delete stored files' 'Delete files' 'Keep files'
    }
    Update-UiToken
    $work = if ($deleteStore) { 'param($Id) Remove-PackTuneCustomApp -Id $Id -DeleteStore' } else { 'param($Id) Remove-PackTuneCustomApp -Id $Id' }
    [void](Start-UiTask -Kind 'custom' -Title "Removing $($app.DisplayName) from Intune" -Display $app.DisplayName -NeedsAuth -Arguments @{ Id = $app.Id } -Work $work -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') { Write-UiLog "[$($Job.Display)] removed from Intune." 'Success'; Show-Toast "$($Job.Display) was removed from Intune." 'ok' }
        $script:CustomApps = $null; Show-CustomDetails $null; Start-CustomRefresh
    })
}
Add-Click $ui.BtnCustomExport {
    $app = Get-SelectedCustomApp
    if (-not $app) { return }
    if (-not $script:Settings.StoreSiteUrl) { throw 'No package store is set up (Start page, Package store).' }
    $target = $script:ExportTarget
    if (-not $target) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Folder for the export of $($app.DisplayName) $($app.Version) (a sub folder is created)"
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $target = $dlg.SelectedPath
    }
    $destination = Join-Path $target ("$($app.AppId)-$($app.Version)")
    Update-UiToken
    [void](Start-UiTask -Kind 'custom' -Title "Exporting $($app.DisplayName) $($app.Version) from the package store" -Display "Export $($app.DisplayName)" -NeedsAuth -Arguments @{ AppId = $app.AppId; Version = $app.Version; Destination = $destination } `
        -Work 'param($AppId, $Version, $Destination) Export-PackTuneCustomApp -AppId $AppId -Version $Version -Destination $Destination' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') {
            $saved = @($Result | Where-Object { $_.Destination }) | Select-Object -First 1
            Write-UiLog "[$($Job.Display)] saved and checked in $($saved.Destination). Edit the files in 'installer', then New version." 'Success'
            Show-Toast "$($Job.Display) was saved to $($saved.Destination)." 'ok'
            if (-not $env:PACKTUNE_SMOKE -and $saved.Destination) { Start-Process explorer.exe $saved.Destination }
        }
    })
}

# ---------------------------------------------------------------- package store (readiness, dialog)
$script:StoreState = $null
function Start-StoreCheck {
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'storecheck')) { return }
    if (-not $script:Settings.StoreSiteUrl) { $script:StoreState = [pscustomobject]@{ State = 'NotConfigured'; Message = 'Enter the address of the SharePoint site that keeps the packages.' }; Update-Readiness; return }
    # Tests: no request to Microsoft Graph from the smoke run
    if ($env:PACKTUNE_SMOKE) { $script:StoreState = [pscustomobject]@{ State = 'NoAccess'; Message = 'The site cannot be read (smoke test). An administrator grants PackTune access to this one site (Grant access).' }; Update-Readiness; return }
    Update-UiToken
    [void](Start-UiTask -Kind 'storecheck' -Title 'Checking the package store' -Display 'Package store' -Hidden -NeedsAuth -Pool $script:UserPool -Work 'Get-PackTuneStoreState | Select-Object State, Message' -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_.State }) | Select-Object -First 1
        $script:StoreState = if ($r) { $r } else { [pscustomobject]@{ State = 'NoAccess'; Message = 'The package store could not be checked, see Activity.' } }
        Update-Readiness
        if ($script:OpenDialog -eq 'DlgStore') { Update-StoreDialog }
    })
}
function Get-StoreReadinessItems {
    $items = @()
    $items += if (-not (Test-SignedIn)) { @{ Key = 'store'; Title = 'Package store (optional)'; State = 'warn'; Optional = $true; Text = 'Keeps every version of a custom application in a private SharePoint library, so it can be updated and edited from any PC. Sign in first.' } }
              elseif (-not $script:Settings.StoreSiteUrl) { @{ Key = 'store'; Title = 'Package store (optional)'; State = 'warn'; Optional = $true; Text = 'Keeps every version of a custom application in a private SharePoint library, so it can be updated and edited from any PC. MSIX applications need it.'; Fix = 'Set up'; Action = { Show-StoreDialog } } }
              elseif (-not $script:StoreState) { @{ Key = 'store'; Title = 'Package store (optional)'; State = 'warn'; Optional = $true; Wait = (Test-TaskRunning 'storecheck'); Text = 'Checking the package store ...'; Fix = 'Check'; Action = { Start-StoreCheck } } }
              elseif ($script:StoreState.State -eq 'Ready') { @{ Key = 'store'; Title = 'Package store (optional)'; State = 'ok'; Optional = $true; Text = $script:StoreState.Message } }
              else { @{ Key = 'store'; Title = 'Package store (optional)'; State = 'warn'; Optional = $true; Text = $script:StoreState.Message; Fix = 'Set up'; Action = { Show-StoreDialog } } }
    return $items
}
function Update-StoreDialog {
    $ui.TxtStoreStatus.Text = if ($script:StoreState) { $script:StoreState.Message } elseif ($script:Settings.StoreSiteUrl) { 'Not checked yet.' } else { '' }
    $ui.TxtStoreStatus.Foreground = if ($script:StoreState -and $script:StoreState.State -eq 'Ready') { $script:PillColors['ok'][1] } else { [System.Windows.Media.Brushes]::Black }
    $ui.BtnStoreCreate.IsEnabled = ($script:StoreState -and $script:StoreState.State -eq 'NoLibrary')
    $ui.BtnStoreGrant.IsEnabled = [bool]$script:Settings.StoreSiteUrl -and (Test-SignedIn)
}
function Show-StoreDialog {
    $ui.TxtStoreSite.Text = $script:Settings.StoreSiteUrl
    $ui.TxtStoreLibrary.Text = $script:Settings.StoreLibrary
    Update-StoreDialog
    Show-Dialog 'DlgStore'
}
Add-Click $ui.BtnStoreClose { Close-Dialog }
Add-Click $ui.BtnStoreSave {
    $s = Get-PackTuneSettings
    $s.StoreSiteUrl = $ui.TxtStoreSite.Text.Trim(); $s.StoreLibrary = $ui.TxtStoreLibrary.Text.Trim()
    [void](Save-PackTuneSettings -Settings $s)
    $script:Settings = Get-PackTuneSettings
    $script:StoreState = $null
    Update-StoreDialog
    Start-StoreCheck
    Update-Readiness
}
Add-Click $ui.BtnStoreCreate {
    Update-UiToken
    [void](Start-UiTask -Kind 'store' -Title 'Creating the document library of the package store' -Display 'Package store' -NeedsAuth -Pool $script:UserPool -Work 'Initialize-PackTuneStore | Out-Null' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') { Write-UiLog 'The document library of the package store was created.' 'Success' }
        $script:StoreState = $null; Start-StoreCheck
    })
}
Add-Click $ui.BtnStoreGrant {
    if (-not $script:Settings.StoreSiteUrl) { throw 'Save the address of the site first.' }
    if (-not (Confirm-Action "An administrator signs in with Microsoft's app 'Microsoft Graph Command Line Tools' and the permission Sites.FullControl.All, which PackTune uses for this one grant only.`n`n$($script:StoreGrantConsentNote)`n`nContinue?" 'Grant access to the SharePoint site' 'Continue' 'Cancel')) { return }
    $token = $null
    try { $token = Get-EmbeddedToken -TenantID $(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'organizations' }) -ClientID '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Scopes @('Sites.FullControl.All') -Hint 'Sign in with an administrator account: it grants PackTune access to this one SharePoint site.' }
    catch { if ($_.Exception.Message -ne 'Sign-in cancelled.') { Show-Error $_.Exception.Message } else { Show-SignInCancelled }; return }
    $role = if ($script:StoreState -and $script:StoreState.State -eq 'NoLibrary') { 'manage' } else { 'write' }
    $access = if ($token) { [string]$token.access_token } else { '' }
    [void](Start-UiTask -Kind 'store' -Title "Granting PackTune access to the SharePoint site (role $role)" -Display 'Package store' -Pool $script:UserPool -Arguments @{ Site = $script:Settings.StoreSiteUrl; Client = $script:Settings.ClientID; Token = $access; Role = $role } `
        -Work 'param($Site, $Client, $Token, $Role) $p = @{ SiteUrl = $Site; ClientID = $Client; Role = $Role }; if ($Token) { $p.Token = $Token }; Grant-PackTuneStoreAccess @p | Out-Null' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') { Write-UiLog 'PackTune has access to the SharePoint site now.' 'Success'; Write-UiLog $script:StoreGrantConsentNote 'Warning'; Show-Toast 'Access to the SharePoint site granted.' 'ok' }
        $script:StoreState = $null; Start-StoreCheck
    })
}

# ---------------------------------------------------------------- add application: live search in both repositories
$script:AddRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstAddResults.ItemsSource = $script:AddRows
$script:AddResultRows = @()
$script:AddPending = $null
$script:AddTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:AddTimer.Interval = [TimeSpan]::FromMilliseconds(450)

function Test-AppListed($Row) {
    # Is this app in the list already (curated, mine or popular)?
    foreach ($l in @($script:SourceRows) + @($script:MyRows) + @($script:PopularRows)) {
        if (($Row.ChocoId -and $l.ChocoId -and $l.ChocoId -ieq $Row.ChocoId) -or ($Row.WingetId -and $l.WingetId -and $l.WingetId -ieq $Row.WingetId)) { return $true }
    }
    return $false
}
function Set-AddRow($Card, $Src) {
    $tags = New-Object System.Collections.ArrayList
    foreach ($source in 'Winget', 'Chocolatey') {
        if ($Src.Sources -notcontains $source) { continue }
        $version = if ($source -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
        $label = if ($source -eq 'Winget') { 'winget' } else { 'Choco' }
        $rec = $Src.RecommendedMarked -and $Src.Recommended -eq $source
        [void]$tags.Add((New-TagRow ("$label $version").Trim() $(if ($rec) { 'recsrc' } else { 'plain' })))
        if ($rec) { [void]$tags.Add((New-TagRow 'Recommended' 'rec')) }
    }
    $listed = Test-AppListed $Src
    $icon = if ($Src.IconUrl) { Get-IconPreview ([string]$Src.IconUrl) }
    $sub = @($(if ($Src.Downloads -gt 0) { '{0:N0} downloads' -f $Src.Downloads } elseif ($Src.Sources -contains 'Winget' -and $Src.Sources.Count -eq 1) { 'winget only' }), $Src.Category) | Where-Object { $_ }
    Set-Row $Card (@{
        Data = $Src; Title = $Src.Name; Items = $tags.ToArray(); Sub = ($sub -join "  $([char]0x00B7)  ")
        Icon = $icon; MonoVis = (ConvertTo-Vis (-not $icon)); AddText = $(if ($listed) { 'In list' } else { 'Add' }); CanAdd = [string](-not $listed)
    } + (Get-TileStyle $Src.Name))
}
function Update-AddRows {
    $script:AddRows.Clear()
    foreach ($r in @($script:AddResultRows)) { $card = New-Object PackTune.Row; Set-AddRow $card $r; $script:AddRows.Add($card) }
    $n = @($script:AddResultRows).Count
    $ui.TxtAddEmpty.Text = if ($n -eq 0 -and $ui.TxtAddSearch.Text.Trim().Length -ge 2 -and -not (Test-TaskRunning 'addsearch')) { 'Nothing found.' } elseif ($n -eq 0) { 'Type at least two characters.' } else { '' }
    $ui.TxtAddStatus.Text = if (Test-TaskRunning 'addsearch') { 'Searching ...' } elseif ($n) { "$n result(s), most downloaded first" } else { '' }
}
function Start-AddSearch([string]$Term) {
    # One request set at a time (rate limit); typing meanwhile only remembers the latest text, older answers are dropped
    if ($Term.Length -lt 2) { $script:AddResultRows = @(); Update-AddRows; return }
    if (Test-TaskRunning 'addsearch') { $script:AddPending = $Term; return }
    $ui.TxtAddStatus.Text = 'Searching ...'
    [void](Start-UiTask -Kind 'addsearch' -Title "Searching for '$Term'" -Display "Add application: $Term" -Pool $script:UserPool -Hidden -Arguments @{ Term = $Term } -Work 'param($Term) Search-PackTuneApps -SearchPattern $Term -Top 25 -Cache $Shared.Meta' -OnDone {
        param($Result, $Job)
        $term = [string]$Job.Spec.Arguments.Term
        $pending = $script:AddPending; $script:AddPending = $null
        if ($pending -and $pending -ne $term) { Start-AddSearch $pending; return }   # stale: the text changed meanwhile
        if ($script:OpenDialog -ne 'DlgAddApp') { return }
        $script:AddResultRows = @($Result | Where-Object { $_ -and $_.Name })
        $script:MetaDirty = $true
        Update-AddRows
        if ($Job.Status -eq 'failed') { $ui.TxtAddStatus.Text = 'The search failed, see Activity' }
    })
}
$script:AddTimer.Add_Tick({ $script:AddTimer.Stop(); try { Start-AddSearch $ui.TxtAddSearch.Text.Trim() } catch { Show-Error $_.Exception.Message } })
$ui.TxtAddSearch.Add_TextChanged({
    $ui.HintAddSearch.Visibility = ConvertTo-Vis (-not $ui.TxtAddSearch.Text)
    $script:AddTimer.Stop(); $script:AddTimer.Start()   # debounce: search when typing has paused
})
$ui.TxtAddSearch.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $script:AddTimer.Stop(); try { Start-AddSearch $ui.TxtAddSearch.Text.Trim() } catch { Show-Error $_.Exception.Message } } })
Add-Click $ui.BtnAddApp {
    $script:AddResultRows = @(); $script:AddPending = $null
    $ui.TxtAddSearch.Text = ''
    Update-AddRows
    Show-Dialog 'DlgAddApp'
    [void]$ui.TxtAddSearch.Focus()
}
Add-Click $ui.BtnAddClose { $script:AddTimer.Stop(); Close-Dialog }
$ui.LstAddResults.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -isnot [System.Windows.Controls.Button] -or $b.Uid -ne 'add' -or $b.DataContext -isnot [PackTune.Row]) { return }
        $src = $b.DataContext.Data
        $result = Add-PackTuneMyApp -Name $src.Name -ChocoId $src.ChocoId -WingetId $src.WingetId -Tags $src.Tags
        if ($result.Added) {
            Show-Toast "$($src.Name) is in My apps." 'ok'
            Write-UiLog "Added $($src.Name) to my apps."
        }
        else { Show-Toast $result.Reason 'info' }
        # In the list at once; its package infos are read in the background
        Update-CatalogRows
        Update-AppList
        Start-CatalogPrefetch
        Set-AddRow $b.DataContext $src
    }
    catch { Show-Error $_.Exception.Message }
})
Add-Click $ui.BtnDetailRemoveMine {
    $src = $script:DetailRow
    if (-not $src -or -not $src.Mine) { return }
    [void](Remove-PackTuneMyApp -ChocoId $src.ChocoId -WingetId $src.WingetId)
    Set-AppSelected $src $false
    $script:DetailRow = $null
    $ui.PanelDetails.Visibility = 'Collapsed'
    Update-CatalogRows
    Update-AppList
    Show-Toast "$($src.Name) was taken off your list (Intune is unchanged)." 'info'
}

# ---------------------------------------------------------------- selection and details
function Set-AppSelected($Src, [bool]$On) {
    $key = Get-AppKey $Src
    if ($On) { $script:Selected[$key] = $Src } else { $script:Selected.Remove($key) }
    if ($script:CardRows.ContainsKey($key)) { $script:CardRows[$key]['Selected'] = [string][bool]$On }
    Update-SelectionBar
}
function Clear-Selection {
    foreach ($key in @($script:Selected.Keys)) { if ($script:CardRows.ContainsKey($key)) { $script:CardRows[$key]['Selected'] = 'False' } }
    $script:Selected.Clear()
    Update-SelectionBar
}
Add-Click $ui.BtnClearSelection { Clear-Selection }
$ui.CardList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -isnot [System.Windows.Controls.Button] -or $b.DataContext -isnot [PackTune.Row]) { return }
        $src = $b.DataContext.Data
        if ($b.Uid -eq 'details') { Show-AppDetails $src }
        elseif ($b.Uid -eq 'card') { Set-AppSelected $src (-not $script:Selected.Contains((Get-AppKey $src))) }
    }
    catch { Show-Error $_.Exception.Message }
})

function Update-SelectionBar {
    $count = $script:Selected.Count
    $ui.SelectionBar.Visibility = ConvertTo-Vis ($count -gt 0 -and $script:CurrentPage -eq 'Apps')
    $ui.CardList.Padding = if ($ui.SelectionBar.Visibility -eq 'Visible') { '0,0,0,110' } else { '0,0,0,16' }
    $ui.TxtSelectionCount.Text = if ($count -eq 1) { '1 app selected' } else { "$count apps selected" }
    $wingetMissing = (@($script:Selected.Values | Where-Object { (Get-AppSource $_) -eq 'Winget' }).Count -gt 0) -and -not $script:ModuleState.Winget
    $ui.BtnReview.IsEnabled = $count -gt 0 -and (Test-SignedIn) -and $script:ModuleState.Ok -and -not $wingetMissing
    $ui.BtnReview.ToolTip = if (-not (Test-SignedIn)) { 'Sign in first' } elseif (-not $script:ModuleState.Ok) { 'Install the IntuneWin32App module first (Start)' }
                            elseif ($wingetMissing) { 'Install the Microsoft.WinGet.Client module first (Settings > Components)' } else { 'Choose source, version and updates per app, then deploy' }
    Update-SandboxButtons
}
$ui.RbPreferWinget.Add_Checked({ $script:Preferred = 'Winget'; Update-SelectionBar })
$ui.RbPreferChoco.Add_Checked({ $script:Preferred = 'Chocolatey'; Update-SelectionBar })
Add-Click $ui.BtnReview { Show-DeployDialog }

function Show-AppDetails($Src, [switch]$Keep) {
    $script:DetailRow = $Src
    $ui.PanelDetails.Visibility = 'Visible'
    $source = Get-AppSource $Src
    $meta = Get-AppMeta $Src $source
    $other = $Src.Sources | Where-Object { $_ -ne $source } | Select-Object -First 1
    $ui.TxtDetailTitle.Text = $Src.Name
    $ui.BtnDetailRemoveMine.Visibility = ConvertTo-Vis ([bool]$Src.Mine)
    $parts = @(); if ($meta -and $meta.Found -and $meta.Authors) { $parts += $meta.Authors }; if ($meta -and $meta.Found -and $meta.License) { $parts += "license $($meta.License)" }
    $ui.TxtDetailMeta.Text = $parts -join "  $([char]0x00B7)  "
    $lines = foreach ($s in 'Winget', 'Chocolatey') {
        if ($Src.Sources -contains $s) {
            $v = if ($s -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
            "$(Get-SourceLabel $s): $(Get-AppId $Src $s)$(if ($v) { ", version $v" })$(if ($Src.RecommendedMarked -and $Src.Recommended -eq $s) { ' (recommended)' })"
        }
    }
    $ui.TxtDetailSources.Text = @($lines) -join "`n"
    $summary = if ($meta -and $meta.Summary) { $meta.Summary } elseif ($meta -and $meta.Description) { $meta.Description } elseif ($meta -and $meta.Found) { '' } else { 'Package infos are still loading, or the source has none.' }
    $ui.TxtDetailSummary.Text = ([string]$summary -replace '\s+', ' ').Trim()
    $note = (Get-CardNote $Src)
    $ui.BoxLicense.Visibility = ConvertTo-Vis ([bool]$note)
    $ui.TxtLicenseNote.Text = $note
    $ui.BtnDetailSite.IsEnabled = [bool]($meta -and $meta.ProjectUrl)
    $ui.BtnDetailLicense.IsEnabled = [bool]($meta -and $meta.LicenseUrl)
    $ui.BtnDetailRepo.Content = if ($source -eq 'Winget') { 'winget-pkgs' } else { 'chocolatey.org' }
    $t = Get-TileStyle $Src.Name
    $ui.BoxDetailIcon.Background = ConvertTo-Brush $t.TileBg; $ui.TxtDetailMono.Text = $t.Mono; $ui.TxtDetailMono.Foreground = ConvertTo-Brush $t.TileFg
    Update-DetailIcon
    Update-SelectionBar
}
function Get-CardNote($Src) {
    $key = Get-AppKey $Src
    if ($script:CardRows.ContainsKey($key)) { return [string]$script:CardRows[$key]['License'] }
    ''
}
Add-Click $ui.BtnDetailClose { $script:DetailRow = $null; $ui.PanelDetails.Visibility = 'Collapsed'; Update-SelectionBar }

function Update-DetailIcon {
    $src = $script:DetailRow
    if (-not $src) { return }
    $key = Get-AppKey $src
    $custom = $script:CustomIcons[$key]
    $ui.ImgDetail.Source = $null
    $rawUrl = $null
    foreach ($s in 'Chocolatey', 'Winget') { $m = Get-AppMeta $src $s; if (-not $rawUrl -and $m -and $m.Found -and $m.IconUrl) { $rawUrl = [string]$m.IconUrl } }
    try {
        if ($custom) {
            $stream = New-Object IO.MemoryStream(, [Convert]::FromBase64String($custom))
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $stream; $bmp.EndInit(); $bmp.Freeze()
            $stream.Dispose()
            $ui.ImgDetail.Source = $bmp
        }
        elseif ($preview = Get-IconPreview $rawUrl) {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = [Uri]$preview; $bmp.EndInit()
            $ui.ImgDetail.Source = $bmp
        }
    }
    catch { }
    $ui.TxtCustomIcon.Text = if ($custom) { "Custom icon set ($([math]::Round($custom.Length * 3 / 4 / 1024)) KB), used instead of the one from the package source." }
                             elseif ($rawUrl -match '\.svg(\?|#|$)') { 'SVG icon from the package source, converted to PNG with Edge for Intune.' }
                             elseif ($rawUrl) { 'Icon from the package source.' }
                             else { 'This package has no icon; the app is created without one unless you choose a file.' }
    $ui.BtnCustomIconRemove.Visibility = ConvertTo-Vis ([bool]$custom)
}

Add-Click $ui.BtnCustomIcon {
    if (-not $script:DetailRow) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = "Icon for $($script:DetailRow.Name)"
    $dlg.Filter = 'Images (*.png;*.jpg;*.jpeg;*.svg;*.ico)|*.png;*.jpg;*.jpeg;*.svg;*.ico|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    Set-CustomIcon -Key (Get-AppKey $script:DetailRow) -Path $dlg.FileName
}
function Set-CustomIcon([string]$Key, [string]$Path) {
    $window.Cursor = 'Wait'
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 5MB) { throw 'The icon file is larger than 5 MB.' }
        $workPath = Join-Path $script:WorkRoot "icons\$($Key -replace '[^A-Za-z0-9._-]', '_')"
        New-Item -Path $workPath -ItemType Directory -Force | Out-Null
        $png = ConvertTo-PngBytes -Bytes $bytes -WorkPath $workPath
        $script:CustomIcons[$Key] = [Convert]::ToBase64String($png)
        Write-UiLog "Custom icon for $Key taken from $(Split-Path $Path -Leaf)."
    }
    finally { $window.Cursor = $null }
    Update-DetailIcon
}
Add-Click $ui.BtnCustomIconRemove { if ($script:DetailRow) { $script:CustomIcons.Remove((Get-AppKey $script:DetailRow)); Update-DetailIcon } }
Add-Click $ui.BtnDetailSite { $m = Get-AppMeta $script:DetailRow (Get-AppSource $script:DetailRow); if ($m.ProjectUrl -match '^https?://') { Start-Process $m.ProjectUrl } }
Add-Click $ui.BtnDetailLicense { $m = Get-AppMeta $script:DetailRow (Get-AppSource $script:DetailRow); if ($m.LicenseUrl -match '^https?://') { Start-Process $m.LicenseUrl } }
Add-Click $ui.BtnDetailRepo {
    $src = $script:DetailRow; $source = Get-AppSource $src; $id = Get-AppId $src $source
    if ($source -eq 'Winget') {
        $path = @($id.Split('.') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        Start-Process "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$($id.Substring(0, 1).ToLower())/$path"
    }
    else { Start-Process "https://community.chocolatey.org/packages/$([Uri]::EscapeDataString($id))" }
}
Add-Click $ui.BtnDetailTest {
    $src = $script:DetailRow
    if (-not $src) { return }
    $source = Get-AppSource $src
    Start-PackageTest -Package (Get-AppId $src $source) -Source $source -Title $src.Name -Version 'latest' -Policy @{ UpdateMode = $script:Settings.UpdateMode; GraceHours = $script:Settings.GraceHours }
}

# ---------------------------------------------------------------- update modes (deploy dialog, settings)
$script:PolicyModes = @('Off', 'Startup', 'Custom')
$script:PolicyModeLabels = @('Off', 'Automatic, per schedule', 'Ask the user, then install')
$script:PolicyModeHelp = @{
    Off     = 'No automatic updates. A version you release here is installed by Intune right away.'
    Startup = 'Updated when the schedule allows it (default: at startup and in a time window), after a random wait.'
    Custom  = 'The user is offered the update and can install it at once. When the time is up it is installed anyway, without a restart.'
}
foreach ($place in 'Deploy', 'Default') {
    $ui["Cmb${place}Update"].ItemsSource = $script:PolicyModeLabels
    $ui["Cmb${place}GraceUnit"].ItemsSource = @('hours', 'days')
    $ui["Cmb${place}Update"].Add_SelectionChanged({ param($src) Sync-PolicyControls ($src.Name -replace '^Cmb|Update$', '') })
}
$ui.CmbTenantGraceUnit.ItemsSource = @('hours', 'days')
$ui.CmbDeployVersion.ItemsSource = @('Always the newest version', 'Pin the current version')
$ui.CmbDefaultVersion.ItemsSource = @('Always the newest version', 'Pin the current version')
$ui.CmbDeployAssign.ItemsSource = @('Required for all users', 'Available in the Company Portal', 'No assignment')
$script:AssignValues = @('Required', 'Available', 'None')

function Sync-PolicyControls([string]$Place) {
    $mode = $script:PolicyModes[[Math]::Max(0, $ui["Cmb${Place}Update"].SelectedIndex)]
    $ui["Panel${Place}Grace"].Visibility = ConvertTo-Vis ($mode -eq 'Custom')
    $ui["Txt${Place}UpdateHelp"].Text = $script:PolicyModeHelp[$mode]
}
function Set-PolicyControls([string]$Place, [string]$Mode, [int]$GraceHours) {
    $ui["Cmb${Place}Update"].SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:PolicyModes, $Mode))
    $inDays = $GraceHours -gt 0 -and $GraceHours % 24 -eq 0
    $ui["Txt${Place}Grace"].Text = [string]$(if ($inDays) { $GraceHours / 24 } else { $GraceHours })
    $ui["Cmb${Place}GraceUnit"].SelectedIndex = if ($inDays) { 1 } else { 0 }
    Sync-PolicyControls $Place
}
function ConvertTo-GraceHours([string]$Text, [int]$UnitIndex, [bool]$Required) {
    $factor = if ($UnitIndex -eq 1) { 24 } else { 1 }
    $hours = if (([string]$Text).Trim() -match '^\d{1,5}$') { [int]$Text.Trim() * $factor } else { 0 }
    if ($hours -lt 1 -or $hours -gt 2160) {
        if ($Required) { throw 'The time until the update is installed anyway must be between 1 hour and 90 days.' }
        $hours = [int]$script:Settings.GraceHours
    }
    $hours
}
function Read-PolicyControls([string]$Place) {
    $mode = $script:PolicyModes[[Math]::Max(0, $ui["Cmb${Place}Update"].SelectedIndex)]
    @{ UpdateMode = $mode; GraceHours = (ConvertTo-GraceHours $ui["Txt${Place}Grace"].Text $ui["Cmb${Place}GraceUnit"].SelectedIndex ($mode -eq 'Custom')) }
}
function Format-UpdateText([string]$Mode, [int]$GraceHours) {
    switch ($Mode) {
        'Off' { 'Off' }
        'Custom' { 'Ask user, ' + $(if ($GraceHours % 24 -eq 0) { "$($GraceHours / 24) day(s)" } else { "$GraceHours hour(s)" }) }
        default { 'Automatic' }
    }
}
function Compare-PackageVersion([string]$A, [string]$B) {
    $c = Compare-SourceVersion -A $A -B $B
    if ($null -eq $c) { 0 } else { $c }
}

# ---------------------------------------------------------------- schedule text
function Format-ScheduleSummary($S) {
    # The schedule in words: when updates install, and under which conditions
    $dayNames = @{ '1' = 'Mon'; '2' = 'Tue'; '3' = 'Wed'; '4' = 'Thu'; '5' = 'Fri'; '6' = 'Sat'; '7' = 'Sun' }
    $when = @()
    if ($S.TriggerWindow) {
        $days = if ($S.WindowDays -eq '1234567') { 'daily' } elseif ($S.WindowDays -eq '12345') { 'Mon to Fri' } else { (($S.WindowDays.ToCharArray() | ForEach-Object { $dayNames[[string]$_] }) -join ', ') }
        $when += "$days $($S.WindowFrom) to $($S.WindowTo)"
    }
    if ($S.TriggerStart) { $when += 'at PC start' }
    if ($S.TriggerLogon) { $when += 'at user sign-in' }
    $whenText = if ($when.Count) { ($when -join ', or ') } else { 'Not on a schedule' }
    $whenText = $whenText.Substring(0, 1).ToUpper() + $whenText.Substring(1)
    $cond = @()
    if ($S.OnlyOnMains) { $cond += 'only on mains power' }
    if ($S.NoPresentation) { $cond += 'not during presentations' }
    if ($S.NoMetered) { $cond += 'not on a metered network' }
    if ($S.AppNotRunning) { $cond += 'when the app is not in use' }
    if ($S.IdleMinutes -gt 0) { $cond += "after $($S.IdleMinutes) min idle" }
    $condText = if ($cond.Count) { ($cond -join ', ') } else { 'No further conditions' }
    $condText = $condText.Substring(0, 1).ToUpper() + $condText.Substring(1)
    @{ When = $whenText; Conditions = $condText }
}

# ---------------------------------------------------------------- deploy dialog
$script:DeployCombos = New-Object System.Collections.ArrayList
$script:DeploySchedule = $null     # schedule values chosen for this deployment (hashtable), $null = settings default
$script:DeployVersionTexts = @{}

function Get-SourceOptionText($Src, [string]$Source) {
    $v = if ($Source -eq 'Winget') { $Src.WingetVersion } else { $Src.ChocoVersion }
    $other = if ($Source -eq 'Winget') { $Src.ChocoVersion } else { $Src.WingetVersion }
    $id = Get-AppId $Src $Source
    $text = "$(Get-SourceLabel $Source)$(if ($v) { ' ' + $v } elseif ($id -and (Test-MetaMissing $id $Source)) { ' (version loading)' } else { ' (version unknown)' })"
    # Recommended only when both versions are known and this one is newer
    if ($Src.RecommendedMarked -and $Src.Recommended -eq $Source -and $v -and $other) { $text += ', recommended (newer)' }
    $text
}

function Update-DeployVersionTexts {
    $pinned = $ui.CmbDeployVersion.SelectedIndex -eq 1
    foreach ($entry in $script:DeployCombos) {
        $source = $entry.Sources[[Math]::Max(0, $entry.Combo.SelectedIndex)]
        $v = if ($source -eq 'Winget') { $entry.Src.WingetVersion } else { $entry.Src.ChocoVersion }
        $entry.VersionText.Text = if ($pinned) { "Pinned$(if ($v) { ' to ' + $v })" } else { "Always newest$(if ($v) { " ($v)" })" }
    }
    $sources = @($script:DeployCombos | ForEach-Object { $_.Sources[[Math]::Max(0, $_.Combo.SelectedIndex)] } | Select-Object -Unique)
    $ui.TxtDeployDependency.Inlines.Clear()
    $bold = New-Object System.Windows.Documents.Run 'Dependencies are added automatically. '; $bold.FontWeight = 'SemiBold'
    [void]$ui.TxtDeployDependency.Inlines.Add($bold)
    [void]$ui.TxtDeployDependency.Inlines.Add((New-Object System.Windows.Documents.Run 'Every app depends on PackTune Runtime, which puts Chocolatey and winget on the device. It is created first when the tenant does not have it yet.'))
    $notes = @($script:DeployCombos | ForEach-Object { $src = $_.Sources[[Math]::Max(0, $_.Combo.SelectedIndex)]; $n = Get-CardNote $_.Src; if ($n) { "$($_.Src.Name): license note" } })
    $assign = $script:AssignValues[[Math]::Max(0, $ui.CmbDeployAssign.SelectedIndex)]
    $ui.TxtDeployWarn.Text = (@($notes) + @($(if ($assign -eq 'Required') { 'Required installs on every device of all users.' })) | Where-Object { $_ }) -join ' '
}

function Show-DeployDialog {
    if ($script:Selected.Count -eq 0) { throw 'Select at least one app first.' }
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first (Sign in, top right).' }
    if (-not $script:ModuleState.Ok) { throw "IntuneWin32App $($script:MinimumModuleVersion) or newer is required (Start > Get ready)." }
    # The rows as they are now (feed infos may have arrived since the apps were selected)
    foreach ($key in @($script:Selected.Keys)) {
        $fresh = @(@($script:SourceRows) + @($script:SearchRows) | Where-Object { (Get-AppKey $_) -eq $key }) | Select-Object -First 1
        if ($fresh) { $script:Selected[$key] = $fresh }
    }
    $ui.PanelDeployRows.Children.Clear()
    $script:DeployCombos.Clear()
    foreach ($src in $script:Selected.Values) {
        $key = Get-AppKey $src
        $tile = Get-TileStyle $src.Name
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,0,0,0'
        foreach ($w in @(@('Star', 1), @('Pixel', 330), @('Pixel', 150))) {
            $c = New-Object System.Windows.Controls.ColumnDefinition
            $c.Width = [System.Windows.GridLength]::new($w[1], $w[0]); [void]$grid.ColumnDefinitions.Add($c)
        }
        $row = New-Object System.Windows.Controls.Border
        $row.BorderBrush = Get-Brush 'Divider'; $row.BorderThickness = '0,0,0,1'; $row.Padding = '0,10'
        $name = New-Object System.Windows.Controls.StackPanel; $name.Orientation = 'Horizontal'
        $tileBox = New-Object System.Windows.Controls.Border
        $tileBox.Width = 32; $tileBox.Height = 32; $tileBox.CornerRadius = 7; $tileBox.Background = ConvertTo-Brush $tile.TileBg; $tileBox.Margin = '0,0,12,0'
        $letter = New-Object System.Windows.Controls.TextBlock; $letter.Text = $tile.Mono; $letter.FontWeight = 'Bold'; $letter.FontSize = 13; $letter.Foreground = ConvertTo-Brush $tile.TileFg
        $letter.HorizontalAlignment = 'Center'; $letter.VerticalAlignment = 'Center'
        $tileIcon = Get-AppIconUrl $src
        $tileGrid = New-Object System.Windows.Controls.Grid
        [void]$tileGrid.Children.Add($letter)
        if ($tileIcon) {
            $img = New-Object System.Windows.Controls.Image; $img.Margin = '3'; $img.Source = ConvertTo-ImageSource $tileIcon
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
            [void]$tileGrid.Children.Add($img); $letter.Visibility = 'Collapsed'
        }
        $tileBox.Child = $tileGrid
        $label = New-Object System.Windows.Controls.TextBlock; $label.Text = $src.Name; $label.FontWeight = 'SemiBold'; $label.VerticalAlignment = 'Center'
        [void]$name.Children.Add($tileBox); [void]$name.Children.Add($label)
        $combo = New-Object System.Windows.Controls.ComboBox
        $combo.Margin = '0,0,12,0'; $combo.VerticalAlignment = 'Center'; $combo.Width = 316
        $combo.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "Install $($src.Name) with")
        $sources = @($src.Sources)
        $combo.ItemsSource = @($sources | ForEach-Object { Get-SourceOptionText $src $_ })
        $combo.SelectedIndex = [Math]::Max(0, [array]::IndexOf($sources, (Get-AppSource $src)))
        $ver = New-Object System.Windows.Controls.TextBlock; $ver.Foreground = Get-Brush 'Text2'; $ver.VerticalAlignment = 'Center'; $ver.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetColumn($combo, 1); [System.Windows.Controls.Grid]::SetColumn($ver, 2)
        [void]$grid.Children.Add($name); [void]$grid.Children.Add($combo); [void]$grid.Children.Add($ver)
        $row.Child = $grid
        [void]$ui.PanelDeployRows.Children.Add($row)
        [void]$script:DeployCombos.Add(@{ Key = $key; Src = $src; Combo = $combo; Sources = $sources; VersionText = $ver })
        $combo.Add_SelectionChanged({
            foreach ($entry in $script:DeployCombos) { $script:SourceChoice[$entry.Key] = $entry.Sources[[Math]::Max(0, $entry.Combo.SelectedIndex)] }
            Update-DeployVersionTexts
        })
    }
    $n = $script:Selected.Count
    $ui.TxtDeployTitle.Text = "Deploy $n app$(if ($n -ne 1) { 's' }) to $(if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'the tenant' })"
    $ui.BtnDeployGo.Content = "Deploy $n app$(if ($n -ne 1) { 's' })"
    $assignIndex = if ($ui.RbRequired.IsChecked) { 0 } elseif ($ui.RbNone.IsChecked) { 2 } else { 1 }
    $ui.CmbDeployAssign.SelectedIndex = $assignIndex
    $ui.CmbDeployVersion.SelectedIndex = if ($script:Settings.VersionMode -eq 'Pinned') { 1 } else { 0 }
    Set-PolicyControls 'Deploy' $script:Settings.UpdateMode $script:Settings.GraceHours
    $script:DeploySchedule = $null
    Update-DeploySchedule
    Update-DeployVersionTexts
    Show-Dialog 'DlgDeploy'
}
$ui.CmbDeployVersion.Add_SelectionChanged({ if ($script:OpenDialog -eq 'DlgDeploy') { Update-DeployVersionTexts } })
$ui.CmbDeployAssign.Add_SelectionChanged({ if ($script:OpenDialog -eq 'DlgDeploy') { Update-DeployVersionTexts } })

function Update-DeploySchedule {
    $s = if ($script:DeploySchedule) { New-ChocoSchedule -Values $script:DeploySchedule -Base (Get-ChocoScheduleDefaults) } else { Get-ChocoScheduleDefaults }
    $t = Format-ScheduleSummary $s
    $ui.TxtDeploySchedule.Text = "$($t.When). $($t.Conditions)."
}
Add-Click $ui.BtnDeploySchedule {
    $s = if ($script:DeploySchedule) { New-ChocoSchedule -Values $script:DeploySchedule -Base (Get-ChocoScheduleDefaults) } else { Get-ChocoScheduleDefaults }
    Show-ScheduleDialog -Mode 'Deploy' -Schedule $s -Title 'When the new apps update on devices'
}
Add-Click $ui.BtnDeployCancel { Close-Dialog }
Add-Click $ui.BtnDeployGo { Start-Deploy }

function Start-Deploy {
    $assignment = $script:AssignValues[[Math]::Max(0, $ui.CmbDeployAssign.SelectedIndex)]
    $policy = Read-PolicyControls 'Deploy'
    $version = if ($ui.CmbDeployVersion.SelectedIndex -eq 1) { 'current' } else { 'latest' }
    $items = foreach ($entry in $script:DeployCombos) {
        $source = $entry.Sources[[Math]::Max(0, $entry.Combo.SelectedIndex)]
        [pscustomobject]@{ Key = $entry.Key; Src = $entry.Src; Source = $source; Id = (Get-AppId $entry.Src $source); Title = $entry.Src.Name; LicenseNote = (Get-CardNote $entry.Src) }
    }
    $items = @($items)
    $present = @($items | Where-Object { $script:TenantPackages.ContainsKey((Get-MetaKey $_.Id $_.Source)) })
    $todo = @($items | Where-Object { -not $script:TenantPackages.ContainsKey((Get-MetaKey $_.Id $_.Source)) })
    if ($todo.Count -eq 0) { throw "The selected app(s) are already in the tenant ($(($present | ForEach-Object { $_.Title }) -join ', ')). Remove them under 'In tenant' first to deploy them again." }
    if ($present.Count -gt 0) { Write-UiLog "Already in the tenant, left out: $(($present | ForEach-Object { $_.Title }) -join ', ')." 'Warning' }
    $licensed = @($todo | Where-Object LicenseNote)
    if ($licensed.Count -gt 0) {
        $text = ($licensed | ForEach-Object { "- $($_.Title): $($_.LicenseNote)" }) -join "`n"
        if (-not (Confirm-Action "These packages carry a license note:`n`n$text`n`nDeploy them anyway?" 'License notes' 'Deploy anyway' 'Cancel')) { return }
    }
    if ($assignment -eq 'Required' -and -not (Confirm-Action "Required installs the $($todo.Count) app(s) automatically on every device of all users. Continue?" 'Required assignment' 'Continue' 'Cancel')) { return }
    if (@($todo | Where-Object { $_.Source -eq 'Winget' }).Count -and -not $script:ModuleState.Winget) { throw 'winget packages need the Microsoft.WinGet.Client module: install it under Settings > Components.' }
    $schedule = if ($script:DeploySchedule) { (New-ChocoSchedule -Values $script:DeploySchedule -Base (Get-ChocoScheduleDefaults)) } else { $null }
    Update-UiToken
    $work = @'
param($Id, $Source, $Assignment, $Architecture, $IconBase64, $UpdateMode, $GraceHours, $Version, $Schedule)
$Params = @{ Assignment = $Assignment; Architecture = $Architecture; NoIconPrompt = $true; UpdateMode = $UpdateMode; GraceHours = $GraceHours; Version = $Version }
if ($IconBase64) { $Params.IconBase64 = $IconBase64 }
if ($Schedule) { $Params.Schedule = $Schedule }
if ($Source -eq 'Winget') { New-PackTuneWingetApp -WingetId $Id @Params }
else { New-PackTuneChocolateyApp -ChocoName $Id @Params }
'@
    foreach ($item in $todo) {
        $icon = $script:CustomIcons[$item.Key]
        $label = Get-SourceLabel $item.Source
        [void](Start-UiTask -Kind 'deploy' -Title "Deploying $($item.Title) from $label ($assignment)" -Display $item.Title -Package $item.Id -NeedsAuth -Work $work -OnDone {
            param($Result, $Job)
            switch ($Job.Status) {
                'succeeded' {
                    Write-UiLog "[$($Job.Package)] created in Intune." 'Success'
                    $key = Get-MetaKey $Job.Package $Job.Source
                    $script:TenantPackages[$key] = $true
                    $script:RecentDeploys[$key] = Get-Date
                    $appId = @($Result | Where-Object { $_ -is [string] }) | Select-Object -First 1
                    $Job.Row['Open'] = [string]$appId; Update-JobRow $Job
                    Show-Toast "$($Job.Display) was created in Intune." 'ok'
                }
                'skipped' { Show-Toast "$($Job.Display) was skipped: it is already in the tenant." 'warn' }
            }
            $script:TenantApps = $null
            if (-not @($script:Tasks | Where-Object { $_.Job.Kind -eq 'deploy' }).Count) { Start-TenantRefresh }
            Update-AppList
        } -Arguments @{ Id = $item.Id; Source = $item.Source; Assignment = $assignment; Architecture = $script:Settings.Architecture; IconBase64 = $icon; UpdateMode = $policy.UpdateMode; GraceHours = $policy.GraceHours; Version = $version; Schedule = $schedule })
    }
    Write-UiLog "$($todo.Count) deployment(s) queued, assignment $assignment, updates: $(Format-UpdateText $policy.UpdateMode $policy.GraceHours)." 'Info'
    Clear-Selection
    Close-Dialog
    Show-Page 'Activity'
}


# ---------------------------------------------------------------- schedule dialog
$script:SchCtx = @{ Mode = 'App'; App = $null }
$script:SchIntervalValues = @(1, 4, 24)
$script:SchDeadlineValues = @('Install', 'AskClose', 'Close', 'Wait')
$script:SchRestartValues = @('Never', 'Ask', 'OutsideWindow')
$script:SchRetryValues = @('Next', 'None', 'Every')
$ui.SchInterval.ItemsSource = @('Every hour', 'Every 4 hours', 'Once a day')
$ui.SchIdleMin.ItemsSource = @('1', '5', '10', '15', '30', '60')
$ui.SchDeadlineApp.ItemsSource = @('Install anyway', 'Ask, close after the time below', 'Close without asking', 'Wait until it is closed')
$ui.SchRestart.ItemsSource = @('Never, wait for the user', 'Ask the user', 'Outside the time window')
$ui.SchRetry.ItemsSource = @('Retry at the next chance', 'Do not retry', 'Retry several times')
$ui.SchGraceUnit.ItemsSource = @('hours', 'days')
$script:SchDays = 1..7 | ForEach-Object { $ui["SchD$_"] }

function Set-ScheduleControls($S, [int]$GraceHours, [int]$DelayMin, [int]$DelayMax) {
    $ui.SchStart.IsChecked = [bool]$S.TriggerStart; $ui.SchWindow.IsChecked = [bool]$S.TriggerWindow
    $ui.SchFrom.Text = $S.WindowFrom; $ui.SchTo.Text = $S.WindowTo
    for ($d = 1; $d -le 7; $d++) { $ui["SchD$d"].IsChecked = ([string]$S.WindowDays).Contains([string]$d) }
    $ui.SchIdle.IsChecked = $S.IdleMinutes -gt 0
    $idleIndex = [array]::IndexOf(@('1', '5', '10', '15', '30', '60'), [string]$S.IdleMinutes); $ui.SchIdleMin.SelectedIndex = if ($idleIndex -ge 0) { $idleIndex } else { 2 }
    $ui.SchLogon.IsChecked = [bool]$S.TriggerLogon
    $ui.SchMains.IsChecked = [bool]$S.OnlyOnMains; $ui.SchPresentation.IsChecked = [bool]$S.NoPresentation
    $ui.SchMetered.IsChecked = [bool]$S.NoMetered; $ui.SchNotRunning.IsChecked = [bool]$S.AppNotRunning
    $ui.SchInterval.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchIntervalValues, [int]$S.CheckIntervalHours))
    $ui.SchDeadlineApp.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchDeadlineValues, [string]$S.DeadlineAppMode))
    $ui.SchRestart.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchRestartValues, [string]$S.RestartMode))
    $ui.SchRetry.SelectedIndex = [Math]::Max(0, [array]::IndexOf($script:SchRetryValues, [string]$S.RetryMode))
    $ui.SchCloseAfter.Text = [string]$S.CloseAfterMinutes; $ui.SchRetryCount.Text = [string]$S.RetryCount; $ui.SchRetryHours.Text = [string]$S.RetryHours
    $ui.SchProcesses.Text = [string]$S.ProcessNames
    $inDays = $GraceHours -gt 0 -and $GraceHours % 24 -eq 0
    $ui.SchGrace.Text = [string]$(if ($inDays) { $GraceHours / 24 } else { $GraceHours }); $ui.SchGraceUnit.SelectedIndex = if ($inDays) { 1 } else { 0 }
    $ui.SchDelayMin.Text = [string]$DelayMin; $ui.SchDelayMax.Text = [string]$DelayMax
}

function Read-ScheduleControls {
    $days = -join (1..7 | Where-Object { $ui["SchD$_"].IsChecked } | ForEach-Object { [string]$_ })
    $values = [ordered]@{
        TriggerStart = [bool]$ui.SchStart.IsChecked; TriggerWindow = [bool]$ui.SchWindow.IsChecked
        WindowFrom = $ui.SchFrom.Text.Trim(); WindowTo = $ui.SchTo.Text.Trim(); WindowDays = $days
        IdleMinutes = $(if ($ui.SchIdle.IsChecked) { [int]$ui.SchIdleMin.SelectedItem } else { 0 })
        TriggerLogon = [bool]$ui.SchLogon.IsChecked
        OnlyOnMains = [bool]$ui.SchMains.IsChecked; NoPresentation = [bool]$ui.SchPresentation.IsChecked; NoMetered = [bool]$ui.SchMetered.IsChecked; AppNotRunning = [bool]$ui.SchNotRunning.IsChecked
        CheckIntervalHours = $script:SchIntervalValues[[Math]::Max(0, $ui.SchInterval.SelectedIndex)]
        DeadlineAppMode = $script:SchDeadlineValues[[Math]::Max(0, $ui.SchDeadlineApp.SelectedIndex)]
        CloseAfterMinutes = $ui.SchCloseAfter.Text.Trim()
        RestartMode = $script:SchRestartValues[[Math]::Max(0, $ui.SchRestart.SelectedIndex)]
        RetryMode = $script:SchRetryValues[[Math]::Max(0, $ui.SchRetry.SelectedIndex)]
        RetryCount = $ui.SchRetryCount.Text.Trim(); RetryHours = $ui.SchRetryHours.Text.Trim()
        ProcessNames = $ui.SchProcesses.Text.Trim()
    }
    if (-not $values.TriggerWindow) { $values.WindowDays = $(if ($days) { $days } else { '1234567' }) }
    $schedule = New-ChocoSchedule -Values $values   # validates, throws a readable message
    if ($schedule.IdleMinutes -eq 0 -and $ui.SchIdle.IsChecked) { throw 'Choose the idle time in minutes.' }
    $delayMin = 0; $delayMax = 0
    if (-not ([int]::TryParse($ui.SchDelayMin.Text.Trim(), [ref]$delayMin) -and [int]::TryParse($ui.SchDelayMax.Text.Trim(), [ref]$delayMax)) -or $delayMin -lt 0 -or $delayMax -lt $delayMin) { throw 'The random wait needs two whole minutes, the second not smaller than the first.' }
    @{ Values = $values; Schedule = $schedule; GraceHours = (ConvertTo-GraceHours $ui.SchGrace.Text $ui.SchGraceUnit.SelectedIndex $false); DelayMin = $delayMin; DelayMax = $delayMax }
}

function Update-ScheduleSummary {
    try {
        $r = Read-ScheduleControls
        $t = Format-ScheduleSummary $r.Schedule
        $ui.TxtScheduleSummary.Text = "Summary: $($t.When). $($t.Conditions)."
    }
    catch { $ui.TxtScheduleSummary.Text = $_.Exception.Message }
}

function Update-ScheduleApplyButton {
    $default = $script:SchCtx.Mode -eq 'Default' -or ($script:SchCtx.Mode -eq 'App' -and $ui.RbSchDefault.IsChecked)
    $ui.BtnScheduleApply.Content = switch ($true) { ($script:SchCtx.Mode -eq 'Deploy') { 'Use for these apps' } $default { 'Save as default' } default { 'Apply in Intune' } }
    $edit = $default
    foreach ($n in 'SchDelayMin', 'SchDelayMax') { $ui[$n].IsEnabled = $edit }
    $ui.SchDelayMin.ToolTip = if ($edit) { $null } else { 'The random wait is set in Settings > Package sources.' }
}

function Show-ScheduleDialog {
    param([ValidateSet('App', 'Default', 'Deploy')][string]$Mode, $Schedule, [string]$Title, $App, [int]$GraceHours = $script:Settings.GraceHours)
    $script:SchCtx = @{ Mode = $Mode; App = $App }
    $ui.TxtScheduleTitle.Text = $Title
    $ui.SegSchedule.Visibility = ConvertTo-Vis ($Mode -eq 'App')
    $ui.RbSchThis.IsChecked = $true
    $dMin = if ($App -and $App.DelayMin) { $App.DelayMin } else { $script:Settings.UpdateDelayMinMinutes }
    $dMax = if ($App -and $App.DelayMax) { $App.DelayMax } else { $script:Settings.UpdateDelayMaxMinutes }
    Set-ScheduleControls $Schedule $GraceHours $script:Settings.UpdateDelayMinMinutes $script:Settings.UpdateDelayMaxMinutes
    $ui.TxtSchNotRunning.Text = if ($App) { "$($App.DisplayName) is not in use" } else { 'The app is not in use' }
    Update-ScheduleApplyButton
    Update-ScheduleSummary
    Show-Dialog 'DlgSchedule'
}
foreach ($n in 'SchStart', 'SchWindow', 'SchIdle', 'SchLogon', 'SchMains', 'SchPresentation', 'SchMetered', 'SchNotRunning', 'SchD1', 'SchD2', 'SchD3', 'SchD4', 'SchD5', 'SchD6', 'SchD7') {
    $ui[$n].Add_Click({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleSummary } })
}
foreach ($n in 'SchFrom', 'SchTo') { $ui[$n].Add_TextChanged({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleSummary } }) }
$ui.RbSchThis.Add_Checked({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleApplyButton } })
$ui.RbSchDefault.Add_Checked({ if ($script:OpenDialog -eq 'DlgSchedule') { Update-ScheduleApplyButton } })

function Save-DefaultSchedule($R) {
    $s = Get-PackTuneSettings
    $s.UpdateSchedule = ($R.Values | ConvertTo-Json -Compress)
    $s.UpdateDelayMinMinutes = $R.DelayMin; $s.UpdateDelayMaxMinutes = $R.DelayMax; $s.GraceHours = $R.GraceHours
    [void](Save-PackTuneSettings -Settings $s)
    $script:Settings = Get-PackTuneSettings
    Write-UiLog 'Schedule for new apps saved in the settings.' 'Success'
    Show-Toast 'Schedule for new apps saved.' 'ok'
    Update-SettingsView
}
Add-Click $ui.BtnScheduleCancel { if ($script:SchCtx.Mode -eq 'Deploy') { Show-Dialog 'DlgDeploy' } else { Close-Dialog } }
Add-Click $ui.BtnScheduleApply {
    $r = Read-ScheduleControls
    switch ($script:SchCtx.Mode) {
        'Deploy' { $script:DeploySchedule = $r.Values; Update-DeploySchedule; Show-Dialog 'DlgDeploy' }
        'Default' { Save-DefaultSchedule $r; Close-Dialog }
        default {
            if ($ui.RbSchDefault.IsChecked) { Save-DefaultSchedule $r; Close-Dialog }
            else {
                $app = $script:SchCtx.App
                $policy = Read-TenantPolicy
                $version = Get-TenantVersion
                $script:TenantSchedule = $r.Values
                Close-Dialog
                Start-AppApply -App $app -Version $version -Policy @{ UpdateMode = $policy.UpdateMode; GraceHours = $(if ($policy.UpdateMode -eq 'Custom') { $policy.GraceHours } else { $r.GraceHours }) } -Schedule $r.Values
            }
        }
    }
}

# ---------------------------------------------------------------- tenant
function Update-UiToken {
    # Renews the sign-in on the UI thread before it is handed to a task (silent, at most one short web request)
    try {
        Update-PackTuneToken 3>&1 6>&1 | ForEach-Object { Write-UiLog ([string]$_) $(if ($_ -is [System.Management.Automation.WarningRecord]) { 'Warning' } else { 'Info' }) }
        $script:Shared.Auth = Get-PackTuneAuthState
    }
    catch { Write-UiLog $_.Exception.Message 'Warning' }
}

$script:TenantRowList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstTenant.ItemsSource = $script:TenantRowList
$script:DeviceCounts = @{}
$script:TenantPolicyApp = ''
$script:TenantSchedule = $null

# ---------------------------------------------------------------- app icons in the tenant views
# 1. the icon of the package (same cache as the Apps page; winget apps borrow the one of the same catalog app),
# 2. the icon stored in the Intune app (read lazily in the background, kept on disk next to the other icons),
# 3. the letter tile.
$script:AppIconCache = @{}     # Intune app id -> icon file
$script:AppIconTried = @{}     # "app id|modified" -> asked once

function ConvertTo-ImageSource($Path) {
    if (-not $Path) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) { $bmp.CacheOption = 'OnLoad' }   # local file: read now; a URL loads in the background
        $bmp.UriSource = [Uri][string]$Path
        $bmp.EndInit()
        $bmp
    }
    catch { $null }
}

function Get-IconFromMeta([string]$Id, [string]$Source) {
    if (-not $Id) { return $null }
    $meta = $script:Shared.Meta[(Get-MetaKey $Id $Source)]
    if ($meta -and $meta.Found -and $meta.IconUrl) { $p = Get-IconPreview ([string]$meta.IconUrl); if ($p) { return [string]$p } }
}

function Get-PackageIcon([string]$Package, [string]$Source) {
    # Icon of a package; winget packages rarely have one and borrow it from the same app's Chocolatey package
    $icon = Get-IconFromMeta $Package $Source
    if ($icon) { return $icon }
    $entry = @($script:Catalog | Where-Object { ($_.WingetId -and $_.WingetId -ieq $Package) -or ($_.Id -and $_.Id -ieq $Package) }) | Select-Object -First 1
    if ($entry) {
        $icon = Get-IconFromMeta $entry.Id 'Chocolatey'
        if (-not $icon) { $icon = Get-IconFromMeta $entry.WingetId 'Winget' }
        return $icon
    }
}

function Get-AppIconFile([string]$AppId, [string]$Modified) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$AppId|$Modified")) | ForEach-Object { $_.ToString('x2') })
    [string](Join-Path $script:IconCacheDir "app-$hash.png")
}

function Get-TenantAppIcon($App) {
    if ($App.IsChocolatey) { $icon = Get-IconFromMeta 'chocolatey' 'Chocolatey'; if ($icon) { return $icon } }
    elseif ($App.Package) { $icon = Get-PackageIcon $App.Package $App.Source; if ($icon) { return $icon } }
    $file = $script:AppIconCache[$App.Id]
    if (-not $file) { $disk = Get-AppIconFile $App.Id $App.Modified; if (Test-Path $disk) { $file = $disk; $script:AppIconCache[$App.Id] = $disk } }
    if ($file) { return [string]$file }
}

$script:AppIconWork = @'
param($Items, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
foreach ($Item in $Items) {
    try {
        $App = Invoke-InsightGraph $Ctx GET "/beta/deviceAppManagement/mobileApps/$($Item.Id)?`$select=largeIcon"
        if ($App.largeIcon -and $App.largeIcon.value) {
            New-Item -ItemType Directory -Path (Split-Path $Item.File) -Force | Out-Null
            [IO.File]::WriteAllBytes($Item.File, [Convert]::FromBase64String([string]$App.largeIcon.value))
            [pscustomobject]@{ Id = $Item.Id; File = $Item.File }
        }
    }
    catch { }   # no icon for this app: the letter tile stays
}
'@

function Start-AppIconTask {
    # Icons stored in the Intune apps that have no package icon: one single-app read each, in the background
    if (-not (Test-SignedIn) -or $null -eq $script:TenantApps -or (Test-TaskRunning 'appicons') -or (Test-TaskRunning 'meta')) { return }
    $apps = @($script:TenantApps | Where-Object { -not $_.IsChocolatey }) + $(if ($script:RuntimeId) { [pscustomobject]@{ Id = $script:RuntimeId; Modified = ''; IsDependency = $true } })
    $items = foreach ($app in @($apps | Where-Object { $_ })) {
        if (Get-TenantAppIcon $app) { continue }
        $key = "$($app.Id)|$($app.Modified)"
        if ($script:AppIconTried.ContainsKey($key)) { continue }
        $script:AppIconTried[$key] = $true
        @{ Id = [string]$app.Id; File = (Get-AppIconFile $app.Id $app.Modified) }
    }
    $items = @($items)
    if ($items.Count -eq 0) { return }
    [void](Start-UiTask -Kind 'appicons' -Title 'Reading the app icons from Intune' -Hidden -NeedsAuth -Pool $script:MetaPool -Arguments @{ Items = $items; Fake = $script:InsightFake } -Work $script:AppIconWork -OnDone {
        param($Result, $Job)
        foreach ($r in @($Result | Where-Object { $_ -and $_.File })) { $script:AppIconCache[$r.Id] = [string]$r.File }
        Update-TenantRows
        if ($script:CurrentPage -eq 'Status' -and $script:StatusApp) { Set-StatusIcon }
    })
}

function Start-TenantRefresh {
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first.' }
    if (Test-TaskRunning 'tenant') { return }
    $ui.TxtTenantCount.Text = 'Reading the apps in the tenant ...'
    Update-UiToken
    $work = @'
Get-PackTuneTenantApps | ForEach-Object {
    $Intents = ''
    try { $Intents = (@(Get-PackTuneAppIntents -AppId $_.Id) -join ',') } catch { }
    [pscustomobject]@{
        Id = [string]$_.Id; DisplayName = [string]$_.DisplayName; Package = [string]$_.Package; Source = [string]$_.Source; IsChocolatey = [bool]$_.IsChocolatey; Created = [string]$_.Created
        Version = [string]$_.Version; UpdateMode = [string]$_.UpdateMode; GraceHours = [int]$_.GraceHours; HasPolicy = [bool]$_.HasPolicy; Intents = $Intents; Schedule = $_.Schedule
    }
}
'@
    [void](Start-UiTask -Kind 'tenant' -Title 'Reading the apps this tool created in the tenant' -Display 'Tenant apps' -Hidden -NeedsAuth -Work $work -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'failed') {
            $ui.TxtTenantCount.Text = if ($script:GraphDown -and @($script:TenantApps).Count) { "$(@($script:TenantApps).Count) app(s) - last known list, not current" } elseif ($script:GraphDown) { "Can't read the tenant right now - see the banner" } else { 'Could not read the tenant, see Activity' }
            Update-Readiness; Complete-SetupStep $false 'reading the tenant'; return
        }
        $script:TenantApps = @($Result | Where-Object { $_ -and $_.Id } | ForEach-Object {
            $_ | Add-Member -NotePropertyName LatestVersion -NotePropertyValue '' -Force -PassThru | Add-Member -NotePropertyName UpdateAvailable -NotePropertyValue $false -Force -PassThru
        } | Sort-Object { -not $_.IsChocolatey }, DisplayName)
        # Catalog and search mark what is already there, including apps created in the last minutes that Graph does not list yet
        $script:TenantPackages = @{}
        foreach ($app in $script:TenantApps) { if ($app.Package -and -not $app.IsChocolatey) { $script:TenantPackages[(Get-MetaKey $app.Package $app.Source)] = $true } }
        foreach ($key in @($script:RecentDeploys.Keys)) {
            if ($script:RecentDeploys[$key] -gt (Get-Date).AddMinutes(-5)) { $script:TenantPackages[$key] = $true } else { $script:RecentDeploys.Remove($key) }
        }
        $items = foreach ($app in $script:TenantApps) { if ($app.Package -and -not $app.IsChocolatey) { @{ Source = $app.Source; Id = $app.Package } } }
        Start-MetaPrefetch -Items (@($items) + @(@{ Source = 'Chocolatey'; Id = 'chocolatey' }))
        Update-TenantRows -Force
        Update-AppList
        Start-AppIconTask
        Start-DependencyCheck
        Start-RuntimeCheck
        Start-StatusCheck
        Start-CountsTask
        Start-SupersededCheck
        Update-Readiness
    })
    Update-Readiness
}
Add-Click $ui.BtnTenantRefresh { $script:TenantApps = $script:TenantApps; Start-TenantRefresh }

function Start-CountsTask {
    $ids = @($script:TenantApps | Where-Object { -not $_.IsChocolatey -and $_.Package } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0 -or (Test-TaskRunning 'counts')) { return }
    $work = @'
param($Ids, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
foreach ($Id in $Ids) {
    try { $S = Get-InsightAppInstallStatus -Context $Ctx -AppId $Id; [pscustomobject]@{ Id = $Id; Installed = $S.Installed; Failed = $S.Failed; Pending = $S.Pending; Stale = $S.NotReported7Days } }
    catch { [pscustomobject]@{ Id = $Id; Error = $_.Exception.Message } }
}
'@
    [void](Start-UiTask -Kind 'counts' -Title 'Reading the install counts' -Hidden -NeedsAuth -Arguments @{ Ids = $ids; Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        foreach ($r in @($Result | Where-Object { $_ -and $_.Id })) { $script:DeviceCounts[$r.Id] = $r }
        Update-TenantRows
    })
}

function Get-IntentText($App) {
    if ($App.IsChocolatey -or $App.IsDependency) { return 'Automatic' }
    $i = @([string]$App.Intents -split ',' | Where-Object { $_ })
    if ($i -contains 'required') { 'Required' } elseif ($i -contains 'available') { 'Available' } else { 'None' }
}

function Update-TenantRows {
    param([switch]$Force)
    if ($null -eq $script:TenantApps) {
        $script:TenantRowList.Clear()
        $ui.TxtTenantEmpty.Visibility = 'Visible'
        $ui.TxtTenantEmpty.Text = if (Test-SignedIn) { 'Reading the apps in the tenant ...' } else { 'Sign in to see the apps this tool created in your tenant.' }
        $ui.TxtTenantCount.Text = if (Test-SignedIn) { 'Reading the apps in the tenant ...' } else { 'Sign in to see the apps this tool created in your tenant.' }
        $ui.BannerRelease.Visibility = 'Collapsed'; $ui.BannerRuntime.Visibility = 'Collapsed'; $ui.BannerCleanup.Visibility = 'Collapsed'
        Update-TenantBadge
        Update-TenantButtons
        return
    }
    foreach ($app in $script:TenantApps) {
        if (-not $app.Package -or $app.IsChocolatey) { continue }
        $meta = $script:Shared.Meta[(Get-MetaKey $app.Package $app.Source)]
        $latest = if ($meta -and $meta.Found) { [string]$meta.Version } else { '' }
        $app.LatestVersion = $latest
        $app.UpdateAvailable = [bool]($app.Version -and $latest -and (Compare-PackageVersion $latest $app.Version) -gt 0)
    }
    $selected = if ($ui.LstTenant.SelectedItem) { $ui.LstTenant.SelectedItem.Data.Id } else { $null }
    $list = New-Object System.Collections.ArrayList
    foreach ($app in $script:TenantApps) { if (-not $app.IsChocolatey) { [void]$list.Add($app) } }
    if ($script:RuntimeId) {
        [void]$list.Add([pscustomobject]@{ Id = $script:RuntimeId; DisplayName = 'PackTune Runtime'; Package = ''; Source = 'Winget'; IsChocolatey = $false; IsDependency = $true; Version = ''; UpdateMode = ''; GraceHours = 0; Intents = ''; Schedule = $null; LatestVersion = ''; UpdateAvailable = $false })
    }
    # The old dependency apps stay in the list until they are removed (Remove old dependency apps)
    if ($script:RuntimeInfo) {
        foreach ($o in @($script:RuntimeInfo.OldDependencyApps)) {
            [void]$list.Add([pscustomobject]@{ Id = $o.Id; DisplayName = $o.DisplayName; Package = ''; Source = 'Chocolatey'; IsChocolatey = ($o.Kind -eq 'Chocolatey'); IsDependency = $true; IsOld = $true; Version = ''; UpdateMode = ''; GraceHours = 0; Intents = ''; Schedule = $null; LatestVersion = ''; UpdateAvailable = $false })
        }
    }
    $deps = @($list | Where-Object { $_.IsChocolatey -or $_.IsDependency })
    $ordered = @($deps) + @($list | Where-Object { -not ($_.IsChocolatey -or $_.IsDependency) })
    $rows = foreach ($app in $ordered) {
        $count = $script:DeviceCounts[$app.Id]
        $isDep = $app.IsChocolatey -or $app.IsDependency
        $title = if ($app.IsOld) { "$($app.DisplayName) (old)" } elseif ($app.IsChocolatey) { 'Chocolatey' } else { $app.DisplayName }
        $sub = if ($app.IsOld) { 'Old dependency app, replaced by PackTune Runtime' } elseif ($app.IsDependency) { 'Dependency of all apps: Chocolatey and winget for SYSTEM' } else { "$($app.Package) $([char]0x00B7) $(Get-SourceLabel $app.Source)" }
        $ok = if ($count -and -not $count.Error) { "$($count.Installed) installed" } elseif ($isDep) { '' } else { '-' }
        $bad = if ($count -and -not $count.Error) { @($(if ($count.Failed) { "$($count.Failed) failed" }), $(if ($count.Pending) { "$($count.Pending) pending" })) | Where-Object { $_ } | Select-Object -First 1 } else { '' }
        $updates = if ($isDep) { 'Updated daily' } elseif ($app.UpdateMode -eq 'Custom') { "Ask user, $(if ($app.GraceHours % 24 -eq 0) { "$($app.GraceHours / 24) days" } else { "$($app.GraceHours) h" })" } elseif ($app.UpdateMode -eq 'Off') { 'Off' } else { if ($app.Schedule.TriggerStart -and -not $app.Schedule.TriggerWindow) { 'At startup' } else { 'Automatic' } }
        $icon = Get-TenantAppIcon $app
        New-Row (@{
            Data = $app; Title = $title; Sub = $sub
            Version = $(if ($isDep) { 'latest' } elseif ($app.Version) { $app.Version } else { 'Always newest' })
            Newer = $(if ($app.UpdateAvailable) { "$($app.LatestVersion) available" } else { '' }); NewerVis = (ConvertTo-Vis $app.UpdateAvailable)
            Updates = $updates; Assigned = (Get-IntentText $app); Ok = $ok; Bad = $bad; BadVis = (ConvertTo-Vis ([bool]$bad)); Icon = $icon; MonoVis = (ConvertTo-Vis (-not $icon))
        } + (Get-TileStyle $title))
    }
    $rows = @($rows)
    $keys = ($ordered | ForEach-Object { $_.Id }) -join '|'
    $same = $keys -eq $script:TenantKeys
    if ($same -and -not $Force) {
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $old = $script:TenantRowList[$i]
            foreach ($k in 'Newer', 'NewerVis', 'Ok', 'Bad', 'BadVis', 'Updates', 'Version', 'Assigned', 'Icon', 'MonoVis') { $old[$k] = $rows[$i][$k] }
            $old.Data = $rows[$i].Data
        }
    }
    else {
        $script:TenantKeys = $keys
        $script:TenantRowList.Clear()
        foreach ($r in $rows) { $script:TenantRowList.Add($r) }
        if ($selected) { $ui.LstTenant.SelectedItem = @($script:TenantRowList | Where-Object { $_.Data.Id -eq $selected })[0] }
    }
    $ui.TxtTenantEmpty.Visibility = ConvertTo-Vis ($rows.Count -eq 0)
    $ui.TxtTenantEmpty.Text = 'This tool has not created any app in the tenant yet. Pick apps under Apps.'
    $apps = @($ordered | Where-Object { -not ($_.IsChocolatey -or $_.IsDependency) }).Count
    $tenant = if ($script:Settings.TenantID) { $script:Settings.TenantID } else { 'the tenant' }
    $ui.TxtTenantCount.Text = "$apps app$(if ($apps -ne 1) { 's' }) and $($deps.Count) dependency app$(if ($deps.Count -ne 1) { 's' }) this tool created in $tenant$(if ($script:GraphDown) { ' (last known list, not current)' })"
    # Banners
    $updates = @($ordered | Where-Object UpdateAvailable)
    if ($updates.Count) {
        $u = $updates[0]
        $ui.BannerRelease.Visibility = 'Visible'
        $ui.TxtBannerRelease.Inlines.Clear()
        $b = New-Object System.Windows.Documents.Run "$($u.DisplayName) $($u.LatestVersion) is available."; $b.FontWeight = 'Bold'
        [void]$ui.TxtBannerRelease.Inlines.Add($b)
        [void]$ui.TxtBannerRelease.Inlines.Add((New-Object System.Windows.Documents.Run " The app is pinned to $($u.Version). Release it when you are ready.$(if ($updates.Count -gt 1) { " $($updates.Count - 1) more app(s) have updates." })"))
        $ui.BtnBannerRelease.Content = "Release $($u.LatestVersion)"
        $ui.BtnBannerRelease.Uid = $u.Id
    }
    else { $ui.BannerRelease.Visibility = 'Collapsed' }
    $noRuntime = @($script:WingetNoRuntime); $info = $script:RuntimeInfo
    $ui.BannerRuntime.Visibility = ConvertTo-Vis ($info -and $info.State -eq 'Migrate' -and $noRuntime.Count -gt 0)
    $ui.TxtBannerRuntime.Text = "$($noRuntime.Count) app$(if ($noRuntime.Count -ne 1) { 's' }) still use$(if ($noRuntime.Count -eq 1) { 's' }) the old dependency apps (Chocolatey, winget runtime). PackTune Runtime replaces them."
    $ui.BtnBannerRuntime.Content = 'Switch to PackTune Runtime'
    $unusedOld = @(if ($info) { $info.UnusedOld })
    $ui.BannerOldDeps.Visibility = ConvertTo-Vis ($unusedOld.Count -gt 0)
    $ui.TxtBannerOldDeps.Text = "$($unusedOld.Count) old dependency app$(if ($unusedOld.Count -ne 1) { 's' }) ($(($unusedOld | ForEach-Object { $_.DisplayName }) -join ', ')) no longer $(if ($unusedOld.Count -ne 1) { 'are' } else { 'is' }) used by any app."
    $old = @($script:SupersededOld)
    $ui.BannerCleanup.Visibility = ConvertTo-Vis ($old.Count -gt 0)
    $ui.TxtBannerCleanup.Text = "$($old.Count) old app version$(if ($old.Count -ne 1) { 's' }) $(if ($old.Count -ne 1) { 'are' } else { 'is' }) no longer installed on any device."
    Update-TenantBadge
    Update-TenantButtons
}
$script:TenantKeys = ''
$script:WingetNoRuntime = @()

function Update-TenantBadge {
    $updates = @($script:TenantApps | Where-Object UpdateAvailable).Count
    $problems = @($script:DeviceCounts.Values | Where-Object { $_.Failed } | ForEach-Object { [int]$_.Failed } | Measure-Object -Sum).Sum
    $text = if ($updates) { "$updates update$(if ($updates -ne 1) { 's' })" } elseif ($problems) { "$problems problem$(if ($problems -ne 1) { 's' })" } else { '' }
    $ui.BadgeTenant.Visibility = ConvertTo-Vis ([bool]$text)
    $ui.TxtBadgeTenant.Text = $text
    $ui.BadgeTenant.Background = if ($updates -or -not $problems) { Get-Brush 'WarningBg' } else { Get-Brush 'ErrorBg' }
    $ui.TxtBadgeTenant.Foreground = if ($updates -or -not $problems) { Get-Brush 'Warning' } else { Get-Brush 'Danger' }
}

function Start-RuntimeCheck { Start-DependencyCheck }   # the runtime state replaces the separate winget check

# ---------------------------------------------------------------- clean up superseded old app versions
$script:InstallCountFake = ''     # tests only: script text (param($AppId) -> device count) instead of the Graph query
$script:SupersededOld = @()
function Start-SupersededCheck {
    # Old versions of released apps that no device reports installed any more (hidden; Graph install counts)
    if (-not (Test-SignedIn) -or (Test-TaskRunning 'supercheck')) { return }
    $work = 'param($CountFake) $P = @{ WhatIf = $true }; if ($CountFake) { $P.InstallCount = [scriptblock]::Create($CountFake) }; Remove-PackTuneSupersededApps @P'
    [void](Start-UiTask -Kind 'supercheck' -Title 'Checking superseded old app versions' -Hidden -NeedsAuth -Arguments @{ CountFake = $script:InstallCountFake } -Work $work -OnDone {
        param($Result, $Job)
        $script:SupersededOld = @($Result | Where-Object { $_ -and $_.OldId -and $null -ne $_.InstalledCount -and $_.InstalledCount -eq 0 })
        Update-TenantRows
    })
}
Add-Click $ui.BtnBannerCleanup {
    $old = @($script:SupersededOld)
    if ($old.Count -eq 0) { return }
    $list = ($old | ForEach-Object { "- $($_.OldName) $($_.OldVersion) (replaced by $($_.NewVersion))" }) -join "`n"
    if (-not (Confirm-Action "Remove these old app versions from Intune?`n`n$list`n`nNo device reports them installed any more. Apps that are still installed somewhere stay." 'Clean up' 'Remove' 'Cancel')) { return }
    Update-UiToken
    $work = 'param($Ids, $CountFake) $P = @{ AppId = $Ids }; if ($CountFake) { $P.InstallCount = [scriptblock]::Create($CountFake) }; Remove-PackTuneSupersededApps @P'
    [void](Start-UiTask -Kind 'cleanup' -Title "Removing $($old.Count) old app version(s)" -Display 'Clean up old versions' -NeedsAuth -Arguments @{ Ids = @($old | ForEach-Object { $_.OldId }); CountFake = $script:InstallCountFake } -Work $work -OnDone {
        param($Result, $Job)
        $removed = @($Result | Where-Object { $_.Removed }).Count
        if ($Job.Status -eq 'succeeded') { Show-Toast "$removed old app version(s) removed." 'ok' }
        $script:SupersededOld = @(); $script:TenantApps = $null
        Start-TenantRefresh
    })
}
Add-Click $ui.BtnBannerRuntime { Start-RuntimeSwitch }
function Start-RuntimeSwitch {
    # Moves the apps from the old dependency apps (Chocolatey, winget runtime) to PackTune Runtime; asks first
    $apps = @($script:WingetNoRuntime)
    if ($apps.Count -eq 0) { return }
    $list = ($apps | Select-Object -First 12 | ForEach-Object { "- $($_.DisplayName)" }) -join "`n"
    if ($apps.Count -gt 12) { $list += "`n- and $($apps.Count - 12) more" }
    if (-not (Confirm-Action "Switch $($apps.Count) app(s) to PackTune Runtime?`n`n$list`n`nEach app depends on PackTune Runtime instead of the old dependency apps. Nothing is removed, and nothing changes on the devices now." 'Switch to PackTune Runtime' 'Switch' 'Cancel')) { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'runtime' -Title 'Switching the apps to PackTune Runtime' -Display 'Switch to PackTune Runtime' -NeedsAuth -Arguments @{ Ids = @($apps | ForEach-Object { $_.Id }) } -Work 'param($Ids) Switch-PackTuneAppsToRuntime -AppId $Ids' -OnDone {
        param($Result, $Job)
        $n = @($Result | Where-Object { $_ -and $_.Id }).Count
        if ($Job.Status -eq 'succeeded') { Show-Toast "$n app(s) now depend on PackTune Runtime." 'ok' }
        else { Write-UiLog "[Switch to PackTune Runtime] not all apps were switched, see the messages above." 'Error'; Show-Toast 'Not all apps could be switched to PackTune Runtime, see Activity.' 'bad' }
        $script:RuntimeInfo = $null; $script:WingetNoRuntime = @()
        Start-DependencyCheck
        Update-TenantRows
        Update-Readiness
    })
}
Add-Click $ui.BtnBannerOldDeps { Start-OldDependencyCleanup }
function Start-OldDependencyCleanup {
    # Removes the old dependency apps nothing depends on any more; only on request, after a confirmation
    $old = @($script:RuntimeInfo.UnusedOld)
    if ($old.Count -eq 0) { return }
    $list = ($old | ForEach-Object { "- $($_.DisplayName)" }) -join "`n"
    if (-not (Confirm-Action "Remove these old dependency apps from Intune?`n`n$list`n`nNo app depends on them any more. Devices keep what they installed." 'Remove old dependency apps' 'Remove' 'Cancel')) { return }
    Update-UiToken
    [void](Start-UiTask -Kind 'cleanupdeps' -Title "Removing $($old.Count) old dependency app(s)" -Display 'Remove old dependency apps' -NeedsAuth -Work 'Remove-PackTuneUnusedDependencyApps' -OnDone {
        param($Result, $Job)
        $n = @($Result | Where-Object { $_.Removed }).Count
        if ($Job.Status -eq 'succeeded') { Show-Toast "$n old dependency app(s) removed." 'ok' }
        else { Show-Toast 'Not all old dependency apps could be removed, see Activity.' 'bad' }
        $script:RuntimeInfo = $null; $script:TenantApps = $null
        Start-TenantRefresh
    })
}

function Get-SelectedTenantApp { if ($ui.LstTenant.SelectedItem) { $ui.LstTenant.SelectedItem.Data } }

function Get-TenantVersion { if ($ui.CmbTenantVersion.SelectedIndex -le 0) { 'latest' } else { [string]$ui.CmbTenantVersion.SelectedItem } }
function Set-TenantVersionChoices($App, [string[]]$Versions) {
    $list = @('Always the newest version') + @($Versions | Where-Object { $_ })
    if ($App.Version -and $list -notcontains $App.Version) { $list += $App.Version }
    $ui.CmbTenantVersion.ItemsSource = $list
    $ui.CmbTenantVersion.SelectedIndex = if ($App.Version) { [array]::IndexOf($list, $App.Version) } else { 0 }
}
function Read-TenantPolicy {
    $mode = if ($ui.RbTenantOff.IsChecked) { 'Off' } elseif ($ui.RbTenantCustom.IsChecked) { 'Custom' } else { 'Startup' }
    @{ UpdateMode = $mode; GraceHours = (ConvertTo-GraceHours $ui.TxtTenantGrace.Text $ui.CmbTenantGraceUnit.SelectedIndex ($mode -eq 'Custom')) }
}
function Update-TenantScheduleText($App) {
    $sched = if ($script:TenantSchedule) { New-ChocoSchedule -Values $script:TenantSchedule -Base $App.Schedule } else { $App.Schedule }
    if (-not $sched) { $sched = Get-ChocoScheduleDefaults }
    $mode = try { Read-TenantPolicy } catch { @{ UpdateMode = 'Custom' } }
    $t = Format-ScheduleSummary $sched
    $ui.TxtTenantWhen.Text = switch ($mode.UpdateMode) { 'Off' { 'Not automatic: only versions you release here' } 'Custom' { 'When the user agrees, or at the deadline' } default { $t.When } }
    $ui.TxtTenantConditions.Text = if ($mode.UpdateMode -eq 'Off') { 'Intune installs a released version right away' } else { $t.Conditions }
}

function Show-TenantPolicy($App) {
    $id = "$($App.Id)|$($App.Version)|$($App.UpdateMode)|$($App.GraceHours)"
    if ($script:TenantPolicyApp -eq $id) { return }
    $script:TenantPolicyApp = $id
    $script:TenantSchedule = $null
    $inDays = $App.GraceHours -gt 0 -and $App.GraceHours % 24 -eq 0
    $ui.TxtTenantGrace.Text = [string]$(if ($inDays) { $App.GraceHours / 24 } else { $App.GraceHours }); $ui.CmbTenantGraceUnit.SelectedIndex = if ($inDays) { 1 } else { 0 }
    switch ($App.UpdateMode) { 'Off' { $ui.RbTenantOff.IsChecked = $true } 'Custom' { $ui.RbTenantCustom.IsChecked = $true } default { $ui.RbTenantStartup.IsChecked = $true } }
    Set-TenantVersionChoices $App @()
    Update-TenantScheduleText $App
    [void](Start-UiTask -Kind 'versions' -Title 'Reading the package versions' -Package $App.Package -Pool $script:MetaPool -Hidden -Arguments @{ Package = $App.Package; Source = $App.Source } `
        -Work 'param($Package, $Source) Get-PackTunePackageVersions -Package $Package -Source $Source' -OnDone {
            param($Result, $Job)
            $now = Get-SelectedTenantApp
            if ($Job.Status -ne 'succeeded' -or -not $now -or $now.Package -ne $Job.Package) { return }
            $chosen = $ui.CmbTenantVersion.SelectedItem
            Set-TenantVersionChoices $now @($Result | ForEach-Object { [string]$_ })
            if ($chosen -and @($ui.CmbTenantVersion.ItemsSource) -contains $chosen) { $ui.CmbTenantVersion.SelectedItem = $chosen }
        })
}

function Update-TenantButtons {
    $app = Get-SelectedTenantApp
    $on = [bool]$app
    $ui.TxtTenantAppEmpty.Visibility = ConvertTo-Vis (-not $on)
    $ui.ScrollTenantApp.Visibility = ConvertTo-Vis $on
    if (-not $on) { $script:TenantPolicyApp = ''; return }
    $isDep = $app.IsChocolatey -or $app.IsDependency
    $t = Get-TileStyle $(if ($app.IsChocolatey) { 'Chocolatey' } else { $app.DisplayName })
    $ui.BoxTenantIcon.Background = ConvertTo-Brush $t.TileBg; $ui.TxtTenantMono.Text = $t.Mono; $ui.TxtTenantMono.Foreground = ConvertTo-Brush $t.TileFg
    $tenantIcon = Get-TenantAppIcon $app; $ui.ImgTenant.Source = ConvertTo-ImageSource $tenantIcon; $ui.TxtTenantMono.Visibility = ConvertTo-Vis (-not $tenantIcon)
    $ui.TxtTenantAppTitle.Text = if ($app.IsOld) { "$($app.DisplayName) (old)" } elseif ($app.IsChocolatey) { 'Chocolatey' } else { $app.DisplayName }
    $ui.TxtTenantAppSub.Text = if ($app.IsOld) { 'Old dependency app, replaced by PackTune Runtime' } elseif ($isDep) { 'Dependency of every app, updated daily' } else { "$($app.Package) $([char]0x00B7) $(Get-SourceLabel $app.Source) $([char]0x00B7) $(Get-IntentText $app)" }
    $busy = Test-TaskRunning 'policy'
    $ui.BtnTenantOpen.IsEnabled = $true
    $ui.BtnTenantRemove.IsEnabled = (Test-SignedIn) -and -not (Test-TaskRunning 'remove') -and -not $app.IsDependency
    $ui.GbTenantPolicy.Visibility = ConvertTo-Vis (-not $isDep)
    $ui.BtnTenantApply.Visibility = ConvertTo-Vis (-not $isDep)
    Update-SandboxButtons
    $ui.BtnTenantTest.Visibility = ConvertTo-Vis (-not $isDep)
    $ui.BtnTenantRelease.Visibility = ConvertTo-Vis ($app.UpdateAvailable -and -not $isDep)
    $ui.TxtTenantAvailableNote.Visibility = ConvertTo-Vis ((-not $isDep) -and (@([string]$app.Intents -split ',') -contains 'available') -and (@([string]$app.Intents -split ',') -notcontains 'required'))
    $noRuntime = @($script:WingetNoRuntime | Where-Object { $_.Id -eq $app.Id }).Count -gt 0
    $ui.TxtDependencyNote.Visibility = ConvertTo-Vis $noRuntime
    $ui.TxtDependencyNote.Text = if ($noRuntime) { 'This app still uses the old dependency apps. Switch to PackTune Runtime (banner above the list) moves it over.' } else { '' }
    if ($isDep) { $script:TenantPolicyApp = ''; return }
    $ui.BtnTenantApply.IsEnabled = (Test-SignedIn) -and -not $busy
    $ui.BtnTenantRelease.IsEnabled = (Test-SignedIn) -and -not $busy
    $ui.BtnTenantRelease.Content = if ($app.UpdateAvailable) { "Release $($app.LatestVersion)" } else { 'Release update' }
    $ui.PanelTenantGrace.Visibility = ConvertTo-Vis ([bool]$ui.RbTenantCustom.IsChecked)
    Show-TenantPolicy $app
}
$ui.LstTenant.Add_SelectionChanged({ try { Update-TenantButtons } catch { Show-Error $_.Exception.Message } })
foreach ($n in 'RbTenantOff', 'RbTenantStartup', 'RbTenantCustom') {
    $ui[$n].Add_Checked({ $app = Get-SelectedTenantApp; if ($app -and $script:TenantPolicyApp) { $ui.PanelTenantGrace.Visibility = ConvertTo-Vis ([bool]$ui.RbTenantCustom.IsChecked); Update-TenantScheduleText $app } })
}
$ui.LstTenant.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -is [System.Windows.Controls.Button] -and $b.Uid -eq 'devices' -and $b.DataContext -is [PackTune.Row]) {
            $app = $b.DataContext.Data
            if (-not ($app.IsChocolatey -or $app.IsDependency)) { Show-AppStatus $app }
        }
    }
    catch { Show-Error $_.Exception.Message }
})

function Start-AppApply {
    # Rebuilds the package with the new settings and changes the app in Intune (in place or through supersedence); devices follow on their own
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][hashtable]$Policy, $Schedule)
    if (-not (Test-SignedIn)) { throw 'Sign in to Intune first (Sign in, top right).' }
    Update-UiToken
    $arguments = @{ AppId = $App.Id; Version = $Version; UpdateMode = $Policy.UpdateMode; GraceHours = $Policy.GraceHours; Schedule = $Schedule }
    $work = @'
param($AppId, $Version, $UpdateMode, $GraceHours, $Schedule)
if ($Schedule) { Update-PackTuneApp -AppId $AppId -Version $Version -UpdateMode $UpdateMode -GraceHours $GraceHours -Schedule $Schedule }
else { Publish-PackTuneRelease -AppId $AppId -Version $Version -UpdateMode $UpdateMode -GraceHours $GraceHours }
'@
    [void](Start-UiTask -Kind 'policy' -Title "Update settings of $($App.DisplayName): $(Format-UpdateText $Policy.UpdateMode $Policy.GraceHours), version $Version" -Display $App.DisplayName -Package $App.Package -NeedsAuth -Arguments $arguments -Work $work -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') {
            $via = @($Result | Where-Object { $_.Path }) | Select-Object -First 1
            Write-UiLog "[$($Job.Package)] changed in Intune$(if ($via -and $via.Path -eq 'Supersedence') { ' (new app superseding the old one)' }). Devices pick it up at their next Intune check." 'Success'
            Show-Toast "$($Job.Display) was changed in Intune." 'ok'
        }
        $script:TenantApps = $null; $script:TenantPolicyApp = ''
        Start-TenantRefresh
    })
    Update-TenantButtons
}
Add-Click $ui.BtnTenantApply {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    $policy = Read-TenantPolicy
    $version = Get-TenantVersion
    $text = "Change '$($app.DisplayName)' in Intune?`n`nVersion: $(if ($version -eq 'latest') { 'always the newest' } else { $version })`nUpdates: $(Format-UpdateText $policy.UpdateMode $policy.GraceHours)`n`nThe package is rebuilt and uploaded. Apps that are only Available are replaced by a new app that supersedes the old one."
    if (-not (Confirm-Action $text 'Apply in Intune' 'Apply' 'Cancel')) { return }
    Start-AppApply -App $app -Version $version -Policy $policy -Schedule $script:TenantSchedule
}
function Start-ReleaseApp($App) {
    if (-not $App -or -not $App.UpdateAvailable) { return }
    if (-not (Confirm-Action "Release version $($App.LatestVersion) of '$($App.DisplayName)'?`n`nIt goes from $($App.Version) to $($App.LatestVersion). Devices install it according to the update mode of the app: $(Format-UpdateText $App.UpdateMode $App.GraceHours).`n`nApps that are only Available are updated through a new app that supersedes the old one." 'Release update' 'Release' 'Cancel')) { return }
    Start-AppApply -App $App -Version $App.LatestVersion -Policy @{ UpdateMode = $App.UpdateMode; GraceHours = $App.GraceHours }
}
Add-Click $ui.BtnTenantRelease { Start-ReleaseApp (Get-SelectedTenantApp) }
Add-Click $ui.BtnBannerRelease { $id = $ui.BtnBannerRelease.Uid; Start-ReleaseApp @($script:TenantApps | Where-Object { $_.Id -eq $id })[0] }
Add-Click $ui.BtnTenantSchedule {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    $sched = if ($script:TenantSchedule) { New-ChocoSchedule -Values $script:TenantSchedule -Base $app.Schedule } elseif ($app.Schedule) { $app.Schedule } else { Get-ChocoScheduleDefaults }
    $grace = (Read-TenantPolicy).GraceHours
    Show-ScheduleDialog -Mode 'App' -Schedule $sched -Title "When $($app.DisplayName) updates on devices" -App $app -GraceHours $grace
}
Add-Click $ui.BtnTenantTest {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    Start-PackageTest -Package $app.Package -Source $app.Source -Title $app.DisplayName -Version (Get-TenantVersion) -Policy (Read-TenantPolicy)
}
Add-Click $ui.BtnTenantRemove {
    $app = Get-SelectedTenantApp
    if (-not $app) { return }
    $others = @($script:TenantApps | Where-Object { -not $_.IsChocolatey -and $_.Source -eq 'Chocolatey' }).Count
    if ($app.IsChocolatey -and $others -gt 0) { throw "Chocolatey is the dependency of the $others app(s) created by this tool. Remove those first." }
    Confirm-AppRemoval $app "Remove '$($app.DisplayName)' from Intune?`n`nThe app and its assignments are deleted in the tenant. Devices keep the installed software and its update task; nothing is uninstalled." { Start-TenantRemoval $app }
}
function Start-TenantRemoval($app) {
    Update-UiToken
    [void](Start-UiTask -Kind 'remove' -Title "Removing $($app.DisplayName) from Intune" -Display $app.DisplayName -Package $app.Package -NeedsAuth -Arguments @{ Id = $app.Id; Source = $app.Source } -Work 'param($Id, $Source) Remove-PackTuneApp -Id $Id' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'succeeded') {
            Write-UiLog "[$($Job.Package)] removed from Intune." 'Success'
            Show-Toast "$($Job.Display) was removed from Intune." 'ok'
            if ($Job.Package) { $script:RecentDeploys.Remove((Get-MetaKey $Job.Package $Job.Source)) }
        }
        $script:TenantApps = $null
        Start-TenantRefresh
    })
    Update-TenantButtons
}
Add-Click $ui.BtnTenantOpen {
    $app = Get-SelectedTenantApp
    if ($app) { Start-Process "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($app.Id)" }
}

# ---------------------------------------------------------------- status of one app
$script:StatusApp = $null
$script:StatusData = $null
function Set-StatusIcon {
    $app = $script:StatusApp
    if (-not $app) { return }
    $t = Get-TileStyle $app.DisplayName
    $ui.BoxStatusIcon.Background = ConvertTo-Brush $t.TileBg; $ui.TxtStatusMono.Text = $t.Mono; $ui.TxtStatusMono.Foreground = ConvertTo-Brush $t.TileFg
    $icon = Get-TenantAppIcon $app
    $ui.ImgStatus.Source = ConvertTo-ImageSource $icon
    $ui.TxtStatusMono.Visibility = ConvertTo-Vis (-not $icon)
}
function Show-AppStatus($App) {
    $script:StatusApp = $App
    $script:StatusData = $null
    Show-Page 'Status'
    $ui.TxtStatusTitle.Text = "$($App.DisplayName) on devices"
    Set-StatusIcon
    $ui.TxtStatusSub.Text = 'Intune install status, plus the update log each device reports. Reading ...'
    foreach ($n in 'TxtStatOk', 'TxtStatWait', 'TxtStatFail', 'TxtStatStale') { $ui[$n].Text = '-' }
    $script:DeviceRowList.Clear()
    $ui.BoxDeviceLog.Visibility = 'Collapsed'
    $ui.TxtDevicesEmpty.Visibility = 'Visible'; $ui.TxtDevicesEmpty.Text = 'Reading the install status ...'
    Update-StatusBanner
    Start-StatusLoad
}
$script:DeviceRowList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstDevices.ItemsSource = $script:DeviceRowList

function Update-StatusBanner {
    $st = $script:StatusScript
    $show = $st -and $st.State -ne 'Present'
    $ui.BoxStatusScript.Visibility = ConvertTo-Vis ([bool]$show)
    if (-not $show) { return }
    if ($st.State -eq 'Missing') { $ui.TxtStatusScript.Text = 'The status script is not set up. Without it you see the Intune install status, but not the log the device reports. It runs as a Remediations detection script on all devices, once an hour.'; $ui.BtnStatusScript.Visibility = 'Visible' }
    else { $ui.TxtStatusScript.Text = "The device log is not available in this tenant: Remediations need a Windows Enterprise E3/E5 (or A3/A5, VDA) license. The install status above still works. $(Get-FriendlyCause $st.Reason)"; $ui.BtnStatusScript.Visibility = 'Collapsed' }
}
Add-Click $ui.BtnStatusScript { Start-StatusScriptSetup }
Add-Click $ui.BtnStatusBack { Show-Page 'Tenant' }
Add-Click $ui.BtnStatusRefresh { if ($script:StatusApp) { Show-AppStatus $script:StatusApp } }

function Start-StatusLoad {
    $app = $script:StatusApp
    if (-not $app) { return }
    Update-UiToken
    $work = @'
param($AppId, $Package, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
$St = Get-InsightAppInstallStatus -Context $Ctx -AppId $AppId
$Script = $null; $Runs = @()
try { $Script = Get-InsightStatusScriptState -Context $Ctx } catch { }
if ($Script) {
    try { $Runs = @(Get-InsightDeviceRunStates -Context $Ctx -ScriptId $Script.id) } catch { }
    $St = Merge-InsightStatus -InstallStatus $St -Package $Package -RunStates $Runs
}
[pscustomobject]@{ Status = $St; HasScript = [bool]$Script }
'@
    [void](Start-UiTask -Kind 'status' -Title "Reading the install status of $($app.DisplayName)" -Display "Status of $($app.DisplayName)" -Hidden -NeedsAuth -Arguments @{ AppId = $app.Id; Package = $app.Package; Fake = $script:InsightFake } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $_.Status }) | Select-Object -First 1
        if ($Job.Status -ne 'succeeded' -or -not $r) {
            $ui.TxtDevicesEmpty.Visibility = 'Visible'
            $ui.TxtDevicesEmpty.Text = 'The install status could not be read. Check that the sign-in has the permission DeviceManagementApps.Read.All (Start > App registration).'
            $ui.TxtStatusSub.Text = 'Intune install status, plus the update log each device reports.'
            return
        }
        $script:StatusData = $r
        Show-StatusRows $r.Status
    })
}

function Show-StatusRows($St) {
    $ui.TxtStatOk.Text = [string]$St.Installed; $ui.TxtStatWait.Text = [string]$St.Pending; $ui.TxtStatFail.Text = [string]$St.Failed; $ui.TxtStatStale.Text = [string]$St.NotReported7Days
    $ui.TxtStatusSub.Text = "Intune install status, plus the update log each device reports. Updated $((Get-Date).ToString('HH:mm'))."
    $rows = foreach ($d in @($St.Devices | Sort-Object @{ Expression = { switch -Wildcard ($_.State) { 'failed' { 0 } 'uninstallFailed' { 0 } 'pendingInstall' { 1 } default { 2 } } } }, DeviceName)) {
        $last = $d.LastResult
        $label, $kind = if ($d.State -in 'failed', 'uninstallFailed') { 'Failed', 'bad' } elseif ($d.State -eq 'pendingInstall') { 'Waiting', 'warn' } elseif ($d.NotReported) { 'No report', 'gray' } elseif ($d.State -eq 'installed') { 'Installed', 'ok' } else { $d.State, 'gray' }
        $cause = if ($last -and -not $last.Ok -and $last.Cause) { [string]$last.Cause } elseif ($d.Cause) { [string]$d.Cause } elseif ($label -eq 'No report') { "No report for 7 days" } else { '' }
        $code = if ($last -and -not $last.Ok -and $null -ne $last.ExitCode) { "exit $($last.ExitCode)" } elseif ($d.ErrorCode) { [string]$d.ErrorCode } else { '' }
        $when = if ($d.LastReport) { $t = ([datetime]$d.LastReport).ToLocalTime(); if ($t.Date -eq (Get-Date).Date) { "Today $($t.ToString('HH:mm'))" } else { $t.ToString('d MMM') } } else { '' }
        New-Row @{ Data = $d; Title = $d.DeviceName; Sub = $d.User; Status = $label; StatusBg = $script:PillColors[$kind][0]; StatusFg = $script:PillColors[$kind][1]
            Version = $d.Version; Cause = $cause; Code = $code; When = $when }
    }
    $script:DeviceRowList.Clear()
    foreach ($r in @($rows)) { $script:DeviceRowList.Add($r) }
    $ui.TxtDevicesEmpty.Visibility = ConvertTo-Vis ($script:DeviceRowList.Count -eq 0)
    $ui.TxtDevicesEmpty.Text = 'No device reports this app yet.'
    if ($script:DeviceRowList.Count) { $ui.LstDevices.SelectedIndex = 0 }
}
$ui.LstDevices.Add_SelectionChanged({ try { Show-DeviceLog } catch { Show-Error $_.Exception.Message } })
function Show-DeviceLog {
    $row = $ui.LstDevices.SelectedItem
    if (-not $row) { $ui.BoxDeviceLog.Visibility = 'Collapsed'; return }
    $d = $row.Data
    $ui.BoxDeviceLog.Visibility = 'Visible'
    $ui.TxtDeviceLogTitle.Text = "Log from $($d.DeviceName) (reported by the device)"
    $l = $d.LastResult
    $lines = @()
    if ($l) {
        $when = if ($l.LastAttempt) { [string]$l.LastAttempt } else { '' }
        if ($l.Ok) { $lines += "$when  $($l.Package): version $($l.InstalledVersion), no problem reported" }
        else {
            $lines += "$when  $($l.Action) $($l.Package): installed $($l.InstalledVersion), target $($l.TargetVersion)"
            $lines += "$when  exit code $($l.ExitCode): $($l.Cause)"
        }
    }
    $ui.TxtDeviceLog.Text = if ($lines.Count) { $lines -join "`n" } elseif ($script:StatusScript -and $script:StatusScript.State -eq 'Present') { 'This device has not reported a log for this app yet. Devices report when the result changes, otherwise every 7 days.' } else { 'No device log: the status script is not set up (see above).' }
    $ui.TxtRetryHint.Text = if ($d.State -in 'failed', 'uninstallFailed') { 'The device retries by itself at the next chance (see Failed update in the schedule). To retry now, run a Sync from Intune on the device, or collect diagnostics first when the cause is not clear.' } else { '' }
}
Add-Click $ui.BtnDiagnostics {
    $row = $ui.LstDevices.SelectedItem
    if (-not $row) { return }
    $info = Get-InsightDiagnosticsInfo -ManagedDeviceId $row.Data.DeviceId -Package $script:StatusApp.Package
    $ui.TxtRetryHint.Text = $info.Hint
    Start-Process $info.Url
}

# ---------------------------------------------------------------- import dialog
$script:ImportSource = 'This'
$script:ImportRowList = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LstImport.ItemsSource = $script:ImportRowList
$script:ImportContext = $null

$script:KindLabels = @{ ToolCreated = 'This tool'; ChocolateyWin32 = 'Win32 with Chocolatey'; WingetWin32 = 'Win32 with winget'; StoreApp = 'Store app (new)'; Other = 'Win32, own installer'; Export = 'Export file' }
$script:ActionLabels = @{ Managed = 'Already managed'; TakeOver = 'Take over'; KeepAsStoreApp = 'Keep as Store app'; SkipDuplicate = 'Skip, duplicate'; CannotManage = 'Cannot be managed'; Recreate = 'Create here' }
function Show-ImportDialog {
    if ($script:ImportSource -eq 'This' -and (Test-SignedIn) -and -not $script:ImportApps) { Start-ImportRead }
    Show-Dialog 'DlgImport'
    Update-ImportRows
}
$script:ImportApps = $null
function Get-ImportFeedText($App) {
    # How the package source of an imported Chocolatey app is shown in its row
    $src = [string]$App.PackageSource
    if ($src -eq [string]$script:Settings.PackageSource) { return "package source $src (same as yours)" }
    if ($App.ProposedAction -ne 'Recreate') { return "package source $src" }
    if (Test-InsightFeedUrl $src) { return "offers package source $src (asked before it is used, otherwise yours)" }
    return "offered package source $src refused (only https without user, password or query), yours is used"
}
function Update-ImportRows {
    $apps = @($script:ImportApps | Where-Object { $_ -and -not $_.Infrastructure })
    $rows = foreach ($a in $apps) {
        $pick = $a.ProposedAction -in 'TakeOver', 'Recreate'
        $kind = $script:KindLabels[[string]$a.Kind]; if (-not $kind) { $kind = [string]$a.Kind }
        $kc = switch ($a.Kind) { 'ToolCreated' { 'info' } 'ChocolateyWin32' { 'gray' } 'WingetWin32' { 'ok' } 'StoreApp' { 'ok' } default { 'gray' } }
        $settings = if ($a.Package -and $a.ProposedAction -ne 'CannotManage') { "$(if ($a.Version) { "Version $($a.Version) pinned" } else { 'Latest' }), $(Format-UpdateText $a.UpdateMode $a.GraceHours)" } else { $a.Reason }
        # The package source an import offers is shown, never taken silently (asked per app when creating)
        if ($a.Source -eq 'Chocolatey' -and $a.PackageSource -and $a.ProposedAction -ne 'CannotManage') { $settings += "; $(Get-ImportFeedText $a)" }
        $icon = if ($a.Package) { Get-PackageIcon $a.Package $a.Source }
        New-Row (@{ Data = $a; Icon = $icon; MonoVis = (ConvertTo-Vis (-not $icon)); Title = $a.DisplayName; Sub = $(if ($a.Kind -eq 'Export') { 'From the export file' } else { $a.Reason }); Kind = $kind; KindBg = $script:PillColors[$kc][0]; KindFg = $script:PillColors[$kc][1]
            Found = $(if ($a.Package) { "$($a.Source): $($a.Package)" } else { '' }); Settings = $settings; Action = $(if ($script:ActionLabels[[string]$a.ProposedAction]) { $script:ActionLabels[[string]$a.ProposedAction] } else { $a.ProposedAction })
            Checked = $pick; CanPick = $pick; Opacity = $(if ($pick -or $a.ProposedAction -eq 'Managed') { 1 } else { 0.6 }) } + (Get-TileStyle $a.DisplayName))
    }
    $script:ImportRowList.Clear()
    foreach ($r in @($rows)) { $script:ImportRowList.Add($r) }
    $ui.TxtImportEmpty.Visibility = ConvertTo-Vis ($script:ImportRowList.Count -eq 0)
    $ui.TxtImportEmpty.Text = if ($script:ImportReading) { 'Reading the apps ...' } elseif ($script:ImportSource -eq 'This' -and -not (Test-SignedIn)) { 'Sign in first.' } elseif ($script:ImportSource -eq 'Other') { 'Enter the tenant and the client ID of the app registration there, then sign in and read.' } elseif ($script:ImportSource -eq 'File') { 'Choose an export file.' } else { 'No apps found.' }
    Update-ImportSummary
}
$script:ImportReading = $false
function Get-ImportChecked { @($script:ImportRowList | Where-Object { $_['Checked'] -eq 'True' } | ForEach-Object { $_.Data }) }
function Update-ImportSummary {
    $checked = @(Get-ImportChecked).Count
    $pickable = @($script:ImportRowList | Where-Object { $_['CanPick'] -eq 'True' }).Count
    $ui.TxtImportSummary.Text = "$checked of $($script:ImportRowList.Count) apps selected. " + $(if ($script:ImportSource -eq 'This') { 'Taken-over apps get the new scripts with their next update settings change; nothing changes on devices now.' } else { 'The apps are created in this tenant with their settings; assignments start as None.' })
    $ui.BtnImportGo.Content = if ($script:ImportSource -eq 'This') { "Take over $checked app$(if ($checked -ne 1) { 's' })" } else { "Create $checked app$(if ($checked -ne 1) { 's' })" }
    $ui.BtnImportGo.IsEnabled = $checked -gt 0 -and (Test-SignedIn)
    $ui.BtnImpExport.IsEnabled = @($script:ImportApps | Where-Object { $_.Managed -and -not $_.Infrastructure }).Count -gt 0
}
$ui.LstImport.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    $b = $e.OriginalSource
    if ($b -is [System.Windows.Controls.CheckBox] -and $b.DataContext -is [PackTune.Row]) { $b.DataContext['Checked'] = [string][bool]$b.IsChecked; Update-ImportSummary }
})
function Set-ImportSource([string]$Source) {
    $script:ImportSource = $Source
    $ui.PanelImpOther.Visibility = ConvertTo-Vis ($Source -eq 'Other'); $ui.PanelImpFile.Visibility = ConvertTo-Vis ($Source -eq 'File')
    $script:ImportApps = $null
    if ($Source -eq 'This' -and (Test-SignedIn)) { Start-ImportRead }
    Update-ImportRows
}
$ui.RbImpThis.Add_Checked({ if ($script:OpenDialog -eq 'DlgImport') { Set-ImportSource 'This' } })
$ui.RbImpOther.Add_Checked({ if ($script:OpenDialog -eq 'DlgImport') { Set-ImportSource 'Other' } })
$ui.RbImpFile.Add_Checked({ if ($script:OpenDialog -eq 'DlgImport') { Set-ImportSource 'File' } })

function Start-ImportRead {
    param([string]$TenantID, [string]$ClientID)
    if (Test-TaskRunning 'importread') { return }
    Update-UiToken
    $script:ImportReading = $true
    $work = @'
param($Mode, $Grace, $Fake, $OtherTenant, $OtherClient, $Authority, $UrlHandler)
if ($OtherTenant) {
    $Params = @{ TenantID = $OtherTenant; ClientID = $OtherClient; ShouldCancel = { $Shared.CancelSignIn } }
    if ($Authority) { $Params.Authority = $Authority }
    if ($UrlHandler) { $Params.UrlHandler = [scriptblock]::Create($UrlHandler) }
    $Ctx = Get-InsightOtherTenantContext @Params
}
else { $Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext } }
Get-InsightTenantApps -Context $Ctx -DefaultUpdateMode $Mode -DefaultGraceHours $Grace
'@
    $args2 = @{ Mode = $script:Settings.UpdateMode; Grace = [int]$script:Settings.GraceHours; Fake = $script:InsightFake; OtherTenant = $TenantID; OtherClient = $ClientID; Authority = $script:SignInTest.Authority; UrlHandler = $script:SignInTest.UrlHandler }
    $script:Shared.CancelSignIn = $false
    [void](Start-UiTask -Kind 'importread' -Title $(if ($TenantID) { "Reading the apps of $TenantID" } else { 'Reading the apps in the tenant for the import' }) -Display 'Import: read apps' -Pool $script:UserPool -NeedsAuth -Arguments $args2 -Work $work -Hidden -OnDone {
        param($Result, $Job)
        $script:ImportReading = $false
        $apps = @($Result | ForEach-Object { $_ } | Where-Object { $_ -and $_.PSObject.Properties["ProposedAction"] })
        if ($Job.Spec.Arguments.OtherTenant) {
            # Apps of another tenant are recreated here: everything this tool manages or can take over becomes a candidate
            foreach ($a in $apps) { if ($a.Package -and $a.Source -in 'Chocolatey', 'Winget' -and $a.ProposedAction -in 'Managed', 'TakeOver') { $a.ProposedAction = 'Recreate' } }
        }
        else { $script:ImportExisting = $apps }
        $script:ImportApps = $apps
        if ($Job.Status -eq 'failed') { Show-Toast 'The apps could not be read, see Activity.' 'bad' }
        if ($script:OpenDialog -eq 'DlgImport') { Update-ImportRows }
    })
}
$script:ImportExisting = @()
Add-Click $ui.BtnImpRead {
    if (-not $ui.TxtImpTenant.Text.Trim() -or -not $ui.TxtImpClient.Text.Trim()) { throw 'Enter the tenant and the client ID of the app registration there first.' }
    Start-ImportRead -TenantID $ui.TxtImpTenant.Text.Trim() -ClientID $ui.TxtImpClient.Text.Trim()
    Update-ImportRows
}
function Read-ImportFile([string]$Path) {
    $script:ImportApps = @(Read-InsightExportFile -Path $Path)
    Update-ImportRows
}
Add-Click $ui.BtnImpOpenFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Export file'; $dlg.Filter = 'Export files (*.json)|*.json|All files (*.*)|*.*'
    if ($dlg.ShowDialog($window)) { Read-ImportFile $dlg.FileName }
}
function Export-ManagedApps([string]$Path) {
    $count = Export-InsightManagedApps -Apps @($script:ImportApps) -Path $Path
    Write-UiLog "$count app(s) exported to $Path." 'Success'
    Show-Toast "$count app(s) exported." 'ok'
}
Add-Click $ui.BtnImpExport {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Export managed apps'; $dlg.Filter = 'Export files (*.json)|*.json'; $dlg.FileName = 'PackTune-apps.json'
    if ($dlg.ShowDialog($window)) { Export-ManagedApps $dlg.FileName }
}
Add-Click $ui.BtnImportCancel { Close-Dialog }
Add-Click $ui.BtnImportGo {
    $picked = @(Get-ImportChecked)
    if ($picked.Count -eq 0) { return }
    Update-UiToken
    if ($script:ImportSource -eq 'This') {
        $work = @'
param($Apps, $Fake)
$Ctx = if ($Fake) { New-InsightGraphContext -Invoke ([scriptblock]::Create($Fake)) } else { New-InsightGraphContext }
Set-InsightAppTakeOver -Context $Ctx -Apps $Apps
'@
        [void](Start-UiTask -Kind 'takeover' -Title "Taking over $($picked.Count) app(s)" -Display 'Import: take over' -NeedsAuth -Arguments @{ Apps = $picked; Fake = $script:InsightFake } -Work $work -OnDone {
            param($Result, $Job)
            $done = @($Result | Where-Object { $_.Done }).Count
            if ($Job.Status -eq 'succeeded') { Show-Toast "$done app(s) taken over." 'ok' }
            $script:TenantApps = $null; $script:ImportApps = $null
            Start-TenantRefresh
        })
    }
    else {
        # A package source from the import (export file, notes of another tenant) is used only after a yes per app;
        # otherwise, and when it is not a plain https URL, the app gets the package source of these settings
        $own = if ($script:Settings.PackageSource) { [string]$script:Settings.PackageSource } else { 'the Chocolatey community repository' }
        foreach ($a in $picked) {
            $use = $false
            $src = [string]$a.PackageSource
            if ($a.Source -eq 'Chocolatey' -and $src -and $src -ne [string]$script:Settings.PackageSource) {
                if (Test-InsightFeedUrl $src) {
                    $use = Confirm-Action "'$($a.DisplayName)' comes with its own Chocolatey package source:`n`n$src`n`nDevices would install it from there. Your package source: $own.`n`nUse the package source of the import for this app? (Use mine = your package source)" 'Package source of the import' 'Use import source' 'Use mine'
                }
                else { Write-UiLog "$($a.DisplayName): the offered package source is refused (only https without user, password or query), your package source is used." 'Warning' }
            }
            $a | Add-Member -NotePropertyName UseOfferedSource -NotePropertyValue $use -Force
        }
        $work = 'param($Candidates, $Existing) New-InsightRecreatedApps -Candidates $Candidates -ExistingApps $Existing'
        [void](Start-UiTask -Kind 'takeover' -Title "Creating $($picked.Count) app(s) from the import" -Display 'Import: create apps' -NeedsAuth -Arguments @{ Candidates = $picked; Existing = @($script:ImportExisting) } -Work $work -OnDone {
            param($Result, $Job)
            $done = @($Result | Where-Object { $_.Done }).Count
            if ($Job.Status -eq 'succeeded') { Show-Toast "$done app(s) created from the import." 'ok' }
            $script:TenantApps = $null
            Start-TenantRefresh
        })
    }
    Close-Dialog
    Show-Page 'Activity'
}
Add-Click $ui.BtnImport { Show-ImportDialog }

# ---------------------------------------------------------------- activity
$ui.LstJobs.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($s, $e)
    try {
        $b = $e.OriginalSource
        if ($b -isnot [System.Windows.Controls.Button] -or $b.DataContext -isnot [PackTune.Row]) { return }
        $job = $b.DataContext.Data
        if ($b.Uid -eq 'log') { $job.LogOpen = -not $job.LogOpen; Update-JobRow $job }
        elseif ($b.Uid -eq 'retry') { Restart-Job $job }
        elseif ($b.Uid -eq 'open' -and $job.Row['Open']) { Start-Process "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($job.Row['Open'])" }
    }
    catch { Show-Error $_.Exception.Message }
})
function Restart-Job($Job) {
    $spec = $Job.Spec
    if (-not $spec) { return }
    if ($spec.NeedsAuth) { Update-UiToken }
    $script:JobRows.Remove($Job.Row)
    [void](Start-UiTask @spec)
}
Add-Click $ui.BtnLogClear {
    foreach ($row in @($script:JobRows)) { if ($row.Data.Status -notin 'queued', 'running') { $script:JobRows.Remove($row) } }
}
Add-Click $ui.BtnLogFolder { New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null; Start-Process explorer.exe $script:LogFolder }
$script:JobRows.Add_CollectionChanged({
    $ui.TxtJobsEmpty.Visibility = ConvertTo-Vis ($script:JobRows.Count -eq 0)
})

# ---------------------------------------------------------------- sandbox test
# ---------------------------------------------------------------- Windows Sandbox and the capture tools (optional, for the Test buttons and custom applications)
$script:SandboxOverride = $null          # tests: @{ Present; Home; VirtualizationOff; Toolchain = 'Ready' or 'Missing' }
$script:SandboxInstallOverride = $null   # tests: script block that gets the elevated command instead of starting it
$script:SandboxRestart = $false          # installed in this session, Windows has to restart
$script:SandboxState = $null

function Get-SandboxState {
    # Detected without administrator rights: the program file of the feature, the edition and (if known) the virtualization flag
    $o = $script:SandboxOverride
    if ($o) { $present = [bool]$o.Present; $isHome = [bool]$o.Home; $virtOff = [bool]$o.VirtualizationOff; $toolchain = if ($o.Toolchain) { [string]$o.Toolchain } else { 'Ready' } }
    else {
        $present = Test-Path (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe')
        $edition = try { [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID } catch { '' }
        $isHome = $edition -match '^Core'
        $virtOff = $false
        if (-not $present -and -not $isHome) { try { $virtOff = (@(Get-CimInstance Win32_Processor -ErrorAction Stop | Where-Object { $_.VirtualizationFirmwareEnabled -eq $false }).Count -gt 0) } catch { } }
        $toolchain = (Get-PackTuneToolchainState).State
    }
    $reason = if ($present) { '' } elseif ($isHome) { 'Windows Home does not include Windows Sandbox (it needs Pro, Enterprise or Education).' } elseif ($virtOff) { 'Virtualization is switched off in the BIOS or UEFI.' } else { '' }
    [pscustomobject]@{ Present = $present; Installable = (-not $present -and -not $isHome); Reason = $reason; Toolchain = $toolchain; RestartPending = $script:SandboxRestart }
}
function Update-SandboxState { $script:SandboxState = Get-SandboxState; Update-SandboxButtons }
function Get-CachedSandboxState { if (-not $script:SandboxState) { $script:SandboxState = Get-SandboxState }; $script:SandboxState }

function Get-SandboxBlocker {
    # Why the Test buttons cannot be used right now, or $null
    $s = Get-CachedSandboxState
    if ($s.RestartPending) { return 'Windows Sandbox needs a restart of Windows first. See the Start page (Sandbox test).' }
    if (-not $s.Present) { return 'Windows Sandbox is not installed. Set it up on the Start page (Sandbox test).' }
    $null
}

function New-Spinner([double]$Size = 14, $Brush) {
    # A rotating "sync" glyph for everything that is busy
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontFamily = $window.FindResource('IconFont'); $tb.Text = [string][char]0xE895; $tb.FontSize = $Size
    $tb.VerticalAlignment = 'Center'; $tb.HorizontalAlignment = 'Center'
    if ($Brush) { $tb.Foreground = $Brush }
    $tb.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    $rotate = New-Object System.Windows.Media.RotateTransform
    $tb.RenderTransform = $rotate
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation 0.0, 360.0, ([System.Windows.Duration][TimeSpan]::FromSeconds(1.1))
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
    $tb
}
$script:BusyLook = @{}
function Set-ButtonBusy($Button, [bool]$Busy, [string]$Text) {
    # Busy: a rotating spinner and the text instead of the usual content; back to the original afterwards
    if (-not $script:BusyLook.ContainsKey($Button.Name)) { $script:BusyLook[$Button.Name] = @($Button.Content, $Button.Tag) }
    $look = $script:BusyLook[$Button.Name]
    if ($Busy) {
        if ($Button.Content -is [System.Windows.Controls.StackPanel] -and $Button.Content.Tag -eq 'busy') { $Button.Content.Children[1].Text = $Text; return }
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Orientation = 'Horizontal'; $panel.Tag = 'busy'
        $spin = New-Spinner 14 $Button.Foreground; $spin.Margin = '0,0,8,0'
        $label = New-Object System.Windows.Controls.TextBlock; $label.Text = $Text; $label.VerticalAlignment = 'Center'
        [void]$panel.Children.Add($spin); [void]$panel.Children.Add($label)
        $Button.Tag = $null; $Button.Content = $panel
    }
    elseif ($Button.Content -is [System.Windows.Controls.StackPanel] -and $Button.Content.Tag -eq 'busy') { $Button.Content = $look[0]; $Button.Tag = $look[1] }
}
function Get-ButtonLabel($Button) { if ($Button.Content -is [System.Windows.Controls.StackPanel]) { [string]$Button.Content.Children[1].Text } else { [string]$Button.Content } }
function Set-SandboxButtonBusy($Button, [bool]$Busy, [bool]$Enabled, $Tip) {
    # A running test: the button says so at once (spinner + "Starting sandbox ...") and is disabled
    Set-ButtonBusy $Button $Busy 'Starting sandbox ...'
    $Button.IsEnabled = $Enabled -and -not $Busy
    $Button.ToolTip = $Tip
}
function Show-TestMenu([ValidateSet('Detail', 'Tenant', 'Custom')][string]$Kind, $Target) {
    # Split button of Test in sandbox: the installation test (default) or the update from a previous version
    $menu = New-Object System.Windows.Controls.ContextMenu
    $script:TestMenuActions = @{}
    $add = {
        param([string]$Header, [string]$Text, [bool]$Enabled, [scriptblock]$Action)
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $Header; $mi.ToolTip = $Text; $mi.IsEnabled = $Enabled
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($mi, $false)
        $script:TestMenuActions[$mi] = $Action
        $mi.Add_Click({ param($src) try { & $script:TestMenuActions[$src] } catch { Show-Error $_.Exception.Message } })
        [void]$menu.Items.Add($mi)
    }
    $blocker = Get-SandboxBlocker
    switch ($Kind) {
        'Custom' {
            & $add 'Test installation' 'Install, detect and uninstall this MSI in a fresh Windows Sandbox.' ([bool]$script:CustomInfo -and -not $blocker) { Start-CustomTest }
            # The previous version comes from the package store (latest stored version of the app); the file dialog only when there is no store
            $storeApp = $null
            if ($script:Settings.StoreSiteUrl -and (Test-SignedIn)) {
                if ($script:CustomMode -eq 'Version' -and $script:CustomUpdateApp -and $script:CustomUpdateApp.AppId) { $storeApp = [string]$script:CustomUpdateApp.AppId }
                elseif ($script:CustomInfo) { $cid = Get-PackTuneCustomAppId $script:CustomInfo; if (@($script:CustomApps | Where-Object { $_.AppId -eq $cid }).Count) { $storeApp = $cid } }
            }
            if ($storeApp) {
                $sid = $storeApp
                & $add 'Test update from the previous version (package store)' 'The latest stored version of this app is installed first (taken from the package store), then this MSI as the update.' ([bool]$script:CustomInfo -and -not $blocker) { Start-CustomTest '' $sid }.GetNewClosure()
            }
            else { & $add 'Test update from the previous version ...' 'No package store version: choose the previous MSI. It is installed first, then this one as the update.' ([bool]$script:CustomInfo -and -not $blocker) {
                $dlg = New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Title = 'Previous version (MSI)'; $dlg.Filter = 'MSI files (*.msi)|*.msi'
                if ($script:CustomMode -eq 'Version' -and $script:CustomUpdateApp -and $script:CustomUpdateApp.Path) { $dlg.InitialDirectory = Split-Path $script:CustomUpdateApp.Path }
                if ($dlg.ShowDialog($window)) { Start-CustomTest $dlg.FileName }
            } }
        }
        default {
            if ($Kind -eq 'Detail') {
                $src = $script:DetailRow
                if (-not $src) { return }
                $source = Get-AppSource $src; $package = Get-AppId $src $source; $title = $src.Name
                $policy = @{ UpdateMode = $script:Settings.UpdateMode; GraceHours = $script:Settings.GraceHours }; $released = ''
                $versions = @(Get-PackTunePackageVersions -Package $package -Source $source)
            }
            else {
                $app = Get-SelectedTenantApp
                if (-not $app) { return }
                $package = $app.Package; $source = $app.Source; $title = $app.DisplayName; $policy = Read-TenantPolicy; $released = [string]$app.Version
                $versions = @($ui.CmbTenantVersion.ItemsSource | Where-Object { $_ -and $_ -notlike 'Always*' })
            }
            $run = { Start-PackageTest -Package $package -Source $source -Title $title -Version 'latest' -Policy $policy }.GetNewClosure()
            & $add 'Test installation' 'Install, detect and uninstall the newest version in a fresh Windows Sandbox.' (-not $blocker) $run
            $older = @(@($released) + @($versions | Select-Object -Skip 1) | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 12)
            if (-not $older.Count) { & $add 'Test update from the previous version' 'No older version is known.' $false {} }
            foreach ($v in $older) {
                $from = [string]$v
                $label = "Test update from $from$(if ($from -eq $released) { ' (released in Intune)' })"
                $go = { Start-PackageTest -Package $package -Source $source -Title $title -Version 'latest' -Policy $policy -FromVersion $from }.GetNewClosure()
                & $add $label "Installs $from first, then updates to the newest version, and detects both." (-not $blocker) $go
            }
        }
    }
    Show-Flyout $menu $Target
}
Add-Click $ui.BtnDetailTestMenu { Show-TestMenu 'Detail' $ui.BtnDetailTestMenu }
Add-Click $ui.BtnTenantTestMenu { Show-TestMenu 'Tenant' $ui.BtnTenantTestMenu }
Add-Click $ui.BtnCustomTestMenu { Show-TestMenu 'Custom' $ui.BtnCustomTestMenu }
function Block-SandboxStart {
    # $true (with a message) when no sandbox test can start now: one is running, or Windows Sandbox is open
    $msg = ''
    if (Test-TaskRunning 'test') { $msg = 'A sandbox test is already running (Windows Sandbox runs one at a time). It is in Activity.' }
    elseif (-not $script:SandboxOverride) { try { if (Test-PackTuneSandboxRunning) { $msg = 'Windows Sandbox is already open. Close it first (Windows Sandbox runs one at a time).' } } catch { } }
    if ($msg) { Show-Toast $msg 'warn'; Write-UiLog $msg 'Warning' }
    [bool]$msg
}
function Show-SandboxStarted {
    Show-Toast 'Sandbox test started - Windows Sandbox opens in a moment' 'info'
    Update-SandboxButtons
}
function Update-SandboxButtons {
    $blocker = Get-SandboxBlocker
    $busy = Test-TaskRunning 'test'
    $busyTip = 'A sandbox test is running (Windows Sandbox runs one at a time).'
    $tip = if ($blocker) { $blocker } elseif ($busy) { $busyTip } else { $null }
    $detail = [bool]$script:DetailRow
    Set-SandboxButtonBusy $ui.BtnDetailTest $busy ($detail -and -not $blocker) $tip
    $app = Get-SelectedTenantApp
    $isDep = $app -and ($app.IsChocolatey -or $app.IsDependency)
    Set-SandboxButtonBusy $ui.BtnTenantTest $busy ([bool]$app -and -not $isDep -and -not $blocker) $tip
    Set-SandboxButtonBusy $ui.BtnCustomTest $busy ([bool]$script:CustomInfo) $tip
    $ui.BtnDetailTestMenu.IsEnabled = $ui.BtnDetailTest.IsEnabled -or ($detail -and -not $busy -and -not $blocker)
    $ui.BtnTenantTestMenu.IsEnabled = $ui.BtnTenantTest.IsEnabled
    $ui.BtnCustomTestMenu.IsEnabled = $ui.BtnCustomTest.IsEnabled
}
function Get-SandboxInstallCommand {
    # The elevated command: only the optional feature, no restart (the user restarts when it suits)
    $script = '$ErrorActionPreference = ''Stop''; try { $r = Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart; if ($r.RestartNeeded) { exit 3010 } else { exit 0 } } catch { Write-Error $_.Exception.Message; exit 1 }'
    @{ File = 'powershell.exe'; Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$script`""; Verb = 'RunAs' }
}

function Get-CustomCaptureState {
    # Custom applications of type Other are captured in Windows Sandbox; the capture tools are downloaded on first use
    $blocker = Get-SandboxBlocker
    if ($blocker) { return [pscustomobject]@{ State = 'Blocked'; Message = $blocker } }
    [pscustomobject]@{ State = 'Ready'; Message = 'Windows Sandbox is ready.' }
}

function Start-ToolchainDownload {
    if (Test-TaskRunning 'toolchain') { return }
    [void](Start-UiTask -Kind 'toolchain' -Title 'Downloading the capture tools (MSIX Packaging Tool and signing tools from Microsoft)' -Display 'Capture tools' -Pool $script:UserPool -Work 'Update-PackTuneToolchain | Out-Null' -OnDone {
        param($Result, $Job)
        if ($Job.Status -eq 'failed') { Show-Toast 'The capture tools could not be downloaded, see Activity.' 'bad' } else { Show-Toast 'The capture tools are ready.' 'ok' }
        Update-SandboxState
        Update-Readiness
    })
    Update-Readiness
}

function Start-SandboxInstall {
    if (Test-TaskRunning 'sandboxinstall') { return }
    $command = Get-SandboxInstallCommand
    if ($script:SandboxInstallOverride) { & $script:SandboxInstallOverride $command; return }
    $work = @'
param($File, $Arguments)
try {
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -Verb RunAs -PassThru -Wait -WindowStyle Hidden
    [pscustomobject]@{ Exit = $p.ExitCode }
}
catch { [pscustomobject]@{ Exit = -1; Declined = ($_.Exception.Message -match 'cancel|abgebrochen|1223' -or $_.Exception.NativeErrorCode -eq 1223); Message = $_.Exception.Message } }
'@
    Show-Toast 'Windows asks for administrator approval to install Windows Sandbox.' 'info'
    [void](Start-UiTask -Kind 'sandboxinstall' -Title 'Installing Windows Sandbox (needs administrator approval)' -Display 'Windows Sandbox' -Pool $script:UserPool -Arguments @{ File = $command.File; Arguments = $command.Arguments } -Work $work -OnDone {
        param($Result, $Job)
        $r = @($Result | Where-Object { $_ -and $null -ne $_.Exit }) | Select-Object -First 1
        if ($r -and $r.Declined) { Show-Toast 'Installation cancelled: the administrator approval was declined.' 'warn'; Write-UiLog 'Windows Sandbox: the administrator approval was declined.' 'Warning' }
        elseif ($r -and $r.Exit -in 0, 3010) { $script:SandboxRestart = $true; Show-Toast 'Windows Sandbox is installed. Restart Windows to finish.' 'ok'; Write-UiLog 'Windows Sandbox installed, restart required.' 'Success' }
        else { Show-Toast "Windows Sandbox could not be installed ($(if ($r) { if ($r.Message) { $r.Message } else { "exit code $($r.Exit)" } } else { 'no answer' }))." 'bad' }
        Update-SandboxState
        Update-Readiness
    })
    Update-Readiness
}

function Start-PackageTest {
    param([Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)][string]$Source, [string]$Title, [string]$Version, [hashtable]$Policy, [string]$FromVersion)
    if (Block-SandboxStart) { return }
    if ($Source -eq 'Winget' -and -not $script:ModuleState.Winget) { throw 'winget packages need the Microsoft.WinGet.Client module: install it under Settings > Components.' }
    $name = if ($Title) { $Title } else { $Package }
    $arguments = @{ Package = $Package; Source = $Source; Version = $Version; UpdateMode = $Policy.UpdateMode; GraceHours = $Policy.GraceHours; FromVersion = $FromVersion }
    $work = 'param($Package, $Source, $Version, $UpdateMode, $GraceHours, $FromVersion) $p = @{ ChocoName = $Package; Source = $Source; Version = $Version; UpdateMode = $UpdateMode; GraceHours = $GraceHours }; if ($FromVersion) { $p.FromVersion = $FromVersion }; Test-PackTunePackage @p -AutoRun'
    [void](Start-UiTask -Kind 'test' -Title "Sandbox test of ${name}: the lab plays detect, install, detect, uninstall, detect in the sandbox and reports the result" -Display "Sandbox: $name$(if ($FromVersion) { " (update from $FromVersion)" })" -Package $Package -Pool $script:TestPool -Arguments $arguments -Work $work -OnDone {
        param($Result, $Job)
        $outcome = @($Result | Where-Object { $_.Verdict }) | Select-Object -First 1
        if ($Job.Status -eq 'failed' -or -not $outcome) { Write-UiLog "[$($Job.Package)] the sandbox test could not run, see above." 'Error'; Show-Toast "Sandbox test of $($Job.Display) could not run: $(Get-FriendlyCause (@($Job.Log | Where-Object { $_.Level -eq 'Error' } | Select-Object -Last 1 | ForEach-Object { $_.Text })[0]))" 'bad' 'Details' { Show-Page 'Activity' } }
        elseif ($outcome.Verdict -eq 'Passed') { Write-UiLog "[$($Job.Package)] sandbox test passed." 'Success'; Show-Toast "$($Job.Display) passed." 'ok' }
        else { Write-UiLog "[$($Job.Package)] sandbox test failed: $($outcome.Message)" 'Warning'; Show-Toast "Sandbox test failed: $($outcome.Message)" 'warn' }
        Update-SelectionBar
        Update-TenantButtons
    })
    Show-SandboxStarted
    Update-SelectionBar
    Update-TenantButtons
}

function Assert-SignInSettings {
    if (-not $script:Settings.TenantID -or -not $script:Settings.ClientID) {
        Show-Page 'Settings'
        throw 'Enter tenant and the client ID of your app registration first (Settings), then sign in.'
    }
    if (-not $script:ModuleState.Ok) {
        Show-Page 'Settings'
        throw "IntuneWin32App $($script:MinimumModuleVersion) or newer is required (Settings > Components)."
    }
}

# ---------------------------------------------------------------- embedded sign-in (WebView2 window of this app)
# Default for the sign-in and the app registration setup. The system browser stays as the explicit choice (sign in
# menu) and as the automatic fallback when the WebView2 runtime is missing or the embedded window cannot start.
$script:EmbeddedAvailableOverride = $null   # tests: $true / $false instead of looking for the WebView2 runtime
$script:EmbeddedSignInOverride = $null      # tests: script block ($TenantID, $ClientID, $Scopes) returning a token response
$script:EmbeddedReason = ''
$script:LastSignInPath = ''                 # 'embedded' or 'browser' (what the last sign-in used)

function Test-EmbeddedSignIn {
    # Is the embedded window usable? Loads the WebView2 SDK once (download from NuGet, signature checked)
    if ($null -ne $script:EmbeddedAvailableOverride) { $script:EmbeddedReason = 'not available'; return [bool]$script:EmbeddedAvailableOverride }
    $window.Cursor = 'Wait'
    try { [void](Get-PackTuneWebView2 -CacheFolder (Join-Path $script:WorkRoot 'WebView2')); return $true }
    catch { $script:EmbeddedReason = $_.Exception.Message; return $false }
    finally { $window.Cursor = $null }
}

# One WebView2 profile per Windows user (%LOCALAPPDATA%\PackTune\WebView2Session, current user only, cleared on Sign out):
# the normal sign-in, the setup sign-in and the Keevault sign-in share the Microsoft session (no second password or passkey)
$script:SignInSession = if ($env:PACKTUNE_SMOKE) { Get-PackTuneSessionFolder -Root (Join-Path ([IO.Path]::GetTempPath()) ('PackTuneSmoke-' + [guid]::NewGuid().ToString('N'))) } else { Get-PackTuneSessionFolder }
# What the tenant granted so far, per tenant (next to the settings): the normal sign-in asks for exactly this, so a user who is
# no administrator is never sent to a consent page. Missing scopes are asked for by "Confirm now" only.
$script:GrantedScopesPath = Join-Path (Split-Path $script:SettingsPath -Parent) 'grantedscopes.json'
function Get-GrantedScopeMemory {
    $m = @{}
    try { if (Test-Path $script:GrantedScopesPath) { $j = Get-Content $script:GrantedScopesPath -Raw | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $m[$p.Name] = @($p.Value) } } } catch { }
    $m
}
function Save-GrantedScopes {
    # After a sign-in: the Graph scopes of the token are what the tenant granted (added to what is known)
    if (-not $Global:AccessToken -or -not $Global:AccessToken.Scopes -or -not $script:Settings.TenantID) { return }
    $granted = @($Global:AccessToken.Scopes | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' } | Where-Object { $_ -and $_ -notin 'offline_access', 'openid', 'profile', 'email' })
    $m = Get-GrantedScopeMemory
    $key = ([string]$script:Settings.TenantID).ToLower()
    $m[$key] = @(@($m[$key]) + $granted | Where-Object { $_ } | Select-Object -Unique)
    try { ($m | ConvertTo-Json -Depth 4) | Set-Content -Path $script:GrantedScopesPath -Encoding UTF8 } catch { }
}
function Get-PackTuneSignInScopes {
    # Normal sign-in: the base set on the very first sign-in, afterwards what was granted (remembered per tenant).
    # -Consent ("Confirm now"): everything the tool wants, the missing ones included; the administrator consents for the organization.
    param([switch]$Consent)
    $base = @($script:GraphScopeString -split ' ' | Where-Object { $_ -like 'https://graph.microsoft.com/*' } | ForEach-Object { $_ -replace '^https://graph\.microsoft\.com/', '' })
    $known = @((Get-GrantedScopeMemory)[([string]$script:Settings.TenantID).ToLower()] | Where-Object { $_ })
    if ($Consent) { return @($base + $known + @($script:GraphInsightScopes) | Select-Object -Unique) }
    if ($known.Count) { return @($known | Select-Object -Unique) }
    $base
}
function Test-AdminConsentRefusal($ErrorRecord) { $ErrorRecord.Exception.Message -like 'An administrator must confirm these permissions*' }
function Show-AdminConsentRefusal {
    Show-Toast 'An administrator must confirm these permissions.' 'warn'
    Write-UiLog 'An administrator must confirm these permissions (the sign-in of a user who is no administrator cannot grant them for the organization).' 'Warning'
}$script:SignInHint = ''
$script:FirstSignInHow = ''
$script:BrowserSignIn = 'Invoke-PackTuneBrowserSignIn'   # tests replace it
function Set-SignInHintFromToken {
    # Signed in already (browser, Keevault or this window): that account is the login hint, so a second sign-in lands on its session
    if ($script:SignInHint -or -not (Test-SignedIn)) { return }
    try { $a = (Get-PackTuneIdentity).Account; if ($a) { $script:SignInHint = [string]$a } } catch { }
}
function Invoke-EmbeddedSignIn {
    # Sign-in window, modal to the main window (its timer keeps the background tasks running). Returns the token response.
    param([Parameter(Mandatory)][string]$TenantID, [Parameter(Mandatory)][string]$ClientID, [string[]]$Scopes, [string]$Hint, [ValidateSet('default', 'consent')][string]$Prompt = 'default')
    Set-SignInHintFromToken
    $first = if ($script:FirstSignInHow) { $script:FirstSignInHow } else { 'this window (embedded Microsoft)' }
    Write-UiLog "Sign-in request ($(if ($ClientID -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { 'setup client: creating the app registration / store grant' } else { 'PackTune app registration' })): client id $ClientID; prompt $Prompt; login_hint sent: $([bool]$script:SignInHint); domain_hint sent: False; user data folder: $script:SignInSession; first sign-in of this run: $first; scopes: $(@($Scopes) -join ' ')"
    if ($script:FirstSignInHow -eq 'Keevault') {
        # The run was signed in through Keevault: every follow-up sign-in (consent, setup, package store grant) goes the same way,
        # so a re-authentication is confirmed in Keevault (passkey shim + auto-fill), never in the Windows passkey dialog
        Write-UiLog "Sign-in method of this run: Keevault (account $script:SignInHint); this window uses Keevault too."
        if ($script:KeevaultSignInOverride) { return (& $script:KeevaultSignInOverride $TenantID $ClientID $Scopes $Prompt $script:SignInSession) }
        $pump = { $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background) }
        return (Connect-PackTuneWithKeevault -TenantID $TenantID -ClientID $ClientID -CacheFolder (Join-Path $script:WorkRoot 'WebView2') -UserDataFolder $script:SignInSession -Scopes $Scopes -Prompt $Prompt -Owner $window -OnWait $pump -OnAccount { param($User) @{ TenantID = $TenantID; ClientID = $ClientID } })
    }
    if ($script:EmbeddedSignInOverride) { return (& $script:EmbeddedSignInOverride $TenantID $ClientID $Scopes $script:SignInHint $Prompt $script:SignInSession) }
    $params = @{ TenantID = $TenantID; ClientID = $ClientID; Scopes = $Scopes; CacheFolder = (Join-Path $script:WorkRoot 'WebView2'); Owner = $window; Title = 'Sign in to Microsoft'; Hint = $Hint; UserDataFolder = $script:SignInSession }
    $params.Prompt = $Prompt   # never 'login': the session of the shared profile goes straight on
    if ($script:SignInHint) { $params.LoginHint = $script:SignInHint }
    & $script:BrowserSignIn @params
}

function Test-EmbeddedStartFailure($ErrorRecord) { $ErrorRecord.Exception.Message -like 'The embedded browser could not start*' }

function Get-EmbeddedToken {
    <#
    The token of an embedded sign-in, or $null when the browser has to be used instead (a toast says why).
    A cancelled sign-in throws 'Sign-in cancelled.'.
    #>
    param([Parameter(Mandatory)][string]$TenantID, [Parameter(Mandatory)][string]$ClientID, [string[]]$Scopes, [string]$Hint, [ValidateSet('default', 'consent')][string]$Prompt = 'default')
    if (-not (Test-EmbeddedSignIn)) {
        Show-Toast "The sign-in window of this app is not available ($($script:EmbeddedReason -replace '\s+', ' ')). Using the web browser instead." 'warn'
        Write-UiLog "Embedded sign-in not available: $script:EmbeddedReason" 'Warning'
        return $null
    }
    try {
        $script:LastSignInPath = 'embedded'
        $token = Invoke-EmbeddedSignIn -TenantID $TenantID -ClientID $ClientID -Scopes $Scopes -Hint $Hint -Prompt $Prompt
        # The account that signed in is the login hint of the next sign-in in this run (same session, no second password)
        try { $claims = Get-PackTuneTokenClaims ([string]$token.access_token); $account = if ($claims.upn) { $claims.upn } elseif ($claims.preferred_username) { $claims.preferred_username } else { '' }; if ($account) { $script:SignInHint = [string]$account } } catch { }
        return $token
    }
    catch {
        if (Test-EmbeddedStartFailure $_) {
            $script:LastSignInPath = ''
            Show-Toast "The sign-in window could not start. Using the web browser instead." 'warn'
            Write-UiLog $_.Exception.Message 'Warning'
            return $null
        }
        throw
    }
}

function Connect-Intune {
    # Consent: the administrator confirms new permissions on the consent page of this same sign-in (prompt=consent)
    param([ValidateSet('Microsoft', 'Browser', 'Keevault')][string]$Method = 'Microsoft', [switch]$Consent)
    $prompt = if ($Consent) { 'consent' } else { 'default' }
    if (-not $script:Settings.ClientID -and $script:ModuleState.Ok -and $Method -ne 'Keevault') {
        # No app registration yet: the sign-in starts with its setup (admin sign-in, consent), then signs in with it
        $script:SignInAfterRegistration = $true
        Start-AppRegistration
        return
    }
    Assert-SignInSettings
    $tenant = $script:Settings.TenantID
    $clientId = $script:Settings.ClientID
    if ($Method -eq 'Keevault') {
        # Keevault and the embedded sign-in window take the foreground; the tool keeps painting meanwhile but takes no clicks
        $window.IsEnabled = $false
        $window.Cursor = 'Wait'
        try {
            $pump = { $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background) }
            $token = Connect-PackTuneWithKeevault -TenantID $tenant -ClientID $clientId -CacheFolder (Join-Path $script:WorkRoot 'WebView2') -UserDataFolder $script:SignInSession -Scopes (Get-PackTuneSignInScopes -Consent:$Consent) -Prompt $prompt -Owner $window -OnWait $pump -OnAccount { param($User) Resolve-AccountTenant $User }
            Set-PackTuneToken -TokenResponse $token -TenantID $token.SignInTenantID -ClientID $token.SignInClientID
            if (-not (Test-PackTuneSameTenant $token.SignInTenantID $tenant)) { Switch-Tenant $token.SignInTenantID $token.SignInClientID }
            $script:Shared.Auth = Get-PackTuneAuthState
            Complete-SignIn 'via Keevault'
        }
        catch {
            if (Test-AdminConsentRefusal $_) { Show-AdminConsentRefusal; Complete-SetupStep $false 'the sign-in' }
            elseif (Test-EmbeddedStartFailure $_) { Write-UiLog $_.Exception.Message 'Error'; Show-Toast 'The Keevault sign-in window could not start. Use Sign in in the web browser from the menu next to Sign in.' 'bad' 'Details' { Show-Page 'Activity' }; Complete-SetupStep $false 'the sign-in' }
            else { throw }
        }
        finally { $window.IsEnabled = $true; $window.Cursor = $null; [void]$window.Activate() }
        return
    }
    if ($Method -eq 'Microsoft') {
        # Default: the sign-in window of this app; the browser only when it cannot be used
        try {
            $token = Get-EmbeddedToken -TenantID $tenant -ClientID $clientId -Scopes (Get-PackTuneSignInScopes -Consent:$Consent) -Prompt $prompt
            if ($token) {
                Set-PackTuneToken -TokenResponse $token -TenantID $tenant -ClientID $clientId
                $script:Shared.Auth = Get-PackTuneAuthState
                Complete-SignIn 'in the app'
                return
            }
        }
        catch {
            if (Test-AdminConsentRefusal $_) { Show-AdminConsentRefusal; Complete-SetupStep $false 'the sign-in'; return }
            if ($_.Exception.Message -eq 'Sign-in cancelled.') { Show-SignInCancelled; Complete-SetupStep $false 'the sign-in'; return }
            Complete-SetupStep $false 'the sign-in'
            throw
        }
    }
    $script:LastSignInPath = 'browser'
    if (Test-TaskRunning 'connect') { return }
    # Sign-in in the browser (PKCE, answer on a loopback port). It waits in a background runspace, at most five
    # minutes, and "Cancel sign-in" ends it: closing the browser window must not block the next sign-in.
    $script:Shared.CancelSignIn = $false
    $work = @'
param($TenantID, $ClientID, $Authority, $UrlHandler)
$Params = @{ TenantID = $TenantID; ClientID = $ClientID; ShouldCancel = { $Shared.CancelSignIn } }
if ($Authority) { $Params.Authority = $Authority }
if ($UrlHandler) { $Params.UrlHandler = [scriptblock]::Create($UrlHandler) }
Connect-PackTune @Params | Out-Null
Get-PackTuneAuthState
'@
    $arguments = @{ TenantID = $tenant; ClientID = $clientId; Authority = $script:SignInTest.Authority; UrlHandler = $script:SignInTest.UrlHandler }
    [void](Start-UiTask -Kind 'connect' -Title "Sign in to ${tenant}: complete the Microsoft sign-in in your browser" -Display 'Sign-in' -Pool $script:UserPool -Work $work -Arguments $arguments -OnDone {
        param($Result, $Job)
        $state = @($Result | Where-Object { $_ -is [hashtable] -and $_.AccessToken })
        if ($Job.Status -ne 'succeeded' -or $state.Count -eq 0) { Update-ConnectionStatus; Complete-SetupStep $false 'the sign-in'; return }   # the reason is in the activity panel
        $script:Shared.Auth = $state[0]
        Set-PackTuneAuthState $script:Shared.Auth
        Complete-SignIn 'in the browser'
    })
}
function Get-AccountDomain([string]$User) { if ($User -match '@([^@\s]+)$') { $Matches[1].ToLower() } else { '' } }

function Resolve-AccountTenant([string]$User) {
    # The account chosen in Keevault decides the tenant. Its own app registration is needed there: the one of
    # another tenant is used when it is known, otherwise the tool switches and offers to create one.
    $tenant = [string]$script:Settings.TenantID
    $domain = Get-AccountDomain $User
    if (-not $domain -or (Test-PackTuneSameTenant $tenant $domain)) { return @{ TenantID = $tenant; ClientID = $script:Settings.ClientID } }
    $known = Get-PackTuneTenantClient $domain
    if ($known) {
        Write-UiLog "$User belongs to ${domain}: signing in there with its app registration ($known)."
        return @{ TenantID = $domain; ClientID = $known }
    }
    Switch-Tenant $domain ''
    throw "$User belongs to the tenant $domain, which has no app registration for this tool yet. The tool switched to ${domain}: click Create (start page) to set it up, then sign in again."
}

function Switch-Tenant([string]$TenantID, [string]$ClientID) {
    if (Test-PackTuneSameTenant $TenantID $script:Settings.TenantID) {
        # The same tenant under another name: nothing to switch, the app registration stays
        Write-UiLog "$TenantID is the tenant already in use ($($script:Settings.TenantID)): kept, app registration unchanged."
        return
    }
    $s = Get-PackTuneSettings; $s.TenantID = $TenantID; $s.ClientID = $ClientID
    [void](Save-PackTuneSettings -Settings $s); $script:Settings = Get-PackTuneSettings
    $script:TenantApps = $null; $script:CustomApps = $null; $script:TenantPackages = @{}
    Update-SettingsView
    Update-ConnectionStatus
    Write-UiLog "Tenant switched to $TenantID$(if ($ClientID) { " (app registration $ClientID)" } else { ', no app registration yet' })."
}

# Tests only: another authority and URL handler for the browser sign-in (set by Tests\GuiSmokeDriver.ps1)
$script:SignInTest = @{}

function Complete-SignIn([string]$How) {
    if (-not $script:FirstSignInHow) { $script:FirstSignInHow = $(switch -Wildcard ($How) { '*browser*' { 'system browser' } '*Keevault*' { 'Keevault' } default { 'embedded Microsoft' } }); try { Set-PackTuneSignInMethod $script:FirstSignInHow } catch { } }
    $script:TenantApps = $null
    Update-ConnectionStatus
    $identity = Get-PackTuneIdentity
    # Tenant identity is the GUID: remember which domain names belong to it (settings tenant, account domain)
    try { if ($identity.TenantId) { Register-PackTuneTenantAlias -Guid ([string]$identity.TenantId) -Name @([string]$script:Settings.TenantID, (Get-AccountDomain ([string]$identity.Account))); $script:Settings = Get-PackTuneSettings } } catch { }
    Save-GrantedScopes
    Write-UiLog "Signed in $How as $($identity.Account) (tenant $($identity.TenantId))." 'Success'
    Start-TenantRefresh
}

function Disconnect-Intune {
    $script:GraphDown = $null; $script:GraphRetryAt = $null; try { Update-GraphDownBanner } catch { }
    $script:Shared.Auth = $null
    Set-PackTuneAuthState @{}
    $script:TenantApps = $null; $script:CustomApps = $null; $script:TenantPackages = @{}; $script:RuntimeId = $null; $script:RuntimeInfo = $null; $script:StatusScript = $null; $script:SupersededOld = @()
    $script:DeviceCounts = @{}; $script:WingetNoRuntime = @(); $script:ImportApps = $null
    Update-TenantRows
    Update-AppList
    Update-ConnectionStatus
    $script:SignInHint = ''
    [void](Clear-PackTuneSession -UserDataFolder $script:SignInSession)   # the Microsoft session of the app's sign-in windows
    Write-UiLog 'Signed out. The sign-in in your browser stays, close it there if needed.'
}

function Show-Flyout {
    # Windows 11 flyout: right edge on the right edge of the target, 4 px below it (the template leaves 8 px for the shadow)
    param([Parameter(Mandatory)]$Menu, [Parameter(Mandatory)]$Target)
    $Menu.PlacementTarget = $Target
    $Menu.Placement = 'Custom'
    $Menu.CustomPopupPlacementCallback = [System.Windows.Controls.Primitives.CustomPopupPlacementCallback] {
        param($popupSize, $targetSize, $offset)
        $point = New-Object System.Windows.Point ($targetSize.Width - $popupSize.Width + 8), ($targetSize.Height - 4)
        , @([System.Windows.Controls.Primitives.CustomPopupPlacement]::new($point, [System.Windows.Controls.Primitives.PopupPrimaryAxis]::None))
    }
    $script:LastMenu = $Menu
    $Menu.IsOpen = $true
}

$script:SignInMenuMethods = @{}
function Show-SignInMenu($Target) {
    # Options of the split button next to Sign in
    $kv = Find-KeevaultMcp
    $menu = New-Object System.Windows.Controls.ContextMenu
    $items = @(
        @{ Glyph = [char]0xE774; Header = 'Sign in with Microsoft'; Text = 'Opens the Microsoft sign-in in a window of this app.'; Method = 'Microsoft'; Enabled = $true }
        @{ Glyph = [char]0xE12B; Header = 'Sign in in the web browser'; Text = 'Use it when your organization requires a compliant or joined device.'; Method = 'Browser'; Enabled = $true }
        @{ Glyph = [char]0xE72E; Header = 'Sign in with Keevault'; Method = 'Keevault'; Enabled = ($kv.Installed -and $kv.McpEnabled)
           Text = $(if (-not $kv.Installed) { 'Keevault is not installed.' }
                    elseif (-not $kv.McpEnabled) { 'Switch on AI agents (MCP) in Keevault first.' }
                    elseif (-not $kv.Running) { 'Start and unlock Keevault first, then pick the account there.' }
                    else { 'Pick the account in Keevault; it fills in password and code or confirms the passkey.' }) }
    )
    foreach ($i in $items) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $i.Header; $mi.Tag = [string]$i.Glyph; $mi.ToolTip = $i.Text; $mi.IsEnabled = $i.Enabled
        # The menu shows the text below the title; no extra tooltip popup
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($mi, $false)
        $script:SignInMenuMethods[$mi] = $i.Method
        $mi.Add_Click({
            param($src)
            try { Connect-Intune -Method $script:SignInMenuMethods[$src] } catch { Show-Error $_.Exception.Message }
        })
        [void]$menu.Items.Add($mi)
    }
    Show-Flyout $menu $Target
}

function Show-AccountMenu {
    # Account pill: sign out, switch to another tenant the tool knows
    $menu = New-Object System.Windows.Controls.ContextMenu
    $script:AccountMenuActions = @{}
    $entries = New-Object System.Collections.ArrayList
    [void]$entries.Add(@{ Glyph = [char]0xE7E8; Header = 'Sign out'; Text = 'The sign-in in your browser stays, close it there if needed.'; Action = { Disconnect-Intune } })
    $known = ConvertFrom-TenantClients $script:Settings.TenantClients
    foreach ($tenant in @($known.Keys | Sort-Object | Where-Object { $_ -ne ([string]$script:Settings.TenantID).ToLower() })) {
        $t = $tenant; $c = $known[$tenant]
        [void]$entries.Add(@{ Glyph = [char]0xE8AB; Header = "Switch to $t"; Text = 'Signs out and uses the app registration of that tenant.'; Action = { Disconnect-Intune; Switch-Tenant $t $c }.GetNewClosure() })
    }
    [void]$entries.Add(@{ Glyph = [char]0xE713; Header = 'Another tenant ...'; Text = 'Enter a tenant and client ID in the settings.'; Action = { Show-Page 'Settings' } })
    foreach ($i in $entries) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $i.Header; $mi.Tag = [string]$i.Glyph; $mi.ToolTip = $i.Text
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($mi, $false)
        $script:AccountMenuActions[$mi] = $i.Action
        $mi.Add_Click({ param($src) try { & $script:AccountMenuActions[$src] } catch { Show-Error $_.Exception.Message } })
        [void]$menu.Items.Add($mi)
    }
    Show-Flyout $menu $ui.BtnAccount
}
Add-Click $ui.BtnAccount { Show-AccountMenu }
Add-Click $ui.BtnSignIn {
    if ((Test-TaskRunning 'connect') -or (Test-TaskRunning 'appreg')) {
        $script:Shared.CancelSignIn = $true
        Write-UiLog 'Cancelling the sign-in ...'
    }
    else { Connect-Intune }
}
Add-Click $ui.BtnSignInMenu { Show-SignInMenu $ui.PanelSignedOut }

# ---------------------------------------------------------------- own title bar (WindowChrome): caption buttons, maximized state
function Update-WindowState {
    $max = $window.WindowState -eq 'Maximized'
    $ui.BtnMaximize.Content = [string]$(if ($max) { [char]0xE923 } else { [char]0xE922 })
    $ui.BtnMaximize.ToolTip = if ($max) { 'Restore' } else { 'Maximize' }
    # A maximized chrome window reaches over the screen edge by the size of its resize frame: keep the content inside
    $ui.RootGrid.Margin = if ($max) { [System.Windows.SystemParameters]::WindowResizeBorderThickness } else { New-Object System.Windows.Thickness 0 }
}
$window.Add_StateChanged({ Update-WindowState })
Add-Click $ui.BtnMinimize { $window.WindowState = 'Minimized' }
Add-Click $ui.BtnMaximize { $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } }
Add-Click $ui.BtnClose { $window.Close() }
# Alt+Down (or F4) opens the sign-in options, like a split button
$ui.PanelSignedOut.Add_PreviewKeyDown({
    param($s, $e)
    if (($e.Key -eq 'System' -and $e.SystemKey -eq 'Down') -or $e.Key -eq 'F4') { $e.Handled = $true; try { Show-SignInMenu $ui.PanelSignedOut } catch { Show-Error $_.Exception.Message } }
})

# ---------------------------------------------------------------- settings
function Update-SettingsView {
    $s = Get-PackTuneSettings
    $ui.TxtTenantId.Text = $s.TenantID
    $ui.TxtClientId.Text = $s.ClientID
    $ui.TxtMetadataFeed.Text = $s.MetadataFeed
    $ui.TxtPackageSource.Text = $s.PackageSource
    $ui.TxtChocoDownloadUrl.Text = $s.ChocolateyDownloadUrl
    $ui.TxtDelayMin.Text = [string]$s.UpdateDelayMinMinutes
    $ui.TxtDelayMax.Text = [string]$s.UpdateDelayMaxMinutes
    $ui.CmbArchitecture.SelectedItem = $s.Architecture
    $ui.CmbAssignment.SelectedItem = $s.Assignment
    $ui.CmbPreferredSource.SelectedIndex = if ($s.Source -eq 'Winget') { 0 } else { 1 }
    $ui.TxtSettingsPath.Text = $script:SettingsPath
    Set-PolicyControls 'Default' $s.UpdateMode $s.GraceHours
    $ui.CmbDefaultVersion.SelectedIndex = if ($s.VersionMode -eq 'Pinned') { 1 } else { 0 }
    $t = Format-ScheduleSummary (Get-ChocoScheduleDefaults)
    $ui.TxtDefaultSchedule.Text = "$($t.When). $($t.Conditions)."
    $script:SandboxState = $null; Update-Readiness; Update-SandboxButtons
    Update-ModuleState
}
$ui.CmbArchitecture.ItemsSource = @('x64x86', 'x64', 'x86', 'arm64', 'AllWithARM64')
$ui.CmbAssignment.ItemsSource = @('Available', 'Required', 'None')
$ui.CmbPreferredSource.ItemsSource = @('winget', 'Chocolatey')

function Save-Settings {
    $defaults = Read-PolicyControls 'Default'
    $new = [ordered]@{
        UpdateMode            = $defaults.UpdateMode
        GraceHours            = $defaults.GraceHours
        VersionMode           = $(if ($ui.CmbDefaultVersion.SelectedIndex -eq 1) { 'Pinned' } else { 'Latest' })
        TenantID              = $ui.TxtTenantId.Text
        ClientID              = $ui.TxtClientId.Text
        MetadataFeed          = $ui.TxtMetadataFeed.Text
        PackageSource         = $ui.TxtPackageSource.Text
        ChocolateyDownloadUrl = $ui.TxtChocoDownloadUrl.Text
        Architecture          = [string]$ui.CmbArchitecture.SelectedItem
        Assignment            = [string]$ui.CmbAssignment.SelectedItem
        UpdateDelayMinMinutes = $(if ($ui.TxtDelayMin.Text -match '^\d+$') { [int]$ui.TxtDelayMin.Text } else { throw 'The update delay must be a whole number of minutes.' })
        UpdateDelayMaxMinutes = $(if ($ui.TxtDelayMax.Text -match '^\d+$') { [int]$ui.TxtDelayMax.Text } else { throw 'The update delay must be a whole number of minutes.' })
        Source                = $(if ($ui.CmbPreferredSource.SelectedIndex -eq 0) { 'Winget' } else { 'Chocolatey' })
    }
    $feedChanged = $new.MetadataFeed.Trim() -ne $script:Settings.MetadataFeed
    [void](Save-PackTuneSettings -Settings ([pscustomobject]$new))
    $script:Settings = Get-PackTuneSettings
    if ($feedChanged) { $script:Shared.Meta.Clear(); $script:MetaDirty = $true }
    Write-UiLog "Settings saved to $script:SettingsPath." 'Success'
    Show-Toast 'Settings saved.' 'ok'
    Set-DeployDefaults
    $script:SandboxState = $null; Update-Readiness; Update-SandboxButtons
    Update-ConnectionStatus
}
function Set-DeployDefaults {
    $script:Preferred = if ($script:Settings.Source -eq 'Winget') { 'Winget' } else { 'Chocolatey' }
    $ui.RbPreferWinget.IsChecked = $script:Preferred -eq 'Winget'
    $ui.RbPreferChoco.IsChecked = $script:Preferred -ne 'Winget'
    switch ($script:Settings.Assignment) { 'Required' { $ui.RbRequired.IsChecked = $true } 'None' { $ui.RbNone.IsChecked = $true } default { $ui.RbAvailable.IsChecked = $true } }
}
Add-Click $ui.BtnSaveSettings { Save-Settings }
Add-Click $ui.BtnOpenWorkFolder { New-Item -Path $script:WorkRoot -ItemType Directory -Force | Out-Null; Start-Process explorer.exe $script:WorkRoot }
Add-Click $ui.BtnSettingsGrant {
    # The tenant and client ID typed here are saved first
    if ($ui.TxtTenantId.Text.Trim() -ne [string]$script:Settings.TenantID -or $ui.TxtClientId.Text.Trim() -ne [string]$script:Settings.ClientID) { Save-Settings }
    Start-AppRegistration
}
Add-Click $ui.BtnDefaultSchedule {
    Show-ScheduleDialog -Mode 'Default' -Schedule (Get-ChocoScheduleDefaults) -Title 'When updates install by default' -GraceHours (Read-PolicyControls 'Default').GraceHours
}

function Start-ModuleInstall {
    if (Test-TaskRunning 'components') { return }
    [void](Start-UiTask -Kind 'components' -Title "Installing the IntuneWin32App ($($script:MinimumModuleVersion) or newer) and Microsoft.WinGet.Client modules from the PowerShell Gallery" -Display 'Modules' -Work 'Install-PackTuneComponents' -Pool $script:UserPool -OnDone {
        param($Result, $Job)
        Update-ModuleState
        Update-ConnectionStatus
        if ($Job.Status -eq 'succeeded') { Write-UiLog "IntuneWin32App $($script:ModuleState.Version) and Microsoft.WinGet.Client $($script:ModuleState.WingetVersion) are ready." 'Success'; Show-Toast 'The modules are ready.' 'ok' }
        if ($script:CurrentPage -eq 'Apps') { Start-CatalogPrefetch }
        Complete-SetupStep ($Job.Status -eq 'succeeded') 'installing the modules'
    })
    Update-Readiness
}
Add-Click $ui.BtnInstallModule { Start-ModuleInstall }

# ---------------------------------------------------------------- run
$window.Add_Closing({
    param($s, $e)
    $running = @($script:Tasks | Where-Object { -not $_.Hidden -and $_.Job.Kind -in 'deploy', 'policy' })
    if ($running.Count -gt 0 -and -not $env:PACKTUNE_SMOKE) {
        $answer = if (Confirm-Action "$($running.Count) change(s) in Intune are still running. Close anyway? Apps that are half created need to be removed in Intune." 'Close PackTune' 'Close anyway' 'Keep open') { 'Yes' } else { 'No' }
        if ($answer -ne 'Yes') { $e.Cancel = $true }
    }
})
$window.Add_Closed({
    try { Close-PackTuneSessionHold } catch { }   # the session stays in its folder until Sign out
    $timer.Stop()
    Save-MetaCache
    # Not waited for: a task may sit in a web request, and the process ends right after this anyway
    $script:Shared.CancelSignIn = $true
    foreach ($task in @($script:Tasks)) { try { [void]$task.PS.BeginStop($null, $null) } catch { } }
    [System.Windows.Application]::Current.Shutdown()
})

Update-ModuleState
Set-DeployDefaults
Write-UiLog "PackTune $script:ToolVersion started. Work folder: $script:WorkRoot"
if (-not $script:ModuleState.Ok) { Write-UiLog "The IntuneWin32App module ($($script:MinimumModuleVersion) or newer) is missing: install it on the start page." 'Warning' }
Update-CatalogRows
Update-ConnectionStatus
Show-Page 'Start'
Update-TenantRows
$timer.Start()
$script:AutoRefreshPending = Test-PackTuneRefreshDue
Start-CatalogPrefetch
Start-PopularLoad -AllowStale
if (-not (Test-TaskRunning 'meta')) { Start-IconRender }   # all infos came from the cache
# Test hook: PACKTUNE_SMOKE names a script that drives the window off-screen and renders every page.
if ($env:PACKTUNE_SMOKE) { . $env:PACKTUNE_SMOKE }
$window.Show()
[void]$window.Activate()
[void][System.Windows.Application]::Current.Run()
