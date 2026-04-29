#Requires -Version 5.1
# ===============================================================================
#  Script      :  Remove-IntuneManagedDeviceByDevicesIDs.ps1
#  Description :  Bulk-delete Intune Managed Device records via Microsoft
#                 Graph API using a Managed Device ID input list.
#                 Supports Dry Run mode and batch size enforcement.
#  Author      :  Sethu Kumar B
#  Version     :  3.0
#  Last Updated:  2025-04-28
#  Permissions :  DeviceManagementManagedDevices.ReadWrite.All (App Registration)
# ===============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ===============================================================================
#  CONFIGURATION  —  Fill in before running
# ===============================================================================

$TenantID = ""
$ClientID = ""
$ClientSecret = ""

$InputFile     = "$PSScriptRoot\DeviceIDs.txt"
$LogFile       = "$PSScriptRoot\Logs\Remove-IntuneManagedDevice_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# DRY RUN : $true  = simulate only, no deletions
#           $false = live run, deletions are permanent
$DryRun        = $true

# BATCH CAP : Abort if input exceeds this count.
# Change to any number you need (e.g. 50, 500, 5000)
$MaxBatchSize  = 1
# ===============================================================================


# ───────────────────────────────────────────────────────────────────────────────
#  LOGGING
# ───────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string] $Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","SECTION")]
        [string] $Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $padded    = $Level.PadRight(7)
    $entry     = "[$timestamp]  $padded  $Message"

    $colour = switch ($Level) {
        "SUCCESS" { "Green"   }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        "SECTION" { "Cyan"    }
        default   { "White"   }
    }

    Write-Host $entry -ForegroundColor $colour
    Add-Content -Path $LogFile -Value $entry
}

function Write-Section {
    param([string]$Title)
    $line = "─" * 79
    Write-Log $line        "SECTION"
    Write-Log "  $Title"   "SECTION"
    Write-Log $line        "SECTION"
}


# ───────────────────────────────────────────────────────────────────────────────
#  GRAPH API — TOKEN
# ───────────────────────────────────────────────────────────────────────────────
function Get-GraphToken {
    $body = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    try {
        $response = Invoke-RestMethod `
            -Method      POST `
            -Uri         "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body        $body `
            -ContentType "application/x-www-form-urlencoded"
        return $response.access_token
    }
    catch {
        Write-Log "Token acquisition failed. Verify TenantId, ClientId, and ClientSecret." "ERROR"
        Write-Log "Detail : $_" "ERROR"
        exit 1
    }
}


# ───────────────────────────────────────────────────────────────────────────────
#  INITIALISE — LOG FOLDER
# ───────────────────────────────────────────────────────────────────────────────
$logFolder = Split-Path $LogFile
if (-not (Test-Path $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
}


# ───────────────────────────────────────────────────────────────────────────────
#  STARTUP BANNER
# ───────────────────────────────────────────────────────────────────────────────
Write-Section "Remove-IntuneManagedDevice  |  v3.0  |  Sethu Kumar B"
Write-Log "Start Time   : $(Get-Date -Format 'dddd, dd MMMM yyyy  HH:mm:ss')" "INFO"
Write-Log "Input File   : $InputFile"                                          "INFO"
Write-Log "Log File     : $LogFile"                                            "INFO"
Write-Log "Batch Cap    : $MaxBatchSize device(s) per run"                    "INFO"

if ($DryRun) {
    Write-Log "" "WARN"
    Write-Log "  ⚠  DRY RUN MODE ACTIVE — ZERO DELETIONS WILL OCCUR" "WARN"
    Write-Log "     Set `$DryRun = `$false to perform live deletions." "WARN"
    Write-Log "" "WARN"
}
else {
    Write-Log "" "WARN"
    Write-Log "  ⚠  LIVE MODE — DELETIONS ARE PERMANENT AND IRREVERSIBLE" "WARN"
    Write-Log "" "WARN"
}


# ───────────────────────────────────────────────────────────────────────────────
#  VALIDATE INPUT FILE
# ───────────────────────────────────────────────────────────────────────────────
Write-Section "Step 1 of 4 — Validating Input File"

if (-not (Test-Path $InputFile)) {
    Write-Log "Input file not found : $InputFile" "ERROR"
    exit 1
}

$DeviceIDs = @(Get-Content $InputFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })

