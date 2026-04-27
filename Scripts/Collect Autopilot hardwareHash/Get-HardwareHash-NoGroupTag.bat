@echo off
:: ==============================================================================
:: Script Name  : Get-HardwareHash-NoGroupTag.bat
:: Description  : Collects Autopilot hardware hash. No Group Tag.
:: Author       : Sethu Kumar B
:: Version      : 1.2
:: Created Date : 2026-04-27
:: ==============================================================================

echo.
echo ================================================================
echo   Autopilot Hardware Hash Collector  ^|  Sethu Kumar B
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
echo ^& 'C:\Program Files\WindowsPowerShell\Scripts\Get-WindowsAutoPilotInfo.ps1' -OutputFile $out
echo Write-Host "[OK] Saved: $out" -ForegroundColor Green
) > "%TMPPS%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%"
del "%TMPPS%" >nul 2>&1

echo.
echo ================================================================
echo   Done. File saved to C:\HWID\
echo ================================================================
echo.
pause