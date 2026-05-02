<#
.SYNOPSIS
    Detects whether Google Chrome is installed and up-to-date against the latest
    stable release, fetched live from Google's official version API.

.DESCRIPTION
    This script is designed as a Detection Script for Microsoft Intune Proactive
    Remediations. It performs the following steps:

      1. Queries Google's public Chrome Version History REST API to retrieve the
         latest stable Chrome version for Windows (no API key required).
      2. Scans known Chrome installation paths on the device.
      3. Compares the installed version against the live latest stable version.
      4. Outputs a Status and CurrentVersion, then exits with the appropriate code.

    Exit Codes:
      0 - Compliant   : Chrome is installed AND version >= latest stable
      1 - NotCompliant: Chrome is installed BUT version < latest stable
      1 - NotInstalled: Chrome executable was not found on the device
      1 - APIError    : Could not reach Google's API to determine required version

    Output format (captured by Intune remediation logs):
      Status=<Compliant|NotCompliant|NotInstalled|APIError>
      RequiredVersion=<version fetched from API | Unknown>
      CurrentVersion=<installed version | None>

.NOTES
    Script Name   : Detect-ChromeVersionCompliance.ps1
    Author        : Sethu Kumar B
    Version       : 2.0.0
    Created       : 2025-04-17
    Last Modified : 2025-04-17

    Requirements:
      - Windows PowerShell 5.1 or later
      - Internet access from the device at time of execution
        (to reach versionhistory.googleapis.com)
      - Run as: SYSTEM account (default Intune context)

    API Used (public, no auth required):
      https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions/all/releases?orderBy=version%20desc&pageSize=1

.EXAMPLE
    PS C:\> .\Detect-ChromeVersionCompliance.ps1
    Status=Compliant
    RequiredVersion=136.0.7103.93
    CurrentVersion=136.0.7103.93

.LINK
    Google Chrome Version History API:
    https://developer.chrome.com/docs/versionhistory/reference/

    Microsoft Intune Proactive Remediations:
    https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations
#>


# -----------------------------------------------------------------------
# SECTION 1: Configuration — Chrome Installation Paths
# -----------------------------------------------------------------------
# All known locations where Chrome may be installed on a Windows device.
# The script checks each path in order and stops at the first match.
# Covers: 64-bit, 32-bit (legacy), and Enterprise/MSI deployments.
# -----------------------------------------------------------------------

$chromePaths = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "C:\Program Files\Google\Chrome\Application\GoogleChromeEnterprise\Application\chrome.exe"
)


# -----------------------------------------------------------------------
# SECTION 2: Fetch Latest Stable Chrome Version from Google's Public API
# -----------------------------------------------------------------------
# Google exposes a public REST API (no API key required) that returns
# Chrome release data per platform and channel.
#
# Endpoint used:
#   versionhistory.googleapis.com → win64 platform → stable channel
#   Results ordered by version descending, page size 1 = latest only.
#
# On failure (no internet, API down, parse error), the script sets
# status to "APIError" and exits 1 so Intune flags it for investigation.
# -----------------------------------------------------------------------

$requiredVersion = $null
$apiUrl = "https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions/all/releases?orderBy=version%20desc&pageSize=1"

try {
    # Fetch JSON response from Google's Version History API
    $response = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 15

    # Navigate the JSON structure: releases[0].version contains the version string
    # e.g., "136.0.7103.93"
    $latestVersionString = $response.releases[0].version
    $requiredVersion = [version]$latestVersionString

} catch {
    # API unreachable, response malformed, or version string couldn't be parsed.
    # Report APIError so the Intune admin knows the check could not complete.
    Write-Output "Status=APIError"
    Write-Output "RequiredVersion=Unknown"
    Write-Output "CurrentVersion=Unknown"
    Write-Output "Detail=Failed to retrieve latest Chrome version from Google API: $_"
    exit 1
}


# -----------------------------------------------------------------------
# SECTION 3: Detect Installed Chrome Version
# -----------------------------------------------------------------------
# Iterates through known Chrome install paths. On finding chrome.exe,
# reads the ProductVersion from the file's version metadata.
# Falls back to FileVersionInfo (.NET) if Get-Item fails.
# Stops at the first found executable (break after match).
# -----------------------------------------------------------------------

$currentVersion = $null

foreach ($path in $chromePaths) {
    if (Test-Path -Path $path) {
        try {
            # Primary method: read ProductVersion from file metadata via PowerShell
            $currentVersion = (Get-Item $path).VersionInfo.ProductVersion

        } catch {
            # Fallback method: use .NET FileVersionInfo directly
            # Useful if the PowerShell provider has access issues
            try {
                $fileInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
                $currentVersion = $fileInfo.ProductVersion
            } catch {
                $currentVersion = $null
            }
        }

        # Stop searching once Chrome is found at this path
        break
    }
}


# -----------------------------------------------------------------------
# SECTION 4: Compare Versions and Determine Compliance Status
# -----------------------------------------------------------------------
# Three possible outcomes:
#   A) Chrome found + version parseable + meets requirement → Compliant
#   B) Chrome found + version below requirement (or unparseable) → NotCompliant
#   C) Chrome not found at any known path → NotInstalled
# -----------------------------------------------------------------------

$status   = "NotInstalled"
$exitCode = 1

if ($currentVersion) {
    try {
        $installedVerObj = [version]$currentVersion

        if ($installedVerObj -ge $requiredVersion) {
            $status   = "Compliant"
            $exitCode = 0
        } else {
            $status   = "NotCompliant"
            $exitCode = 1
        }

    } catch {
        # Version string found but could not be cast to [version] type
        # Treat as NotCompliant and still report the raw string for diagnostics
        $status   = "NotCompliant"
        $exitCode = 1
    }

} else {
    # No chrome.exe found at any of the known paths
    $currentVersion = "None"
    $status         = "NotInstalled"
    $exitCode       = 1
}


# -----------------------------------------------------------------------
# SECTION 5: Output Results and Exit
# -----------------------------------------------------------------------
# Intune captures Write-Output lines in the detection script log.
# Always output all three fields so logs are consistent and easy to parse,
# regardless of the outcome.
# -----------------------------------------------------------------------

Write-Output "Status=$status"
Write-Output "RequiredVersion=$requiredVersion"
Write-Output "CurrentVersion=$currentVersion"

exit $exitCode