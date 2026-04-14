==============================================================================
 Script Name  : Get-IntuneDeviceSummary.ps1
 Version      : 1.2
 Author       : Sethu Kumar B
 Created      : 2026-03-25
 Last Modified: 2026-03-25
 Type         : READ ONLY — No changes are made to any system
==============================================================================

OVERVIEW
--------
Get-IntuneDeviceSummary.ps1 retrieves a comprehensive device summary from
Microsoft Intune using the Graph API BETA endpoint. It supports two input
modes — looking up specific devices by hostname from a text file, or pulling
the full Intune device inventory with an optional OS filter.

For every device found, the script fetches the complete $entity payload
directly by device ID, which guarantees all fields are returned — including
the last logged on user, which is not available in standard list responses.

This script does NOT make any changes. It is safe to run in production.


WHY THIS SCRIPT EXISTS
----------------------
The standard Intune portal and basic Graph API list queries do not always
return every field for a device. Specifically:

  - The list endpoint (/managedDevices?$filter=...) excludes certain fields
    such as usersLoggedOn from its response regardless of $select usage.
  - Using $filter and $select together on the Intune managed devices endpoint
    causes an HTTP 400 Bad Request error.

This script solves both problems by:
  1. Using $filter without $select for the initial hostname search (avoids 400).
  2. Fetching the full $entity record for every matched device by its device ID,
     which returns the complete payload including usersLoggedOn and all other
     fields visible in Graph Explorer.

The result is a single CSV with a full picture of every device — identity,
OS, users, enrollment, management state, Entra ID details, and security.


WHEN TO USE THIS SCRIPT
-----------------------
  - You need a full device inventory export from Intune.
  - You need to look up specific devices by hostname and get their full details.
  - You need to identify the last logged on user for a device (not just the
    primary user).
  - You are auditing enrollment types, compliance state, or encryption status
    across the fleet.
  - You need serial numbers, BIOS versions, or hardware details for a list of
    devices.
  - You are preparing data for asset management, audit, or reporting purposes.


HOW IT WORKS
------------
  1. Authenticates to Microsoft Graph API using an Azure AD App Registration
     (client credentials flow).

  2. Depending on the input mode selected:

       File Mode  — Reads Hostnames.txt from the script folder.
                    For each hostname:
                      Step 1: Search Intune using:
                              GET /beta/deviceManagement/managedDevices
                                  ?$filter=deviceName eq '{name}'
                              ($select intentionally omitted — $filter + $select
                               causes HTTP 400 on the Intune endpoint.)
                      Step 2: Fetch the full $entity by device ID:
                              GET /beta/deviceManagement/managedDevices/{id}
                              (Guarantees all fields including usersLoggedOn.)
                      Step 3: Resolve the last logged on user GUID to UPN:
                              GET /beta/users/{userId}?$select=userPrincipalName

       All Mode   — Pulls all devices from Intune using pagination.
                    Applies an OS filter client-side (default: Windows).
                    Fetches full $entity for every device in the result set.

  3. Exports all results to a timestamped CSV in the script folder.


INPUT MODES
-----------
  The script supports two modes selected at runtime (or pre-configured):

  Mode 1 — Hostname File
    Reads Hostnames.txt from the script folder.
    One hostname per line. Blank lines are ignored.
    Duplicates are automatically removed.
    OS filter is NOT applied in file mode — returns the device as-is.
    Devices not found in Intune are included in the CSV as NOT FOUND rows.

  Mode 2 — All Devices
    Pulls the entire Intune managed device inventory.
    Supports OS filter: All, Windows, macOS, iOS, Android, Linux
    Default OS filter is Windows.
    Paginated — handles large environments automatically.


PREREQUISITES
-------------
  1. Azure AD App Registration with the following Application permissions
     (Admin Consent must be granted):

       DeviceManagementManagedDevices.Read.All  — Read Intune device records
       User.Read.All                            — Resolve user GUIDs to UPNs

  2. Fill in the CONFIGURATION section at the top of the script:
       $TenantID     = "your-tenant-id"
       $ClientID     = "your-client-id"
       $ClientSecret = "your-client-secret"

  3. PowerShell 5.1 or later. No additional modules required.


