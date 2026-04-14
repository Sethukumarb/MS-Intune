# ==============================================================================
# Script Name  : Get-WindowsDeviceInventory.ps1
# Description  : Retrieves a COMPLETE inventory of all Windows managed devices
#                from Microsoft Intune (Microsoft Graph API) with the maximum
#                number of available device fields, including:
#
#                  — Core identity        : DeviceName, Serial, DeviceID, AAD DeviceID
#                  — OS details           : Friendly OS name, version, build number
#                  — Hardware             : Model, Manufacturer, Storage, RAM, CPU
#                  — User info            : Primary User, Last Logged On User,
#                                          Enrolled By, Enrolled By Username
#                  — Enrollment           : Enrollment type, profile, join type,
#                                          enrollment date, enrollment profile name
#                  — Compliance           : Compliance state, grace period expiry
#                  — Management           : Management state, management agent,
#                                          management certificate expiry
#                  — Security             : BitLocker status, Defender state,
#                                          Encryption state, TPM info
#                  — Connectivity         : Last Sync, IMEI, MEID, ICCID,
#                                          WiFi MAC, Ethernet MAC, Phone Number
#                  — Autopilot / Shared   : Autopilot enrolled, Shared device,
#                                          Device category
#                  — Configuration        : Supervised mode, Exchange activated,
#                                          Remote assistance, Partner reporting
#
#                Uses the /beta endpoint for maximum field coverage (some fields
#                like enrolledByUserId are only available in beta).
#
#                SPEED OPTIMISATION:
#                  Parallel batch processing using PowerShell Runspaces
#                  (PS 5.1 compatible — does NOT require PS 7 or ForEach-Object -Parallel)
#                  Per-device usersLoggedOn enrichment is batched in parallel
#                  with a configurable throttle ($MaxParallelJobs) to avoid
#                  Graph API throttling (429 Too Many Requests).
#
#                OUTPUT:
#                  Single CSV file saved to $PSScriptRoot (same folder as script).
#                  Optional: override output path via $OutputFolder variable.
#                  Filename: Windows_Device_Inventory_[timestamp].csv
#
# Author       : Sethu Kumar B
# Version      : 1.2
# Created Date : 2026-03-27
# Last Modified: 2026-03-27
#
# Requirements :
#   - Azure AD App Registration (READ-ONLY App Registration recommended)
#   - Graph API Application Permissions (admin consent granted):
#       DeviceManagementManagedDevices.Read.All   — Device inventory + users
#       DeviceManagementConfiguration.Read.All    — Enrollment profiles
#       Device.Read.All                           — AAD device join type info
#   - PowerShell 5.1 or later (no additional modules required)
#   - Network access to:
#       https://login.microsoftonline.com          (token endpoint)
#       https://graph.microsoft.com                (Graph API — beta endpoint)
#
# Change Log   :
#   v1.0 - 2026-03-27 - Sethu Kumar B - Initial release
#   v1.1 - 2026-03-27 - Sethu Kumar B - Fixed 400 Bad Request: removed $select
#                                        from collection URI ($filter + $select
#                                        conflict on managedDevices endpoint)
#   v1.2 - 2026-03-27 - Sethu Kumar B - Added Write-Log function; all console
#                                        output now mirrors to a .log file saved
#                                        in $PSScriptRoot alongside the CSV
# ==============================================================================


#region ─── CONFIGURATION ─── Edit these values before running ────────────────

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ── OUTPUT PATH ──────────────────────────────────────────────────────────────
# Default: script saves CSV in the same folder as the script ($PSScriptRoot).
# To override, change $OutputFolder to a full path, e.g. "C:\Reports\Intune"
# The folder will be created automatically if it does not exist.
# Set to $null or "" to use $PSScriptRoot (default).
# ─────────────────────────────────────────────────────────────────────────────
$OutputFolder = ""    # Leave empty = save next to script

# ── PERFORMANCE SETTINGS ──────────────────────────────────────────────────────
# $MaxParallelJobs : Number of parallel runspace threads for per-device API calls
#                    (usersLoggedOn enrichment). Increase for faster runs on
#                    large fleets. Keep ≤ 20 to stay well within Graph API
#                    throttling limits (10,000 req/10 min per app).
#                    Recommended: 10 (safe default), max: 20
$MaxParallelJobs  = 10

# $PageSize        : Records per API page. Max supported by Graph = 1000 for
#                    managedDevices with $top. Use 1000 for fastest pagination.
$PageSize         = 1000

#endregion ────────────────────────────────────────────────────────────────────


