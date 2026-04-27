@echo off
:: ==============================================================================
:: Script Name  : Get-HardwareHash-WithGroupTag.bat
:: Description  : Collects Autopilot hardware hash with Group Tag.
::                Set GROUP_TAG below before running.
:: Author       : Sethu Kumar B
:: Version      : 1.2
:: Created Date : 2026-04-27
:: ==============================================================================

:: -------------------------------------------------------
:: SET YOUR GROUP TAG HERE
set GROUP_TAG=ENTER-GROUP-TAG-HERE
:: -------------------------------------------------------

echo.
echo ================================================================
echo   Autopilot Hardware Hash Collector  ^|  Sethu Kumar B
echo   Group Tag: %GROUP_TAG%
echo ================================================================
echo.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Run this script as Administrator.
    pause
    exit /b 1
)

set TMPPS=%TEMP%\hwid_collect.ps1

(
echo Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force ^| Out-Null
echo Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
echo Install-Script -Name Get-WindowsAutoPilotInfo -Force
echo $serial = ^(Get-CimInstance Win32_BIOS^).SerialNumber.Trim^(^) -replace '[\\/:*?"<>^|]','_'
echo New-Item -Path 'C:\HWID' -ItemType Directory -Force ^| Out-Null
echo $out = "C:\HWID\$serial.csv"
echo ^& 'C:\Program Files\WindowsPowerShell\Scripts\Get-WindowsAutoPilotInfo.ps1' -OutputFile $out -GroupTag '%GROUP_TAG%'
echo Write-Host "[OK] Saved: $out" -ForegroundColor Green
echo Write-Host "[OK] Group Tag: %GROUP_TAG%" -ForegroundColor Green
) > "%TMPPS%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%"
del "%TMPPS%" >nul 2>&1

echo.
echo ================================================================
echo   Done. File saved to C:\HWID\
echo ================================================================
echo.
pause