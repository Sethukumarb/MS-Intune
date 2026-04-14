#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-WindowsDeviceInventory-Simple.ps1
# Description  : Retrieves all Windows managed devices from Microsoft Intune
#                using the default columns available on the Graph API
#                managedDevices collection endpoint - no per-device enrichment
#                calls, no parallel runspaces, no extra complexity.
#
#                This is the LIGHTWEIGHT version of the Windows inventory.
#                Use this when you need a fast, clean export of the standard
#                Intune device fields. For additional fields (RAM, enrolled-by,
#                last logged on user, etc.) use Get-WindowsDeviceInventory.ps1.
#
#                Default columns exported:
#                  DeviceName, IntuneDeviceID, AzureAD_DeviceID, SerialNumber,
#                  OperatingSystem, FriendlyOSName, OSVersion, OSBuildNumber,
#                  Manufacturer, DeviceModel, PrimaryUser_UPN,
#                  PrimaryUser_DisplayName, ComplianceState, ManagementState,
#                  ManagementAgent, EnrollmentType, OwnerType, IsEncrypted,
#                  EnrolledDateTime, LastSyncDateTime, DaysSinceLastSync
#
#                Key behaviours:
#                  - Uses v1.0 endpoint (stable - no beta dependency)
#                  - $filter only on collection (no $select - avoids HTTP 400)
#                  - Full pagination via @odata.nextLink (all devices retrieved)
#                  - FriendlyOSName derived from OS build number
#                  - All output saved to $PSScriptRoot by default
#                  - Log file written alongside CSV in $PSScriptRoot
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-03-27
# Last Modified: 2026-03-27
#
# Requirements :
#   - Azure AD App Registration (READ-ONLY recommended)
#   - Graph API Application Permissions (admin consent granted):
#       DeviceManagementManagedDevices.Read.All   - Intune device inventory
#   - PowerShell 5.1 or later
#   - Network access to:
#       https://login.microsoftonline.com          (token endpoint)
#       https://graph.microsoft.com                (Graph API v1.0)
#
# Change Log   :
#   v1.0 - 2026-03-27 - Sethu Kumar B - Initial release
# ==============================================================================


#region --- CONFIGURATION --- Edit these values before running ----------------

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# -- PAGE SIZE -----------------------------------------------------------------
# Graph API maximum for managedDevices is 1000 per page.
# 1000 gives the fewest number of pages and fastest overall retrieval.
# Reduce to 100 only if you hit throttling issues in a very large environment.
# ------------------------------------------------------------------------------
$PageSize = 1000

#endregion --------------------------------------------------------------------


#region --- FUNCTIONS ---------------------------------------------------------

# ------------------------------------------------------------------------------
# FUNCTION : Write-Log
# Purpose  : Writes a timestamped message simultaneously to the console
#            (colour-coded by level) and to the log file at $script:LogFile.
#            All script output is routed here - the log file is a complete
#            record of every run with no extra effort required.
#
# Levels   : INFO | SUCCESS | WARN | ERROR | SECTION | PROGRESS | BLANK
# Note     : [AllowEmptyString()] is required - PowerShell 5.1 implicitly
#            validates [Mandatory][string] and rejects "" without it.
# ------------------------------------------------------------------------------
function Write-Log {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO","SUCCESS","WARN","ERROR","SECTION","PROGRESS","BLANK")]
        [string]$Level = "INFO"
    )

    $ColourMap = @{
        INFO     = "White"
        SUCCESS  = "Green"
        WARN     = "Yellow"
        ERROR    = "Red"
        SECTION  = "Cyan"
        PROGRESS = "Gray"
        BLANK    = "Gray"
    }

    $PrefixMap = @{
        INFO     = "[INFO]    "
        SUCCESS  = "[SUCCESS] "
        WARN     = "[WARN]    "
        ERROR    = "[ERROR]   "
        SECTION  = "[SECTION] "
        PROGRESS = "[PROGRESS]"
        BLANK    = "          "
    }

    Write-Host $Message -ForegroundColor $ColourMap[$Level]

    if ($script:LogFile) {
        try {
            $Ts      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $LogLine = "$Ts  $($PrefixMap[$Level]) $Message"
            Add-Content -Path $script:LogFile -Value $LogLine -Encoding UTF8
        }
        catch { }
    }
}


