[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 600)]
    [int]$WaitSeconds
)

Write-Output "Waiting $WaitSeconds seconds for Azure RBAC assignments to propagate."
Start-Sleep -Seconds $WaitSeconds
Write-Output 'Azure RBAC propagation wait completed.'
