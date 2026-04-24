#Requires -Version 5.1
# ==============================================================================
# Script Name  : Remove-IntuneDeviceObjects.ps1
# Description  : Deletes Intune managed device and Windows Autopilot device
#                identity records for devices identified by serial number.
#
#                WHAT THIS SCRIPT DELETES:
#                  Intune Managed Device   - DELETE /deviceManagement/managedDevices/{id}
#                  Autopilot Device        - DELETE /deviceManagement/windowsAutopilotDeviceIdentities/{id}
#
#                WHAT THIS SCRIPT SKIPS:
#                  Azure AD Device Object  - No permission. Logged as SKIPPED.
#                                           Delete manually from Entra portal if needed.
#
#                LOOKUP STRATEGY:
#                  Serial -> bulk pull all Intune devices -> hashtable lookup
#                  Serial -> bulk pull all Autopilot devices -> hashtable lookup
#                  No $filter used - causes HTTP 500 on these endpoints.
#
#                DRY RUN MODE ($DryRun = $true - DEFAULT):
#                  Shows exactly what would be deleted. No DELETE calls made.
#                  Review output CSV then set $DryRun = $false to execute.
#
#                INPUT FILE:
#                  input.txt - same folder as this script
#                  One serial number per line. # comments and blank lines ignored.
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  RemoveDevices_[timestamp].csv        - full audit of all actions
#                  RemoveDevices_[timestamp].log        - detailed run log
#                  RemoveDevices_Transcript_[timestamp].log - full PS transcript
#
#                CSV COLUMNS:
#                  SerialNumber, DeviceName, Manufacturer, Model,
#                  IntuneDeviceID, IntuneDeleteStatus, IntuneDeleteNote,
#                  AutopilotDeviceID, AutopilotDeleteStatus, AutopilotDeleteNote,
#                  AzureADDeviceID, AzureADStatus,
#                  OverallResult, Timestamp
#
#                RESULT VALUES:
#                  DELETED       - Object found and successfully deleted
#                  DRY RUN       - Would be deleted (DryRun = $true)
#                  NOT FOUND     - No record found for this serial
#                  FAILED        - Delete call failed (error in Note column)
#                  SKIPPED       - Not attempted (no permission or not applicable)
#
# Author       : Sethu Kumar B
# Version      : 1.3
# Created Date : 2026-04-17
# Last Modified: 2026-04-17
#
# Permissions required (admin consent granted):
#   DeviceManagementManagedDevices.ReadWrite.All  - read + delete Intune devices
#   DeviceManagementServiceConfig.ReadWrite.All   - read + delete Autopilot devices
#
# Change Log   :
#   v1.0 - 2026-04-17 - Sethu Kumar B - Initial release.
#   v1.1 - 2026-04-17 - Sethu Kumar B - Fixed duplicate handling.
#   v1.2 - 2026-04-17 - Sethu Kumar B - Duplicate warning input-only.
#   v1.3 - 2026-04-17 - Sethu Kumar B - Windows OS filter on Intune pull.
#                        input serials (not all 1113 tenant serials). Added
#                        Azure AD device lookup per Intune record - reports
#                        found/not found, no delete. Azure AD count in summary.
#                        Separate CSV row per Azure AD entry. Fixed DupeLabel
#                        string interpolation bug.: hashtables
#                        now store List of ALL records per serial. Processing
#                        loop iterates every duplicate independently - one
#                        DELETE per record, one CSV row per record.
#                        RecordType column added: Intune / Intune (Duplicate N/M)
#                        Duplicate serials flagged in log as WARN during pull.
# ==============================================================================


#region --- CONFIGURATION -------------------------------------------------------
$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# -- DRY RUN -------------------------------------------------------------------

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# WARNING: $DryRun = $false WILL PERMANENTLY DELETE DEVICE RECORDS.
#          THIS CANNOT BE UNDONE.
#          Always run with $DryRun = $true first and review the CSV output
#          before setting $DryRun = $false.
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

$DryRun = $false

# -- INPUT FILE ----------------------------------------------------------------
$InputFileName = "remove_inputserialnumbers.txt"
$InputPath     = Join-Path $PSScriptRoot $InputFileName

# -- THROTTLE ------------------------------------------------------------------
$MaxRetries = 5

#endregion ----------------------------------------------------------------------


