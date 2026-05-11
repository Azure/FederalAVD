param(
    [bool]$DisableWindowsUpdate         = $true,
    [bool]$DisableM365Update            = $true,
    [bool]$DisableTeamsUpdate           = $true,
    [bool]$DisableOneDriveUpdate        = $true,
    [bool]$DisableEdgeUpdate            = $true,
    [bool]$DisableWebView2Update        = $true,
    [bool]$DisableStoreAutoUpdate       = $true,
    [bool]$DisableBuiltInAppsAutoUpdate = $true
)

$ErrorActionPreference = 'Stop'

function Write-OutputWithTimeStamp {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message
    )
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$PropertyType,
        $Value
    )
    If (!(Test-Path -Path $Path)) {
        Write-OutputWithTimeStamp "Creating registry key: $Path"
        New-Item -Path $Path -Force | Out-Null
    }
    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    If ($existing) {
        $current = Get-ItemPropertyValue -Path $Path -Name $Name
        If ($current -ne $Value) {
            Write-OutputWithTimeStamp "Setting $Path\$Name : $current -> $Value"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
        }
        Else {
            Write-OutputWithTimeStamp "$Path\$Name is already $Value"
        }
    }
    Else {
        Write-OutputWithTimeStamp "Creating $Path\$Name = $Value"
        New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
    }
}

