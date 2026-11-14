# Fake IntuneWin32App for the GUI smoke test (Tests\Invoke-GuiSmoke.ps1): no network, apps are kept in a JSON file
$Store = Join-Path $env:LOCALAPPDATA "fake-intune.json"
function Read-Store { if (Test-Path $Store) { $Data = Get-Content $Store -Raw | ConvertFrom-Json; @(foreach ($Item in $Data) { $Item }) } else { @() } }
function Write-Store($Apps) { ConvertTo-Json -InputObject @($Apps) -Depth 6 | Set-Content $Store }

function Test-FakeAccessToken {
    # Behaves like the real module 1.5.0 where it hurts: the expiry check only works with an invariant date format
    # (it writes the date in the current culture and reads it back as en-US), and a failed check ends the calling
    # function with "break". Callers that do not go through Invoke-IntuneModule get the same silent stop here,
    # on every machine and every day of the month.
    if ($null -eq $Global:AccessToken -or $null -eq $Global:AuthenticationHeader) {
        Write-Warning "Unable to find authentication header, use Connect-MSIntuneGraph function before running this function (fake)"; break
    }
    if ([System.Threading.Thread]::CurrentThread.CurrentCulture.Name -ne "") {
        Write-Warning "Silent token refresh failed (fake): the module was called outside Invoke-IntuneModule"; break
    }
    $Expires = [DateTimeOffset]::Parse($Global:AccessToken.ExpiresOn.ToString(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
    if ($Expires -le [DateTimeOffset]::UtcNow.AddMinutes(5)) { Write-Warning "Access token has expired (fake)"; break }
}

function Get-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    Test-FakeAccessToken
    # Tests: the network is down (like the real module: a warning and no result)
    if (Test-Path (Join-Path $env:LOCALAPPDATA 'fake-network-down')) { Write-Warning ("Der Remotename konnte nicht aufgel" + [char]0xF6 + "st werden: 'graph.microsoft.com'"); return }
    $Apps = Read-Store
    if ($ID) { $Apps = $Apps | Where-Object { $_.id -eq $ID } }
    # Tests: the list of the tenant lags behind (Graph): apps created after the file was written are not listed yet, by id they are
    $Lag = Join-Path $env:LOCALAPPDATA 'fake-list-lag'
    if (-not $ID -and (Test-Path $Lag)) { $Since = (Get-Item $Lag).LastWriteTime; $Apps = $Apps | Where-Object { $_.createdDateTime -and [datetime]$_.createdDateTime -lt $Since } }
    if ($DisplayName) { $Apps = $Apps | Where-Object { $_.displayName -like "*$DisplayName*" } }
    $Apps
}
function Update-IntuneWin32AppPackageFile { param([string]$ID, [string]$FilePath)
    Test-FakeAccessToken
    if (-not (Test-Path $FilePath)) { throw "intunewin missing" }
    $Apps = Read-Store; ($Apps | Where-Object id -eq $ID).uploads++; Write-Store $Apps
}
function Set-IntuneWin32App {
    # Same types as the real module: a detection rule of the wrong type fails here too
    param([string]$ID, [string]$Notes, [string]$AppVersion, [System.Collections.Specialized.OrderedDictionary[]]$DetectionRule)
    Test-FakeAccessToken
    $Apps = Read-Store
    $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    if ($Notes) { $App.notes = $Notes }
    if ($AppVersion) { $App.displayVersion = $AppVersion }
    if ($DetectionRule) { $App.detection = $DetectionRule[0].scriptContent }
    Write-Store $Apps
}
function Remove-IntuneWin32App { param([string]$DisplayName, [string]$ID)
    Test-FakeAccessToken
    Invoke-FakeIntuneGraph -Method DELETE -Path "mobileApps/$ID"
}
function New-IntuneWin32AppPackage { param($SourceFolder, $SetupFile, $OutputFolder, [switch]$Force)
    $Path = Join-Path $OutputFolder "install.intunewin"; Set-Content $Path "fake"; [pscustomobject]@{ Path = $Path }
}
function New-IntuneWin32AppDetectionRuleScript { param($ScriptFile) [ordered]@{ "@odata.type" = "script"; scriptContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScriptFile)) } }
function New-IntuneWin32AppDetectionRuleFile { param([switch]$Existence, $DetectionType, $Path, $FileOrFolder) @{ type = "file" } }
function New-IntuneWin32AppRequirementRule { param($Architecture, $MinimumSupportedWindowsRelease) @{ arch = $Architecture; release = [string]$MinimumSupportedWindowsRelease } }