#region --- INIT ----------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$DryLabel       = if ($DryRun) { "[DRY RUN] " } else { "" }
$OutputFile     = Join-Path $PSScriptRoot "${DryLabel}RemoveDevices_$Timestamp.csv"
$script:LogFile = Join-Path $PSScriptRoot "${DryLabel}RemoveDevices_$Timestamp.log"
$TranscriptFile = Join-Path $PSScriptRoot "${DryLabel}RemoveDevices_Transcript_$Timestamp.log"

try { Start-Transcript -Path $TranscriptFile -Force | Out-Null } catch { }

try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Remove-IntuneDeviceObjects v1.0`r`nStarted: $(Get-Date)`r`nDryRun: $DryRun`r`n`r`n",
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
# Invoke-GraphGetAllPages
# Bulk paginated GET with PS 5.1-compatible 429 retry + exponential backoff.
# -----------------------------------------------------------------------------
function Invoke-GraphGetAllPages {
    param (
        [string]$InitialUri,
        [string]$AccessToken,
        [string]$Label,
        [int]$MaxRetries = 5
    )
    $Headers    = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $AllRecords = [System.Collections.Generic.List[PSObject]]::new()
    $Uri        = $InitialUri
    $Page       = 0
    $Total      = 0

    Write-Log "Pulling: $Label" -Level INFO

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
                Write-Log "  Page $Page - $Count records (total: $Total)" -Level INFO
                foreach ($rec in $r.value) { $AllRecords.Add($rec) }
                $Uri     = $r.'@odata.nextLink'
                $Success = $true
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
                    }
                    else { Write-Log "  429 persisted after $MaxRetries attempts. Skipping page." -Level WARN; $Uri = $null; $Success = $true }
                }
                else { Write-Log "  Page $Page failed - HTTP $Code" -Level ERROR; $Uri = $null; $Success = $true }
            }
        } while (-not $Success -and $Attempt -lt $MaxRetries)

    } while ($Uri)

    Write-Log "$Label - $Total total records." -Level SUCCESS
    return $AllRecords.ToArray()
}


# -----------------------------------------------------------------------------
# Get-AzureADDevice
# Looks up Azure AD device by azureADDeviceId (GUID from Intune record).
# Returns device object or $null if not found / no permission.
# Used for reporting only - no delete attempted.
# -----------------------------------------------------------------------------
function Get-AzureADDevice {
    param ([string]$AzureADDeviceId, [string]$AccessToken)
    if ([string]::IsNullOrWhiteSpace($AzureADDeviceId) -or $AzureADDeviceId -eq "N/A") { return $null }
    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $Uri     = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$AzureADDeviceId'&`$select=id,displayName,deviceId,operatingSystem,isCompliant,isManaged"
    try {
        $r = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
        if ($r.value -and $r.value.Count -gt 0) { return $r.value[0] }
        return $null
    }
    catch { return $null }
}


# -----------------------------------------------------------------------------
# Invoke-GraphDelete
# Single DELETE request. Returns $true on success (204), $false on failure.
# -----------------------------------------------------------------------------
function Invoke-GraphDelete {
    param ([string]$Uri, [string]$AccessToken)
    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    try {
        Invoke-RestMethod -Method DELETE -Uri $Uri -Headers $Headers -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        $Code = $_.Exception.Response.StatusCode.value__
        throw "HTTP $Code : $($_.Exception.Message)"
    }
}

#endregion ----------------------------------------------------------------------


#region --- MAIN ----------------------------------------------------------------

# Banner
Write-Host ""
if ($DryRun) {
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Remove-IntuneDeviceObjects  |  DRY RUN - NO DELETES          " -ForegroundColor Cyan
    Write-Host "  Sethu Kumar B                                                 " -ForegroundColor Cyan
    Write-Host "  Review CSV output then set DryRun = false to execute.         " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}
