<#
.SYNOPSIS
    Sets a custom desktop wallpaper and removes any previously deployed wallpaper files.

.DESCRIPTION
    This script performs the following tasks:
      1. Deletes any old wallpaper files (both .jpg and .png variants) from the Windows
         wallpaper directory, if they exist.
      2. Copies the new wallpaper image from the script's source directory to the
         Windows wallpaper directory.
      3. Applies the new wallpaper as the current desktop background using the
         Windows User32 SystemParametersInfo API.

.PARAMETER Image
    Full path to the wallpaper image that will be applied as the desktop background.
    Defaults to "C:\Windows\web\wallpaper\Windows\New_Wallpaper.jpg".

.AUTHOR
    Sethu Kumar B

.VERSION
    1.3 - Removed team name, generalized image names, added detailed descriptions
#>

param (
    [string]$Image = "C:\Windows\web\wallpaper\Windows\New_Wallpaper.jpg"
)

# --- Remove old wallpaper files (.jpg and .png variants) ---
$oldWallpapers = @(
    "C:\Windows\web\wallpaper\Windows\Old_Wallpaper.jpg",
    "C:\Windows\web\wallpaper\Windows\Old_Wallpaper.png"
)

foreach ($file in $oldWallpapers) {
    if (Test-Path -Path $file) {
        Remove-Item -Path $file -Force
        Write-Output "Deleted: $(Split-Path $file -Leaf)"
    }
}

# --- Copy new wallpaper image to the Windows wallpaper directory ---
Copy-Item "$PSScriptRoot\New_Wallpaper.jpg" "C:\Windows\web\wallpaper\Windows" -Force
Write-Output "Copied: New_Wallpaper.jpg to wallpaper directory."

<#
.FUNCTION Set-WallPaper

.DESCRIPTION
    Applies the specified image file as the Windows desktop wallpaper by invoking
    the SystemParametersInfo function from the Windows User32 API.
    Uses the SPI_SETDESKWALLPAPER action (0x0014) with SPIF_UPDATEINIFILE (0x01)
    and SPIF_SENDCHANGE (0x02) flags to ensure the change is saved and broadcast
    to all running applications immediately.

    To avoid duplicate type definition errors on repeated script runs, the function
    checks whether the 'Params' type has already been loaded into the session before
    calling Add-Type.

.PARAMETER Image
    Full file path to the image (.jpg or .png) to be set as the desktop wallpaper.

.EXAMPLE
    Set-WallPaper -Image "C:\Windows\web\wallpaper\Windows\New_Wallpaper.jpg"
#>
Function Set-WallPaper {
    param (
        [string]$Image
    )

    if (-not ([System.Management.Automation.PSTypeName]'Params').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Params {
    [DllImport("User32.dll", CharSet=CharSet.Unicode)]
    public static extern int SystemParametersInfo(Int32 uAction, Int32 uParam, String lpvParam, Int32 fuWinIni);
}
"@
    }

    $SPI_SETDESKWALLPAPER = 0x0014
    $fWinIni = 0x01 -bor 0x02

    [Params]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $Image, $fWinIni) | Out-Null
    Write-Output "Wallpaper applied: $Image"
}

# --- Apply the new wallpaper ---
Set-WallPaper -Image $Image