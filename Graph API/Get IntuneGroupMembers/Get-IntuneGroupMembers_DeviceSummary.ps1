#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-IntuneGroupDeviceSummary.ps1
# Description  : Retrieves full device details for all devices that are members
#                of a specified Azure AD / Entra ID Group, using the Microsoft
#                Graph API BETA endpoint ($entity payload).
#
#                Input  : Azure AD Group ID — configured directly in the script
#                Output : CSV file with full device details (same columns as
#                         Get-IntuneDeviceSummary.ps1)
#
#                Query strategy:
#                  Step 1 — Get all members of the group:
#                             GET /beta/groups/{groupId}/members
#                           Returns Azure AD device objects (not Intune records).
#                           Handles pagination automatically via @odata.nextLink.
#
#                  Step 2 — For each Azure AD device member, find the matching
#                           Intune managed device record using the Azure AD
#                           Device ID:
#                             GET /beta/deviceManagement/managedDevices
#                                 ?$filter=azureADDeviceId eq '{aadDeviceId}'
#                           $select intentionally omitted — combining $filter
#                           and $select on the Intune endpoint causes HTTP 400.
#
#                  Step 3 — Fetch full $entity record by Intune Device ID:
#                             GET /beta/deviceManagement/managedDevices/{id}
#                           Guarantees all fields including usersLoggedOn are
#                           returned (excluded from list responses).
#
#                  Step 4 — Resolve usersLoggedOn userId GUID to UPN:
#                             GET /beta/users/{userId}?$select=userPrincipalName
#
#                  Members that are Users (not devices) are automatically
#                  skipped — only device-type members are processed.
#
#                  Members that are Azure AD devices but have no matching
#                  Intune record (not enrolled) are logged as NOT ENROLLED
#                  and included in the CSV with available fields populated.
#
#                CSV columns exported (identical to Get-IntuneDeviceSummary):
#
#                  IDENTITY   : DeviceName, ManagedDeviceName, FQDN,
#                               SerialNumber, Manufacturer, Model,
#                               ChassisType, BIOSVersion, WiFiMacAddress
#
#                  OS         : OperatingSystem, OSVersion, OSFriendlyName,
#                               SKUFamily
#
#                  USERS      : PrimaryUserDisplayName, PrimaryUserEmail,
#                               PrimaryUserEmailAddress, EnrolledByEmail,
#                               LastLogonEmail, LastLogonDateTime
#
#                  ENROLLMENT : EnrolledDateTime, EnrollmentType,
#                               EnrollmentProfileName, JoinType,
#                               AutopilotEnrolled, AzureADRegistered,
#                               AADRegistered
#
#                  MANAGEMENT : ManagementState, ManagementAgent,
#                               ComplianceState, OwnerType,
#                               DeviceRegistrationState, LastSyncDateTime
#
#                  ENTRA ID   : AzureADDeviceId, AzureActiveDirectoryDeviceId
#
#                  SECURITY   : IsEncrypted
#
#                Output files:
#                  IntuneGroupDeviceSummary_<GroupName>_<timestamp>.csv
#                  <GroupName>_<timestamp>.log
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-03-25
# Last Modified: 2026-03-25
#
# Change Log   :
#   v1.0 - 2026-03-25 - Initial release.
#
# Requirements :
#   App Registration permissions (admin consent granted):
#     DeviceManagementManagedDevices.Read.All  — read Intune device records
#     User.Read.All                            — resolve Last Logon userId to UPN
#     GroupMember.Read.All                     — read group membership
#     Device.Read.All                          — read Azure AD device objects
# ==============================================================================


#region --- CONFIGURATION --- Edit before running ---

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ------------------------------------------------------------------
# GROUP ID
# Azure AD / Entra ID Group Object ID.
# Found in: Azure Portal → Groups → [Group] → Overview → Object ID
# Supports: Security Groups, Microsoft 365 Groups, Dynamic Device Groups
# ------------------------------------------------------------------
$GroupId = ""

