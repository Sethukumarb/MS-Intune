#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-DeviceOwnerDetails.ps1
# Description  : Retrieves full device and owner details for one or more devices
#                by serial number. Serial numbers are read from a plain text
#                file in the same folder as this script.
#
#                For each serial number the script queries:
#                  - Intune managed device record (device details, compliance,
#                    enrollment, OS, hardware)
#                  - Intune primary user (UPN, display name)
#                  - Azure AD / Entra ID user profile (department, job title,
#                    office location, phone, city, country)
#                  - Azure AD manager (manager display name and UPN)
#                  - Windows Autopilot registration (group tag, profile,
#                    enrollment state)
#
#                LOOKUP STRATEGY:
#                  Serial number -> Intune managedDevices (bulk pull + hashtable)
#                  -> Primary user UPN -> Azure AD user profile + manager
#                  -> Autopilot device identity (bulk pull + hashtable)
#
#                READ ONLY: This script makes only GET requests.
#                No changes are made to any device, user, or policy.
#
#                INPUT FILE:
#                  SerialNumbers.txt - same folder as this script
#                  One serial number per line. Blank lines and # comments ignored.
#
#                  Example:
#                    5CG114589DQ
#                    5CG8854866A
#                    # Office laptop
#                    5CG14577KPQ
#
#                OUTPUT FILES (saved to $PSScriptRoot):
#                  DeviceOwnerDetails_[timestamp].csv  - full results
#                  DeviceOwnerDetails_[timestamp].log  - run log
#
#                CSV COLUMNS:
#                  -- IDENTITY --
#                  SerialNumber, DeviceName, IntuneDeviceID, AzureAD_DeviceID,
#                  AutopilotDeviceID
#
#                  -- HARDWARE --
#                  Manufacturer, Model, OSPlatform, OSVersion, OSBuildNumber,
#                  FreeStorageGB, TotalStorageGB, PhysicalMemoryGB
#
#                  -- ENROLLMENT --
#                  EnrollmentType, EnrollmentDate, LastSyncDateTime,
#                  DaysSinceLastSync, ComplianceState, ManagementState,
#                  ManagementAgent, JoinType, OwnerType, IsEncrypted,
#                  IsSupervised, AutopilotEnrolled
#
#                  -- AUTOPILOT --
#                  GroupTag, AutopilotProfile, AutopilotEnrollmentState,
#                  AutopilotLastContactedDate
#
#                  -- PRIMARY USER --
#                  PrimaryUser_UPN, PrimaryUser_DisplayName,
#                  PrimaryUser_Department, PrimaryUser_JobTitle,
#                  PrimaryUser_OfficeLocation, PrimaryUser_City,
#                  PrimaryUser_Country, PrimaryUser_Phone,
#                  PrimaryUser_Manager, PrimaryUser_ManagerUPN,
#                  PrimaryUser_AccountEnabled
#
#                  -- STATUS --
#                  LookupStatus, LookupNote
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-04-15
# Last Modified: 2026-04-15
#
# Requirements :
#   - Azure AD App Registration (READ-ONLY recommended)
#   - Graph API Application Permissions (admin consent granted):
#       DeviceManagementManagedDevices.Read.All  - Intune device details
#       DeviceManagementServiceConfig.Read.All   - Autopilot details
#       User.Read.All                            - User profile + manager
#       Directory.Read.All                       - Azure AD device + manager
#   - PowerShell 5.1 or later
#   - TLS 1.2 enabled
#
# Change Log   :
#   v1.0 - 2026-04-15 - Sethu Kumar B - Initial release. Bulk pulls Intune
#                        devices and Autopilot records into hashtables for
#                        fast serial number lookup. Per-user Graph calls for
#                        profile, manager, and department details.
# ==============================================================================


#region --- CONFIGURATION -------------------------------------------------------

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# Input file name - must be in the same folder as this script
$InputFileName = "SerialNumbers.txt"
$InputPath     = Join-Path $PSScriptRoot $InputFileName

#endregion ----------------------------------------------------------------------


#region --- INIT ----------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile     = Join-Path $PSScriptRoot "DeviceOwnerDetails_$Timestamp.csv"
$script:LogFile = Join-Path $PSScriptRoot "DeviceOwnerDetails_$Timestamp.log"

#endregion ----------------------------------------------------------------------


#region --- FUNCTIONS -----------------------------------------------------------

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


