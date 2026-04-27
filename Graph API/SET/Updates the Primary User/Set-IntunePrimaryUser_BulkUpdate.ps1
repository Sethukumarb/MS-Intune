#Requires -Version 5.1
# ==============================================================================
# Script Name  : Set-IntunePrimaryUser_BulkUpdate.ps1
# Description  : Reads a CSV file containing Hostname and PrimaryUserEmail,
#                then automatically updates the Primary User on each Intune
#                managed device — no per-device confirmation required.
#
#                Input CSV format (two columns, header row required):
#                  Hostname,PrimaryUserEmail
#                  WDhgAP-3bll,sethu@abc.com
#                  WDgdfgfdAP-VEEM,john.doe@abc.com
#
#                Processing logic per row:
#                  Step 1 — Validate row (both fields present)
#                  Step 2 — Search Intune by Hostname
#                           Skip + ERROR if not found
#                           Warn if duplicate records exist (processes all)
#                  Step 3 — Validate PrimaryUserEmail exists in Azure AD
#                           Skip + ERROR if user not found
#                  Step 4 — Update Primary User on the device
#                           DELETE existing user $ref
#                           POST   new user $ref
#                  Step 5 — Log result to audit CSV
#
#                Dry-Run mode ($DryRun = $true):
#                  All steps run EXCEPT the actual DELETE/POST API calls.
#                  Validates every hostname and email, shows what WOULD change,
#                  exports a preview audit CSV. No changes made in Intune.
#                  Set $DryRun = $false to apply changes for real.
#
#                Skip conditions (logged as ERROR, device not touched):
#                  - Hostname or PrimaryUserEmail missing in CSV row
#                  - Hostname not found in Intune
#                  - PrimaryUserEmail does not exist in Azure AD
#                  - Intune Device ID cannot be resolved
#
#                Audit CSV columns:
#                  Hostname, IntuneDeviceId, SerialNumber
#                  OldPrimaryUser, NewPrimaryUser
#                  Action, Result, Note, Timestamp
#
#                Output files:
#                  SetPrimaryUser_Audit_<timestamp>.csv
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-03-25
# Last Modified: 2026-03-25
#
# Change Log   :
#   v1.0 - 2026-03-25 - Initial release.
#
# Requirements :
#   App Registration permissions (admin consent granted):
#     DeviceManagementManagedDevices.ReadWrite.All
#     User.Read.All
# ==============================================================================


#region --- CONFIGURATION --- Edit before running ---

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

# ------------------------------------------------------------------
# INPUT CSV
# Full path to CSV file with columns: Hostname, PrimaryUserEmail
# Header row is required.
# ------------------------------------------------------------------
$InputCSV = "C:\Users\Set Primary User\InputDevices_BulkUpdate.csv"

# ------------------------------------------------------------------
# OUTPUT FOLDER
# Audit CSV saved here. Created automatically if missing.
# ------------------------------------------------------------------
$OutputFolder = "C:\Users\Set Primary User\Output"

# ------------------------------------------------------------------
# DRY RUN
# $true  — Validates everything, shows what WOULD change, no updates
#           applied. Exports a preview audit CSV.
# $false — Live run. Actually updates Primary User in Intune.
# ------------------------------------------------------------------
$DryRun = $false

#endregion


#region --- FUNCTIONS ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","HEADER","ACTION","DRYRUN")]
        [string]$Level = "INFO"
    )
    $t = Get-Date -Format "HH:mm:ss"
    switch ($Level) {
        "HEADER"  { Write-Host "`n$Message" -ForegroundColor Cyan }
        "INFO"    { Write-Host "[$t] [INFO]    $Message" -ForegroundColor Gray }
        "WARN"    { Write-Host "[$t] [WARN]    $Message" -ForegroundColor Yellow }
        "ERROR"   { Write-Host "[$t] [ERROR]   $Message" -ForegroundColor Red }
        "SUCCESS" { Write-Host "[$t] [OK]      $Message" -ForegroundColor Green }
        "ACTION"  { Write-Host "[$t] [ACTION]  $Message" -ForegroundColor Magenta }
        "DRYRUN"  { Write-Host "[$t] [DRY-RUN] $Message" -ForegroundColor DarkYellow }
    }
}