# ------------------------------------------------------------------
# OUTPUT FOLDER
# Default : Script’s own folder ($PSScriptRoot) — CSV saved next to the script.
# Override: Replace $PSScriptRoot with any custom path you need.
#           Example: $OutputFolder = "C:\Temp\IntuneGroupDeviceSummary"
# Folder is created automatically if it does not exist.
# ------------------------------------------------------------------
$OutputFolder = $PSScriptRoot

#endregion


#region --- FUNCTIONS ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","HEADER")]
        [string]$Level = "INFO"
    )
    $t        = Get-Date -Format "HH:mm:ss"
    $date     = Get-Date -Format "yyyy-MM-dd"
    $logEntry = ""

    switch ($Level) {
        "HEADER"  {
            $logEntry = "`n[$date $t] [======]  $Message"
            Write-Host "`n$Message" -ForegroundColor Cyan
        }
        "INFO"    {
            $logEntry = "[$date $t] [INFO]    $Message"
            Write-Host "[$t] [INFO]    $Message" -ForegroundColor Gray
        }
        "WARN"    {
            $logEntry = "[$date $t] [WARN]    $Message"
            Write-Host "[$t] [WARN]    $Message" -ForegroundColor Yellow
        }
        "ERROR"   {
            $logEntry = "[$date $t] [ERROR]   $Message"
            Write-Host "[$t] [ERROR]   $Message" -ForegroundColor Red
        }
        "SUCCESS" {
            $logEntry = "[$date $t] [OK]      $Message"
            Write-Host "[$t] [OK]      $Message" -ForegroundColor Green
        }
    }

    # Write to log file if path is set
    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        Add-Content -Path $script:LogFile -Value $logEntry -Encoding UTF8
    }
}


function Get-GraphAccessToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $uri  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    try {
        Write-Log "Requesting access token from Microsoft Identity Platform..." -Level INFO
        $r = Invoke-RestMethod -Method POST -Uri $uri -Body $body `
             -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Write-Log "Access token acquired successfully." -Level SUCCESS
        return $r.access_token
    }
    catch {
        Write-Log "Failed to acquire access token: $_" -Level ERROR
        exit 1
    }
}


# ------------------------------------------------------------------------------
# Paginate all @odata.nextLink pages. Returns flat array of all records.
# ------------------------------------------------------------------------------
function Invoke-GraphGetAllPages {
    param([string]$InitialUri, [string]$AccessToken, [string]$Label)

    $headers    = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $allRecords = [System.Collections.Generic.List[PSObject]]::new()
    $uri        = $InitialUri
    $page       = 0
    $total      = 0

    Write-Log "Querying: $Label" -Level INFO

    do {
        $page++
        try {
            $r      = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
            $count  = $r.value.Count
            $total += $count
            Write-Log "  Page $page — $count records  (running total: $total)" -Level INFO
            foreach ($rec in $r.value) { $allRecords.Add($rec) }
            $uri = $r.'@odata.nextLink'
        }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            $body = ""
            try {
                $s   = $_.Exception.Response.GetResponseStream()
                $rdr = [System.IO.StreamReader]::new($s)
                $body = $rdr.ReadToEnd(); $rdr.Close()
            } catch {}
            Write-Log "Page $page failed — HTTP $code" -Level ERROR
            if ($body) { Write-Log "Response body: $body" -Level ERROR }
            $uri = $null
        }
    } while ($uri)

    Write-Log "Done — $total records across $page page(s)." -Level SUCCESS
    return $allRecords.ToArray()
}


# ------------------------------------------------------------------------------
# Resolve Azure AD User GUID to UPN.
# Returns empty string on failure — never throws.
# ------------------------------------------------------------------------------
function Get-UserUPNById {
    param([string]$UserId, [string]$AccessToken)

    if ([string]::IsNullOrWhiteSpace($UserId)) { return "" }

    $uri = "https://graph.microsoft.com/beta/users/" + $UserId +
           "?`$select=userPrincipalName"
    try {
        $r = Invoke-RestMethod -Uri $uri `
             -Headers @{ Authorization = "Bearer $AccessToken" } `
             -Method GET -ErrorAction Stop
        return $r.userPrincipalName
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Log "  UPN resolve failed for userId '$UserId' — HTTP $code" -Level WARN
        return ""
    }
}