function Disable-Service {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    If ($svc) {
        If ($svc.StartType -ne 'Disabled') {
            Write-OutputWithTimeStamp "Disabling service: $Name"
            Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        Else {
            Write-OutputWithTimeStamp "Service already disabled: $Name"
        }
    }
    Else {
        Write-OutputWithTimeStamp "Service not found (skipping): $Name"
    }
}

Start-Transcript -Path "$env:SystemRoot\Logs\Disable-SoftwareUpdates.log" -Force
Write-OutputWithTimeStamp 'Starting Disable-SoftwareUpdates'

#region Windows Update
If ($DisableWindowsUpdate) {
    Write-OutputWithTimeStamp '--- Windows Update ---'
    # Disable Windows Update via policy (NoAutoUpdate + AUOptions=1 = never check)
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate'    -PropertyType 'DWORD' -Value 1
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'AUOptions'       -PropertyType 'DWORD' -Value 1
    # Disable delivery optimisation peer sharing
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name 'DODownloadMode' -PropertyType 'DWORD' -Value 0
    # Disable Windows Update services
    Disable-Service -Name 'wuauserv'    # Windows Update
    Disable-Service -Name 'UsoSvc'      # Update Orchestrator Service
    Disable-Service -Name 'WaaSMedicSvc' # Windows Update Medic (protected — best-effort via reg)
    # Prevent WaaSMedicSvc from being re-enabled (image-safe workaround)
    Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' -Name 'Start' -PropertyType 'DWORD' -Value 4
}
#endregion

#region Microsoft 365 / Office Updates
If ($DisableM365Update) {
    Write-OutputWithTimeStamp '--- Microsoft 365 / Office Updates ---'
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'enableautomaticupdates' -PropertyType 'DWORD' -Value 0
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'hideupdatenotifications' -PropertyType 'DWORD' -Value 1
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'hideenabledisableupdates'  -PropertyType 'DWORD' -Value 1
    # Disable Click-to-Run update task
    $c2rTask = Get-ScheduledTask -TaskName 'Office Automatic Updates 2.0' -ErrorAction SilentlyContinue
    If ($c2rTask) {
        Write-OutputWithTimeStamp 'Disabling scheduled task: Office Automatic Updates 2.0'
        Disable-ScheduledTask -TaskName 'Office Automatic Updates 2.0' -TaskPath $c2rTask.TaskPath -ErrorAction SilentlyContinue | Out-Null
    }
}
#endregion

#region Teams for VDI
If ($DisableTeamsUpdate) {
    Write-OutputWithTimeStamp '--- Teams for VDI Updates ---'
    # New Teams (MSTeams) — disable auto-update via policy
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Teams' -Name 'DisableAutoUpdate' -PropertyType 'DWORD' -Value 1
    # Classic Teams machine-wide installer update prevention
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftTeams' -Name 'DisableAutoUpdate' -PropertyType 'DWORD' -Value 1
    # Disable Teams update scheduled tasks (classic)
    foreach ($taskName in @('Teams Update Task', 'TeamsMachineUninstallerTaskHkcu', 'TeamsMachineUninstallerTaskHklm')) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        If ($task) {
            Write-OutputWithTimeStamp "Disabling scheduled task: $taskName"
            Disable-ScheduledTask -TaskName $taskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

#region OneDrive
If ($DisableOneDriveUpdate) {
    Write-OutputWithTimeStamp '--- OneDrive Updates ---'
    # Prevent OneDrive per-machine from auto-updating
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\OneDrive'           -Name 'PreventAutoUpdate'                  -PropertyType 'DWORD' -Value 1
    # Disable OneDrive updater scheduled tasks
    foreach ($taskName in @('OneDrive Reporting Task-S-*', 'OneDrive Standalone Update Task-S-*')) {
        Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | ForEach-Object {
            Write-OutputWithTimeStamp "Disabling scheduled task: $($_.TaskName)"
            $_ | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

#region Microsoft Edge
If ($DisableEdgeUpdate) {
    Write-OutputWithTimeStamp '--- Microsoft Edge Updates ---'
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'UpdateDefault'                        -PropertyType 'DWORD'  -Value 0
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -PropertyType 'DWORD' -Value 0
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'       -Name 'EdgeEnhanceImagesEnabled'              -PropertyType 'DWORD'  -Value 0
    # Disable Edge Update services
    Disable-Service -Name 'edgeupdate'
    Disable-Service -Name 'edgeupdatem'
    # Disable Edge update scheduled tasks
    foreach ($taskName in @('MicrosoftEdgeUpdateTaskMachineCore', 'MicrosoftEdgeUpdateTaskMachineUA')) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        If ($task) {
            Write-OutputWithTimeStamp "Disabling scheduled task: $taskName"
            Disable-ScheduledTask -TaskName $taskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

#region WebView2
If ($DisableWebView2Update) {
    Write-OutputWithTimeStamp '--- WebView2 Runtime Updates ---'
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -PropertyType 'DWORD' -Value 0
    # Disable WebView2 updater scheduled tasks
    foreach ($taskName in @('MicrosoftEdgeUpdateTaskMachineCore', 'MicrosoftEdgeUpdateTaskMachineUA')) {
        # Shared with Edge above — already handled if $DisableEdgeUpdate was true; idempotent
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        If ($task) {
            Disable-ScheduledTask -TaskName $taskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

#region Microsoft Store / UWP App Auto-Update
If ($DisableStoreAutoUpdate) {
    Write-OutputWithTimeStamp '--- Microsoft Store Auto-Update ---'
    # Disable automatic app updates from the Store
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload'                 -PropertyType 'DWORD' -Value 2
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'DisableStoreApps'             -PropertyType 'DWORD' -Value 1
    # Disable Store update scheduled tasks
    $storeTasks = @(
        @{ Name = 'Scheduled Start';      Path = '\Microsoft\Windows\WindowsUpdate\' },
        @{ Name = 'ScanForUpdates';       Path = '\Microsoft\Windows\InstallService\' },
        @{ Name = 'ScanForUpdatesAsUser'; Path = '\Microsoft\Windows\InstallService\' },
        @{ Name = 'SmartRetry';           Path = '\Microsoft\Windows\InstallService\' }
    )
    foreach ($entry in $storeTasks) {
        $task = Get-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue
        If ($task) {
            Write-OutputWithTimeStamp "Disabling scheduled task: $($entry.Path)$($entry.Name)"
            Disable-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

#region Built-in Windows App Auto-Update (UWP)
If ($DisableBuiltInAppsAutoUpdate) {
    Write-OutputWithTimeStamp '--- Built-in Windows Apps Auto-Update ---'
    # Prevent pre-installed app content from updating silently
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -PropertyType 'DWORD' -Value 1
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent'   -PropertyType 'DWORD' -Value 1
    # Disable automatic maintenance (which triggers silent app updates)
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Task Scheduler\Maintenance' -Name 'Maintenance Disabled' -PropertyType 'DWORD' -Value 1
    # Disable background access for UWP apps (prevents background refresh/update checks)
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name 'LetAppsRunInBackground' -PropertyType 'DWORD' -Value 2
    # Disable scheduled tasks that update/reinstall built-in apps
    $uwpTasks = @(
        @{ Name = 'UpdateLibrary';          Path = '\Microsoft\Windows\Windows Media Sharing\' },
        @{ Name = 'StartupAppTask';         Path = '\Microsoft\Windows\ApplicationData\' },
        @{ Name = 'CleanupTemporaryState';  Path = '\Microsoft\Windows\ApplicationData\' },
        @{ Name = 'Pre-staged app cleanup'; Path = '\Microsoft\Windows\Appx\' }
    )
    foreach ($entry in $uwpTasks) {
        $task = Get-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue
        If ($task) {
            Write-OutputWithTimeStamp "Disabling scheduled task: $($entry.Path)$($entry.Name)"
            Disable-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

Write-OutputWithTimeStamp 'Disable-SoftwareUpdates complete.'
Stop-Transcript
