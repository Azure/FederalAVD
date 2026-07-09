<#
.SYNOPSIS
    Checks whether an Azure VM size is available in a region and whether vCPU quota
    is sufficient for the requested number of session hosts.

.DESCRIPTION
    Validates that the specified VM size:
      - Exists in the target region for the current subscription
      - Has no location-level restrictions (subscription policy / quota block)
      - Has no availability zone restrictions (relevant when using availability =
        AvailabilityZones, which is the default in the poc parameter file)
      - Has sufficient vCPU quota (VM family quota and total regional vCPU quota)
        to deploy the requested number of session hosts

    Designed as a pre-flight check for the FederalAVD PoC / starter deployment.
    The default values match the poc.hostpool.parameters.json example file:
        virtualMachineSize : Standard_D4ads_v5  (4 vCPUs per VM)
        sessionHostCount   : 2

    Can also be used to evaluate any alternative VM size or session host count
    before a full deployment run.

.PARAMETER VmSize
    Azure VM size to validate.
    Default: Standard_D4ads_v5 (PoC starter default - 4 vCPUs, 16 GB RAM).

.PARAMETER Location
    Azure region to check. Required.
    Examples: eastus2, usgovvirginia, usgovarizona, usgoviowa.

.PARAMETER SessionHostCount
    Number of session host VMs to be deployed.
    Used to calculate total vCPU demand.
    Default: 2 (PoC starter default).

.PARAMETER SubscriptionId
    Azure subscription ID to check quota against.
    If omitted, the current subscription context is used.

.EXAMPLE
    .\Test-AvdVmSize.ps1 -Location eastus2

    Checks the PoC defaults (Standard_D4ads_v5 x 2) in East US 2.

.EXAMPLE
    .\Test-AvdVmSize.ps1 -Location usgovvirginia -SessionHostCount 5

    Checks whether Standard_D4ads_v5 x 5 has enough quota in US Gov Virginia.

.EXAMPLE
    .\Test-AvdVmSize.ps1 -VmSize Standard_D8ads_v5 -Location eastus2 -SessionHostCount 10

    Evaluates a larger VM size with 10 session hosts.

.NOTES
    Requires the Az PowerShell module (Az.Compute).
    Must be connected to Azure before running: Connect-AzAccount
    For Azure Government: Connect-AzAccount -Environment AzureUSGovernment

    If you need to see all VM sizes available in a region run:
        .\Get-AvailableVMSkus.ps1 -Region <location>
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$VmSize = 'Standard_D4ads_v5',

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter()]
    [int]$SessionHostCount = 2,

    [Parameter()]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Verify active Azure context
# ---------------------------------------------------------------------------
$context = Get-AzContext
if ($null -eq $context) {
    Write-Error 'No active Azure context. Run Connect-AzAccount (add -Environment AzureUSGovernment for Gov) before using this script.'
    exit 1
}

if ($SubscriptionId) {
    $context = Set-AzContext -Subscription $SubscriptionId
}

$subId = $context.Subscription.Id

Write-Host ''
Write-Host '=== AVD VM Size Pre-Flight Check ===' -ForegroundColor Cyan
Write-Host "  VM Size        : $VmSize"
Write-Host "  Location       : $Location"
Write-Host "  Session Hosts  : $SessionHostCount"
Write-Host "  Subscription   : $subId"
Write-Host "  Environment    : $($context.Environment.Name)"
Write-Host ''

$overallPass = $true

# ---------------------------------------------------------------------------
# Retrieve SKU details
# ---------------------------------------------------------------------------
Write-Host 'Checking SKU availability...' -ForegroundColor Cyan

$skuList = Get-AzComputeResourceSku -Location $Location -ErrorAction SilentlyContinue |
    Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize }

if (-not $skuList) {
    Write-Host "[FAIL] '$VmSize' does not exist in region '$Location'." -ForegroundColor Red
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host "  - Run .\Get-AvailableVMSkus.ps1 -Region $Location -SkuFilter 'D4' to list similar sizes."
    Write-Host "  - Update 'virtualMachineSize' in your parameter file and re-run this script."
    Write-Host ''
    exit 1
}

$sku = $skuList | Select-Object -First 1

# ---------------------------------------------------------------------------
# Check location-level restrictions
# ---------------------------------------------------------------------------
$locationRestricted = $sku.Restrictions |
    Where-Object { $_.Type -eq 'Location' -and ($_.RestrictionInfo.Locations -contains $Location) }

if ($locationRestricted) {
    Write-Host "[FAIL] '$VmSize' is RESTRICTED for this subscription in '$Location'." -ForegroundColor Red
    Write-Host "       This is typically a subscription quota policy or capacity reservation."
    Write-Host "       Check: Azure Portal -> Subscriptions -> [$subId] -> Usage + quotas"
    Write-Host ''
    exit 1
}

Write-Host "[PASS] '$VmSize' is available in '$Location' (no location restrictions)." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Check availability zone restrictions
# ---------------------------------------------------------------------------
$zoneRestrictions = $sku.Restrictions | Where-Object { $_.Type -eq 'Zone' }

