<#
.SYNOPSIS
    Enables or disables AVD drain mode and manages the scaling plan exclusion tag
    for a numeric range of session hosts in a host pool.

.DESCRIPTION
    Retrieves session hosts from the specified host pool and operates on the subset
    identified by SessionHostPrefix + a padded numeric range (Start to End).

    Mode 'Drain'   - Sets AllowNewSession=false and adds the scaling plan exclusion
                     tag. Use on old hosts before replacement to stop new sessions
                     from being routed to them.

    Mode 'Restore' - Sets AllowNewSession=true and removes the scaling plan exclusion
                     tag. Use on new hosts after they are online and healthy.

    The VM resource ID is read directly from each session host object (ResourceId
    property), so no separate VM lookup is required and naming conventions on the
    Azure resource do not matter.

.PARAMETER Mode
    'Drain'   - Enable drain mode and add the exclusion tag.
    'Restore' - Disable drain mode and remove the exclusion tag.

.PARAMETER TagName
    The name of the tag used as the scaling plan exclusion marker.

.PARAMETER HostPoolName
    The name of the AVD host pool.

.PARAMETER HostPoolResourceGroup
    The resource group containing the host pool.

.PARAMETER SessionHostPrefix
    The prefix of the session host computer name before the padded index,
    e.g., 'avd-' for hosts named avd-001, avd-002, etc.

.PARAMETER Start
    The first index in the range to operate on (inclusive).

.PARAMETER End
    The last index in the range to operate on (inclusive).

.PARAMETER PadWidth
    The zero-pad width of the numeric suffix. Default is 3 (e.g., 001, 002).

.EXAMPLE
    # Drain old hosts 1-10 after the new hosts our online and healthy during a replacement cycle
    .\ Set-SessionHostMaintenanceMode.ps1 -Mode Drain -TagName ScalingPlanExclusion `
        -HostPoolName hp-avd-prod -HostPoolResourceGroup rg-avd `
        -SessionHostPrefix 'avd-' -Start 1 -End 10

.EXAMPLE
    # Restore new hosts 11-20 after they are online and healthy
    .\Set-SessionHostMaintenanceMode.ps1 -Mode Restore -TagName ScalingPlanExclusion `
        -HostPoolName hp-avd-prod -HostPoolResourceGroup rg-avd `
        -SessionHostPrefix 'avd-' -Start 11 -End 20
#>
param (
    [Parameter(Mandatory)]
    [ValidateSet('Drain', 'Restore')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$TagName,

    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$HostPoolResourceGroup,

    [Parameter(Mandatory)]
    [string]$SessionHostPrefix,

    [Parameter(Mandatory)]
    [int]$Start,

    [Parameter(Mandatory)]
    [int]$End,

    [int]$PadWidth = 3
)

if (-not (Get-AzContext)) {
    Write-Host 'No Azure context found. Please connect to Azure using Connect-AzAccount.' -ForegroundColor Red
    exit 1
}

Import-Module Az.DesktopVirtualization -ErrorAction Stop

$allowNewSession = $Mode -eq 'Restore'
$tagOperation    = if ($Mode -eq 'Drain') { 'Merge' } else { 'Delete' }

# Fetch all session hosts once. The ResourceId property on each object is the
# underlying VM's ARM resource ID - no separate VM lookup is needed.
$allSessionHosts = Get-AzWvdSessionHost `
    -ResourceGroupName $HostPoolResourceGroup `
    -HostPoolName $HostPoolName `
    -ErrorAction Stop

Write-Host "Processing hosts ${SessionHostPrefix}$($Start.ToString("D$PadWidth")) to ${SessionHostPrefix}$($End.ToString("D$PadWidth")) in '$Mode' mode..." -ForegroundColor Cyan

for ($i = $Start; $i -le $End; $i++) {

    $computerName = $SessionHostPrefix + $i.ToString("D$PadWidth")

    # Match against the computer name portion of the registered session host name
    # (<hostpool>/<computername>.<domain>) - handles any domain suffix automatically.
    $sessionHost = $allSessionHosts | Where-Object {
        (($_.Name -split '/')[1] -split '\.')[0] -eq $computerName
    }

    Write-Host "`n[$computerName]" -ForegroundColor White

    if (-not $sessionHost) {
        Write-Host '  Not found in host pool - skipping' -ForegroundColor Yellow
        continue
    }

    $fqdn         = ($sessionHost.Name -split '/')[1]
    $vmResourceId = $sessionHost.ResourceId

    # -------- VM TAGGING --------
    # ResourceId is the VM's ARM resource ID - use it directly, no name lookup needed.
    try {
        Update-AzTag `
            -ResourceId $vmResourceId `
            -Operation $tagOperation `
            -Tag @{ $TagName = '' }

        if ($Mode -eq 'Drain') {
            Write-Host "  Tag '$TagName' added" -ForegroundColor Green
        }
        else {
            Write-Host "  Tag '$TagName' removed" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "  Tag operation failed: $_" -ForegroundColor Red
    }

    # -------- AVD DRAIN MODE --------
    try {
        Update-AzWvdSessionHost `
            -ResourceGroupName $HostPoolResourceGroup `
            -HostPoolName $HostPoolName `
            -Name $fqdn `
            -AllowNewSession $allowNewSession

        if ($Mode -eq 'Drain') {
            Write-Host '  Drain mode ENABLED (AllowNewSession=false)' -ForegroundColor Magenta
        }
        else {
            Write-Host '  Drain mode DISABLED (AllowNewSession=true)' -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  Session host update failed: $_" -ForegroundColor Red
    }
}

Write-Host "`nDone." -ForegroundColor Cyan
