#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Applies VDI performance and resource optimizations to a Windows image for AVD deployment.

.DESCRIPTION
    Optimizes a Windows image for AVD based on the selected optimization profile and whether
    outbound internet traffic should be restricted in the deployed environment.

    References:
      [1] MS VDI optimization guide (primary source for all services, tasks, and policies):
          https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remote-desktop-services-vdi-optimize-configuration
      [2] Windows Restricted Traffic Limited Functionality Baseline (items marked * in [1]):
          https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services
      [3] SMB client performance tuning (Section 9 - LanManWorkstation parameters):
          https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/
      [4] FSLogix profile container + OneDrive Files On-Demand (Storage Sense rationale):
          https://learn.microsoft.com/en-us/fslogix/tutorial-container-onedrive
      [5] Microsoft Edge Update policies (Section 6 - EdgeUpdate registry):
          https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies
      [6] OneDrive GPO / update ring policy (Section 6 - GPOSetUpdateRing):
          https://learn.microsoft.com/en-us/sharepoint/use-group-policy#set-the-sync-app-update-ring
      [7] Update channel lockdown logic originally from Disable-SoftwareUpdates.ps1
          (that script is now fully superseded by NonPersistent sections of this script).

    This script does NOT handle the following (each has a dedicated script):
      - Removal of built-in AppX packages
      - Disk cleanup / temp file removal

    Optimization categories applied:
      - System services        : disable services with no benefit in a VDI environment
      - Scheduled tasks        : disable tasks that waste resources or conflict with image servicing
      - Registry policies      : privacy, telemetry, visual effects, network, and feature controls
      - Default user hive      : visual effect and privacy settings for all new user sessions
      - Network tuning         : SMB / LanManWorkstation client performance parameters
      - Autologgers            : disable startup event trace sessions with no VDI value
      - Optional features      : remove Windows components not needed in VDI

    Optimization profiles (-OptimizationProfile):
      None                     - No optimization. When -RestrictInternet is also false
                                 the script logs and exits cleanly. When true, only
                                 the restricted traffic settings (Section 7) are applied.
      NonPersistent-UpdatesOnly - Locks down all software update channels only (Sections
                                 2, 4, 6): OS, M365, Teams, OneDrive, Edge, WebView2,
                                 Store. Use when you manage other VDI hardening separately.
      NonPersistent-Full       - Full optimization for pooled AVD host pools where VMs
                                 are replaced on a regular cadence (typically monthly).
      Persistent               - Full optimization minus update-channel lockdown. Update
                                 channels remain intact for SCCM, Intune, or similar.

    Restricted internet traffic (-RestrictInternet):
      When true, disables NCSI passive polling, online font providers, Teredo IPv6,
      and WiFi autologgers (Section 7). Applies independently of -OptimizationProfile,
      including when profile is None. Default is false.

    Deliberate deviations from the VDI article [1]:

      Storage Sense [Section 5 - machine policy]:
        The article recommends disabling Storage Sense. This script ENABLES and
        configures it via ADMX-backed Computer Configuration policy
        (Software\Policies\Microsoft\Windows\StorageSense, since Win10 1903).
        In FSLogix profile container deployments, OneDrive Files On-Demand caches
        locally opened files inside the container VHD on Azure Files or Azure
        NetApp Files. Without proactive dehydration, containers grow monotonically
        -- increasing storage cost and FSLogix attach time. Storage Sense is
        configured to dehydrate OneDrive content not accessed in 30 days, run
        monthly, and clean temp files. Recycle Bin and Downloads cleanup are left
        off to avoid surprising users. Machine policy overrides any per-user
        Settings UI configuration.
        Ref: [4], https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image

      Windows Search / WSearch service [Section 1]:
        The article recommends evaluating WSearch for disabling. This script
        intentionally leaves it at its default startup type. The OS disk and
        search index persist for the VM's full monthly lifecycle; the FSLogix
        Outlook/Exchange search index survives image replacement by living inside
        the profile container. Disabling WSearch would break Outlook and File
        Explorer search for every user for the entire month a VM is in service.
        A commented-out Disable-VdiService call is provided for special-purpose
        (kiosk / task-worker) images where search is genuinely not required.

      RegIdleBackup scheduled task [Section 3]:
        The article lists RegIdleBackup for disabling. This script retains it.
        Registry hives persist across reboots for the VM's monthly lifecycle;
        backups enable in-place recovery from hive corruption without a VM redeploy.

      SilentCleanup scheduled task [Section 3]:
        The article lists SilentCleanup for disabling. This script retains it.
        It only triggers on low disk space and provides ongoing hygiene over the
        monthly operational life of the VM -- complementary to, not redundant with,
        the image-build-time disk cleanup script.

.PARAMETER OptimizationProfile
    The optimization profile to apply. See the .DESCRIPTION for full details.

      None                     - No optimization; only -RestrictInternet takes effect.
      NonPersistent-UpdatesOnly - Lock down update channels only (OS, M365, Teams,
                                 OneDrive, Edge, WebView2, Store).
      NonPersistent-Full       - Full optimization for pooled AVD host pools.
      Persistent               - Full optimization minus update-channel lockdown.

.PARAMETER RestrictInternet
    When true, restricts outbound network traffic (NCSI, font providers, Teredo, WiFi
    autologgers). Applies to all profiles, including None. Default is false.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile NonPersistent-Full
    Full optimization for a pooled AVD image. Internet traffic not restricted.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile NonPersistent-Full -RestrictInternet $true
    Full optimization for a pooled image in an air-gapped or restricted environment.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile NonPersistent-UpdatesOnly
    Lock down update channels only. Combine with your own optimization tooling.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile Persistent -RestrictInternet $true
    Personal host pool in a restricted network environment.

.EXAMPLE
    .\Optimize-AVDImage.ps1 -OptimizationProfile None -RestrictInternet $true
    Restrict internet traffic only; skip all other optimization.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('None', 'NonPersistent-UpdatesOnly', 'NonPersistent-Full', 'Persistent')]
    [string]$OptimizationProfile,

    # Accepts bool or string ('true'/'false'/'1'/'0') — Azure RunCommand passes all
    # parameters as strings, so [bool] would reject 'false' with a type error.
    [Parameter(Mandatory = $false)]
    [string]$RestrictInternet = 'false'
)

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Optimize-AVDImage.log"
$RestrictInternetBool = $RestrictInternet -in @('true', '1', 'yes')
$RunFullOptimization = $OptimizationProfile -in @('NonPersistent-Full', 'Persistent')
$RunNonPersistentSections = $OptimizationProfile -in @('NonPersistent-UpdatesOnly', 'NonPersistent-Full')

# LGPO state - initialized here; populated in the detection block inside the try {} below
$script:LgpoExe = Join-Path $env:SystemRoot 'System32\LGPO.exe'
$script:LgpoAvailable = $false
$script:LgpoLines = [System.Collections.Generic.List[string]]@()
# Parallel list of raw registry data used to fall back to direct writes if LGPO fails
$script:LgpoFallbackEntries = [System.Collections.Generic.List[hashtable]]@()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(ValueFromPipeline = $true, Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

function Disable-VdiService {
    <#
    .SYNOPSIS
        Stops and disables a Windows service if it exists.
        Falls back to setting the Start registry value directly when Set-Service
        fails (e.g., protected services such as WaaSMedicSvc).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "  [SKIP] Service not found: $Name"
        return
    }
    try {
        # Do not attempt to stop the service during an image build -- the image is
        # about to be sysprepped and captured. Only the startup type matters: setting
        # it to Disabled writes Start=4 to the registry so the service does not run
        # after the image is deployed. Stopping during the build risks blocking
        # indefinitely on services with stubborn dependents (e.g. DPS).
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Write-Log "  [OK]   Disabled service: $DisplayName ($Name)"
    }
    catch {
        Write-Log "  [WARN] Set-Service failed for $Name ($_ ) - attempting registry fallback"
        try {
            # Start value: 4 = Disabled. This is the reliable fallback for
            # SFC-protected services that reject Set-Service calls.
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" `
                -Name 'Start' -Value 4 -Type DWord -Force -ErrorAction Stop
            Write-Log "  [OK]   Disabled service via registry fallback: $DisplayName ($Name)"
        }
        catch {
            Write-Log "  [WARN] Registry fallback also failed for $Name - $_"
        }
    }
}

function Disable-VdiTask {
    <#
    .SYNOPSIS
        Disables a scheduled task if it exists.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskPath,
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            Write-Log "  [SKIP] Scheduled task not found: $TaskPath$TaskName"
            return
        }
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log "  [OK]   Disabled task: $TaskPath$TaskName"
    }
    catch {
        Write-Log "  [WARN] Could not disable task $TaskPath$TaskName - $_"
    }
}