if ($DeviceIDs.Count -eq 0) {
    Write-Log "Input file is empty. Nothing to process." "WARN"
    exit 0
}

Write-Log "Loaded $($DeviceIDs.Count) Device ID(s) from input file." "SUCCESS"


# ───────────────────────────────────────────────────────────────────────────────
#  BATCH SIZE GUARD
# ───────────────────────────────────────────────────────────────────────────────
Write-Section "Step 2 of 4 — Batch Size Enforcement"

if ($DeviceIDs.Count -gt $MaxBatchSize) {
    Write-Log "ABORTED — Input contains $($DeviceIDs.Count) device(s). Maximum allowed per run: $MaxBatchSize." "ERROR"
    Write-Log "Action  — Split the input file into smaller batches, or increase `$MaxBatchSize in the CONFIG block." "ERROR"
    exit 1
}

Write-Log "Batch size check passed : $($DeviceIDs.Count) / $MaxBatchSize device(s)." "SUCCESS"


# ───────────────────────────────────────────────────────────────────────────────
#  AUTHENTICATE
# ───────────────────────────────────────────────────────────────────────────────
Write-Section "Step 3 of 4 — Authenticating to Microsoft Graph"

Write-Log "Requesting access token from Azure AD..." "INFO"
$Token   = Get-GraphToken
$Headers = @{ Authorization = "Bearer $Token" }
Write-Log "Token acquired successfully." "SUCCESS"


# ───────────────────────────────────────────────────────────────────────────────
#  PROCESS DEVICES
# ───────────────────────────────────────────────────────────────────────────────
Write-Section "Step 4 of 4 — Processing Devices"

$Success  = 0
$NotFound = 0
$Failed   = 0
$Counter  = 0

foreach ($DeviceId in $DeviceIDs) {
    $Counter++
    $Uri     = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$DeviceId"
    $Prefix  = "[$Counter/$($DeviceIDs.Count)]"

    try {
        $device     = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
        $DeviceName = $device.deviceName
        $OS         = $device.operatingSystem
        $UPN        = $device.userPrincipalName

        if ($DryRun) {
            Write-Log "$Prefix  DRY RUN | WOULD DELETE  |  $DeviceName  |  $OS  |  $UPN  |  ID: $DeviceId" "WARN"
            $Success++
        }
        else {
            Invoke-RestMethod -Method DELETE -Uri $Uri -Headers $Headers -ErrorAction Stop
            Write-Log "$Prefix  DELETED              |  $DeviceName  |  $OS  |  $UPN  |  ID: $DeviceId" "SUCCESS"
            $Success++
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Log "$Prefix  NOT FOUND            |  ID: $DeviceId" "WARN"
            $NotFound++
        }
        else {
            Write-Log "$Prefix  FAILED               |  ID: $DeviceId  |  HTTP $statusCode  |  $_" "ERROR"
            $Failed++
        }
    }
}


# ───────────────────────────────────────────────────────────────────────────────
#  SUMMARY
# ───────────────────────────────────────────────────────────────────────────────
Write-Section "Execution Summary"

$modeLabel = if ($DryRun) { "DRY RUN (simulated)" } else { "LIVE (permanent)" }

Write-Log "Mode              : $modeLabel"                                      "INFO"
Write-Log "Total Input       : $($DeviceIDs.Count) device(s)"                  "INFO"

if ($DryRun) {
    Write-Log "Would Delete      : $Success device(s)"                         "WARN"
}
else {
    Write-Log "Deleted           : $Success device(s)"                         "SUCCESS"
}

Write-Log "Not Found         : $NotFound device(s)"                            "WARN"
Write-Log "Failed            : $Failed device(s)"                              $(if ($Failed -gt 0) { "ERROR" } else { "INFO" })
Write-Log "End Time          : $(Get-Date -Format 'dddd, dd MMMM yyyy  HH:mm:ss')" "INFO"
Write-Log "Log Saved To      : $LogFile"                                        "INFO"

if ($DryRun) {
    Write-Log "" "WARN"
    Write-Log "  →  Review the log above, then set `$DryRun = `$false to execute live." "WARN"
    Write-Log "" "WARN"
}

Write-Section "Script Complete"


# ───────────────────────────────────────────────────────────────────────────────
#  SECURITY CLEANUP
# ───────────────────────────────────────────────────────────────────────────────
$ClientSecret = ""
$Token        = ""