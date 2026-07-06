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

# Fetch all session hosts once to avoid a per-VM API call.
# Name format returned by the API: <hostpoolname>/<computername>.<domain>
$allSessionHosts = Get-AzWvdSessionHost `
    -ResourceGroupName $HostPoolResourceGroup `
    -HostPoolName $HostPoolName `
    -ErrorAction SilentlyContinue

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
    # Match on <computername>.* to handle any domain without hardcoding.
    $matchedHost = $allSessionHosts | Where-Object { ($_.Name -split '/')[1] -like "$vmName.*" }

    if ($matchedHost) {
        $sessionHostName = ($matchedHost.Name -split '/')[1]
        try {
            Update-AzWvdSessionHost `
                -ResourceGroupName $HostPoolResourceGroup `
                -HostPoolName $HostPoolName `
                -Name $sessionHostName `
                -AllowNewSession $allowNewSession

            if ($DrainMode) {
                Write-Host "Drain mode ENABLED for session host $sessionHostName" -ForegroundColor Magenta
            }
            else {
                Write-Host "Drain mode DISABLED for session host $sessionHostName" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "Session host update failed for $sessionHostName : $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "No session host found in host pool matching VM name: $vmName" -ForegroundColor Yellow
    }
}