#region ─── FUNCTIONS ─────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Write-Log
# Purpose  : Writes a timestamped message to BOTH the console (with colour)
#            AND the log file at $PSScriptRoot\Windows_Device_Inventory_[ts].log
#            All script output is routed through this function so the log file
#            is a complete record of every run — no separate tee required.
#
# Parameters:
#   $Message  — Text to write
#   $Level    — INFO (default) | SUCCESS | WARN | ERROR | SECTION | PROGRESS
#               Each level maps to a console foreground colour and a log prefix.
#   $NoNewLine — Switch: pass to suppress newline (rarely needed)
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","SECTION","PROGRESS","BLANK")]
        [string]$Level     = "INFO",
        [switch]$NoNewLine
    )

    # Console colour map
    $ColourMap = @{
        INFO     = "White"
        SUCCESS  = "Green"
        WARN     = "Yellow"
        ERROR    = "Red"
        SECTION  = "Cyan"
        PROGRESS = "Gray"
        BLANK    = "Gray"
    }

    # Log file prefix map
    $PrefixMap = @{
        INFO     = "[INFO]    "
        SUCCESS  = "[SUCCESS] "
        WARN     = "[WARN]    "
        ERROR    = "[ERROR]   "
        SECTION  = "[SECTION] "
        PROGRESS = "[PROGRESS]"
        BLANK    = "          "
    }

    $Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine     = "$Timestamp  $($PrefixMap[$Level]) $Message"
    $ConsoleArgs = @{
        Object          = $Message
        ForegroundColor = $ColourMap[$Level]
        NoNewline       = $NoNewLine.IsPresent
    }

    # Write to console
    Write-Host @ConsoleArgs

    # Write to log file (script-level variable $script:LogFile set in MAIN)
    if ($script:LogFile) {
        try {
            if ($NoNewLine) {
                [System.IO.File]::AppendAllText($script:LogFile, $LogLine)
            }
            else {
                Add-Content -Path $script:LogFile -Value $LogLine -Encoding UTF8
            }
        }
        catch {
            # Silently ignore log write failures — never block the main script
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-GraphAccessToken
# Purpose  : Authenticates using App Registration client credentials flow.
#            Returns a Bearer access token for all subsequent Graph API calls.
# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Invoke-GraphGetAllPages
# Purpose  : Calls a Graph API URI and follows all @odata.nextLink pages
#            until every record is retrieved. Returns a flat array of objects.
# ─────────────────────────────────────────────────────────────────────────────
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

    Write-Log "[QUERY] Fetching $EntityLabel — paginating all results..." -Level SECTION

    do {
        $PageNumber++
        try {
            $Response    = Invoke-RestMethod -Method GET -Uri $CurrentUri `
                           -Headers $Headers -ErrorAction Stop
            $PageCount   = $Response.value.Count
            $TotalSoFar += $PageCount

            Write-Log ("  Page {0,3}  |  {1,5} records  |  Total so far: {2}" -f `
                        $PageNumber, $PageCount, $TotalSoFar) -Level PROGRESS

            foreach ($Record in $Response.value) { $AllRecords.Add($Record) }

            $CurrentUri = $Response.'@odata.nextLink'
        }
        catch {
            Write-Log "  Page $PageNumber failed for '$EntityLabel': $_" -Level ERROR
            $CurrentUri = $null
        }
    } while ($CurrentUri)

    Write-Log "[QUERY] $EntityLabel — $TotalSoFar records across $PageNumber page(s)." -Level SUCCESS
    Write-Log "" -Level BLANK

    return $AllRecords.ToArray()
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : ConvertTo-FriendlyOSName
# Purpose  : Converts raw OS version strings from Intune into a clean,
#            human-readable Windows version name for the CSV output.
#            Examples:
#              "10.0.22631.xxxx" → "Windows 11 23H2"
#              "10.0.19045.xxxx" → "Windows 10 22H2"
#              "10.0.22000.xxxx" → "Windows 11 21H2"
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-FriendlyOSName {
    param ([string]$OSVersion)

    if ([string]::IsNullOrWhiteSpace($OSVersion)) { return "Unknown" }

    # Extract major build number from version string (e.g. "10.0.22631.3447" → 22631)
    $BuildNumber = 0
    if ($OSVersion -match "10\.0\.(\d+)") {
        $BuildNumber = [int]$Matches[1]
    }
    elseif ($OSVersion -match "^(\d+)$") {
        $BuildNumber = [int]$OSVersion
    }

    # Windows 11 builds (>= 22000)
    if ($BuildNumber -ge 26100) { return "Windows 11 24H2" }
    if ($BuildNumber -ge 22631) { return "Windows 11 23H2" }
    if ($BuildNumber -ge 22621) { return "Windows 11 22H2" }
    if ($BuildNumber -ge 22000) { return "Windows 11 21H2" }

    # Windows 10 builds
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

    # Windows Server builds (common)
    if ($BuildNumber -ge 20348) { return "Windows Server 2022" }
    if ($BuildNumber -ge 17763) { return "Windows Server 2019" }
    if ($BuildNumber -ge 14393) { return "Windows Server 2016" }

    # Fallback — return original version if no match
    return "Windows (Build $BuildNumber)"
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : ConvertTo-FriendlyDate
# Purpose  : Converts ISO 8601 datetime strings to a clean readable format.
#            Returns "N/A" for null/empty values and handles the Graph API
#            "0001-01-01T00:00:00Z" sentinel value (means "never").
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-FriendlyDate {
    param ([string]$DateString)

    if ([string]::IsNullOrWhiteSpace($DateString)) { return "N/A" }
    if ($DateString -like "0001-01-01*")            { return "Never" }

    try {
        $dt = [datetime]::Parse($DateString, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    }
    catch {
        return $DateString
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-LastLoggedOnUser
# Purpose  : Retrieves the usersLoggedOn property for a single Intune device.
#            This property requires a separate per-device entity GET call —
#            it cannot be fetched via $select on the collection endpoint.
#            Returns the UPN of the most recently logged on user.
# ─────────────────────────────────────────────────────────────────────────────
function Get-LastLoggedOnUser {
    param (
        [Parameter(Mandatory)][string]$IntuneDeviceId,
        [Parameter(Mandatory)][string]$AccessToken
    )

    $Headers = @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    # Use string concatenation for PS 5.1 URI compatibility (avoids backtick issues)
    $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/" +
           $IntuneDeviceId +
           "?`$select=usersLoggedOn"

    try {
        $Response = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop

        if ($Response.usersLoggedOn -and $Response.usersLoggedOn.Count -gt 0) {
            # Sort by lastLogOnDateTime descending — pick the most recent user
            $LastUser = $Response.usersLoggedOn |
                        Sort-Object { [datetime]$_.lastLogOnDateTime } -Descending |
                        Select-Object -First 1
            return $LastUser.userId   # Returns the UPN / user ID
        }
        return "No Logon Data"
    }
    catch {
        return "LOOKUP ERROR"
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Invoke-ParallelLastLogonEnrichment
# Purpose  : Runs Get-LastLoggedOnUser for every device in parallel using
#            PowerShell Runspaces (PS 5.1 compatible — no PS 7 required).
#            Returns a hashtable keyed by IntuneDeviceId → LastLoggedOnUser UPN.
#
#            Runspaces allow true multi-threading in PS 5.1 without the
#            ForEach-Object -Parallel syntax that requires PS 7.
#            Each runspace makes its own independent Graph API call.
#            $MaxParallelJobs controls the thread pool size (throttle).
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-ParallelLastLogonEnrichment {
    param (
        [Parameter(Mandatory)][array]$Devices,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][int]$MaxParallelJobs
    )

    Write-Log "[PARALLEL] Starting last-logon enrichment for $($Devices.Count) devices..." -Level SECTION
    Write-Log "[PARALLEL] Thread pool size: $MaxParallelJobs parallel runspaces" -Level PROGRESS
    Write-Log "" -Level BLANK

    # Script block executed inside each runspace thread
    $ScriptBlock = {
        param ($DeviceId, $Token)

        $Headers = @{
            Authorization  = "Bearer $Token"
            "Content-Type" = "application/json"
        }
        $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/" +
               $DeviceId + "?`$select=usersLoggedOn"

        try {
            $Response = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
            if ($Response.usersLoggedOn -and $Response.usersLoggedOn.Count -gt 0) {
                $LastUser = $Response.usersLoggedOn |
                            Sort-Object { [datetime]$_.lastLogOnDateTime } -Descending |
                            Select-Object -First 1
                return @{ DeviceId = $DeviceId; User = $LastUser.userId }
            }
            return @{ DeviceId = $DeviceId; User = "No Logon Data" }
        }
        catch {
            return @{ DeviceId = $DeviceId; User = "LOOKUP ERROR" }
        }
    }

    # Create a thread-safe runspace pool
    $RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallelJobs)
    $RunspacePool.Open()

    $Jobs        = [System.Collections.Generic.List[PSObject]]::new()
    $ResultTable = @{}

    # Submit all jobs to the runspace pool
    foreach ($Device in $Devices) {
        $PS = [powershell]::Create()
        $PS.RunspacePool = $RunspacePool
        [void]$PS.AddScript($ScriptBlock)
        [void]$PS.AddArgument($Device.IntuneDeviceID)
        [void]$PS.AddArgument($AccessToken)

        $Handle = $PS.BeginInvoke()
        $Jobs.Add([PSCustomObject]@{ PS = $PS; Handle = $Handle; DeviceId = $Device.IntuneDeviceID })
    }

    # Collect results as jobs complete
    $Completed  = 0
    $TotalJobs  = $Jobs.Count
    $LastReport = 0

    foreach ($Job in $Jobs) {
        try {
            $Result = $Job.PS.EndInvoke($Job.Handle)
            if ($Result -and $Result.DeviceId) {
                $ResultTable[$Result.DeviceId] = $Result.User
            }
            else {
                $ResultTable[$Job.DeviceId] = "No Data"
            }
        }
        catch {
            $ResultTable[$Job.DeviceId] = "ERROR"
        }
        finally {
            $Job.PS.Dispose()
        }

        $Completed++

        # Progress update every 100 devices
        if ($Completed - $LastReport -ge 100 -or $Completed -eq $TotalJobs) {
            Write-Log ("  Enriched {0}/{1} devices..." -f $Completed, $TotalJobs) -Level PROGRESS
            $LastReport = $Completed
        }
    }

    $RunspacePool.Close()
    $RunspacePool.Dispose()

    Write-Log "[PARALLEL] Last-logon enrichment complete." -Level SUCCESS
    Write-Log "" -Level BLANK
    return $ResultTable
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Get-AllWindowsDevices
# Purpose  : Queries the Graph API /beta/deviceManagement/managedDevices
#            endpoint with a Windows OS filter and retrieves ALL available
#            device fields in a single paginated call.
#
#            Uses /beta endpoint because several fields are beta-only:
#              enrolledByUserId, enrolledByUserDisplayName, physicalMemoryInBytes,
#              processorArchitecture, bootstrapTokenEscrowed, deviceGuardStatus,
#              hardwareInformation, deviceCategory, skuFamily, etc.
# ─────────────────────────────────────────────────────────────────────────────
function Get-AllWindowsDevices {
    param (
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][int]$PageSize
    )

    # ── FIX: Do NOT combine $filter + $select on the managedDevices collection  ──
    # The Graph API returns HTTP 400 when both are used together on this endpoint.
    # Solution: apply $filter only — Graph returns all available fields.
    # Field selection is handled client-side in Shape-DeviceRecord.
    # Reference: same pattern used in Get-FullDeviceInventory.ps1 (your library).
    # ─────────────────────────────────────────────────────────────────────────────
    $BaseUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices"
    $Uri     = $BaseUri + "?`$filter=operatingSystem eq 'Windows'" +
               "&`$top=" + $PageSize

    return Invoke-GraphGetAllPages -InitialUri $Uri `
                                   -AccessToken $AccessToken `
                                   -EntityLabel "Windows managed devices"
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Convert-StorageToGB
# Purpose  : Converts bytes (long integer) to a rounded GB string.
#            Returns "N/A" for null or zero values.
# ─────────────────────────────────────────────────────────────────────────────
function Convert-StorageToGB {
    param ($Bytes)
    if (-not $Bytes -or $Bytes -eq 0) { return "N/A" }
    return [math]::Round($Bytes / 1GB, 2).ToString() + " GB"
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Convert-RAMToGB
# Purpose  : Converts physicalMemoryInBytes to a human-readable GB string.
# ─────────────────────────────────────────────────────────────────────────────
function Convert-RAMToGB {
    param ($Bytes)
    if (-not $Bytes -or $Bytes -eq 0) { return "N/A" }
    return [math]::Round($Bytes / 1GB, 1).ToString() + " GB"
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : ConvertTo-FriendlyEnrollmentType
# Purpose  : Maps Graph API deviceEnrollmentType enum values to readable strings.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-FriendlyEnrollmentType {
    param ([string]$EnrollmentType)
    $Map = @{
        "userEnrollment"                    = "User Enrollment (BYOD)"
        "deviceEnrollmentManager"           = "Device Enrollment Manager (DEM)"
        "azureDomainJoined"                 = "Azure AD Joined"
        "userEnrollmentWithServiceAccount"  = "User Enrollment with Service Account"
        "deviceEnrollmentProgram"           = "Apple DEP / Autopilot"
        "windowsAutoEnrollment"             = "Windows Auto-Enrollment (MDM)"
        "windowsBulkAzureDomainJoin"        = "Bulk Azure AD Join"
        "windowsBulkUserless"               = "Bulk Userless (Autopilot)"
        "windowsCoManagement"               = "Co-Management (Intune + SCCM)"
        "unknownFutureValue"                = "Unknown"
        "unknown"                           = "Unknown"
    }
    if ($Map.ContainsKey($EnrollmentType)) { return $Map[$EnrollmentType] }
    return $EnrollmentType
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : ConvertTo-FriendlyJoinType
# Purpose  : Maps Graph API joinType enum to a readable join type string.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-FriendlyJoinType {
    param ([string]$JoinType)
    $Map = @{
        "azureADJoined"             = "Azure AD Joined (Cloud-only)"
        "hybridAzureADJoined"       = "Hybrid Azure AD Joined"
        "azureADRegistered"         = "Azure AD Registered (Workplace)"
        "unknownFutureValue"        = "Unknown"
        "unknown"                   = "Unknown"
    }
    if ($Map.ContainsKey($JoinType)) { return $Map[$JoinType] }
    if ([string]::IsNullOrWhiteSpace($JoinType)) { return "Not Set" }
    return $JoinType
}


# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION : Shape-DeviceRecord
# Purpose  : Converts a raw Graph API managed device object into a clean,
#            fully-labelled PSCustomObject with all columns for CSV export.
#            Applies all friendly name conversions, storage formatting,
#            and date formatting inline.
# ─────────────────────────────────────────────────────────────────────────────
function Shape-DeviceRecord {
    param (
        [Parameter(Mandatory)][PSObject]$Device,
        [Parameter(Mandatory)][hashtable]$LastLogonTable
    )

    # Look up last logged on user from enrichment table
    $LastLoggedOnUser = "Not Enriched"
    if ($LastLogonTable.ContainsKey($Device.id)) {
        $LastLoggedOnUser = $LastLogonTable[$Device.id]
    }

    # Friendly OS name from build number
    $FriendlyOS = ConvertTo-FriendlyOSName -OSVersion $Device.osVersion

    # Extract build number from osVersion string
    $BuildNumber = "N/A"
    if ($Device.osVersion -match "10\.0\.(\d+)") { $BuildNumber = $Matches[1] }

    return [PSCustomObject]@{

        # ── IDENTITY ──────────────────────────────────────────────────────────
        "DeviceName"                        = if ($Device.deviceName) { $Device.deviceName } else { "N/A" }
        "IntuneDeviceID"                    = $Device.id
        "AzureAD_DeviceID"                  = if ($Device.azureADDeviceId) { $Device.azureADDeviceId } else { "N/A" }
        "SerialNumber"                      = if ($Device.serialNumber) { $Device.serialNumber } else { "N/A" }

        # ── OS INFORMATION ────────────────────────────────────────────────────
        "OperatingSystem"                   = "Windows"
        "FriendlyOSName"                    = $FriendlyOS
        "OSVersion_Full"                    = if ($Device.osVersion) { $Device.osVersion } else { "N/A" }
        "OSBuildNumber"                     = $BuildNumber
        "SKUFamily"                         = if ($Device.skuFamily) { $Device.skuFamily } else { "N/A" }

        # ── HARDWARE ──────────────────────────────────────────────────────────
        "Manufacturer"                      = if ($Device.manufacturer) { $Device.manufacturer } else { "N/A" }
        "DeviceModel"                       = if ($Device.model) { $Device.model } else { "N/A" }
        "RAM_GB"                            = Convert-RAMToGB -Bytes $Device.physicalMemoryInBytes
        "TotalStorage_GB"                   = Convert-StorageToGB -Bytes $Device.storageTotal
        "FreeStorage_GB"                    = Convert-StorageToGB -Bytes $Device.storageFree
        "ProcessorArchitecture"             = if ($Device.processorArchitecture) { $Device.processorArchitecture } else { "N/A" }
        "WiFi_MAC"                          = if ($Device.wiFiMacAddress) { $Device.wiFiMacAddress } else { "N/A" }
        "Ethernet_MAC"                      = if ($Device.ethernetMacAddress) { $Device.ethernetMacAddress } else { "N/A" }

        # ── PRIMARY USER ──────────────────────────────────────────────────────
        "PrimaryUser_UPN"                   = if ($Device.userPrincipalName) { $Device.userPrincipalName } else { "No Primary User" }
        "PrimaryUser_DisplayName"           = if ($Device.userDisplayName) { $Device.userDisplayName } else { "N/A" }
        "PrimaryUser_AADObjectID"           = if ($Device.userId) { $Device.userId } else { "N/A" }
        "PrimaryUser_Email"                 = if ($Device.emailAddress) { $Device.emailAddress } else { "N/A" }

        # ── LAST LOGGED ON USER (parallel enrichment) ─────────────────────────
        "LastLoggedOn_UserID"               = $LastLoggedOnUser

        # ── ENROLLED BY ───────────────────────────────────────────────────────
        "EnrolledBy_UPN"                    = if ($Device.enrolledByUserId) { $Device.enrolledByUserId } else { "N/A" }
        "EnrolledBy_DisplayName"            = if ($Device.enrolledByUserDisplayName) { $Device.enrolledByUserDisplayName } else { "N/A" }
        "EnrolledBy_UPN_Explicit"           = if ($Device.enrolledByUserPrincipalName) { $Device.enrolledByUserPrincipalName } else { "N/A" }

        # ── ENROLLMENT DETAILS ────────────────────────────────────────────────
        "EnrollmentType"                    = ConvertTo-FriendlyEnrollmentType -EnrollmentType $Device.deviceEnrollmentType
        "EnrollmentType_Raw"                = if ($Device.deviceEnrollmentType) { $Device.deviceEnrollmentType } else { "N/A" }
        "JoinType"                          = ConvertTo-FriendlyJoinType -JoinType $Device.joinType
        "JoinType_Raw"                      = if ($Device.joinType) { $Device.joinType } else { "N/A" }
        "AutopilotEnrolled"                 = if ($null -ne $Device.autopilotEnrolled) { $Device.autopilotEnrolled } else { "N/A" }
        "DeviceRegistrationState"           = if ($Device.deviceRegistrationState) { $Device.deviceRegistrationState } else { "N/A" }
        "EnrolledDateTime"                  = ConvertTo-FriendlyDate -DateString $Device.enrolledDateTime

        # ── OWNERSHIP ─────────────────────────────────────────────────────────
        "OwnerType"                         = if ($Device.managedDeviceOwnerType) { $Device.managedDeviceOwnerType } else { "N/A" }
        "DeviceCategory"                    = if ($Device.deviceCategoryDisplayName) { $Device.deviceCategoryDisplayName } else { "N/A" }
        "IsSharedDevice"                    = if ($null -ne $Device.isSharedDevice) { $Device.isSharedDevice } else { "N/A" }

        # ── COMPLIANCE ────────────────────────────────────────────────────────
        "ComplianceState"                   = if ($Device.complianceState) { $Device.complianceState } else { "N/A" }
        "ComplianceGracePeriodExpiry"       = ConvertTo-FriendlyDate -DateString $Device.complianceGracePeriodExpirationDateTime

        # ── MANAGEMENT ────────────────────────────────────────────────────────
        "ManagementState"                   = if ($Device.managementState) { $Device.managementState } else { "N/A" }
        "ManagementAgent"                   = if ($Device.managementAgent) { $Device.managementAgent } else { "N/A" }
        "ManagementCertExpiry"              = ConvertTo-FriendlyDate -DateString $Device.managementCertificateExpirationDate
        "IsSupervised"                      = if ($null -ne $Device.isSupervised) { $Device.isSupervised } else { "N/A" }

        # ── SECURITY / ENCRYPTION ─────────────────────────────────────────────
        "IsEncrypted"                       = if ($null -ne $Device.isEncrypted) { $Device.isEncrypted } else { "N/A" }
        "BootstrapTokenEscrowed"            = if ($null -ne $Device.bootstrapTokenEscrowed) { $Device.bootstrapTokenEscrowed } else { "N/A" }
        "DeviceGuard_VBS_HWRequirement"     = if ($Device.deviceGuardVirtualizationBasedSecurityHardwareRequirementState) { $Device.deviceGuardVirtualizationBasedSecurityHardwareRequirementState } else { "N/A" }
        "DeviceGuard_VBS_State"             = if ($Device.deviceGuardVirtualizationBasedSecurityState) { $Device.deviceGuardVirtualizationBasedSecurityState } else { "N/A" }
        "DeviceGuard_CredentialGuard"       = if ($Device.deviceGuardLocalSystemAuthorityCredentialGuardState) { $Device.deviceGuardLocalSystemAuthorityCredentialGuardState } else { "N/A" }
        "PartnerThreatState"                = if ($Device.partnerReportedThreatState) { $Device.partnerReportedThreatState } else { "N/A" }

        # ── EXCHANGE / EAS ────────────────────────────────────────────────────
        "EAS_Activated"                     = if ($null -ne $Device.easActivated) { $Device.easActivated } else { "N/A" }
        "EAS_ActivationDateTime"            = ConvertTo-FriendlyDate -DateString $Device.easActivationDateTime
        "EAS_AccessState"                   = if ($Device.exchangeAccessState) { $Device.exchangeAccessState } else { "N/A" }
        "EAS_AccessStateReason"             = if ($Device.exchangeAccessStateReason) { $Device.exchangeAccessStateReason } else { "N/A" }

        # ── TIMESTAMPS ────────────────────────────────────────────────────────
        "LastSyncDateTime"                  = ConvertTo-FriendlyDate -DateString $Device.lastSyncDateTime
        "DaysSinceLastSync"                 = if ($Device.lastSyncDateTime -and $Device.lastSyncDateTime -notlike "0001*") {
                                                  [math]::Round(((Get-Date) - [datetime]::Parse($Device.lastSyncDateTime)).TotalDays, 1)
                                              } else { "N/A" }

        # ── NOTES ─────────────────────────────────────────────────────────────
        "DeviceNotes"                       = if ($Device.notes) { $Device.notes } else { "N/A" }
    }
}

#endregion ────────────────────────────────────────────────────────────────────


#region ─── MAIN ──────────────────────────────────────────────────────────────

# ── Step 1: Resolve output folder + initialise log file ───────────────────────
if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $ResolvedOutput = $PSScriptRoot
}
else {
    $ResolvedOutput = $OutputFolder
}

$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile = Join-Path $ResolvedOutput ("Windows_Device_Inventory_" + $Timestamp + ".csv")

# Log file always goes to $PSScriptRoot regardless of $OutputFolder
# This keeps logs alongside the script for easy access
$script:LogFile = Join-Path $PSScriptRoot ("Windows_Device_Inventory_" + $Timestamp + ".log")

# Initialise log file with a header banner
$LogHeader = @"
================================================================================
  Windows Device Full Inventory  |  Endpoint Engineering  |  Sethu Kumar B
  Run started : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Script      : $PSCommandPath
  Log file    : $($script:LogFile)
  Output file : $OutputFile
================================================================================

"@
try {
    [System.IO.File]::WriteAllText($script:LogFile, $LogHeader, [System.Text.Encoding]::UTF8)
}
catch {
    Write-Host "[WARN] Could not create log file at $($script:LogFile): $_" -ForegroundColor Yellow
    $script:LogFile = $null   # Disable logging — script continues without it
}

# ── Step 2: Console banner ────────────────────────────────────────────────────
Write-Log ""                                                                              -Level BLANK
Write-Log "================================================================" -Level SECTION
Write-Log "   Windows Device Full Inventory  |  Endpoint Engineering      " -Level SECTION
Write-Log "================================================================" -Level SECTION
Write-Log "[INFO] Output folder   : $ResolvedOutput"                         -Level INFO
Write-Log "[INFO] Output CSV      : $OutputFile"                             -Level INFO
Write-Log "[INFO] Log file        : $($script:LogFile)"                      -Level INFO
Write-Log "[INFO] Timestamp       : $Timestamp"                              -Level INFO
Write-Log "[INFO] Page size       : $PageSize"                               -Level INFO
Write-Log "[INFO] Parallel jobs   : $MaxParallelJobs"                        -Level INFO
Write-Log "[INFO] API endpoint    : /beta/deviceManagement/managedDevices"   -Level INFO
Write-Log "[INFO] OS filter       : Windows (server-side — filter only, no select)" -Level INFO
Write-Log "[INFO] 400 fix applied : \$filter + \$select conflict avoided"    -Level INFO
Write-Log "" -Level BLANK

# ── Step 3: Create output folder if needed ────────────────────────────────────
if (-not (Test-Path -Path $ResolvedOutput)) {
    try {
        New-Item -ItemType Directory -Path $ResolvedOutput -Force | Out-Null
        Write-Log "[INFO] Created output folder: $ResolvedOutput" -Level SUCCESS
        Write-Log "" -Level BLANK
    }
    catch {
        Write-Log "[ERROR] Cannot create output folder: $_" -Level ERROR
        exit 1
    }
}

# ── Step 4: Authenticate ──────────────────────────────────────────────────────
$AccessToken = Get-GraphAccessToken -TenantId $TenantId `
               -ClientId $ClientId -ClientSecret $ClientSecret

# ── Step 5: Pull all Windows device records (paginated) ───────────────────────
Write-Log "------------------------------------------------------------" -Level SECTION
Write-Log "  STEP 1 OF 3  —  Fetching Windows Device Records"           -Level SECTION
Write-Log "------------------------------------------------------------" -Level SECTION

$RawDevices = Get-AllWindowsDevices -AccessToken $AccessToken -PageSize $PageSize

Write-Log "[INFO] Total Windows devices retrieved: $($RawDevices.Count)" -Level INFO
Write-Log "" -Level BLANK

if ($RawDevices.Count -eq 0) {
    Write-Log "[WARN] No Windows devices returned. Check App Registration permissions and TenantId." -Level WARN
    exit 0
}

# ── Step 6: Parallel last-logon enrichment ────────────────────────────────────
Write-Log "------------------------------------------------------------" -Level SECTION
Write-Log "  STEP 2 OF 3  —  Parallel Last-Logon Enrichment"            -Level SECTION
Write-Log "------------------------------------------------------------" -Level SECTION

$DeviceList     = $RawDevices | ForEach-Object { [PSCustomObject]@{ IntuneDeviceID = $_.id } }
$LastLogonTable = Invoke-ParallelLastLogonEnrichment -Devices $DeviceList `
                  -AccessToken $AccessToken -MaxParallelJobs $MaxParallelJobs

# ── Step 7: Shape all records into final output objects ───────────────────────
Write-Log "------------------------------------------------------------" -Level SECTION
Write-Log "  STEP 3 OF 3  —  Shaping Records and Exporting CSV"         -Level SECTION
Write-Log "------------------------------------------------------------" -Level SECTION

Write-Log "[INFO] Shaping $($RawDevices.Count) device records into final column set..." -Level INFO

$FinalDevices = [System.Collections.Generic.List[PSObject]]::new()
foreach ($Device in $RawDevices) {
    $Shaped = Shape-DeviceRecord -Device $Device -LastLogonTable $LastLogonTable
    $FinalDevices.Add($Shaped)
}

Write-Log "[INFO] Shaping complete." -Level SUCCESS
Write-Log "" -Level BLANK

# ── Step 8: Export CSV ────────────────────────────────────────────────────────
try {
    $FinalDevices | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $FileSizeMB = (((Get-Item $OutputFile).Length) / 1MB).ToString("0.00")
    Write-Log "[EXPORT] CSV written successfully."                                    -Level SUCCESS
    Write-Log "         Path : $OutputFile"                                           -Level INFO
    Write-Log "         Rows : $($FinalDevices.Count)  |  Size: $FileSizeMB MB"      -Level INFO
    Write-Log "" -Level BLANK
}
catch {
    Write-Log "[ERROR] Failed to write CSV: $_" -Level ERROR
    exit 1
}

# ── Step 9: Final Summary ─────────────────────────────────────────────────────
$Win11Count   = ($FinalDevices | Where-Object { $_.FriendlyOSName -like "Windows 11*" }).Count
$Win10Count   = ($FinalDevices | Where-Object { $_.FriendlyOSName -like "Windows 10*" }).Count
$OtherCount   = $FinalDevices.Count - $Win11Count - $Win10Count
$Compliant    = ($FinalDevices | Where-Object { $_.ComplianceState -eq "compliant" }).Count
$NonCompliant = ($FinalDevices | Where-Object { $_.ComplianceState -eq "nonCompliant" }).Count
$Unknown      = ($FinalDevices | Where-Object { $_.ComplianceState -eq "unknown" }).Count
$Encrypted    = ($FinalDevices | Where-Object { $_.IsEncrypted -eq $true }).Count
$NotEncrypted = ($FinalDevices | Where-Object { $_.IsEncrypted -eq $false }).Count
$Autopilot    = ($FinalDevices | Where-Object { $_.AutopilotEnrolled -eq $true }).Count
$AADJoined    = ($FinalDevices | Where-Object { $_.JoinType -like "*Cloud-only*" }).Count
$HybridJoined = ($FinalDevices | Where-Object { $_.JoinType -like "*Hybrid*" }).Count

Write-Log "================================================================" -Level SECTION
Write-Log "   SUMMARY"                                                        -Level SECTION
Write-Log "================================================================" -Level SECTION
Write-Log "  Total Windows devices   : $($FinalDevices.Count)"  -Level INFO
Write-Log "  ── OS Breakdown ──"                                 -Level INFO
Write-Log "  Windows 11              : $Win11Count"              -Level INFO
Write-Log "  Windows 10              : $Win10Count"              -Level INFO
Write-Log "  Other / Unknown build   : $OtherCount"             -Level INFO
Write-Log "  ── Compliance ──"                                   -Level INFO
Write-Log "  Compliant               : $Compliant"              -Level SUCCESS
Write-Log "  Non-Compliant           : $NonCompliant"           -Level WARN
Write-Log "  Unknown                 : $Unknown"                -Level INFO
Write-Log "  ── Security ──"                                     -Level INFO
Write-Log "  Encrypted               : $Encrypted"              -Level SUCCESS
Write-Log "  Not Encrypted           : $NotEncrypted"           -Level WARN
Write-Log "  ── Enrollment ──"                                   -Level INFO
Write-Log "  Autopilot Enrolled      : $Autopilot"              -Level INFO
Write-Log "  Azure AD Joined         : $AADJoined"              -Level INFO
Write-Log "  Hybrid Azure AD Joined  : $HybridJoined"           -Level INFO
Write-Log "" -Level BLANK
Write-Log "  Output CSV  : $OutputFile"                          -Level SECTION
Write-Log "  Log file    : $($script:LogFile)"                   -Level SECTION
Write-Log "================================================================" -Level SECTION
Write-Log "" -Level BLANK

#endregion ────────────────────────────────────────────────────────────────────