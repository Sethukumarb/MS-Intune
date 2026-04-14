==============================================================================
 Script Name  : Get-UserDevices.ps1
 Version      : 1.0
 Author       : Sethu Kumar B
 Created      : 2026-04-03
 Last Modified: 2026-04-03
 Type         : READ ONLY — No changes are made to any system
==============================================================================

OVERVIEW
--------
Get-UserDevices.ps1 retrieves all devices associated with one or more users
from both Microsoft Intune and Azure AD (Entra ID). It reads a list of user
email addresses from a text file, queries both systems for each user, combines
and deduplicates the results, and exports a separate CSV file per user.

The script also produces a full PowerShell transcript and a custom action log
for complete auditability of every step.

This script does NOT make any changes. It is safe to run in production.


WHY THIS SCRIPT EXISTS
----------------------
When investigating a user's devices — for example during offboarding, a
security review, or a compliance audit — devices may exist in Intune as
managed device records, in Azure AD as registered device objects, or in both.
Checking each system separately is time-consuming and risks missing records.

This script solves that by:
  - Querying Intune managed devices for the user by UPN and email address.
  - Querying Azure AD registered devices via the user's registeredDevices
    relationship.
  - Combining both result sets and deduplicating by device name and source.
  - Clearly labelling each record with its source so you know exactly where
    it came from — Intune, Azure AD, or both.
  - Exporting one CSV per user so results are easy to review individually.


WHEN TO USE THIS SCRIPT
-----------------------
  - You are offboarding a user and need to identify all their devices across
    Intune and Azure AD before wiping or retiring them.
  - You are running a compliance or security audit on specific users.
  - You need to check whether a user's device is Intune-enrolled, only Azure
    AD registered, or appearing in both systems.
  - You are investigating a device issue and need a full picture of all
    devices linked to a user account.
  - You need to bulk-process multiple users from a list in one run.


HOW IT WORKS
------------
  1. Reads users.txt from the script folder — one email address per line.

  2. Authenticates to Microsoft Graph using an Azure AD App Registration
     (client credentials flow via Connect-MgGraph).

  3. For each email address:

       Intune Query:
         GET /v1.0/deviceManagement/managedDevices
             ?$select=id,deviceName,userPrincipalName,emailAddress,
                      serialNumber,operatingSystem,azureADDeviceId
         Matches devices where userPrincipalName or emailAddress equals
         the user's email. Optional OS filter applied here.

       Azure AD Query:
         GET /v1.0/users?$filter=userPrincipalName eq '{email}'
                                  or mail eq '{email}'
         Then for each matched user:
         GET /v1.0/users/{id}/registeredDevices
             ?$select=id,deviceId,displayName,operatingSystem
         Optional OS filter applied here.

  4. Combines both result sets, deduplicates by DeviceName + DeviceSource,
     and exports to a per-user CSV file in the script folder.

  5. Writes a transcript and action log for every step.


AUTHENTICATION METHOD
---------------------
  This script uses the Microsoft Graph PowerShell SDK (Connect-MgGraph)
  with app-only authentication (client credentials).

  Unlike other scripts in this library that use Invoke-RestMethod directly,
  this script requires the Microsoft Graph PowerShell SDK to be installed:

    Install-Module Microsoft.Graph -Scope CurrentUser

  The TenantId, ClientId, and ClientSecret are passed as script parameters
  or can be set as defaults in the param() block at the top of the script.


PREREQUISITES
-------------
  1. Microsoft Graph PowerShell SDK installed:
       Install-Module Microsoft.Graph -Scope CurrentUser

  2. Azure AD App Registration with the following Application permissions
     (Admin Consent must be granted):

       DeviceManagementManagedDevices.Read.All  — Read Intune managed devices
       Device.Read.All                          — Read Azure AD device objects
       User.Read.All                            — Look up users by email / UPN

  3. Fill in the param() block at the top of the script or pass at runtime:
       $TenantId     = "your-tenant-id"
       $ClientId     = "your-client-id"
       $ClientSecret = "your-client-secret"

  4. PowerShell 5.1 or later.


