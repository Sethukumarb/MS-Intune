===============================================================================
 Autopilot Hardware Hash Collection & Import  |  README
 Author: Sethu Kumar B
===============================================================================

FILES IN THIS PACKAGE
---------------------
1. Get-AutopilotHardwareHash.ps1             Collect hash - NO Group Tag
2. Get-AutopilotHardwareHash-WithGroupTag.ps1  Collect hash - WITH Group Tag
3. Get-HardwareHash-NoGroupTag.bat           Same as #1 but BAT launcher
4. Get-HardwareHash-WithGroupTag.bat         Same as #2 but BAT launcher


===============================================================================
 *** GROUP TAG - WHERE TO SET IT ***
===============================================================================

  If you need a Group Tag, edit ONE of these before running:

  IN PowerShell file (#2):
  -------------------------
  Open: Get-AutopilotHardwareHash-WithGroupTag.ps1
  Find line 47:
      $GroupTag = "ENTER-GROUP-TAG-HERE"
  Replace ENTER-GROUP-TAG-HERE with your tag. Example:
      $GroupTag = "Corporate-Laptops"

  IN BAT file (#4):
  -----------------
  Open: Get-HardwareHash-WithGroupTag.bat
  Find line 14:
      set GROUP_TAG=ENTER-GROUP-TAG-HERE
  Replace ENTER-GROUP-TAG-HERE with your tag. Example:
      set GROUP_TAG=Corporate-Laptops

  NOTE: No quotes needed in the BAT file. Quotes required in the PS1 file.

  If you do NOT need a Group Tag, use files #1 or #3 instead. No edits needed.

===============================================================================


REQUIREMENTS
------------
- Run as Administrator (all scripts)
- PowerShell 5.1 or later
- Internet access to PSGallery (for hash collection scripts)


WORKFLOW
--------
STEP 1 - Collect hardware hash on each device
  Run either:
    Get-AutopilotHardwareHash.ps1               (no Group Tag)
    Get-AutopilotHardwareHash-WithGroupTag.ps1  (with Group Tag)
  -- or the BAT equivalents --
    Get-HardwareHash-NoGroupTag.bat
    Get-HardwareHash-WithGroupTag.bat

  Output: C:\HWID\<SerialNumber>.csv per device




NOTES
-----
- BAT files write a temp .ps1 to %TEMP%, run it, then delete it

===============================================================================