function Get-GraphAccessToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $uri  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    try {
        Write-Log "Requesting access token from Microsoft Identity Platform..." -Level INFO
        $r = Invoke-RestMethod -Method POST -Uri $uri -Body $body `
             -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Write-Log "Access token acquired successfully." -Level SUCCESS
        return $r.access_token
    }
    catch {
        Write-Log "Failed to acquire access token: $_" -Level ERROR
        exit 1
    }
}


# ------------------------------------------------------------------------------
# Search Intune for managed devices matching a hostname.
# Returns array of stub device objects (may be >1 if duplicates exist).
# Returns empty array if not found. Never throws.
# ------------------------------------------------------------------------------
function Find-IntuneDeviceByHostname {
    param([string]$Hostname, [string]$AccessToken)

    $encoded = [Uri]::EscapeDataString($Hostname)
    $uri     = "https://graph.microsoft.com/beta/deviceManagement/managedDevices" +
               "?`$filter=deviceName eq '$encoded'"
    $headers = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }

    try {
        $r = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
        if ($r.value) { return $r.value }
        else          { return @() }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Log "  Intune search failed for '$Hostname' — HTTP $code : $_" -Level ERROR
        return @()
    }
}


# ------------------------------------------------------------------------------
# Validate a user UPN exists in Azure AD and return their Object ID.
# Returns empty string if not found or on any error. Never throws.
# ------------------------------------------------------------------------------
function Get-UserObjectId {
    param([string]$UserUPN, [string]$AccessToken)

    if ([string]::IsNullOrWhiteSpace($UserUPN)) { return "" }

    $uri = "https://graph.microsoft.com/beta/users/" +
           [Uri]::EscapeDataString($UserUPN) + "?`$select=id,userPrincipalName"
    try {
        $r = Invoke-RestMethod -Uri $uri `
             -Headers @{ Authorization = "Bearer $AccessToken" } `
             -Method GET -ErrorAction Stop
        return $r.id
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) {
            Write-Log "  User '$UserUPN' not found in Azure AD (404)." -Level ERROR
        }
        else {
            Write-Log "  User lookup failed for '$UserUPN' — HTTP $code : $_" -Level ERROR
        }
        return ""
    }
}


