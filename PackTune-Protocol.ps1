# Protocol of a session: what an administrator did with PackTune since it started, as a ready-to-paste entry for a ticket system or
# time tracking. One structured action journal (fed from one place, Complete-UiTask of the window, through Add-PackTuneProtocolFromJob),
# rendered in English or German, saved after every action (atomic) to %LOCALAPPDATA%\PackTune\Protocols and, when the package store is
# set up, to the folder "Protocols" of its library (where other administrators' protocols can be read, read only).
# No tokens, passwords or secrets: every text that goes in is cleaned first (Remove-PackTuneProtocolSecrets).

$script:ProtocolFolderName = "Protocols"
# Order and names of the groups; the Kind of a job decides the group (Get-PackTuneProtocolCategory), kinds not listed are not recorded
$script:ProtocolCategories = @("deploy", "assignment", "policy", "removal", "test", "custom", "import", "repo", "export", "setup")
$script:ProtocolText = @{
    en = @{
        title = "PackTune session protocol"; date = "Date"; time = "Time"; duration = "Duration"; admin = "Administrator"; tenant = "Tenant"; actions = "Actions"
        none = "No actions in this session."; unknown = "not signed in"; minutes = "min"; hours = "h"; seconds = "s"
        ok = "done"; failed = "failed"; skipped = "skipped"; passed = "passed"; testfailed = "failed"
        deploy = "Deployments"; assignment = "Assignments"; policy = "Update settings and releases"; removal = "Removals"; test = "Sandbox tests"
        custom = "Custom applications"; import = "Imports"; repo = "Repositories"; export = "Exports"; setup = "Setup"
    }
    de = @{
        title = "PackTune-Sitzungsprotokoll"; date = "Datum"; time = "Zeit"; duration = "Dauer"; admin = "Administrator"; tenant = "Mandant"; actions = "Aktionen"
        none = "Keine Aktionen in dieser Sitzung."; unknown = "nicht angemeldet"; minutes = "Min"; hours = "Std"; seconds = "s"
        ok = "erledigt"; failed = "fehlgeschlagen"; skipped = "%uebersprungen"; passed = "bestanden"; testfailed = "nicht bestanden"
        deploy = "Bereitstellungen"; assignment = "Zuweisungen"; policy = "Update-Einstellungen und Releases"; removal = "Entfernungen"; test = "Sandbox-Tests"
        custom = "Eigene Anwendungen"; import = "Importe"; repo = "Repositories"; export = "Exporte"; setup = "Einrichtung"
    }
}

function ConvertFrom-PackTuneProtocolText([string]$Text) {
    # German texts are written with %ae %oe %ue %Ae %Oe %Ue %ss (the script file is plain ASCII)
    $Text.Replace("%ae", [string][char]0xE4).Replace("%oe", [string][char]0xF6).Replace("%ue", [string][char]0xFC).Replace("%Ae", [string][char]0xC4).Replace("%Oe", [string][char]0xD6).Replace("%Ue", [string][char]0xDC).Replace("%ss", [string][char]0xDF)
}

function Get-PackTuneProtocolLabels([string]$Language) {
    $Key = if ($Language -eq "de") { "de" } else { "en" }
    $Labels = @{}
    foreach ($Name in $script:ProtocolText[$Key].Keys) { $Labels[$Name] = ConvertFrom-PackTuneProtocolText $script:ProtocolText[$Key][$Name] }
    return $Labels
}

function Get-PackTuneProtocolFolder { Join-Path $script:WorkRoot $script:ProtocolFolderName }

