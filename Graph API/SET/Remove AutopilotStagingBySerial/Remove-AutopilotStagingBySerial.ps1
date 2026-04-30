#Requires -Version 5.1
# ==============================================================================
# Script Name  : Remove-AutopilotStagingBySerial.ps1
# Description  : Deletes specific devices from the Autopilot staging endpoint
#                (importedWindowsAutopilotDeviceIdentities) by serial number.
#
#                HOW IT WORKS:
#                  1. Reads serial numbers from a TXT file (one per line)
#                  2. Fetches all current staging records from Graph API
#                  3. Matches serials from TXT against staging records
#                  4. Deletes matched records one by one (no bulk delete in Graph)
#                  5. Reports and exports results to CSV + log
#
#                INPUT FILE:
#                  Serials.txt in same folder as script (one serial per line).
#                  Blank lines and lines starting with # are ignored.
#
#                SAFE TO RUN:
#                  - Only deletes staging records (temporary import queue).
#                  - Does NOT affect actual Autopilot devices in
#                    windowsAutopilotDeviceIdentities.
#                  - Does NOT affect Intune, Azure AD, or group tag assignments.
#                  - Serials not found in staging are logged and skipped safely.
#
#                OUTPUT CSV COLUMNS:
#                  SerialNumber, ImportedDeviceID, ImportStatus,
#                  ErrorCode, ErrorName, DeleteResult, DeleteDetail
#
#                DELETE RESULT VALUES:
#                  deleted        - successfully removed from staging
#                  not found      - serial not present in staging (already clean)
#                  failed         - delete call returned an error
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-04-30
#
# Requirements :
#   - Azure AD App Registration
#   - Graph API Application Permission (admin consent granted):
#       DeviceManagementServiceConfig.ReadWrite.All
#   - PowerShell 5.1 or later
#   - TLS 1.2 enabled
# ==============================================================================


#region --- CONFIGURATION -------------------------------------------------------

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# -- INPUT FILE ----------------------------------------------------------------
# One serial number per line. Blank lines and # comments ignored.
$SerialsFile = Join-Path $PSScriptRoot "Serials.txt"

# -- THROTTLE ------------------------------------------------------------------
$MaxRetries = 5

#endregion ----------------------------------------------------------------------


#region --- INIT ----------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile     = Join-Path $PSScriptRoot "AutopilotStagingDelete_$Timestamp.csv"
$script:LogFile = Join-Path $PSScriptRoot "AutopilotStagingDelete_$Timestamp.log"
$TranscriptFile = Join-Path $PSScriptRoot "AutopilotStagingDelete_Transcript_$Timestamp.log"

try { Start-Transcript -Path $TranscriptFile -Force | Out-Null } catch { }

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Remove-AutopilotStagingBySerial v1.0`r`nStarted: $(Get-Date)`r`n`r`n",
        [System.Text.Encoding]::UTF8)
} catch { $script:LogFile = $null }

#endregion ----------------------------------------------------------------------


#region --- FUNCTIONS -----------------------------------------------------------

