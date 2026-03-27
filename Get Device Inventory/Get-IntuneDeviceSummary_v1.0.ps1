#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-IntuneDeviceSummary.ps1
# Description  : Retrieves a full device summary from Microsoft Intune using
#                the Graph API BETA endpoint ($entity payload).
#
#                Input modes (chosen at runtime):
#                  1. .txt file  — one hostname per line
#                  2. All devices — pulls everything (OS filter applied)
#
#                Query strategy:
#                  Step 1 — Search by hostname using $filter=deviceName eq '<n>'
#                           $select intentionally omitted ($filter + $select on
#                           the Intune endpoint causes HTTP 400 Bad Request).
#
#                  Step 2 — For each matched device, fetch the full $entity
#                           record by device ID:
#                             GET /beta/deviceManagement/managedDevices/{id}
#                           This guarantees every field is returned, including
#                           usersLoggedOn which is excluded from list responses.
#
#                  Step 3 — Resolve usersLoggedOn userId GUID to UPN via
#                             GET /beta/users/{userId}?$select=userPrincipalName
#
#                CSV columns exported (all from $entity payload):
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
# Author       : Sethu Kumar B
# Version      : 1.2
# Created Date : 2026-03-25
# Last Modified: 2026-03-25
#
# Change Log   :
#   v1.0 - 2026-03-25 - Initial release.
#   v1.1 - 2026-03-25 - Fixed HTTP 400: removed $select from file-mode URI.
#   v1.2 - 2026-03-25 - Expanded all $entity fields into CSV. Added per-device
#                        entity fetch (Step 2) to guarantee usersLoggedOn is
#                        populated. Fixed All-mode to avoid $filter+$select.
#                        Updated NOT FOUND placeholder to match full column set.
#
# Requirements :
#   - Azure AD App Registration:
#       DeviceManagementManagedDevices.Read.All
#       User.Read.All
#   - PowerShell 5.1 or later
# ==============================================================================


#region --- CONFIGURATION --- Edit before running ---

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ------------------------------------------------------------------
# INPUT FILE
# Full path to a .txt file with one hostname per line.
# Leave as "" to be prompted at runtime.
# ------------------------------------------------------------------
$InputFile = "C:\temp\Hostnames.txt"

# ------------------------------------------------------------------
# OS FILTER
# Applied in All-devices mode only.
# Hostname file mode returns the device regardless of OS.
#
# Valid values: All, Windows, macOS, iOS, Android, Linux
# Default     : Windows
# ------------------------------------------------------------------
$OSFilter = "Windows"

# ------------------------------------------------------------------
# OUTPUT FOLDER — created automatically if missing.
# ------------------------------------------------------------------
$OutputFolder = "C:\temp\Output"

#endregion


#region --- FUNCTIONS ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","HEADER")]
        [string]$Level = "INFO"
    )
    $t = Get-Date -Format "HH:mm:ss"
    switch ($Level) {
        "HEADER"  { Write-Host "`n$Message" -ForegroundColor Cyan }
        "INFO"    { Write-Host "[$t] [INFO]    $Message" -ForegroundColor Gray }
        "WARN"    { Write-Host "[$t] [WARN]    $Message" -ForegroundColor Yellow }
        "ERROR"   { Write-Host "[$t] [ERROR]   $Message" -ForegroundColor Red }
        "SUCCESS" { Write-Host "[$t] [OK]      $Message" -ForegroundColor Green }
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
# Resolve an Azure AD User GUID to UPN.
# Returns empty string on any failure — never throws.
# ------------------------------------------------------------------------------
function Get-UserUPNById {
    param([string]$UserId, [string]$AccessToken)
    try {
        $r = Invoke-RestMethod `
             -Uri "https://graph.microsoft.com/beta/users/$UserId`?`$select=userPrincipalName" `
             -Headers @{ Authorization = "Bearer $AccessToken" } `
             -Method GET -ErrorAction Stop
        return $r.userPrincipalName
    }
    catch { return "" }
}


# ------------------------------------------------------------------------------
# Fetch the full $entity payload for a single device by Intune Device ID.
#
# WHY THIS IS NEEDED:
#   The list endpoint (/managedDevices?$filter=...) does NOT return every field.
#   Specifically, usersLoggedOn is excluded from list responses by the Intune
#   endpoint regardless of $select usage. Fetching the device directly by its
#   ID returns the complete $entity payload — the same data visible in Graph
#   Explorer — with all fields including usersLoggedOn guaranteed to be present.
# ------------------------------------------------------------------------------
function Get-DeviceEntity {
    param([string]$DeviceId, [string]$AccessToken)
    try {
        $r = Invoke-RestMethod `
             -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$DeviceId" `
             -Headers @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" } `
             -Method GET -ErrorAction Stop
        return $r
    }
    catch {
        Write-Log "  Entity fetch failed for device ID $DeviceId : $_" -Level WARN
        return $null
    }
}


# ------------------------------------------------------------------------------
# Paginate through all @odata.nextLink pages. Returns a flat array of records.
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
                $s    = $_.Exception.Response.GetResponseStream()
                $rdr  = [System.IO.StreamReader]::new($s)
                $body = $rdr.ReadToEnd()
                $rdr.Close()
            } catch {}
            Write-Log "Page $page failed — HTTP $code" -Level ERROR
            if ($body) { Write-Log "Response body: $body" -Level ERROR }
            $uri = $null
        }
    } while ($uri)

    Write-Log "Done — $total records across $page page(s)." -Level SUCCESS
    return $allRecords.ToArray()
}


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
# NOT FOUND placeholder row — column layout must match ConvertTo-DeviceRow exactly.
# ------------------------------------------------------------------------------
function New-NotFoundRow {
    param([string]$Hostname)
    [PSCustomObject]@{
        DeviceName                   = $Hostname
        ManagedDeviceName            = "NOT FOUND"
        
        SerialNumber                 = ""
        Manufacturer                 = ""
        Model                        = ""
        ChassisType                  = ""
        
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
        AzureADDeviceId              = ""
        AzureActiveDirectoryDeviceId = ""
        IsEncrypted                  = ""
        BIOSVersion                  = ""
    }
}


