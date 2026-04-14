#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-IntuneAuditReport-GroupAssignments.ps1
# Description  : Retrieves all Configuration Profile changes from the Intune
#                audit log for a specified date range.
#
#                Captures the full lifecycle of configuration profile events:
#                  - Create          : Profile created
#                  - Delete          : Profile deleted
#                  - Assign          : Profile assigned to a group
#                  - RemoveReference : Profile removed from a group
#                  - Patch           : Profile settings or assignment modified
#                  - SetReference    : Assignment relationship added/updated
#
#                HOW IT WORKS:
#                  Step 1 — Authenticate to Microsoft Graph API
#                  Step 2 — Pull all audit events in the date range filtered
#                           server-side by:
#                             category eq 'DeviceConfiguration'
#                             activityDateTime ge {StartDate}
#                             activityDateTime le {EndDate}
#                  Step 3 — Filter client-side for all relevant operations:
#                             Create / Delete / Assign / Patch /
#                             SetReference / RemoveReference
#                  Step 4 — Shape each event into a clean CSV row
#                  Step 5 — Export CSV and log to $PSScriptRoot
#
#                WHY CLIENT-SIDE FILTER FOR OPERATION TYPE:
#                  The Graph API does not reliably support combining multiple
#                  activityOperationType values in a single $filter expression.
#                  Server-side filter is applied on category + activityDateTime
#                  (the most selective fields). Operation type is then filtered
#                  client-side from the already-reduced result set.
#
#                CSV COLUMNS:
#                  EventDateTime, OperationType, ActionLabel,
#                  ProfileName, ProfileType, ComponentName,
#                  ChangedBy_UPN, ChangedBy_DisplayName,
#                  ChangedBy_IPAddress, ChangedBy_AppName,
#                  ActivityResult, ActivityType,
#                  OldValue, NewValue, AuditEventID
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  IntuneAudit_GroupAssignments_[StartDate]_[EndDate]_[ts].csv
#                  IntuneAudit_GroupAssignments_[StartDate]_[EndDate]_[ts].log
#
# Author       : Sethu Kumar B
# Version      : 1.2
# Created Date : 2026-04-10
# Last Modified: 2026-04-10
#
# Requirements :
#   - Azure AD App Registration (READ-ONLY recommended)
#   - Graph API Application Permissions (admin consent granted):
#       DeviceManagementConfiguration.Read.All  — read config profile audit events
#   - PowerShell 5.1 or later
#
# Change Log   :
#   v1.0 - 2026-04-10 - Sethu Kumar B - Initial release.
#                        Date range configurable in config block.
#                        Captures Assign, Patch, SetReference, RemoveReference.
#                        Server-side filter on category + date range.
#                        Client-side filter on operation type.
#   v1.1 - 2026-04-10 - Sethu Kumar B - Expanded to full profile lifecycle.
#   v1.2 - 2026-04-10 - Sethu Kumar B - Fixed actor identity resolution with
#                        Resolve-ActorIdentity (UPN/SPN/App/UserId priority).
#                        Added OSPlatform and ChangedBy_Type columns.
# ==============================================================================


#region ─── CONFIGURATION ─── Edit these values before running ────────────────

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ── DATE RANGE ────────────────────────────────────────────────────────────────
# Define the start and end date for the audit log query.
# Format : YYYY-MM-DD
# Example: To query March 2026 → StartDate = "2026-03-01", EndDate = "2026-03-31"
# The script converts these to ISO 8601 UTC timestamps automatically.
# Maximum lookback supported by Intune audit logs: 2 years.
# ─────────────────────────────────────────────────────────────────────────────
$StartDate = "2026-03-01"   # inclusive — from 00:00:00 UTC on this date
$EndDate   = "2026-04-10"   # inclusive — to 23:59:59 UTC on this date

# ── OUTPUT PATH ───────────────────────────────────────────────────────────────
# Default: saves CSV and log to the same folder as this script ($PSScriptRoot).
# ─────────────────────────────────────────────────────────────────────────────
$OutputFolder = $PSScriptRoot

#endregion ────────────────────────────────────────────────────────────────────


#region ─── FUNCTIONS ─────────────────────────────────────────────────────────

