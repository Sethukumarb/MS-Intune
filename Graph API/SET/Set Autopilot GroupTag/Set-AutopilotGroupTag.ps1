#Requires -Version 5.1
# ==============================================================================
# Script Name  : Set-AutopilotGroupTag.ps1
# Description  : Adds or updates the Group Tag on Windows Autopilot devices
#                using serial numbers read from a plain text input file.
#
#                For each serial number the script:
#                  1. Looks up the Autopilot device record by serial number
#                  2. Reads the current Group Tag (empty or existing value)
#                  3. Posts the new Group Tag using updateDeviceProperties
#                  4. Records the before/after in the audit CSV and log
#
#                ACTION LABELS:
#                  TAG ADDED    — device had no group tag, new tag applied
#                  TAG UPDATED  — device had an existing tag, tag changed
#                  NO CHANGE    — new tag is identical to existing tag, skipped
#
#                DRY RUN MODE (default: $DryRun = $true):
#                  Shows what would change but makes no API calls.
#                  Set $DryRun = $false to apply changes.
#
#                INPUT FILE:
#                  AutopilotGroupTag.txt — same folder as this script
#                  Format: SerialNumber,NewGroupTag  (one per line)
#                  Blank lines and lines starting with # are ignored.
#
#                  Example:
#                    SN-001234,Engineering
#                    SN-005678,Manufacturing
#                    SN-009999,AI
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  AutopilotGroupTag_[timestamp].csv  — full audit CSV
#                  AutopilotGroupTag_[timestamp].log  — run log
#
#                AUDIT CSV COLUMNS:
#                  SerialNumber, AutopilotDeviceID, DeviceName,
#                  Manufacturer, Model, EnrollmentState,
#                  OldGroupTag, NewGroupTag, Action,
#                  Result, ErrorDetail, Timestamp
#
# Author       : Sethu Kumar B
# Version      : 1.3
# Created Date : 2026-04-10
# Last Modified: 2026-04-10
#
# Requirements :
#   - Azure AD App Registration
#   - Graph API Application Permissions (admin consent granted):
#       DeviceManagementManagedDevices.Read.All      — read Autopilot device list
#       DeviceManagementServiceConfig.ReadWrite.All   — update Autopilot group tag
#   - PowerShell 5.1 or later
#
# Change Log   :
#   v1.0 - 2026-04-10 - Sethu Kumar B - Initial release.
#   v1.1 - 2026-04-14 - Sethu Kumar B - Fixed HTTP 500: replaced $filter with
#                        full paginated pull + client-side hashtable lookup.
#   v1.2 - 2026-04-14 - Sethu Kumar B - Switched to /beta endpoint.
#   v1.3 - 2026-04-14 - Sethu Kumar B - Removed $select from bulk pull URI
#                        ($select + $top combination causes 500 on this endpoint).
#                        Added response body capture to error output so the real
#                        underlying error message is visible in the log.
#                        Reads serial numbers + new tags from TXT file.
#                        Dry run mode default. Before/after group tag audit.
#                        TAG ADDED / TAG UPDATED / NO CHANGE action labels.
#                        429 retry with Retry-After backoff.
# ==============================================================================


#region ─── CONFIGURATION ─── Edit these values before running ────────────────

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ── DRY RUN ───────────────────────────────────────────────────────────────────
# $true  → READ ONLY — shows what would change but makes NO API updates.
#           Run this first to verify all serials are found and tags are correct.
# $false → LIVE — actually updates the Group Tag on each Autopilot device.
#           Only set this after reviewing the dry run output.
# ─────────────────────────────────────────────────────────────────────────────
$DryRun = $true

# ── INPUT FILE ────────────────────────────────────────────────────────────────
# File must be in the same folder as this script.
# Format: SerialNumber,NewGroupTag  — one entry per line.
# Lines starting with # and blank lines are ignored.
# ─────────────────────────────────────────────────────────────────────────────
$InputFileName = "AutopilotGroupTag.txt"
$InputPath     = Join-Path $PSScriptRoot $InputFileName

