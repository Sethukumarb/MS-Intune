#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-UserDevices.ps1
# Description  : Retrieves all Intune and Azure AD devices associated with one
#                or more users from a text file. Queries both Intune managed
#                devices and Azure AD registered devices per user, deduplicates
#                the results, and exports a per-user CSV file for each email.
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-04-03
# Last Modified: 2026-04-03
#
# Change Log   :
#   v1.0 - 2026-04-03 - Sethu Kumar B - Initial release.
#
# Requirements :
#   - Microsoft Graph PowerShell SDK (Install-Module Microsoft.Graph)
#   - Azure AD App Registration:
#       DeviceManagementManagedDevices.Read.All
#       Device.Read.All
#       User.Read.All
# ==============================================================================

<#
.SYNOPSIS
    Collects device details for one or more users from Intune and Azure AD, with optional OS filtering.

.DESCRIPTION
    This script reads user email addresses from a text file in the same folder as the script.
    For each email, it queries Microsoft Graph for:
    - Intune managed devices
    - Azure AD devices linked through the user's registered devices relationship

    It returns a combined, deduplicated list of devices and exports the results to individual
    per-user CSV files named after each email address.
    The script also writes:
    - a full PowerShell transcript,
    - a custom action log.

    Required Microsoft Graph application permissions:
    - DeviceManagementManagedDevices.Read.All
    - Device.Read.All
    - User.Read.All

.PARAMETER TenantId
    Microsoft Entra tenant ID.

.PARAMETER ClientId
    App registration client ID.

.PARAMETER ClientSecret
    App registration client secret.

.PARAMETER InputFile
    Text file containing one email per line. Default is users.txt in the script folder.

.PARAMETER TargetOS
    Optional operating system filter. Examples: Windows, iOS, Android, macOS.

.EXAMPLE
    .\Get-UserDevices.ps1

.EXAMPLE
    .\Get-UserDevices.ps1 -TargetOS "Windows"

.NOTES
    Output files are created in the same folder as the script:
    - Get-UserDevices-Transcript.log
    - Get-UserDevices-Actions.log
    - <email>-Devices.csv  (one file per user, e.g. john.doe_at_contoso.com-Devices.csv)

    The DeviceSource column in the CSV indicates where the device record originated:
    - "Intune (Managed Device)"       - pulled from Intune /managedDevices
    - "Azure AD (Registered Device)"  - pulled from Azure AD /registeredDevices
#>

param(
    [string]$TenantId     = "",
    [string]$ClientId     = "",
    [string]$ClientSecret = "",
    [string]$InputFile    = "users.txt",
    [string]$TargetOS     = "Windows"
)

# ---------------------------------------------------------------------------
# $PSScriptRoot is the reliable PS 5.1+ way to resolve the script's own folder.
# Consistent with all other scripts in this library.
# ---------------------------------------------------------------------------
$ScriptRoot      = $PSScriptRoot
$TranscriptFile  = Join-Path $ScriptRoot "Get-UserDevices-Transcript.log"
$ActionLogFile   = Join-Path $ScriptRoot "Get-UserDevices-Actions.log"
$InputPath       = Join-Path $ScriptRoot $InputFile

# ---------------------------------------------------------------------------
# Helper: convert an email address into a safe filename token
# Replaces @ with _at_ so the filename stays readable and filesystem-safe
# e.g.  john.doe@contoso.com  ->  john.doe_at_contoso.com
# ---------------------------------------------------------------------------
function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email
    )
    return $Email -replace '@', '_at_'
}

function Write-ActionLog {
    <#
    .SYNOPSIS
        Writes a timestamped message to the screen and action log.

    .DESCRIPTION
        Writes important events, warnings, and errors to both the console and the action log file.

    .PARAMETER Message
        Message to write.

    .PARAMETER Level
        Log level. Valid values are INFO, WARN, and ERROR.
    #>
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Message"
    Write-Host $line
    Add-Content -Path $ActionLogFile -Value $line
}

function Connect-ToGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using app-only authentication.

    .DESCRIPTION
        Converts the client secret to a secure string, builds a PSCredential object,
        and connects to Microsoft Graph using Connect-MgGraph.
    #>
    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $cred         = [pscredential]::new($ClientId, $secureSecret)
    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred | Out-Null
}