# ------------------------------------------------------------------------------
# Shape a full $entity device object into the CSV output row.
# Input must be a complete entity record from Get-DeviceEntity.
# ------------------------------------------------------------------------------
function ConvertTo-DeviceRow {
    param([PSObject]$Device, [string]$AccessToken)

    # Resolve Last Logged On from usersLoggedOn array.
    # Sort descending by lastLogOnDateTime, take the most recent entry.
    # userId is a GUID — must be resolved to UPN via /beta/users/{id}.
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

#endregion


#region --- MAIN ---

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Intune Device Summary  |  Endpoint Engineering        " -ForegroundColor Cyan
Write-Host "   Graph API : BETA  |  Source: managedDevices/entity    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Ensure output folder exists
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    Write-Log "Output folder created: $OutputFolder" -Level INFO
}

# Validate OS filter
$validOS = @("All","Windows","macOS","iOS","Android","Linux")
if ($OSFilter -notin $validOS) {
    Write-Log "Invalid OSFilter '$OSFilter'. Valid values: $($validOS -join ', ')" -Level ERROR
    exit 1
}

# Authenticate
$token = Get-GraphAccessToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret

# -------------------------------------------------------
# Choose input mode
# -------------------------------------------------------
$mode = ""

if (-not [string]::IsNullOrWhiteSpace($InputFile) -and (Test-Path $InputFile -PathType Leaf)) {
    $mode = "file"
    Write-Log "Input file pre-configured: $InputFile" -Level INFO
}
else {
    Write-Host ""
    Write-Host "  Select input mode:" -ForegroundColor White
    Write-Host "  [1]  Load hostnames from a .txt file" -ForegroundColor Yellow
    Write-Host "  [2]  Pull ALL devices from Intune" -ForegroundColor Yellow
    Write-Host ""
    $choice = (Read-Host "  Enter 1 or 2").Trim()

    switch ($choice) {
        "1" {
            $mode      = "file"
            $InputFile = (Read-Host "  Enter full path to .txt file").Trim().Trim('"')
            if (-not (Test-Path $InputFile -PathType Leaf)) {
                Write-Log "File not found: $InputFile" -Level ERROR
                exit 1
            }
        }
        "2" { $mode = "all" }
        default {
            Write-Log "Invalid choice '$choice'. Exiting." -Level ERROR
            exit 1
        }
    }
}

$results  = [System.Collections.Generic.List[PSObject]]::new()
$notFound = @()

