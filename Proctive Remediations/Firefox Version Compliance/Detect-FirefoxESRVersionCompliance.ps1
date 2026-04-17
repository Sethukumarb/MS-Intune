<#
.SYNOPSIS
    Detects whether Mozilla Firefox ESR (Extended Support Release) is installed
    and up-to-date against the latest ESR release, fetched live from Mozilla's
    official Product Details API.

.DESCRIPTION
    This script is designed as a Detection Script for Microsoft Intune Proactive
    Remediations. It performs the following steps:

      1. Queries Mozilla's public Product Details REST API to retrieve the latest
         Firefox ESR version (FIREFOX_ESR field — not the standard stable channel).
      2. Scans the Windows Registry Uninstall hive for any key whose DisplayName
         contains "Mozilla Firefox" and "ESR", covering both 64-bit and 32-bit hives.
      3. Falls back to reading firefox.exe file version if no registry entry is found.
      4. Compares the installed ESR version against the live latest ESR version.
      5. Outputs Status, RequiredVersion, and CurrentVersion, then exits with the
         appropriate code for Intune to evaluate.

    NOTE: Firefox ESR and Firefox Standard are separate release tracks.
          ESR versions follow a different numbering scheme (e.g., 115.x, 128.x, 140.x)
          and are intended for enterprise environments requiring longer support cycles.
          This script targets ESR exclusively.

    Exit Codes:
      0 - Compliant   : Firefox ESR is installed AND version >= latest ESR release
      1 - NotCompliant: Firefox ESR is installed BUT version < latest ESR release
      1 - NotInstalled: Firefox ESR was not found via registry or file path
      1 - APIError    : Could not reach Mozilla's API to determine required ESR version

    Output format (captured by Intune remediation logs):
      Status=<Compliant|NotCompliant|NotInstalled|APIError>
      RequiredVersion=<ESR version fetched from API | Unknown>
      CurrentVersion=<installed version | None>

.NOTES
    Script Name   : Detect-FirefoxESRVersionCompliance.ps1
    Author        : Sethu Kumar B
    Version       : 2.0.0
    Created       : 2025-04-17
    Last Modified : 2025-04-17

    Requirements:
      - Windows PowerShell 5.1 or later
      - Internet access from the device at time of execution
        (to reach product-details.mozilla.org)
      - Run as: SYSTEM account (default Intune context)
      - Targets Firefox ESR only — will NOT match standard Firefox installs

    Detection Priority:
      1. Registry: Scans HKLM Uninstall keys (64-bit and 32-bit hives)
                   Matches DisplayName containing both "Mozilla Firefox" AND "ESR"
      2. Fallback: firefox.exe FileVersion metadata from default install path

    API Used (public, no auth required):
      https://product-details.mozilla.org/1.0/firefox_versions.json
      Field used: FIREFOX_ESR  (e.g., "128.12.0esr" → normalized to "128.12.0")

.EXAMPLE
    PS C:\> .\Detect-FirefoxESRVersionCompliance.ps1
    Status=Compliant
    RequiredVersion=128.12.0
    CurrentVersion=128.12.0

.LINK
    Mozilla Product Details API:
    https://product-details.mozilla.org/1.0/firefox_versions.json

    Firefox ESR Release Calendar:
    https://wiki.mozilla.org/Release_Management/Calendar

    Microsoft Intune Proactive Remediations:
    https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations
#>


# -----------------------------------------------------------------------
# SECTION 1: Configuration — Registry and File Paths
# -----------------------------------------------------------------------
# Firefox ESR registers itself in the Windows Uninstall hive with a
# DisplayName such as:
#   "Mozilla Firefox 128.12.0 ESR (x64 en-US)"
#
# Because the key name includes the version number, it changes with every
# ESR update. Instead of hardcoding a version-specific key path (which
# breaks on every update), we scan the full Uninstall hive and match on
# DisplayName containing BOTH "Mozilla Firefox" AND "ESR".
#
# This correctly excludes standard Firefox installs (which have no "ESR"
# in their DisplayName) while remaining version-agnostic.
# -----------------------------------------------------------------------

$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

# Default ESR installation path — used as fallback if registry check fails
$firefoxESRExePath = "C:\Program Files\Mozilla Firefox\firefox.exe"