if ($zoneRestrictions) {
    $restrictedZones = ($zoneRestrictions |
        ForEach-Object { $_.RestrictionInfo.Zones } |
        Where-Object { $_ } |
        Sort-Object -Unique) -join ', '

    Write-Host "[WARN] '$VmSize' has zone restrictions in '$Location'." -ForegroundColor Yellow
    Write-Host "       Restricted availability zones: $restrictedZones"
    Write-Host "       The poc starter parameter file uses availability = AvailabilityZones."
    Write-Host "       If all zones in your region are restricted, change 'availability' to 'None'"
    Write-Host "       in your parameter file, or choose a different VM size."
} else {
    Write-Host '[PASS] No availability zone restrictions.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Determine vCPU count from SKU capabilities
# ---------------------------------------------------------------------------
$vcpuCap = $sku.Capabilities | Where-Object { $_.Name -eq 'vCPUs' }
$vcpusPerVm = if ($vcpuCap) { [int]$vcpuCap.Value } else { 0 }
$totalVcpusNeeded = 0

Write-Host ''

if ($vcpusPerVm -eq 0) {
    Write-Host "[WARN] Could not read vCPU count for '$VmSize' from SKU capabilities." -ForegroundColor Yellow
} else {
    $totalVcpusNeeded = $vcpusPerVm * $SessionHostCount
    Write-Host "vCPU calculation: $VmSize = $vcpusPerVm vCPUs x $SessionHostCount session hosts = $totalVcpusNeeded vCPUs needed"
}

# ---------------------------------------------------------------------------
# Check vCPU quota (VM family and total regional)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Checking vCPU quota...' -ForegroundColor Cyan

$vmFamily  = $sku.Family
$allUsage  = Get-AzVMUsage -Location $Location

# VM family quota
$familyUsage = $allUsage | Where-Object { $_.Name.Value -eq $vmFamily }

if ($familyUsage) {
    foreach ($entry in $familyUsage) {
        $available = $entry.Limit - $entry.CurrentValue
        $needed    = if ($totalVcpusNeeded -gt 0) { $totalVcpusNeeded } else { $vcpusPerVm }
        if ($available -ge $needed) {
            Write-Host "[PASS] VM Family Quota ($($entry.Name.LocalizedValue))" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] VM Family Quota ($($entry.Name.LocalizedValue))" -ForegroundColor Red
            $overallPass = $false
        }
        Write-Host "       Limit: $($entry.Limit)  |  Used: $($entry.CurrentValue)  |  Available: $available  |  Needed: $needed"
    }
} else {
    Write-Host "[WARN] Could not locate family quota entry for VM family '$vmFamily'." -ForegroundColor Yellow
    Write-Host "       To inspect all entries: Get-AzVMUsage -Location $Location | Select-Object @{n='Name';e={`$_.Name.LocalizedValue}}, CurrentValue, Limit | Format-Table"
}

# Total regional vCPU quota
$regionalUsage = $allUsage | Where-Object { $_.Name.Value -eq 'cores' }

if ($regionalUsage) {
    foreach ($entry in $regionalUsage) {
        $available = $entry.Limit - $entry.CurrentValue
        $needed    = if ($totalVcpusNeeded -gt 0) { $totalVcpusNeeded } else { $vcpusPerVm }
        if ($available -ge $needed) {
            Write-Host "[PASS] Total Regional vCPUs ($($entry.Name.LocalizedValue))" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Total Regional vCPUs ($($entry.Name.LocalizedValue))" -ForegroundColor Red
            $overallPass = $false
        }
        Write-Host "       Limit: $($entry.Limit)  |  Used: $($entry.CurrentValue)  |  Available: $available  |  Needed: $needed"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan

if (-not $overallPass) {
    Write-Host "[ACTION REQUIRED] Insufficient vCPU quota for $SessionHostCount x $VmSize in '$Location'." -ForegroundColor Red
    Write-Host ''
    Write-Host 'Options:'
    Write-Host "  1. Request a quota increase:"
    Write-Host "     Azure Portal -> Subscriptions -> [$subId] -> Usage + quotas"
    Write-Host "     Filter by '$Location' and '$vmFamily', then select 'Request Increase'."
    Write-Host "     Gov cloud requests may require coordination with your cloud broker or sponsor."
    Write-Host "  2. Reduce 'sessionHostCount' in your parameter file (fewer total vCPUs needed)."
    Write-Host "  3. Choose a smaller VM size and update 'virtualMachineSize' in your parameter file."
    Write-Host "     Run .\Get-AvailableVMSkus.ps1 -Region $Location -SkuFilter 'D2' to see smaller options."
    Write-Host ''
    Write-Host '  See: docs/troubleshooting.md#vcpu-quota-exhaustion'
    Write-Host ''
} elseif ($zoneRestrictions) {
    Write-Host "[READY (with caution)] '$VmSize' is available but has zone restrictions in '$Location'." -ForegroundColor Yellow
    Write-Host "  Review the zone restriction warning above before deploying with availability = AvailabilityZones."
    Write-Host "  If the warning is acceptable, proceed with deployment."
    Write-Host ''
} else {
    Write-Host "[READY] '$VmSize' x $SessionHostCount is available in '$Location' with sufficient quota." -ForegroundColor Green
    Write-Host '  Proceed with deployment.'
    Write-Host ''
}
