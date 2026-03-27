# Author: Sethukumar

$app = Get-AppxPackage -AllUsers | Where-Object {$_.Name -like "*Solitaire*"}

if ($app -ne $null)
{
Remove-AppxPackage $app -AllUsers}

timeout /t 30

$app = Get-AppxPackage -AllUsers | Where-Object { $_Name-like "*Solitaire*"}

if ($app -eq $null)
{exit 0)

else {
exit 1}