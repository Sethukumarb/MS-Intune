================================================================================
 INTUNE PROACTIVE REMEDIATION — REBOOT CHECK
 Detect-DeviceReboot.ps1  |  Invoke-RebootNotification.ps1
================================================================================

OVERVIEW
--------
This solution uses Intune Proactive Remediation to detect devices that have not
been rebooted within a defined number of days, and surfaces a WPF toast-style
notification to the logged-on user prompting them to restart.

--------------------------------------------------------------------------------
FILES
--------------------------------------------------------------------------------
Detect-DeviceReboot.ps1
    Detection script. Checks last boot time via WMI. Exits 1 (Non-Compliant)
    if the device has not rebooted within the threshold, triggering remediation.
    Exits 0 (Compliant) if within the acceptable window.

Invoke-RebootNotification.ps1
    Remediation script. When run as SYSTEM (Intune default), it writes a
    user-session script to disk and launches it via a one-shot Scheduled Task
    in the context of the logged-on user. The user-session script renders a
    WPF notification dialog with two options:
      - Restart Now  : Starts a live countdown timer and reboots the device.
      - Postpone     : Schedules a silent reboot via shutdown.exe after N hours.

--------------------------------------------------------------------------------
CONFIGURATION (edit top of each script)
--------------------------------------------------------------------------------
Detect-DeviceReboot.ps1
  $DaysThreshold      — Days without reboot before flagging Non-Compliant (default: 7)

Invoke-RebootNotification.ps1
  $DAYS_THRESHOLD     — Must match detection script (default: 7)
  $REBOOT_COUNTDOWN   — Minutes before reboot fires when Restart Now is clicked (default: 3)
  $POSTPONE_HOURS     — Hours until auto-reboot after Postpone is clicked (default: 2)
  $PRIMARY_COLOR      — Hex color for banner, buttons, and accent bar (default: #0078D4)
  $FOOTER_TEXT        — Support message shown at the bottom of the notification dialog

--------------------------------------------------------------------------------
INTUNE DEPLOYMENT
--------------------------------------------------------------------------------
  Policy type    : Proactive Remediation
  Detection      : Detect-DeviceReboot.ps1
  Remediation    : Invoke-RebootNotification.ps1
  Run as account : SYSTEM
  Architecture   : 64-bit
  Schedule       : Daily (recommended)

--------------------------------------------------------------------------------
HOW IT WORKS
--------------------------------------------------------------------------------
1. Intune runs Detect-DeviceReboot.ps1 as SYSTEM on the device.
2. If Non-Compliant (Exit 1), Intune runs Invoke-RebootNotification.ps1 as SYSTEM.
3. The remediation script collects boot info while running as SYSTEM (full WMI access),
   writes a self-contained user-session script to C:\ProgramData\IT\Notifications\,
   and registers a one-shot Scheduled Task to launch it under the logged-on user account.
4. The Scheduled Task runs the user-session script, which renders the WPF notification.
5. After 15 seconds (enough for the WPF window to open), the launch task is deleted.
6. The user interacts with the dialog — Restart Now or Postpone.

--------------------------------------------------------------------------------
KNOWN BEHAVIOURS
--------------------------------------------------------------------------------
- If no user is logged on when remediation runs, the script exits cleanly (Exit 0)
  and no notification is shown. Intune will retry on the next scheduled run.
- Postpone uses shutdown.exe directly — no additional scheduled tasks are created.
- The Restart Now countdown calls shutdown.exe once and counts down in the UI only.
  Closing the window before the timer ends does NOT cancel the scheduled reboot.
  To cancel manually: run  shutdown /a  from an elevated prompt.

--------------------------------------------------------------------------------
VERSION HISTORY
--------------------------------------------------------------------------------
Detection Script
  1.0 - Initial release
  1.1 - Added detailed synopsis, description, and inline comments

Remediation Script
  1.0 - Initial release
  2.0 - Bulletproof session-launch pattern via Scheduled Task
  2.1 - Fixed EndBoundary XML schema error on postpone task
  2.2 - Removed DeleteExpiredTaskAfter, added try/catch
  3.0 - Removed all scheduled-task logic from Postpone entirely.
        Postpone now calls shutdown /r /t directly. Zero dependencies.
================================================================================