else {
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  Remove-IntuneDeviceObjects  |  LIVE - DELETES WILL EXECUTE   " -ForegroundColor Red
    Write-Host "  Sethu Kumar B                                                 " -ForegroundColor Red
    Write-Host "  !! DEVICE RECORDS WILL BE PERMANENTLY DELETED !!             " -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
}
Write-Log "" -Level BLANK
Write-Log "Mode         : $(if ($DryRun) {'DRY RUN - no deletes'} else {'LIVE - deletes will execute'})" `
          -Level $(if ($DryRun) {"INFO"} else {"WARN"})
Write-Log "Input file   : $InputPath"         -Level INFO
Write-Log "Output CSV   : $OutputFile"        -Level INFO
Write-Log "Log file     : $($script:LogFile)" -Level INFO
Write-Log "Transcript   : $TranscriptFile"    -Level INFO
Write-Log "" -Level BLANK


# -- Step 1: Read serial numbers ------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 - Reading Input File" -Level INFO
Write-Log "==========================================================" -Level SECTION

if (-not (Test-Path $InputPath)) {
    Write-Log "Input file not found: $InputPath" -Level ERROR
    Write-Log "Create input.txt with one serial number per line." -Level ERROR
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

$Serials = [System.Collections.Generic.List[string]]::new()
foreach ($Line in (Get-Content -Path $InputPath -Encoding UTF8)) {
    $T = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($T) -or $T.StartsWith("#")) { continue }
    $Serials.Add($T)
}

Write-Log "Serials loaded: $($Serials.Count)" -Level $(if ($Serials.Count -gt 0) {"SUCCESS"} else {"WARN"})
if ($Serials.Count -eq 0) {
    Write-Log "No serials found. Exiting." -Level WARN
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}
foreach ($s in $Serials) { Write-Log "  -> $s" -Level INFO }
Write-Log "" -Level BLANK


# -- Step 2: Authenticate ------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 2 - Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Token = Get-GraphToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret


# -- Step 3: Bulk pull Intune managed devices into hashtable -------------------
# $filter on serialNumber causes HTTP 500 - bulk pull + client-side lookup.
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 - Building Intune Device Lookup Table (Windows only)" -Level INFO
Write-Log "==========================================================" -Level SECTION

$IntuneUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
             "?`$filter=operatingSystem eq 'Windows'" +
             "&`$select=id,serialNumber,deviceName,manufacturer,model," +
             "azureADDeviceId,userPrincipalName,operatingSystem&`$top=1000"

$AllIntune  = Invoke-GraphGetAllPages -InitialUri $IntuneUri -AccessToken $Token `
              -Label "Intune Windows managed devices" -MaxRetries $MaxRetries

# Store ALL devices per serial as a list - one serial can have multiple
# Intune records (duplicate enrollments with different device names/IDs)
$IntuneBySerial = @{}
foreach ($d in $AllIntune) {
    if (-not [string]::IsNullOrWhiteSpace($d.serialNumber)) {
        $Key = $d.serialNumber.ToLower().Trim()
        if (-not $IntuneBySerial.ContainsKey($Key)) {
            $IntuneBySerial[$Key] = [System.Collections.Generic.List[PSObject]]::new()
        }
        $IntuneBySerial[$Key].Add($d)
    }
}
$TotalIntuneRecords = ($IntuneBySerial.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Log "Intune lookup table: $($IntuneBySerial.Count) unique serials, $TotalIntuneRecords total records." -Level SUCCESS
Write-Log "" -Level BLANK


# -- Step 4: Bulk pull Autopilot devices into hashtable -----------------------
# No $select - causes HTTP 500 combined with $top on this endpoint.
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 - Building Autopilot Device Lookup Table" -Level INFO
Write-Log "==========================================================" -Level SECTION

$APUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities" +
         "?`$top=1000"