# ------------------------------------------------------------------------------
# Find Intune managed device by Azure AD Device ID.
# The group membership returns Azure AD device objects which contain the
# deviceId (Azure AD Device ID). This is matched to the Intune record via
# azureADDeviceId filter on the managedDevices endpoint.
#
# Returns array of Intune stub records (may be >1 for duplicates).
# Returns empty array if not enrolled in Intune. Never throws.
# ------------------------------------------------------------------------------
function Find-IntuneDeviceByAADId {
    param([string]$AADDeviceId, [string]$AccessToken)

    # $select intentionally omitted — $filter + $select = HTTP 400 on Intune endpoint
    $uri     = "https://graph.microsoft.com/beta/deviceManagement/managedDevices" +
               "?`$filter=azureADDeviceId eq '$AADDeviceId'"
    $headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }

    try {
        $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
        if ($r.value -and $r.value.Count -gt 0) { return $r.value }
        else { return @() }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Log "  Intune lookup failed for AAD DeviceId '$AADDeviceId' — HTTP $code" -Level WARN
        return @()
    }
}


# ------------------------------------------------------------------------------
# Fetch full $entity payload for a single Intune device by its Intune Device ID.
# Required because usersLoggedOn is excluded from list endpoint responses.
# Returns $null on failure — never throws.
# ------------------------------------------------------------------------------
function Get-DeviceEntity {
    param([string]$DeviceId, [string]$AccessToken)

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/" + $DeviceId
    try {
        $r = Invoke-RestMethod -Uri $uri `
             -Headers @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" } `
             -Method GET -ErrorAction Stop
        return $r
    }
    catch {
        Write-Log "  Entity fetch failed for Intune ID '$DeviceId' : $_" -Level WARN
        return $null
    }
}


# ------------------------------------------------------------------------------
# OS Friendly Name helpers
# ------------------------------------------------------------------------------
function Get-WindowsFriendlyName {
    param([string]$OSVersion)
    if ($OSVersion -match '^\d+\.\d+\.(\d+)') { $b = [int]$Matches[1] } else { return "Unknown" }
    switch ($b) {
        10240 { "Win10 1507" }  10586 { "Win10 1511" }  14393 { "Win10 1607" }
        15063 { "Win10 1703" }  16299 { "Win10 1709" }  17134 { "Win10 1803" }
        17763 { "Win10 1809" }  18362 { "Win10 1903" }  18363 { "Win10 1909" }
        19041 { "Win10 2004" }  19042 { "Win10 20H2" }  19043 { "Win10 21H1" }
        19044 { "Win10 21H2" }  19045 { "Win10 22H2" }  22000 { "Win11 21H2" }
        22621 { "Win11 22H2" }  22631 { "Win11 23H2" }  26100 { "Win11 24H2" }
        26200 { "Win11 25H2" }
        default { "Unknown Build ($b)" }
    }
}

function Get-MacOSFriendlyName {
    param([string]$OSVersion)
    if ($OSVersion -match '^(\d+)\.(\d+)') { $maj = [int]$Matches[1]; $min = [int]$Matches[2] }
    else { return "Unknown" }
    switch ($maj) {
        26 { "macOS 26 Tahoe"    }  15 { "macOS 15 Sequoia"  }  14 { "macOS 14 Sonoma"   }
        13 { "macOS 13 Ventura"  }  12 { "macOS 12 Monterey" }  11 { "macOS 11 Big Sur"  }
        10 {
            switch ($min) {
                15 { "macOS 10.15 Catalina"    }  14 { "macOS 10.14 Mojave"      }
                13 { "macOS 10.13 High Sierra" }  12 { "macOS 10.12 Sierra"      }
                default { "macOS 10.$min" }
            }
        }
        default { "Unknown macOS ($maj.$min)" }
    }
}

