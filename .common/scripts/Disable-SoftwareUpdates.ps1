<#
.SYNOPSIS
    Disables selected software update channels in a Windows image for AVD pooled host pool scenarios.

.DESCRIPTION
    Intended for use during image customization via Azure VM Run Command. Each parameter selects an
    update channel to permanently disable by setting policy registry keys, disabling related Windows
    services, and disabling scheduled tasks. Parameters are passed as strings ('true'/'false') because
    Azure Run Command passes all parameters as strings.

    Designed for pooled AVD host pools where VMs are regularly replaced from a golden image rather
    than patched in place. Disabling update channels prevents unwanted background downloads, restarts,
    and policy drift after deployment.

.PARAMETER DisableWindowsUpdate
    Disables the Windows Update (wuauserv) and Update Orchestrator (UsoSvc) services, sets AU policy
    to never check for updates (AUOptions=1, NoAutoUpdate=1), and disables Delivery Optimization peer
    sharing (DODownloadMode=0).

.PARAMETER DisableM365Update
    Disables Click-to-Run automatic updates for Microsoft 365 / Office apps via policy keys and
    disables the 'Office Automatic Updates 2.0' scheduled task.

.PARAMETER DisableTeamsUpdate
    Sets the DisableAutoUpdate registry value for new Teams (MSTeams) to prevent automatic updates.

.PARAMETER DisableOneDriveUpdate
    Sets the OneDrive sync app update ring to Deferred (GPOSetUpdateRing=0) via the documented policy
    key, which defers updates for up to 60 days. Also disables the OneDrive standalone update
    scheduled tasks that apply when OneDrive is not running.

.PARAMETER DisableEdgeUpdate
    Disables the Edge update services (edgeupdate / edgeupdatem), sets the EdgeUpdate policy to block
    all updates (UpdateDefault=0 and the Edge app-specific GUID), and disables the Edge update
    scheduled tasks.

.PARAMETER DisableWebView2Update
    Sets the EdgeUpdate policy for the WebView2 Runtime GUID to block updates. Shared scheduled tasks
    with Edge are handled idempotently.

.PARAMETER DisableStoreAutoUpdate
    Disables Store auto-download (AutoDownload policy and InstallService scheduled tasks) and
    cloud content delivery (DisableWindowsConsumerFeatures, DisableCloudOptimizedContent) that
    allows pre-installed UWP apps to silently refresh.

.NOTES
    - All parameters default to 'true'. Pass 'false' to leave a channel enabled.
    - WaaSMedicSvc (Windows Update Medic) is a protected service; disabling via Set-Service is
      best-effort. The Start registry value is set directly as a fallback.
    - Run as SYSTEM or with local administrator privileges.
    - Log written to %SystemRoot%\Logs\Disable-SoftwareUpdates.log.

.LINK
    Windows Update AU policy keys:
    https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings#configuring-automatic-updates-by-editing-the-registry

.LINK
    Delivery Optimization DODownloadMode:
    https://learn.microsoft.com/en-us/windows/deployment/update/waas-delivery-optimization-reference#download-mode

.LINK
    Microsoft 365 / Office update management:
    https://learn.microsoft.com/en-us/deployoffice/updates/manage-updates-office-deployment-tool

.LINK
    New Teams VDI deployment and update policy:
    https://learn.microsoft.com/en-us/microsoftteams/new-teams-vdi-requirements-deploy

.LINK
    OneDrive sync app update process (rings, update checks, scheduled tasks):
    https://learn.microsoft.com/en-us/sharepoint/sync-client-update-process

.LINK
    OneDrive GPOSetUpdateRing policy (Set the sync app update ring):
    https://learn.microsoft.com/en-us/sharepoint/use-group-policy#set-the-sync-app-update-ring

.LINK
    Microsoft Edge Update policies (UpdateDefault, per-app GUIDs):
    https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies

.LINK
    WebView2 Runtime enterprise management:
    https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/enterprise

.LINK
    Microsoft Store ApplicationManagement policy CSP:
    https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-applicationmanagement

.LINK
    CloudContent / consumer features policy CSP:
    https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowwindowsconsumerfeatures

#>
param(
    [string]$DisableWindowsUpdate = 'false',
    [string]$DisableM365Update = 'false',
    [string]$DisableTeamsUpdate = 'false',
    [string]$DisableOneDriveUpdate = 'false',
    [string]$DisableEdgeUpdate = 'false',
    [string]$DisableWebView2Update = 'false',
    [string]$DisableStoreAutoUpdate = 'false'
)

$DisableWindowsUpdate = [System.Convert]::ToBoolean($DisableWindowsUpdate)
$DisableM365Update = [System.Convert]::ToBoolean($DisableM365Update)
$DisableTeamsUpdate = [System.Convert]::ToBoolean($DisableTeamsUpdate)
$DisableOneDriveUpdate = [System.Convert]::ToBoolean($DisableOneDriveUpdate)
$DisableEdgeUpdate = [System.Convert]::ToBoolean($DisableEdgeUpdate)
$DisableWebView2Update = [System.Convert]::ToBoolean($DisableWebView2Update)
$DisableStoreAutoUpdate = [System.Convert]::ToBoolean($DisableStoreAutoUpdate)

$ErrorActionPreference = 'Stop'

