#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Updates built-in UWP/AppX apps in the provisioned (machine) layer during an AVD image build.

.DESCRIPTION
    Uses winget with --scope machine to update the provisioned package layer in
    C:\Program Files\WindowsApps. Because this targets the provisioned layer rather than any
    per-user layer, every new user profile created from the captured image inherits the updated
    app versions immediately — no per-user Store update delay.

    The InstallService\ScanForUpdates scheduled task approach was intentionally replaced because
    that task runs as SYSTEM and updates only SYSTEM's per-user package registration, not the
    provisioned layer. It has no effect on new user profiles created from the image.

    winget --scope machine calls Add-AppxProvisionedPackage internally, which is the correct
    primitive for updating the machine-wide provisioned layer from SYSTEM context.

    Air-gapped environments: if winget cannot reach its update sources, it exits with a
    "no applicable update" code and this script exits cleanly with a warning. The build is
    not failed (treatFailureAsDeploymentFailure is false for this run command).
#>

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Update-UwpApps.log"

function Write-Log {
    param(
        [parameter(ValueFromPipeline = $True, Mandatory = $True, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

function Get-ProvisionedPackageVersionMap {
    $map = @{}
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object {
        $map[$_.DisplayName] = $_.Version
    }
    return $map
}

function Find-WingetExe {
    # Search the machine-level WindowsApps path first. This path is accessible from SYSTEM
    # context; the per-user path (%LOCALAPPDATA%\Microsoft\WindowsApps) is not.
    $candidate = Get-ChildItem `
        -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*" `
        -Filter 'winget.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }

    # Fall back to PATH (covers cases where winget is already on the system PATH).
    $inPath = Get-Command -Name 'winget' -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    return $null
}

try {
    Write-Log "Updating Built-In UWP Apps via winget (machine scope)"

    # --- Pre-flight: DISM readiness check ---
    # winget --scope machine calls DISM/AppX APIs internally. An active CBS/servicing pass
    # holds the DISM session lock and will cause winget to hang or fail. Wait up to 3 minutes.
    Write-Log "Pre-flight: checking for active CBS/DISM operations (TiWorker / TrustedInstaller)..."
    $dismWaitSeconds  = 180
    $dismPollInterval = 10
    $dismElapsed      = 0
    while ($dismElapsed -lt $dismWaitSeconds) {
        $cbsActive = Get-Process -Name 'TiWorker', 'TrustedInstaller' -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.HasExited }
        if (-not $cbsActive) { break }
        Write-Log "Pre-flight: CBS/DISM in use ($($cbsActive.Name -join ', ')). Waiting $dismPollInterval s... ($dismElapsed / $dismWaitSeconds s elapsed)"
        Start-Sleep -Seconds $dismPollInterval
        $dismElapsed += $dismPollInterval
    }
    if ($dismElapsed -ge $dismWaitSeconds) {
        Write-Log "WARNING: CBS/DISM was still active after $dismWaitSeconds seconds. AppX operations may hang or fail."
    }
    else {
        Write-Log "Pre-flight: no active CBS/DISM operations detected."
    }

    # Check for a pending reboot (informational — does not abort).
    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue))
    if ($pendingReboot) {
        Write-Log "WARNING: A pending reboot was detected. AppX operations may behave unexpectedly."
    }
    else {
        Write-Log "Pre-flight: no pending reboot detected."
    }

    # --- Step 1: Ensure winget is available at the machine-level path ---
    Write-Log "Step 1: Locating winget..."
    $WingetExe = Find-WingetExe

    if (-not $WingetExe) {
        Write-Log "winget not found at machine-level path. Attempting to install Microsoft.WinGet.Client and repair App Installer..."
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers -ErrorAction Stop
            Import-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
            # -AllUsers provisions winget.exe to C:\Program Files\WindowsApps, making it
            # accessible from SYSTEM. Without -AllUsers it is only registered per-user.
            Repair-WinGetPackageManager -AllUsers -Force -ErrorAction Stop
            Write-Log "App Installer repaired successfully."
        }
        catch {
            Write-Log "WARNING: Could not install or repair winget: $($_.Exception.Message)"
            Write-Log "This may be an air-gapped environment or PSGallery is unreachable. Skipping UWP app updates."
            Exit 0
        }
        $WingetExe = Find-WingetExe
    }

    if (-not $WingetExe) {
        Write-Log "winget executable not found after repair attempt. Skipping UWP app updates."
        Exit 0
    }

    $WingetVersion = & $WingetExe --version 2>&1
    Write-Log "winget found at: $WingetExe (version: $WingetVersion)"

    # --- Step 2: Snapshot provisioned package versions before upgrade ---
    Write-Log "Step 2: Snapshotting provisioned package versions..."
    $VersionsBefore = Get-ProvisionedPackageVersionMap
    Write-Log "Found $($VersionsBefore.Count) provisioned package(s)."

    # --- Step 3: Run winget upgrade ---
    # --scope machine   → updates the provisioned layer (C:\Program Files\WindowsApps),
    #                     not a per-user layer. This is the key difference vs InstallService.
    # --silent          → suppresses all UI; required for unattended image builds.
    # --accept-*        → suppresses license/agreement prompts.
    # --disable-interactivity → prevents winget from waiting for user input (winget 1.2+).
    #
    # Apps that do not support machine scope are skipped by winget with a note in the output;
    # they do not cause a non-zero exit code. Apps requiring Microsoft account authentication
    # (paid msstore apps) are also silently skipped.
    $WingetArgs = @(
        'upgrade', '--all',
        '--scope', 'machine',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    Write-Log "Step 3: Running: $WingetExe $($WingetArgs -join ' ')"

    $WingetOutput = & $WingetExe @WingetArgs 2>&1
    $WingetExitCode = $LASTEXITCODE

    foreach ($line in $WingetOutput) {
        Write-Log "  [winget] $line"
    }

    # 0             = success
    # -1978335212   = 0x8A15002C = APPINSTALLER_CLI_ERROR_NO_APPLICABLE_UPDATE (nothing to update)
    # Both are acceptable outcomes.
    $NoUpdateCode = -1978335212
    if ($WingetExitCode -eq 0 -or $WingetExitCode -eq $NoUpdateCode) {
        Write-Log "winget completed (exit code: $WingetExitCode)."
    }
    else {
        Write-Log "WARNING: winget exited with code $WingetExitCode. Some packages may not have updated. Review the output above for details."
    }

    # --- Step 4: Summary ---
    Write-Log "*********************************"
    Write-Log "Update Summary"
    Write-Log "*********************************"
    $FinalVersionMap = Get-ProvisionedPackageVersionMap
    $Updated = $FinalVersionMap.Keys | Where-Object {
        $VersionsBefore.ContainsKey($_) -and $VersionsBefore[$_] -ne $FinalVersionMap[$_]
    }
    $NewPackages = $FinalVersionMap.Keys | Where-Object { -not $VersionsBefore.ContainsKey($_) }

    if ($Updated) {
        Write-Log "Packages updated ($(@($Updated).Count)):"
        foreach ($pkg in ($Updated | Sort-Object)) {
            Write-Log "  $pkg : $($VersionsBefore[$pkg]) -> $($FinalVersionMap[$pkg])"
        }
    }
    else {
        Write-Log "No provisioned package versions changed. The image may already be up to date, or installed apps may not support machine-scope upgrades via winget."
    }
    if ($NewPackages) {
        Write-Log "New packages added ($(@($NewPackages).Count)):"
        foreach ($pkg in ($NewPackages | Sort-Object)) {
            Write-Log "  $pkg : $($FinalVersionMap[$pkg])"
        }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}