function Write-Log {
    param (
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","SECTION","BLANK")]
        [string]$Level = "INFO"
    )
    $ColourMap = @{
        INFO    = "Gray";  SUCCESS = "Green"; WARN  = "Yellow"
        ERROR   = "Red";   SECTION = "Cyan";  BLANK = "Gray"
    }
    $PrefixMap = @{
        INFO    = "[INFO]   "; SUCCESS = "[OK]     "; WARN  = "[WARN]   "
        ERROR   = "[ERROR]  "; SECTION = "[=======]"; BLANK = "         "
    }
    $t = Get-Date -Format "HH:mm:ss"
    if     ($Level -eq "BLANK")   { Write-Host "" }
    elseif ($Level -eq "SECTION") { Write-Host "`n$Message" -ForegroundColor Cyan }
    else   { Write-Host "[$t] $($PrefixMap[$Level]) $Message" -ForegroundColor $ColourMap[$Level] }
    if ($script:LogFile) {
        try {
            Add-Content -Path $script:LogFile `
                -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($PrefixMap[$Level]) $Message" `
                -Encoding UTF8
        } catch { }
    }
}


function Get-GraphAccessToken {
    param ([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $Body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    try {
        Write-Log "Requesting access token from Microsoft Identity Platform..." -Level INFO
        $r = Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
             -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
             -Body $Body -ErrorAction Stop
        Write-Log "Access token acquired successfully." -Level SUCCESS
        return $r.access_token
    }
    catch {
        Write-Log "Authentication failed: $_" -Level ERROR
        exit 1
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Invoke-GraphGetAllPages
# Purpose  : Follows all @odata.nextLink pages and returns a flat array.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-GraphGetAllPages {
    param (
        [string]$InitialUri,
        [string]$AccessToken,
        [string]$Label
    )
    $Headers    = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $AllRecords = [System.Collections.Generic.List[PSObject]]::new()
    $Uri        = $InitialUri
    $Page       = 0
    $Total      = 0

    Write-Log "Querying Graph API: $Label" -Level INFO

    do {
        $Page++
        try {
            $r      = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
            $Count  = $r.value.Count
            $Total += $Count
            Write-Log "  Page $Page — $Count events  (running total: $Total)" -Level INFO
            foreach ($rec in $r.value) { $AllRecords.Add($rec) }
            $Uri = $r.'@odata.nextLink'
        }
        catch {
            $Code = $_.Exception.Response.StatusCode.value__
            Write-Log "  Page $Page failed — HTTP $Code : $_" -Level ERROR
            $Uri = $null
        }
    } while ($Uri)

    Write-Log "Completed — $Total total events across $Page page(s)." -Level SUCCESS
    return $AllRecords.ToArray()
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Resolve-ActorIdentity
# Purpose  : Resolves the best available identity from the audit actor object.
#            Priority: UPN → ServicePrincipal → AppDisplayName → UserId → Unknown
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-ActorIdentity {
    param ([PSObject]$Actor)
    if (-not $Actor) { return [PSCustomObject]@{ Identity = "Unknown"; Type = "Unknown" } }
    if (-not [string]::IsNullOrWhiteSpace($Actor.userPrincipalName)) {
        return [PSCustomObject]@{ Identity = $Actor.userPrincipalName; Type = "User" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Actor.servicePrincipalName)) {
        return [PSCustomObject]@{ Identity = $Actor.servicePrincipalName; Type = "Service Principal" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Actor.applicationDisplayName)) {
        return [PSCustomObject]@{ Identity = $Actor.applicationDisplayName; Type = "Application" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Actor.userId)) {
        return [PSCustomObject]@{ Identity = $Actor.userId + " (User ID — UPN not available)"; Type = "User (ID only)" }
    }
    return [PSCustomObject]@{ Identity = "Unknown"; Type = "Unknown" }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Resolve-OSPlatform
# Purpose  : Extracts OS platform from modifiedProperties or activityType.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-OSPlatform {
    param ([PSObject]$Event)
    if ($Event.resources -and $Event.resources.Count -gt 0) {
        $Resource = $Event.resources[0]
        if ($Resource.modifiedProperties) {
            $osProp = $Resource.modifiedProperties | Where-Object { $_.displayName -eq "OperatingSystem" } | Select-Object -First 1
            if ($osProp) {
                $val = if ($osProp.newValue) { $osProp.newValue } else { $osProp.oldValue }
                if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Event.activityType)) {
        foreach ($os in @("Windows","macOS","iOS","Android","Linux","ChromeOS")) {
            if ($Event.activityType -match $os) { return $os }
        }
    }
    return "N/A"
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-ActionLabel
# Purpose  : Maps activityOperationType to a clear human-readable label
#            for the ActionLabel column in the CSV output.
#
#            Full lifecycle covered:
#              Create          → PROFILE CREATED
#              Delete          → PROFILE DELETED
#              Assign          → ASSIGNED TO GROUP
#              RemoveReference → REMOVED FROM GROUP
#              Patch           → PROFILE MODIFIED
#              SetReference    → ASSIGNMENT RELATIONSHIP ADDED
# ─────────────────────────────────────────────────────────────────────────────
function Get-ActionLabel {
    param ([string]$OperationType)
    switch ($OperationType) {
        "Create"          { return "PROFILE CREATED" }
        "Delete"          { return "PROFILE DELETED" }
        "Assign"          { return "ASSIGNED TO GROUP" }
        "RemoveReference" { return "REMOVED FROM GROUP" }
        "Patch"           { return "PROFILE MODIFIED" }
        "SetReference"    { return "ASSIGNMENT RELATIONSHIP ADDED" }
        default           { return $OperationType.ToUpper() }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-ModifiedPropertyValues
# Purpose  : Extracts all old and new values from modifiedProperties array
#            inside the audit event resource. Concatenates multiple properties
#            with a pipe separator for readability in the CSV.
# ─────────────────────────────────────────────────────────────────────────────
function Get-ModifiedPropertyValues {
    param ([array]$ModifiedProperties, [string]$ValueType)
    if (-not $ModifiedProperties -or $ModifiedProperties.Count -eq 0) { return "" }
    if ($ValueType -eq "old") {
        $vals = $ModifiedProperties |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.oldValue) } |
                ForEach-Object { "$($_.displayName): $($_.oldValue)" }
    }
    else {
        $vals = $ModifiedProperties |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.newValue) } |
                ForEach-Object { "$($_.displayName): $($_.newValue)" }
    }
    return ($vals -join " | ")
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Format-AuditDateTime
# Purpose  : Formats ISO 8601 activityDateTime to readable local time string.
# ─────────────────────────────────────────────────────────────────────────────
function Format-AuditDateTime {
    param ([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString)) { return "N/A" }
    try {
        $dt = [datetime]::Parse($DateString, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch { return $DateString }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : ConvertTo-AuditRow
# Purpose  : Shapes a raw audit event object into a clean CSV output row.
#            Extracts actor (who), resource (what), operation (action type),
#            and modified properties (old/new values where available).
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-AuditRow {
    param ([PSObject]$Event)

    # ── Actor (who made the change) ───────────────────────────────────────────
    $Actor          = $Event.actor
    $ChangedBy_UPN  = if ($Actor.userPrincipalName)      { $Actor.userPrincipalName }      else { "N/A" }
    $ChangedBy_Name = if ($Actor.applicationDisplayName) { $Actor.applicationDisplayName } else { "N/A" }
    $ChangedBy_IP   = if ($Actor.ipAddress)              { $Actor.ipAddress }              else { "N/A" }
    $ChangedBy_App  = if ($Actor.applicationDisplayName) { $Actor.applicationDisplayName } else { "N/A" }

    # Fall back to service principal if UPN is empty (automated/service action)
    if ($ChangedBy_UPN -eq "N/A" -and -not [string]::IsNullOrWhiteSpace($Actor.servicePrincipalName)) {
        $ChangedBy_UPN = $Actor.servicePrincipalName + " (Service Principal)"
    }

    # ── Resource (what was changed) ───────────────────────────────────────────
    $Resource    = if ($Event.resources -and $Event.resources.Count -gt 0) { $Event.resources[0] } else { $null }
    $ProfileName = if ($Resource -and -not [string]::IsNullOrWhiteSpace($Resource.displayName)) {
                       $Resource.displayName
                   } else { $Event.displayName }
    $ProfileType = if ($Resource -and $Resource.auditResourceType) {
                       $Resource.auditResourceType
                   } else { $Event.componentName }

    # ── Modified properties (old/new values where available) ─────────────────
    $ModProps = if ($Resource -and $Resource.modifiedProperties) { $Resource.modifiedProperties } else { @() }
    $OldValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "old"
    $NewValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "new"

    [PSCustomObject]@{
        EventDateTime         = Format-AuditDateTime $Event.activityDateTime
        OperationType         = $Event.activityOperationType
        ActionLabel           = Get-ActionLabel -OperationType $Event.activityOperationType
        ProfileName           = $ProfileName
        ProfileType           = $ProfileType
        ComponentName         = $Event.componentName
        ChangedBy_UPN         = $ChangedBy_UPN
        ChangedBy_DisplayName = $ChangedBy_Name
        ChangedBy_IPAddress   = $ChangedBy_IP
        ChangedBy_AppName     = $ChangedBy_App
        ActivityResult        = $Event.activityResult
        ActivityType          = $Event.activityType
        OldValue              = $OldValue
        NewValue              = $NewValue
        AuditEventID          = $Event.id
    }
}

#endregion ────────────────────────────────────────────────────────────────────


#region ─── MAIN ──────────────────────────────────────────────────────────────

# ── Validate dates ────────────────────────────────────────────────────────────
try {
    $StartDT = [datetime]::ParseExact($StartDate, "yyyy-MM-dd", $null)
    $EndDT   = [datetime]::ParseExact($EndDate,   "yyyy-MM-dd", $null)
}
catch {
    Write-Host "[ERROR] Invalid date format. Use YYYY-MM-DD for StartDate and EndDate." -ForegroundColor Red
    exit 1
}

if ($StartDT -gt $EndDT) {
    Write-Host "[ERROR] StartDate ($StartDate) cannot be after EndDate ($EndDate)." -ForegroundColor Red
    exit 1
}

# ── Build ISO 8601 timestamps for Graph API filter ───────────────────────────
$StartISO = $StartDT.ToString("yyyy-MM-ddT00:00:00Z")
$EndISO   = $EndDT.ToString("yyyy-MM-ddT23:59:59Z")

# ── Initialise output paths ───────────────────────────────────────────────────
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$DateLabel      = "${StartDate}_to_${EndDate}"
$OutputFile     = Join-Path $OutputFolder "IntuneAudit_GroupAssignments_${DateLabel}_${Timestamp}.csv"
$script:LogFile = Join-Path $OutputFolder "IntuneAudit_GroupAssignments_${DateLabel}_${Timestamp}.log"

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Get-IntuneAuditReport-GroupAssignments`r`nStarted: $(Get-Date)`r`nDate Range: $StartDate to $EndDate`r`n`r`n",
        [System.Text.Encoding]::UTF8)
}
catch { $script:LogFile = $null }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Intune Audit — Configuration Profile Changes & Assignments    " -ForegroundColor Cyan
Write-Host "  Sethu Kumar B  |  READ ONLY                                   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Date range   : $StartDate  →  $EndDate"                    -Level INFO
Write-Log "Category     : DeviceConfiguration"                         -Level INFO
Write-Log "Operations   : Create, Delete, Assign, Patch, SetReference, RemoveReference" -Level INFO
Write-Log "Output CSV   : $OutputFile"                                 -Level INFO
Write-Log "Log file     : $($script:LogFile)"                          -Level INFO
Write-Log "" -Level BLANK

# ── STEP 1: Authenticate ──────────────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 — Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Token = Get-GraphAccessToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret

# ── STEP 2: Pull audit events ─────────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 2 — Pulling Audit Events from Graph API" -Level INFO
Write-Log "==========================================================" -Level SECTION
Write-Log "Server-side filter : category = DeviceConfiguration"          -Level INFO
Write-Log "Server-side filter : activityDateTime $StartDate → $EndDate"  -Level INFO
Write-Log "Note               : Operation type filtered client-side"      -Level INFO
Write-Log "" -Level BLANK

$FilterStr = "category eq 'DeviceConfiguration'" +
             " and activityDateTime ge $StartISO" +
             " and activityDateTime le $EndISO"

$EncodedFilter = [Uri]::EscapeDataString($FilterStr)
$AuditUri      = "https://graph.microsoft.com/v1.0/deviceManagement/auditEvents" +
                 "?`$filter=$EncodedFilter&`$top=100"

$RawEvents = Invoke-GraphGetAllPages -InitialUri $AuditUri -AccessToken $Token `
             -Label "DeviceConfiguration audit events ($StartDate to $EndDate)"

Write-Log "" -Level BLANK
Write-Log "Total DeviceConfiguration events in date range: $($RawEvents.Count)" -Level INFO

# ── STEP 3: Client-side filter for full lifecycle operations ──────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 — Filtering for Full Lifecycle Operations" -Level INFO
Write-Log "==========================================================" -Level SECTION

$TargetOps = @("Create", "Delete", "Assign", "RemoveReference", "Patch", "SetReference")

$FilteredEvents = @($RawEvents | Where-Object {
    $TargetOps -contains $_.activityOperationType
})

Write-Log "Events matching lifecycle operations : $($FilteredEvents.Count)" `
    -Level $(if ($FilteredEvents.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK

foreach ($Op in $TargetOps) {
    $OpCount = @($FilteredEvents | Where-Object { $_.activityOperationType -eq $Op }).Count
    $Label   = Get-ActionLabel -OperationType $Op
    Write-Log ("  {0,-35} : {1}" -f $Label, $OpCount) -Level INFO
}
Write-Log "" -Level BLANK

if ($FilteredEvents.Count -eq 0) {
    Write-Log "No events found in the specified date range." -Level WARN
    Write-Log "Verify the date range and that profile changes occurred." -Level WARN
    Write-Log "" -Level BLANK
}

# ── STEP 4: Shape events into CSV rows ────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 — Shaping Records into CSV Rows" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Results = [System.Collections.Generic.List[PSObject]]::new()

foreach ($Event in $FilteredEvents) {
    $Results.Add((ConvertTo-AuditRow -Event $Event))
}

# Sort by EventDateTime descending — most recent first
$Results = @($Results | Sort-Object EventDateTime -Descending)

Write-Log "Shaped $($Results.Count) rows." -Level SUCCESS
Write-Log "" -Level BLANK

# ── STEP 5: Export CSV ────────────────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 5 — Exporting CSV" -Level INFO
Write-Log "==========================================================" -Level SECTION

if ($Results.Count -gt 0) {
    try {
        $Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
        $SizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
        Write-Log "CSV exported successfully." -Level SUCCESS
        Write-Log "  Path : $OutputFile"       -Level INFO
        Write-Log "  Rows : $($Results.Count)  |  Size: $SizeMB MB" -Level INFO
    }
    catch {
        Write-Log "CSV export failed: $_" -Level ERROR
        exit 1
    }
}
else {
    Write-Log "No rows to export — CSV not created." -Level WARN
}

# ── Summary ───────────────────────────────────────────────────────────────────
$CreatedCount  = @($Results | Where-Object { $_.OperationType -eq "Create" }).Count
$DeletedCount  = @($Results | Where-Object { $_.OperationType -eq "Delete" }).Count
$AssignedCount = @($Results | Where-Object { $_.OperationType -eq "Assign" }).Count
$RemovedCount  = @($Results | Where-Object { $_.OperationType -eq "RemoveReference" }).Count
$ModifiedCount = @($Results | Where-Object { $_.OperationType -eq "Patch" }).Count
$SetRefCount   = @($Results | Where-Object { $_.OperationType -eq "SetReference" }).Count
$UniqueActors  = @($Results | Where-Object { $_.ChangedBy_UPN -ne "N/A" } |
                   Select-Object -ExpandProperty ChangedBy_UPN -Unique)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  COMPLETE — READ ONLY — NO CHANGES MADE                       " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "  Date range queried         : $StartDate  →  $EndDate"          -Level INFO
Write-Log "  Total events pulled        : $($RawEvents.Count)"              -Level INFO
Write-Log "  Lifecycle events found     : $($Results.Count)"                 -Level $(if ($Results.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK
Write-Log "  ── Breakdown by Action ──────────────────────────────────" -Level SECTION
Write-Log "  PROFILE CREATED            : $CreatedCount"                     -Level $(if ($CreatedCount  -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  PROFILE DELETED            : $DeletedCount"                     -Level $(if ($DeletedCount  -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  ASSIGNED TO GROUP          : $AssignedCount"                    -Level $(if ($AssignedCount -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  REMOVED FROM GROUP         : $RemovedCount"                     -Level $(if ($RemovedCount  -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  PROFILE MODIFIED           : $ModifiedCount"                    -Level $(if ($ModifiedCount -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  ASSIGNMENT REL. ADDED      : $SetRefCount"                      -Level $(if ($SetRefCount   -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "" -Level BLANK
Write-Log "  ── Who Made Changes ─────────────────────────────────────" -Level SECTION
Write-Log "  Unique actors              : $($UniqueActors.Count)"            -Level INFO
foreach ($Actor in $UniqueActors) {
    Write-Log "    → $Actor" -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  Output CSV  : $OutputFile"        -Level INFO
Write-Log "  Log file    : $($script:LogFile)" -Level INFO
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

#endregion ────────────────────────────────────────────────────────────────────