function Remove-PackTuneProtocolSecrets {
    # Everything that looks like a token, a password or a key goes out before a text is recorded; ids (GUIDs) stay out of the text too
    param([AllowEmptyString()][string]$Text, [int]$MaxLength = 200)
    if (-not $Text) { return "" }
    $T = $Text
    $T = [regex]::Replace($T, 'eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}(\.[A-Za-z0-9_\-]*)?', "(token removed)")
    $T = [regex]::Replace($T, '(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{8,}', '$1 (removed)')
    $T = [regex]::Replace($T, '(?i)\b(password|passwort|pwd|secret|client_secret|token|access_token|refresh_token|apikey|api[_-]?key|sas|sig|code)\s*[=:]\s*("[^"]*"|''[^'']*''|\S+)', '$1=(removed)')
    $T = [regex]::Replace($T, '(?i)([?&](sig|token|code|key|access_token)=)[^&\s]+', '$1(removed)')
    $T = [regex]::Replace($T, '\b[A-Za-z0-9+/_\-]{40,}={0,2}', "(removed)")
    $T = [regex]::Replace($T, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', "(id)")
    $T = ($T -replace '\s+', ' ').Trim()
    if ($T.Length -gt $MaxLength) { $T = $T.Substring(0, $MaxLength - 3) + "..." }
    return $T
}

function Get-PackTuneProtocolCategory {
    # The group of a job, or $null when the job is not part of the protocol (reads, checks, icons, feed lookups)
    param([string]$Kind, [string]$Title)
    switch ($Kind) {
        "deploy" { return "deploy" }
        "assign" { return "assignment" }
        "policy" { return "policy" }
        "release" { return "policy" }
        "remove" { return "removal" }
        "test" { return "test" }
        "takeover" { return "import" }
        "export" { return "export" }
        { $_ -in "repoadd", "repoapprove", "repowrite", "repomove" } { return "repo" }
        { $_ -in "runtime", "chocolatey", "components", "appreg", "store", "statusscript", "toolchain", "sandboxinstall", "cleanup", "cleanupdeps" } { return "setup" }
        "custom" {
            if ($Title -match '^Removing ') { return "removal" }
            if ($Title -match '^Exporting ') { return "export" }
            return "custom"
        }
        default { return $null }
    }
}

function New-PackTuneProtocol {
    param([string]$Admin, [string]$Account, [string]$Tenant, [datetime]$Started = (Get-Date))
    [ordered]@{
        Format  = "PackTune.Protocol"; Version = 1
        Id      = $Started.ToString("yyyy-MM-dd-HHmmss")
        Started = $Started.ToString("o"); Ended = $Started.ToString("o")
        Admin   = (Remove-PackTuneProtocolSecrets $Admin 80); Account = (Remove-PackTuneProtocolSecrets $Account 120); Tenant = (Remove-PackTuneProtocolSecrets $Tenant 120)
        Actions = New-Object System.Collections.ArrayList
    }
}

function Set-PackTuneProtocolIdentity {
    # Admin and tenant are known once someone signed in; later calls only fill what is still empty
    param([Parameter(Mandatory = $true)]$Protocol, [string]$Admin, [string]$Account, [string]$Tenant)
    if ($Admin -and -not $Protocol.Admin) { $Protocol.Admin = Remove-PackTuneProtocolSecrets $Admin 80 }
    if ($Account -and -not $Protocol.Account) { $Protocol.Account = Remove-PackTuneProtocolSecrets $Account 120 }
    if ($Tenant -and -not $Protocol.Tenant) { $Protocol.Tenant = Remove-PackTuneProtocolSecrets $Tenant 120 }
}

function Add-PackTuneProtocolAction {
    # Result: ok, failed, skipped, passed (sandbox verdict) or testfailed
    param(
        [Parameter(Mandatory = $true)]$Protocol, [Parameter(Mandatory = $true)][string]$Category, [Parameter(Mandatory = $true)][string]$Subject,
        [ValidateSet("ok", "failed", "skipped", "passed", "testfailed")][string]$Result = "ok", [string]$Note, [datetime]$At = (Get-Date)
    )
    if ($Category -notin $script:ProtocolCategories) { throw "Unknown protocol group '$Category'" }
    $Entry = [ordered]@{ At = $At.ToString("o"); Category = $Category; Subject = (Remove-PackTuneProtocolSecrets $Subject 120); Result = $Result; Note = (Remove-PackTuneProtocolSecrets $Note 200) }
    [void]$Protocol.Actions.Add($Entry)
    if ($At -gt [datetime]$Protocol.Ended) { $Protocol.Ended = $At.ToString("o") }
    return $Entry
}

function Add-PackTuneProtocolFromJob {
    <#
        The one hook: a finished job of the window becomes an action. $Job is the job table of Start-UiTask (Kind, Title, Display, Status, Source,
        Finished, Result). -Cause is the short reason of a failure (the window's friendly cause). Returns the action, or $null when the job is
        not part of the protocol.
    #>
    param([Parameter(Mandatory = $true)]$Protocol, [Parameter(Mandatory = $true)]$Job, [string]$Cause)
    $Category = Get-PackTuneProtocolCategory -Kind ([string]$Job.Kind) -Title ([string]$Job.Title)
    if (-not $Category) { return $null }
    $Subject = if ($Job.Display) { [string]$Job.Display } else { [string]$Job.Title }
    $Result = switch ([string]$Job.Status) { "succeeded" { "ok" } "skipped" { "skipped" } default { "failed" } }
    $Note = ""
    if ($Category -eq "test") {
        $Outcome = @($Job.Result | Where-Object { $_.Verdict }) | Select-Object -First 1
        if ($Outcome) {
            $Result = if ([string]$Outcome.Verdict -eq "Passed") { "passed" } else { "testfailed" }
            if ($Result -eq "testfailed") { $Note = [string]$Outcome.Message }
        }
        elseif ($Result -eq "ok") { $Result = "failed"; $Note = "no verdict" }
    }
    if ($Category -eq "policy" -and [string]$Job.Title -match '^[^:]+:\s*(.+)$') { $Note = $Matches[1] }
    if ($Category -eq "deploy" -and $Job.Source) { $Note = [string]$Job.Source }
    if ($Result -eq "failed" -and $Cause) { $Note = $(if ($Note) { "$Note - $Cause" } else { $Cause }) }
    $At = if ($Job.Finished) { [datetime]$Job.Finished } else { Get-Date }
    return Add-PackTuneProtocolAction -Protocol $Protocol -Category $Category -Subject $Subject -Result $Result -Note $Note -At $At
}

function Get-PackTuneProtocolDuration($Protocol, [datetime]$End) {
    $Stop = if ($End) { $End } else { [datetime]$Protocol.Ended }
    $Span = $Stop - [datetime]$Protocol.Started
    if ($Span.TotalSeconds -lt 0) { $Span = [TimeSpan]::Zero }
    return $Span
}

function Format-PackTuneProtocolSpan([TimeSpan]$Span, $Labels) {
    if ($Span.TotalHours -ge 1) { return "{0} {1} {2} {3}" -f [int][math]::Floor($Span.TotalHours), $Labels.hours, $Span.Minutes, $Labels.minutes }
    if ($Span.TotalMinutes -ge 1) { return "{0} {1}" -f [int][math]::Round($Span.TotalMinutes), $Labels.minutes }
    return "{0} {1}" -f [int]$Span.TotalSeconds, $Labels.seconds
}

function ConvertTo-PackTuneProtocolText {
    <#
        The protocol as text for pasting: header (date, start, end, duration, administrator, tenant), then every group with its actions
        (time, subject, result, short note). -Format Markdown uses a heading and bullet points. -End is "now" for a running protocol.
    #>
    param([Parameter(Mandatory = $true)]$Protocol, [ValidateSet("en", "de")][string]$Language = "en", [ValidateSet("Text", "Markdown")][string]$Format = "Text", [datetime]$End)
    $L = Get-PackTuneProtocolLabels $Language
    $Started = [datetime]$Protocol.Started
    $Stop = if ($End) { $End } else { [datetime]$Protocol.Ended }
    $Span = Get-PackTuneProtocolDuration $Protocol $Stop
    $Culture = if ($Language -eq "de") { [Globalization.CultureInfo]::GetCultureInfo("de-DE") } else { [Globalization.CultureInfo]::InvariantCulture }
    $DateText = if ($Language -eq "de") { $Started.ToString("dd.MM.yyyy", $Culture) } else { $Started.ToString("yyyy-MM-dd", $Culture) }
    $Who = if ($Protocol.Admin -and $Protocol.Account -and $Protocol.Admin -ne $Protocol.Account) { "$($Protocol.Admin) ($($Protocol.Account))" } elseif ($Protocol.Admin) { [string]$Protocol.Admin } elseif ($Protocol.Account) { [string]$Protocol.Account } else { $L.unknown }
    $Tenant = if ($Protocol.Tenant) { [string]$Protocol.Tenant } else { $L.unknown }
    $Actions = @($Protocol.Actions)
    $Out = New-Object System.Collections.Generic.List[string]
    $Bullet = if ($Format -eq "Markdown") { "- " } else { "  " }
    if ($Format -eq "Markdown") { $Out.Add("# $($L.title)"); $Out.Add("") } else { $Out.Add($L.title) }
    foreach ($Pair in @(
            @($L.date, $DateText),
            @($L.time, ("{0} - {1}" -f $Started.ToString("HH:mm"), $Stop.ToString("HH:mm"))),
            @($L.duration, (Format-PackTuneProtocolSpan $Span $L)),
            @($L.admin, $Who), @($L.tenant, $Tenant), @($L.actions, [string]$Actions.Count))) {
        $Out.Add($(if ($Format -eq "Markdown") { "- **$($Pair[0]):** $($Pair[1])" } else { "$($Pair[0]): $($Pair[1])" }))
    }
    $Out.Add("")
    if (-not $Actions.Count) { $Out.Add($L.none) }
    foreach ($Category in $script:ProtocolCategories) {
        $Group = @($Actions | Where-Object { $_.Category -eq $Category } | Sort-Object { [datetime]$_.At })
        if (-not $Group.Count) { continue }
        $Out.Add($(if ($Format -eq "Markdown") { "## $($L[$Category])" } else { "$($L[$Category]):" }))
        foreach ($A in $Group) {
            $Word = $L[[string]$A.Result]
            $Line = "{0}{1}  {2}: {3}" -f $Bullet, ([datetime]$A.At).ToString("HH:mm"), $A.Subject, $Word
            if ($A.Note) { $Line += " ($($A.Note))" }
            $Out.Add($Line)
        }
        $Out.Add("")
    }
    return (($Out -join "`r`n").TrimEnd() + "`r`n")
}

function Write-PackTuneAtomicFile {
    # Written next to the target, then moved over it: a crash leaves the old or the new file, never half of one
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $Folder = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -Path $Folder -ItemType Directory -Force | Out-Null }
    $Temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [IO.File]::WriteAllText($Temp, $Text, (New-Object Text.UTF8Encoding $true))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($Temp, $Path, [NullString]::Value) } else { [IO.File]::Move($Temp, $Path) }
    }
    finally { if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue } }
}