$LogFile = "$env:SystemRoot\Logs\Disable-SoftwareUpdates.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
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
        Write-Log "Creating registry key: $Path"
        New-Item -Path $Path -Force | Out-Null
    }
    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    If ($existing) {
        $current = Get-ItemPropertyValue -Path $Path -Name $Name
        If ($current -ne $Value) {
            Write-Log "Setting $Path\$Name : $current -> $Value"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
        }
        Else {
            Write-Log "$Path\$Name is already $Value"
        }
    }
    Else {
        Write-Log "Creating $Path\$Name = $Value"
        New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
    }
}

function Disable-Service {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    If ($svc) {
        If ($svc.StartType -ne 'Disabled') {
            Write-Log "Disabling service: $Name"
            Set-Service -Name $Name -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        Else {
            Write-Log "Service already disabled: $Name"
        }
    }
    Else {
        Write-Log "Service not found (skipping): $Name"
    }
}

try {
Write-Log 'Starting Disable-SoftwareUpdates'

#region Windows Update
If ($DisableWindowsUpdate) {
    Write-Log '--- Windows Update ---'
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
    $updateTaskName = 'Scheduled Start'
    $updateTaskPath = '\Microsoft\Windows\WindowsUpdate\'
    $updateTask = Get-ScheduledTask -TaskName $updateTaskName -TaskPath $updateTaskPath -ErrorAction SilentlyContinue
    if ($updateTask) {
            Write-Log "Disabling scheduled task: $updateTaskPath$updateTaskName"
            Disable-ScheduledTask -TaskName $updateTaskName -TaskPath $updateTaskPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
    #endregion

    #region Microsoft 365 / Office Updates
    If ($DisableM365Update) {
        Write-Log '--- Microsoft 365 / Office Updates ---'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'enableautomaticupdates' -PropertyType 'DWORD' -Value 0
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'hideupdatenotifications' -PropertyType 'DWORD' -Value 1
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'hideenabledisableupdates'  -PropertyType 'DWORD' -Value 1
        # Disable Click-to-Run update task
        $c2rTaskName = 'Office Automatic Updates 2.0'
        $c2rTask = Get-ScheduledTask -TaskName $c2rTaskName -ErrorAction SilentlyContinue
        If ($c2rTask) {
            Write-Log "Disabling scheduled task: $c2rTaskName"
            Disable-ScheduledTask -TaskName $c2rTaskName -TaskPath $c2rTask.TaskPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
    #endregion

    #region Teams for VDI
    If ($DisableTeamsUpdate) {
        Write-Log '--- Teams for VDI Updates ---'
        # New Teams (MSTeams) — disable auto-update via policy
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Teams' -Name 'DisableAutoUpdate' -PropertyType 'DWORD' -Value 1
    }
    #endregion

    #region OneDrive
    If ($DisableOneDriveUpdate) {
        Write-Log '--- OneDrive Updates ---'
        # Set the OneDrive update ring to Deferred (value 0) via the documented GPOSetUpdateRing policy.
        # Deferred ring defers new builds for up to 60 days and allows controlled update deployment.
        # Ref: https://learn.microsoft.com/en-us/sharepoint/use-group-policy#set-the-sync-app-update-ring
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'GPOSetUpdateRing' -PropertyType 'DWORD' -Value 0
        # Disable the OneDrive standalone update scheduled task that triggers updates when OneDrive is not running.
        # Ref: https://learn.microsoft.com/en-us/sharepoint/sync-client-update-process#how-the-sync-app-checks-for-and-applies-updates
        foreach ($taskName in @('OneDrive Reporting Task-S-*', 'OneDrive Standalone Update Task-S-*')) {
            Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Log "Disabling scheduled task: $($_.TaskName)"
                $_ | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    #endregion

    #region Microsoft Edge
    If ($DisableEdgeUpdate) {
        Write-Log '--- Microsoft Edge Updates ---'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'UpdateDefault'                        -PropertyType 'DWORD'  -Value 0
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -PropertyType 'DWORD' -Value 0
        # Disable Edge Update services
        Disable-Service -Name 'edgeupdate'
        Disable-Service -Name 'edgeupdatem'
        # Disable Edge update scheduled tasks
        foreach ($taskName in @('MicrosoftEdgeUpdateTaskMachineCore', 'MicrosoftEdgeUpdateTaskMachineUA')) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            If ($task) {
                Write-Log "Disabling scheduled task: $taskName"
                Disable-ScheduledTask -TaskName $taskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    #endregion

    #region WebView2
    If ($DisableWebView2Update) {
        Write-Log '--- WebView2 Runtime Updates ---'
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
        Write-Log '--- Microsoft Store / UWP App Auto-Update ---'
        # Disable automatic app updates from the Store
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -PropertyType 'DWORD' -Value 2
        # Disable Store update scheduled tasks
        $storeTasks = @(
            @{ Name = 'ScanForUpdates'; Path = '\Microsoft\Windows\InstallService\' },
            @{ Name = 'ScanForUpdatesAsUser'; Path = '\Microsoft\Windows\InstallService\' },
            @{ Name = 'SmartRetry'; Path = '\Microsoft\Windows\InstallService\' }
        )
        foreach ($entry in $storeTasks) {
            $task = Get-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue
            If ($task) {
                Write-Log "Disabling scheduled task: $($entry.Path)$($entry.Name)"
                Disable-ScheduledTask -TaskName $entry.Name -TaskPath $entry.Path -ErrorAction SilentlyContinue | Out-Null
            }
        }
        # Prevent pre-installed app content from updating silently via cloud content delivery
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -PropertyType 'DWORD' -Value 1
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent'   -PropertyType 'DWORD' -Value 1
    }
    #endregion

    Write-Log 'Disable-SoftwareUpdates complete.'
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}
