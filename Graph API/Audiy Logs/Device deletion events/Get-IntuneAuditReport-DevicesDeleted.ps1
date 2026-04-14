#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-IntuneAuditReport-DevicesDeleted.ps1
# Description  : Retrieves all device deletion events from the Intune audit log
#                for a specified date range.
#
#                Captures device deletion events:
#                  - Delete          : Device record deleted from Intune
#                  - RemoveReference : Device relationship removed (e.g. user
#                                      unassigned, device removed from group)
#
#                ACTOR IDENTITY RESOLUTION — TWO SOURCES:
#                  Source 1 — actor object fields (priority order):
#                    userPrincipalName    → human admin acting via Intune portal
#                    servicePrincipalName → automated service action
#                    applicationDisplayName → app-based action
#                    userId               → GUID fallback
#
#                  Source 2 — modifiedProperties fallback:
#                    For events triggered by the Intune service internally,
#                    actor fields may be empty. The script falls back to
#                    UserPrincipalName or EnrolledByUserPrincipalName from
#                    modifiedProperties where available.
#
#                429 THROTTLING PROTECTION:
#                  Pagination reads the Retry-After header from HTTP 429
#                  responses and waits before retrying. Up to $MaxRetries
#                  retries per page with random jitter to avoid thundering herd.
#
#                OS PLATFORM:
#                  Extracted from modifiedProperties (OperatingSystem field)
#                  or parsed from the activityType string as a fallback.
#
#                HOW IT WORKS:
#                  Step 1 — Authenticate to Microsoft Graph API
#                  Step 2 — Pull all audit events in the date range filtered
#                           server-side by:
#                             category eq 'Device'
#                             activityDateTime ge {StartDate}
#                             activityDateTime le {EndDate}
#                           429 retry with Retry-After backoff built in.
#                  Step 3 — Filter client-side for deletion operations:
#                             Delete / RemoveReference
#                  Step 4 — Shape each event into a clean CSV row
#                  Step 5 — Export CSV and log to $PSScriptRoot
#
#                CSV COLUMNS:
#                  EventDateTime, OperationType, ActionLabel,
#                  DeviceName, DeviceType, OSPlatform,
#                  DeletedBy, DeletedBy_Type, DeletedBy_Source,
#                  DeletedBy_IPAddress, DeletedBy_AppName,
#                  ActivityResult, ActivityType,
#                  OldValue, NewValue, AuditEventID
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  IntuneAudit_DevicesDeleted_[StartDate]_[EndDate]_[ts].csv
#                  IntuneAudit_DevicesDeleted_[StartDate]_[EndDate]_[ts].log
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-04-10
# Last Modified: 2026-04-10
#
# Requirements :
#   - Azure AD App Registration (READ-ONLY recommended)
#   - Graph API Application Permissions (admin consent granted):
#       DeviceManagementManagedDevices.Read.All  — read device audit events
#   - PowerShell 5.1 or later
#
# Change Log   :
#   v1.0 - 2026-04-10 - Sethu Kumar B - Initial release.
#                        Captures Delete and RemoveReference operations.
#                        Dual-source actor resolution (actor fields +
#                        modifiedProperties fallback). 429 Retry-After
#                        backoff built into pagination. OSPlatform column.
#                        DeletedBy_Source column shows identity resolution path.
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
#
#            Source 1 — actor object (priority order):
#              1. userPrincipalName     — human admin via Intune portal
#              2. servicePrincipalName  — automated service
#              3. applicationDisplayName — app-based action
#              4. userId GUID           — last resort name fallback
#
#            Source 2 — modifiedProperties fallback:
#              When actor fields are empty (Intune service triggered),
#              identity is extracted from:
#                UserPrincipalName
#                EnrolledByUserPrincipalName
#
#            Returns [PSCustomObject] with:
#              Identity — best resolved name / UPN / GUID
#              Type     — User / Service Principal / Application / Unknown
#              Source   — where the identity was resolved from
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-ActorIdentity {
    param (
        [PSObject]$Actor,
        [array]$ModifiedProperties
    )

    # Source 1 — actor object
    if ($Actor) {
        if (-not [string]::IsNullOrWhiteSpace($Actor.userPrincipalName)) {
            return [PSCustomObject]@{ Identity = $Actor.userPrincipalName;      Type = "User";               Source = "Actor (UPN)" }
        }
        if (-not [string]::IsNullOrWhiteSpace($Actor.servicePrincipalName)) {
            return [PSCustomObject]@{ Identity = $Actor.servicePrincipalName;   Type = "Service Principal";  Source = "Actor (Service Principal)" }
        }
        if (-not [string]::IsNullOrWhiteSpace($Actor.applicationDisplayName)) {
            return [PSCustomObject]@{ Identity = $Actor.applicationDisplayName; Type = "Application";        Source = "Actor (Application)" }
        }
    }

    # Source 2 — modifiedProperties fallback
    if ($ModifiedProperties -and $ModifiedProperties.Count -gt 0) {
        foreach ($PropName in @("UserPrincipalName","EnrolledByUserPrincipalName")) {
            $prop = $ModifiedProperties | Where-Object { $_.displayName -eq $PropName } | Select-Object -First 1
            if ($prop) {
                $val = if ($prop.oldValue) { $prop.oldValue } else { $prop.newValue }
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    return [PSCustomObject]@{ Identity = $val; Type = "User"; Source = "ModifiedProperties ($PropName)" }
                }
            }
        }
    }

    # Source 1 continued — userId GUID fallback
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
                $val = if ($osProp.oldValue) { $osProp.oldValue } else { $osProp.newValue }
                if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
            }
        }
    }

    # For Delete events oldValue is more likely to be populated
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
# ─────────────────────────────────────────────────────────────────────────────
function Get-ActionLabel {
    param ([string]$OperationType)
    switch ($OperationType) {
        "Delete"          { return "DEVICE DELETED" }
        "RemoveReference" { return "DEVICE RELATIONSHIP REMOVED" }
        default           { return $OperationType.ToUpper() }
    }
}


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
#            For Delete events, oldValue is the important column — it contains
#            the device details that existed before deletion.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-AuditRow {
    param ([PSObject]$Event)

    # ── Resource ──────────────────────────────────────────────────────────────
    $Resource   = if ($Event.resources -and $Event.resources.Count -gt 0) { $Event.resources[0] } else { $null }
    $DeviceName = if ($Resource -and -not [string]::IsNullOrWhiteSpace($Resource.displayName)) {
                      $Resource.displayName
                  } else { $Event.displayName }
    $DeviceType = if ($Resource -and $Resource.auditResourceType) {
                      $Resource.auditResourceType
                  } else { $Event.componentName }

    # ── Modified properties ───────────────────────────────────────────────────
    # For Delete events, oldValue is what mattered — device properties before deletion
    $ModProps = if ($Resource -and $Resource.modifiedProperties) { $Resource.modifiedProperties } else { @() }

    # ── Resolve who deleted the device ───────────────────────────────────────
    $Resolved = Resolve-ActorIdentity -Actor $Event.actor -ModifiedProperties $ModProps

    # ── OS Platform ───────────────────────────────────────────────────────────
    $OSPlatform = Resolve-OSPlatform -Event $Event

    # ── Old/New values ────────────────────────────────────────────────────────
    $OldValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "old"
    $NewValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "new"

    [PSCustomObject]@{
        EventDateTime        = Format-AuditDateTime $Event.activityDateTime
        OperationType        = $Event.activityOperationType
        ActionLabel          = Get-ActionLabel -OperationType $Event.activityOperationType
        DeviceName           = $DeviceName
        DeviceType           = $DeviceType
        OSPlatform           = $OSPlatform
        DeletedBy            = $Resolved.Identity
        DeletedBy_Type       = $Resolved.Type
        DeletedBy_Source     = $Resolved.Source
        DeletedBy_IPAddress  = if ($Event.actor.ipAddress) { $Event.actor.ipAddress } else { "N/A" }
        DeletedBy_AppName    = if ($Event.actor.applicationDisplayName) { $Event.actor.applicationDisplayName } else { "N/A" }
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
$OutputFile     = Join-Path $OutputFolder "IntuneAudit_DevicesDeleted_${DateLabel}_${Timestamp}.csv"
$script:LogFile = Join-Path $OutputFolder "IntuneAudit_DevicesDeleted_${DateLabel}_${Timestamp}.log"

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Get-IntuneAuditReport-DevicesDeleted`r`nStarted: $(Get-Date)`r`nDate Range: $StartDate to $EndDate`r`n`r`n",
        [System.Text.Encoding]::UTF8)
}
catch { $script:LogFile = $null }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Intune Audit — Devices Deleted                                " -ForegroundColor Cyan
Write-Host "  Sethu Kumar B  |  READ ONLY                                   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Date range   : $StartDate  →  $EndDate"                -Level INFO
Write-Log "Category     : Device"                                   -Level INFO
Write-Log "Operations   : Delete, RemoveReference"                 -Level INFO
Write-Log "Max retries  : $MaxRetries (429 throttle protection)"   -Level INFO
Write-Log "Output CSV   : $OutputFile"                             -Level INFO
Write-Log "Log file     : $($script:LogFile)"                      -Level INFO
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
Write-Log "Server-side filter : category = Device"                      -Level INFO
Write-Log "Server-side filter : activityDateTime $StartDate → $EndDate" -Level INFO
Write-Log "Throttle protection: 429 Retry-After backoff active"         -Level INFO
Write-Log "Note               : Operation type filtered client-side"     -Level INFO
Write-Log "" -Level BLANK

