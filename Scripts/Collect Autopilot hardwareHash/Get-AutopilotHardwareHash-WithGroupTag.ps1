#Requires -Version 5.1
# ==============================================================================
# Script Name  : Get-AutopilotHardwareHash-WithGroupTag.ps1
# Description  : Collects the Windows Autopilot hardware hash from the local
#                device and saves it as a CSV file ready for import.
#                Group Tag is configurable via the CONFIGURATION section.
#
#                HOW IT WORKS:
#                  1. Sets execution policy and installs NuGet + PSGallery
#                  2. Installs Get-WindowsAutoPilotInfo script from PSGallery
#                  3. Detects device serial number (sanitised for file naming)
#                  4. Collects hardware hash via Get-WindowsAutoPilotInfo
#                  5. Saves CSV to C:\HWID\<SerialNumber>.csv with Group Tag
#
#                OUTPUT CSV COLUMNS (standard Autopilot format):
#                  Device Serial Number, Windows Product ID, Hardware Hash,
#                  Group Tag
#
#                OUTPUT FILE:
#                  C:\HWID\<SerialNumber>.csv
#
#                NOTE:
#                  Set $GroupTag in the CONFIGURATION section before running.
#                  CSV is ready for direct use with Import-AutopilotDevices.ps1.
#
# Author       : Sethu Kumar B
# Version      : 1.0
# Created Date : 2026-04-27
# Last Modified: 2026-04-27
#
# Requirements :
#   - Must run as Administrator
#   - PowerShell 5.1 or later
#   - Internet access to reach PSGallery
#
# Change Log   :
#   v1.0 - 2026-04-27 - Sethu Kumar B - Initial release. Group Tag configurable.
# ==============================================================================


#region --- CONFIGURATION -------------------------------------------------------

# Set your Group Tag here before running.
# Examples: "Corporate-Laptops", "Engineering", "Kiosk-Devices"
$GroupTag     = "ENTER-GROUP-TAG-HERE"

$OutputFolder = "C:\HWID"

#endregion ----------------------------------------------------------------------


#region --- MAIN ----------------------------------------------------------------

# -- Step 1: Execution policy and package provider -----------------------------
Write-Host "[INFO] Setting execution policy..." -ForegroundColor Cyan
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

Write-Host "[INFO] Installing NuGet provider..." -ForegroundColor Cyan
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null

Write-Host "[INFO] Trusting PSGallery..." -ForegroundColor Cyan
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted


# -- Step 2: Install Get-WindowsAutoPilotInfo ----------------------------------
Write-Host "[INFO] Installing Get-WindowsAutoPilotInfo..." -ForegroundColor Cyan
Install-Script -Name Get-WindowsAutoPilotInfo -Force


# -- Step 3: Detect serial number ----------------------------------------------
$Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
$Serial = $Serial -replace '[\\/:*?"<>|]', '_'
Write-Host "[INFO] Serial number : $Serial"    -ForegroundColor Cyan
Write-Host "[INFO] Group Tag     : $GroupTag"  -ForegroundColor Cyan


# -- Step 4: Create output folder ----------------------------------------------
New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
$OutputFile = Join-Path $OutputFolder "$Serial.csv"


# -- Step 5: Collect hardware hash with Group Tag ------------------------------
Write-Host "[INFO] Collecting hardware hash..." -ForegroundColor Cyan

& "C:\Program Files\WindowsPowerShell\Scripts\Get-WindowsAutoPilotInfo.ps1" `
    -OutputFile $OutputFile `
    -GroupTag   $GroupTag

if (Test-Path $OutputFile) {
    Write-Host "[OK]  Hardware hash saved: $OutputFile" -ForegroundColor Green
    Write-Host "[OK]  Group Tag applied  : $GroupTag"   -ForegroundColor Green
} else {
    Write-Host "[ERROR] Output file not created. Check errors above." -ForegroundColor Red
    exit 1
}

#endregion ----------------------------------------------------------------------