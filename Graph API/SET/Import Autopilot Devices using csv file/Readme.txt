===============================================================================
 Import-AutopilotDevices.ps1  |  README
 Author: Sethu Kumar B  |  Version: 1.5
===============================================================================

WHAT IT DOES
------------
Imports Windows Autopilot hardware hashes from one or more CSV files into
Microsoft Intune via Graph API. Polls import status and exports a full
per-device result CSV.


REQUIREMENTS
------------
- PowerShell 5.1 or later
- Azure AD App Registration with admin-consented application permission:
    DeviceManagementServiceConfig.ReadWrite.All
- TLS 1.2 (enabled automatically by script)


SETUP
-----
1. Open script and fill in the CONFIGURATION section:
     $TenantID     = "your-tenant-id"
     $ClientID     = "your-app-client-id"
     $ClientSecret = "your-app-secret"

2. Create an "Import" subfolder next to the script.

3. Place one or more hardware hash CSV files in the Import folder.


CSV FORMAT
----------
Required columns:
  Device Serial Number
  Hardware Hash

Optional columns:
  Windows Product ID
  Group Tag


HOW TO RUN
----------
Right-click the script > Run with PowerShell
  -- or --
Open PowerShell and run:
  .\Import-AutopilotDevices.ps1


OUTPUT (saved to script folder)
-------------------------------
  AutopilotImport_[timestamp].csv          Per-device import status
  AutopilotImport_[timestamp].log          Structured run log
  AutopilotImport_Transcript_[timestamp].log  Full PS transcript


IMPORT STATUS VALUES
--------------------
  complete            Successfully imported into Autopilot
  error               Import failed  (see StatusDetail column)
  pending             Still processing when poll timeout was reached
  unknown             Not yet processed


NOTES
-----
- Batches up to 500 devices per API call automatically
- Group Tag applied during import if present; omitted if blank
- Polls every 30 seconds, timeout at 30 minutes (configurable)
- Script is read-only after import - does not delete or modify devices

===============================================================================