<#
.SYNOPSIS
    Detects and reports the last reboot time of a Windows device for Microsoft Intune compliance monitoring.

.DESCRIPTION
    This script retrieves the last boot/reboot time of the local Windows operating system
    using WMI (Windows Management Instrumentation). It is designed to be used as a
    Detection Script within Microsoft Intune Proactive Remediations or custom compliance
    policies. The output is formatted as a human-readable string that Intune can capture
    in its remediation logs or compliance reporting dashboard.

    When successful, the script writes the last reboot timestamp to standard output and
    exits with code 0 (success). If an error occurs (e.g., WMI service unavailable,
    insufficient permissions), it writes a descriptive error message and exits with
    code 1 (failure), signalling to Intune that detection was unsuccessful.

.NOTES
    Script Name   : Detect-LastRebootTime.ps1
    Author        : Sethu Kumar B
    Version       : 1.0.0
    Created       : 2025-04-01
    Last Modified : 2025-04-01

    Requirements:
      - Windows PowerShell 5.1 or later
      - Run context: SYSTEM account (default for Intune scripts)
      - WMI service must be running on the target device

    Deployment:
      - Deploy via Microsoft Intune > Devices > Scripts & remediations
      - Assign as the "Detection Script" in a Proactive Remediation package
      - Run in 64-bit PowerShell: Recommended
      - Run as logged-on user: No (run as SYSTEM)

    Exit Codes:
      0 - Success: Last boot time retrieved and written to output
      1 - Failure: WMI query failed or an unexpected error occurred

.EXAMPLE
    Run manually in PowerShell:
    PS C:\> .\Detect-LastRebootTime.ps1
    Device last rebooted on: 04/15/2025 08:32:11

.LINK
    Microsoft Intune Proactive Remediations:
    https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations
#>


# -----------------------------------------------------------------------
# SECTION 1: Retrieve Operating System Information via WMI
# -----------------------------------------------------------------------
# Uses the Win32_OperatingSystem WMI class to access system-level metadata.
# The LastBootUpTime property is stored in WMI DMTF datetime format
# (e.g., "20250415083211.000000+000"), so it must be converted to a
# standard .NET DateTime object before it can be displayed.
# -----------------------------------------------------------------------

try {

    # Step 1: Query WMI for the Win32_OperatingSystem object.
    # This object contains properties about the OS, including boot time,
    # OS version, total/free memory, and more.
    $os = Get-WmiObject -Class Win32_OperatingSystem

    # Step 2: Convert the raw WMI datetime string (LastBootUpTime) into
    # a .NET DateTime object using the built-in ConvertToDateTime() method.
    # Without this conversion, the value is an unreadable DMTF string.
    $lastBootTime = $os.ConvertToDateTime($os.LastBootUpTime)

    # Step 3: Output the result in a human-readable format.
    # Intune captures this Write-Output value in the detection script log,
    # making it visible in the remediation run results in the Intune portal.
    Write-Output "Device last rebooted on: $lastBootTime"

    # Implicit exit code 0 (success) — PowerShell exits 0 when no exit is specified
    # and no terminating error occurs.

} catch {

    # -----------------------------------------------------------------------
    # SECTION 2: Error Handling
    # -----------------------------------------------------------------------
    # Catches any terminating errors from the try block above, such as:
    #   - WMI service not running (winmgmt service stopped)
    #   - Insufficient permissions to query Win32_OperatingSystem
    #   - Corrupted WMI repository
    #
    # The $_ automatic variable holds the current error record, including
    # the exception message, which is appended to the output for diagnostics.
    # -----------------------------------------------------------------------

    Write-Output "Error retrieving last boot time: $_"

    # Exit code 1 signals FAILURE to Intune.
    # Intune will mark the detection as failed and can trigger a
    # remediation script in response (if one is configured in the package).
    exit 1
}