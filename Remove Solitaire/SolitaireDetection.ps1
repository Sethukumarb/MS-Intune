# Author: Sethukumar

$app = Get-AppxPackage -Allusers | Where-Object {$_Name -like "*Solitaire*"}

If ($app -ne $null) 
{
exit 1
}

else {
exit 0
}