# ------------------------------------------------------------------------------
# FUNCTION : Get-GraphAccessToken
# Purpose  : Authenticates to Microsoft Identity Platform using App Registration
#            client credentials (client_id + client_secret).
#            Returns a Bearer access token for all Graph API calls.
# On fail  : Writes error and exits script (no point continuing without a token)
# ------------------------------------------------------------------------------
function Get-GraphAccessToken {
    param (
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    $TokenUrl = "https://login.microsoftonline.com/" + $TenantId + "/oauth2/v2.0/token"

    $Body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }

    try {
        Write-Log "[AUTH] Requesting access token from Microsoft Identity Platform..." -Level SECTION
        $Response = Invoke-RestMethod -Method POST -Uri $TokenUrl -Body $Body `
                    -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Write-Log "[AUTH] Access token acquired successfully." -Level SUCCESS
        Write-Log "" -Level BLANK
        return $Response.access_token
    }
    catch {
        Write-Log "[AUTH] Authentication failed: $_" -Level ERROR
        exit 1
    }
}


# ------------------------------------------------------------------------------
# FUNCTION : Invoke-GraphGetAllPages
# Purpose  : Executes a GET request to a Graph API URI and automatically
#            follows every @odata.nextLink page until all records are collected.
#
#            Graph API returns a maximum of 1000 records per response.
#            Without following nextLink, only the first page is retrieved -
#            giving a false and incomplete inventory count.
#
# Returns  : Flat [array] of all result objects across all pages.
# ------------------------------------------------------------------------------
function Invoke-GraphGetAllPages {
    param (
        [Parameter(Mandatory)][string]$InitialUri,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$EntityLabel
    )

    $Headers = @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    $AllRecords = [System.Collections.Generic.List[PSObject]]::new()
    $CurrentUri = $InitialUri
    $PageNumber = 0
    $TotalSoFar = 0

    Write-Log "[QUERY] Fetching $EntityLabel - following all pages..." -Level SECTION

    do {
        $PageNumber++
        try {
            $Response    = Invoke-RestMethod -Method GET -Uri $CurrentUri `
                           -Headers $Headers -ErrorAction Stop
            $PageCount   = $Response.value.Count
            $TotalSoFar += $PageCount

            $PageMsg = "  Page " + ("{0,3}" -f $PageNumber) + `
                       "  |  " + ("{0,5}" -f $PageCount) + " records this page" + `
                       "  |  Running total: $TotalSoFar"
            Write-Log $PageMsg -Level PROGRESS

            foreach ($Item in $Response.value) { $AllRecords.Add($Item) }

            $CurrentUri = $Response.'@odata.nextLink'
        }
        catch {
            Write-Log "  Page $PageNumber failed: $_" -Level ERROR
            $CurrentUri = $null
        }
    } while ($CurrentUri)

    Write-Log "[QUERY] Done - $TotalSoFar total records across $PageNumber page(s)." -Level SUCCESS
    Write-Log "" -Level BLANK

    return $AllRecords.ToArray()
}


