param(
    [Parameter(Mandatory=$true)]
    [string]$AppsToRemove
)

function Write-OutputWithTimeStamp {
    param(
        [parameter(ValueFromPipeline=$True, Mandatory=$True, Position=0)]
        [string]$Message
    )    
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

Start-Transcript -Path "$env:SystemRoot\Logs\Remove-Apps.log" -Force
Write-Output "*********************************"
Write-Output "Removing Built-In Windows Apps"
Write-Output "*********************************"
[array]$apps = $AppsToRemove.replace('\"', '"') | ConvertFrom-Json

$ProvisionedApps = Get-AppxProvisionedPackage -online
$InstalledApps = Get-AppxPackage -AllUsers

ForEach ($app in $apps) {

    If ($($ProvisionedApps.DisplayName) -contains $app) {
        Write-OutputWithTimeStamp "Removing Provisioned AppX Package [$app]"
        Get-AppxProvisionedPackage -online | Where-Object {$_.DisplayName -eq "$app"} | Remove-AppxProvisionedPackage -Online -AllUsers
    }

    If ($($InstalledApps.Name) -contains $app) {
        Write-OutputWithTimeStamp "Uninstalling Appx Package [$app] for all users."
        Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq "$app" } | Remove-AppxPackage -AllUsers
    }

}
Write-Output "*********************************"
Write-Output "Removing Built-in Capabilities"
Write-Output "*********************************"
$capabilitylist = "App.Support.ContactSupport", "App.Support.QuickAssist"

ForEach ($capability in $capabilitylist) {
    $InstalledCapability = $null
    $InstalledCapability = Get-WindowsCapability -Online | Where-Object { $_.Name -like "$capability*" -and $_.State -ne "NotPresent" }
    If ($InstalledCapability) {
        Write-OutputWithTimeStamp "Removing [$Capability]"
        $InstalledCapability | Remove-WindowsCapability -Online
    }
}
Stop-Transcript