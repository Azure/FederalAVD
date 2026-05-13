<#
.SYNOPSIS
    Lists available VM SKUs in an Azure region along with their restriction status.

.DESCRIPTION
    Queries Azure Compute Resource SKUs for virtual machine types in the specified region,
    optionally filtered by SKU name, and reports on any location or availability zone
    restrictions that would prevent deployment in the current subscription.

.PARAMETER Region
    The Azure region to query (e.g. 'eastus2', 'usgovvirginia').

.PARAMETER SkuFilter
    A substring to filter SKU names. Only SKUs whose name contains this string will be
    returned. Leave empty to return all VM SKUs in the region.

.EXAMPLE
    .\Get-AvailableVMSkus.ps1 -Region eastus2 -SkuFilter 'D4s'

    Returns all D4s-series VM SKUs available in East US 2, along with any subscription
    or zone restrictions.

.EXAMPLE
    .\Get-AvailableVMSkus.ps1 -Region eastus2

    Returns every VM SKU available in East US 2.

.NOTES
    Requires an active Azure PowerShell session (Connect-AzAccount) with read access to
    the target subscription's compute resource SKUs.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $Region,

    [Parameter()]
    [string]
    $SkuFilter = ''
)
$VMSKUs = Get-AzComputeResourceSku -Location $Region | where-object {$_.ResourceType -eq 'virtualMachines' -and $_.Name.Contains($SkuFilter)}
$OutTable = @() 
foreach ($SkuName in $VMSKUs.Name) {
    $LocRestriction = if ((($VMSKUs | where-Object Name -EQ $SkuName).Restrictions.Type | Out-String).Contains("Location")) { "NotAvailableInRegion" }else { "Available - No region restrictions applied" }
    $ZoneRestriction = if ((($VMSKUs | where-Object Name -EQ $SkuName).Restrictions.Type | Out-String).Contains("Zone")) { "NotAvailableInZone: " + (((($VMSKUs | where-Object Name -EQ $SkuName).Restrictions.RestrictionInfo.Zones) | Where-Object { $_ }) -join ",") } else { "Available - No zone restrictions applied" }
 
    $OutTable += New-Object PSObject -Property @{
        "Name"                      = $SkuName
        "Location"                  = $Region
        "Applies to SubscriptionID" = $SubId
        "Subscription Restriction"  = $LocRestriction
        "Zone Restriction"          = $ZoneRestriction
    }
}
$OutTable | Select-Object Name, Location, "Applies to SubscriptionID", "Subscription Restriction", "Zone Restriction" | Sort-Object -Property Name | Format-Table   