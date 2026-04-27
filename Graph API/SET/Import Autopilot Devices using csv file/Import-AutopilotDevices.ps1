#Requires -Version 5.1
# ==============================================================================
# Script Name  : Import-AutopilotDevices.ps1
# Description  : Imports Windows Autopilot devices from one or more hardware
#                hash CSV files located in the Import folder inside the script
#                root directory.
#
#                HOW IT WORKS:
#                  1. Scans Import\ subfolder for all .csv files
#                  2. Validates each CSV has required columns
#                  3. Batches devices (up to 500 per API call) and POSTs to
#                     Graph API importedWindowsAutopilotDeviceIdentities/import
#                  4. Resolves import IDs by querying the staging endpoint
#                     filtered by serial number (endpoint returns 204, no body)
#                  5. Polls import status until all devices reach a terminal
#                     state (complete / error) or timeout is reached
#                  6. Exports full status CSV and log to script root folder
#
#                CSV INPUT FORMAT (columns required in each file):
#                  Device Serial Number  - device serial number
#                  Windows Product ID    - can be empty
#                  Hardware Hash         - base64 hardware hash string
#                  Group Tag             - optional, applied during import
#
#                IMPORT STATUS VALUES (per device in output CSV):
#                  complete     - successfully imported into Autopilot
#                  error        - import failed (error detail in StatusDetail)
#                  pending      - still processing when poll timeout reached
#                  unknown      - initial state before processing begins
#
#                POLL BEHAVIOUR:
#                  After submitting each batch, the script waits briefly then
#                  polls the import status every $PollIntervalSeconds until all
#                  devices reach a terminal state or $PollTimeoutMinutes is hit.
#
#                BATCH SIZE:
#                  Graph API supports up to 500 devices per import call.
#                  Large CSV files are automatically split into batches.
#
#                INPUT:
#                  $PSScriptRoot\Import\*.csv  - one or more hardware hash CSVs
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  AutopilotImport_[timestamp].csv        - full import status
#                  AutopilotImport_[timestamp].log        - detailed run log
#                  AutopilotImport_Transcript_[timestamp].log - PS transcript
#
#                OUTPUT CSV COLUMNS:
#                  SourceFile, SerialNumber, WindowsProductID, GroupTag,
#                  ImportedDeviceID, ImportStatus, StatusDetail,
#                  BatchNumber, SubmittedAt, StatusCheckedAt
#
# Author       : Sethu Kumar B
# Version      : 1.5
# Created Date : 2026-04-17
# Last Modified: 2026-04-27
#
# Requirements :
#   - Azure AD App Registration
#   - Graph API Application Permission (admin consent granted):
#       DeviceManagementServiceConfig.ReadWrite.All  - Autopilot import
#   - PowerShell 5.1 or later
#   - TLS 1.2 enabled
#
# Change Log   :
#   v1.0 - 2026-04-17 - Sethu Kumar B - Initial release.
#   v1.1 - 2026-04-17 - Sethu Kumar B - Fixed body structure, added error logging.
#   v1.2 - 2026-04-24 - Sethu Kumar B - Removed @odata.type from device objects
#                        and state block. Batch import with async status polling.
#                        Multi-file support. Full per-device status in output CSV.
#   v1.3 - 2026-04-27 - Sethu Kumar B - Fixed 400 BadRequest: wrapped request body
#                        in importedWindowsAutopilotDeviceIdentities key. Fixed
#                        response unwrap logic.
#   v1.4 - 2026-04-27 - Sethu Kumar B - Fixed field name orderIdentifier -> groupTag.
#   v1.5 - 2026-04-27 - Sethu Kumar B - Fixed ID resolution: /import returns 204 No
#                        Content (no body). Switched to Invoke-WebRequest to handle
#                        204. Added Get-ImportedDevicesBySerial to resolve IDs via
#                        GET after submit. groupTag and productKey omitted entirely
#                        when blank instead of sending empty string.
# ==============================================================================


#region --- CONFIGURATION -------------------------------------------------------

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# -- IMPORT FOLDER -------------------------------------------------------------
$ImportFolder = Join-Path $PSScriptRoot "Import"