# ------------------------------------------------------------------------------
# Update the Primary User on an Intune managed device.
#
# Steps:
#   A — Resolve new user UPN → Azure AD Object ID
#   B — DELETE existing primary user $ref
#   C — POST new primary user $ref
#
# Returns [PSCustomObject] { Success, Message }
# ------------------------------------------------------------------------------
function Set-DevicePrimaryUser {
    param(
        [string]$DeviceId,
        [string]$NewUserUPN,
        [string]$NewUserId,
        [string]$OldUserUPN,
        [string]$AccessToken
    )

    $headers     = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $graphBase   = "https://graph.microsoft.com/beta"
    $usersRefUri = "$graphBase/deviceManagement/managedDevices/$DeviceId/users/`$ref"

    # STEP B — Remove existing primary user
    if (-not [string]::IsNullOrWhiteSpace($OldUserUPN)) {
        Write-Log "  [B] Removing existing primary user: $OldUserUPN" -Level INFO

        $oldUserId = Get-UserObjectId -UserUPN $OldUserUPN -AccessToken $AccessToken

        if (-not [string]::IsNullOrWhiteSpace($oldUserId)) {
            $deleteBody = @{ "@odata.id" = "$graphBase/users/$oldUserId" } | ConvertTo-Json
            try {
                Invoke-RestMethod -Method DELETE -Uri $usersRefUri `
                    -Headers $headers -Body $deleteBody -ErrorAction Stop | Out-Null
                Write-Log "  [B] Existing primary user removed." -Level SUCCESS
            }
            catch {
                $code = $_.Exception.Response.StatusCode.value__
                if ($code -eq 404) {
                    Write-Log "  [B] No existing user ref found (404) — continuing." -Level INFO
                }
                else {
                    return [PSCustomObject]@{
                        Success = $false
                        Message = "DELETE existing user failed (HTTP $code): $_"
                    }
                }
            }
        }
        else {
            Write-Log "  [B] Could not resolve old user ID — skipping DELETE." -Level WARN
        }
    }
    else {
        Write-Log "  [B] No existing primary user — skipping DELETE." -Level INFO
    }

    # Buffer between DELETE and POST
    Start-Sleep -Milliseconds 500

    # STEP C — Assign new primary user
    Write-Log "  [C] Assigning new primary user: $NewUserUPN" -Level INFO
    $postBody = @{ "@odata.id" = "$graphBase/users/$NewUserId" } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method POST -Uri $usersRefUri `
            -Headers $headers -Body $postBody -ErrorAction Stop | Out-Null
        Write-Log "  [C] Primary user assigned successfully." -Level SUCCESS
        return [PSCustomObject]@{ Success = $true; Message = "Updated successfully" }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        return [PSCustomObject]@{
            Success = $false
            Message = "POST new user failed (HTTP $code): $_"
        }
    }
}


# ------------------------------------------------------------------------------
# Build a standard audit log row
# ------------------------------------------------------------------------------
function New-AuditRow {
    param(
        [string]$Hostname,
        [string]$IntuneDeviceId,
        [string]$SerialNumber,
        [string]$OldPrimaryUser,
        [string]$NewPrimaryUser,
        [string]$Action,
        [string]$Result,
        [string]$Note
    )
    [PSCustomObject]@{
        Hostname        = $Hostname
        IntuneDeviceId  = $IntuneDeviceId
        SerialNumber    = $SerialNumber
        OldPrimaryUser  = $OldPrimaryUser
        NewPrimaryUser  = $NewPrimaryUser
        Action          = $Action
        Result          = $Result
        Note            = $Note
        Timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

#endregion


#region --- MAIN ---

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Set-IntunePrimaryUser  |  Endpoint Engineering        " -ForegroundColor Cyan
Write-Host "   Graph API: BETA  |  Bulk Automatic Primary User Set   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host ""
    Write-Host "  !! DRY-RUN MODE — No changes will be made in Intune !!" -ForegroundColor DarkYellow
    Write-Host "  !! Set DryRun = false in config to apply changes      !!" -ForegroundColor DarkYellow
    Write-Host ""
}

# Validate input CSV exists
if (-not (Test-Path $InputCSV -PathType Leaf)) {
    Write-Log "Input CSV not found: $InputCSV" -Level ERROR
    exit 1
}

# Ensure output folder exists
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    Write-Log "Output folder created: $OutputFolder" -Level INFO
}

# Read and validate CSV
Write-Log "Reading input CSV: $InputCSV" -Level INFO
try {
    $inputRows = Import-Csv -Path $InputCSV -ErrorAction Stop
}
catch {
    Write-Log "Failed to read input CSV: $_" -Level ERROR
    exit 1
}

# Validate required columns exist
if (-not ($inputRows[0].PSObject.Properties.Name -contains "Hostname") -or
    -not ($inputRows[0].PSObject.Properties.Name -contains "PrimaryUserEmail")) {
    Write-Log "CSV must contain columns: Hostname, PrimaryUserEmail" -Level ERROR
    Write-Log "Found columns: $($inputRows[0].PSObject.Properties.Name -join ', ')" -Level ERROR
    exit 1
}

$totalRows = $inputRows.Count
Write-Log "Rows loaded: $totalRows" -Level INFO

# Authenticate
$token = Get-GraphAccessToken -TenantId $TenantID -ClientId $ClientID -ClientSecret $ClientSecret

# Counters
$successCount  = 0
$errorCount    = 0
$skippedCount  = 0
$dryRunCount   = 0
$auditLog      = [System.Collections.Generic.List[PSObject]]::new()
$counter       = 0

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   Processing $totalRows row(s)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

foreach ($row in $inputRows) {
    $counter++
    $hostname  = $row.Hostname.Trim().ToUpper()
    $newUserUPN = $row.PrimaryUserEmail.Trim().ToLower()

    Write-Host ""
    Write-Log "[$counter/$totalRows] ----------------------------------------" -Level INFO
    Write-Log "[$counter/$totalRows] Hostname : $hostname" -Level INFO
    Write-Log "[$counter/$totalRows] New User : $newUserUPN" -Level INFO

    # ------------------------------------------------------------------
    # STEP 1 — Validate row has both fields
    # ------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($hostname) -or [string]::IsNullOrWhiteSpace($newUserUPN)) {
        Write-Log "  Row $counter is missing Hostname or PrimaryUserEmail — skipping." -Level ERROR
        $errorCount++
        $auditLog.Add((New-AuditRow `
            -Hostname       $hostname `
            -IntuneDeviceId "" `
            -SerialNumber   "" `
            -OldPrimaryUser "" `
            -NewPrimaryUser $newUserUPN `
            -Action         "SKIPPED" `
            -Result         "ERROR" `
            -Note           "Missing Hostname or PrimaryUserEmail in CSV row"))
        continue
    }

    # ------------------------------------------------------------------
    # STEP 2 — Find device in Intune by hostname
    # ------------------------------------------------------------------
    Write-Log "  Searching Intune for: $hostname" -Level INFO
    $devices = Find-IntuneDeviceByHostname -Hostname $hostname -AccessToken $token

    if ($devices.Count -eq 0) {
        Write-Log "  NOT FOUND in Intune: $hostname — skipping." -Level ERROR
        $errorCount++
        $auditLog.Add((New-AuditRow `
            -Hostname       $hostname `
            -IntuneDeviceId "" `
            -SerialNumber   "" `
            -OldPrimaryUser "" `
            -NewPrimaryUser $newUserUPN `
            -Action         "SKIPPED" `
            -Result         "ERROR" `
            -Note           "Hostname not found in Intune"))
        continue
    }

    if ($devices.Count -gt 1) {
        Write-Log "  DUPLICATE — $($devices.Count) Intune records found for '$hostname'. Processing all." -Level WARN
    }
    else {
        Write-Log "  Found in Intune — Device ID: $($devices[0].id)" -Level SUCCESS
    }

    # ------------------------------------------------------------------
    # STEP 3 — Validate new user exists in Azure AD
    # ------------------------------------------------------------------
    Write-Log "  Validating user in Azure AD: $newUserUPN" -Level INFO
    $newUserId = Get-UserObjectId -UserUPN $newUserUPN -AccessToken $token

    if ([string]::IsNullOrWhiteSpace($newUserId)) {
        Write-Log "  User '$newUserUPN' not found in Azure AD — skipping all devices for this row." -Level ERROR
        $errorCount++
        foreach ($d in $devices) {
            $auditLog.Add((New-AuditRow `
                -Hostname       $hostname `
                -IntuneDeviceId $d.id `
                -SerialNumber   $d.serialNumber `
                -OldPrimaryUser $d.userPrincipalName `
                -NewPrimaryUser $newUserUPN `
                -Action         "SKIPPED" `
                -Result         "ERROR" `
                -Note           "New user '$newUserUPN' not found in Azure AD"))
        }
        continue
    }

    Write-Log "  User validated — Object ID: $newUserId" -Level SUCCESS

    # ------------------------------------------------------------------
    # STEP 4 — Update Primary User (or dry-run preview)
    # ------------------------------------------------------------------
    foreach ($device in $devices) {
        $deviceId      = $device.id
        $serialNumber  = $device.serialNumber
        $currentUser   = $device.userPrincipalName

        Write-Log "  Device  : $($device.deviceName)  [$deviceId]" -Level INFO
        Write-Log "  Current : $currentUser" -Level INFO
        Write-Log "  New     : $newUserUPN" -Level INFO

        # Check if already correct — no update needed
        if (-not [string]::IsNullOrWhiteSpace($currentUser) -and
            $currentUser.ToLower() -eq $newUserUPN.ToLower()) {
            Write-Log "  Primary User already matches '$newUserUPN' — no update needed." -Level SUCCESS
            $skippedCount++
            $auditLog.Add((New-AuditRow `
                -Hostname       $hostname `
                -IntuneDeviceId $deviceId `
                -SerialNumber   $serialNumber `
                -OldPrimaryUser $currentUser `
                -NewPrimaryUser $newUserUPN `
                -Action         "SKIPPED" `
                -Result         "NO CHANGE NEEDED" `
                -Note           "Primary User already matches target"))
            continue
        }

        # DRY RUN — log what would happen, make no changes
        if ($DryRun) {
            Write-Log "  [DRY-RUN] Would update Primary User:" -Level DRYRUN
            Write-Log "  [DRY-RUN]   From : $currentUser" -Level DRYRUN
            Write-Log "  [DRY-RUN]   To   : $newUserUPN" -Level DRYRUN
            $dryRunCount++
            $auditLog.Add((New-AuditRow `
                -Hostname       $hostname `
                -IntuneDeviceId $deviceId `
                -SerialNumber   $serialNumber `
                -OldPrimaryUser $currentUser `
                -NewPrimaryUser $newUserUPN `
                -Action         "DRY-RUN" `
                -Result         "WOULD UPDATE" `
                -Note           "DryRun=true. Set DryRun=false to apply."))
            continue
        }

        # LIVE RUN — apply the update
        Write-Log "  Updating Primary User..." -Level ACTION
        $result = Set-DevicePrimaryUser `
            -DeviceId    $deviceId `
            -NewUserUPN  $newUserUPN `
            -NewUserId   $newUserId `
            -OldUserUPN  $currentUser `
            -AccessToken $token

        if ($result.Success) {
            Write-Log "  SUCCESS: Primary User updated to '$newUserUPN'" -Level SUCCESS
            $successCount++
            $auditLog.Add((New-AuditRow `
                -Hostname       $hostname `
                -IntuneDeviceId $deviceId `
                -SerialNumber   $serialNumber `
                -OldPrimaryUser $currentUser `
                -NewPrimaryUser $newUserUPN `
                -Action         "UPDATED" `
                -Result         "SUCCESS" `
                -Note           $result.Message))
        }
        else {
            Write-Log "  FAILED: $($result.Message)" -Level ERROR
            $errorCount++
            $auditLog.Add((New-AuditRow `
                -Hostname       $hostname `
                -IntuneDeviceId $deviceId `
                -SerialNumber   $serialNumber `
                -OldPrimaryUser $currentUser `
                -NewPrimaryUser $newUserUPN `
                -Action         "UPDATED" `
                -Result         "ERROR" `
                -Note           $result.Message))
        }
    }

    Start-Sleep -Milliseconds 200
}

# =======================================================
# Export Audit CSV
# =======================================================
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$modeLabel  = if ($DryRun) { "DryRun" } else { "Live" }
$auditFile  = Join-Path $OutputFolder "SetPrimaryUser_Audit_${modeLabel}_${timestamp}.csv"

try {
    $auditLog | Export-Csv -Path $auditFile -NoTypeInformation -Encoding UTF8
    Write-Log "Audit CSV exported: $auditFile" -Level SUCCESS
}
catch {
    Write-Log "Failed to export audit CSV: $_" -Level ERROR
}

# =======================================================
# Final Summary
# =======================================================
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   COMPLETE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Mode              : $(if ($DryRun) {'DRY-RUN (no changes made)'} else {'LIVE'})" `
           -ForegroundColor $(if ($DryRun) {"DarkYellow"} else {"White"})
Write-Host "  Input CSV         : $InputCSV"          -ForegroundColor White
Write-Host "  Total rows        : $totalRows"          -ForegroundColor White
if ($DryRun) {
Write-Host "  Would update      : $dryRunCount"        -ForegroundColor DarkYellow
} else {
Write-Host "  Updated OK        : $successCount"       -ForegroundColor Green
}
Write-Host "  Already correct   : $skippedCount"       -ForegroundColor Gray
Write-Host "  Errors / Skipped  : $errorCount"         -ForegroundColor $(if ($errorCount -gt 0) {"Red"} else {"White"})
Write-Host "  Audit CSV         :"                     -ForegroundColor White
Write-Host "    $auditFile"                            -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

#endregion