# ------------------------------------------------------------------------------
# FUNCTION : ConvertTo-FriendlyOSName
# Purpose  : Maps a Windows OS build version string (e.g. "10.0.22631.3447")
#            to a human-readable release name (e.g. "Windows 11 23H2").
#            Used to populate the FriendlyOSName column in the CSV output.
#
# Logic    : Extracts the 5-digit build number from the version string and
#            compares it against known Windows release build thresholds.
#            Falls back to "Windows (Build XXXXX)" for unrecognised builds.
# ------------------------------------------------------------------------------
function ConvertTo-FriendlyOSName {
    param ([string]$OSVersion)

    if ([string]::IsNullOrWhiteSpace($OSVersion)) { return "Unknown" }

    $BuildNumber = 0
    if ($OSVersion -match "10\.0\.(\d+)") {
        $BuildNumber = [int]$Matches[1]
    }
    elseif ($OSVersion -match "^(\d+)$") {
        $BuildNumber = [int]$OSVersion
    }

    if ($BuildNumber -ge 28000) { return "Windows 11 26H2" }
    if ($BuildNumber -ge 26200) { return "Windows 11 25H2" }
    if ($BuildNumber -ge 26100) { return "Windows 11 24H2" }
    if ($BuildNumber -ge 22631) { return "Windows 11 23H2" }
    if ($BuildNumber -ge 22621) { return "Windows 11 22H2" }
    if ($BuildNumber -ge 22000) { return "Windows 11 21H2" }
    if ($BuildNumber -ge 19045) { return "Windows 10 22H2" }
    if ($BuildNumber -ge 19044) { return "Windows 10 21H2" }
    if ($BuildNumber -ge 19043) { return "Windows 10 21H1" }
    if ($BuildNumber -ge 19042) { return "Windows 10 20H2" }
    if ($BuildNumber -ge 19041) { return "Windows 10 2004" }
    if ($BuildNumber -ge 18363) { return "Windows 10 1909" }
    if ($BuildNumber -ge 18362) { return "Windows 10 1903" }
    if ($BuildNumber -ge 17763) { return "Windows 10 1809" }
    if ($BuildNumber -ge 17134) { return "Windows 10 1803" }
    if ($BuildNumber -ge 16299) { return "Windows 10 1709" }
    if ($BuildNumber -ge 15063) { return "Windows 10 1703" }
    if ($BuildNumber -ge 14393) { return "Windows 10 1607" }
    if ($BuildNumber -ge 10586) { return "Windows 10 1511" }
    if ($BuildNumber -ge 10240) { return "Windows 10 1507" }
    if ($BuildNumber -ge 20348) { return "Windows Server 2022" }
    if ($BuildNumber -ge 17763) { return "Windows Server 2019" }
    if ($BuildNumber -ge 14393) { return "Windows Server 2016" }
    if ($BuildNumber -gt 0)     { return "Windows (Build $BuildNumber)" }
    return "Unknown"
}


