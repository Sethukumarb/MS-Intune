Set-AutopilotGroupTag.ps1 — How to Use
What this script does
It reads a list of device serial numbers from a text file, looks up each device in Autopilot, and updates the Group Tag. If a device has no tag it adds one. If it already has a tag it updates it. Nothing else is touched.

Step 1 — Fill in your credentials
Open the script in Notepad or VS Code and find this section near the top:
powershell

$TenantID     = ""
$ClientID     = ""
$ClientSecret = ""

Paste your App Registration values between the quotes. Save the file.

Step 2 — Create the input file
In the same folder as the script, create a file named exactly:
AutopilotGroupTag.txt

Open it and add one device per line in this format:

SerialNumber,GroupTag

Example:
5CG1vkajdhvfTDQ,Engineering
5CGjvbhhljsdvfjlasZA,Manufacturing
5CG38t283PQ,AI

Rules:

Serial number first, then a comma, then the group tag
One device per line
Lines starting with # are treated as comments and ignored
Blank lines are ignored


Step 3 — Run in Dry Run first

At the top of the script find this line:
powershell$DryRun = $true

Leave it as $true. This is the safe preview mode — it will show you exactly what would change but will not update anything.
Run the script. Check the console output and the CSV file it creates. You will see:

Each serial number found or not found
The current group tag on the device
What the new group tag would be


Step 4 — Check the results
For each device the script will tell you one of these:
What you seeWhat it meansTAG ADDEDDevice had no group tag — will add the new oneTAG UPDATEDDevice already has a tag — will change it to the new oneNO CHANGEDevice already has the same tag — nothing to doNOT FOUNDSerial number not found in Autopilot — check the serial
Review each line carefully. If something looks wrong fix the input file and run dry run again.

Step 5 — Apply the changes
Once you are happy with the dry run output, open the script and change:
powershell$DryRun = $true
to:
powershell$DryRun = $false
Run the script again. The group tags will be updated.

Step 6 — Check the output files
Two files are saved in the same folder as the script after every run:
FileWhat it containsAutopilotGroupTag_[timestamp].csvFull before and after record for every deviceAutopilotGroupTag_[timestamp].logDetailed log of everything the script did
The CSV shows the old group tag and new group tag side by side for every device — keep this as your change record.

Important notes

Always run Dry Run first — get into the habit even for small changes
The script only changes the Group Tag field — nothing else on the device is touched
Devices already enrolled and running are not affected — the tag change only matters at the next Autopilot provisioning
If a serial is not found double check it in the Intune portal under Devices → Windows → Windows Enrollment → Devices