<#
.SYNOPSIS
    Detects whether Docker Desktop is installed and up-to-date against the latest
    release, fetched live from the Microsoft WinGet package manifest on GitHub.

.DESCRIPTION
    This script is designed as a Detection Script for Microsoft Intune Proactive
    Remediations. It performs the following steps:

      1. Queries the GitHub Contents API to retrieve the latest Docker Desktop
         version available in the official Microsoft WinGet package repository
         (github.com/microsoft/winget-pkgs). This is Docker's official public
         release channel for Windows — no API key is required for public repos.
      2. Reads the installed Docker Desktop version from the Windows Registry
         Uninstall key (preferred method).
      3. Compares the installed version against the latest WinGet release version.
      4. Outputs Status, RequiredVersion, and CurrentVersion, then exits with the
         appropriate code for Intune to evaluate.

    NOTE: Docker Desktop does not publish a dedicated public version API endpoint
          (unlike Chrome or Firefox). The WinGet manifest on GitHub is the most
          reliable, official, and version-agnostic source for the latest stable
          release version on Windows.

    Exit Codes:
      0 - Compliant   : Docker Desktop is installed AND version >= latest release
      1 - NotCompliant: Docker Desktop is installed BUT version < latest release
      1 - NotInstalled: Docker Desktop was not found in the registry
      1 - APIError    : Could not reach GitHub API to determine required version

    Output format (captured by Intune remediation logs):
      Status=<Compliant|NotCompliant|NotInstalled|APIError>
      RequiredVersion=<version fetched from WinGet manifest | Unknown>
      CurrentVersion=<installed version | None>

.NOTES
    Script Name   : Detect-DockerDesktopVersionCompliance.ps1
    Author        : Sethu Kumar B
    Version       : 2.0.0
    Created       : 2025-04-17
    Last Modified : 2025-04-17

    Requirements:
      - Windows PowerShell 5.1 or later
      - Internet access from the device at time of execution
        (to reach api.github.com)
      - Run as: SYSTEM account (default Intune context)
      - Run context: 64-bit PowerShell

    Detection method:
      Registry key: HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop
      Property    : DisplayVersion

    Version Source (public, no auth required):
      GitHub API: https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/d/Docker/DockerDesktop
      Parses the highest version folder name from the WinGet manifest directory listing.

.EXAMPLE
    PS C:\> .\Detect-DockerDesktopVersionCompliance.ps1
    Status=Compliant
    RequiredVersion=4.40.0
    CurrentVersion=4.40.0

.LINK
    Docker Desktop Release Notes:
    https://docs.docker.com/desktop/release-notes/

    WinGet Package Manifest (Docker Desktop):
    https://github.com/microsoft/winget-pkgs/tree/master/manifests/d/Docker/DockerDesktop

    Microsoft Intune Proactive Remediations:
    https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations
#>


# -----------------------------------------------------------------------
# SECTION 1: Configuration — Registry Path for Docker Desktop
# -----------------------------------------------------------------------
# Docker Desktop registers itself in the Windows Uninstall hive under a
# fixed key name "Docker Desktop" (not version-specific), making registry
# detection straightforward and version-agnostic.
#
# Unlike Firefox ESR, this key name does NOT change between versions,
# so a direct path lookup is reliable across all Docker Desktop releases.
# -----------------------------------------------------------------------

$registryPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop"
$registryValue = "DisplayVersion"


# -----------------------------------------------------------------------
# SECTION 2: Fetch Latest Docker Desktop Version from WinGet Manifest
# -----------------------------------------------------------------------
# Docker Desktop does not publish a dedicated public JSON version API.
# The most authoritative public source for the latest stable Windows
# release is the Microsoft WinGet community package manifest repository
# on GitHub (microsoft/winget-pkgs).
#
# Strategy:
#   - Call the GitHub Contents API to list all version subfolders under
#     the Docker/DockerDesktop manifest path.
#   - Parse each folder name as a [version] object.
#   - Select the highest version — this is the latest stable release.
#
# The GitHub Contents API is public and requires no authentication for
# public repositories. A User-Agent header is required by GitHub's API
# policy; without it, requests return HTTP 403.
# -----------------------------------------------------------------------

$requiredVersion = $null
$apiUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/d/Docker/DockerDesktop"

try {
    # GitHub API requires a User-Agent header — requests without it return 403
    $headers = @{ "User-Agent" = "IntuneDetectionScript/2.0" }

    # Retrieve the directory listing of version folders from the WinGet manifest repo
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing -TimeoutSec 15

    # Each item in the response is a folder named after a Docker Desktop version (e.g., "4.40.0")
    # Filter to only directory entries, then cast names to [version] and select the highest
    $latestVersion = $response |
        Where-Object { $_.type -eq "dir" } |
        ForEach-Object {
            try { [version]$_.name } catch { $null }
        } |
        Where-Object { $_ -ne $null } |
        Sort-Object -Descending |
        Select-Object -First 1

    if (-not $latestVersion) {
        throw "No valid version folders found in WinGet manifest directory."
    }

    $requiredVersion = $latestVersion

} catch {
    # GitHub API unreachable, rate-limited, or response unparseable.
    Write-Output "Status=APIError"
    Write-Output "RequiredVersion=Unknown"
    Write-Output "CurrentVersion=Unknown"
    Write-Output "Detail=Failed to retrieve latest Docker Desktop version from WinGet manifest: $_"
    exit 1
}


# -----------------------------------------------------------------------
# SECTION 3: Detect Installed Docker Desktop Version
# -----------------------------------------------------------------------
# Docker Desktop uses a fixed registry key name ("Docker Desktop") that
# does not change between versions. This makes detection straightforward —
# a single direct registry path lookup is sufficient.
#
# The DisplayVersion property contains the version string as installed,
# e.g., "4.40.0" — matching the format used in the WinGet manifests.
# -----------------------------------------------------------------------

$currentVersion = $null

if (Test-Path $registryPath) {
    try {
        $regProps = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        if ($regProps.$registryValue) {
            $currentVersion = $regProps.$registryValue
        }
    } catch {
        $currentVersion = $null
    }
}


# -----------------------------------------------------------------------
# SECTION 4: Compare Versions and Determine Compliance Status
# -----------------------------------------------------------------------
# Three possible outcomes:
#   A) Docker Desktop found + version parseable + meets requirement → Compliant
#   B) Docker Desktop found + version below latest (or unparseable) → NotCompliant
#   C) No Docker Desktop registry entry found → NotInstalled
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
        # Version string present but not castable to [version] — treat as NotCompliant
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
# All fields are always written for consistent, parseable Intune log output.
# -----------------------------------------------------------------------

Write-Output "Status=$status"
Write-Output "RequiredVersion=$requiredVersion"
Write-Output "CurrentVersion=$currentVersion"

exit $exitCode