# ------------------------------------------------------------------------------
# FUNCTION : ConvertTo-FriendlyDate
# Purpose  : Formats an ISO 8601 datetime string into a clean local-time string.
#            Returns "Never" for the Graph API sentinel "0001-01-01T00:00:00Z"
#            which means the field has never been set.
#            Returns "N/A" for null or empty values.
# ------------------------------------------------------------------------------
function ConvertTo-FriendlyDate {
    param ([string]$DateString)

    if ([string]::IsNullOrWhiteSpace($DateString)) { return "N/A" }
    if ($DateString -like "0001-01-01*")            { return "Never" }

    try {
        $dt = [datetime]::Parse($DateString, $null,
              [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch { return $DateString }
}


# ------------------------------------------------------------------------------
# FUNCTION : ConvertTo-FriendlyEnrollmentType
# Purpose  : Maps Graph API deviceEnrollmentType raw enum values to readable
#            display strings so the CSV is self-explanatory without lookups.
# ------------------------------------------------------------------------------
function ConvertTo-FriendlyEnrollmentType {
    param ([string]$Value)

    $Map = @{
        "userEnrollment"                   = "User Enrollment (BYOD)"
        "deviceEnrollmentManager"          = "Device Enrollment Manager (DEM)"
        "azureDomainJoined"                = "Azure AD Joined"
        "userEnrollmentWithServiceAccount" = "User Enrollment with Service Account"
        "deviceEnrollmentProgram"          = "Apple DEP / Autopilot"
        "windowsAutoEnrollment"            = "Windows Auto-Enrollment (MDM)"
        "windowsBulkAzureDomainJoin"       = "Bulk Azure AD Join"
        "windowsBulkUserless"              = "Bulk Userless (Autopilot)"
        "windowsCoManagement"              = "Co-Management (Intune + SCCM)"
        "unknownFutureValue"               = "Unknown"
        "unknown"                          = "Unknown"
    }

    if ([string]::IsNullOrWhiteSpace($Value)) { return "N/A" }
    if ($Map.ContainsKey($Value))             { return $Map[$Value] }
    return $Value
}


# ------------------------------------------------------------------------------
# FUNCTION : Get-WindowsDevices
# Purpose  : Builds the Graph API URI for the Windows-filtered managed devices
#            collection and calls Invoke-GraphGetAllPages to retrieve all records.
#
#            IMPORTANT - $filter only, NO $select on this endpoint:
#            The v1.0 managedDevices collection throws HTTP 400 when both
#            $filter and $select are combined. Using $filter alone returns all
#            default fields which is exactly what this script needs.
#            Field selection is done client-side in Shape-DeviceRecord.
# ------------------------------------------------------------------------------
function Get-WindowsDevices {
    param (
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][int]$PageSize
    )

    $Uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices" +
           "?`$filter=operatingSystem eq 'Windows'" +
           "&`$top=$PageSize"

    return Invoke-GraphGetAllPages -InitialUri $Uri `
                                   -AccessToken $AccessToken `
                                   -EntityLabel "Windows managed devices"
}


# ------------------------------------------------------------------------------
# FUNCTION : Shape-DeviceRecord
# Purpose  : Converts a raw Graph API managedDevice object into a clean
#            PSCustomObject with only the default/standard columns, formatted
#            for direct CSV export. Applies friendly name conversions for OS,
#            dates, enrollment type, and compliance state inline.
# ------------------------------------------------------------------------------
function Shape-DeviceRecord {
    param (
        [Parameter(Mandatory)][PSObject]$Device
    )

    $BuildNumber = "N/A"
    if ($Device.osVersion -match "10\.0\.(\d+)") {
        $BuildNumber = $Matches[1]
    }

    $DaysSinceSync = "N/A"
    if ($Device.lastSyncDateTime -and $Device.lastSyncDateTime -notlike "0001*") {
        try {
            $SyncDate      = [datetime]::Parse($Device.lastSyncDateTime, $null,
                             [System.Globalization.DateTimeStyles]::RoundtripKind)
            $DaysSinceSync = [math]::Round(((Get-Date) - $SyncDate).TotalDays, 1)
        }
        catch { $DaysSinceSync = "N/A" }
    }

    return [PSCustomObject]@{

        # -- IDENTITY ----------------------------------------------------------
        "DeviceName"              = if ($Device.deviceName)            { $Device.deviceName }            else { "N/A" }
        "IntuneDeviceID"          = $Device.id
        "AzureAD_DeviceID"        = if ($Device.azureADDeviceId)       { $Device.azureADDeviceId }       else { "N/A" }
        "SerialNumber"            = if ($Device.serialNumber)          { $Device.serialNumber }          else { "N/A" }

        # -- OS ----------------------------------------------------------------
        "OperatingSystem"         = "Windows"
        "FriendlyOSName"          = ConvertTo-FriendlyOSName -OSVersion $Device.osVersion
        "OSVersion"               = if ($Device.osVersion)             { $Device.osVersion }             else { "N/A" }
        "OSBuildNumber"           = $BuildNumber

        # -- HARDWARE ----------------------------------------------------------
        "Manufacturer"            = if ($Device.manufacturer)          { $Device.manufacturer }          else { "N/A" }
        "DeviceModel"             = if ($Device.model)                 { $Device.model }                 else { "N/A" }

        # -- USER --------------------------------------------------------------
        "PrimaryUser_UPN"         = if ($Device.userPrincipalName)     { $Device.userPrincipalName }     else { "No Primary User" }
        "PrimaryUser_DisplayName" = if ($Device.userDisplayName)       { $Device.userDisplayName }       else { "N/A" }

        # -- COMPLIANCE & MANAGEMENT -------------------------------------------
        "ComplianceState"         = if ($Device.complianceState)       { $Device.complianceState }       else { "N/A" }
        "ManagementState"         = if ($Device.managementState)       { $Device.managementState }       else { "N/A" }
        "ManagementAgent"         = if ($Device.managementAgent)       { $Device.managementAgent }       else { "N/A" }

        # -- ENROLLMENT --------------------------------------------------------
        "EnrollmentType"          = ConvertTo-FriendlyEnrollmentType -Value $Device.deviceEnrollmentType
        "OwnerType"               = if ($Device.managedDeviceOwnerType){ $Device.managedDeviceOwnerType } else { "N/A" }

        # -- SECURITY ----------------------------------------------------------
        "IsEncrypted"             = if ($null -ne $Device.isEncrypted) { $Device.isEncrypted }           else { "N/A" }

        # -- TIMESTAMPS --------------------------------------------------------
        "EnrolledDateTime"        = ConvertTo-FriendlyDate -DateString $Device.enrolledDateTime
        "LastSyncDateTime"        = ConvertTo-FriendlyDate -DateString $Device.lastSyncDateTime
        "DaysSinceLastSync"       = $DaysSinceSync
    }
}

#endregion --------------------------------------------------------------------


#region --- MAIN --------------------------------------------------------------

# -- Step 1: Resolve paths and initialise log file ----------------------------
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile     = Join-Path $PSScriptRoot ("Windows_Inventory_Simple_" + $Timestamp + ".csv")
$script:LogFile = Join-Path $PSScriptRoot ("Windows_Inventory_Simple_" + $Timestamp + ".log")

$LogHeader = @"
================================================================================
  Windows Device Inventory (Simple)  |  Sethu Kumar B
  Run started : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Script      : $PSCommandPath
  Output CSV  : $OutputFile
  Log file    : $($script:LogFile)
  Endpoint    : /v1.0/deviceManagement/managedDevices
  OS filter   : Windows (server-side)
================================================================================

"@

try {
    [System.IO.File]::WriteAllText($script:LogFile, $LogHeader,
        [System.Text.Encoding]::UTF8)
}
catch {
    Write-Host "[WARN] Could not create log file: $_" -ForegroundColor Yellow
    $script:LogFile = $null
}

# -- Step 2: Console + log banner ---------------------------------------------
Write-Log "" -Level BLANK
Write-Log "================================================================" -Level SECTION
Write-Log "  Windows Device Inventory (Simple)  |  Sethu Kumar B          " -Level SECTION
Write-Log "================================================================" -Level SECTION
Write-Log "[INFO] Script root     : $PSScriptRoot"       -Level INFO
Write-Log "[INFO] Output CSV      : $OutputFile"         -Level INFO
Write-Log "[INFO] Log file        : $($script:LogFile)"  -Level INFO
Write-Log "[INFO] Timestamp       : $Timestamp"          -Level INFO
Write-Log "[INFO] Page size       : $PageSize"           -Level INFO
Write-Log "[INFO] API endpoint    : v1.0 managedDevices (filter only - no select)" -Level INFO
Write-Log "[INFO] Friendly OS     : Enabled (build number to release name)" -Level INFO
Write-Log "" -Level BLANK

# -- Step 3: Authenticate -----------------------------------------------------
$AccessToken = Get-GraphAccessToken -TenantId $TenantID `
               -ClientId $ClientID -ClientSecret $ClientSecret

# -- Step 4: Retrieve all Windows devices -------------------------------------
Write-Log "------------------------------------------------------------" -Level SECTION
Write-Log "  STEP 1 OF 2  -  Fetching Windows Device Records           " -Level SECTION
Write-Log "------------------------------------------------------------" -Level SECTION

$RawDevices = Get-WindowsDevices -AccessToken $AccessToken -PageSize $PageSize

Write-Log "[INFO] Windows devices retrieved: $($RawDevices.Count)" -Level INFO
Write-Log "" -Level BLANK

if ($RawDevices.Count -eq 0) {
    Write-Log "[WARN] No Windows devices returned. Verify TenantId, ClientId, and API permissions." -Level WARN
    exit 0
}

# -- Step 5: Shape records and export CSV -------------------------------------
Write-Log "------------------------------------------------------------" -Level SECTION
Write-Log "  STEP 2 OF 2  -  Shaping Records and Exporting CSV        " -Level SECTION
Write-Log "------------------------------------------------------------" -Level SECTION

Write-Log "[INFO] Shaping $($RawDevices.Count) records..." -Level INFO

$FinalDevices = [System.Collections.Generic.List[PSObject]]::new()
foreach ($Device in $RawDevices) {
    $FinalDevices.Add((Shape-DeviceRecord -Device $Device))
}

Write-Log "[INFO] Shaping complete." -Level SUCCESS

try {
    $FinalDevices | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $SizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
    Write-Log "[EXPORT] CSV exported successfully." -Level SUCCESS
    Write-Log "         Path  : $OutputFile"        -Level INFO
    Write-Log "         Rows  : $($FinalDevices.Count)   |   Size: $SizeMB MB" -Level INFO
    Write-Log "" -Level BLANK
}
catch {
    Write-Log "[EXPORT] Failed to write CSV: $_" -Level ERROR
    exit 1
}

# -- Step 6: Summary ----------------------------------------------------------
$Win11        = ($FinalDevices | Where-Object { $_.FriendlyOSName -like "Windows 11*"     }).Count
$Win10        = ($FinalDevices | Where-Object { $_.FriendlyOSName -like "Windows 10*"     }).Count
$WinServer    = ($FinalDevices | Where-Object { $_.FriendlyOSName -like "Windows Server*" }).Count
$Other        = $FinalDevices.Count - $Win11 - $Win10 - $WinServer
$Compliant    = ($FinalDevices | Where-Object { $_.ComplianceState -eq "compliant"         }).Count
$NonCompliant = ($FinalDevices | Where-Object { $_.ComplianceState -eq "nonCompliant"      }).Count
$Unknown      = ($FinalDevices | Where-Object { $_.ComplianceState -eq "unknown"           }).Count
$Encrypted    = ($FinalDevices | Where-Object { $_.IsEncrypted -eq $true                  }).Count
$NotEncrypted = ($FinalDevices | Where-Object { $_.IsEncrypted -eq $false                 }).Count
$Stale7       = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 7   }).Count
$Stale30      = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 30  }).Count
$Stale60      = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 60  }).Count
$Stale90      = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 90  }).Count
$Stale120     = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 120 }).Count
$Stale180     = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 180 }).Count
$Stale365     = ($FinalDevices | Where-Object { $_.DaysSinceLastSync -ne "N/A" -and [double]$_.DaysSinceLastSync -gt 365 }).Count

Write-Log "================================================================" -Level SECTION
Write-Log "   SUMMARY                                                      " -Level SECTION
Write-Log "================================================================" -Level SECTION
Write-Log "  Total Windows devices     : $($FinalDevices.Count)"  -Level INFO
Write-Log "" -Level BLANK
Write-Log "  -- OS Breakdown --------------------------------------------------" -Level SECTION
Write-Log "  Windows 11                : $Win11"       -Level INFO
Write-Log "  Windows 10                : $Win10"       -Level INFO
Write-Log "  Windows Server            : $WinServer"   -Level INFO
Write-Log "  Unknown / Other build     : $Other"       -Level WARN
Write-Log "" -Level BLANK
Write-Log "  -- Compliance ----------------------------------------------------" -Level SECTION
Write-Log "  Compliant                 : $Compliant"    -Level SUCCESS
Write-Log "  Non-Compliant             : $NonCompliant" -Level WARN
Write-Log "  Unknown / Grace Period    : $Unknown"      -Level INFO
Write-Log "" -Level BLANK
Write-Log "  -- Encryption ----------------------------------------------------" -Level SECTION
Write-Log "  Encrypted                 : $Encrypted"    -Level SUCCESS
Write-Log "  Not Encrypted             : $NotEncrypted" -Level WARN
Write-Log "" -Level BLANK
Write-Log "  -- Check-In Health -----------------------------------------------" -Level SECTION
Write-Log "  Not synced > 7 days       : $Stale7"   -Level WARN
Write-Log "  Not synced > 30 days      : $Stale30"  -Level WARN
Write-Log "  Not synced > 60 days      : $Stale60"  -Level WARN
Write-Log "  Not synced > 90 days      : $Stale90"  -Level ERROR
Write-Log "  Not synced > 120 days     : $Stale120" -Level ERROR
Write-Log "  Not synced > 180 days     : $Stale180" -Level ERROR
Write-Log "  Not synced > 365 days     : $Stale365" -Level ERROR
Write-Log "" -Level BLANK
Write-Log "  -- Output Files --------------------------------------------------" -Level SECTION
Write-Log "  CSV  : $OutputFile"          -Level INFO
Write-Log "  Log  : $($script:LogFile)"   -Level INFO
Write-Log "================================================================" -Level SECTION
Write-Log "" -Level BLANK

#endregion --------------------------------------------------------------------