function Set-PolicyValue {
    <#
    .SYNOPSIS
        Creates or updates a registry value, creating the key path if needed.
        When LGPO.exe is available and the path is a policy subtree, queues
        the entry for batch application via Invoke-ApplyPolicyQueue:
          Computer: HKLM:\SOFTWARE\Policies\... and legacy
                    HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\...
          User:     HKLM:\TempDefaultUser\Software\Policies\... and legacy
                    HKLM:\TempDefaultUser\Software\Microsoft\Windows\CurrentVersion\Policies\...
        All other paths write directly to the registry.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Value,
        [Parameter(Mandatory = $false)]
        [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::DWord
    )
    # Route policy paths through LGPO when available (DWORD and SZ types only).
    # Computer section: machine policy subtrees under HKLM:\SOFTWARE\...
    # User section:     user policy subtrees under HKLM:\TempDefaultUser\...
    #                   (LGPO writes these to GroupPolicy\User\Registry.pol,
    #                    applying to all users at logon - same effective scope
    #                    as writing to the default user hive policies directly)
    $lgpoSection = $null
    $lgpoRelPath = $null
    if ($script:LgpoAvailable) {
        if ($Path -like 'HKLM:\SOFTWARE\Policies\*' -or
            $Path -like 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\*') {
            $lgpoSection = 'Computer'
            $lgpoRelPath = $Path -replace '^HKLM:\\', ''
        }
        elseif ($Path -like 'HKLM:\TempDefaultUser\Software\Policies\*' -or
            $Path -like 'HKLM:\TempDefaultUser\Software\Microsoft\Windows\CurrentVersion\Policies\*') {
            $lgpoSection = 'User'
            $lgpoRelPath = $Path -replace '^HKLM:\\TempDefaultUser\\', ''
        }
    }
    if ($null -ne $lgpoSection) {
        $lgpoData = switch ($Type) {
            ([Microsoft.Win32.RegistryValueKind]::DWord) { "DWORD:$Value" }
            ([Microsoft.Win32.RegistryValueKind]::String) { "SZ:$Value" }
            default { $null }
        }
        if ($null -ne $lgpoData) {
            $null = $script:LgpoLines.Add($lgpoSection)
            $null = $script:LgpoLines.Add($lgpoRelPath)
            $null = $script:LgpoLines.Add($Name)
            $null = $script:LgpoLines.Add($lgpoData)
            $null = $script:LgpoLines.Add('')
            $null = $script:LgpoFallbackEntries.Add(@{ Path = $Path; Name = $Name; Value = $Value; Type = $Type })
            Write-Log "  [LGPO/$lgpoSection] Queued: $Path\$Name = $Value"
            return
        }
    }
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        Write-Log "  [OK]   Registry: $Path\$Name = $Value"
    }
    catch {
        Write-Log "  [WARN] Could not set $Path\$Name - $_"
    }
}

function Disable-VdiAutologger {
    <#
    .SYNOPSIS
        Disables a Windows startup event trace (autologger) session.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$Name"
    if (Test-Path $regPath) {
        Set-PolicyValue -Path $regPath -Name 'Start' -Value 0
        Write-Log "  [OK]   Disabled autologger: $Name"
    }
    else {
        Write-Log "  [SKIP] Autologger not found: $Name"
    }
}