function Write-Log {
    param (
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","SECTION","BLANK")]
        [string]$Level = "INFO"
    )
    $ColourMap = @{ INFO="Gray"; SUCCESS="Green"; WARN="Yellow"; ERROR="Red"; SECTION="Cyan"; BLANK="Gray" }
    $PrefixMap = @{ INFO="[INFO]   "; SUCCESS="[OK]     "; WARN="[WARN]   "; ERROR="[ERROR]  "; SECTION=""; BLANK="         " }
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


function Get-GraphToken {
    param ([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $Body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    try {
        Write-Log "Requesting access token..." -Level INFO
        $r = Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
             -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
             -Body $Body -ErrorAction Stop
        Write-Log "Access token acquired." -Level SUCCESS
        return $r.access_token
    }
    catch { Write-Log "Authentication failed: $_" -Level ERROR; exit 1 }
}


# -----------------------------------------------------------------------------
# Get-StagingRecords
# Pages through all importedWindowsAutopilotDeviceIdentities.
# Returns hashtable keyed by serialNumber (lowercase) -> record object.
# -----------------------------------------------------------------------------
function Get-StagingRecords {
    param ([string]$AccessToken)

    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $Uri     = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities?`$top=1000"
    $Lookup  = @{}

    do {
        try {
            $r   = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
            $Arr = if ($r.PSObject.Properties["value"]) { @($r.value) } else { @($r) }
            foreach ($rec in $Arr) {
                if (-not $rec) { continue }
                if ($rec.PSObject.Properties["serialNumber"] -and $rec.serialNumber) {
                    $key = $rec.serialNumber.ToLower()
                    # If duplicate serial in staging, keep most recently created
                    if (-not $Lookup.ContainsKey($key)) {
                        $Lookup[$key] = $rec
                    }
                    else {
                        try {
                            $existing = [datetime]::Parse($Lookup[$key].createdDateTime)
                            $current  = [datetime]::Parse($rec.createdDateTime)
                            if ($current -gt $existing) { $Lookup[$key] = $rec }
                        } catch { }
                    }
                }
            }
            $Uri = if ($r.PSObject.Properties["@odata.nextLink"]) { $r.'@odata.nextLink' } else { $null }
        }
        catch {
            Write-Log "Page fetch failed: $_" -Level ERROR
            $Uri = $null
        }
    } while ($Uri)

    return $Lookup
}


# -----------------------------------------------------------------------------
# Remove-StagingRecord
# DELETEs a single staging record by ID. Retries on 429.
# Returns $true on success, $false on failure.
# -----------------------------------------------------------------------------
function Remove-StagingRecord {
    param (
        [string]$RecordID,
        [string]$AccessToken
    )

    $Headers = @{ Authorization = "Bearer $AccessToken" }
    $Uri     = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$RecordID"
    $Attempt = 0

    do {
        $Attempt++
        try {
            $Resp = Invoke-WebRequest -Method DELETE -Uri $Uri -Headers $Headers `
                    -UseBasicParsing -ErrorAction Stop
            # 204 No Content = success
            if ($Resp.StatusCode -eq 204 -or $Resp.StatusCode -eq 200) { return $true }
            return $true
        }
        catch {
            $Code = $_.Exception.Response.StatusCode.value__
            if ($Code -eq 429) {
                $Wait = 60
                try {
                    $HV = $_.Exception.Response.Headers.GetValues("Retry-After")
                    if ($HV -and $HV.Count -gt 0) { $Wait = [int]$HV[0] }
                } catch { }
                $Wait += Get-Random -Minimum 1 -Maximum 10
                if ($Attempt -lt $MaxRetries) {
                    Write-Log "  429 throttled - waiting ${Wait}s (retry $Attempt/$MaxRetries)..." -Level WARN
                    Start-Sleep -Seconds $Wait
                } else { return $false }
            }
            else {
                Write-Log "  DELETE failed (HTTP $Code): $_" -Level ERROR
                return $false
            }
        }
    } while ($Attempt -lt $MaxRetries)

    return $false
}

#endregion ----------------------------------------------------------------------


#region --- MAIN ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Remove-AutopilotStagingBySerial  |  Sethu Kumar B            " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Serials file : $SerialsFile"      -Level INFO
Write-Log "Output CSV   : $OutputFile"       -Level INFO
Write-Log "Log file     : $($script:LogFile)" -Level INFO
Write-Log "Transcript   : $TranscriptFile"   -Level INFO
Write-Log "" -Level BLANK


# -- Step 1: Load serials from TXT ---------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 - Loading Serial Numbers from TXT" -Level INFO
Write-Log "==========================================================" -Level SECTION

if (-not (Test-Path $SerialsFile)) {
    Write-Log "Serials file not found: $SerialsFile" -Level ERROR
    Write-Log "Create Serials.txt in the script folder with one serial per line." -Level ERROR
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

# Read, trim, skip blanks and # comments
$RawLines     = Get-Content -Path $SerialsFile -Encoding UTF8
$TargetSerials = @($RawLines |
    ForEach-Object { $_.Trim() } |
    Where-Object   { $_ -ne "" -and -not $_.StartsWith("#") })

Write-Log "Serials loaded: $($TargetSerials.Count)" -Level $(if ($TargetSerials.Count -gt 0) {"SUCCESS"} else {"WARN"})

if ($TargetSerials.Count -eq 0) {
    Write-Log "No serials found in file. Exiting." -Level WARN
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

foreach ($s in $TargetSerials) {
    Write-Log "  -> $s" -Level INFO
}
Write-Log "" -Level BLANK


# -- Step 2: Authenticate ------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 2 - Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Token = Get-GraphToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret
Write-Log "" -Level BLANK


# -- Step 3: Fetch staging records ---------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 - Fetching Staging Records" -Level INFO
Write-Log "==========================================================" -Level SECTION

$StagingMap = Get-StagingRecords -AccessToken $Token
Write-Log "Total staging records found: $($StagingMap.Count)" -Level INFO
Write-Log "" -Level BLANK


# -- Step 4: Match and delete --------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 - Matching and Deleting" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Results      = [System.Collections.Generic.List[PSObject]]::new()
$CountDeleted = 0
$CountMissing = 0
$CountFailed  = 0

foreach ($Serial in $TargetSerials) {
    $key = $Serial.ToLower()

    if (-not $StagingMap.ContainsKey($key)) {
        Write-Log "  NOT FOUND  : $Serial - not in staging (already clean or never imported)" -Level WARN
        $CountMissing++
        $Results.Add([PSCustomObject]@{
            SerialNumber     = $Serial
            ImportedDeviceID = ""
            ImportStatus     = ""
            ErrorCode        = ""
            ErrorName        = ""
            DeleteResult     = "not found"
            DeleteDetail     = "Serial not present in staging"
        })
        continue
    }

    $rec = $StagingMap[$key]
    $RecID = if ($rec.PSObject.Properties["id"]) { [string]$rec.id } else { "" }

    $ImportStatus = "unknown"
    $ErrorCode    = ""
    $ErrorName    = ""
    if ($rec.PSObject.Properties["state"] -and $rec.state) {
        if ($rec.state.PSObject.Properties["deviceImportStatus"]) { $ImportStatus = [string]$rec.state.deviceImportStatus }
        if ($rec.state.PSObject.Properties["deviceErrorCode"])    { $ErrorCode    = [string]$rec.state.deviceErrorCode    }
        if ($rec.state.PSObject.Properties["deviceErrorName"])    { $ErrorName    = [string]$rec.state.deviceErrorName    }
    }

    if (-not $RecID) {
        Write-Log "  SKIP       : $Serial - staging record has no ID" -Level WARN
        $CountFailed++
        $Results.Add([PSCustomObject]@{
            SerialNumber     = $Serial
            ImportedDeviceID = ""
            ImportStatus     = $ImportStatus
            ErrorCode        = $ErrorCode
            ErrorName        = $ErrorName
            DeleteResult     = "failed"
            DeleteDetail     = "Record found but ID missing - cannot delete"
        })
        continue
    }

    Write-Log ("  Deleting   : {0,-30} | StagingID: {1} | Status: {2}" -f $Serial, $RecID, $ImportStatus) -Level INFO
    $ok = Remove-StagingRecord -RecordID $RecID -AccessToken $Token

    if ($ok) {
        Write-Log "  DELETED    : $Serial" -Level SUCCESS
        $CountDeleted++
        $Results.Add([PSCustomObject]@{
            SerialNumber     = $Serial
            ImportedDeviceID = $RecID
            ImportStatus     = $ImportStatus
            ErrorCode        = $ErrorCode
            ErrorName        = $ErrorName
            DeleteResult     = "deleted"
            DeleteDetail     = ""
        })
    }
    else {
        Write-Log "  FAILED     : $Serial - delete call failed" -Level ERROR
        $CountFailed++
        $Results.Add([PSCustomObject]@{
            SerialNumber     = $Serial
            ImportedDeviceID = $RecID
            ImportStatus     = $ImportStatus
            ErrorCode        = $ErrorCode
            ErrorName        = $ErrorName
            DeleteResult     = "failed"
            DeleteDetail     = "DELETE request failed - check log"
        })
    }

    # Small pause between deletes to avoid throttle
    Start-Sleep -Milliseconds 300
}

Write-Log "" -Level BLANK
Write-Log "--- Delete Summary ---" -Level SECTION
Write-Log "  Deleted    : $CountDeleted" -Level $(if ($CountDeleted -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  Not found  : $CountMissing" -Level $(if ($CountMissing -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  Failed     : $CountFailed"  -Level $(if ($CountFailed  -gt 0) {"ERROR"}   else {"INFO"})
Write-Log "" -Level BLANK


# -- Step 5: Export CSV --------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 5 - Exporting Results" -Level INFO
Write-Log "==========================================================" -Level SECTION

try {
    $Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $SizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
    Write-Log "CSV exported." -Level SUCCESS
    Write-Log "  Path : $OutputFile" -Level INFO
    Write-Log "  Rows : $($Results.Count)  |  Size: $SizeMB MB" -Level INFO
}
catch { Write-Log "CSV export failed: $_" -Level ERROR }

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  DELETE COMPLETE  |  Sethu Kumar B                            " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }

#endregion ----------------------------------------------------------------------