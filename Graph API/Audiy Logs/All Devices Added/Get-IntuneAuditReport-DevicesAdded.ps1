#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-IntuneAuditReport-DevicesAdded.ps1
# Description  : Retrieves all device addition events from the Intune audit log
#                for a specified date range.
#
#                Captures the full lifecycle of device addition events:
#                  - Create          : Device enrolled / added to Intune
#                  - Patch           : Device record updated / modified
#                  - SetReference    : Device relationship added (e.g. user assigned)
#                  - Assign          : Device assigned to a group or profile
#
#                ACTOR IDENTITY RESOLUTION — TWO SOURCES:
#                  Source 1 — actor object fields (priority order):
#                    userPrincipalName    → human admin acting via Intune portal
#                    servicePrincipalName → automated service (Autopilot / DEM)
#                    applicationDisplayName → app-based action
#                    userId               → GUID fallback
#
#                  Source 2 — modifiedProperties inside the audit resource:
#                    For device enrollment events the actor fields are often
#                    empty because the action is triggered by the Intune
#                    enrollment service — not by the admin directly. In this
#                    case the enrolling user identity is written into the device
#                    record as modifiedProperties entries:
#                      EnrolledByUserPrincipalName
#                      UserPrincipalName
#                    The script checks Source 2 as a fallback when Source 1
#                    returns no identity.
#
#                429 THROTTLING PROTECTION:
#                  The pagination function reads the Retry-After header from
#                  HTTP 429 responses and waits the specified number of seconds
#                  before retrying the same page. Up to 3 retries per page.
#                  This prevents data loss from throttling on large date ranges.
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
#                  Step 3 — Filter client-side for addition-related operations:
#                             Create / Patch / SetReference / Assign
#                  Step 4 — Shape each event into a clean CSV row
#                  Step 5 — Export CSV and log to $PSScriptRoot
#
#                CSV COLUMNS:
#                  EventDateTime, OperationType, ActionLabel,
#                  DeviceName, DeviceType, OSPlatform,
#                  ActionBy, ActionBy_Type, ActionBy_Source,
#                  ActionBy_IPAddress, ActionBy_AppName,
#                  ActivityResult, ActivityType,
#                  OldValue, NewValue, AuditEventID
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  IntuneAudit_DevicesAdded_[StartDate]_[EndDate]_[ts].csv
#                  IntuneAudit_DevicesAdded_[StartDate]_[EndDate]_[ts].log
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
#   v1.1 - 2026-04-10 - Sethu Kumar B - Fixed actor identity: Resolve-ActorIdentity
#                        checks UPN/SPN/App/UserId in priority order. Added
#                        OSPlatform and ActionBy_Type columns.
#   v1.2 - 2026-04-10 - Sethu Kumar B - Fixed 429 throttling: pagination now
#                        reads Retry-After header and retries automatically.
#                        Fixed enrollment user identity: when actor fields are
#                        empty (Intune enrollment service), script falls back
#                        to EnrolledByUserPrincipalName / UserPrincipalName
#                        from modifiedProperties. Added ActionBy_Source column
#                        to show which source the identity was resolved from.
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
# Maximum retries per page when Graph API returns HTTP 429 (Too Many Requests).
# The script reads the Retry-After header and waits that many seconds before
# retrying. Increase $MaxRetries if you have a very large date range.
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
#
#            429 THROTTLING PROTECTION:
#              When the Graph API returns HTTP 429, the function reads the
#              Retry-After response header (Graph always sends it) and waits
#              that many seconds before retrying the same page. A random jitter
#              of 1-5 seconds is added to avoid thundering herd after the
#              throttle window lifts. Up to $MaxRetries retries per page.
#              If all retries are exhausted the page is skipped with a warning
#              and pagination continues — partial results are still exported.
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
                    # Read Retry-After header — Graph always sends this on 429
                    $RetryAfter = 30
                    try {
                        $RetryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                    } catch { }
                    $Jitter = Get-Random -Minimum 1 -Maximum 5
                    $Wait   = $RetryAfter + $Jitter
                    Write-Log "  Page $Page — HTTP 429 throttled. Waiting ${Wait}s (Retry-After: ${RetryAfter}s + jitter: ${Jitter}s). Retry $Attempt/$MaxRetries..." -Level WARN
                    Start-Sleep -Seconds $Wait
                    # Do NOT advance $Uri — retry the same page
                }
                else {
                    Write-Log "  Page $Page failed — HTTP $Code : $_ (attempt $Attempt/$MaxRetries)" -Level ERROR
                    $Uri     = $null
                    $Success = $true  # Exit retry loop, stop pagination
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
#              2. servicePrincipalName  — automated service / Autopilot / DEM
#              3. applicationDisplayName — app-based action
#              4. userId GUID           — last resort name fallback
#
#            Source 2 — modifiedProperties fallback:
#              For device enrollment events the actor fields are often empty
#              because the action is performed by the Intune enrollment service
#              internally. The enrolling user identity is written into the
#              device record as modifiedProperties. Checked fields:
#                EnrolledByUserPrincipalName  (most reliable for enrollment)
#                UserPrincipalName
#
#            Returns [PSCustomObject] with:
#              Identity — best resolved name / UPN / GUID
#              Type     — User / Service Principal / Application / Unknown
#              Source   — "Actor" or "ModifiedProperties (EnrolledBy)"
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-ActorIdentity {
    param (
        [PSObject]$Actor,
        [array]$ModifiedProperties
    )

    # ── Source 1: actor object fields ─────────────────────────────────────────
    if ($Actor) {
        if (-not [string]::IsNullOrWhiteSpace($Actor.userPrincipalName)) {
            return [PSCustomObject]@{
                Identity = $Actor.userPrincipalName
                Type     = "User"
                Source   = "Actor (UPN)"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Actor.servicePrincipalName)) {
            return [PSCustomObject]@{
                Identity = $Actor.servicePrincipalName
                Type     = "Service Principal"
                Source   = "Actor (Service Principal)"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Actor.applicationDisplayName)) {
            return [PSCustomObject]@{
                Identity = $Actor.applicationDisplayName
                Type     = "Application"
                Source   = "Actor (Application)"
            }
        }
    }

    # ── Source 2: modifiedProperties fallback ─────────────────────────────────
    # For enrollment events the enrolling user is stored here
    if ($ModifiedProperties -and $ModifiedProperties.Count -gt 0) {

        # Check EnrolledByUserPrincipalName first — most specific for enrollment
        $enrolledBy = $ModifiedProperties |
                      Where-Object { $_.displayName -eq "EnrolledByUserPrincipalName" } |
                      Select-Object -First 1
        if ($enrolledBy) {
            $val = if ($enrolledBy.newValue) { $enrolledBy.newValue } else { $enrolledBy.oldValue }
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                return [PSCustomObject]@{
                    Identity = $val
                    Type     = "User"
                    Source   = "ModifiedProperties (EnrolledByUPN)"
                }
            }
        }

        # Check UserPrincipalName as secondary fallback
        $upnProp = $ModifiedProperties |
                   Where-Object { $_.displayName -eq "UserPrincipalName" } |
                   Select-Object -First 1
        if ($upnProp) {
            $val = if ($upnProp.newValue) { $upnProp.newValue } else { $upnProp.oldValue }
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                return [PSCustomObject]@{
                    Identity = $val
                    Type     = "User"
                    Source   = "ModifiedProperties (UPN)"
                }
            }
        }
    }

    # ── Source 1 continued: userId GUID ──────────────────────────────────────
    if ($Actor -and -not [string]::IsNullOrWhiteSpace($Actor.userId)) {
        return [PSCustomObject]@{
            Identity = $Actor.userId + " (User ID — UPN not available)"
            Type     = "User (ID only)"
            Source   = "Actor (User ID)"
        }
    }

    return [PSCustomObject]@{
        Identity = "Unknown — Intune enrollment service"
        Type     = "Service"
        Source   = "Not available"
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Resolve-OSPlatform
# Purpose  : Extracts OS platform from modifiedProperties or activityType.
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-OSPlatform {
    param ([PSObject]$Event)

    # Check 1 — modifiedProperties OperatingSystem field
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

    # Check 2 — activityType string (e.g. "Create ManagedDevice Windows")
    if (-not [string]::IsNullOrWhiteSpace($Event.activityType)) {
        foreach ($os in @("Windows","macOS","iOS","Android","Linux","ChromeOS")) {
            if ($Event.activityType -match $os) { return $os }
        }
    }

    # Check 3 — displayName string
    if (-not [string]::IsNullOrWhiteSpace($Event.displayName)) {
        foreach ($os in @("Windows","macOS","iOS","Android","Linux","ChromeOS")) {
            if ($Event.displayName -match $os) { return $os }
        }
    }

    return "N/A"
}


function Get-ActionLabel {
    param ([string]$OperationType)
    switch ($OperationType) {
        "Create"          { return "DEVICE ENROLLED / ADDED" }
        "Patch"           { return "DEVICE RECORD UPDATED" }
        "SetReference"    { return "DEVICE RELATIONSHIP ADDED" }
        "Assign"          { return "DEVICE ASSIGNED TO GROUP" }
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
    $ModProps = if ($Resource -and $Resource.modifiedProperties) { $Resource.modifiedProperties } else { @() }

    # ── Resolve actor identity — pass both actor AND modifiedProperties ────────
    # modifiedProperties contains EnrolledByUserPrincipalName for enrollment events
    # where actor fields are empty (Intune enrollment service triggered)
    $Resolved = Resolve-ActorIdentity -Actor $Event.actor -ModifiedProperties $ModProps

    # ── OS Platform ───────────────────────────────────────────────────────────
    $OSPlatform = Resolve-OSPlatform -Event $Event

    # ── Old/New values ────────────────────────────────────────────────────────
    $OldValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "old"
    $NewValue = Get-ModifiedPropertyValues -ModifiedProperties $ModProps -ValueType "new"

    [PSCustomObject]@{
        EventDateTime      = Format-AuditDateTime $Event.activityDateTime
        OperationType      = $Event.activityOperationType
        ActionLabel        = Get-ActionLabel -OperationType $Event.activityOperationType
        DeviceName         = $DeviceName
        DeviceType         = $DeviceType
        OSPlatform         = $OSPlatform
        ActionBy           = $Resolved.Identity
        ActionBy_Type      = $Resolved.Type
        ActionBy_Source    = $Resolved.Source
        ActionBy_IPAddress = if ($Event.actor.ipAddress) { $Event.actor.ipAddress } else { "N/A" }
        ActionBy_AppName   = if ($Event.actor.applicationDisplayName) { $Event.actor.applicationDisplayName } else { "N/A" }
        ActivityResult     = $Event.activityResult
        ActivityType       = $Event.activityType
        OldValue           = $OldValue
        NewValue           = $NewValue
        AuditEventID       = $Event.id
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
$OutputFile     = Join-Path $OutputFolder "IntuneAudit_DevicesAdded_${DateLabel}_${Timestamp}.csv"
$script:LogFile = Join-Path $OutputFolder "IntuneAudit_DevicesAdded_${DateLabel}_${Timestamp}.log"

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Get-IntuneAuditReport-DevicesAdded`r`nStarted: $(Get-Date)`r`nDate Range: $StartDate to $EndDate`r`n`r`n",
        [System.Text.Encoding]::UTF8)
}
catch { $script:LogFile = $null }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Intune Audit — Devices Added / Enrolled                       " -ForegroundColor Cyan
Write-Host "  Sethu Kumar B  |  READ ONLY                                   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Date range   : $StartDate  →  $EndDate"                -Level INFO
Write-Log "Category     : Device"                                   -Level INFO
Write-Log "Operations   : Create, Patch, SetReference, Assign"     -Level INFO
Write-Log "Max retries  : $MaxRetries (429 throttle protection)"   -Level INFO
Write-Log "Output CSV   : $OutputFile"                             -Level INFO
Write-Log "Log file     : $($script:LogFile)"                      -Level INFO
Write-Log "" -Level BLANK

# ── STEP 1: Authenticate ──────────────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 — Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION
$Token = Get-GraphAccessToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret

# ── STEP 2: Pull audit events (429 retry built in) ────────────────────────────
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

# ── STEP 3: Filter for addition operations ────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 — Filtering for Device Addition Operations" -Level INFO
Write-Log "==========================================================" -Level SECTION

$TargetOps      = @("Create", "Patch", "SetReference", "Assign")
$FilteredEvents = @($RawEvents | Where-Object { $TargetOps -contains $_.activityOperationType })

Write-Log "Events matching addition operations : $($FilteredEvents.Count)" `
    -Level $(if ($FilteredEvents.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK

foreach ($Op in $TargetOps) {
    $OpCount = @($FilteredEvents | Where-Object { $_.activityOperationType -eq $Op }).Count
    Write-Log ("  {0,-35} : {1}" -f (Get-ActionLabel -OperationType $Op), $OpCount) -Level INFO
}
Write-Log "" -Level BLANK

if ($FilteredEvents.Count -eq 0) {
    Write-Log "No device addition events found in the specified date range." -Level WARN
    Write-Log "Verify the date range and that devices were added in this period." -Level WARN
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
$EnrolledCount  = @($Results | Where-Object { $_.OperationType -eq "Create" }).Count
$UpdatedCount   = @($Results | Where-Object { $_.OperationType -eq "Patch" }).Count
$RelAddedCount  = @($Results | Where-Object { $_.OperationType -eq "SetReference" }).Count
$AssignedCount  = @($Results | Where-Object { $_.OperationType -eq "Assign" }).Count
$UserActions    = @($Results | Where-Object { $_.ActionBy_Type -eq "User" }).Count
$SvcActions     = @($Results | Where-Object { $_.ActionBy_Type -notin @("User","User (ID only)") }).Count
$FromModProps   = @($Results | Where-Object { $_.ActionBy_Source -like "ModifiedProperties*" }).Count
$OSBreakdown    = $Results | Where-Object { $_.OSPlatform -ne "N/A" } |
                  Group-Object OSPlatform | Sort-Object Count -Descending
$UniqueActors   = @($Results | Where-Object { $_.ActionBy -notlike "Unknown*" } |
                    Select-Object -ExpandProperty ActionBy -Unique)
$UniqueDevices  = @($Results | Select-Object -ExpandProperty DeviceName -Unique)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  COMPLETE — READ ONLY — NO CHANGES MADE                       " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "  Date range queried         : $StartDate  →  $EndDate"          -Level INFO
Write-Log "  Total events pulled        : $($RawEvents.Count)"              -Level INFO
Write-Log "  Addition events found      : $($Results.Count)"                 -Level $(if ($Results.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK
Write-Log "  ── Breakdown by Action ──────────────────────────────────" -Level SECTION
Write-Log "  DEVICE ENROLLED / ADDED    : $EnrolledCount"                    -Level $(if ($EnrolledCount -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  DEVICE RECORD UPDATED      : $UpdatedCount"                     -Level INFO
Write-Log "  DEVICE RELATIONSHIP ADDED  : $RelAddedCount"                    -Level INFO
Write-Log "  DEVICE ASSIGNED TO GROUP   : $AssignedCount"                    -Level INFO
Write-Log "" -Level BLANK
Write-Log "  ── OS Platform Breakdown ────────────────────────────────" -Level SECTION
foreach ($os in $OSBreakdown) {
    Write-Log ("  {0,-20} : {1}" -f $os.Name, $os.Count) -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Actor Identity Sources ───────────────────────────────" -Level SECTION
Write-Log "  Actions by users (UPN)     : $UserActions"                      -Level INFO
Write-Log "  Actions by services / apps : $SvcActions"                       -Level INFO
Write-Log "  Identity from modifiedProps: $FromModProps"                      -Level $(if ($FromModProps -gt 0) {"WARN"} else {"INFO"})
Write-Log "  (ModifiedProps = enrollment service — user written to device record)" -Level INFO
Write-Log "" -Level BLANK
Write-Log "  ── Devices Enrolled ─────────────────────────────────────" -Level SECTION
Write-Log "  Unique devices             : $($UniqueDevices.Count)"           -Level INFO
foreach ($Device in ($UniqueDevices | Select-Object -First 20)) {
    Write-Log "    → $Device" -Level INFO
}
if ($UniqueDevices.Count -gt 20) {
    Write-Log "    ... and $($UniqueDevices.Count - 20) more — see CSV for full list" -Level INFO
}
Write-Log "" -Level BLANK
Write-Log "  ── Who Added Devices ────────────────────────────────────" -Level SECTION
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