$FilterStr     = "category eq 'Device' and activityDateTime ge $StartISO and activityDateTime le $EndISO"
$EncodedFilter = [Uri]::EscapeDataString($FilterStr)
$AuditUri      = "https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?`$filter=$EncodedFilter&`$top=100"

$RawEvents = Invoke-GraphGetAllPages -InitialUri $AuditUri -AccessToken $Token `
             -Label "Device audit events ($StartDate to $EndDate)" `
             -MaxRetries $MaxRetries

Write-Log "" -Level BLANK
Write-Log "Total Device events in date range: $($RawEvents.Count)" -Level INFO

# ── STEP 3: Filter for deletion operations ────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 — Filtering for Device Deletion Operations" -Level INFO
Write-Log "==========================================================" -Level SECTION

$TargetOps      = @("Delete", "RemoveReference")
$FilteredEvents = @($RawEvents | Where-Object { $TargetOps -contains $_.activityOperationType })

Write-Log "Events matching deletion operations : $($FilteredEvents.Count)" `
    -Level $(if ($FilteredEvents.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK

foreach ($Op in $TargetOps) {
    $OpCount = @($FilteredEvents | Where-Object { $_.activityOperationType -eq $Op }).Count
    Write-Log ("  {0,-35} : {1}" -f (Get-ActionLabel -OperationType $Op), $OpCount) -Level INFO
}
Write-Log "" -Level BLANK

if ($FilteredEvents.Count -eq 0) {
    Write-Log "No device deletion events found in the specified date range." -Level WARN
    Write-Log "Verify the date range and that devices were deleted in this period." -Level WARN
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
$DeletedCount   = @($Results | Where-Object { $_.OperationType -eq "Delete" }).Count
$RemRefCount    = @($Results | Where-Object { $_.OperationType -eq "RemoveReference" }).Count
$UserDeletions  = @($Results | Where-Object { $_.DeletedBy_Type -eq "User" }).Count
$SvcDeletions   = @($Results | Where-Object { $_.DeletedBy_Type -notin @("User","User (ID only)") }).Count
$FromModProps   = @($Results | Where-Object { $_.DeletedBy_Source -like "ModifiedProperties*" }).Count
$OSBreakdown    = $Results | Where-Object { $_.OSPlatform -ne "N/A" } |
                  Group-Object OSPlatform | Sort-Object Count -Descending
$UniqueActors   = @($Results | Where-Object { $_.DeletedBy -notlike "Unknown*" } |
                    Select-Object -ExpandProperty DeletedBy -Unique)
$UniqueDevices  = @($Results | Select-Object -ExpandProperty DeviceName -Unique)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  COMPLETE — READ ONLY — NO CHANGES MADE                       " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "  Date range queried         : $StartDate  →  $EndDate"          -Level INFO
Write-Log "  Total events pulled        : $($RawEvents.Count)"              -Level INFO
Write-Log "  Deletion events found      : $($Results.Count)"                 -Level $(if ($Results.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK
Write-Log "  ── Breakdown by Action ──────────────────────────────────" -Level SECTION
Write-Log "  DEVICE DELETED             : $DeletedCount"                     -Level $(if ($DeletedCount -gt 0) {"WARN"} else {"INFO"})
Write-Log "  DEVICE RELATIONSHIP REMOVED: $RemRefCount"                      -Level $(if ($RemRefCount  -gt 0) {"WARN"} else {"INFO"})
Write-Log "" -Level BLANK
Write-Log "  ── OS Platform Breakdown ────────────────────────────────" -Level SECTION
foreach ($os in $OSBreakdown) {
    Write-Log ("  {0,-20} : {1}" -f $os.Name, $os.Count) -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Actor Breakdown ──────────────────────────────────────" -Level SECTION
Write-Log "  Deleted by users           : $UserDeletions"                    -Level INFO
Write-Log "  Deleted by services / apps : $SvcDeletions"                     -Level INFO
Write-Log "  Identity from modifiedProps: $FromModProps"                      -Level INFO
Write-Log "" -Level BLANK
Write-Log "  ── Deleted Devices ──────────────────────────────────────" -Level SECTION
Write-Log "  Unique devices             : $($UniqueDevices.Count)"           -Level INFO
foreach ($Device in ($UniqueDevices | Select-Object -First 20)) {
    Write-Log "    → $Device" -Level WARN
}
if ($UniqueDevices.Count -gt 20) {
    Write-Log "    ... and $($UniqueDevices.Count - 20) more — see CSV for full list" -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Who Deleted Devices ──────────────────────────────────" -Level SECTION
Write-Log "  Unique actors              : $($UniqueActors.Count)"            -Level INFO
foreach ($Actor in $UniqueActors) {
    Write-Log "    → $Actor" -Level WARN
}
Write-Log "" -Level BLANK
Write-Log "  Output CSV  : $OutputFile"        -Level INFO
Write-Log "  Log file    : $($script:LogFile)" -Level INFO
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

#endregion ────────────────────────────────────────────────────────────────────