INPUT FILE
----------
  File Name : users.txt
  Location  : Same folder as the script (script root folder)
  Format    : One user email address per line. Blank lines are ignored.

  Example:
    john.doe@contoso.com
    jane.smith@contoso.com
    bob.jones@contoso.com

  The default file name is users.txt. This can be overridden at runtime:
    .\Get-UserDevices.ps1 -InputFile "myusers.txt"


OS FILTER
---------
  The script supports an optional OS filter via the -TargetOS parameter.
  Default value is Windows.

  Examples:
    .\Get-UserDevices.ps1 -TargetOS "Windows"
    .\Get-UserDevices.ps1 -TargetOS "iOS"
    .\Get-UserDevices.ps1 -TargetOS "macOS"
    .\Get-UserDevices.ps1 -TargetOS "Android"
    .\Get-UserDevices.ps1 -TargetOS ""        (no filter — returns all OS)

  The OS filter is applied to both the Intune and Azure AD result sets.


OUTPUT FILES
------------
  All files are saved to the same folder as the script.

  Per-user CSV  : [email]-Devices.csv — one file per user processed.
                  The @ symbol in the email is replaced with _at_ for a
                  safe, readable filename.

  Transcript    : Get-UserDevices-Transcript.log
                  Full PowerShell transcript of the entire script run.

  Action Log    : Get-UserDevices-Actions.log
                  Timestamped log of key events, warnings, and errors.

  Example output files for john.doe@contoso.com:
    john.doe_at_contoso.com-Devices.csv
    Get-UserDevices-Transcript.log
    Get-UserDevices-Actions.log


CSV COLUMNS
-----------
  UserEmail          — Email address used to look up this user
  DeviceSource       — Where the record came from:
                         "Intune (Managed Device)"      — from /managedDevices
                         "Azure AD (Registered Device)" — from /registeredDevices
  DeviceName         — Device hostname / display name
  IntuneDeviceId     — Intune managed device GUID (blank for AAD-only records)
  AzureADDeviceId    — Azure AD Device ID (GUID)
  AzureADObjectId    — Azure AD Object ID of the device
  UserPrincipalName  — UPN of the user the device is associated with
  SerialNumber       — Hardware serial number (Intune records only)
  OperatingSystem    — OS platform (Windows, macOS, iOS, Android, etc.)


DEVICE SOURCE EXPLAINED
-----------------------
  Every row in the CSV has a DeviceSource column that tells you exactly
  where the record was retrieved from:

  "Intune (Managed Device)"
    The device is enrolled in Intune. Record retrieved from:
    GET /v1.0/deviceManagement/managedDevices
    These records have IntuneDeviceId and SerialNumber populated.

  "Azure AD (Registered Device)"
    The device appears in the user's registeredDevices relationship in
    Azure AD / Entra ID. Retrieved from:
    GET /v1.0/users/{id}/registeredDevices
    The device may or may not be Intune-enrolled.
    IntuneDeviceId and SerialNumber will be blank for these records.


EMPTY USER OUTPUT
-----------------
  If no devices are found for a user in either system, the script still
  creates a CSV file for that user containing a single blank placeholder
  row. This ensures every user in the input file has an output file —
  nothing is silently skipped.


IMPORTANT NOTES
---------------
  - READ ONLY: This script only performs GET requests. It does not create,
    modify, or delete any records in Intune or Azure AD.
  - This script requires the Microsoft Graph PowerShell SDK. It uses
    Connect-MgGraph and Invoke-MgGraphRequest — not Invoke-RestMethod.
    This is different from other scripts in this library.
  - The default OS filter is Windows. Pass -TargetOS "" to return all
    platforms with no filtering.
  - Deduplication is applied by DeviceName + DeviceSource. If the same
    device appears in both Intune and Azure AD it will appear as two
    separate rows — one per source — since the source differs.
  - The @ symbol in email addresses is replaced with _at_ in filenames
    to keep output filenames filesystem-safe and readable.
  - All output paths use the script root folder resolved via
    Split-Path -Parent $MyInvocation.MyCommand.Path — consistent
    regardless of where PowerShell is launched from.


CHANGE LOG
----------
  v1.0 — 2026-04-03 — Sethu Kumar B — Initial release.

==============================================================================