function Invoke-ApplyPolicyQueue {
    <#
    .SYNOPSIS
        Applies all LGPO-queued policy entries in a single lgpo.exe invocation,
        then clears the queue. No-op if LGPO is unavailable or the queue is empty.
    #>
    if (-not $script:LgpoAvailable -or $script:LgpoLines.Count -eq 0) { return }
    $entryCount = [int]($script:LgpoLines.Count / 5)
    $tempFile = Join-Path $env:SystemRoot "Temp\LGPO-$(Get-Date -Format 'HHmmssff').txt"
    $lgpoSucceeded = $false
    try {
        # Write the registry text file using Add-Content, one line at a time.
        # Format per entry (matching Update-LocalGPOTextFile in the artifact scripts):
        #   Computer           <- scope
        #   SOFTWARE\Policies\ <- key path, stripped of HKLM:\ prefix
        #   ValueName          <- value name
        #   DWORD:1            <- type:data
        #                      <- blank line
        foreach ($line in $script:LgpoLines) {
            Add-Content -Path $tempFile -Value $line
        }
        $proc = Start-Process -FilePath $script:LgpoExe -ArgumentList "/t `"$tempFile`"" -Wait -PassThru
        Write-Log "  LGPO exitcode: '$($proc.ExitCode)'"
        if ($proc.ExitCode -eq 0) {
            Write-Log "  [OK]   LGPO applied $entryCount policy values"
            $lgpoSucceeded = $true
        } else {
            Write-Log "  [WARN] LGPO exited $($proc.ExitCode) for $entryCount values"
        }
    }
    catch {
        Write-Log "  [WARN] LGPO flush failed: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }

    if (-not $lgpoSucceeded) {
        # LGPO failed or threw - apply queued entries directly to the registry so
        # policy values are not silently lost.
        Write-Log "  Applying $($script:LgpoFallbackEntries.Count) policy values via registry fallback..."
        $fbOk = 0; $fbFail = 0
        foreach ($entry in $script:LgpoFallbackEntries) {
            try {
                if (-not (Test-Path $entry.Path)) { New-Item -Path $entry.Path -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -Type $entry.Type -Force -ErrorAction Stop
                $fbOk++
            } catch {
                Write-Log "  [WARN] Fallback registry write failed for $($entry.Path)\$($entry.Name): $_"
                $fbFail++
            }
        }
        Write-Log "  [OK]   Registry fallback: $fbOk applied, $fbFail failed"
    }

    $script:LgpoLines.Clear()
    $script:LgpoFallbackEntries.Clear()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Log ""
    Write-Log "============================================================"
    Write-Log "  Optimize-AVDImage"
    Write-Log "============================================================"
    Write-Log "  Profile         : $OptimizationProfile"
    Write-Log "  RestrictInternet: $RestrictInternetBool"
    Write-Log "  OS              : $([System.Environment]::OSVersion.VersionString)"
    Write-Log "  Timestamp       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "============================================================"
    Write-Log ""

    # -----------------------------------------------------------------------
    # LGPO Detection
    # Attempt to locate or download LGPO.exe for applying policy settings via
    # Local Group Policy Objects. If unavailable, all policy settings fall back
    # to direct registry writes inside Set-PolicyValue.
    # -----------------------------------------------------------------------
    Write-Log "--- LGPO Detection ---"
    if (-not (Test-Path -Path $script:LgpoExe -PathType Leaf)) {
        Write-Log "  LGPO.exe not found in System32 - attempting download from Microsoft..."
        $lgpoTemp = Join-Path $env:TEMP 'Optimize-AVDImage-LGPO'
        try {
            if (-not (Test-Path $lgpoTemp)) { New-Item -Path $lgpoTemp -ItemType Directory -Force | Out-Null }
            $lgpoZip = Join-Path $lgpoTemp 'LGPO.zip'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object System.Net.WebClient).DownloadFile(
                'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip',
                $lgpoZip)
            Expand-Archive -Path $lgpoZip -DestinationPath $lgpoTemp -Force
            $lgpoFile = Get-ChildItem -Path $lgpoTemp -Filter 'LGPO.exe' -Recurse | Select-Object -First 1
            if ($lgpoFile) {
                Copy-Item -Path $lgpoFile.FullName -Destination $script:LgpoExe -Force
                $script:LgpoAvailable = Test-Path -Path $script:LgpoExe -PathType Leaf
                Write-Log "  [OK]   LGPO.exe downloaded and installed to System32"
            }
            else {
                Write-Log "  [WARN] LGPO.exe not found in downloaded archive - registry fallback in use"
            }
        }
        catch {
            Write-Log "  [WARN] Could not download LGPO.exe ($_) - registry fallback in use for all policy settings"
        }
        finally {
            Remove-Item -Path $lgpoTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        $script:LgpoAvailable = $true
        Write-Log "  [OK]   LGPO.exe found in System32 - policy settings will be applied via LGPO"
    }
    Write-Log ""

    # -----------------------------------------------------------------------
    # PRE-STEP - Power Plan
    # Set the active power scheme to High Performance before the Power service
    # is disabled later in the Services section.
    # -----------------------------------------------------------------------
    Write-Log "--- Pre-step: Power Plan ---"
    try {
        # High Performance GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        & powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
        Write-Log "  [OK]   Power plan set to High Performance"
    }
    catch {
        Write-Log "  [WARN] Could not set power plan via powercfg - $_"
    }
    Write-Log ""

    # -----------------------------------------------------------------------
    # SECTION 1 - System Services: All VDI
    # These services provide no benefit in any VDI deployment model.
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 1: System Services (All VDI) ---"

        # Cellular Time - no cellular adapter in VMs
        Disable-VdiService -Name 'autotimesvc'      -DisplayName 'Cellular Time'
        # GameDVR and Broadcast user service (per-user template) - no game workloads
        Disable-VdiService -Name 'BcastDVRUserService' -DisplayName 'GameDVR and Broadcast User Service'
        # CaptureService (per-user template) - screen capture API, not needed in VDI
        Disable-VdiService -Name 'CaptureService'   -DisplayName 'Capture Service'
        # Connected Devices Platform - cross-device scenarios (phone, tablets) irrelevant
        Disable-VdiService -Name 'CDPSvc'           -DisplayName 'Connected Devices Platform Service'
        # CDP User Service (per-user template)
        Disable-VdiService -Name 'CDPUserSvc'       -DisplayName 'CDP User Service'
        # Diagnostic Execution Service
        Disable-VdiService -Name 'DiagSvc'          -DisplayName 'Diagnostic Execution Service'
        # Diagnostic Policy Service
        Disable-VdiService -Name 'DPS'              -DisplayName 'Diagnostic Policy Service'
        # Device Setup Manager - VDI environments control device software centrally
        Disable-VdiService -Name 'DsmSvc'           -DisplayName 'Device Setup Manager'
        # Data Usage Service - no metered network management needed
        Disable-VdiService -Name 'DusmSvc'          -DisplayName 'Data Usage Service'
        # Windows Mobile Hotspot Service - no mobile adapter in VMs
        Disable-VdiService -Name 'icssvc'           -DisplayName 'Windows Mobile Hotspot Service'
        # Geolocation Service
        Disable-VdiService -Name 'lfsvc'            -DisplayName 'Geolocation Service'
        # Downloaded Maps Manager
        Disable-VdiService -Name 'MapsBroker'       -DisplayName 'Downloaded Maps Manager'
        # MessagingService (per-user template) - SMS/MMS not used in enterprise VDI
        Disable-VdiService -Name 'MessagingService' -DisplayName 'Messaging Service'
        # Sync Host (per-user template) - UWP mail/calendar sync
        Disable-VdiService -Name 'OneSyncSvc'       -DisplayName 'Sync Host'
        # Contact Data (per-user template)
        Disable-VdiService -Name 'PimIndexMaintenanceSvc' -DisplayName 'Contact Data'
        # Power - VMs have no physical power management hardware
        Disable-VdiService -Name 'Power'            -DisplayName 'Power'
        # Payments and NFC/SE Manager - no NFC hardware in VMs
        Disable-VdiService -Name 'SEMgrSvc'         -DisplayName 'Payments and NFC/SE Manager'
        # SMS Router Service - no SMS infrastructure in enterprise VDI
        Disable-VdiService -Name 'SmsRouter'        -DisplayName 'Microsoft Windows SMS Router Service'
        # Diagnostic System Host - depends on DPS; disable both together
        Disable-VdiService -Name 'WdiSystemHost'    -DisplayName 'Diagnostic System Host'
        # Windows Error Reporting - reduce overhead; diagnostics done offline
        Disable-VdiService -Name 'WerSvc'           -DisplayName 'Windows Error Reporting'
        # Xbox Live Auth Manager
        Disable-VdiService -Name 'XblAuthManager'   -DisplayName 'Xbox Live Auth Manager'
        # Xbox Live Game Save
        Disable-VdiService -Name 'XblGameSave'      -DisplayName 'Xbox Live Game Save'
        # Xbox Accessory Management Service
        Disable-VdiService -Name 'XboxGipSvc'       -DisplayName 'Xbox Accessory Management Service'
        # Xbox Live Networking Service
        Disable-VdiService -Name 'XboxNetApiSvc'    -DisplayName 'Xbox Live Networking Service'

        # -- Windows Search (WSearch): intentionally NOT disabled --
        # The article lists WSearch with an explicit caution: "Disabling this service prevents
        # indexing of e-mail and other things. Test before disabling this service."
        # In this AVD deployment:
        #   - The OS disk and its search index persist for the full monthly VM lifecycle.
        #   - FSLogix stores the Outlook/Exchange search index inside the profile container
        #     (on Azure Files or Azure NetApp Files); the index survives VM replacement and
        #     re-attaches on next logon, preserving per-user mailbox search across sessions.
        # Disabling WSearch would break Outlook and File Explorer search for every user
        # for the entire month a VM is in service. WSearch is left at its default startup type.
        #
        # To disable for a special-purpose image (e.g., kiosk / task-worker) where users
        # never require search, uncomment:
        # Disable-VdiService -Name 'WSearch' -DisplayName 'Windows Search'

        Write-Log ""
    } # end if RunFullOptimization - Section 1

    # -----------------------------------------------------------------------
    # SECTION 2 - System Services: NonPersistent Only
    # These services either provide no carry-over value in an image-managed
    # deployment, or are superseded by image-level servicing processes.
    # -----------------------------------------------------------------------
    if ($RunNonPersistentSections) {
        Write-Log "--- Section 2: System Services (NonPersistent Only) ---"

        # Superfetch / SysMain - Azure managed disks are SSD-backed, so the
        # sequential-read benefit of prefetching is minimal. In pooled deployments
        # where multiple users may be assigned to the same VM over its lifecycle,
        # accumulated prefetch data reflects a mix of workloads and is less useful.
        Disable-VdiService -Name 'SysMain'          -DisplayName 'Superfetch (SysMain)'
        # Optimize Drives - Azure managed disks are SSD-backed; defragmenting
        # thin-provisioned virtual disks causes unnecessary IOPS and can expand
        # the disk footprint without improving performance.
        Disable-VdiService -Name 'defragsvc'        -DisplayName 'Optimize Drives'
        # Microsoft Store Install Service - app installs are managed through the
        # image build process, not via per-VM Store installs.
        Disable-VdiService -Name 'InstallService'   -DisplayName 'Microsoft Store Install Service'
        # Update Orchestrator - OS updates are applied during image servicing and
        # delivered via image replacement, not via per-VM Windows Update. Note:
        # Windows Defender signature updates use a separate update path (MpCmdRun)
        # and are not affected by disabling UsoSvc.
        Disable-VdiService -Name 'UsoSvc'           -DisplayName 'Update Orchestrator Service'
        # Volume Shadow Copy - AVD session host VMs are not typically backed up at
        # the VM level. User data resides in FSLogix profile containers on Azure
        # Files or Azure NetApp Files, which are backed up at the storage layer.
        # If VM-level backup (e.g., Azure Backup agent) is required, do not disable VSS.
        Disable-VdiService -Name 'VSS'              -DisplayName 'Volume Shadow Copy'
        # Windows Update service - left enabled on Persistent VMs so that SCCM/Intune
        # software update management remains functional.
        Disable-VdiService -Name 'wuauserv'         -DisplayName 'Windows Update'
        # Windows Update Medic - a protected SFC-guarded service that re-enables Windows
        # Update if it detects the service has been disabled. Set-Service is best-effort;
        # Disable-VdiService will fall back to the Start registry value automatically.
        Disable-VdiService -Name 'WaaSMedicSvc'     -DisplayName 'Windows Update Medic Service'
        # Connected User Experiences and Telemetry (DiagTrack) - on NonPersistent VMs
        # there is no Endpoint Analytics, Update Compliance, or per-VM diagnostic value.
        # On Persistent VMs this service must remain running for Intune Endpoint Analytics,
        # Windows Update for Business reports, and the diagnostic data processor config.
        Disable-VdiService -Name 'DiagTrack'        -DisplayName 'Connected User Experiences and Telemetry'
        # Microsoft Edge Update services - on NonPersistent VMs, Edge is updated via the
        # image. On Persistent VMs, SCCM/Intune manages Edge updates; leave services intact.
        Disable-VdiService -Name 'edgeupdate'       -DisplayName 'Microsoft Edge Update Service'
        Disable-VdiService -Name 'edgeupdatem'      -DisplayName 'Microsoft Edge Update Service (Manual Trigger)'

        Write-Log ""
    }

    # -----------------------------------------------------------------------
    # SECTION 3 - Scheduled Tasks: All VDI
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 3: Scheduled Tasks (All VDI) ---"

        $allVdiTasks = @(
            # Application Experience - telemetry data collection
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
            # Autochk - SQM data upload for CEIP
            @{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' },
            # Customer Experience Improvement Program
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask' },
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
            # Diagnosis - scheduled maintenance diagnostics
            @{ Path = '\Microsoft\Windows\Diagnosis\'; Name = 'Scheduled' },
            # Disk Diagnostic - reports disk/system info to Microsoft
            @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
            # DiskFootprint - storage I/O diagnostic collection
            @{ Path = '\Microsoft\Windows\DiskFootprint\'; Name = 'Diagnostics' },
            # Error Details
            @{ Path = '\Microsoft\Windows\ErrorDetails\'; Name = 'EnableErrorDetailsUpdate' },
            @{ Path = '\Microsoft\Windows\ErrorDetails\'; Name = 'ErrorDetailsUpdate' },
            # Feedback / SIUF - satisfaction survey prompts
            @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' },
            @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' },
            # File History
            @{ Path = '\Microsoft\Windows\FileHistory\'; Name = 'File History (maintenance mode)' },
            # Location notification balloon
            @{ Path = '\Microsoft\Windows\Location\'; Name = 'WindowsActionDialog' },
            # Maps toast and map data updates
            @{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsToastTask' },
            @{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsUpdateTask' },
            # Mobile PC
            @{ Path = '\Microsoft\Windows\MobilePC\'; Name = 'HotStart' },
            # Platform Instrumentation - TPM/Secure Boot telemetry
            @{ Path = '\Microsoft\Windows\PI\'; Name = 'Sqm-Tasks' },
            # Power Efficiency Diagnostics
            @{ Path = '\Microsoft\Windows\Power Efficiency Diagnostics\'; Name = 'AnalyzeSystem' },
            # Push To Install
            @{ Path = '\Microsoft\Windows\PushToInstall\'; Name = 'LoginCheck' },
            @{ Path = '\Microsoft\Windows\PushToInstall\'; Name = 'Registration' },
            # Family Safety monitoring
            @{ Path = '\Microsoft\Windows\Shell\'; Name = 'FamilySafetyMonitor' },
            @{ Path = '\Microsoft\Windows\Shell\'; Name = 'FamilySafetyRefreshTask' },
            # Storage Spaces
            @{ Path = '\Microsoft\Windows\SpacePort\'; Name = 'SpaceAgentTask' },
            @{ Path = '\Microsoft\Windows\SpacePort\'; Name = 'SpaceManagerTask' },
            # Speech model download
            @{ Path = '\Microsoft\Windows\Speech\'; Name = 'SpeechModelDownloadTask' },
            # Update Orchestrator reporting
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Report policies' },
            # Startup app notification
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'StartupAppTask' },
            # Diagnostics - WDI resolution host
            @{ Path = '\Microsoft\Windows\WDI\'; Name = 'ResolutionHost' },
            # Windows Error Reporting queued reports
            @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting' },
            # Windows Update scheduled trigger
            @{ Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'Scheduled Start' },
            # WLAN CDSSynchronization
            @{ Path = '\Microsoft\Windows\WlanSvc\'; Name = 'CDSSync' },
            # WOF hash management
            @{ Path = '\Microsoft\Windows\WOF\'; Name = 'WIM-Hash-Management' },
            @{ Path = '\Microsoft\Windows\WOF\'; Name = 'WIM-Hash-Validation' },
            # Xbox Game Save
            @{ Path = '\Microsoft\XblGameSave\'; Name = 'XblGameSaveTask' },
            @{ Path = '\Microsoft\XblGameSave\'; Name = 'XblGameSaveTaskLogon' }
        )

        foreach ($task in $allVdiTasks) {
            Disable-VdiTask -TaskPath $task.Path -TaskName $task.Name
        }

        # -- Tasks from the article intentionally NOT disabled (All VDI) --
        #
        # RegIdleBackup (\Microsoft\Windows\Registry\RegIdleBackup):
        #   The article lists this task. However, registry hives are fully persisted
        #   on disk across reboots for the VM's monthly lifecycle. Registry backups
        #   enable in-place recovery from hive corruption without a full VM redeploy.
        #   Disabling would remove a useful safety net for mid-lifecycle recovery.
        #   To disable: Disable-VdiTask -TaskPath '\Microsoft\Windows\Registry\' -TaskName 'RegIdleBackup'
        #
        # SilentCleanup (\Microsoft\Windows\DiskCleanup\SilentCleanup):
        #   The article lists this task. SilentCleanup only triggers when disk space
        #   falls below ~5 GB (via Automatic Maintenance) and provides ongoing hygiene
        #   over the VM's monthly operational lifecycle. The image-build cleanup script
        #   handles build-time cleanup; this task handles post-deployment operational cleanup.
        #   To disable: Disable-VdiTask -TaskPath '\Microsoft\Windows\DiskCleanup\' -TaskName 'SilentCleanup'

        Write-Log ""
    } # end if RunFullOptimization - Section 3

    # -----------------------------------------------------------------------
    # SECTION 4 - Scheduled Tasks: NonPersistent Only
    # These tasks serve no purpose in an image-managed deployment, or their
    # function is better handled at the image-build stage.
    # -----------------------------------------------------------------------
    if ($RunNonPersistentSections) {
        Write-Log "--- Section 4: Scheduled Tasks (NonPersistent Only) ---"

        $nonPersistentTasks = @(
            # Disk defragmentation - no benefit on Azure SSD-backed managed disks;
            # defragging thin-provisioned virtual disks expands disk footprint.
            @{ Path = '\Microsoft\Windows\Defrag\'; Name = 'ScheduledDefrag' },
            # WinSAT - performance benchmark scores on Azure VMs vary with host load
            # and are not representative or actionable.
            @{ Path = '\Microsoft\Windows\Maintenance\'; Name = 'WinSAT' },
            # Memory diagnostics - memory hardware is managed at the hypervisor
            # and Azure platform layer; guest-level memory diagnostics produce no
            # actionable information for VM workloads.
            @{ Path = '\Microsoft\Windows\MemoryDiagnostic\'; Name = 'ProcessMemoryDiagnosticEvents' },
            @{ Path = '\Microsoft\Windows\MemoryDiagnostic\'; Name = 'RunFullMemoryDiagnostic' },
            # StartComponentCleanup - CBS component cleanup should run during
            # image build/maintenance windows, not on production VMs.
            @{ Path = '\Microsoft\Windows\Servicing\'; Name = 'StartComponentCleanup' },
            # System Restore - already hard-disabled via policy in Section 5;
            # disabling the task here is redundant but explicit.
            @{ Path = '\Microsoft\Windows\SystemRestore\'; Name = 'SR' },
            # Windows Update scans - OS updates are delivered via image replacement;
            # scanning for updates on individual VMs is unnecessary.
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan' },
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan Static Task' },
            @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'USO_UxBroker' }
        )

        foreach ($task in $nonPersistentTasks) {
            Disable-VdiTask -TaskPath $task.Path -TaskName $task.Name
        }

        # Update channel tasks: path-agnostic disables. Task paths vary by install
        # location or include per-user SIDs, so these are found by name only.
        # On Persistent VMs, SCCM/Intune manages these update channels; leave intact.
        Write-Log "  Disabling update channel scheduled tasks (NonPersistent)..."

        # Microsoft 365 / Office Click-to-Run automatic updates
        $officeUpdateTask = Get-ScheduledTask -TaskName 'Office Automatic Updates 2.0' `
            -ErrorAction SilentlyContinue
        if ($officeUpdateTask) {
            Disable-ScheduledTask -TaskPath $officeUpdateTask.TaskPath `
                -TaskName $officeUpdateTask.TaskName `
                -ErrorAction SilentlyContinue | Out-Null
            Write-Log "  [OK]   Disabled task: $($officeUpdateTask.TaskPath)$($officeUpdateTask.TaskName)"
        }
        else { Write-Log '  [SKIP] Task not found: Office Automatic Updates 2.0' }

        # OneDrive standalone update tasks - names include per-user SIDs; matched by wildcard
        foreach ($pattern in @('OneDrive Reporting Task-S-*', 'OneDrive Standalone Update Task-S-*')) {
            Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName `
                    -ErrorAction SilentlyContinue | Out-Null
                Write-Log "  [OK]   Disabled task: $($_.TaskPath)$($_.TaskName)"
            }
        }

        # Microsoft Edge / WebView2 update tasks (registered by EdgeUpdate installer;
        # path is not a fixed known value across all Windows versions)
        foreach ($edgeTaskName in @('MicrosoftEdgeUpdateTaskMachineCore', 'MicrosoftEdgeUpdateTaskMachineUA')) {
            $edgeUpdateTask = Get-ScheduledTask -TaskName $edgeTaskName -ErrorAction SilentlyContinue
            if ($edgeUpdateTask) {
                Disable-ScheduledTask -TaskPath $edgeUpdateTask.TaskPath `
                    -TaskName $edgeUpdateTask.TaskName `
                    -ErrorAction SilentlyContinue | Out-Null
                Write-Log "  [OK]   Disabled task: $($edgeUpdateTask.TaskPath)$($edgeUpdateTask.TaskName)"
            }
            else { Write-Log "  [SKIP] Task not found: $edgeTaskName" }
        }

        # Microsoft Store / InstallService update tasks
        $storeUpdateTasks = @(
            @{ Path = '\Microsoft\Windows\InstallService\'; Name = 'ScanForUpdates' },
            @{ Path = '\Microsoft\Windows\InstallService\'; Name = 'ScanForUpdatesAsUser' },
            @{ Path = '\Microsoft\Windows\InstallService\'; Name = 'SmartRetry' }
        )
        foreach ($entry in $storeUpdateTasks) {
            Disable-VdiTask -TaskPath $entry.Path -TaskName $entry.Name
        }

        Write-Log ""
    }

    # -----------------------------------------------------------------------
    # SECTION 5 - Registry / Policy Settings: All VDI
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 5: Registry / Policy Settings (All VDI) ---"

        # -- Telemetry (AT: Computer Configuration > Windows Components > Data Collection and Preview Builds) --
        # AllowTelemetry = 1 (Required/Basic) is the minimum for all VDI types:
        #   - Persistent VMs managed by Intune require >= 1 for Endpoint Analytics,
        #     Windows Update for Business reports, Update Compliance, and the
        #     Windows diagnostic data processor configuration (GDPR controller mode).
        #   - Microsoft explicitly warns that AllowTelemetry = 0 prevents Windows Update
        #     failure information from being sent, which breaks update diagnostics.
        # NonPersistent VMs override this to 0 in Section 6 since transient VMs have
        # no per-VM diagnostic reporting value.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'AllowTelemetry' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'DoNotShowFeedbackNotifications' -Value 1

        # -- Windows Error Reporting (AT: Computer Configuration > Windows Components > Windows Error Reporting) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' `
            -Name 'Disabled' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' `
            -Name 'DontSendAdditionalData' -Value 1

        # -- Privacy / Consumer Experiences --
        # AT: Computer Configuration > Windows Components > Cloud Content
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableWindowsConsumerFeatures' -Value 1
        # DisableSoftLanding: suppresses the "Windows Tips" feature (Consumer Experiences > Do not show Windows tips).
        # This is the correct ADMX-defined value name; DisableWindowsTips has no ADMX definition and is omitted.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableSoftLanding' -Value 1
        # NOTE: DisableThirdPartySuggestions and DisableWindowsSpotlightFeatures are defined by CloudContent.admx
        # as User Configuration policies only (HKCU). They are applied correctly in Section 8 via the default
        # user hive. Writing them at HKLM is not honored as a Computer Configuration GP setting.
        # AT: Computer Configuration > System > OS Policies
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnableCdp' -Value 0

        # -- Advertising ID (AT: Computer Configuration > System > User Profiles) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' `
            -Name 'DisabledByGroupPolicy' -Value 1

        # -- App Privacy (AT: Computer Configuration > Windows Components > App Privacy) --
        # Values: 0 = User in control, 1 = Force allow, 2 = Force deny
        $appPrivacyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessDiagnosticInfo'    -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessLocation'          -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessMotion'            -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessNotifications'     -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsActivateWithVoice'       -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsActivateWithVoiceAboveLock' -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessRadios'            -Value 2
        Set-PolicyValue -Path $appPrivacyPath -Name 'LetAppsAccessCellularData'      -Value 2

        # -- Input Personalization and Inking / Typing data collection --
        # AllowInputPersonalization=0 disables speech recognition services machine-wide
        # and suppresses Windows learning from inking and typing input. Users cannot
        # re-enable it in Settings. This policy covers all four per-user preferences:
        # RestrictImplicitInkCollection, RestrictImplicitTextCollection,
        # AcceptedPrivacyPolicy, and HarvestContacts.
        # AT: Computer Configuration > Control Panel > Regional and Language Options
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' `
            -Name 'AllowInputPersonalization' -Value 0
        # AllowLinguisticDataCollection=0 stops sending inking/typing data to Microsoft
        # to improve language recognition (telemetry, separate from the personalization
        # feature above).
        # AT: Computer Configuration > Windows Components > Text Input
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput' `
            -Name 'AllowLinguisticDataCollection' -Value 0

        # -- Location and Sensors (AT: Computer Configuration > Windows Components > Location and Sensors) --
        $locationPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
        Set-PolicyValue -Path $locationPath -Name 'DisableLocation'               -Value 1
        Set-PolicyValue -Path $locationPath -Name 'DisableSensors'                -Value 1
        Set-PolicyValue -Path $locationPath -Name 'DisableWindowsLocationProvider' -Value 1

        # -- Search and Cortana (AT: Computer Configuration > Windows Components > Search) --
        $searchPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
        Set-PolicyValue -Path $searchPath -Name 'AllowCortana'                    -Value 0
        Set-PolicyValue -Path $searchPath -Name 'AllowCortanaAboveLock'           -Value 0
        Set-PolicyValue -Path $searchPath -Name 'AllowSearchToUseLocation'        -Value 0
        Set-PolicyValue -Path $searchPath -Name 'DisableWebSearch'                -Value 1
        Set-PolicyValue -Path $searchPath -Name 'ConnectedSearchUseWeb'           -Value 0
        Set-PolicyValue -Path $searchPath -Name 'PreventIndexingEmailAttachments' -Value 1
        Set-PolicyValue -Path $searchPath -Name 'PreventIndexingOfflineFiles'     -Value 1

        # -- BITS peer caching (AT: Computer Configuration > Network > Background Intelligent Transfer Service (BITS)) --
        $bitsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS'
        Set-PolicyValue -Path $bitsPath -Name 'EnablePeercaching'          -Value 0
        Set-PolicyValue -Path $bitsPath -Name 'DisableBranchCache'         -Value 1
        Set-PolicyValue -Path $bitsPath -Name 'DisablePeerCachingClient'   -Value 1
        Set-PolicyValue -Path $bitsPath -Name 'DisablePeerCachingServer'   -Value 1

        # -- BranchCache service-level disable (AT: Computer Configuration > Network > BranchCache) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\PeerDist\Service' `
            -Name 'Enable' -Value 0

        # -- Delivery Optimization (AT: Computer Configuration > Windows Components > Delivery Optimization) --
        # 99 = Simple download mode; no contact with Delivery Optimization cloud services
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' `
            -Name 'DODownloadMode' -Value 99

        # -- Maps (AT: Computer Configuration > Windows Components > Maps) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps' `
            -Name 'AutoDownloadAndUpdateMapData' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps' `
            -Name 'AllowUnsolicitedNetworkTrafficOnSettingsPage' -Value 0

        # -- Messaging (AT: Computer Configuration > Windows Components > Messaging) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Messaging' `
            -Name 'AllowMessageSync' -Value 0

        # -- Offline Files (AT: Computer Configuration > Network > Offline Files) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache' `
            -Name 'Enabled' -Value 0

        # -- Desktop Window Manager animations (AT: Computer Configuration > Windows Components > Desktop Window Manager) --
        # NOTE: WiFiSenseCredShared and WiFiSenseOpen were removed -- they have no ADMX backing and
        # the WiFiSense feature was deprecated in Windows 10 1803. The correct GP policy for WiFi
        # auto-connect writes to a different key (wcmsvc\wifinetworkmanager\config\AutoConnectAllowedOEM).
        # NOTE: UseSolidColorForStart was removed -- it has no definition in DWM.admx or any other
        # built-in ADMX. DWM.admx defines only: DisallowAnimations, DisallowColorizationColorChanges,
        # DefaultColorizationColorState.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DWM' `
            -Name 'DisallowAnimations' -Value 1

        # -- Microsoft Edge: disable preloading and background activity (AT: Computer Configuration > Microsoft Edge) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled'  -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -Value 0

        # -- OneDrive: suppress network traffic until user signs in --
        # DISABLED: PreventNetworkTrafficPreUserSignIn blocks OneDrive Known Folder Move (KFM)
        # and silent automatic sign-in from completing at logon. With KFM deployed, OneDrive
        # must be able to communicate before user sign-in to redirect Desktop/Documents/Pictures.
        # Leaving this unset (or explicitly 0) is required for KFM and silent sign-in to work.
        # Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' `
        #              -Name 'PreventNetworkTrafficPreUserSignIn' -Value 1

        # -- Windows Ink Workspace (AT: Computer Configuration > Windows Components > Windows Ink Workspace) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' `
            -Name 'AllowWindowsInkWorkspace' -Value 0

        # -- Windows Game DVR / Recording (AT: Computer Configuration > Windows Components > Windows Game Recording and Broadcasting) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' `
            -Name 'AllowGameDVR' -Value 0

        # -- Speech model auto-update (AT: Computer Configuration > Windows Components > Speech) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Speech' `
            -Name 'AllowSpeechModelUpdate' -Value 0

        # -- Microsoft Store: suppress OS upgrade offers (AT: Computer Configuration > Windows Components > Store) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' `
            -Name 'DisableOSUpgrade' -Value 1

        # -- OOBE: skip privacy settings experience at first logon (AT: Computer Configuration > Windows Components > OOBE) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' `
            -Name 'DisablePrivacyExperience' -Value 1

        # -- Logon screen (AT: Computer Configuration > System > Logon) --
        # "Show first sign-in animation" = Disabled: suppresses the welcome animation
        # and the Microsoft account opt-in prompt on first logon.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
            -Name 'EnableFirstLogonAnimation' -Value 0
        # "Show clear logon background" = Enabled: removes the acrylic blur overlay on the
        # logon background image so it renders clearly. Reduces compositing work and
        # bandwidth when the image is delivered over a remoting protocol.
        # (Different from DisableLogonBackgroundImage, which hides the image entirely.)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'DisableAcrylicBackgroundOnLogon' -Value 1

        # -- Search index (AT: Computer Configuration > Windows Components > Search) --
        # StopIndexingOnLimitedHardDriveSpace prevents the index from consuming
        # remaining disk capacity when space is low (threshold: ~5 GB).
        # Disabling encrypted item indexing reduces indexing overhead.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
            -Name 'StopIndexingOnLimitedHardDriveSpace' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
            -Name 'AllowIndexingEncryptedStoresOrItems' -Value 0

        # -- NTFS: disable short (8.3) file name creation on all volumes --
        Set-PolicyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
            -Name 'NtfsDisable8dot3NameCreation' -Value 1

        # -- AutoPlay (AT: Computer Configuration > Windows Components > AutoPlay Policies) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Name 'NoDriveTypeAutoRun' -Value 255
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'NoAutorun' -Value 1

        # -- Application Compatibility: Inventory Collector (AT: Computer Configuration > Windows Components > Application Compatibility) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' `
            -Name 'DisableInventory' -Value 1

        # -- File Explorer: thumbnail caching (AT: Computer Configuration > Windows Components > File Explorer) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'DisableThumbsDBOnNetworkFolders' -Value 1

        # -- File History (AT: Computer Configuration > Windows Components > File History) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\FileHistory' `
            -Name 'Disabled' -Value 1

        # -- Find My Device (AT: Computer Configuration > Windows Components > Find My Device) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' `
            -Name 'AllowFindMyDevice' -Value 0

        # -- HomeGroup (AT: Computer Configuration > Windows Components > HomeGroup) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HomeGroup' `
            -Name 'DisableHomeGroup' -Value 1

        # -- RSS Feeds: disable background sync (AT: Computer Configuration > Windows Components > RSS Feeds) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Feeds' `
            -Name 'BackgroundSyncStatus' -Value 0

        # -- Storage Health (AT: Computer Configuration > System > Storage Health) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageHealth' `
            -Name 'AllowDiskHealthModelUpdates' -Value 0

        # -- Storage Sense --
        # DELIBERATE DEVIATION FROM VDI ARTICLE: The article recommends disabling
        # Storage Sense. This script ENABLES and configures it via ADMX-backed
        # Computer Configuration policy (Software\Policies\Microsoft\Windows\StorageSense),
        # available since Windows 10 1903.
        #
        # Rationale: In FSLogix profile container deployments, OneDrive Files On-Demand
        # caches locally accessed files inside the FSLogix VHD/VHDX container stored on
        # Azure Files or Azure NetApp Files. Without proactive dehydration the container
        # grows monotonically -- every file opened stays cached and is never returned to
        # online-only status. Over weeks or months this:
        #   1. Increases container size (Azure Files / ANF storage costs)
        #   2. Increases FSLogix attach time at each logon (larger VHD to mount/diff)
        #   3. Can hit per-container size caps if configured
        # Storage Sense "dehydrate cloud content not accessed in X days" directly solves
        # this by making OneDrive files that haven't been opened in 30+ days online-only
        # again, keeping the container lean. This benefit applies equally to NonPersistent
        # and Persistent VMs because the container (not the OS disk) accumulates.
        # Ref: [4] https://learn.microsoft.com/en-us/fslogix/tutorial-container-onedrive
        # Ref: https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image
        # Ref: https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-storage
        #
        # Policy key: Software\Policies\Microsoft\Windows\StorageSense
        # AT: Computer Configuration > Windows Components > Storage Sense
        # When AllowStorageSenseGlobal = 1 (Enabled), Storage Sense is forced on and
        # users cannot disable it. The remaining policies configure its behavior.
        # Note: ConfigStorageSenseCloudContentDehydrationThreshold > 0 implicitly enables
        # cloud content dehydration; there is no separate "include OneDrive" policy value.
        $ssPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
        Set-PolicyValue -Path $ssPolicyPath -Name 'AllowStorageSenseGlobal'                          -Value 1  # force Storage Sense on
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseGlobalCadence'                  -Value 30 # run monthly
        Set-PolicyValue -Path $ssPolicyPath -Name 'AllowStorageSenseTemporaryFilesCleanup'           -Value 1  # delete unused temp files
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseRecycleBinCleanupThreshold'     -Value 0  # never auto-clean Recycle Bin
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseDownloadsCleanupThreshold'      -Value 0  # never auto-clean Downloads
        Set-PolicyValue -Path $ssPolicyPath -Name 'ConfigStorageSenseCloudContentDehydrationThreshold' -Value 30 # dehydrate cloud files not opened in 30 days

        # -- System Restore (AT: Computer Configuration > System > System Restore) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' `
            -Name 'DisableSR' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' `
            -Name 'DisableConfig' -Value 1

        # -- Toast / push notifications (AT: Computer Configuration > Windows Components > Push Notifications) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' `
            -Name 'NoCloudApplicationNotification' -Value 1

        # -- Windows Mobility Center (AT: Computer Configuration > Windows Components > Windows Mobility Center) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\MobilityCenter' `
            -Name 'NoMobilityCenter' -Value 1

        # -- Windows Installer (AT: Computer Configuration > Windows Components > Windows Installer) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' `
            -Name 'MaxPatchCacheSize' -Value 5
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' `
            -Name 'LimitSystemRestoreCheckpointing' -Value 1

        # -- Windows Reliability Analysis (AT: Computer Configuration > System > Troubleshooting and Diagnostics > Windows Performance) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Reliability Analysis\WMI' `
            -Name 'WMIEnable' -Value 0

        # -- Windows Security: suppress non-critical notifications (AT: Computer Configuration > Windows Components > Windows Security > Notifications) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' `
            -Name 'DisableEnhancedNotifications' -Value 1

        # -- Windows Update (AT: Computer Configuration > Windows Components > Windows Update) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -Name 'EnableFeaturedSoftware' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -Name 'ManagePreviewBuilds' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -Name 'ManagePreviewBuildsPolicyValue' -Value 0

        # -- Event Viewer (AT: Computer Configuration > Windows Components > Event Viewer) --
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EventViewer' `
            -Name 'MicrosoftEventVwrDisableLinks' -Value 1

        # -- Handwriting --
        # AT: Computer Configuration > Windows Components > Handwriting Error Reporting
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports' `
            -Name 'PreventHandwritingErrorReports' -Value 1
        # AT: Computer Configuration > Windows Components > Tablet PC > Handwriting Personalization
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC' `
            -Name 'PreventHandwritingDataSharing' -Value 1

        # -- Cloud content: block silently pushed pre-installed UWP app refreshes (AT: Computer Configuration > Windows Components > Cloud Content) --
        # DisableCloudOptimizedContent prevents Microsoft from silently re-pushing removed or
        # refreshed pre-installed apps via cloud content delivery. This applies regardless of
        # persistence model because no VDI deployment should have uncontrolled app installs.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Name 'DisableCloudOptimizedContent' -Value 1

        # -- Software Protection Platform: disable KMS Client Online AVS Validation --
        # Prevents the device from sending activation state data to Microsoft's online
        # Anti-Piracy Validation Service. Enterprise VDI uses on-premises KMS infrastructure.
        # AT: Computer Configuration > Windows Components > Software Protection Platform
        # Ref: Article local policy table - Software Protection Platform
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Software Protection Platform' `
            -Name 'NoGenTicket' -Value 1

        # -- Control Panel: disable online tips (AT: Computer Configuration > Control Panel) --
        # Prevents the Settings app from contacting Microsoft content services to fetch tips.
        # Ref: Article local policy table - Control Panel
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' `
            -Name 'AllowOnlineTips' -Value 0

        # -- Device Installation (AT: Computer Configuration > System > Device Installation) --
        # Ref: Article local policy table - Device Installation
        # Don't send a Windows Error Report when a generic driver is installed on a device
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' `
            -Name 'DisableSendGenericDriverNotFoundToWER' -Value 1
        # Prevent System Restore point creation during device installation activity
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' `
            -Name 'DisableSystemRestore' -Value 1
        # Turn off "Found New Hardware" balloon notifications during device installation
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' `
            -Name 'DisableBalloonTips' -Value 1
        # Prevent device metadata retrieval from the Internet
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' `
            -Name 'PreventDeviceMetadataFromNetwork' -Value 1
        # Don't search Windows Update for device drivers; drivers must come from the image
        # or enterprise management (SCCM/Intune/WSUS) to ensure consistent, tested versions.
        # AT: Computer Configuration > System > Device Installation > Device Driver Installation
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' `
            -Name 'DontSearchWindowsUpdate' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' `
            -Name 'SearchOrderConfig' -Value 0

        # -- Edge UI (AT: Computer Configuration > Windows Components > Edge UI) --
        # Ref: Article local policy table - Edge UI
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI' `
            -Name 'AllowEdgeSwipe' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI' `
            -Name 'DisableHelpSticker' -Value 1

        # -- File Explorer: suppress "new application installed" association balloon (AT: Computer Configuration > Windows Components > File Explorer) --
        # Ref: Article local policy table - File Explorer
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'NoNewAppAlert' -Value 1

        # -- Internet Communication Management (AT: Computer Configuration > Windows Components > Internet Communication Management > Internet Communication settings) --
        # Disables Windows shell components that make outbound calls to Microsoft web services.
        # Ref: Article local policy table - Internet Communication Management
        # Turn off Internet download for Web publishing and online ordering wizards
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'NoPublishingWizard' -Value 1
        # Turn off Internet file association service (opening unknown file types via Microsoft lookup)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'NoInternetOpenWith' -Value 1
        # Turn off "Order Prints Online" picture task
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' `
            -Name 'NoOnlinePrintsWizard' -Value 1
        # Turn off Windows Customer Experience Improvement Program (AT: Computer Configuration > Windows Components > Windows Customer Experience Improvement Program)
        # (belt-and-suspenders: AllowTelemetry in Section 5 and the Consolidator/UsbCeip
        #  tasks in Section 3 already suppress CEIP data collection)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' `
            -Name 'CEIPEnable' -Value 0

        # -- Logon (AT: Computer Configuration > System > Logon) --
        # Ref: Article local policy table - Logon
        # Don't enumerate connected users on domain-joined computers at the logon screen
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'DontEnumerateConnectedUsers' -Value 1
        # Don't enumerate local users on domain-joined computers at the logon screen
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnumerateLocalUsers' -Value 0
        # Turn off app notifications on the lock screen
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'DisableLockScreenAppNotifications' -Value 1

        # -- Peer-to-Peer networking (AT: Computer Configuration > Network > Microsoft Peer-to-Peer Networking Services) --
        # P2P networking provides no value in a managed VDI environment.
        # Ref: Article local policy table - Microsoft Peer-to-Peer Networking Services
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Peernet' `
            -Name 'Disabled' -Value 1

        # -- Online Assistance (AT: Computer Configuration > System > Internet Communication Management > Internet Communication settings) --
        # Prevents the help system from fetching online content or transmitting implicit feedback.
        # Ref: Article local policy table - Online Assistance
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Assistance\Client\1.0' `
            -Name 'NoOnlineAssist' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Assistance\Client\1.0' `
            -Name 'NoImplicitFeedback' -Value 1

        # -- Troubleshooting and Diagnostics (AT: Computer Configuration > System > Troubleshooting and Diagnostics) --
        # NOTE: DPS (Diagnostic Policy Service) is disabled in Section 1, which makes
        # all Windows diagnostic scenario execution non-functional regardless of these
        # policy settings. These policies are applied per article guidance for completeness
        # and to ensure the behavior is also enforced if DPS is ever re-enabled.
        # Ref: Article local policy table - Troubleshooting and Diagnostics
        # Disable Scheduled Maintenance automatic troubleshooting behavior
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics' `
            -Name 'EnabledExecution' -Value 0
        # Prevent users from launching troubleshooting wizards from Control Panel
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScriptedDiagnostics' `
            -Name 'EnableDiagnostics' -Value 0
        # Prevent users from accessing online troubleshooting content (Windows Online Troubleshooting Service)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScriptedDiagnosticsProvider\Policy' `
            -Name 'DisableQueryRemoteServer' -Value 1
        # NOTE: The article also lists per-scenario "Configure Scenario Execution Level = Disabled"
        # for Windows Boot, Shutdown, Memory, Standby/Resume, Resource Exhaustion, Responsiveness,
        # and PerfTrack performance diagnostics. Each scenario uses a GUID-keyed registry subkey:
        #   HKLM:\SOFTWARE\Policies\Microsoft\Windows\WDI\{<scenario-guid>}\ScenarioExecutionEnabled = 0
        # Since DPS is disabled in Section 1, all diagnostic scenarios are non-functional regardless.
        # Per-scenario policies are intentionally omitted here to avoid maintaining GUID-to-scenario
        # mappings across Windows versions. If DPS is re-enabled, add the relevant GUIDs manually.

        Invoke-ApplyPolicyQueue
        Write-Log ""
    } # end if RunFullOptimization - Section 5

    # -----------------------------------------------------------------------
    # SECTION 6 - Registry / Policy Settings: NonPersistent Only
    # -----------------------------------------------------------------------
    if ($RunNonPersistentSections) {
        Write-Log "--- Section 6: Registry / Policy Settings (NonPersistent Only) ---"

        # Override telemetry to Security/Off for NonPersistent VMs. These are transient;
        # Endpoint Analytics, Update Compliance, and per-VM diagnostic reports have no
        # value when the VM will be replaced with a new image on a regular basis.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Name 'AllowTelemetry' -Value 0

        # Disable Windows Update scan/install. OS updates are applied during image
        # servicing and delivered via image replacement, not per-VM Windows Update.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
            -Name 'NoAutoUpdate' -Value 1
        # AUOptions = 1 (Never check for updates) - belt-and-suspenders with NoAutoUpdate
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
            -Name 'AUOptions' -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -Name 'DisableWindowsUpdateAccess' -Value 1

        # -- Update channel lockdown: application-level (NonPersistent Only) --
        # On Persistent VMs, SCCM or Intune manages these update channels directly.
        # Disabling them here would remove the management tool's ability to patch apps.
        # On NonPersistent VMs, every update is delivered via the next image replacement.

        # Microsoft 365 / Office Click-to-Run
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' `
            -Name 'enableautomaticupdates'   -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' `
            -Name 'hideupdatenotifications'  -Value 1
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' `
            -Name 'hideenabledisableupdates' -Value 1

        # Microsoft Teams for VDI: disable automatic client updates
        # Ref: https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy#disable-teams-autoupdate-in-non-persistent-vdi
        # disableAutoUpdate = 1 prevents the Teams MSIX bootstrapper from self-updating.
        # Teams is updated via image replacement on the next build cycle.
        # NOTE: This is a vendor-defined registry key (not ADMX-backed). It writes to
        # SOFTWARE\Microsoft\Teams (outside the Policies hive) and is read directly by the Teams client.
        # Requires Teams build 23306.3314.2555.9628 or higher.
        # IMPORTANT: When this key is present, the Teams bootstrapper will NOT automatically install or
        # upgrade the Teams Meeting Add-in (TMA). TMA must be deployed separately at image build time
        # via 'teamsbootstrapper.exe --installTMA' or by running MicrosoftTeamsMeetingAddinInstaller.msi
        # from the Teams install directory (C:\Program Files\WindowsApps\MSTeams_*).
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Microsoft\Teams' `
            -Name 'disableAutoUpdate' -Value 1

        # OneDrive: block automatic updates entirely (image provides the pinned version)
        # Ref: https://learn.microsoft.com/en-us/sharepoint/use-group-policy#set-the-sync-app-update-ring
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' `
            -Name 'GPOSetUpdateRing' -Value 0

        # Microsoft Edge (Chromium): block automatic updates via EdgeUpdate service policy
        # UpdateDefault = 0 blocks all app updates globally via the EdgeUpdate service
        # GUID {56EB18F8...} = Edge Stable Channel app-specific override
        # Ref: https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
            -Name 'UpdateDefault' -Value 0
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
            -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -Value 0

        # WebView2 Runtime: block automatic updates via EdgeUpdate policy
        # GUID {F3017226...} = WebView2 Runtime app-specific entry
        # Ref: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/enterprise
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
            -Name 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Value 0

        # Microsoft Store: disable automatic app download and update
        # 2 = AutoDownload disabled; app installs are managed through the image
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' `
            -Name 'AutoDownload' -Value 2

        # Disable file layout auto-optimization. The OptimalLayout service rearranges
        # files on disk to improve sequential read performance. On Azure SSD-backed
        # managed disks, random I/O is nearly as fast as sequential I/O, making
        # this optimization marginal at best.
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OptimalLayout' `
            -Name 'EnableAutoLayout' -Value 0

        # Disable Prefetcher and Superfetch via Session Manager parameters.
        # Although prefetch data does persist across reboots within the monthly VM
        # lifecycle, two factors reduce its effectiveness here:
        #   1. Azure managed disks are SSD-backed; random I/O speed is close to
        #      sequential, so prefetching provides minimal latency improvement.
        #   2. In pooled deployments, VMs may serve multiple users over their
        #      lifecycle; accumulated prefetch data reflects mixed workload patterns
        #      and benefits no individual user's session.
        # This complements disabling the SysMain service in Section 2.
        $prefetchPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
        Set-PolicyValue -Path $prefetchPath -Name 'EnablePrefetcher'  -Value 0
        Set-PolicyValue -Path $prefetchPath -Name 'EnableSuperfetch'  -Value 0

        Invoke-ApplyPolicyQueue
        Write-Log ""
    }

    # -----------------------------------------------------------------------
    # SECTION 7 - Restricted Internet Traffic Settings
    # Applied when -RestrictInternet is true. Reduces outbound network traffic
    # for air-gapped or proxy-only environments. Applies to all profiles,
    # including None.
    # Ref: [2] Windows Restricted Traffic Baseline
    # -----------------------------------------------------------------------
    if ($RestrictInternetBool) {
        Write-Log "--- Section 7: Restricted Internet Traffic ---"

        # NCSI passive polling
        # DISABLED: DisablePassivePolling causes Windows to stop probing network state, which
        # makes the OS report "Unidentified Network / No Internet Access" even when the network
        # is fully functional. Applications using Windows Network Awareness APIs (WinHTTP,
        # WinINet, Outlook, proxy auto-detection) may behave as if offline, blocking
        # authentication flows, Exchange connectivity, and WPAD discovery. The CPU overhead
        # from passive polling in a static VDI network is negligible compared to the breakage.
        # Ref: Article local policy table - Network Connectivity Status Indicator (Restricted Traffic baseline)
        # Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator' `
        #              -Name 'DisablePassivePolling' -Value 1

        # Online font providers - Windows contacts Microsoft's online font service when
        # rendering text with fonts not installed locally. Disable to prevent outbound calls.
        # Ref: Article local policy table - Fonts (Restricted Traffic baseline)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Name 'EnableFontProviders' -Value 0

        # Teredo IPv6 transition technology - tunnels IPv6 traffic over IPv4 UDP for
        # NAT traversal. Has no purpose in a VDI environment with no internet-facing IPv6 need.
        # Ref: Article local policy table - TCPIP Settings / IPv6 Transition Technologies (Restricted Traffic baseline)
        Set-PolicyValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition' `
            -Name 'Teredo_State' -Value 'Disabled' `
            -Type ([Microsoft.Win32.RegistryValueKind]::String)

        # WiFi autologgers - no Wi-Fi hardware in VMs; these traces serve no purpose
        # in restricted environments. Included here so they apply even when
        # -OptimizationProfile is None.
        Disable-VdiAutologger -Name 'WiFiSession'
        Disable-VdiAutologger -Name 'WinPhoneCritical'

        Invoke-ApplyPolicyQueue
        Write-Log ""
    } # end if RestrictInternet - Section 7

    # -----------------------------------------------------------------------
    # SECTION 8 - Default User Profile Settings
    # Applied to C:\Users\Default\NTUSER.DAT so that every new user session
    # created from this image inherits the performance and privacy settings.
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 8: Default User Profile Settings ---"

        $defaultHivePath = 'C:\Users\Default\NTUSER.DAT'
        $hiveMounted = $false

        if (Test-Path $defaultHivePath) {
            try {
                # Load the default user hive under a temporary HKLM key
                $loadResult = & reg.exe load 'HKLM\TempDefaultUser' $defaultHivePath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "reg.exe load returned exit code $LASTEXITCODE - $loadResult"
                }
                $hiveMounted = $true
                Write-Log "  Default user hive mounted at HKLM:\TempDefaultUser"

                $du = 'HKLM:\TempDefaultUser'

                # -- Visual effects: Custom (performance-oriented) --
                # VisualFXSetting 3 = Custom; specific items controlled via Advanced keys
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" `
                    -Name 'VisualFXSetting' -Value 3

                # ShellState binary - suppress animations in Explorer shell
                $shellState = [byte[]](0x24, 0x00, 0x00, 0x00, 0x3C, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
                Set-ItemProperty -Path "$du\Software\Microsoft\Windows\CurrentVersion\Explorer" `
                    -Name 'ShellState' -Value $shellState -Type Binary -Force -ErrorAction SilentlyContinue
                Write-Log "  [OK]   Registry: ShellState (Binary)"

                # UserPreferencesMask - control visual effect checkboxes
                # 0x9032078010000000: shadows under mouse, smooth fonts; disable most animations
                $prefMask = [byte[]](0x90, 0x32, 0x07, 0x80, 0x10, 0x00, 0x00, 0x00)
                Set-ItemProperty -Path "$du\Control Panel\Desktop" `
                    -Name 'UserPreferencesMask' -Value $prefMask -Type Binary -Force -ErrorAction SilentlyContinue
                Write-Log "  [OK]   Registry: UserPreferencesMask (Binary)"

                # Explorer Advanced display options
                $explorerAdv = "$du\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
                Set-PolicyValue -Path $explorerAdv -Name 'IconsOnly'          -Value 1
                Set-PolicyValue -Path $explorerAdv -Name 'ListviewAlphaSelect' -Value 0
                Set-PolicyValue -Path $explorerAdv -Name 'ListviewShadow'      -Value 0
                Set-PolicyValue -Path $explorerAdv -Name 'ShowCompColor'       -Value 1
                Set-PolicyValue -Path $explorerAdv -Name 'ShowInfoTip'         -Value 1
                Set-PolicyValue -Path $explorerAdv -Name 'TaskbarAnimations'   -Value 0

                # Desktop - window drag, font smoothing, animation
                Set-PolicyValue -Path "$du\Control Panel\Desktop" `
                    -Name 'DragFullWindows' -Value '0' `
                    -Type ([Microsoft.Win32.RegistryValueKind]::String)
                Set-PolicyValue -Path "$du\Control Panel\Desktop" `
                    -Name 'FontSmoothing' -Value '2' `
                    -Type ([Microsoft.Win32.RegistryValueKind]::String)
                Set-PolicyValue -Path "$du\Control Panel\Desktop\WindowMetrics" `
                    -Name 'MinAnimate' -Value '0' `
                    -Type ([Microsoft.Win32.RegistryValueKind]::String)

                # DWM - disable Aero Peek and thumbnail caching
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\DWM" `
                    -Name 'EnableAeroPeek' -Value 0
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\DWM" `
                    -Name 'AlwaysHiberNateThumbnails' -Value 0

                # Content Delivery Manager - disable suggested / pre-installed apps and tips
                $cdmPath = "$du\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
                Set-PolicyValue -Path $cdmPath -Name 'ContentDeliveryAllowed'              -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'OemPreInstalledAppsEnabled'          -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'PreInstalledAppsEnabled'             -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SilentInstalledAppsEnabled'          -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContentEnabled'            -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SoftLandingEnabled'                  -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SystemPaneSuggestionsEnabled'        -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-338393Enabled'     -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-353694Enabled'     -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-353696Enabled'     -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-338388Enabled'     -Value 0
                Set-PolicyValue -Path $cdmPath -Name 'SubscribedContent-338389Enabled'     -Value 0

                # Privacy - opt out of language-based content and settings suggestions
                Set-PolicyValue -Path "$du\Control Panel\International\User Profile" `
                    -Name 'HttpAcceptLanguageOptOut' -Value 1

                # User Profile Engagement - suppress SCOOBE (Settings welcome experience)
                Set-PolicyValue -Path "$du\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" `
                    -Name 'ScoobeSystemSettingEnabled' -Value 0

                # ==================================================================
                # User Configuration policies (applied via default user hive)
                # These mirror the "Local Computer Policy \ User Configuration"
                # section of the VDI optimization article. Machine-level equivalents
                # for the Cloud Content settings are already in Section 5; these
                # user-level policies are applied here for defense in depth and to
                # cover cases where machine policy has not yet propagated (e.g.,
                # during the first boot of the golden image itself).
                # Two user-config Cloud Content policies have NO machine equivalent:
                #   ConfigureWindowsSpotlight and DisableTailoredExperiencesWithDiagnosticData.
                # ==================================================================

                # -- Cloud Content (User Configuration) --
                # Ref: Article local policy table - User Configuration > Windows Components > Cloud Content
                $duCloudContent = "$du\Software\Policies\Microsoft\Windows\CloudContent"
                # Turn off all Windows Spotlight features (lock screen, tips, consumer features)
                Set-PolicyValue -Path $duCloudContent -Name 'DisableWindowsSpotlightFeatures'              -Value 1
                # Don't suggest third-party content in Windows Spotlight
                Set-PolicyValue -Path $duCloudContent -Name 'DisableThirdPartySuggestions'                 -Value 1
                # Don't use diagnostic data for tailored experiences (USER CONFIG ONLY - no machine equivalent)
                Set-PolicyValue -Path $duCloudContent -Name 'DisableTailoredExperiencesWithDiagnosticData' -Value 1
                # Configure Windows spotlight on lock screen: 2 = Disabled (USER CONFIG ONLY - no machine equivalent)
                # 1 = enabled, 2 = disabled (user cannot select spotlight as lock screen)
                Set-PolicyValue -Path $duCloudContent -Name 'ConfigureWindowsSpotlight'                    -Value 2

                # -- Start Menu and Taskbar (User Configuration) --
                # Ref: Article local policy table - User Configuration > Start Menu and Taskbar
                $duLegacyExplorer = "$du\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
                # Turn off user tracking (suppresses frequently-used programs list and MRU data)
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoInstrumentation'   -Value 1
                # Don't add shares of recently opened documents to Network Locations
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoRecentDocsNetHood' -Value 1
                # Don't use search-based method when resolving shell shortcuts
                Set-PolicyValue -Path $duLegacyExplorer -Name 'NoResolveSearch'     -Value 1

                $duExplorer = "$du\Software\Policies\Microsoft\Windows\Explorer"
                # Don't display or track items in Jump Lists from remote locations
                Set-PolicyValue -Path $duExplorer -Name 'NoRemoteDestinations'          -Value 1
                # Turn off Aero Shake window minimizing mouse gesture
                Set-PolicyValue -Path $duExplorer -Name 'NoWindowMinimizingShortcuts'   -Value 1
                # Turn off all balloon notifications in the taskbar notification area
                Set-PolicyValue -Path $duExplorer -Name 'TaskbarNoNotification'         -Value 1
                # Turn off feature advertisement balloon notifications
                Set-PolicyValue -Path $duExplorer -Name 'NoBalloonFeatureAdvertisements' -Value 1

                $duPushNotify = "$du\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
                # Turn off toast (in-app popup) notifications
                Set-PolicyValue -Path $duPushNotify -Name 'NoToastApplicationNotification'           -Value 1
                # Turn off toast notifications on the lock screen
                Set-PolicyValue -Path $duPushNotify -Name 'NoToastApplicationNotificationOnLockScreen' -Value 1

                # -- Desktop (User Configuration) --
                # Ref: Article local policy table - User Configuration > Desktop
                # Don't add shares of recently opened documents to Network Locations (also Explorer above)
                # Turn off Aero Shake already covered above

                # -- Edge UI (User Configuration) --
                # Turn off app-usage tracking in the Start search / Charm bar MRU list
                # Ref: Article local policy table - User Configuration > Edge UI
                Set-PolicyValue -Path "$du\Software\Policies\Microsoft\Windows\EdgeUI" `
                    -Name 'DisableMFUTracking' -Value 1

                # -- File Explorer (User Configuration) --
                # Ref: Article local policy table - User Configuration > File Explorer
                # Turn off caching of thumbnail pictures
                Set-PolicyValue -Path $duExplorer -Name 'DisableThumbnails'             -Value 1
                # Turn off display of recent search entries in the File Explorer search box
                Set-PolicyValue -Path $duExplorer -Name 'DisableSearchBoxSuggestions'   -Value 1
                # Turn off caching of thumbnails in hidden thumbs.db files
                # (machine-level DisableThumbsDBOnNetworkFolders is also set in Section 5)
                Set-PolicyValue -Path $duExplorer -Name 'DisableThumbsDBOnNetworkFolders' -Value 1

                Invoke-ApplyPolicyQueue
                Write-Log "  Default user profile settings applied"
            }
            catch {
                Write-Log "  [WARN] Error applying default user profile settings - $_"
            }
            finally {
                if ($hiveMounted) {
                    # Force garbage collection to release any PowerShell handles before unloading
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                    Start-Sleep -Seconds 2
                    $unloadResult = & reg.exe unload 'HKLM\TempDefaultUser' 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "  Default user hive unloaded successfully"
                    }
                    else {
                        Write-Log "  [WARN] Could not unload default user hive (may leave a stale mount): $unloadResult"
                    }
                }
            }
        }
        else {
            Write-Log "  [SKIP] Default user hive not found at $defaultHivePath"
        }

        Write-Log ""
    } # end if RunFullOptimization - Section 8

    # -----------------------------------------------------------------------
    # SECTION 9 - Network Performance Tuning (LanManWorkstation / SMB client)
    # Improves SMB client performance for profile share and application data
    # access across the network in VDI environments.
    # Reference: https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 9: Network Performance Tuning (LanManWorkstation) ---"

        $lanman = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
        # Disable bandwidth throttling on high-latency network connections
        Set-PolicyValue -Path $lanman -Name 'DisableBandwidthThrottling'  -Value 1
        # Increase file metadata cache entries (default 64 -> 1024)
        Set-PolicyValue -Path $lanman -Name 'FileInfoCacheEntriesMax'     -Value 1024
        # Increase directory information cache entries (default 16 -> 1024)
        Set-PolicyValue -Path $lanman -Name 'DirectoryCacheEntriesMax'    -Value 1024
        # Increase file-not-found cache entries (default 128 -> 2048)
        Set-PolicyValue -Path $lanman -Name 'FileNotFoundCacheEntriesMax' -Value 2048
        # Reduce max dormant open files per share connection (default 1023 -> 256)
        # Helps when many clients connect to the same SMB server (e.g., profile share)
        Set-PolicyValue -Path $lanman -Name 'DormantFileLimit'            -Value 256

        Write-Log ""
    } # end if RunFullOptimization - Section 9

    # -----------------------------------------------------------------------
    # SECTION 10 - Autologgers (Windows Startup Event Trace Sessions)
    # Disable diagnostic traces that serve no purpose in a managed VDI image.
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 10: Autologgers ---"

        $autologgers = [System.Collections.Generic.List[string]]@(
            'Cellcore',                 # Cellular architecture trace
            'CloudExperienceHostOOBE',  # OOBE cloud experience trace
            'DiagLog',                  # Diagnostic Policy Service log
            'RadioMgr',                 # NFC/radio manager trace
            'ReadyBoot',                # Boot prefetch analysis
            'WDIContextLog',            # WDI miniport driver trace
            'WiFiDriverIHVSession'      # WLAN IHV diagnostic session
        )

        foreach ($logger in $autologgers) {
            Disable-VdiAutologger -Name $logger
        }

        Write-Log ""
    } # end if RunFullOptimization - Section 10

    # -----------------------------------------------------------------------
    # SECTION 11 - Optional Windows Features
    # -----------------------------------------------------------------------
    if ($RunFullOptimization) {
        Write-Log "--- Section 11: Optional Windows Features ---"

        $featuresToDisable = @(
            @{ Name = 'WindowsMediaPlayer'; Label = 'Windows Media Player' },
            @{ Name = 'WorkFolders-Client'; Label = 'Work Folders Client' },
            @{ Name = 'Printing-XPSServices-Features'; Label = 'XPS Viewer / Services' }
        )

        foreach ($feature in $featuresToDisable) {
            $featureState = Get-WindowsOptionalFeature -Online -FeatureName $feature.Name `
                -ErrorAction SilentlyContinue
            if ($null -eq $featureState) {
                Write-Log "  [SKIP] Optional feature not found: $($feature.Label) ($($feature.Name))"
                continue
            }
            if ($featureState.State -ne 'Enabled') {
                Write-Log "  [SKIP] Optional feature already disabled: $($feature.Label)"
                continue
            }
            try {
                Disable-WindowsOptionalFeature -Online -FeatureName $feature.Name `
                    -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "  [OK]   Disabled optional feature: $($feature.Label)"
            }
            catch {
                Write-Log "  [WARN] Could not disable $($feature.Label) - $_"
            }
        }

        Write-Log ""
    } # end if RunFullOptimization - Section 11

    Write-Log "============================================================"
    Write-Log "  Optimize-AVDImage Complete"
    Write-Log "  Profile: $OptimizationProfile | RestrictInternet: $RestrictInternetBool"
    Write-Log "  Log: $LogFile"
    Write-Log "============================================================"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    throw
}