function Get-OSFriendlyName {
    param([string]$OS, [string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return "N/A" }
    switch -Wildcard ($OS) {
        "Windows" { Get-WindowsFriendlyName -OSVersion $Version }
        "macOS"   { Get-MacOSFriendlyName   -OSVersion $Version }
        default   { $Version }
    }
}


# ------------------------------------------------------------------------------
# Shape full $entity device object into CSV output row.
# Resolves Last Logon userId GUID to UPN.
# ------------------------------------------------------------------------------
function ConvertTo-DeviceRow {
    param([PSObject]$Device, [string]$AccessToken)

    # Resolve Last Logon from usersLoggedOn array
    $lastLogonEmail = ""
    $lastLogonTime  = ""

    if ($Device.usersLoggedOn -and $Device.usersLoggedOn.Count -gt 0) {
        $recent = $Device.usersLoggedOn |
                  Sort-Object { [datetime]$_.lastLogOnDateTime } -Descending |
                  Select-Object -First 1
        $lastLogonTime = $recent.lastLogOnDateTime
        if (-not [string]::IsNullOrWhiteSpace($recent.userId)) {
            $lastLogonEmail = Get-UserUPNById -UserId $recent.userId -AccessToken $AccessToken
        }
    }

    [PSCustomObject]@{
        # --- IDENTITY ---
        DeviceName                   = $Device.deviceName
        ManagedDeviceName            = $Device.managedDeviceName
        FQDN                         = $Device.deviceFullQualifiedDomainName
        SerialNumber                 = $Device.serialNumber
        Manufacturer                 = $Device.manufacturer
        Model                        = $Device.model
        ChassisType                  = $Device.chassisType
        BIOSVersion                  = $Device.systemManagementBIOSVersion
        WiFiMacAddress               = $Device.wiFiMacAddress
        # --- OS ---
        OperatingSystem              = $Device.operatingSystem
        OSVersion                    = $Device.osVersion
        OSFriendlyName               = Get-OSFriendlyName -OS $Device.operatingSystem `
                                                          -Version $Device.osVersion
        SKUFamily                    = $Device.skuFamily
        # --- USERS ---
        PrimaryUserDisplayName       = $Device.userDisplayName
        PrimaryUserEmail             = $Device.userPrincipalName
        PrimaryUserEmailAddress      = $Device.emailAddress
        EnrolledByEmail              = $Device.enrolledByUserPrincipalName
        LastLogonEmail               = $lastLogonEmail
        LastLogonDateTime            = $lastLogonTime
        # --- ENROLLMENT & JOIN ---
        EnrolledDateTime             = $Device.enrolledDateTime
        EnrollmentType               = $Device.deviceEnrollmentType
        EnrollmentProfileName        = $Device.enrollmentProfileName
        JoinType                     = $Device.joinType
        AutopilotEnrolled            = $Device.autopilotEnrolled
        AzureADRegistered            = $Device.azureADRegistered
        AADRegistered                = $Device.aadRegistered
        # --- MANAGEMENT ---
        ManagementState              = $Device.managementState
        ManagementAgent              = $Device.managementAgent
        ComplianceState              = $Device.complianceState
        OwnerType                    = $Device.managedDeviceOwnerType
        DeviceRegistrationState      = $Device.deviceRegistrationState
        LastSyncDateTime             = $Device.lastSyncDateTime
        # --- AZURE AD / ENTRA ID ---
        AzureADDeviceId              = $Device.azureADDeviceId
        AzureActiveDirectoryDeviceId = $Device.azureActiveDirectoryDeviceId
        # --- SECURITY ---
        IsEncrypted                  = $Device.isEncrypted
    }
}


# ------------------------------------------------------------------------------
# NOT ENROLLED placeholder — for Azure AD devices with no Intune record.
# Column layout must match ConvertTo-DeviceRow exactly.
# ------------------------------------------------------------------------------
function New-NotEnrolledRow {
    param([string]$DeviceName, [string]$AADDeviceId)
    [PSCustomObject]@{
        DeviceName                   = $DeviceName
        ManagedDeviceName            = "NOT ENROLLED IN INTUNE"
        FQDN                         = ""
        SerialNumber                 = ""
        Manufacturer                 = ""
        Model                        = ""
        ChassisType                  = ""
        BIOSVersion                  = ""
        WiFiMacAddress               = ""
        OperatingSystem              = ""
        OSVersion                    = ""
        OSFriendlyName               = ""
        SKUFamily                    = ""
        PrimaryUserDisplayName       = ""
        PrimaryUserEmail             = ""
        PrimaryUserEmailAddress      = ""
        EnrolledByEmail              = ""
        LastLogonEmail               = ""
        LastLogonDateTime            = ""
        EnrolledDateTime             = ""
        EnrollmentType               = ""
        EnrollmentProfileName        = ""
        JoinType                     = ""
        AutopilotEnrolled            = ""
        AzureADRegistered            = ""
        AADRegistered                = ""
        ManagementState              = ""
        ManagementAgent              = ""
        ComplianceState              = ""
        OwnerType                    = ""
        DeviceRegistrationState      = ""
        LastSyncDateTime             = ""
        AzureADDeviceId              = $AADDeviceId
        AzureActiveDirectoryDeviceId = $AADDeviceId
        IsEncrypted                  = ""
    }
}

#endregion


#region --- MAIN ---

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Intune Group Device Summary  |  Endpoint Engineering  " -ForegroundColor Cyan
Write-Host "   Graph API : BETA  |  Source: Group Members + Entity   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Validate Group ID
if ([string]::IsNullOrWhiteSpace($GroupId) -or $GroupId -eq "YOUR-GROUP-OBJECT-ID") {
    Write-Log "GroupId is not configured. Set GroupId in the CONFIGURATION region." -Level ERROR
    exit 1
}

# Ensure output folder exists
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    Write-Log "Output folder created: $OutputFolder" -Level INFO
}

# Authenticate
$token = Get-GraphAccessToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret

# =======================================================
# STEP 1 — Get all members of the group
# =======================================================
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   STEP 1 — Fetching Group Members" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Log "Group ID : $GroupId" -Level INFO

# Fetch group display name for output filename
$groupName     = ""
$groupNameSafe = ""
try {
    $groupInfo = Invoke-RestMethod `
        -Uri ("https://graph.microsoft.com/beta/groups/" + $GroupId + "?`$select=displayName") `
        -Headers @{ Authorization = "Bearer $token" } `
        -Method GET -ErrorAction Stop
    $groupName     = $groupInfo.displayName
    $groupNameSafe = $groupName -replace '[\/:*?"<>|]', '_'
    Write-Log "Group Name : $groupName" -Level INFO
}
catch {
    Write-Log "Could not fetch group name — using Group ID in filename." -Level WARN
    $groupName     = $GroupId
    $groupNameSafe = $GroupId.Substring(0, [Math]::Min(8, $GroupId.Length))
}

# ------------------------------------------------------------------
# LOG FILE — named after the group, saved in the script root folder.
# Filename: <GroupName>_<timestamp>.log
# Initialised here after group name is resolved.
# ------------------------------------------------------------------
$logTimestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $PSScriptRoot "${groupNameSafe}_${logTimestamp}.log"

$logHeader = @"
================================================================================
  Script     : Get-IntuneGroupDeviceSummary.ps1
  Group Name : $groupName
  Group ID   : $GroupId
  Started    : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Log File   : $($script:LogFile)
================================================================================
"@
Set-Content -Path $script:LogFile -Value $logHeader -Encoding UTF8
Write-Log "Log file started : $($script:LogFile)" -Level INFO

# Use /members/microsoft.graph.device to return ONLY device-type members
# server-side. Avoids HTTP 400 caused by @odata.type in $select.
# deviceId = Azure AD Device ID used to match the Intune managed device record.
$membersUri = "https://graph.microsoft.com/beta/groups/$GroupId" +
              "/members/microsoft.graph.device" +
              "?`$select=id,displayName,deviceId,operatingSystem&`$top=100"

$deviceMembers = Invoke-GraphGetAllPages -InitialUri $membersUri `
                 -AccessToken $token -Label "Group device members"

if ($deviceMembers.Count -eq 0) {
    Write-Log "No device members found in group '$GroupId'. Verify the Group ID is correct." -Level WARN
    exit 0
}

Write-Log "Device members found : $($deviceMembers.Count)" -Level INFO


# =======================================================
# STEP 2 & 3 — Find Intune record + fetch entity per device
# =======================================================
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   STEP 2 & 3 — Resolving Intune Records" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$results        = [System.Collections.Generic.List[PSObject]]::new()
$notEnrolled    = @()
$duplicateCount = 0
$counter        = 0
$total          = $deviceMembers.Count

foreach ($member in $deviceMembers) {
    $counter++
    $aadDeviceName = $member.displayName
    $aadDeviceId   = $member.deviceId   # Azure AD Device ID (GUID)

    Write-Log "[$counter/$total] Processing: $aadDeviceName" -Level INFO

    # Validate AAD Device ID is present
    if ([string]::IsNullOrWhiteSpace($aadDeviceId)) {
        Write-Log "  No Azure AD Device ID on this member — skipping." -Level WARN
        $notEnrolled += $aadDeviceName
        $results.Add((New-NotEnrolledRow -DeviceName $aadDeviceName -AADDeviceId ""))
        continue
    }

    Write-Log "  AAD Device ID : $aadDeviceId" -Level INFO

    # STEP 2 — Find Intune managed device by Azure AD Device ID
    $intuneDevices = Find-IntuneDeviceByAADId -AADDeviceId $aadDeviceId -AccessToken $token

    if ($intuneDevices.Count -eq 0) {
        Write-Log "  NOT ENROLLED in Intune: $aadDeviceName" -Level WARN
        $notEnrolled += $aadDeviceName
        $results.Add((New-NotEnrolledRow -DeviceName $aadDeviceName -AADDeviceId $aadDeviceId))
        continue
    }

    if ($intuneDevices.Count -gt 1) {
        Write-Log "  DUPLICATE — $($intuneDevices.Count) Intune records for '$aadDeviceName'" -Level WARN
        $duplicateCount++
    }
    else {
        Write-Log "  Intune ID : $($intuneDevices[0].id)" -Level SUCCESS
    }

    # STEP 3 — Fetch full $entity for each matched Intune record
    foreach ($stub in $intuneDevices) {
        Write-Log "  Fetching entity: $($stub.deviceName) [$($stub.id)]" -Level INFO
        $entity = Get-DeviceEntity -DeviceId $stub.id -AccessToken $token

        if ($entity) {
            $row = ConvertTo-DeviceRow -Device $entity -AccessToken $token
            Write-Log "  Done — $($entity.operatingSystem) $($entity.osVersion)" -Level SUCCESS
        }
        else {
            Write-Log "  Entity fetch failed — using stub fallback." -Level WARN
            $row = ConvertTo-DeviceRow -Device $stub -AccessToken $token
        }

        $results.Add($row)
    }

    Start-Sleep -Milliseconds 200
}

# =======================================================
# Export CSV
# =======================================================
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = Join-Path $OutputFolder "IntuneGroupDeviceSummary_${groupNameSafe}_${timestamp}.csv"

try {
    $results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
}
catch {
    Write-Log "Failed to export CSV: $_" -Level ERROR
    exit 1
}

# =======================================================
# Final Summary
# =======================================================
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   COMPLETE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Group Name        : $groupName"                  -ForegroundColor White
Write-Host "  Group ID          : $GroupId"                    -ForegroundColor White
Write-Host "  Device members    : $($deviceMembers.Count)"     -ForegroundColor White
Write-Host "  Records exported  : $($results.Count)"           -ForegroundColor Green
Write-Host "  Not in Intune     : $($notEnrolled.Count)"       -ForegroundColor $(if ($notEnrolled.Count -gt 0) {"Yellow"} else {"White"})
Write-Host "  Duplicates found  : $duplicateCount"             -ForegroundColor $(if ($duplicateCount -gt 0) {"Yellow"} else {"White"})
Write-Host "  Output CSV        :"                             -ForegroundColor White
Write-Host "    $outputFile"                                   -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

if ($notEnrolled.Count -gt 0) {
    Write-Host ""
    Write-Log "Devices NOT enrolled in Intune ($($notEnrolled.Count)):" -Level WARN
    $notEnrolled | ForEach-Object { Write-Log "  - $_" -Level WARN }
}

# Write log file footer
$logFooter = @"

================================================================================
  Completed : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Records   : $($results.Count)
  Log File  : $($script:LogFile)
================================================================================
"@
Add-Content -Path $script:LogFile -Value $logFooter -Encoding UTF8
Write-Log "Log file saved  : $($script:LogFile)" -Level SUCCESS

#endregion