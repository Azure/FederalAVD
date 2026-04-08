param (
    [Parameter(Mandatory)]
    [ValidateSet("Add","Delete")]
    [string]$Operation,

    [Parameter(Mandatory)]
    [string]$VmNamePrefix,

    [Parameter(Mandatory)]
    [int]$Start,

    [Parameter(Mandatory)]
    [int]$End,

    [int]$PadWidth = 3,

    [Parameter(Mandatory)]
    [string]$TagName,

    # AVD parameters
    [Parameter(Mandatory)]
    [string]$HostPoolName,

    [Parameter(Mandatory)]
    [string]$HostPoolResourceGroup,

    # Drain mode control
    [Parameter(Mandatory)]
    [bool]$DrainMode
)

If (-not (Get-AzContext)) {
    Write-Host "No Azure context found. Please connect to Azure using Connect-AzAccount." -ForegroundColor Red
    exit 1
}

Import-Module Az.DesktopVirtualization -ErrorAction Stop

# Translate DrainMode -> AllowNewSession
$allowNewSession = -not $DrainMode

for ($i = $Start; $i -le $End; $i++) {

    $vmName = $VmNamePrefix + ('{0:D' + $PadWidth + '}' -f $i)

    # -------- VM TAGGING --------
    $vm = Get-AzResource `
        -ResourceType "Microsoft.Compute/virtualMachines" `
        -Filter "name eq '$vmName'" `
        -ErrorAction SilentlyContinue

    if ($vm) {
        if ($Operation -eq "Add") {
            Update-AzTag `
                -ResourceId $vm.ResourceId `
                -Operation Merge `
                -Tag @{ $TagName = '' }

            Write-Host "Tagged VM $vmName with $TagName=''" -ForegroundColor Green
        }
        else {
            Update-AzTag `
                -ResourceId $vm.ResourceId `
                -Operation Delete `
                -Tag @{ $TagName = "" }

            Write-Host "Deleted tag $TagName from VM $vmName" -ForegroundColor Cyan
        }
    }
    else {
        Write-Host "VM not found: $vmName" -ForegroundColor Yellow
    }

    # -------- AVD DRAIN MODE --------
    $sessionHostName = "$vmName.$HostPoolName"

    try {
        Update-AzWvdSessionHost `
            -ResourceGroupName $HostPoolResourceGroup `
            -HostPoolName $HostPoolName `
            -Name $sessionHostName `
            -AllowNewSession $allowNewSession

        if ($DrainMode) {
            Write-Host "Drain mode ENABLED for session host $vmName" -ForegroundColor Magenta
        }
        else {
            Write-Host "Drain mode DISABLED for session host $vmName" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Session host not found or update failed: $vmName" -ForegroundColor Yellow
    }
}