function Get-PackTuneProtocolFileBase($Protocol) {
    # <date-time>-<user>: the Windows user name (known before anyone signs in, so the name never changes during a session);
    # letters, digits, dot, dash only (the same name is used in the package store)
    $User = ([string]$env:USERNAME) -replace '[^A-Za-z0-9._-]', '-'
    $User = $User.Trim("-.")
    if (-not $User) { $User = "admin" }
    if ($User.Length -gt 40) { $User = $User.Substring(0, 40) }
    return "$($Protocol.Id)-$User"
}

function Save-PackTuneProtocol {
    # The journal as .json (source of truth) and the readable .md next to it, atomically; called after every action
    param([Parameter(Mandatory = $true)]$Protocol, [string]$Folder = (Get-PackTuneProtocolFolder), [string]$Language = "en")
    $Base = Get-PackTuneProtocolFileBase $Protocol
    $Json = Join-Path $Folder "$Base.json"
    Write-PackTuneAtomicFile -Path $Json -Text ($Protocol | ConvertTo-Json -Depth 6)
    Write-PackTuneAtomicFile -Path (Join-Path $Folder "$Base.md") -Text (ConvertTo-PackTuneProtocolText -Protocol $Protocol -Language $Language -Format Markdown)
    return $Json
}

function Read-PackTuneProtocolJson {
    # A protocol from its json text; $null when it is not one (a foreign or damaged file never breaks the history)
    param([Parameter(Mandatory = $true)][string]$Text)
    try {
        $Raw = $Text.TrimStart([char]0xFEFF) | ConvertFrom-Json
        if ($Raw.Format -ne "PackTune.Protocol" -or -not $Raw.Id -or -not $Raw.Started) { return $null }
        $P = [ordered]@{ Format = "PackTune.Protocol"; Version = 1; Id = [string]$Raw.Id; Started = [string]$Raw.Started; Ended = $(if ($Raw.Ended) { [string]$Raw.Ended } else { [string]$Raw.Started })
            Admin = [string]$Raw.Admin; Account = [string]$Raw.Account; Tenant = [string]$Raw.Tenant; Actions = (New-Object System.Collections.ArrayList) }
        foreach ($A in @($Raw.Actions)) {
            if ($A.Category -notin $script:ProtocolCategories) { continue }
            [void]$P.Actions.Add([ordered]@{ At = [string]$A.At; Category = [string]$A.Category; Subject = (Remove-PackTuneProtocolSecrets ([string]$A.Subject) 120); Result = $(if ([string]$A.Result -in "ok", "failed", "skipped", "passed", "testfailed") { [string]$A.Result } else { "ok" }); Note = (Remove-PackTuneProtocolSecrets ([string]$A.Note) 200) })
        }
        return $P
    }
    catch { return $null }
}