# -----------------------------------------------------------------------
# SECTION 2: Fetch Latest Firefox ESR Version from Mozilla's Public API
# -----------------------------------------------------------------------
# Mozilla's Product Details API returns version strings for all release
# channels in a single JSON response. The field we need is:
#
#   FIREFOX_ESR — e.g., "128.12.0esr"
#
# IMPORTANT: The ESR version string from the API includes the "esr" suffix
# (e.g., "128.12.0esr"). This suffix must be stripped before casting to
# the [version] type, which only accepts numeric dotted strings.
#
# This is different from the standard stable field (LATEST_FIREFOX_VERSION)
# used for non-ESR Firefox detection.
# -----------------------------------------------------------------------

$requiredVersion = $null
$apiUrl = "https://product-details.mozilla.org/1.0/firefox_versions.json"

try {
    # Call Mozilla's Product Details API
    $response = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 15

    # Extract the ESR version string — e.g., "128.12.0esr"
    $esrVersionRaw = $response.FIREFOX_ESR

    # Strip the "esr" suffix to get a clean numeric version string — e.g., "128.12.0"
    $esrVersionClean = $esrVersionRaw -replace "esr", ""
    $requiredVersion = [version]$esrVersionClean

} catch {
    # API unreachable, unexpected JSON structure, or version string unparseable.
    Write-Output "Status=APIError"
    Write-Output "RequiredVersion=Unknown"
    Write-Output "CurrentVersion=Unknown"
    Write-Output "Detail=Failed to retrieve latest Firefox ESR version from Mozilla API: $_"
    exit 1
}


# -----------------------------------------------------------------------
# SECTION 3: Detect Installed Firefox ESR Version
# -----------------------------------------------------------------------
# METHOD 1 — Registry Scan (preferred)
#   Scans both 64-bit and 32-bit Uninstall hives. Matches only keys where
#   DisplayName contains BOTH "Mozilla Firefox" AND "ESR" to avoid false
#   matches against standard Firefox installs on the same device.
#
# METHOD 2 — EXE File Version (fallback)
#   Firefox ESR and standard Firefox share the same default install path:
#     C:\Program Files\Mozilla Firefox\firefox.exe
#   This fallback is only used when no ESR registry entry is found.
#   Note: If standard Firefox is installed at the same path, this fallback
#   may return a non-ESR version — registry method is strongly preferred.
# -----------------------------------------------------------------------

$currentVersion = $null

# Method 1: Registry scan — match DisplayName containing "Mozilla Firefox" AND "ESR"
foreach ($hive in $registryPaths) {
    if (Test-Path $hive) {
        $subKeys = Get-ChildItem -Path $hive -ErrorAction SilentlyContinue

        foreach ($key in $subKeys) {
            try {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue

                # Must match BOTH "Mozilla Firefox" AND "ESR" to target ESR specifically
                if ($props.DisplayName -like "*Mozilla Firefox*" -and $props.DisplayName -like "*ESR*") {
                    $currentVersion = $props.DisplayVersion
                    break
                }
            } catch {
                continue
            }
        }
    }

    if ($currentVersion) { break }
}

# Method 2: Fallback to firefox.exe file version
if (-not $currentVersion -and (Test-Path $firefoxESRExePath)) {
    try {
        $currentVersion = (Get-Item $firefoxESRExePath).VersionInfo.FileVersion
    } catch {
        $currentVersion = $null
    }
}


# -----------------------------------------------------------------------
# SECTION 4: Compare Versions and Determine Compliance Status
# -----------------------------------------------------------------------
# Three possible outcomes:
#   A) ESR found + version parseable + meets requirement → Compliant
#   B) ESR found + version below latest ESR (or unparseable) → NotCompliant
#   C) No ESR entry found in registry or at exe path → NotInstalled
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
        # Version string present but not parseable as [version] — treat as NotCompliant
        $status   = "NotCompliant"
        $exitCode = 1
    }

} else {
    $currentVersion = "None"
    $status         = "NotInstalled"
    $exitCode       = 1
}


# -----------------------------------------------------------------------
# SECTION 5: Output Results and Exit
# -----------------------------------------------------------------------
# All three output fields are always written for consistent log output
# in Intune, regardless of the compliance outcome.
# -----------------------------------------------------------------------

Write-Output "Status=$status"
Write-Output "RequiredVersion=$requiredVersion"
Write-Output "CurrentVersion=$currentVersion"

exit $exitCode