# =======================================================
# MODE: FILE — per-hostname lookup then entity fetch
# =======================================================
if ($mode -eq "file") {

    $hostnames = Get-Content -Path $InputFile -Encoding UTF8 |
                 Where-Object { $_ -match '\S' } |
                 ForEach-Object { $_.Trim().ToUpper() } |
                 Select-Object -Unique

    $total   = $hostnames.Count
    $counter = 0

    Write-Log "===========================================================" -Level HEADER
    Write-Log "Mode : Hostname file  —  $total unique hostname(s)" -Level INFO
    Write-Log "Note : No OS filter in file mode — returns device as-is" -Level INFO
    Write-Log "===========================================================" -Level HEADER

    foreach ($name in $hostnames) {
        $counter++
        Write-Log "[$counter/$total] Searching: $name" -Level INFO

        # STEP 1: Search by deviceName.
        # $select intentionally omitted — $filter + $select = HTTP 400 on Intune endpoint.
        $encoded = [Uri]::EscapeDataString($name)
        $listUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices" +
                   "?`$filter=deviceName eq '$encoded'"
        $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

        try {
            $listResp = Invoke-RestMethod -Method GET -Uri $listUri `
                        -Headers $headers -ErrorAction Stop

            if ($listResp.value -and $listResp.value.Count -gt 0) {

                if ($listResp.value.Count -gt 1) {
                    Write-Log "  DUPLICATE — $($listResp.value.Count) records found for '$name'" -Level WARN
                }
                else {
                    Write-Log "  Match found — Device ID: $($listResp.value[0].id)" -Level SUCCESS
                }

                foreach ($stub in $listResp.value) {

                    # STEP 2: Fetch full $entity by device ID.
                    # Guarantees usersLoggedOn and all other fields are present.
                    Write-Log "  Fetching full entity for: $($stub.deviceName)  [$($stub.id)]" -Level INFO
                    $entity = Get-DeviceEntity -DeviceId $stub.id -AccessToken $token

                    if ($entity) {
                        $row = ConvertTo-DeviceRow -Device $entity -AccessToken $token
                        Write-Log "  Resolved — $($entity.operatingSystem) $($entity.osVersion)" -Level SUCCESS
                    }
                    else {
                        Write-Log "  Entity fetch failed — using list stub as fallback." -Level WARN
                        $row = ConvertTo-DeviceRow -Device $stub -AccessToken $token
                    }

                    $results.Add($row)
                }
            }
            else {
                Write-Log "  NOT FOUND in Intune: $name" -Level WARN
                $notFound += $name
                $results.Add((New-NotFoundRow -Hostname $name))
            }
        }
        catch {
            Write-Log "  Graph API error for '$name': $_" -Level ERROR
            $notFound += $name
            $results.Add((New-NotFoundRow -Hostname $name))
        }

        Start-Sleep -Milliseconds 200
    }

    if ($notFound.Count -gt 0) {
        Write-Host ""
        Write-Log "Hostnames NOT FOUND in Intune ($($notFound.Count)):" -Level WARN
        $notFound | ForEach-Object { Write-Log "  - $_" -Level WARN }
    }
}

# =======================================================
# MODE: ALL — full inventory with client-side OS filter
# =======================================================
elseif ($mode -eq "all") {

    Write-Log "===========================================================" -Level HEADER
    Write-Log "Mode : All devices  |  OS Filter: $OSFilter" -Level INFO
    Write-Log "===========================================================" -Level HEADER

    # No $filter, no $select — avoids HTTP 400. OS filter applied client-side.
    $listUri    = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$top=100"
    $rawDevices = Invoke-GraphGetAllPages -InitialUri $listUri -AccessToken $token `
                  -Label "All Intune managed devices"

    # Client-side OS filter
    if ($OSFilter -ne "All") {
        $rawDevices = $rawDevices | Where-Object { $_.operatingSystem -eq $OSFilter }
        Write-Log "OS filter '$OSFilter' applied. Devices remaining: $($rawDevices.Count)" -Level INFO
    }

    $total   = $rawDevices.Count
    $counter = 0
    Write-Log "Fetching full entity for each device ($total total)..." -Level INFO

    foreach ($stub in $rawDevices) {
        $counter++
        if ($counter % 50 -eq 0 -or $counter -eq $total) {
            Write-Log "  [$counter/$total] Processing..." -Level INFO
        }

        $entity = Get-DeviceEntity -DeviceId $stub.id -AccessToken $token

        if ($entity) {
            $row = ConvertTo-DeviceRow -Device $entity -AccessToken $token
        }
        else {
            $row = ConvertTo-DeviceRow -Device $stub -AccessToken $token
        }

        $results.Add($row)
        Start-Sleep -Milliseconds 100
    }
}

# =======================================================
# Export CSV
# =======================================================
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$osLabel    = if ($mode -eq "file") { "ByHostname" } else { $OSFilter }
$outputFile = Join-Path $OutputFolder "All_IntuneDeviceSummary_${osLabel}_${timestamp}.csv"

try {
    $results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "   COMPLETE" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Mode            : $mode"              -ForegroundColor White
    if ($mode -eq "file") {
    Write-Host "  Input file      : $InputFile"         -ForegroundColor White
    Write-Host "  Not found       : $($notFound.Count)" -ForegroundColor $(if ($notFound.Count -gt 0) {"Yellow"} else {"White"})
    } else {
    Write-Host "  OS filter       : $OSFilter"          -ForegroundColor White
    }
    Write-Host "  Total records   : $($results.Count)"  -ForegroundColor White
    Write-Host "  Output CSV      :"                    -ForegroundColor White
    Write-Host "    $outputFile"                        -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
}
catch {
    Write-Log "Failed to export CSV: $_" -Level ERROR
    exit 1
}

#endregion