function Send-PackTuneProtocolToStore {
    # The protocol (json and md) into the folder "Protocols" of the package store library; throws when the store cannot be reached
    param([Parameter(Mandatory = $true)]$Protocol, $Store = (Resolve-PackTuneStore), [string]$Language = "en")
    if (-not $Store.DriveId) { throw "The package store has no library yet." }
    $Base = Get-PackTuneProtocolFileBase $Protocol
    $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-protocol-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $Temp -Force | Out-Null
    try {
        $Json = Join-Path $Temp "$Base.json"; $Md = Join-Path $Temp "$Base.md"
        [IO.File]::WriteAllText($Json, ($Protocol | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $true))
        [IO.File]::WriteAllText($Md, (ConvertTo-PackTuneProtocolText -Protocol $Protocol -Language $Language -Format Markdown), (New-Object Text.UTF8Encoding $true))
        Send-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($script:ProtocolFolderName, "$Base.json") -LocalPath $Json
        Send-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($script:ProtocolFolderName, "$Base.md") -LocalPath $Md
    }
    finally { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-PackTuneProtocolHistory {
    <#
        Earlier protocols, newest first: the local folder and, when $Store is given, the store folder (other administrators' too).
        One row per protocol Id + account (a protocol that is in both places once, Where = Local, Store or Both). Returns the rows;
        -Warnings collects what could not be read (the history is shown with what is there).
    #>
    param([string]$Folder = (Get-PackTuneProtocolFolder), $Store, [int]$Limit = 60, [ref]$Warnings)
    $Rows = @{}
    $Notes = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Folder) {
        foreach ($File in @(Get-ChildItem -LiteralPath $Folder -Filter "*.json" -File | Sort-Object Name -Descending | Select-Object -First $Limit)) {
            $P = Read-PackTuneProtocolJson -Text ([IO.File]::ReadAllText($File.FullName))
            if (-not $P) { continue }
            $Rows[[IO.Path]::GetFileNameWithoutExtension($File.Name)] = @{ Protocol = $P; Where = "Local" }
        }
    }
    if ($Store -and $Store.DriveId) {
        try {
            $Names = @(Get-PackTuneStoreChildren -DriveId $Store.DriveId -Segments @($script:ProtocolFolderName) | Where-Object { -not $_.folder -and [string]$_.name -like "*.json" } | ForEach-Object { [string]$_.name } | Sort-Object -Descending | Select-Object -First $Limit)
            foreach ($Name in $Names) {
                $Key = [IO.Path]::GetFileNameWithoutExtension($Name)
                if ($Rows.ContainsKey($Key)) { $Rows[$Key].Where = "Both"; continue }
                $Temp = Join-Path ([IO.Path]::GetTempPath()) ("packtune-protocol-" + [guid]::NewGuid().ToString("N") + ".json")
                try {
                    Receive-PackTuneStoreFile -DriveId $Store.DriveId -Segments @($script:ProtocolFolderName, $Name) -Destination $Temp
                    $P = Read-PackTuneProtocolJson -Text ([IO.File]::ReadAllText($Temp))
                    if ($P) { $Rows[$Key] = @{ Protocol = $P; Where = "Store" } }
                }
                catch { [void]$Notes.Add("$Name could not be read: $($_.Exception.Message)") }
                finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
            }
        }
        catch { [void]$Notes.Add("The package store could not be read: $($_.Exception.Message)") }
    }
    if ($Warnings) { $Warnings.Value = @($Notes) }
    return @($Rows.Keys | Sort-Object -Descending | ForEach-Object {
            $P = $Rows[$_].Protocol
            [pscustomobject]@{ Key = $_; Id = $P.Id; Started = [datetime]$P.Started; Admin = $(if ($P.Admin) { $P.Admin } else { $P.Account }); Account = $P.Account; Duration = (Get-PackTuneProtocolDuration $P); Count = @($P.Actions).Count; Where = $Rows[$_].Where; Protocol = $P }
        })
}
