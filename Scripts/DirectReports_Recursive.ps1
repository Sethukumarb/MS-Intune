#	Author: B Sethu Kumar
#	Date: 2024-Apr-20
#  	Version: 1.0

# Generate the direct reports (Recursive) Loop
# Install required modules
Install-Module -Name AzureAD -Force -Confirm:$false
Install-Module -Name ImportExcel -Force -Confirm:$false

# Connect to Azure AD
Connect-AzureAD

# Function to recursively get direct reports
function Get-DirectReportsRecursively {
    param (
        [string]$userObjectId
    )

    # Get direct reports for the given user
    $directReports = Get-AzureADUserDirectReport -ObjectId $userObjectId

    # Initialize an array to store the details
    $allReports = @()

    # Loop through each direct report
    foreach ($report in $directReports) {
        # Get detailed user information for each direct report
        $userDetails = Get-AzureADUser -ObjectId $report.ObjectId

        # Add the user details to the array
        $allReports += [PSCustomObject]@{
            Manager         = (Get-AzureADUser -ObjectId $userObjectId).DisplayName
            DisplayName     = $userDetails.DisplayName
            UserPrincipalName = $userDetails.UserPrincipalName
            JobTitle        = $userDetails.JobTitle
            Department      = $userDetails.Department
            Level           = "Direct Report"
        }

        # Get the direct reports for each direct report (under-reportees)
        $underReports = Get-DirectReportsRecursively -userObjectId $userDetails.ObjectId

        # Add under-reportees to the array
        if ($underReports) {
            $allReports += $underReports
        }
    }

    return $allReports
}

# Specify the target user's UPN (email address)
$userUPN = "Sethu.kumar@example.com"  # Replace with the target user's UPN

# Get the Object ID of the target user
$userObjectId = (Get-AzureADUser -ObjectId $userUPN).ObjectId

# Retrieve the direct reports and their under-reportees recursively
$allReports = Get-DirectReportsRecursively -userObjectId $userObjectId

# Prepare the data for Excel
$reportData = $allReports | Select-Object Manager, DisplayName, UserPrincipalName, JobTitle, Department, Level

# Define the path for the Excel file (in the Downloads folder)
$downloadFolder = "C:\Groups\DirectReport"
$excelFilePath = Join-Path -Path $downloadFolder -ChildPath "DirectReports_$($userUPN.Replace('@', '_')).xlsx"

# Export the data to Excel
$reportData | Export-Excel -Path $excelFilePath -AutoSize -Title "Direct Reports and Under-Reportees for $userUPN"

# Notify the user
Write-Host "Direct reports and under-reportees for $userUPN have been exported to $excelFilePath"