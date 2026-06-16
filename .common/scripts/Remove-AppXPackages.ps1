param(
    [Parameter(Mandatory=$true)]
    [string]$AppsToRemove
)

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Remove-Apps.log"

function Write-Log {
    param(
        [parameter(ValueFromPipeline=$True, Mandatory=$True, Position=0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting Remove-Apps script with the following parameters:"
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)
    [array]$apps = $AppsToRemove.replace('\"', '"') | ConvertFrom-Json

    # Image build context: no user profiles exist, so only provisioned package removal is relevant.
    # Get-AppxPackage -AllUsers is intentionally omitted — it hangs on Windows 11 25H2 in OOBE/image
    # build scenarios when no user hives are mounted, and provides no value on a fresh image.
    Write-Log "Enumerating provisioned AppX packages..."
    $ProvisionedApps = Get-AppxProvisionedPackage -Online

    foreach ($app in $apps) {
        $match = $ProvisionedApps | Where-Object { $_.DisplayName -eq $app }
        if ($match) {
            Write-Log "Removing provisioned AppX package [$app]"
            try {
                $match | Remove-AppxProvisionedPackage -Online -ErrorAction Stop
            }
            catch {
                Write-Log "WARNING: Failed to remove provisioned package [$app]: $($_.Exception.Message)"
            }
        }
        else {
            Write-Log "Provisioned AppX package [$app] not found — skipping."
        }
    }

    Write-Log "*********************************"
    Write-Log "Removing Built-in Capabilities"
    Write-Log "*********************************"
    $capabilityList = "App.Support.ContactSupport", "App.Support.QuickAssist"

    Write-Log "Enumerating installed Windows capabilities..."
    $InstalledCapabilities = Get-WindowsCapability -Online

    foreach ($capability in $capabilityList) {
        $match = $InstalledCapabilities | Where-Object { $_.Name -like "$capability*" -and $_.State -ne 'NotPresent' }
        if ($match) {
            Write-Log "Removing capability [$capability]"
            try {
                $match | Remove-WindowsCapability -Online -ErrorAction Stop
            }
            catch {
                Write-Log "WARNING: Failed to remove capability [$capability]: $($_.Exception.Message)"
            }
        }
        else {
            Write-Log "Capability [$capability] not present — skipping."
        }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    if ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}