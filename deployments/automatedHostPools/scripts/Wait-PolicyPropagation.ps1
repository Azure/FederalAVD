[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 600)]
    [int]$WaitSeconds = 300
)

Write-Output "Waiting $WaitSeconds seconds for Azure Policy assignments and role assignments to propagate."
Start-Sleep -Seconds $WaitSeconds
Write-Output 'Azure Policy propagation wait completed.'