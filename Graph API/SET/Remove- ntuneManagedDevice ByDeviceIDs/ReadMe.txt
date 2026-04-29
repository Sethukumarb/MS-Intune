================================================================================
  README  -  Remove-IntuneManagedDeviceByDevicesIDs.ps1
  Author  :  Sethu Kumar B
  Version :  3.0
  Updated :  2025-04-28
================================================================================

OVERVIEW
--------
Bulk-deletes Intune Managed Device records via Microsoft Graph API.
Targets only Windows device entries under:
  Intune > Devices > Windows > Windows Devices

Does NOT touch Azure AD device objects or Autopilot enrollment entries.


--------------------------------------------------------------------------------
PREREQUISITES
--------------------------------------------------------------------------------

  PowerShell     :  5.1 or later
  App Reg Perm   :  DeviceManagementManagedDevices.ReadWrite.All
                    (Application permission, admin consented)


--------------------------------------------------------------------------------
FILES REQUIRED
--------------------------------------------------------------------------------

  Remove-IntuneManagedDevice.ps1   -  Main script
  DeviceIDs.txt                    -  Input file (one Managed Device ID per line)


--------------------------------------------------------------------------------
INPUT FILE FORMAT  (DeviceIDs.txt)
--------------------------------------------------------------------------------

  One Managed Device ID (GUID) per line. Blank lines are ignored.

  Example:
    xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
    zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz

  How to get the Managed Device ID:
    Intune Portal > Devices > Windows > Windows Devices
    > Click device > copy Device ID from the Overview pane.

  NOTE: This is NOT the Azure AD Device ID. Do not mix them up.


--------------------------------------------------------------------------------
CONFIGURATION  (top of script)
--------------------------------------------------------------------------------

  $TenantId      -  Your Azure AD Tenant ID
  $ClientId      -  App Registration Client ID
  $ClientSecret  -  App Registration Client Secret
  $InputFile     -  Path to DeviceIDs.txt  (default: same folder as script)
  $DryRun        -  See DRY RUN section below  *** READ BEFORE RUNNING ***
  $MaxBatchSize  -  See BATCH LIMIT section below


================================================================================
  *** DRY RUN MODE  -  ALWAYS RUN THIS FIRST ***
================================================================================

  $DryRun = $true    (DEFAULT)
      Script connects to Graph API, resolves each Device ID, and logs
      what WOULD be deleted — but performs ZERO deletions.
      Safe to run at any time. Use this to verify your input list.

  $DryRun = $false
      LIVE MODE. Deletions are PERMANENT and IRREVERSIBLE.
      Device loses MDM enrollment immediately.
      Only flip this after reviewing the Dry Run log.

  RECOMMENDED WORKFLOW:
    Step 1 - Set $DryRun = $true  > run > review log
    Step 2 - Confirm device names and count look correct
    Step 3 - Set $DryRun = $false > run again > actual deletion

  The script clearly labels every log line as DRY RUN or DELETED
  so there is no ambiguity about what mode was active.


================================================================================
  *** BATCH LIMIT  -  ABORT SAFEGUARD ***
================================================================================

  $MaxBatchSize = 1  (DEFAULT)

  If the input file contains MORE devices than this limit,
  the script ABORTS before connecting to Graph API. Nothing is deleted.

  This prevents accidental bulk deletion from a wrong input file.

  Change this number to whatever is appropriate for your run:
    $MaxBatchSize = 5       -  default, safe for testing
    $MaxBatchSize = 50      -  small controlled batch
    $MaxBatchSize = 500     -  larger batch run
    $MaxBatchSize = 5000    -  high-volume cleanup

  There is no upper system limit. You set the ceiling.


--------------------------------------------------------------------------------
LOGGING
--------------------------------------------------------------------------------

  Logs are written to:
    <script folder>\Logs\Remove-IntuneManagedDevice_YYYYMMDD_HHMMSS.log

  The Logs folder is created automatically if it does not exist.

  Each log entry includes:
    - Timestamp
    - Level   (INFO / SUCCESS / WARN / ERROR)
    - Device Name, OS, UPN, Device ID
    - Outcome per device (DELETED / WOULD DELETE / NOT FOUND / FAILED)
    - Final summary (total, deleted, not found, failed)


--------------------------------------------------------------------------------
WHAT THE SCRIPT DELETES
--------------------------------------------------------------------------------

  DELETES   :  Intune Managed Device record (MDM enrollment)
  DOES NOT  :  Delete Azure AD / Entra ID device object
  DOES NOT  :  Remove Autopilot enrollment entry
  DOES NOT  :  Wipe or retire the physical device

  If full device offboarding is required (Intune + AAD + Autopilot),
  a separate script with three API calls per device is needed.


--------------------------------------------------------------------------------
ERROR REFERENCE
--------------------------------------------------------------------------------

  NOT FOUND (404)  -  Device ID not in Intune. Already deleted or wrong ID.
  FAILED           -  Graph API error. HTTP status code logged. Check permissions.
  ABORTED          -  Input count exceeded MaxBatchSize. Reduce input or raise limit.
  Token Error      -  Verify TenantId, ClientId, ClientSecret in CONFIG block.


================================================================================
  END OF README
================================================================================
