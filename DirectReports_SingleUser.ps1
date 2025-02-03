#	Author: B Sethu Kumar
#	Date: 2024-Apr-20
#  	Version: 1.0

# Generate the direct reports (Single User)
# Microsoft-Intune

# Install required modules
Install-Module -Name AzureAD -Force -Confirm:$false
Install-Module -Name ImportExcel -Force -Confirm:$false

# Connect to Azure AD
Connect-AzureAD

# Specify the user's UPN (email address)
$userUPN = "Sethu.kumar@example.com"  # Replace with the target user's UPN

# Retrieve the direct reports
$directReports = Get-AzureADUserDirectReport -ObjectId (Get-AzureADUser -ObjectId $userUPN).ObjectId

# Prepare the data for Excel
$reportData = $directReports | Select-Object DisplayName, UserPrincipalName, JobTitle, Department

# Define the path for the Excel file (in the Downloads folder)
$downloadFolder = "C:\Groups"
$excelFilePath = Join-Path -Path $downloadFolder -ChildPath "DirectReports_$($userUPN.Replace('@', '_')).xlsx"

# Export the data to Excel
$reportData | Export-Excel -Path $excelFilePath -AutoSize -Title "Direct Reports for $userUPN"

# Notify the user
Write-Host "Direct reports for $userUPN have been exported to $excelFilePath"