INPUT FILE
----------
  File Name : Hostnames.txt
  Location  : Same folder as the script (script root folder)
  Format    : One device hostname per line. Blank lines are ignored.
              Hostnames are automatically uppercased and deduplicated.

  Example:
    WP-5k2ChJSOHb
    WP-VegpHYqeeM
    WP-LT-00142

  Note: Only required when running in File Mode (Mode 1).
        Not needed when running in All Devices Mode (Mode 2).


OUTPUT FILE
-----------
  Saved to the same folder as the script.

  File Name : B11_All_IntuneDeviceSummary_[OsLabel]_[yyyyMMdd_HHmmss].csv

  OsLabel is either the OS filter value (e.g. Windows) or ByHostname
  depending on the mode used.

  Example:
    All_IntuneDeviceSummary_Windows_20260402_143022.csv
    All_IntuneDeviceSummary_ByHostname_20260402_143022.csv


CSV COLUMNS
-----------
  IDENTITY
    DeviceName                   — Intune device name
    ManagedDeviceName            — Managed device name (Intune generated)
    FQDN                         — Fully qualified domain name
    SerialNumber                 — Hardware serial number
    Manufacturer                 — Device manufacturer
    Model                        — Device model
    ChassisType                  — Form factor (e.g. laptop, desktop)
    BIOSVersion                  — System BIOS version
    WiFiMacAddress               — Wi-Fi MAC address

  OS
    OperatingSystem              — OS platform (Windows, macOS, etc.)
    OSVersion                    — Full OS build version string
    OSFriendlyName               — Human-readable OS name (e.g. Win11 23H2)
    SKUFamily                    — Windows SKU family

  USERS
    PrimaryUserDisplayName       — Display name of the primary user
    PrimaryUserEmail             — UPN of the primary user
    PrimaryUserEmailAddress      — Email address of the primary user
    EnrolledByEmail              — UPN of the user who enrolled the device
    LastLogonEmail               — UPN of the most recently logged on user
    LastLogonDateTime            — Timestamp of the most recent logon

  ENROLLMENT
    EnrolledDateTime             — Date and time the device was enrolled
    EnrollmentType               — Enrollment method used
    EnrollmentProfileName        — Autopilot or enrollment profile name
    JoinType                     — Azure AD join type
    AutopilotEnrolled            — Whether enrolled via Autopilot (True/False)
    AzureADRegistered            — Azure AD registered status
    AADRegistered                — AAD registered flag

  MANAGEMENT
    ManagementState              — Current management state
    ManagementAgent              — Management agent type
    ComplianceState              — Compliant / Non-compliant / Unknown
    OwnerType                    — Corporate or Personal
    DeviceRegistrationState      — Registration state in Azure AD
    LastSyncDateTime             — Last Intune check-in timestamp

  ENTRA ID
    AzureADDeviceId              — Azure AD Device ID (GUID)
    AzureActiveDirectoryDeviceId — Azure Active Directory Device ID

  SECURITY
    IsEncrypted                  — Whether the device is encrypted (True/False)


IMPORTANT NOTES
---------------
  - READ ONLY: This script only performs GET requests. It does not create,
    modify, or delete any records in Intune or Azure AD.
  - In File Mode, if a hostname is not found in Intune, a NOT FOUND row is
    still added to the CSV so nothing is silently skipped.
  - In All Devices Mode, a 100ms delay is applied between entity fetches to
    avoid Graph API throttling. In File Mode the delay is 200ms.
  - The $select parameter is intentionally omitted from the initial search
    query. Using $filter and $select together on the Intune managed devices
    endpoint returns HTTP 400 Bad Request.
  - The full $entity fetch (Step 2) is always performed per device to ensure
    usersLoggedOn and all other fields are populated correctly.
  - All file paths use $PSScriptRoot — input and output always resolve to the
    same folder as the script regardless of where PowerShell is launched from.
  - In All Devices Mode, large environments with thousands of devices will
    take longer due to the per-device entity fetch. This is by design.


CHANGE LOG
----------
  v1.0 — 2026-03-25 — Sethu Kumar B — Initial release.
  v1.1 — 2026-03-25 — Sethu Kumar B — Fixed HTTP 400: removed $select
                       from file-mode URI.
  v1.2 — 2026-03-25 — Sethu Kumar B — Expanded all $entity fields into CSV.
                       Added per-device entity fetch (Step 2) to guarantee
                       usersLoggedOn is populated. Fixed All-mode to avoid
                       $filter + $select. Updated NOT FOUND placeholder to
                       match full column set.

==============================================================================