# -- BATCH SIZE ----------------------------------------------------------------
# Graph API limit is 500 per call.
$BatchSize = 500

# -- POLL SETTINGS -------------------------------------------------------------
$PollIntervalSeconds = 30
$PollTimeoutMinutes  = 30

# -- THROTTLE ------------------------------------------------------------------
$MaxRetries = 5

#endregion ----------------------------------------------------------------------


#region --- INIT ----------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile     = Join-Path $PSScriptRoot "AutopilotImport_$Timestamp.csv"
$script:LogFile = Join-Path $PSScriptRoot "AutopilotImport_$Timestamp.log"
$TranscriptFile = Join-Path $PSScriptRoot "AutopilotImport_Transcript_$Timestamp.log"

try { Start-Transcript -Path $TranscriptFile -Force | Out-Null } catch { }

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Import-AutopilotDevices v1.5`r`nStarted: $(Get-Date)`r`n`r`n",
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
# Submit-AutopilotBatch
# POSTs a batch of up to 500 devices to the /import endpoint.
# The endpoint returns 204 No Content on success - no body, no IDs.
# Uses Invoke-WebRequest (not Invoke-RestMethod) so 204 does not throw.
# groupTag and productKey are omitted entirely when blank.
# IDs are resolved after submit via Get-ImportedDevicesBySerial.
# -----------------------------------------------------------------------------
function Submit-AutopilotBatch {
    param (
        [array]$Devices,
        [string]$AccessToken
    )

    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $Uri     = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/import"

    # Build device array - omit groupTag / productKey when blank
    $DeviceArray = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Devices) {
        $DevObj = [ordered]@{
            serialNumber              = [string]$d.SerialNumber
            hardwareIdentifier        = [string]$d.HardwareHash
            assignedUserPrincipalName = ""
        }
        if (-not [string]::IsNullOrWhiteSpace($d.GroupTag))         { $DevObj["groupTag"]   = [string]$d.GroupTag }
        if (-not [string]::IsNullOrWhiteSpace($d.WindowsProductID)) { $DevObj["productKey"] = [string]$d.WindowsProductID }
        $DeviceArray.Add($DevObj)
    }

    # Wrap in key required by the endpoint
    $BodyObject = @{ importedWindowsAutopilotDeviceIdentities = $DeviceArray }
    $Body       = $BodyObject | ConvertTo-Json -Depth 10

    $Attempt = 0
    do {
        $Attempt++
        try {
            # Invoke-WebRequest handles 204 cleanly; Invoke-RestMethod throws on no-content
            $Resp = Invoke-WebRequest -Method POST -Uri $Uri -Headers $Headers `
                    -Body $Body -UseBasicParsing -ErrorAction Stop
            Write-Log "  HTTP $($Resp.StatusCode) - batch accepted by API." -Level INFO
            return $true
        }
        catch {
            $Code = $_.Exception.Response.StatusCode.value__
            $RespBody = ""
            try {
                $ErrStream = $_.Exception.Response.GetResponseStream()
                $Reader    = [System.IO.StreamReader]::new($ErrStream)
                $RespBody  = $Reader.ReadToEnd()
                $Reader.Close()
            } catch { }
            if ($RespBody) { Write-Log "  Response body: $RespBody" -Level ERROR }
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
                }
                else { throw $_ }
            }
            else { throw $_ }
        }
    } while ($Attempt -lt $MaxRetries)
}


# -----------------------------------------------------------------------------
# Get-ImportedDevicesBySerial
# Queries importedWindowsAutopilotDeviceIdentities and returns a hashtable
# keyed by serialNumber (lowercase) -> record object.
# Used after batch submit to resolve IDs since /import returns 204 (no body).
# -----------------------------------------------------------------------------
function Get-ImportedDevicesBySerial {
    param ([string]$AccessToken)

    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $Uri     = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities?`$top=1000"
    $All     = [System.Collections.Generic.List[PSObject]]::new()

    do {
        try {
            $r = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
            foreach ($rec in $r.value) { $All.Add($rec) }
            $Uri = $r.'@odata.nextLink'
        }
        catch {
            Write-Log "  Serial lookup poll failed: $($_.Exception.Response.StatusCode.value__)" -Level WARN
            $Uri = $null
        }
    } while ($Uri)

    $Lookup = @{}
    foreach ($item in $All) {
        if ($item.serialNumber) {
            $Lookup[$item.serialNumber.ToLower()] = $item
        }
    }
    return $Lookup
}


# -----------------------------------------------------------------------------
# Get-ImportStatus
# Retrieves current status of all imported devices from the staging endpoint.
# Returns hashtable keyed by id -> status object.
# -----------------------------------------------------------------------------
function Get-ImportStatus {
    param ([string]$AccessToken)

    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $Uri     = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities?`$top=1000"
    $All     = [System.Collections.Generic.List[PSObject]]::new()

    do {
        try {
            $r = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
            foreach ($rec in $r.value) { $All.Add($rec) }
            $Uri = $r.'@odata.nextLink'
        }
        catch {
            Write-Log "Status poll failed: $($_.Exception.Response.StatusCode.value__)" -Level WARN
            $Uri = $null
        }
    } while ($Uri)

    $Lookup = @{}
    foreach ($item in $All) {
        if ($item.id) { $Lookup[[string]$item.id] = $item }
    }
    return $Lookup
}


# -----------------------------------------------------------------------------
# Wait-ForImportCompletion
# Polls import status until all tracked IDs reach terminal state or timeout.
# Returns final status hashtable.
# -----------------------------------------------------------------------------
function Wait-ForImportCompletion {
    param (
        [string[]]$DeviceIDs,
        [string]$AccessToken,
        [int]$PollIntervalSeconds,
        [int]$PollTimeoutMinutes
    )

    $TerminalStates = @("complete", "error", "completedWithError")
    $Deadline       = (Get-Date).AddMinutes($PollTimeoutMinutes)
    $PollCount      = 0

    Write-Log "  Polling for import completion (interval: ${PollIntervalSeconds}s, timeout: ${PollTimeoutMinutes}min)..." -Level INFO

    do {
        $PollCount++
        Start-Sleep -Seconds $PollIntervalSeconds

        $StatusMap = Get-ImportStatus -AccessToken $AccessToken
        $Pending   = 0
        $Complete  = 0
        $Errors    = 0

        foreach ($Id in $DeviceIDs) {
            if ($StatusMap.ContainsKey($Id)) {
                $State = [string]$StatusMap[$Id].state.deviceImportStatus
                if ($TerminalStates -contains $State) {
                    if ($State -eq "complete") { $Complete++ } else { $Errors++ }
                } else { $Pending++ }
            } else { $Pending++ }
        }

        $Elapsed = [math]::Round(((Get-Date) - ($Deadline.AddMinutes(-$PollTimeoutMinutes))).TotalMinutes, 1)
        Write-Log ("  Poll $PollCount | Complete: $Complete  Errors: $Errors  Pending: $Pending | Elapsed: ${Elapsed}min") -Level INFO

        if ($Pending -eq 0) {
            Write-Log "  All devices reached terminal state." -Level SUCCESS
            return $StatusMap
        }

        if ((Get-Date) -ge $Deadline) {
            Write-Log "  Poll timeout reached ($PollTimeoutMinutes min). $Pending device(s) still pending." -Level WARN
            return $StatusMap
        }

    } while ($true)
}

#endregion ----------------------------------------------------------------------


#region --- MAIN ----------------------------------------------------------------

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Import-AutopilotDevices  |  Sethu Kumar B                    " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Import folder    : $ImportFolder"            -Level INFO
Write-Log "Output CSV       : $OutputFile"              -Level INFO
Write-Log "Log file         : $($script:LogFile)"       -Level INFO
Write-Log "Transcript       : $TranscriptFile"          -Level INFO
Write-Log "Batch size       : $BatchSize"               -Level INFO
Write-Log "Poll interval    : ${PollIntervalSeconds}s"  -Level INFO
Write-Log "Poll timeout     : ${PollTimeoutMinutes}min" -Level INFO
Write-Log "" -Level BLANK


# -- Step 1: Scan Import folder ------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 - Scanning Import Folder" -Level INFO
Write-Log "==========================================================" -Level SECTION

if (-not (Test-Path $ImportFolder)) {
    Write-Log "Import folder not found: $ImportFolder" -Level ERROR
    Write-Log "Create an 'Import' subfolder in the script root and place CSV files there." -Level ERROR
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

$CsvFiles = @(Get-ChildItem -Path $ImportFolder -Filter "*.csv" -File | Sort-Object Name)

Write-Log "CSV files found: $($CsvFiles.Count)" -Level $(if ($CsvFiles.Count -gt 0) {"SUCCESS"} else {"WARN"})

if ($CsvFiles.Count -eq 0) {
    Write-Log "No CSV files found in: $ImportFolder" -Level WARN
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

foreach ($f in $CsvFiles) {
    Write-Log "  -> $($f.Name)  ($([math]::Round($f.Length/1KB, 1)) KB)" -Level INFO
}
Write-Log "" -Level BLANK


# -- Step 2: Validate and load CSVs --------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 2 - Validating and Loading CSV Files" -Level INFO
Write-Log "==========================================================" -Level SECTION

$RequiredColumns = @("Device Serial Number", "Hardware Hash")
$AllDevices      = [System.Collections.Generic.List[PSObject]]::new()
$SkippedFiles    = 0

foreach ($File in $CsvFiles) {
    Write-Log "Loading: $($File.Name)" -Level INFO
    try {
        $Data = Import-Csv -Path $File.FullName -ErrorAction Stop

        if ($Data.Count -eq 0) {
            Write-Log "  SKIPPED - file is empty." -Level WARN
            $SkippedFiles++
            continue
        }

        $Columns = $Data[0].PSObject.Properties.Name
        $Missing = $RequiredColumns | Where-Object { $Columns -notcontains $_ }
        if ($Missing.Count -gt 0) {
            Write-Log "  SKIPPED - missing required column(s): $($Missing -join ', ')" -Level ERROR
            $SkippedFiles++
            continue
        }

        $InvalidRows = @($Data | Where-Object {
            [string]::IsNullOrWhiteSpace($_.'Device Serial Number') -or
            [string]::IsNullOrWhiteSpace($_.'Hardware Hash')
        })
        if ($InvalidRows.Count -gt 0) {
            Write-Log "  WARNING - $($InvalidRows.Count) row(s) have blank serial or hash - skipping." -Level WARN
        }

        $ValidRows = @($Data | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.'Device Serial Number') -and
            -not [string]::IsNullOrWhiteSpace($_.'Hardware Hash')
        })

        foreach ($row in $ValidRows) {
            $AllDevices.Add([PSCustomObject]@{
                SourceFile       = $File.Name
                SerialNumber     = [string]$row.'Device Serial Number'
                WindowsProductID = if ($row.PSObject.Properties["Windows Product ID"]) { [string]$row.'Windows Product ID' } else { "" }
                HardwareHash     = [string]$row.'Hardware Hash'
                GroupTag         = if ($row.PSObject.Properties["Group Tag"])           { [string]$row.'Group Tag' }           else { "" }
            })
        }

        Write-Log "  Loaded: $($ValidRows.Count) valid device(s)." -Level SUCCESS
    }
    catch {
        Write-Log "  FAILED to load file: $_" -Level ERROR
        $SkippedFiles++
    }
}

Write-Log "" -Level BLANK
Write-Log "Total devices to import : $($AllDevices.Count)" -Level $(if ($AllDevices.Count -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "Files skipped           : $SkippedFiles"        -Level $(if ($SkippedFiles -gt 0) {"WARN"} else {"INFO"})

if ($AllDevices.Count -eq 0) {
    Write-Log "No valid devices to import. Exiting." -Level WARN
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}
Write-Log "" -Level BLANK


# -- Step 3: Authenticate ------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 - Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION
$Token = Get-GraphToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret


# -- Step 4: Submit in batches -------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 - Submitting Import Batches" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Results        = [System.Collections.Generic.List[PSObject]]::new()
$AllDevicesList = $AllDevices.ToArray()
$TotalDevices   = $AllDevicesList.Count
$TotalBatches   = [math]::Ceiling($TotalDevices / $BatchSize)
$BatchNum       = 0
$AllImportedIDs = [System.Collections.Generic.List[string]]::new()
$ImportedIdMap  = @{}

for ($i = 0; $i -lt $TotalDevices; $i += $BatchSize) {
    $BatchNum    = $BatchNum + 1
    $BatchEnd    = [math]::Min($i + $BatchSize - 1, $TotalDevices - 1)
    $Batch       = $AllDevicesList[$i..$BatchEnd]
    $SubmittedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Log "Batch $BatchNum of $TotalBatches - submitting $($Batch.Count) device(s)..." -Level INFO

    try {
        $null = Submit-AutopilotBatch -Devices $Batch -AccessToken $Token

        # /import returns 204 - no IDs in response.
        # Wait briefly then query staging endpoint to resolve IDs by serial.
        Write-Log "  Waiting 10s for staging records to appear..." -Level INFO
        Start-Sleep -Seconds 10

        $SerialMap = Get-ImportedDevicesBySerial -AccessToken $Token

        foreach ($d in $Batch) {
            $snKey    = $d.SerialNumber.ToLower()
            $RetObj   = if ($SerialMap.ContainsKey($snKey)) { $SerialMap[$snKey] } else { $null }
            $ImportId = if ($RetObj -and $RetObj.id) { [string]$RetObj.id } else { "N/A" }

            if ($ImportId -ne "N/A") {
                [void]$AllImportedIDs.Add($ImportId)
                $ImportedIdMap[$ImportId] = $d
            }

            $Results.Add([PSCustomObject]@{
                SourceFile       = $d.SourceFile
                SerialNumber     = $d.SerialNumber
                WindowsProductID = $d.WindowsProductID
                GroupTag         = $d.GroupTag
                ImportedDeviceID = $ImportId
                ImportStatus     = if ($ImportId -ne "N/A") { "submitted" } else { "submitted - id not resolved" }
                StatusDetail     = ""
                BatchNumber      = $BatchNum
                SubmittedAt      = $SubmittedAt
                StatusCheckedAt  = "pending"
            })

            Write-Log ("  -> {0,-20} | ImportID: {1}" -f $d.SerialNumber, $ImportId) -Level INFO
        }
    }
    catch {
        $ErrMsg = [string]$_.Exception.Message
        Write-Log "  Batch $BatchNum FAILED: $ErrMsg" -Level ERROR
        foreach ($d in $Batch) {
            $Results.Add([PSCustomObject]@{
                SourceFile       = $d.SourceFile
                SerialNumber     = $d.SerialNumber
                WindowsProductID = $d.WindowsProductID
                GroupTag         = $d.GroupTag
                ImportedDeviceID = "N/A"
                ImportStatus     = "SUBMIT FAILED"
                StatusDetail     = $ErrMsg
                BatchNumber      = $BatchNum
                SubmittedAt      = $SubmittedAt
                StatusCheckedAt  = "N/A"
            })
        }
    }

    if ($BatchNum -lt $TotalBatches) { Start-Sleep -Seconds 3 }
}

Write-Log "" -Level BLANK
Write-Log "All batches submitted. Total import IDs tracked: $($AllImportedIDs.Count)" -Level INFO


# -- Step 5: Poll for completion status ----------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 5 - Polling Import Status" -Level INFO
Write-Log "==========================================================" -Level SECTION

if ($AllImportedIDs.Count -eq 0) {
    Write-Log "No import IDs to poll. Skipping status check." -Level WARN
}
else {
    $FinalStatusMap  = Wait-ForImportCompletion `
        -DeviceIDs $AllImportedIDs.ToArray() `
        -AccessToken $Token `
        -PollIntervalSeconds $PollIntervalSeconds `
        -PollTimeoutMinutes $PollTimeoutMinutes

    $StatusCheckedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    for ($r = 0; $r -lt $Results.Count; $r++) {
        $Row      = $Results[$r]
        $ImportId = $Row.ImportedDeviceID
        if ($ImportId -eq "N/A") { continue }

        if ($FinalStatusMap.ContainsKey($ImportId)) {
            $StatusObj = $FinalStatusMap[$ImportId]
            $DevState  = if ($StatusObj.state -and $StatusObj.state.deviceImportStatus) {
                             [string]$StatusObj.state.deviceImportStatus
                         } else { "unknown" }
            $RegState  = if ($StatusObj.state -and $StatusObj.state.deviceRegistrationId) {
                             [string]$StatusObj.state.deviceRegistrationId
                         } else { "" }
            $ErrorCode = if ($StatusObj.state -and $StatusObj.state.deviceErrorCode) {
                             [string]$StatusObj.state.deviceErrorCode
                         } else { "" }
            $ErrorName = if ($StatusObj.state -and $StatusObj.state.deviceErrorName) {
                             [string]$StatusObj.state.deviceErrorName
                         } else { "" }

            $Detail = ""
            if ($ErrorCode -and $ErrorCode -ne "0") { $Detail  = "ErrorCode: $ErrorCode" }
            if ($ErrorName) { $Detail += if ($Detail) { " | $ErrorName" } else { $ErrorName } }
            if ($RegState)  { $Detail += if ($Detail) { " | RegID: $RegState" } else { "RegID: $RegState" } }

            $Row.ImportStatus    = $DevState
            $Row.StatusDetail    = $Detail
            $Row.StatusCheckedAt = $StatusCheckedAt

            $Level = if ($DevState -eq "complete") { "SUCCESS" } elseif ($DevState -eq "error") { "ERROR" } else { "WARN" }
            Write-Log ("  {0,-20} | {1,-20} | {2}" -f $Row.SerialNumber, $DevState, $Detail) -Level $Level
        }
        else {
            $Row.ImportStatus    = "pending - not found in status"
            $Row.StatusCheckedAt = $StatusCheckedAt
        }
    }
}
Write-Log "" -Level BLANK


# -- Step 6: Export CSV --------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 6 - Exporting Results" -Level INFO
Write-Log "==========================================================" -Level SECTION

try {
    $Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $SizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
    Write-Log "CSV exported." -Level SUCCESS
    Write-Log "  Path : $OutputFile" -Level INFO
    Write-Log "  Rows : $($Results.Count)  |  Size: $SizeMB MB" -Level INFO
}
catch { Write-Log "CSV export failed: $_" -Level ERROR }


# -- Summary -------------------------------------------------------------------
$CompleteCount = @($Results | Where-Object { $_.ImportStatus -eq "complete" }).Count
$ErrorCount    = @($Results | Where-Object { $_.ImportStatus -eq "error" -or $_.ImportStatus -like "FAILED*" }).Count
$PendingCount  = @($Results | Where-Object { $_.ImportStatus -notlike "complete" -and $_.ImportStatus -notlike "*error*" -and $_.ImportStatus -notlike "*FAILED*" }).Count

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  IMPORT COMPLETE  |  Sethu Kumar B                            " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "  Files processed    : $($CsvFiles.Count - $SkippedFiles) of $($CsvFiles.Count)" -Level INFO
Write-Log "  Total devices      : $TotalDevices"  -Level INFO
Write-Log "  Batches submitted  : $TotalBatches"  -Level INFO
Write-Log "" -Level BLANK
Write-Log "  COMPLETE           : $CompleteCount" -Level $(if ($CompleteCount -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  ERRORS             : $ErrorCount"    -Level $(if ($ErrorCount    -gt 0) {"ERROR"}   else {"INFO"})
Write-Log "  PENDING / UNKNOWN  : $PendingCount"  -Level $(if ($PendingCount  -gt 0) {"WARN"}    else {"INFO"})
Write-Log "" -Level BLANK
Write-Log "  Output CSV   : $OutputFile"        -Level INFO
Write-Log "  Log file     : $($script:LogFile)" -Level INFO
Write-Log "  Transcript   : $TranscriptFile"    -Level INFO
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }

#endregion ----------------------------------------------------------------------