# -----------------------------------------------------------------------------
# Get-GraphToken
# -----------------------------------------------------------------------------
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
# Follows @odata.nextLink until all records are retrieved.
# Returns a flat array of all objects.
# Includes 429 retry with Retry-After backoff.
# -----------------------------------------------------------------------------
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

    Write-Log "Pulling $Label..." -Level INFO

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
                if ($Code -eq 429 -and $Attempt -lt $MaxRetries) {
                    $Wait = 30
                    try { $Wait = [int]$_.Exception.Response.Headers["Retry-After"] } catch { }
                    $Wait += Get-Random -Minimum 1 -Maximum 5
                    Write-Log "  429 throttled - waiting ${Wait}s (retry $Attempt/$MaxRetries)..." -Level WARN
                    Start-Sleep -Seconds $Wait
                }
                else {
                    Write-Log "  Page $Page failed - HTTP $Code : $_" -Level ERROR
                    $Uri     = $null
                    $Success = $true
                }
            }
        } while (-not $Success -and $Attempt -lt $MaxRetries)
    } while ($Uri)

    Write-Log "$Label complete - $Total total records." -Level SUCCESS
    return $AllRecords.ToArray()
}


# -----------------------------------------------------------------------------
# Invoke-GraphGet
# Single GET request (no pagination). Returns response object or $null.
# Used for per-user calls (profile, manager).
# -----------------------------------------------------------------------------
function Invoke-GraphGet {
    param ([string]$Uri, [string]$AccessToken)
    $Headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    try {
        return Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        $Code = $_.Exception.Response.StatusCode.value__
        if ($Code -eq 404) { return $null }
        Write-Log "  GET failed ($Code): $Uri" -Level WARN
        return $null
    }
}