$AllAP = Invoke-GraphGetAllPages -InitialUri $APUri -AccessToken $Token `
         -Label "Autopilot device identities" -MaxRetries $MaxRetries

# Store ALL Autopilot records per serial
$APBySerial = @{}
foreach ($ap in $AllAP) {
    if (-not [string]::IsNullOrWhiteSpace($ap.serialNumber)) {
        $Key = $ap.serialNumber.ToLower().Trim()
        if (-not $APBySerial.ContainsKey($Key)) {
            $APBySerial[$Key] = [System.Collections.Generic.List[PSObject]]::new()
        }
        $APBySerial[$Key].Add($ap)
    }
}
$TotalAPRecords = ($APBySerial.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Log "Autopilot lookup table: $($APBySerial.Count) unique serials, $TotalAPRecords total records." -Level SUCCESS
Write-Log "" -Level BLANK


# -- Step 5: Process each serial -----------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 5 - Processing Deletions" -Level INFO
Write-Log "==========================================================" -Level SECTION

if ($DryRun) {
    Write-Log "DRY RUN active - no DELETE calls will be made." -Level WARN
} else {
    Write-Log "LIVE mode - DELETE calls will execute." -Level WARN
}
Write-Log "" -Level BLANK

$Results = [System.Collections.Generic.List[PSObject]]::new()
$Counter  = 0
$Total    = $Serials.Count

$DeletedIntune    = 0
$DeletedAutopilot = 0
$NotFoundCount    = 0
$FailedCount      = 0

foreach ($Serial in $Serials) {
    $Counter++
    $SerialKey = $Serial.ToLower().Trim()

    # Get ALL Intune and Autopilot records for this serial
    $IntuneDevices = if ($IntuneBySerial.ContainsKey($SerialKey)) { $IntuneBySerial[$SerialKey] } else { [System.Collections.Generic.List[PSObject]]::new() }
    $APDevices     = if ($APBySerial.ContainsKey($SerialKey))     { $APBySerial[$SerialKey] }     else { [System.Collections.Generic.List[PSObject]]::new() }

    $IntuneCount = $IntuneDevices.Count
    $APCount     = $APDevices.Count

    Write-Log "  [$Counter/$Total] Serial: $Serial" -Level INFO
    Write-Log "    Intune records   : $IntuneCount$(if ($IntuneCount -gt 1) {' *** DUPLICATES FOUND ***'} else {''})" `
              -Level $(if ($IntuneCount -gt 1) {"WARN"} elseif ($IntuneCount -eq 1) {"INFO"} else {"WARN"})
    Write-Log "    Autopilot records: $APCount$(if ($APCount -gt 1) {' *** DUPLICATES FOUND ***'} else {''})" `
              -Level $(if ($APCount -gt 1) {"WARN"} elseif ($APCount -eq 1) {"INFO"} else {"WARN"})

    # Get shared device info from first available record
    $Manufacturer = "N/A"; $Model = "N/A"
    if ($IntuneDevices.Count -gt 0) {
        $Manufacturer = if ($IntuneDevices[0].manufacturer) { [string]$IntuneDevices[0].manufacturer } else { "N/A" }
        $Model        = if ($IntuneDevices[0].model)        { [string]$IntuneDevices[0].model }        else { "N/A" }
    } elseif ($APDevices.Count -gt 0) {
        $Manufacturer = if ($APDevices[0].manufacturer) { [string]$APDevices[0].manufacturer } else { "N/A" }
        $Model        = if ($APDevices[0].model)        { [string]$APDevices[0].model }        else { "N/A" }
    }

    # -- Process each Intune record (handles 1 or many duplicates) ------------
    $IntuneDupeIdx = 0
    if ($IntuneDevices.Count -eq 0) {
        Write-Log "    [Intune] NOT FOUND in managed devices" -Level WARN
        $NotFoundCount++
    }

    foreach ($IntuneDevice in $IntuneDevices) {
        $IntuneDupeIdx++
        $IntuneId    = [string]$IntuneDevice.id
        $DeviceName  = if ($IntuneDevice.deviceName)      { [string]$IntuneDevice.deviceName }      else { "N/A" }
        $AzureADId   = if ($IntuneDevice.azureADDeviceId) { [string]$IntuneDevice.azureADDeviceId } else { "N/A" }
        $DupeLabel   = if ($IntuneDevices.Count -gt 1) { " [Duplicate $IntuneDupeIdx of $IntuneCount]" } else { "" }

        $IntuneStatus = ""; $IntuneNote = ""

        if ($DryRun) {
            Write-Log "    [Intune$DupeLabel] FOUND $DeviceName ($IntuneId) - DRY RUN" -Level WARN
            $IntuneStatus = "DRY RUN"
            $IntuneNote   = "Would delete - set DryRun = false to execute"
            $DeletedIntune++
        }
        else {
            try {
                $Uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$IntuneId"
                Invoke-GraphDelete -Uri $Uri -AccessToken $Token | Out-Null
                Write-Log "    [Intune$DupeLabel] DELETED $DeviceName ($IntuneId)" -Level SUCCESS
                $IntuneStatus = "DELETED"
                $IntuneNote   = "Successfully deleted"
                $DeletedIntune++
            }
            catch {
                Write-Log "    [Intune$DupeLabel] FAILED $DeviceName ($IntuneId) - $_" -Level ERROR
                $IntuneStatus = "FAILED"
                $IntuneNote   = [string]$_
                $FailedCount++
            }
            Start-Sleep -Seconds 1
        }

        # One CSV row per Intune record
        $Results.Add([PSCustomObject]@{
            SerialNumber          = $Serial
            DeviceName            = $DeviceName
            Manufacturer          = $Manufacturer
            Model                 = $Model
            RecordType            = "Intune$(if ($IntuneDevices.Count -gt 1) {" (Duplicate $IntuneDupeIdx/$IntuneCount)"} else {''})"
            IntuneDeviceID        = $IntuneId
            IntuneDeleteStatus    = $IntuneStatus
            IntuneDeleteNote      = $IntuneNote
            AutopilotDeviceID     = "N/A"
            AutopilotDeleteStatus = "N/A"
            AutopilotDeleteNote   = "N/A"
            AzureADDeviceID       = $AzureADId
            AzureADStatus         = "SKIPPED - no permission (delete manually from Entra portal)"
            OverallResult         = $IntuneStatus
            Timestamp             = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }

    if (-not $DryRun -and $IntuneDevices.Count -gt 0) { Start-Sleep -Seconds 2 }

    # -- Azure AD lookup (report only - no delete) ----------------------------
    # Look up Azure AD device object for each Intune record.
    # Requires Device.Read.All on the app registration.
    # If permission not granted, lookup returns null and is logged as SKIPPED.
    # Either way no delete is attempted - Azure AD is reporting only.
    $AzureADFoundCount = 0
    foreach ($IntuneDevice in $IntuneDevices) {
        $AzureADId = if ($IntuneDevice.azureADDeviceId) { [string]$IntuneDevice.azureADDeviceId } else { "N/A" }
        $DevName   = if ($IntuneDevice.deviceName)      { [string]$IntuneDevice.deviceName }      else { "N/A" }
        if ($AzureADId -eq "N/A") {
            $AADNote = "No Azure AD device ID on Intune record"
        } else {
            $AADObj = Get-AzureADDevice -AzureADDeviceId $AzureADId -AccessToken $Token
            if ($AADObj) {
                $AzureADFoundCount++
                $AADNote = "Device exists in Azure AD - delete manually from Entra portal"
                Write-Log "    [AzureAD] FOUND $DevName ($AzureADId) - SKIPPED (no permission)" -Level INFO
            } else {
                $AADNote = "Device not found in Azure AD or no read permission"
                Write-Log "    [AzureAD] NOT FOUND / no read permission ($AzureADId)" -Level INFO
            }
        }
        $Results.Add([PSCustomObject]@{
            SerialNumber          = $Serial
            DeviceName            = $DevName
            Manufacturer          = $Manufacturer
            Model                 = $Model
            RecordType            = "Azure AD"
            IntuneDeviceID        = if ($IntuneDevice.id) { [string]$IntuneDevice.id } else { "N/A" }
            IntuneDeleteStatus    = "N/A"
            IntuneDeleteNote      = "N/A"
            AutopilotDeviceID     = "N/A"
            AutopilotDeleteStatus = "N/A"
            AutopilotDeleteNote   = "N/A"
            AzureADDeviceID       = $AzureADId
            AzureADStatus         = "SKIPPED - no delete permission. $AADNote"
            OverallResult         = "SKIPPED"
            Timestamp             = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }

    # -- Process each Autopilot record -----------------------------------------
    $APDupeIdx = 0
    if ($APDevices.Count -eq 0) {
        Write-Log "    [Autopilot] NOT FOUND in Autopilot registry" -Level WARN
    }

    foreach ($APDevice in $APDevices) {
        $APDupeIdx++
        $APId      = [string]$APDevice.id
        $APModel   = if ($APDevice.model) { [string]$APDevice.model } else { $Model }
        $DupeLabel = if ($APDevices.Count -gt 1) { " [Duplicate $APDupeIdx of $APCount]" } else { "" }

        $APStatus = ""; $APNote = ""

        if ($DryRun) {
            Write-Log "    [Autopilot$DupeLabel] FOUND $APModel ($APId) - DRY RUN" -Level WARN
            $APStatus = "DRY RUN"
            $APNote   = "Would delete - set DryRun = false to execute"
            $DeletedAutopilot++
        }
        else {
            try {
                $Uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$APId"
                Invoke-GraphDelete -Uri $Uri -AccessToken $Token | Out-Null
                Write-Log "    [Autopilot$DupeLabel] DELETED $APModel ($APId)" -Level SUCCESS
                $APStatus = "DELETED"
                $APNote   = "Successfully deleted"
                $DeletedAutopilot++
            }
            catch {
                Write-Log "    [Autopilot$DupeLabel] FAILED ($APId) - $_" -Level ERROR
                $APStatus = "FAILED"
                $APNote   = [string]$_
                $FailedCount++
            }
            Start-Sleep -Milliseconds 500
        }

        # One CSV row per Autopilot record
        $Results.Add([PSCustomObject]@{
            SerialNumber          = $Serial
            DeviceName            = "N/A"
            Manufacturer          = $Manufacturer
            Model                 = $APModel
            RecordType            = "Autopilot$(if ($APDevices.Count -gt 1) {" (Duplicate $APDupeIdx/$APCount)"} else {''})"
            IntuneDeviceID        = "N/A"
            IntuneDeleteStatus    = "N/A"
            IntuneDeleteNote      = "N/A"
            AutopilotDeviceID     = $APId
            AutopilotDeleteStatus = $APStatus
            AutopilotDeleteNote   = $APNote
            AzureADDeviceID       = "N/A"
            AzureADStatus         = "SKIPPED - no permission"
            OverallResult         = $APStatus
            Timestamp             = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }

    Write-Log "" -Level BLANK
}


# -- Step 6: Export CSV ---------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 6 - Exporting CSV" -Level INFO
Write-Log "==========================================================" -Level SECTION

try {
    $Results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $SizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
    Write-Log "CSV exported." -Level SUCCESS
    Write-Log "  Path : $OutputFile" -Level INFO
    Write-Log "  Rows : $($Results.Count)  |  Size: $SizeMB MB" -Level INFO
}
catch { Write-Log "CSV export failed: $_" -Level ERROR }


# -- Summary --------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor $(if ($DryRun) {"Cyan"} else {"Red"})
Write-Host "  $(if ($DryRun) {'DRY RUN COMPLETE - NO CHANGES MADE'} else {'DELETIONS COMPLETE'})" -ForegroundColor $(if ($DryRun) {"Cyan"} else {"Red"})
Write-Host "================================================================" -ForegroundColor $(if ($DryRun) {"Cyan"} else {"Red"})
# Build per-input-serial duplicate summary
$InputDupeReport = [System.Collections.Generic.List[string]]::new()
foreach ($s in $Serials) {
    $k = $s.ToLower().Trim()
    $iCount = if ($IntuneBySerial.ContainsKey($k)) { $IntuneBySerial[$k].Count } else { 0 }
    $aCount = if ($APBySerial.ContainsKey($k))     { $APBySerial[$k].Count }     else { 0 }
    if ($iCount -gt 1 -or $aCount -gt 1) {
        $InputDupeReport.Add("  $s : Intune=$iCount  Autopilot=$aCount")
    }
}
$AzureADFoundTotal = @($Results | Where-Object { $_.RecordType -eq "Azure AD" -and $_.AzureADStatus -like "*exists*" }).Count
$AzureADRows       = @($Results | Where-Object { $_.RecordType -eq "Azure AD" }).Count

Write-Log "  Mode                   : $(if ($DryRun) {'DRY RUN'} else {'LIVE'})" `
          -Level $(if ($DryRun) {"INFO"} else {"WARN"})