function New-IntuneWin32AppDependency { param($ID, $DependencyType) [ordered]@{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $ID; dependencyType = ([string]$DependencyType).ToLower().Replace("autoinstall", "autoInstall") } }
function Add-IntuneWin32AppDependency {
    # Like the real module: replaces the dependencies of the app and keeps its supersedence
    param($ID, [System.Collections.Specialized.OrderedDictionary[]]$Dependency)
    Test-FakeAccessToken
    $Apps = Read-Store; $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    # The real module replaces the whole dependency list (supersedence stays)
    $App.dependencies = @(@($Dependency | ForEach-Object { [pscustomobject]@{ targetId = $_.targetId; dependencyType = $_.dependencyType } }) | Where-Object { $_ })
    Write-Store $Apps; $true
}
function Get-IntuneWin32AppDependency { param([string]$ID)
    Test-FakeAccessToken
    $App = Read-Store | Where-Object id -eq $ID
    @(@($App.dependencies) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ "@odata.type" = "#microsoft.graph.mobileAppDependency"; targetId = $_.targetId; dependencyType = $_.dependencyType } })
}
function New-IntuneWin32AppSupersedence { param([string]$ID, [ValidateSet("Replace", "Update")][string]$SupersedenceType)
    Test-FakeAccessToken
    if (-not (Read-Store | Where-Object id -eq $ID)) { Write-Warning "no app $ID (fake)"; return }
    [ordered]@{ "@odata.type" = "#microsoft.graph.mobileAppSupersedence"; supersedenceType = $SupersedenceType.ToLower(); targetId = $ID }
}
function Add-IntuneWin32AppSupersedence { param([string]$ID, [System.Collections.Specialized.OrderedDictionary[]]$Supersedence)
    Test-FakeAccessToken
    $Apps = Read-Store; $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    if ($ID -in $Supersedence.targetId) { throw "An app cannot supersede itself (fake)" }
    $App.supersedence = @(@($App.supersedence) + @($Supersedence | ForEach-Object { [pscustomobject]@{ targetId = $_.targetId; supersedenceType = $_.supersedenceType } }) | Where-Object { $_ })
    Write-Store $Apps; $true
}
function Get-IntuneWin32AppSupersedence { param([string]$ID)
    Test-FakeAccessToken
    $App = Read-Store | Where-Object id -eq $ID
    @(@($App.supersedence) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ "@odata.type" = "#microsoft.graph.mobileAppSupersedence"; targetId = $_.targetId; supersedenceType = $_.supersedenceType } })
}
function Remove-IntuneWin32AppSupersedence { param([string]$ID)
    Test-FakeAccessToken
    $Apps = Read-Store; ($Apps | Where-Object id -eq $ID).supersedence = @(); Write-Store $Apps; $true
}
function Add-FakeAssignment($ID, $Type, $Intent, $GroupID, $AutoUpdate, $Notification) {
    $Apps = Read-Store; $App = $Apps | Where-Object id -eq $ID
    if (-not $App) { throw "App $ID not found (fake)" }
    $Record = [pscustomobject]@{ Type = $Type; Intent = $Intent; GroupID = $GroupID; AutoUpdateSupersededApps = $AutoUpdate; Notifications = $Notification }
    $App.assignments = @(@($App.assignments) + $Record | Where-Object { $_ })
    $App.assignment = $Intent
    Write-Store $Apps; $true
}
function Add-IntuneWin32AppAssignmentAllUsers { param($ID, $Intent, $Notification = "showAll", $AutoUpdateSupersededApps = "notConfigured")
    Test-FakeAccessToken
    if ($AutoUpdateSupersededApps -eq "enabled" -and $Intent -ne "available") { Write-Warning "AutoUpdateSupersededApps is only allowed with Intent available (fake)"; break }
    Add-FakeAssignment $ID "#microsoft.graph.allLicensedUsersAssignmentTarget" $Intent $null $AutoUpdateSupersededApps $Notification
}
function Add-IntuneWin32AppAssignmentAllDevices { param($ID, $Intent, $Notification = "showAll", $AutoUpdateSupersededApps = "notConfigured")
    Test-FakeAccessToken
    Add-FakeAssignment $ID "#microsoft.graph.allDevicesAssignmentTarget" $Intent $null $AutoUpdateSupersededApps $Notification
}
function Add-IntuneWin32AppAssignmentGroup { param([switch]$Include, $ID, $GroupID, $Intent, $Notification = "showAll", $AutoUpdateSupersededApps = "notConfigured")
    Test-FakeAccessToken
    Add-FakeAssignment $ID $(if ($Include) { "#microsoft.graph.groupAssignmentTarget" } else { "#microsoft.graph.exclusionGroupAssignmentTarget" }) $Intent $GroupID $AutoUpdateSupersededApps $Notification
}
function Get-IntuneWin32AppAssignment { param([string]$ID)
    Test-FakeAccessToken
    $App = Read-Store | Where-Object id -eq $ID
    @(@($App.assignments) | Where-Object { $_ })
}
function Add-IntuneWin32App {
    param($FilePath, $DisplayName, $Description, $Publisher, $AppVersion, $Notes, $InstallExperience, $RestartBehavior, $DetectionRule,
        $RequirementRule, $InstallCommandLine, $UninstallCommandLine, $InformationURL, $Icon)
    Test-FakeAccessToken
    if (-not (Test-Path $FilePath)) { throw "intunewin missing" }
    # Tests: the real module gives up with a warning and no object (e.g. a token it cannot use); nothing is created
    if (Test-Path (Join-Path $env:LOCALAPPDATA 'fake-add-silent')) { Write-Warning "Failed to create Win32 app, see the error above (fake)"; return }
    $App = [pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = $DisplayName; notes = $Notes; createdDateTime = (Get-Date).ToString("o")
        hasIcon = [bool]$Icon; iconValid = $(if ($Icon) { $b = [Convert]::FromBase64String($Icon); ($b[0] -eq 0x89 -or $b[0] -eq 0xFF) } else { $false })
        arch = $RequirementRule.arch; publisher = $Publisher; assignment = $null; install = $InstallCommandLine
        displayVersion = $AppVersion; detection = $DetectionRule.scriptContent; uploads = 1
        description = $Description; informationUrl = $InformationURL; largeIcon = $(if ($Icon) { [pscustomobject]@{ type = "image/png"; value = $Icon } } else { $null })
        applicableArchitectures = $RequirementRule.arch; minimumSupportedWindowsRelease = $RequirementRule.release
        dependencies = @(); supersedence = @(); assignments = @()
    }
    Write-Store (@(Read-Store) + $App)
    Start-Sleep -Milliseconds 500
    $App
}
function Invoke-FakeIntuneGraph {
    # The relationship API of Microsoft Graph (beta deviceAppManagement), the way the real service behaves:
    #   GET    mobileApps/{id}/relationships        own relationships (targetType child) and those of other apps that point at this
    #                                               one (targetType parent), dependencies and supersedence alike
    #   POST   mobileApps/{id}/updateRelationships  REPLACES the whole set of the app (dependencies AND supersedence); what is not in
    #                                               the body is gone
    #   DELETE mobileApps/{id}                      400 while the app has relationships of its own ("it is the parent of another app")
    #                                               or while another app points at it
    param([string]$Method = "GET", [string]$Path, $Body)
    Test-FakeAccessToken
    $Apps = Read-Store
    if ($Path -notmatch '^mobileApps/([^/]+)(/(relationships|updateRelationships))?$') { throw "fake Graph: unknown path $Path" }
    $Id = $Matches[1]; $Tail = $Matches[3]
    $App = $Apps | Where-Object id -eq $Id
    if (-not $App) { throw "fake Graph: (404) Not Found: app $Id" }
    $Own = { param($A) @(@(@($A.dependencies) | Where-Object { $_ } | ForEach-Object { @{ Kind = "dep"; TargetId = $_.targetId; Type = $_.dependencyType } }) + @(@($A.supersedence) | Where-Object { $_ } | ForEach-Object { @{ Kind = "sup"; TargetId = $_.targetId; Type = $_.supersedenceType } })) }
    $Name = { param($I) ($Apps | Where-Object id -eq $I).displayName }
    if ($Method -eq "GET" -and $Tail -eq "relationships") {
        $Rows = New-Object System.Collections.ArrayList
        # The service keeps no relationship to an app that is gone
        foreach ($R in @(& $Own $App | Where-Object { $T = $_.TargetId; $Apps | Where-Object id -eq $T })) {
            $Row = [ordered]@{ id = "$Id`_$($R.TargetId)"; sourceId = $Id; targetId = $R.TargetId; targetDisplayName = (& $Name $R.TargetId); targetType = "child" }
            if ($R.Kind -eq "dep") { $Row["@odata.type"] = "#microsoft.graph.mobileAppDependency"; $Row.dependencyType = $R.Type } else { $Row["@odata.type"] = "#microsoft.graph.mobileAppSupersedence"; $Row.supersedenceType = $R.Type }
            [void]$Rows.Add([pscustomobject]$Row)
        }
        foreach ($Other in @($Apps | Where-Object { $_.id -ne $Id })) {
            foreach ($R in @(& $Own $Other | Where-Object { $_.TargetId -eq $Id })) {
                $Row = [ordered]@{ id = "$($Other.id)`_$Id"; sourceId = $Other.id; targetId = $Other.id; targetDisplayName = $Other.displayName; targetType = "parent" }
                if ($R.Kind -eq "dep") { $Row["@odata.type"] = "#microsoft.graph.mobileAppDependency"; $Row.dependencyType = $R.Type } else { $Row["@odata.type"] = "#microsoft.graph.mobileAppSupersedence"; $Row.supersedenceType = $R.Type }
                [void]$Rows.Add([pscustomobject]$Row)
            }
        }
        return [pscustomobject]@{ value = @($Rows) }
    }
    if ($Method -eq "POST" -and $Tail -eq "updateRelationships") {
        $New = @($Body.relationships)
        foreach ($R in $New) { if (-not ($Apps | Where-Object id -eq $R.targetId)) { throw "fake Graph: (400) Bad Request: target app $($R.targetId) does not exist" } }
        $App.dependencies = @($New | Where-Object { [string]$_.'@odata.type' -like "*mobileAppDependency" } | ForEach-Object { [pscustomobject]@{ targetId = $_.targetId; dependencyType = $_.dependencyType } })
        $App.supersedence = @($New | Where-Object { [string]$_.'@odata.type' -like "*mobileAppSupersedence" } | ForEach-Object { [pscustomobject]@{ targetId = $_.targetId; supersedenceType = $_.supersedenceType } })
        Write-Store $Apps
        return
    }
    if ($Method -eq "DELETE" -and -not $Tail) {
        if (@(& $Own $App).Count -gt 0) { throw "fake Graph: (400) BadRequest: Cannot delete this app as it is the parent of another app: $(@(& $Own $App)[0].TargetId)" }
        $Pointing = @($Apps | Where-Object { $_.id -ne $Id -and @(& $Own $_ | Where-Object { $_.TargetId -eq $Id }).Count -gt 0 })
        if ($Pointing.Count) { throw "fake Graph: (400) BadRequest: Cannot delete this app as it is the child of another app: $($Pointing[0].id)" }
        Write-Store @($Apps | Where-Object { $_.id -ne $Id })
        return
    }
    throw "fake Graph: $Method $Path is not supported"
}
Export-ModuleMember -Function Invoke-FakeIntuneGraph, Get-IntuneWin32App, Remove-IntuneWin32App, New-IntuneWin32AppPackage, New-IntuneWin32AppDetectionRuleScript, New-IntuneWin32AppDetectionRuleFile,
    New-IntuneWin32AppRequirementRule, New-IntuneWin32AppDependency, Add-IntuneWin32AppDependency, Get-IntuneWin32AppDependency,
    New-IntuneWin32AppSupersedence, Add-IntuneWin32AppSupersedence, Get-IntuneWin32AppSupersedence, Remove-IntuneWin32AppSupersedence,
    Add-IntuneWin32AppAssignmentAllUsers, Add-IntuneWin32AppAssignmentAllDevices, Add-IntuneWin32AppAssignmentGroup, Get-IntuneWin32AppAssignment,
    Add-IntuneWin32App, Update-IntuneWin32AppPackageFile, Set-IntuneWin32App