# -----------------------------------------------------------------------------
# Format-Date
# Formats ISO 8601 date to readable local time. Returns "Never" for zero dates.
# -----------------------------------------------------------------------------
function Format-Date {
    param ([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString)) { return "N/A" }
    if ($DateString -like "0001-01-01*") { return "Never" }
    try {
        $dt = [datetime]::Parse($DateString, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch { return $DateString }
}


# -----------------------------------------------------------------------------
# Get-DaysSince
# Calculates days since a given ISO date string.
# -----------------------------------------------------------------------------
function Get-DaysSince {
    param ([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString) -or $DateString -like "0001*") { return "N/A" }
    try {
        $dt = [datetime]::Parse($DateString, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return [math]::Round(((Get-Date) - $dt).TotalDays, 1)
    }
    catch { return "N/A" }
}


# -----------------------------------------------------------------------------
# ConvertTo-GB
# Converts bytes to GB rounded to 2 decimal places.
# -----------------------------------------------------------------------------
function ConvertTo-GB {
    param ([object]$Bytes)
    if (-not $Bytes -or $Bytes -eq 0) { return "N/A" }
    try { return [math]::Round([double]$Bytes / 1GB, 2) }
    catch { return "N/A" }
}


# -----------------------------------------------------------------------------
# Get-FriendlyEnrollmentType
# Maps Graph API deviceEnrollmentType to readable string.
# -----------------------------------------------------------------------------
function Get-FriendlyEnrollmentType {
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
    if ($Map.ContainsKey($Value)) { return $Map[$Value] }
    return $Value
}


# -----------------------------------------------------------------------------
# Get-JoinType
# Derives the Azure AD join type from the device's joinType or trustType field.
# -----------------------------------------------------------------------------
function Get-JoinType {
    param ([string]$JoinType, [string]$AzureADRegistered)
    if ($JoinType -eq "azureADJoined")         { return "Azure AD Joined" }
    if ($JoinType -eq "hybridAzureADJoined")   { return "Hybrid Azure AD Joined" }
    if ($JoinType -eq "azureADRegistered")     { return "Azure AD Registered (BYOD)" }
    if ($AzureADRegistered -eq "True")         { return "Azure AD Registered (BYOD)" }
    if ([string]::IsNullOrWhiteSpace($JoinType)) { return "N/A" }
    return $JoinType
}


# -----------------------------------------------------------------------------
# Build-EmptyRow
# Returns a PSCustomObject with all columns set to N/A and a status note.
# Used for serials not found in Intune.
# -----------------------------------------------------------------------------
function Build-EmptyRow {
    param ([string]$SerialNumber, [string]$Status, [string]$Note)
    return [PSCustomObject]@{
        # Identity
        SerialNumber           = $SerialNumber
        DeviceName             = "N/A"
        IntuneDeviceID         = "N/A"
        AzureAD_DeviceID       = "N/A"
        AutopilotDeviceID      = "N/A"
        # Hardware
        Manufacturer           = "N/A"
        Model                  = "N/A"
        OSPlatform             = "N/A"
        OSVersion              = "N/A"
        OSBuildNumber          = "N/A"
        FreeStorageGB          = "N/A"
        TotalStorageGB         = "N/A"
        PhysicalMemoryGB       = "N/A"
        # Enrollment
        EnrollmentType         = "N/A"
        EnrollmentDate         = "N/A"
        LastSyncDateTime       = "N/A"
        DaysSinceLastSync      = "N/A"
        ComplianceState        = "N/A"
        ManagementState        = "N/A"
        ManagementAgent        = "N/A"
        JoinType               = "N/A"
        OwnerType              = "N/A"
        IsEncrypted            = "N/A"
        IsSupervised           = "N/A"
        AutopilotEnrolled      = "N/A"
        # Autopilot
        GroupTag               = "N/A"
        AutopilotProfile       = "N/A"
        AutopilotEnrollState   = "N/A"
        AutopilotLastContacted = "N/A"
        # Primary User
        PrimaryUser_UPN              = "N/A"
        PrimaryUser_DisplayName      = "N/A"
        PrimaryUser_Department       = "N/A"
        PrimaryUser_JobTitle         = "N/A"
        PrimaryUser_OfficeLocation   = "N/A"
        PrimaryUser_City             = "N/A"
        PrimaryUser_Country          = "N/A"
        PrimaryUser_Phone            = "N/A"
        PrimaryUser_Manager          = "N/A"
        PrimaryUser_ManagerUPN       = "N/A"
        PrimaryUser_AccountEnabled   = "N/A"
        # Status
        LookupStatus           = $Status
        LookupNote             = $Note
    }
}

#endregion ----------------------------------------------------------------------


#region --- MAIN ----------------------------------------------------------------

# Init log
try {
    [System.IO.File]::WriteAllText($script:LogFile,
        "Get-DeviceOwnerDetails`r`nStarted: $(Get-Date)`r`nInput: $InputPath`r`n`r`n",
        [System.Text.Encoding]::UTF8)
} catch { $script:LogFile = $null }

# Banner
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Device and Owner Details  |  Sethu Kumar B  |  READ ONLY     " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "" -Level BLANK
Write-Log "Script root  : $PSScriptRoot"     -Level INFO
Write-Log "Input file   : $InputPath"        -Level INFO
Write-Log "Output CSV   : $OutputFile"       -Level INFO
Write-Log "Log file     : $($script:LogFile)" -Level INFO
Write-Log "" -Level BLANK


# -- Step 1: Read serial numbers from input file --------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 1 - Reading Input File" -Level INFO
Write-Log "==========================================================" -Level SECTION

if (-not (Test-Path $InputPath)) {
    Write-Log "Input file not found: $InputPath" -Level ERROR
    Write-Log "Create SerialNumbers.txt with one serial number per line." -Level ERROR
    exit 1
}

$RawLines = Get-Content -Path $InputPath -Encoding UTF8 -ErrorAction Stop
$Serials  = [System.Collections.Generic.List[string]]::new()

foreach ($Line in $RawLines) {
    $Trimmed = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($Trimmed)) { continue }
    if ($Trimmed.StartsWith("#"))               { continue }
    $Serials.Add($Trimmed)
}

Write-Log "File loaded - $($RawLines.Count) lines, $($Serials.Count) valid serial(s)." -Level SUCCESS
Write-Log "" -Level BLANK

if ($Serials.Count -eq 0) {
    Write-Log "No serial numbers found. Exiting." -Level WARN
    exit 0
}

foreach ($s in $Serials) { Write-Log "  -> $s" -Level INFO }
Write-Log "" -Level BLANK


# -- Step 2: Authenticate ------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 2 - Authenticating" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Token = Get-GraphToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret


# -- Step 3: Pull all Intune managed devices into a hashtable ------------------
# One bulk pull for all devices - look up by serial client-side.
# $filter on serialNumber is unreliable on this endpoint (HTTP 500 in some tenants).
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 3 - Building Intune Device Lookup Table" -Level INFO
Write-Log "==========================================================" -Level SECTION

$IntuneUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$top=1000"
$AllIntune  = Invoke-GraphGetAllPages -InitialUri $IntuneUri -AccessToken $Token -Label "Intune managed devices"

# Build hashtable keyed by serialNumber (lowercase) for O(1) lookup
$IntuneBySerial = @{}
foreach ($d in $AllIntune) {
    if (-not [string]::IsNullOrWhiteSpace($d.serialNumber)) {
        $Key = $d.serialNumber.ToLower().Trim()
        if (-not $IntuneBySerial.ContainsKey($Key)) {
            $IntuneBySerial[$Key] = $d
        }
    }
}
Write-Log "Intune lookup table: $($IntuneBySerial.Count) unique serial numbers." -Level INFO
Write-Log "" -Level BLANK


# -- Step 4: Pull all Autopilot devices into a hashtable -----------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 4 - Building Autopilot Device Lookup Table" -Level INFO
Write-Log "==========================================================" -Level SECTION

$APUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$top=1000"
$AllAP = Invoke-GraphGetAllPages -InitialUri $APUri -AccessToken $Token -Label "Autopilot device identities"

# Build hashtable keyed by serialNumber (lowercase)
$AutopilotBySerial = @{}
foreach ($ap in $AllAP) {
    if (-not [string]::IsNullOrWhiteSpace($ap.serialNumber)) {
        $Key = $ap.serialNumber.ToLower().Trim()
        if (-not $AutopilotBySerial.ContainsKey($Key)) {
            $AutopilotBySerial[$Key] = $ap
        }
    }
}
Write-Log "Autopilot lookup table: $($AutopilotBySerial.Count) unique serial numbers." -Level INFO
Write-Log "" -Level BLANK


# -- Step 5: Process each serial number ----------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 5 - Processing Serial Numbers" -Level INFO
Write-Log "==========================================================" -Level SECTION

$Results = [System.Collections.Generic.List[PSObject]]::new()
$Counter  = 0
$Total    = $Serials.Count
$Found    = 0
$NotFound = 0

foreach ($Serial in $Serials) {
    $Counter++
    Write-Log "  [$Counter/$Total] Processing: $Serial" -Level INFO

    $SerialKey = $Serial.ToLower().Trim()

    # -- Intune device lookup --------------------------------------------------
    $Device = if ($IntuneBySerial.ContainsKey($SerialKey)) { $IntuneBySerial[$SerialKey] } else { $null }

    if ($null -eq $Device) {
        Write-Log "    NOT FOUND in Intune - checking Autopilot only..." -Level WARN

        # Check if registered in Autopilot even if not Intune-enrolled
        $APDevice = if ($AutopilotBySerial.ContainsKey($SerialKey)) { $AutopilotBySerial[$SerialKey] } else { $null }

        if ($APDevice) {
            Write-Log "    Found in Autopilot (not yet enrolled in Intune)." -Level WARN
            $Row = Build-EmptyRow -SerialNumber $Serial `
                                  -Status "AUTOPILOT ONLY" `
                                  -Note "Registered in Autopilot but not enrolled in Intune"
            $Row.AutopilotDeviceID      = if ($APDevice.id)               { [string]$APDevice.id }               else { "N/A" }
            $Row.Manufacturer           = if ($APDevice.manufacturer)     { [string]$APDevice.manufacturer }     else { "N/A" }
            $Row.Model                  = if ($APDevice.model)            { [string]$APDevice.model }            else { "N/A" }
            $Row.GroupTag               = if ($APDevice.groupTag)         { [string]$APDevice.groupTag }         else { "(empty)" }
            $Row.AutopilotEnrollState   = if ($APDevice.enrollmentState)  { [string]$APDevice.enrollmentState }  else { "N/A" }
            $Row.AutopilotLastContacted = Format-Date $APDevice.lastContactedDateTime
            $Row.PrimaryUser_UPN        = if ($APDevice.userPrincipalName){ [string]$APDevice.userPrincipalName } else { "N/A" }
            $Results.Add($Row)
            $NotFound++
        } else {
            Write-Log "    NOT FOUND in Autopilot either." -Level WARN
            $Results.Add((Build-EmptyRow -SerialNumber $Serial `
                                         -Status "NOT FOUND" `
                                         -Note "Serial number not found in Intune or Autopilot"))
            $NotFound++
        }

        Write-Log "" -Level BLANK
        continue
    }

    $Found++
    Write-Log "    Found: $($Device.deviceName) | $($Device.manufacturer) $($Device.model)" -Level SUCCESS

    # -- Autopilot record ------------------------------------------------------
    $APDevice = if ($AutopilotBySerial.ContainsKey($SerialKey)) { $AutopilotBySerial[$SerialKey] } else { $null }
    if ($APDevice) {
        Write-Log "    Autopilot record found. Group tag: $(if ($APDevice.groupTag) { $APDevice.groupTag } else { '(empty)' })" -Level INFO
    } else {
        Write-Log "    No Autopilot record found for this serial." -Level INFO
    }

    # -- Primary user details --------------------------------------------------
    $UserUPN     = if ($Device.userPrincipalName) { [string]$Device.userPrincipalName } else { "" }
    $UserProfile = $null
    $Manager     = $null

    if (-not [string]::IsNullOrWhiteSpace($UserUPN)) {
        Write-Log "    Fetching user profile: $UserUPN" -Level INFO

        # User profile - select specific fields to keep response lean
        $UserUri     = "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($UserUPN))" +
                       "?`$select=displayName,department,jobTitle,officeLocation,city," +
                       "country,businessPhones,mobilePhone,accountEnabled,id"
        $UserProfile = Invoke-GraphGet -Uri $UserUri -AccessToken $Token

        if ($UserProfile) {
            Write-Log "    User: $($UserProfile.displayName) | $($UserProfile.department) | $($UserProfile.jobTitle)" -Level INFO

            # Manager
            $ManagerUri = "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($UserUPN))/manager" +
                          "?`$select=displayName,userPrincipalName"
            $Manager    = Invoke-GraphGet -Uri $ManagerUri -AccessToken $Token
            if ($Manager) {
                Write-Log "    Manager: $($Manager.displayName)" -Level INFO
            }
        } else {
            Write-Log "    User profile not found for: $UserUPN" -Level WARN
        }
    } else {
        Write-Log "    No primary user assigned to this device." -Level INFO
    }

    # -- Build OS build number -------------------------------------------------
    $BuildNumber = "N/A"
    if ($Device.osVersion -match "10\.0\.(\d+)") { $BuildNumber = $Matches[1] }

    # -- Phone number - prefer mobile, fall back to business ------------------
    $Phone = "N/A"
    if ($UserProfile) {
        if ($UserProfile.mobilePhone) {
            $Phone = [string]$UserProfile.mobilePhone
        } elseif ($UserProfile.businessPhones -and $UserProfile.businessPhones.Count -gt 0) {
            $Phone = [string]$UserProfile.businessPhones[0]
        }
    }

    # -- Build output row ------------------------------------------------------
    $Row = [PSCustomObject]@{

        # IDENTITY
        SerialNumber           = [string]$Device.serialNumber
        DeviceName             = if ($Device.deviceName)          { [string]$Device.deviceName }          else { "N/A" }
        IntuneDeviceID         = if ($Device.id)                  { [string]$Device.id }                  else { "N/A" }
        AzureAD_DeviceID       = if ($Device.azureADDeviceId)     { [string]$Device.azureADDeviceId }     else { "N/A" }
        AutopilotDeviceID      = if ($APDevice -and $APDevice.id) { [string]$APDevice.id }                else { "N/A" }

        # HARDWARE
        Manufacturer           = if ($Device.manufacturer)        { [string]$Device.manufacturer }        else { "N/A" }
        Model                  = if ($Device.model)               { [string]$Device.model }               else { "N/A" }
        OSPlatform             = if ($Device.operatingSystem)     { [string]$Device.operatingSystem }     else { "N/A" }
        OSVersion              = if ($Device.osVersion)           { [string]$Device.osVersion }           else { "N/A" }
        OSBuildNumber          = $BuildNumber
        FreeStorageGB          = ConvertTo-GB $Device.freeStorageSpaceInBytes
        TotalStorageGB         = ConvertTo-GB $Device.totalStorageSpaceInBytes
        PhysicalMemoryGB       = ConvertTo-GB $Device.physicalMemoryInBytes

        # ENROLLMENT
        EnrollmentType         = Get-FriendlyEnrollmentType -Value $Device.deviceEnrollmentType
        EnrollmentDate         = Format-Date $Device.enrolledDateTime
        LastSyncDateTime       = Format-Date $Device.lastSyncDateTime
        DaysSinceLastSync      = Get-DaysSince $Device.lastSyncDateTime
        ComplianceState        = if ($Device.complianceState)     { [string]$Device.complianceState }     else { "N/A" }
        ManagementState        = if ($Device.managementState)     { [string]$Device.managementState }     else { "N/A" }
        ManagementAgent        = if ($Device.managementAgent)     { [string]$Device.managementAgent }     else { "N/A" }
        JoinType               = Get-JoinType -JoinType $Device.joinType -AzureADRegistered $Device.azureADRegistered
        OwnerType              = if ($Device.managedDeviceOwnerType){ [string]$Device.managedDeviceOwnerType } else { "N/A" }
        IsEncrypted            = if ($null -ne $Device.isEncrypted){ [string]$Device.isEncrypted }        else { "N/A" }
        IsSupervised           = if ($null -ne $Device.isSupervised){ [string]$Device.isSupervised }      else { "N/A" }
        AutopilotEnrolled      = if ($null -ne $Device.autopilotEnrolled){ [string]$Device.autopilotEnrolled } else { "N/A" }

        # AUTOPILOT
        GroupTag               = if ($APDevice -and $APDevice.groupTag)         { [string]$APDevice.groupTag }         else { if ($APDevice) { "(empty)" } else { "Not in Autopilot" } }
        AutopilotProfile       = if ($APDevice -and $APDevice.deploymentProfileAssignmentStatus) { [string]$APDevice.deploymentProfileAssignmentStatus } else { "N/A" }
        AutopilotEnrollState   = if ($APDevice -and $APDevice.enrollmentState)  { [string]$APDevice.enrollmentState }  else { "N/A" }
        AutopilotLastContacted = if ($APDevice)                                 { Format-Date $APDevice.lastContactedDateTime } else { "N/A" }

        # PRIMARY USER
        PrimaryUser_UPN            = if ($UserUPN)                                    { $UserUPN }                                                          else { "No Primary User" }
        PrimaryUser_DisplayName    = if ($Device.userDisplayName)                     { [string]$Device.userDisplayName }                                   else { "N/A" }
        PrimaryUser_Department     = if ($UserProfile -and $UserProfile.department)   { [string]$UserProfile.department }                                   else { "N/A" }
        PrimaryUser_JobTitle       = if ($UserProfile -and $UserProfile.jobTitle)     { [string]$UserProfile.jobTitle }                                     else { "N/A" }
        PrimaryUser_OfficeLocation = if ($UserProfile -and $UserProfile.officeLocation){ [string]$UserProfile.officeLocation }                             else { "N/A" }
        PrimaryUser_City           = if ($UserProfile -and $UserProfile.city)         { [string]$UserProfile.city }                                         else { "N/A" }
        PrimaryUser_Country        = if ($UserProfile -and $UserProfile.country)      { [string]$UserProfile.country }                                      else { "N/A" }
        PrimaryUser_Phone          = $Phone
        PrimaryUser_Manager        = if ($Manager -and $Manager.displayName)          { [string]$Manager.displayName }                                      else { "N/A" }
        PrimaryUser_ManagerUPN     = if ($Manager -and $Manager.userPrincipalName)    { [string]$Manager.userPrincipalName }                                else { "N/A" }
        PrimaryUser_AccountEnabled = if ($UserProfile -and $null -ne $UserProfile.accountEnabled){ [string]$UserProfile.accountEnabled }                   else { "N/A" }

        # STATUS
        LookupStatus           = "FOUND"
        LookupNote             = "Device and user details retrieved successfully"
    }

    $Results.Add($Row)
    Write-Log "" -Level BLANK
    Start-Sleep -Milliseconds 200  # Small delay to avoid throttling on per-user calls
}


# -- Step 6: Export CSV ---------------------------------------------------------
Write-Log "==========================================================" -Level SECTION
Write-Log "STEP 6 - Exporting CSV" -Level INFO
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
} else {
    Write-Log "No results to export." -Level WARN
}


# -- Summary -------------------------------------------------------------------
$APOnly = @($Results | Where-Object { $_.LookupStatus -eq "AUTOPILOT ONLY" }).Count

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  COMPLETE - READ ONLY - NO CHANGES MADE                       " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Log "  Total serials processed   : $Total"    -Level INFO
Write-Log "  Found in Intune           : $Found"    -Level $(if ($Found    -gt 0) {"SUCCESS"} else {"WARN"})
Write-Log "  Autopilot only            : $APOnly"   -Level $(if ($APOnly   -gt 0) {"WARN"}    else {"INFO"})
Write-Log "  Not found                 : $NotFound" -Level $(if ($NotFound -gt 0) {"WARN"}    else {"INFO"})
Write-Log "" -Level BLANK
Write-Log "  Output CSV  : $OutputFile"         -Level INFO
Write-Log "  Log file    : $($script:LogFile)"  -Level INFO
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

#endregion ----------------------------------------------------------------------