Write-Log "  Total serials          : $Total"             -Level INFO
Write-Log "  Intune deleted         : $DeletedIntune"     -Level $(if ($DeletedIntune    -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  Autopilot deleted      : $DeletedAutopilot"  -Level $(if ($DeletedAutopilot -gt 0) {"SUCCESS"} else {"INFO"})
Write-Log "  Not found (either)     : $NotFoundCount"     -Level $(if ($NotFoundCount    -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  Failures               : $FailedCount"       -Level $(if ($FailedCount      -gt 0) {"ERROR"}   else {"INFO"})
Write-Log "  Azure AD found         : $AzureADFoundTotal of $AzureADRows checked - SKIPPED (no delete permission)" -Level INFO
if ($InputDupeReport.Count -gt 0) {
    Write-Log "  Duplicates in your input:" -Level WARN
    foreach ($line in $InputDupeReport) { Write-Log $line -Level WARN }
}
Write-Log "" -Level BLANK
if ($DryRun) {
    Write-Log "  Review CSV then set DryRun = false to execute deletions." -Level WARN
}
Write-Log "  Output CSV   : $OutputFile"         -Level INFO
Write-Log "  Log file     : $($script:LogFile)"  -Level INFO
Write-Log "  Transcript   : $TranscriptFile"     -Level INFO
Write-Host "================================================================" -ForegroundColor $(if ($DryRun) {"Cyan"} else {"Red"})
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }

#endregion ----------------------------------------------------------------------