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
    Write-Log "*********************************"
    Write-Log "Removing Built-In Windows Apps"
    Write-Log "*********************************"
    [array]$apps = $AppsToRemove.replace('\"', '"') | ConvertFrom-Json

    $ProvisionedApps = Get-AppxProvisionedPackage -online
    $InstalledApps = Get-AppxPackage -AllUsers

    ForEach ($app in $apps) {

        If ($($ProvisionedApps.DisplayName) -contains $app) {
            Write-Log "Removing Provisioned AppX Package [$app]"
            Get-AppxProvisionedPackage -online | Where-Object {$_.DisplayName -eq "$app"} | Remove-AppxProvisionedPackage -Online -AllUsers
        }

        If ($($InstalledApps.Name) -contains $app) {
            Write-Log "Uninstalling Appx Package [$app] for all users."
            Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq "$app" } | Remove-AppxPackage -AllUsers
        }

    }
    Write-Log "*********************************"
    Write-Log "Removing Built-in Capabilities"
    Write-Log "*********************************"
    $capabilitylist = "App.Support.ContactSupport", "App.Support.QuickAssist"

    ForEach ($capability in $capabilitylist) {
        $InstalledCapability = $null
        $InstalledCapability = Get-WindowsCapability -Online | Where-Object { $_.Name -like "$capability*" -and $_.State -ne "NotPresent" }
        If ($InstalledCapability) {
            Write-Log "Removing [$Capability]"
            $InstalledCapability | Remove-WindowsCapability -Online
        }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}