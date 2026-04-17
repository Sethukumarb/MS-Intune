<#
.SYNOPSIS
    Detects whether Mozilla Firefox is installed and up-to-date against the latest
    stable release, fetched live from Mozilla's official Product Details API.

.DESCRIPTION
    This script is designed as a Detection Script for Microsoft Intune Proactive
    Remediations. It performs the following steps:

      1. Queries Mozilla's public Product Details REST API to retrieve the latest
         stable Firefox version for Windows (no API key required).
      2. Checks the Windows Registry for an installed Firefox version (primary method).
      3. Falls back to reading the firefox.exe file version if registry is unavailable.
      4. Compares the installed version against the live latest stable version.
      5. Outputs Status, RequiredVersion, and CurrentVersion, then exits with the
         appropriate code for Intune to evaluate.

    Exit Codes:
      0 - Compliant   : Firefox is installed AND version >= latest stable
      1 - NotCompliant: Firefox is installed BUT version < latest stable
      1 - NotInstalled: Firefox was not found via registry or file path
      1 - APIError    : Could not reach Mozilla's API to determine required version

    Output format (captured by Intune remediation logs):
      Status=<Compliant|NotCompliant|NotInstalled|APIError>
      RequiredVersion=<version fetched from API | Unknown>
      CurrentVersion=<installed version | None>

.NOTES
    Script Name   : Detect-FirefoxVersionCompliance.ps1
    Author        : <Your Name / Team Name>
    Version       : 2.0.0
    Created       : 2025-04-17
    Last Modified : 2025-04-17

    Requirements:
      - Windows PowerShell 5.1 or later
      - Internet access from the device at time of execution
        (to reach product-details.mozilla.org)
      - Run as: SYSTEM account (default Intune context)

    Detection Priority:
      1. Registry: HKLM Uninstall keys (both 64-bit and 32-bit hives)
      2. Fallback: firefox.exe file version metadata

    API Used (public, no auth required):
      https://product-details.mozilla.org/1.0/firefox_versions.json
      Field used: LATEST_FIREFOX_VERSION

.EXAMPLE
    PS C:\> .\Detect-FirefoxVersionCompliance.ps1
    Status=Compliant
    RequiredVersion=136.0.1
    CurrentVersion=136.0.1

.LINK
    Mozilla Product Details API:
    https://product-details.mozilla.org/1.0/firefox_versions.json

    Microsoft Intune Proactive Remediations:
    https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations
#>


# -----------------------------------------------------------------------
# SECTION 1: Configuration — Registry and File Paths
# -----------------------------------------------------------------------
# Firefox can appear in multiple registry hive locations depending on
# whether it was installed as a 64-bit or 32-bit application, and whether
# the version label in the key name has changed across releases.
#
# Instead of hardcoding a version-specific key (which breaks on every
# update), we search the entire Uninstall hive for any key whose
# DisplayName contains "Mozilla Firefox". This is version-agnostic.
#
# The exe path is used as a fallback if no registry entry is found.
# -----------------------------------------------------------------------

$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

$firefoxExePath = "C:\Program Files\Mozilla Firefox\firefox.exe"


# -----------------------------------------------------------------------
# SECTION 2: Fetch Latest Stable Firefox Version from Mozilla's Public API
# -----------------------------------------------------------------------
# Mozilla exposes a public JSON endpoint (no API key required) that lists
# current version strings for all Firefox release channels.
#
# Endpoint: product-details.mozilla.org/1.0/firefox_versions.json
# Field used: LATEST_FIREFOX_VERSION (standard/stable release channel)
#
# On failure (no internet, API down, unexpected JSON structure), the
# script sets Status=APIError and exits 1 so Intune flags it for review.
# -----------------------------------------------------------------------

$requiredVersion = $null
$apiUrl = "https://product-details.mozilla.org/1.0/firefox_versions.json"

try {
    # Fetch the Firefox versions JSON from Mozilla's Product Details API
    $response = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 15

    # Extract the stable release version string, e.g. "136.0.1"
    $latestVersionString = $response.LATEST_FIREFOX_VERSION
    $requiredVersion = [version]$latestVersionString

} catch {
    # API unreachable, response malformed, or version string unparseable.
    # Exit with APIError so the admin knows the compliance check could not run.
    Write-Output "Status=APIError"
    Write-Output "RequiredVersion=Unknown"
    Write-Output "CurrentVersion=Unknown"
    Write-Output "Detail=Failed to retrieve latest Firefox version from Mozilla API: $_"
    exit 1
}


# -----------------------------------------------------------------------
# SECTION 3: Detect Installed Firefox Version
# -----------------------------------------------------------------------
# METHOD 1 — Registry Search (preferred)
#   Scans both the 64-bit and 32-bit Uninstall hives for any subkey
#   whose DisplayName contains "Mozilla Firefox". This approach is
#   version-agnostic — it does not rely on the key name including the
#   version number, which changes with every Firefox release.
#
# METHOD 2 — EXE File Version (fallback)
#   If no registry entry is found, reads the FileVersion metadata
#   directly from firefox.exe. Useful for non-standard or silent installs
#   that may not write a proper Uninstall registry key.
# -----------------------------------------------------------------------

$currentVersion = $null

# Method 1: Registry scan across both 64-bit and 32-bit hives
foreach ($hive in $registryPaths) {
    if (Test-Path $hive) {
        $subKeys = Get-ChildItem -Path $hive -ErrorAction SilentlyContinue

        foreach ($key in $subKeys) {
            try {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue

                # Match any Firefox entry regardless of version in the key name
                if ($props.DisplayName -like "*Mozilla Firefox*") {
                    $currentVersion = $props.DisplayVersion
                    break  # Stop at first match found
                }
            } catch {
                # Skip unreadable registry keys and continue scanning
                continue
            }
        }
    }

    # Exit the hive loop early if version already found in first hive
    if ($currentVersion) { break }
}

# Method 2: Fallback to firefox.exe file version metadata
if (-not $currentVersion -and (Test-Path $firefoxExePath)) {
    try {
        $currentVersion = (Get-Item $firefoxExePath).VersionInfo.FileVersion
    } catch {
        $currentVersion = $null
    }
}


# -----------------------------------------------------------------------
# SECTION 4: Compare Versions and Determine Compliance Status
# -----------------------------------------------------------------------
# Three possible outcomes:
#   A) Firefox found + version parseable + meets requirement → Compliant
#   B) Firefox found + version below requirement (or unparseable) → NotCompliant
#   C) Firefox not found via registry or exe path → NotInstalled
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
        # Version string found but could not be cast to [version] — treat as NotCompliant
        $status   = "NotCompliant"
        $exitCode = 1
    }

} else {
    # Firefox not found via registry or exe fallback
    $currentVersion = "None"
    $status         = "NotInstalled"
    $exitCode       = 1
}


# -----------------------------------------------------------------------
# SECTION 5: Output Results and Exit
# -----------------------------------------------------------------------
# Intune captures Write-Output lines in the detection script log.
# All three fields are always written for consistent, parseable log output
# regardless of the outcome path taken above.
# -----------------------------------------------------------------------

Write-Output "Status=$status"
Write-Output "RequiredVersion=$requiredVersion"
Write-Output "CurrentVersion=$currentVersion"

exit $exitCode