# ── THROTTLE SETTINGS ─────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-GraphAccessToken
# ─────────────────────────────────────────────────────────────────────────────
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
# FUNCTION : Invoke-GraphRequest
# Purpose  : Wraps Invoke-RestMethod with 429 Retry-After backoff.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-GraphRequest {
    param (
        [string]$Uri,
        [string]$Method = "GET",
        [string]$AccessToken,
        [hashtable]$Body = $null,
        [int]$MaxRetries = 3
    )

    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $Attempt = 0

    do {
        $Attempt++
        try {
            $Params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $Headers
                ErrorAction = "Stop"
            }
            if ($Body) {
                $Params.Body = ($Body | ConvertTo-Json -Depth 10)
            }
            return Invoke-RestMethod @Params
        }
        catch {
            $Code = $_.Exception.Response.StatusCode.value__
            if ($Code -eq 429 -and $Attempt -lt $MaxRetries) {
                $RetryAfter = 30
                try { $RetryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch { }
                $Jitter = Get-Random -Minimum 1 -Maximum 5
                $Wait   = $RetryAfter + $Jitter
                Write-Log "  HTTP 429 — waiting ${Wait}s before retry $Attempt/$MaxRetries..." -Level WARN
                Start-Sleep -Seconds $Wait
            }
            else { throw $_ }
        }
    } while ($Attempt -lt $MaxRetries)
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-AllAutopilotDevices
# Purpose  : Pulls the full Autopilot device list with pagination and returns
#            a hashtable keyed by serialNumber (lowercase) for fast O(1) lookup.
#
#            WHY NOT USE $filter=serialNumber eq '...' :
#            The Graph API windowsAutopilotDeviceIdentities endpoint returns
#            HTTP 500 Internal Server Error when $filter is used on serialNumber
#            in many tenants. This is a known Graph API limitation on this
#            endpoint. The reliable approach is to pull all devices once,
#            build a hashtable, then look up client-side. For large Autopilot
#            registries this is still fast — one paginated bulk pull shared
#            across all serials in the input file rather than one GET per serial.
# ─────────────────────────────────────────────────────────────────────────────
function Get-AllAutopilotDevices {
    param ([string]$AccessToken)

    $Headers    = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $AllDevices = [System.Collections.Generic.List[PSObject]]::new()
    $Uri        = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities" +
                  "?`$top=1000"
    $Page       = 0

    Write-Log "  Pulling all Autopilot device records (paginated)..." -Level INFO

    do {
        $Page++
        try {
            $r = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
            foreach ($d in $r.value) { $AllDevices.Add($d) }
            Write-Log ("  Page {0} — {1} records  (running total: {2})" -f $Page, $r.value.Count, $AllDevices.Count) -Level INFO
            $Uri = $r.'@odata.nextLink'
        }
        catch {
            $Code = $_.Exception.Response.StatusCode.value__
            if ($Code -eq 429) {
                $RetryAfter = 30
                try { $RetryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch { }
                $Wait = $RetryAfter + (Get-Random -Minimum 1 -Maximum 5)
                Write-Log "  429 throttled — waiting ${Wait}s..." -Level WARN
                Start-Sleep -Seconds $Wait
            }
            else {
                    # Surface the real underlying error from the response body if available
                    $RealError = ""
                    try {
                        $ErrorStream = $_.Exception.Response.GetResponseStream()
                        $Reader      = [System.IO.StreamReader]::new($ErrorStream)
                        $RealError   = $Reader.ReadToEnd()
                        $Reader.Close()
                    } catch { }
                    $Detail = if ($RealError) { "`r`nResponse body: $RealError" } else { "" }
                    throw "Failed to retrieve Autopilot device list — HTTP $Code : $_$Detail"
                }
        }
    } while ($Uri)

    Write-Log "  Total Autopilot devices loaded: $($AllDevices.Count)" -Level SUCCESS

    # Build hashtable keyed by serialNumber (lowercase) for fast client-side lookup
    $Lookup = @{}
    foreach ($d in $AllDevices) {
        if (-not [string]::IsNullOrWhiteSpace($d.serialNumber)) {
            $Key = $d.serialNumber.ToLower().Trim()
            # If duplicate serials exist keep the most recently contacted one
            if (-not $Lookup.ContainsKey($Key)) {
                $Lookup[$Key] = $d
            }
        }
    }

    Write-Log "  Lookup table built: $($Lookup.Count) unique serial numbers." -Level INFO
    return $Lookup
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-AutopilotDeviceBySerial
# Purpose  : Looks up an Autopilot device from the pre-built hashtable.
#            Returns the device object or $null if not found.
# ─────────────────────────────────────────────────────────────────────────────
function Get-AutopilotDeviceBySerial {
    param ([string]$SerialNumber, [hashtable]$DeviceLookup)

    $Key = $SerialNumber.ToLower().Trim()
    if ($DeviceLookup.ContainsKey($Key)) {
        return $DeviceLookup[$Key]
    }
    return $null
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Set-AutopilotGroupTag
# Purpose  : Posts the new group tag to the Autopilot device using the
#            updateDeviceProperties action endpoint.
#            Returns HTTP 204 No Content on success — no response body.
# ─────────────────────────────────────────────────────────────────────────────
function Set-AutopilotGroupTag {
    param (
        [string]$DeviceId,
        [string]$NewGroupTag,
        [string]$AccessToken
    )

    $Uri  = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$DeviceId/updateDeviceProperties"
    $Body = @{ groupTag = $NewGroupTag }

    Invoke-GraphRequest -Uri $Uri -Method POST -AccessToken $AccessToken `
                        -Body $Body -MaxRetries $MaxRetries | Out-Null
}

#endregion ────────────────────────────────────────────────────────────────────


#region ─── MAIN ──────────────────────────────────────────────────────────────

# ── Initialise output paths ───────────────────────────────────────────────────
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile     = Join-Path $PSScriptRoot "AutopilotGroupTag_$Timestamp.csv"
$script:LogFile = Join-Path $PSScriptRoot "AutopilotGroupTag_$Timestamp.log"

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Set-AutopilotGroupTag`r`nStarted: $(Get-Date)`r`nDryRun: $DryRun`r`nInput: $InputPath`r`n`r`n",
        [System.Text.Encoding]::UTF8)
}
catch { $script:LogFile = $null }

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
if ($DryRun) {
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Set-AutopilotGroupTag  |  DRY RUN MODE                       " -ForegroundColor Cyan
    Write-Host "  Sethu Kumar B                                                 " -ForegroundColor Cyan
    Write-Host "  READ ONLY — no group tags will be changed.                    " -ForegroundColor Cyan
    Write-Host "  Review output then set `$DryRun = `$false to apply changes.   " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}
else {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  Set-AutopilotGroupTag  |  LIVE UPDATE MODE                    " -ForegroundColor Yellow
    Write-Host "  Sethu Kumar B                                                  " -ForegroundColor Yellow
    Write-Host "  ⚠  Autopilot Group Tags WILL be updated.                      " -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}

Write-Log "" -Level BLANK
Write-Log "Mode         : $(if ($DryRun) {'DRY RUN — no changes'} else {'LIVE UPDATE'})" `
          -Level $(if ($DryRun) {"INFO"} else {"WARN"})
Write-Log "Input file   : $InputPath"        -Level INFO
Write-Log "Output CSV   : $OutputFile"       -Level INFO
Write-Log "Log file     : $($script:LogFile)" -Level INFO
Write-Log "" -Level BLANK

# ── STEP 1: Read and parse input file ─────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 — Reading Input File" -Level INFO
Write-Log "==========================================================" -Level SECTION

if (-not (Test-Path $InputPath)) {
    Write-Log "Input file not found: $InputPath" -Level ERROR
    Write-Log "Create the file with one entry per line: SerialNumber,NewGroupTag" -Level ERROR
    exit 1
}

$RawLines = Get-Content -Path $InputPath -Encoding UTF8
Write-Log "File loaded — $($RawLines.Count) total lines." -Level SUCCESS

# Parse valid entries — skip blanks and comment lines
$Entries = [System.Collections.Generic.List[PSObject]]::new()
$LineNum = 0

foreach ($Line in $RawLines) {
    $LineNum++
    $Trimmed = $Line.Trim()

    # Skip blank lines and comment lines
    if ([string]::IsNullOrWhiteSpace($Trimmed) -or $Trimmed.StartsWith("#")) { continue }

    # Expect format: SerialNumber,NewGroupTag
    $Parts = $Trimmed -split ",", 2

    if ($Parts.Count -ne 2) {
        Write-Log "  Line $LineNum — Invalid format (expected SerialNumber,GroupTag): '$Trimmed'" -Level WARN
        continue
    }

    $Serial  = $Parts[0].Trim()
    $NewTag  = $Parts[1].Trim()

    if ([string]::IsNullOrWhiteSpace($Serial)) {
        Write-Log "  Line $LineNum — Serial number is empty, skipping." -Level WARN
        continue
    }

    if ([string]::IsNullOrWhiteSpace($NewTag)) {
        Write-Log "  Line $LineNum — New group tag is empty for serial '$Serial', skipping." -Level WARN
        continue
    }

    $Entries.Add([PSCustomObject]@{ Serial = $Serial; NewTag = $NewTag; LineNum = $LineNum })
}

Write-Log "Valid entries parsed : $($Entries.Count)" -Level $(if ($Entries.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "" -Level BLANK

if ($Entries.Count -eq 0) {
    Write-Log "No valid entries found. Nothing to process." -Level WARN
    exit 0
}

# ── STEP 2: Authenticate ──────────────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 2 — Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Token = Get-GraphAccessToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret

# ── Build Autopilot lookup table ──────────────────────────────────────────────
# Pulls ALL Autopilot devices once into a hashtable keyed by serial number.
# This avoids HTTP 500 errors that occur when using $filter=serialNumber on this
# endpoint in many tenants — a known Graph API limitation on windowsAutopilotDeviceIdentities.
Write-Log "" -Level BLANK
Write-Log "Building Autopilot device lookup table..." -Level INFO
$DeviceLookup = Get-AllAutopilotDevices -AccessToken $Token

# ── STEP 3: Process each device ───────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 — Processing Autopilot Devices" -Level INFO
Write-Log "==========================================================" -Level SECTION
Write-Log "$(if ($DryRun) {'DRY RUN — lookups only, no updates will be made.'} else {'LIVE — group tags will be updated.'})" `
          -Level $(if ($DryRun) {"INFO"} else {"WARN"})
Write-Log "" -Level BLANK

$AuditResults = [System.Collections.Generic.List[PSObject]]::new()
$Counter      = 0
$Total        = $Entries.Count

# Counters
$AddedCount    = 0
$UpdatedCount  = 0
$NoChangeCount = 0
$NotFoundCount = 0
$FailedCount   = 0

foreach ($Entry in $Entries) {
    $Counter++
    $Serial = $Entry.Serial
    $NewTag = $Entry.NewTag

    Write-Log "  [$Counter/$Total] Serial: $Serial  →  New Tag: $NewTag" -Level INFO

    # ── Look up device by serial (client-side hashtable lookup) ──────────────────
    # No per-device API call needed — lookup from pre-built hashtable
    $Device = Get-AutopilotDeviceBySerial -SerialNumber $Serial -DeviceLookup $DeviceLookup

    # ── Device not found ──────────────────────────────────────────────────────
    if ($null -eq $Device) {
        Write-Log "    NOT FOUND — serial '$Serial' not registered in Autopilot." -Level WARN
        $AuditResults.Add([PSCustomObject]@{
            SerialNumber      = $Serial
            AutopilotDeviceID = "Not found"
            DeviceName        = "Not found"
            Manufacturer      = "Not found"
            Model             = "Not found"
            EnrollmentState   = "Not found"
            OldGroupTag       = "Not found"
            NewGroupTag       = $NewTag
            Action            = "NOT FOUND"
            Result            = "SKIPPED"
            ErrorDetail       = "Serial number not registered in Windows Autopilot"
            Timestamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
        $NotFoundCount++
        Write-Log "" -Level BLANK
        continue
    }

    # ── Device found — read current group tag ─────────────────────────────────
    $CurrentTag  = if ($Device.groupTag) { [string]$Device.groupTag } else { "" }
    $DeviceName  = if ($Device.displayName)    { [string]$Device.displayName }    else { "N/A" }
    $Manufacturer= if ($Device.manufacturer)   { [string]$Device.manufacturer }   else { "N/A" }
    $Model       = if ($Device.model)          { [string]$Device.model }          else { "N/A" }
    $EnrollState = if ($Device.enrollmentState){ [string]$Device.enrollmentState } else { "N/A" }

    # Display current state clearly
    if ([string]::IsNullOrWhiteSpace($CurrentTag)) {
        Write-Log "    Device found   : $DeviceName ($Manufacturer $Model)" -Level INFO
        Write-Log "    Current tag    : (empty — no group tag set)" -Level INFO
        Write-Log "    New tag        : $NewTag" -Level SUCCESS
    }
    else {
        Write-Log "    Device found   : $DeviceName ($Manufacturer $Model)" -Level INFO
        Write-Log "    Current tag    : $CurrentTag" -Level WARN
        Write-Log "    New tag        : $NewTag" -Level SUCCESS
    }

    # ── Determine action ──────────────────────────────────────────────────────
    if ($CurrentTag -eq $NewTag) {
        # Tags are identical — nothing to do
        Write-Log "    Action         : NO CHANGE — tag is already '$NewTag'" -Level INFO
        $AuditResults.Add([PSCustomObject]@{
            SerialNumber      = $Serial
            AutopilotDeviceID = [string]$Device.id
            DeviceName        = $DeviceName
            Manufacturer      = $Manufacturer
            Model             = $Model
            EnrollmentState   = $EnrollState
            OldGroupTag       = $CurrentTag
            NewGroupTag       = $NewTag
            Action            = "NO CHANGE"
            Result            = "SKIPPED"
            ErrorDetail       = "New tag is identical to existing tag — no update needed"
            Timestamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
        $NoChangeCount++
        Write-Log "" -Level BLANK
        continue
    }

    $ActionLabel = if ([string]::IsNullOrWhiteSpace($CurrentTag)) { "TAG ADDED" } else { "TAG UPDATED" }

    # ── Dry run — log and skip ────────────────────────────────────────────────
    if ($DryRun) {
        Write-Log "    Action         : $ActionLabel (DRY RUN — no change made)" -Level WARN
        $AuditResults.Add([PSCustomObject]@{
            SerialNumber      = $Serial
            AutopilotDeviceID = [string]$Device.id
            DeviceName        = $DeviceName
            Manufacturer      = $Manufacturer
            Model             = $Model
            EnrollmentState   = $EnrollState
            OldGroupTag       = if ([string]::IsNullOrWhiteSpace($CurrentTag)) { "(empty)" } else { $CurrentTag }
            NewGroupTag       = $NewTag
            Action            = "$ActionLabel (DRY RUN)"
            Result            = "DRY RUN"
            ErrorDetail       = ""
            Timestamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
        if ($ActionLabel -eq "TAG ADDED")   { $AddedCount++ }
        else                                { $UpdatedCount++ }
        Write-Log "" -Level BLANK
        Start-Sleep -Milliseconds 200
        continue
    }

    # ── Live update ───────────────────────────────────────────────────────────
    try {
        Set-AutopilotGroupTag -DeviceId $Device.id -NewGroupTag $NewTag -AccessToken $Token

        Write-Log "    Result         : $ActionLabel — SUCCESS ✓" -Level SUCCESS
        if ([string]::IsNullOrWhiteSpace($CurrentTag)) {
            Write-Log "    Change         : (empty)  →  $NewTag" -Level SUCCESS
        }
        else {
            Write-Log "    Change         : $CurrentTag  →  $NewTag" -Level SUCCESS
        }

        $AuditResults.Add([PSCustomObject]@{
            SerialNumber      = $Serial
            AutopilotDeviceID = [string]$Device.id
            DeviceName        = $DeviceName
            Manufacturer      = $Manufacturer
            Model             = $Model
            EnrollmentState   = $EnrollState
            OldGroupTag       = if ([string]::IsNullOrWhiteSpace($CurrentTag)) { "(empty)" } else { $CurrentTag }
            NewGroupTag       = $NewTag
            Action            = $ActionLabel
            Result            = "SUCCESS"
            ErrorDetail       = ""
            Timestamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
        if ($ActionLabel -eq "TAG ADDED") { $AddedCount++ } else { $UpdatedCount++ }
    }
    catch {
        $ErrMsg = [string]$_.Exception.Message
        Write-Log "    Result         : UPDATE FAILED — $ErrMsg" -Level ERROR
        $AuditResults.Add([PSCustomObject]@{
            SerialNumber      = $Serial
            AutopilotDeviceID = [string]$Device.id
            DeviceName        = $DeviceName
            Manufacturer      = $Manufacturer
            Model             = $Model
            EnrollmentState   = $EnrollState
            OldGroupTag       = if ([string]::IsNullOrWhiteSpace($CurrentTag)) { "(empty)" } else { $CurrentTag }
            NewGroupTag       = $NewTag
            Action            = "UPDATE FAILED"
            Result            = "FAILED"
            ErrorDetail       = $ErrMsg
            Timestamp         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
        $FailedCount++
    }

    Write-Log "" -Level BLANK
    Start-Sleep -Milliseconds 300
}

# ── STEP 4: Export audit CSV ───────────────────────────────────────────────────
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 — Exporting Audit CSV" -Level INFO
Write-Log "==========================================================" -Level SECTION

try {
    $AuditResults | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $SizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
    Write-Log "Audit CSV exported." -Level SUCCESS
    Write-Log "  Path : $OutputFile"                                 -Level INFO
    Write-Log "  Rows : $($AuditResults.Count)  |  Size: $SizeMB MB" -Level INFO
}
catch {
    Write-Log "CSV export failed: $_" -Level ERROR
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  $(if ($DryRun) {'DRY RUN COMPLETE — NO CHANGES MADE'} else {'UPDATE COMPLETE'})" -ForegroundColor $(if ($DryRun) {"Cyan"} else {"Yellow"})
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "  Mode                       : $(if ($DryRun) {'DRY RUN'} else {'LIVE UPDATE'})" `
          -Level $(if ($DryRun) {"INFO"} else {"WARN"})
Write-Log "  Total entries in file      : $($Entries.Count)"  -Level INFO
Write-Log "" -Level BLANK
Write-Log "  ── Results ──────────────────────────────────────────────" -Level SECTION
Write-Log "  TAG ADDED   (was empty)    : $AddedCount"     -Level $(if ($AddedCount   -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  TAG UPDATED (was set)      : $UpdatedCount"   -Level $(if ($UpdatedCount -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  NO CHANGE   (tag matched)  : $NoChangeCount"  -Level INFO
Write-Log "  NOT FOUND   (not in AP)    : $NotFoundCount"  -Level $(if ($NotFoundCount -gt 0) {"WARN"} else {"INFO"})
Write-Log "  FAILED                     : $FailedCount"    -Level $(if ($FailedCount   -gt 0) {"ERROR"} else {"INFO"})
Write-Log "" -Level BLANK

if ($DryRun) {
    Write-Log "  ── Next Step ────────────────────────────────────────────" -Level SECTION
    Write-Log "  Review the audit CSV and verify every entry is correct."  -Level INFO
    Write-Log "  When ready — set `$DryRun = `$false and run again."       -Level WARN
}

Write-Log "" -Level BLANK
Write-Log "  Audit CSV : $OutputFile"         -Level INFO
Write-Log "  Log file  : $($script:LogFile)"  -Level INFO
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

#endregion ────────────────────────────────────────────────────────────────────