<#
.SYNOPSIS
    Checks whether the device has been rebooted within the defined threshold period.

.DESCRIPTION
    This script is intended for use as an Intune Proactive Remediation Detection script.
    It performs the following tasks:
      1. Retrieves the last boot time of the device using WMI (Win32_OperatingSystem).
      2. Calculates the number of days elapsed since the last reboot.
      3. Compares the elapsed days against the defined threshold.
      4. Exits with code 1 (Non-Compliant) if the device has not rebooted within
         the threshold period, triggering the paired Remediation script.
      5. Exits with code 0 (Compliant) if the device is within the acceptable reboot window.
      6. Exits with code 1 as a fail-safe if the reboot time cannot be determined.

.NOTES
    Exit Codes:
      0 = Compliant   — Device rebooted within the last $DaysThreshold days. No action taken.
      1 = Non-Compliant — Device overdue for reboot, or uptime could not be determined.
                          Triggers the Remediation script.

    Deploy as: Intune > Devices > Scripts > Proactive Remediations (Detection script)
    Run as:    SYSTEM
    Architecture: 64-bit

.AUTHOR
    Sethu Kumar B

.VERSION
    1.1 - Added detailed synopsis, description, and inline comments
#>

#region ── CONFIGURATION ──────────────────────────────────────────────────────

$DaysThreshold = 7   # Number of days without reboot before device is flagged Non-Compliant

#endregion ────────────────────────────────────────────────────────────────────

try {

    # Retrieve the last boot time from the operating system via WMI
    $lastBoot      = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime

    # Calculate how many days have passed since the last reboot
    $daysSinceBoot = ((Get-Date) - $lastBoot).TotalDays

    Write-Host "Last reboot : $lastBoot"
    Write-Host "Days since  : $([math]::Round($daysSinceBoot, 1)) days"

    if ($daysSinceBoot -gt $DaysThreshold) {

        # Device has not rebooted within the threshold — flag as Non-Compliant
        Write-Host "NON-COMPLIANT — Device has not rebooted in over $DaysThreshold days."
        Exit 1   # Triggers the paired Remediation script

    } else {

        # Device is within the acceptable reboot window — no action needed
        Write-Host "COMPLIANT — Device rebooted within the last $DaysThreshold days."
        Exit 0

    }

} catch {

    # If uptime cannot be determined, fail safe and trigger remediation
    Write-Host "ERROR: $($_.Exception.Message)"
    Exit 1

}