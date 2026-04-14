#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-IntuneAuditReport-ConfigProfileChanges.ps1
# Description  : Retrieves all Configuration Profile changes from the Intune
#                audit log for a specified date range.
#
#                Captures the full lifecycle of configuration profile events:
#                  - Create          : Profile created
#                  - Delete          : Profile deleted
#                  - Assign          : Profile assigned to a group
#                  - RemoveReference : Profile removed from a group
#                  - Patch           : Profile settings modified
#                  - SetReference    : Assignment relationship added/updated
#
#                DIFFERENCE FROM Script 1 (GroupAssignments):
#                  Script 1 focuses on assignment changes (who assigned what
#                  to which group). This script focuses on the full profile
#                  lifecycle including settings changes — the OldValue and
#                  NewValue columns show what settings changed before and
#                  after a Patch operation, making it useful for configuration
#                  drift detection and change management auditing.
#
#                ACTOR IDENTITY RESOLUTION — TWO SOURCES:
#                  Source 1 — actor object fields (priority order):
#                    userPrincipalName    → human admin via Intune portal
#                    servicePrincipalName → automated service action
#                    applicationDisplayName → app-based action
#                    userId               → GUID fallback
#
#                  Source 2 — modifiedProperties fallback:
#                    When actor fields are empty (service-triggered), identity
#                    is extracted from modifiedProperties UserPrincipalName.
#
#                429 THROTTLING PROTECTION:
#                  Pagination reads the Retry-After header from HTTP 429
#                  responses and waits before retrying. Up to $MaxRetries
#                  retries per page with random jitter.
#
#                OS PLATFORM:
#                  Extracted from modifiedProperties (OperatingSystem field)
#                  or parsed from activityType string as a fallback.
#
#                HOW IT WORKS:
#                  Step 1 — Authenticate to Microsoft Graph API
#                  Step 2 — Pull all audit events in the date range filtered
#                           server-side by:
#                             category eq 'DeviceConfiguration'
#                             activityDateTime ge {StartDate}
#                             activityDateTime le {EndDate}
#                           429 retry with Retry-After backoff built in.
#                  Step 3 — Filter client-side for all lifecycle operations:
#                             Create / Delete / Assign / Patch /
#                             SetReference / RemoveReference
#                  Step 4 — Shape each event into a clean CSV row.
#                           OldValue and NewValue columns capture what
#                           changed — most useful for Patch (settings modified)
#                           events.
#                  Step 5 — Export CSV and log to $PSScriptRoot
#
#                CSV COLUMNS:
#                  EventDateTime, OperationType, ActionLabel,
#                  ProfileName, ProfileType, OSPlatform, ComponentName,
#                  ChangedBy, ChangedBy_Type, ChangedBy_Source,
#                  ChangedBy_IPAddress, ChangedBy_AppName,
#                  ActivityResult, ActivityType,
#                  OldValue, NewValue, AuditEventID
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  IntuneAudit_ConfigProfileChanges_[StartDate]_[EndDate]_[ts].csv
#                  IntuneAudit_ConfigProfileChanges_[StartDate]_[EndDate]_[ts].log
#
# Author       : Sethu Kumar B
# Version      : 1.0
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
#                        Full profile lifecycle: Create, Delete, Assign,
#                        RemoveReference, Patch, SetReference.
#                        Dual-source actor resolution. 429 Retry-After backoff.
#                        OldValue/NewValue for settings change detection.
#                        OSPlatform, ChangedBy_Type, ChangedBy_Source columns.
# ==============================================================================


#region ─── CONFIGURATION ─── Edit these values before running ────────────────

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ── DATE RANGE ────────────────────────────────────────────────────────────────
# Format : YYYY-MM-DD
# Maximum lookback supported by Intune audit logs: 2 years.
# ─────────────────────────────────────────────────────────────────────────────
$StartDate = "2026-03-31"   # inclusive — from 00:00:00 UTC on this date
$EndDate   = "2026-04-10"   # inclusive — to 23:59:59 UTC on this date

# ── OUTPUT PATH ───────────────────────────────────────────────────────────────
$OutputFolder = $PSScriptRoot

# ── THROTTLE SETTINGS ─────────────────────────────────────────────────────────
# Maximum retries per page when Graph API returns HTTP 429.
# The script reads Retry-After header and waits before retrying.
# ─────────────────────────────────────────────────────────────────────────────
$MaxRetries = 3