function Invoke-GraphPagedGet {
    <#
    .SYNOPSIS
        Retrieves all pages from a Microsoft Graph GET request.

    .DESCRIPTION
        Sends a GET request to Graph and follows @odata.nextLink until all records are collected.

    .PARAMETER Uri
        Microsoft Graph request URI.

    .OUTPUTS
        Array of returned Graph objects.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $items = @()
    $next  = $Uri

    while ($next) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($response.value) {
            $items += $response.value
        }
        $next = $response.'@odata.nextLink'
    }

    return $items
}

function Get-UserIntuneDevices {
    <#
    .SYNOPSIS
        Gets Intune managed devices for a single user email address.

    .DESCRIPTION
        Queries Intune managedDevices and returns devices where userPrincipalName or emailAddress
        matches the given email address. Optionally filters by operating system.

        DeviceSource is set to "Intune (Managed Device)" for all records returned by this function.

    .PARAMETER Email
        User email address.

    .OUTPUTS
        PSCustomObject list.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email
    )

    $emailLower = $Email.ToLower()
    $osLower    = $TargetOS.ToLower()
    $uri        = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,userPrincipalName,emailAddress,serialNumber,operatingSystem,azureADDeviceId&`$top=999"
    $results    = @()

    while ($uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri

        foreach ($device in $response.value) {
            $upn       = ($device.userPrincipalName | ForEach-Object { $_.ToLower() })
            $mail      = ($device.emailAddress      | ForEach-Object { $_.ToLower() })
            $deviceOS  = ($device.operatingSystem   | ForEach-Object { $_.ToLower() })

            $userMatch = ($upn -eq $emailLower -or $mail -eq $emailLower)
            $osMatch   = ([string]::IsNullOrWhiteSpace($TargetOS) -or $deviceOS -eq $osLower)

            if ($userMatch -and $osMatch) {
                $results += [pscustomobject]@{
                    UserEmail         = $Email
                    # DeviceSource identifies where this record was pulled from.
                    # "Intune (Managed Device)" means the device is enrolled in Intune
                    # and the record was retrieved from /deviceManagement/managedDevices.
                    DeviceSource      = "Intune (Managed Device)"
                    DeviceName        = $device.deviceName
                    IntuneDeviceId    = $device.id
                    AzureADDeviceId   = $device.azureADDeviceId
                    AzureADObjectId   = $device.azureADDeviceId
                    UserPrincipalName = $device.userPrincipalName
                    SerialNumber      = $device.serialNumber
                    OperatingSystem   = $device.operatingSystem
                }
            }
        }

        $uri = $response.'@odata.nextLink'
    }

    return $results
}

function Get-UserAzureADDevices {
    <#
    .SYNOPSIS
        Gets Azure AD registered devices for a single user email address.

    .DESCRIPTION
        Finds the user by email or UPN, then reads the user's registeredDevices relationship.
        Each device object is returned with its directory object ID and display name.

        DeviceSource is set to "Azure AD (Registered Device)" for all records returned by this function.

    .PARAMETER Email
        User email address.

    .OUTPUTS
        PSCustomObject list.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email
    )

    $results   = @()
    $userQuery = "https://graph.microsoft.com/v1.0/users?`$filter=userPrincipalName eq '$Email' or mail eq '$Email'&`$select=id,userPrincipalName,mail"
    $userResponse = Invoke-MgGraphRequest -Method GET -Uri $userQuery

    if (-not $userResponse.value -or $userResponse.value.Count -eq 0) {
        return $results
    }

    foreach ($user in $userResponse.value) {
        $regUri = "https://graph.microsoft.com/v1.0/users/$($user.id)/registeredDevices?`$select=id,deviceId,displayName,operatingSystem"
        $devices = Invoke-GraphPagedGet -Uri $regUri

        foreach ($d in $devices) {
            if ([string]::IsNullOrWhiteSpace($TargetOS) -or ($d.operatingSystem -and $d.operatingSystem.ToLower() -eq $TargetOS.ToLower())) {
                $results += [pscustomobject]@{
                    UserEmail         = $Email
                    # DeviceSource identifies where this record was pulled from.
                    # "Azure AD (Registered Device)" means the device appears in the user's
                    # registeredDevices relationship in Azure AD / Entra ID, retrieved from
                    # /users/{id}/registeredDevices. It may or may not be Intune-enrolled.
                    DeviceSource      = "Azure AD (Registered Device)"
                    DeviceName        = $d.displayName
                    IntuneDeviceId    = ""
                    AzureADDeviceId   = $d.deviceId
                    AzureADObjectId   = $d.id
                    UserPrincipalName = $user.userPrincipalName
                    SerialNumber      = ""
                    OperatingSystem   = $d.operatingSystem
                }
            }
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    New-Item -Path $ActionLogFile -ItemType File -Force | Out-Null
    Start-Transcript -Path $TranscriptFile -Force | Out-Null

    Write-ActionLog -Message "Script started."
    Write-ActionLog -Message "Script root   : $ScriptRoot"
    Write-ActionLog -Message "Input file    : $InputPath"
    Write-ActionLog -Message "Transcript    : $TranscriptFile"

    if (-not [string]::IsNullOrWhiteSpace($TargetOS)) {
        Write-ActionLog -Message "OS filter enabled: $TargetOS"
    }

    if (-not (Test-Path $InputPath)) {
        throw "Input file not found: $InputPath"
    }

    Write-ActionLog -Message "Connecting to Microsoft Graph..."
    Connect-ToGraph
    Write-ActionLog -Message "Connected to Microsoft Graph."

    $emails = Get-Content $InputPath | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    if (-not $emails -or $emails.Count -eq 0) {
        throw "No email addresses found in $InputPath"
    }

    Write-ActionLog -Message ("Found {0} email address(es) in input file." -f $emails.Count)

    foreach ($email in $emails) {
        Write-ActionLog -Message "Processing user: $email"

        # Build a per-user output path.
        # @ is replaced with _at_ for a clean, readable filename.
        # Example: john.doe@contoso.com -> john.doe_at_contoso.com-Devices.csv
        $safeEmail  = ConvertTo-SafeFileName -Email $email
        $outputFile = Join-Path $ScriptRoot "$safeEmail-Devices.csv"

        Write-ActionLog -Message "Output CSV for this user: $outputFile"

        try {
            $intuneDevices = Get-UserIntuneDevices  -Email $email
            $azureDevices  = Get-UserAzureADDevices -Email $email

            $combined = @($intuneDevices + $azureDevices)

            if ($combined.Count -gt 0) {
                # Deduplicate: sort by DeviceName + DeviceSource, keep unique rows
                $userResults = $combined |
                    Where-Object { $_.DeviceName } |
                    Sort-Object DeviceName, DeviceSource -Unique

                foreach ($item in $userResults) {
                    Write-ActionLog -Message ("  Device: {0} | Source: {1}" -f $item.DeviceName, $item.DeviceSource)
                }

                $userResults | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
                Write-ActionLog -Message ("  Exported {0} device(s) to: $outputFile" -f $userResults.Count)
            }
            else {
                # Write a single placeholder row so the file is still created for the user
                [pscustomobject]@{
                    UserEmail         = $email
                    DeviceSource      = ""
                    DeviceName        = ""
                    IntuneDeviceId    = ""
                    AzureADDeviceId   = ""
                    AzureADObjectId   = ""
                    UserPrincipalName = ""
                    SerialNumber      = ""
                    OperatingSystem   = ""
                } | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

                Write-ActionLog -Message "  No devices found for $email" -Level WARN
            }
        }
        catch {
            Write-ActionLog -Message "Error processing $email : $($_.Exception.Message)" -Level ERROR
        }
    }

    Write-ActionLog -Message "All users processed. CSV files saved to: $ScriptRoot"

    Disconnect-MgGraph | Out-Null
    Write-ActionLog -Message "Disconnected from Microsoft Graph."
}
catch {
    Write-ActionLog -Message "Fatal error: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    Stop-Transcript | Out-Null
}