#endregion ────────────────────────────────────────────────────────────────────


#region ─── FUNCTIONS ─────────────────────────────────────────────────────────

function Write-Log {
    param (
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","SECTION","BLANK")]
        [string]$Level = "INFO"
    )
    $ColourMap = @{ INFO="Gray"; SUCCESS="Green"; WARN="Yellow"; ERROR="Red"; SECTION="Cyan"; BLANK="Gray" }
    $PrefixMap = @{ INFO="[INFO]   "; SUCCESS="[OK]     "; WARN="[WARN]   "; ERROR="[ERROR]  "; SECTION="[=======]"; BLANK="         " }
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
    catch { Write-Log "Authentication failed: $_" -Level ERROR; exit 1 }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Invoke-GraphGetAllPages
# Purpose  : Follows all @odata.nextLink pages and returns a flat array.
#            Built-in 429 retry with Retry-After header backoff + jitter.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-GraphGetAllPages {
    param (
        [string]$InitialUri,
        [string]$AccessToken,
        [string]$Label,
        [int]$MaxRetries = 3
    )
    $Headers    = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $AllRecords = [System.Collections.Generic.List[PSObject]]::new()
    $Uri        = $InitialUri
    $Page       = 0
    $Total      = 0

    Write-Log "Querying Graph API: $Label" -Level INFO

    do {
        $Page++
        $Attempt = 0
        $Success = $false

        do {
            $Attempt++
            try {
                $r      = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
                $Count  = $r.value.Count
                $Total += $Count
                Write-Log "  Page $Page — $Count events  (running total: $Total)" -Level INFO
                foreach ($rec in $r.value) { $AllRecords.Add($rec) }
                $Uri     = $r.'@odata.nextLink'
                $Success = $true
            }
            catch {
                $Code = $_.Exception.Response.StatusCode.value__
                if ($Code -eq 429 -and $Attempt -lt $MaxRetries) {
                    $RetryAfter = 30
                    try { $RetryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch { }
                    $Jitter = Get-Random -Minimum 1 -Maximum 5
                    $Wait   = $RetryAfter + $Jitter
                    Write-Log "  Page $Page — HTTP 429. Waiting ${Wait}s (Retry-After: ${RetryAfter}s). Retry $Attempt/$MaxRetries..." -Level WARN
                    Start-Sleep -Seconds $Wait
                }
                else {
                    Write-Log "  Page $Page failed — HTTP $Code (attempt $Attempt/$MaxRetries)" -Level ERROR
                    $Uri     = $null
                    $Success = $true
                }
            }
        } while (-not $Success -and $Attempt -lt $MaxRetries)

    } while ($Uri)

    Write-Log "Completed — $Total total events across $Page page(s)." -Level SUCCESS
    return $AllRecords.ToArray()
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Resolve-ActorIdentity
# Purpose  : Resolves the best available identity from the audit event.
#
#            TWO SOURCES checked:
#            Source 1 — actor object (UPN → SPN → AppName → UserId)
#            Source 2 — modifiedProperties fallback (UserPrincipalName)
#
#            Returns [PSCustomObject]:
#              Identity — best resolved name / UPN / GUID
#              Type     — User / Service Principal / Application / Unknown
#              Source   — where identity was resolved from
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-ActorIdentity {
    param (
        [PSObject]$Actor,
        [array]$ModifiedProperties
    )

    if ($Actor) {
        if (-not [string]::IsNullOrWhiteSpace($Actor.userPrincipalName)) {
            return [PSCustomObject]@{ Identity = $Actor.userPrincipalName;      Type = "User";              Source = "Actor (UPN)" }
        }
        if (-not [string]::IsNullOrWhiteSpace($Actor.servicePrincipalName)) {
            return [PSCustomObject]@{ Identity = $Actor.servicePrincipalName;   Type = "Service Principal"; Source = "Actor (Service Principal)" }
        }
        if (-not [string]::IsNullOrWhiteSpace($Actor.applicationDisplayName)) {
            return [PSCustomObject]@{ Identity = $Actor.applicationDisplayName; Type = "Application";       Source = "Actor (Application)" }
        }
    }

    # Fallback — modifiedProperties
    if ($ModifiedProperties -and $ModifiedProperties.Count -gt 0) {
        foreach ($PropName in @("UserPrincipalName","EnrolledByUserPrincipalName")) {
            $prop = $ModifiedProperties | Where-Object { $_.displayName -eq $PropName } | Select-Object -First 1
            if ($prop) {
                $val = if ($prop.newValue) { $prop.newValue } else { $prop.oldValue }
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    return [PSCustomObject]@{ Identity = $val; Type = "User"; Source = "ModifiedProperties ($PropName)" }
                }
            }
        }
    }

    if ($Actor -and -not [string]::IsNullOrWhiteSpace($Actor.userId)) {
        return [PSCustomObject]@{ Identity = $Actor.userId + " (User ID — UPN not available)"; Type = "User (ID only)"; Source = "Actor (User ID)" }
    }

    return [PSCustomObject]@{ Identity = "Unknown — Intune service"; Type = "Service"; Source = "Not available" }
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
            $osProp = $Resource.modifiedProperties |
                      Where-Object { $_.displayName -eq "OperatingSystem" } |
                      Select-Object -First 1
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

    if (-not [string]::IsNullOrWhiteSpace($Event.displayName)) {
        foreach ($os in @("Windows","macOS","iOS","Android","Linux","ChromeOS")) {
            if ($Event.displayName -match $os) { return $os }
        }
    }

    return "N/A"
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-ActionLabel
# Purpose  : Maps activityOperationType to a clear human-readable label.
#
#            Full lifecycle:
#              Create          → PROFILE CREATED
#              Delete          → PROFILE DELETED
#              Assign          → ASSIGNED TO GROUP
#              RemoveReference → REMOVED FROM GROUP
#              Patch           → PROFILE SETTINGS MODIFIED
#              SetReference    → ASSIGNMENT RELATIONSHIP ADDED
# ─────────────────────────────────────────────────────────────────────────────
function Get-ActionLabel {
    param ([string]$OperationType)
    switch ($OperationType) {
        "Create"          { return "PROFILE CREATED" }
        "Delete"          { return "PROFILE DELETED" }
        "Assign"          { return "ASSIGNED TO GROUP" }
        "RemoveReference" { return "REMOVED FROM GROUP" }
        "Patch"           { return "PROFILE SETTINGS MODIFIED" }
        "SetReference"    { return "ASSIGNMENT RELATIONSHIP ADDED" }
        default           { return $OperationType.ToUpper() }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-ModifiedPropertyValues
# Purpose  : Extracts all old/new values from modifiedProperties array.
#            Pipe-separated for readability in the CSV.
#            For Patch events these values show exactly what setting changed.
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
# Purpose  : Shapes a raw audit event into a clean CSV output row.
#
#            OldValue / NewValue are especially important for Patch events —
#            they show exactly which profile settings were changed and what
#            the before/after values were. This enables configuration drift
#            detection without needing to compare snapshots manually.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-AuditRow {
    param ([PSObject]$Event)

    # ── Resource ──────────────────────────────────────────────────────────────
    $Resource    = if ($Event.resources -and $Event.resources.Count -gt 0) { $Event.resources[0] } else { $null }
    $ProfileName = if ($Resource -and -not [string]::IsNullOrWhiteSpace($Resource.displayName)) {
                       $Resource.displayName
                   } else { $Event.displayName }
    $ProfileType = if ($Resource -and $Resource.auditResourceType) {
                       $Resource.auditResourceType
                   } else { $Event.componentName }

    # ── Modified properties ───────────────────────────────────────────────────
    $ModProps = if ($Resource -and $Resource.modifiedProperties) { $Resource.modifiedProperties } else { @() }

    # ── Resolve actor ─────────────────────────────────────────────────────────
    $Resolved = Resolve-ActorIdentity -Actor $Event.actor -ModifiedProperties $ModProps

    # ── OS Platform ───────────────────────────────────────────────────────────
    $OSPlatform = Resolve-OSPlatform -Event $Event

    # ── Old/New values ────────────────────────────────────────────────────────
    # For Patch events these show what settings were changed before and after
    $OldValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "old"
    $NewValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "new"

    [PSCustomObject]@{
        EventDateTime        = Format-AuditDateTime $Event.activityDateTime
        OperationType        = $Event.activityOperationType
        ActionLabel          = Get-ActionLabel -OperationType $Event.activityOperationType
        ProfileName          = $ProfileName
        ProfileType          = $ProfileType
        OSPlatform           = $OSPlatform
        ComponentName        = $Event.componentName
        ChangedBy            = $Resolved.Identity
        ChangedBy_Type       = $Resolved.Type
        ChangedBy_Source     = $Resolved.Source
        ChangedBy_IPAddress  = if ($Event.actor.ipAddress) { $Event.actor.ipAddress } else { "N/A" }
        ChangedBy_AppName    = if ($Event.actor.applicationDisplayName) { $Event.actor.applicationDisplayName } else { "N/A" }
        ActivityResult       = $Event.activityResult
        ActivityType         = $Event.activityType
        OldValue             = $OldValue
        NewValue             = $NewValue
        AuditEventID         = $Event.id
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
    Write-Host "[ERROR] Invalid date format. Use YYYY-MM-DD." -ForegroundColor Red; exit 1
}
if ($StartDT -gt $EndDT) {
    Write-Host "[ERROR] StartDate cannot be after EndDate." -ForegroundColor Red; exit 1
}

$StartISO = $StartDT.ToString("yyyy-MM-ddT00:00:00Z")
$EndISO   = $EndDT.ToString("yyyy-MM-ddT23:59:59Z")

# ── Initialise output paths ───────────────────────────────────────────────────
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$DateLabel      = "${StartDate}_to_${EndDate}"
$OutputFile     = Join-Path $OutputFolder "IntuneAudit_ConfigProfileChanges_${DateLabel}_${Timestamp}.csv"
$script:LogFile = Join-Path $OutputFolder "IntuneAudit_ConfigProfileChanges_${DateLabel}_${Timestamp}.log"

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Get-IntuneAuditReport-ConfigProfileChanges`r`nStarted: $(Get-Date)`r`nDate Range: $StartDate to $EndDate`r`n`r`n",
        [System.Text.Encoding]::UTF8)
}
catch { $script:LogFile = $null }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Intune Audit — Configuration Profile Changes                  " -ForegroundColor Cyan
Write-Host "  Sethu Kumar B  |  READ ONLY                                   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Date range   : $StartDate  →  $EndDate"                             -Level INFO
Write-Log "Category     : DeviceConfiguration"                                  -Level INFO
Write-Log "Operations   : Create, Delete, Assign, Patch, SetReference, RemoveReference" -Level INFO
Write-Log "Max retries  : $MaxRetries (429 throttle protection)"                -Level INFO
Write-Log "Output CSV   : $OutputFile"                                          -Level INFO
Write-Log "Log file     : $($script:LogFile)"                                   -Level INFO
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
Write-Log "Server-side filter : category = DeviceConfiguration"             -Level INFO
Write-Log "Server-side filter : activityDateTime $StartDate → $EndDate"     -Level INFO
Write-Log "Throttle protection: 429 Retry-After backoff active"              -Level INFO
Write-Log "Note               : Operation type filtered client-side"          -Level INFO
Write-Log "" -Level BLANK

$FilterStr     = "category eq 'DeviceConfiguration' and activityDateTime ge $StartISO and activityDateTime le $EndISO"
$EncodedFilter = [Uri]::EscapeDataString($FilterStr)
$AuditUri      = "https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?`$filter=$EncodedFilter&`$top=100"

$RawEvents = Invoke-GraphGetAllPages -InitialUri $AuditUri -AccessToken $Token `
             -Label "DeviceConfiguration audit events ($StartDate to $EndDate)" `
             -MaxRetries $MaxRetries

Write-Log "" -Level BLANK
Write-Log "Total DeviceConfiguration events in date range: $($RawEvents.Count)" -Level INFO

# ── STEP 3: Filter for full lifecycle operations ──────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 — Filtering for Full Lifecycle Operations" -Level INFO
Write-Log "==========================================================" -Level SECTION

$TargetOps      = @("Create", "Delete", "Assign", "RemoveReference", "Patch", "SetReference")
$FilteredEvents = @($RawEvents | Where-Object { $TargetOps -contains $_.activityOperationType })

Write-Log "Events matching lifecycle operations : $($FilteredEvents.Count)" `
    -Level $(if ($FilteredEvents.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK

foreach ($Op in $TargetOps) {
    $OpCount = @($FilteredEvents | Where-Object { $_.activityOperationType -eq $Op }).Count
    Write-Log ("  {0,-35} : {1}" -f (Get-ActionLabel -OperationType $Op), $OpCount) -Level INFO
}
Write-Log "" -Level BLANK

if ($FilteredEvents.Count -eq 0) {
    Write-Log "No config profile events found in the specified date range." -Level WARN
    Write-Log "Verify the date range and that profile changes occurred." -Level WARN
    Write-Log "" -Level BLANK
}

# ── STEP 4: Shape into CSV rows ───────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 — Shaping Records into CSV Rows" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Results = [System.Collections.Generic.List[PSObject]]::new()
foreach ($Event in $FilteredEvents) {
    $Results.Add((ConvertTo-AuditRow -Event $Event))
}
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
        Write-Log "  Path : $OutputFile" -Level INFO
        Write-Log "  Rows : $($Results.Count)  |  Size: $SizeMB MB" -Level INFO
    }
    catch { Write-Log "CSV export failed: $_" -Level ERROR; exit 1 }
}
else { Write-Log "No rows to export — CSV not created." -Level WARN }

# ── Summary ───────────────────────────────────────────────────────────────────
$CreatedCount   = @($Results | Where-Object { $_.OperationType -eq "Create" }).Count
$DeletedCount   = @($Results | Where-Object { $_.OperationType -eq "Delete" }).Count
$AssignedCount  = @($Results | Where-Object { $_.OperationType -eq "Assign" }).Count
$RemovedCount   = @($Results | Where-Object { $_.OperationType -eq "RemoveReference" }).Count
$ModifiedCount  = @($Results | Where-Object { $_.OperationType -eq "Patch" }).Count
$SetRefCount    = @($Results | Where-Object { $_.OperationType -eq "SetReference" }).Count
$UserChanges    = @($Results | Where-Object { $_.ChangedBy_Type -eq "User" }).Count
$SvcChanges     = @($Results | Where-Object { $_.ChangedBy_Type -notin @("User","User (ID only)") }).Count
$OSBreakdown    = $Results | Where-Object { $_.OSPlatform -ne "N/A" } |
                  Group-Object OSPlatform | Sort-Object Count -Descending
$UniqueActors   = @($Results | Where-Object { $_.ChangedBy -notlike "Unknown*" } |
                    Select-Object -ExpandProperty ChangedBy -Unique)
$UniqueProfiles = @($Results | Where-Object { $_.ProfileName -ne "N/A" } |
                    Select-Object -ExpandProperty ProfileName -Unique)

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
Write-Log "  PROFILE SETTINGS MODIFIED  : $ModifiedCount"                    -Level $(if ($ModifiedCount -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  ASSIGNMENT REL. ADDED      : $SetRefCount"                      -Level $(if ($SetRefCount   -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "" -Level BLANK
Write-Log "  ── OS Platform Breakdown ────────────────────────────────" -Level SECTION
if ($OSBreakdown) {
    foreach ($os in $OSBreakdown) {
        Write-Log ("  {0,-20} : {1}" -f $os.Name, $os.Count) -Level INFO
    }
} else {
    Write-Log "  No OS platform data available in this date range." -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Actor Breakdown ──────────────────────────────────────" -Level SECTION
Write-Log "  Changes by users           : $UserChanges"                      -Level INFO
Write-Log "  Changes by services / apps : $SvcChanges"                       -Level INFO
Write-Log "" -Level BLANK
Write-Log "  ── Profiles Affected ────────────────────────────────────" -Level SECTION
Write-Log "  Unique profiles            : $($UniqueProfiles.Count)"          -Level INFO
foreach ($Profile in ($UniqueProfiles | Select-Object -First 20)) {
    Write-Log "    → $Profile" -Level INFO
}
if ($UniqueProfiles.Count -gt 20) {
    Write-Log "    ... and $($UniqueProfiles.Count - 20) more — see CSV for full list" -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Who Made Changes ─────────────────────────────────────" -Level SECTION
Write-Log "  Unique actors              : $($UniqueActors.Count)"            -Level INFO
foreach ($Actor in $UniqueActors) {
    Write-Log "    → $Actor" -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Settings Change Detection ────────────────────────────" -Level SECTION
Write-Log "  Profile settings modified  : $ModifiedCount events"             -Level $(if ($ModifiedCount -gt 0) {"WARN"} else {"INFO"})
Write-Log "  Review OldValue/NewValue columns in the CSV to see exactly"     -Level INFO
Write-Log "  which settings changed and what the before/after values were."  -Level INFO
Write-Log "" -Level BLANK
Write-Log "  Output CSV  : $OutputFile"        -Level INFO
Write-Log "  Log file    : $($script:LogFile)" -Level INFO
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

#endregion ────────────────────────────────────────────────────────────────────