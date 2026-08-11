<#
.SYNOPSIS
    Provisions built-in UWP apps from offline MSIX packages for all users on the system.

.DESCRIPTION
    Iterates through each app subfolder inside the builtin-uwp-apps artifact directory.
    For each subfolder it installs dependency packages found in a Dependencies subfolder,
    then provisions the main bundle with Add-AppxProvisionedPackage so the app is
    available to every user who signs in after imaging.

    Expected folder structure (populated by Update-ImageArtifacts.ps1 via winget download):

        builtin-uwp-apps\
            Calculator\
                Microsoft.WindowsCalculator_<version>_neutral_~_8wekyb3d8bbwe.msixbundle
                Dependencies\
                    x64\
                        Microsoft.VCLibs.140.00.UWPDesktop_<version>_x64_8wekyb3d8bbwe.appx
                        ...
            Paint\
                ...

    IMPORTANT -- PROVISIONING PREREQUISITE:
    Add-AppxProvisionedPackage must be called with -Regions all. Without this parameter,
    Windows only provisions the app for Start layout pinning scenarios and removes it
    during sysprep (event ID 472: package folder moved to Deleted). This script passes
    -Regions all for every provisioning call.

    Reference: Microsoft internal support article (June 2026) -- "Windows Store apps are not
    retained after sysprep".

.NOTES
    - Requires Windows PowerShell 5.1 or PowerShell 7+ running on Windows.
    - Must be run as Administrator or from a SYSTEM context (e.g., Azure VM Run Command).
    - Uses Add-AppxProvisionedPackage -Online so changes apply to the live OS image.
    - -SkipLicense is used because Store apps downloaded via winget do not require a
      separate license file for enterprise provisioning.
    - If an app folder contains no recognized package file (.msix/.msixbundle/.appx/
      .appxbundle), that folder is skipped with a warning.
    - Individual app failures are logged but do not abort the rest of the script.
#>

[CmdletBinding()]
param()

$Script:Name = 'Install-BuiltinUwpApps'
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $Content = "[$ts] $Message"
    if (-not $env:SUPPRESS_FILELOG) {
        Add-Content -Path $Script:Log -Value $Content -ErrorAction SilentlyContinue
    }
    Write-Output $Content
}

function New-Log {
    param([string]$Path)
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    $date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
    $Script:Log = Join-Path $Path "$Script:Name-$date.log"
}

function Get-PackageFileVersion {
    # Extracts the version segment from an MSIX/APPX package filename.
    # Winget names packages using the pattern: Name_Version_arch_..._Publisher.ext
    # e.g. Microsoft.WindowsCalculator_11.2404.0.0_neutral_~_8wekyb3d8bbwe.msixbundle
    param([string]$FileName)
    if ($FileName -match '_([0-9]+(?:\.[0-9]+){1,3})_') {
        try   { return [Version]$Matches[1] }
        catch { return [Version]'0.0.0.0' }
    }
    return [Version]'0.0.0.0'
}

#endregion Helpers

New-Log (Join-Path $Env:SystemRoot 'Logs')
Write-Log "Install-BuiltinUwpApps: Starting"
Write-Log "Script location : $PSScriptRoot"

# Snapshot all currently provisioned packages before we change anything.
# Keyed by the package name family (publisher prefix before the first version segment)
# so we can look up the pre-run version regardless of installed version number.
$SnapshotBefore = @{}
Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object {
    # Strip from the first version segment onward to get the stable family key.
    # e.g. Microsoft.WindowsCalculator_11.2404.0.0_neutral_~_8wekyb3d8bbwe
    #   -> Microsoft.WindowsCalculator
    $familyKey = $_.PackageName -replace '_[0-9]+(?:\.[0-9]+)+.*$', ''
    $v = Get-PackageFileVersion $_.PackageName
    $SnapshotBefore[$familyKey] = $v
}
Write-Log "Provisioned packages snapshot: $($SnapshotBefore.Count) package(s) recorded."

$AppFolders = Get-ChildItem -Path $PSScriptRoot -Directory -ErrorAction Stop |
    Where-Object { $_.Name -ne 'SharedDependencies' } |
    Sort-Object Name

if ($AppFolders.Count -eq 0) {
    Write-Log "No app subfolders found. Nothing to provision."
    exit 0
}

Write-Log "Found $($AppFolders.Count) app folder(s) to provision."

$SuccessCount = 0
$SkipCount    = 0
$ErrorCount   = 0

# Track per-app before/after for the change summary.
$ChangeLog = [System.Collections.Generic.List[PSCustomObject]]::new()

# Collect shared framework dependencies once -- the same set is used for every app.
# Log the full list here so it appears once in the output rather than repeating for
# each app in the provisioning loop below.
$SharedDepDir = Join-Path -Path $PSScriptRoot -ChildPath 'SharedDependencies'
$DepPackages  = @()
if (Test-Path -Path $SharedDepDir) {
    $DepPackages = @(Get-ChildItem -Path $SharedDepDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.appx', '.msix') })
}
if ($DepPackages.Count -gt 0) {
    Write-Log ""
    Write-Log "Shared framework deps: $($DepPackages.Count) package(s)"
    $DepPackages | Sort-Object Name | ForEach-Object { Write-Log "  $($_.Name)" }
}
else {
    Write-Log "No shared framework dependencies found in SharedDependencies\."
}

foreach ($AppFolder in $AppFolders) {
    Write-Log ""
    Write-Log "=== $($AppFolder.Name) ==="

    # ----------------------------------------------------------------
    # Locate the main bundle at the root of the app folder.
    # Prefer larger files (bundles) over small single-arch packages.
    # ----------------------------------------------------------------
    $PackageExtensions = @('.msixbundle', '.appxbundle', '.msix', '.appx')

    # Sort candidates: highest version first; break ties by preferring bundles over
    # single-arch packages (bundles are neutral/multi-arch and are typically the right
    # choice), then by file size as a last tiebreaker.
    $MainPackage = Get-ChildItem -Path $AppFolder.FullName -File |
        Where-Object { $_.Extension -in $PackageExtensions } |
        Sort-Object @{Expression = { Get-PackageFileVersion $_.Name };   Descending = $true },
                    @{Expression = {
                        switch ($_.Extension) {
                            '.msixbundle' { 0 }
                            '.appxbundle' { 1 }
                            '.msix'       { 2 }
                            '.appx'       { 3 }
                            default       { 4 }
                        }
                    }},
                    @{Expression = { $_.Length }; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $MainPackage) {
        Write-Log "WARNING: No package file found in '$($AppFolder.FullName)'. Skipping."
        $SkipCount++
        $ChangeLog.Add([PSCustomObject]@{ App = $AppFolder.Name; Before = '-'; After = '-'; Change = 'no package' })
        continue
    }

    $PackageVersion = Get-PackageFileVersion $MainPackage.Name
    Write-Log "Main package : $($MainPackage.Name) ($([math]::Round($MainPackage.Length / 1MB, 1)) MB)"
    Write-Log "Package ver  : $PackageVersion"

    # ----------------------------------------------------------------
    # Skip provisioning if the same or a newer version is already
    # provisioned on this image. Compare against the provisioned
    # package's version so we never downgrade.
    # ----------------------------------------------------------------
    # Derive the stable package family key by stripping from the first version
    # segment onward. This matches across different installed vs staged versions.
    # e.g. Microsoft.WindowsCalculator_2021.2508.4.0_Universal_X64
    #   -> Microsoft.WindowsCalculator
    $PackageNamePrefix = [System.IO.Path]::GetFileNameWithoutExtension($MainPackage.Name) -replace '_[0-9]+(?:\.[0-9]+)+.*$', ''
    $ExistingProvisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like "*$PackageNamePrefix*" } |
        Select-Object -First 1
    # Use the snapshot for the before-version (captured before any provisioning ran).
    $VersionBefore = if ($SnapshotBefore.ContainsKey($PackageNamePrefix)) { $SnapshotBefore[$PackageNamePrefix] } else { $null }
    if ($null -ne $ExistingProvisioned) {
        # Extract version from the full provisioned package name (same _ delimited format).
        $ProvisionedVersion = $VersionBefore
        Write-Log "Provisioned  : $($ExistingProvisioned.PackageName)"
        Write-Log "Prov. ver    : $ProvisionedVersion"
        if ($ProvisionedVersion -ge $PackageVersion) {
            Write-Log "SKIP: Provisioned version ($ProvisionedVersion) is already equal to or newer than the staged package ($PackageVersion). No action needed."
            $SkipCount++
            $ChangeLog.Add([PSCustomObject]@{ App = $AppFolder.Name; Before = "$ProvisionedVersion"; After = "$ProvisionedVersion"; Change = 'up-to-date' })
            continue
        }
        Write-Log "Staged package is newer ($PackageVersion > $ProvisionedVersion). Provisioning update."
    }

    Write-Log "Shared deps  : $($DepPackages.Count) package(s)"

    # ----------------------------------------------------------------
    # Provision the app for all users via DISM (online mode).
    # Strategy: attempt without explicit dependencies first. On a
    # modern Windows 11 image the required frameworks (VCLibs, WinAppSDK,
    # UI.Xaml etc.) are already provisioned in the OS component store and
    # DISM can satisfy them without us supplying them. Passing explicit
    # dependency packages that conflict with already-registered versions
    # causes 0xc1570118 (APPX_E_PREREQUISITE_NOT_MET). If the no-dep
    # attempt fails and we have staged dependencies, retry with them.
    # ----------------------------------------------------------------
    $BaseParams = @{
        Online      = $true
        PackagePath = $MainPackage.FullName
        SkipLicense = $true
        Regions     = 'all'   # Required: without this, Windows removes the app during sysprep (event 472)
    }

    # When updating an already-provisioned package, explicitly remove the old entry
    # before adding the new one. Add-AppxProvisionedPackage -Online silently succeeds
    # for in-place updates but often fails to register the new version in the staging
    # manifest used by the AppX deployment service at new user logon (event 327), leaving
    # the old entry removed and the new one absent -- apps missing for every new user.
    # Removing first forces the new package through the clean "fresh install" path.
    if ($null -ne $ExistingProvisioned) {
        Write-Log "Removing old provisioned entry before update (avoid silent staging failure)..."
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $ExistingProvisioned.PackageName -ErrorAction Stop | Out-Null
            Write-Log "Old provisioned entry removed OK."
        }
        catch {
            Write-Log "WARNING: Could not remove old provisioned entry: $_ -- proceeding with add anyway."
        }
    }

    $Provisioned = $false
    try {
        Write-Log "Provisioning '$($AppFolder.Name)' (without explicit dependencies)..."
        Add-AppxProvisionedPackage @BaseParams | Out-Null
        # Verify the new version is actually in the provisioned store -- Add-AppxProvisionedPackage
        # can return without throwing while still failing to register the package for new users.
        $VerifyProvisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -like "*$PackageNamePrefix*" } |
            Select-Object -First 1
        if ($null -ne $VerifyProvisioned) {
            Write-Log "Provisioned  : $($AppFolder.Name) - OK"
            $Provisioned = $true
            # Clear the AppxAllUserStore\Deprovisioned registry entry for this package family.
            # When Remove-AppxProvisionedPackage is called (e.g., by the image build's Remove-AppXPackages
            # step), Windows writes a deprovisioned record here. Even after re-provisioning, the record
            # persists and takes precedence at user logon -- causing AppX to queue the package for removal
            # (event 327) instead of registering it. Deleting the record allows the provisioned package
            # to register normally for every new user session created from this image.
            $PkgFamilyName = $VerifyProvisioned.PackageName -replace '_[^_]+$', ''
            # PackageName format: PublisherName.AppName_Version_arch__PublisherID
            # PackageFamilyName format: PublisherName.AppName_PublisherID
            # Extract from the full PackageName by taking everything before the first '_' then appending
            # the PublisherID (last segment after splitting on '__').
            if ($VerifyProvisioned.PackageName -match '^(.+?)_[\d\.]+_[^_]+__([^_]+)$') {
                $PkgFamilyName = "$($Matches[1])_$($Matches[2])"
            }
            $DeprovPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$PkgFamilyName"
            if (Test-Path $DeprovPath) {
                try {
                    Remove-Item -Path $DeprovPath -Recurse -Force -ErrorAction Stop
                    Write-Log "Cleared deprovisioned record: $PkgFamilyName"
                }
                catch {
                    Write-Log "WARNING: Could not clear deprovisioned record for '$PkgFamilyName': $_"
                }
            }
        }
        else {
            Write-Log "WARNING: Add-AppxProvisionedPackage did not throw but package not found in provisioned store."
            throw "Package not found in provisioned store after Add-AppxProvisionedPackage."
        }
    }
    catch {
        Write-Log "First attempt failed: $_"
        if ($DepPackages.Count -gt 0) {
            Write-Log "Retrying with $($DepPackages.Count) explicit dependency package(s)..."
            try {
                $ParamsWithDeps = $BaseParams.Clone()
                $ParamsWithDeps['DependencyPackagePath'] = $DepPackages | Select-Object -ExpandProperty FullName
                Add-AppxProvisionedPackage @ParamsWithDeps | Out-Null
                $VerifyProvisioned2 = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                    Where-Object { $_.PackageName -like "*$PackageNamePrefix*" } |
                    Select-Object -First 1
                if ($null -ne $VerifyProvisioned2) {
                    Write-Log "Provisioned  : $($AppFolder.Name) - OK (with explicit dependencies)"
                    $Provisioned = $true
                    $PkgFamilyName2 = ''
                    if ($VerifyProvisioned2.PackageName -match '^(.+?)_[\d\.]+_[^_]+__([^_]+)$') {
                        $PkgFamilyName2 = "$($Matches[1])_$($Matches[2])"
                    }
                    if ($PkgFamilyName2 -and (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$PkgFamilyName2")) {
                        try {
                            Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$PkgFamilyName2" -Recurse -Force -ErrorAction Stop
                            Write-Log "Cleared deprovisioned record: $PkgFamilyName2"
                        }
                        catch { Write-Log "WARNING: Could not clear deprovisioned record for '$PkgFamilyName2': $_" }
                    }
                }
                else {
                    Write-Log "ERROR provisioning '$($AppFolder.Name)': not in provisioned store after second attempt."
                }
            }
            catch {
                Write-Log "ERROR provisioning '$($AppFolder.Name)' (both attempts failed): $_"
            }
        }
        else {
            Write-Log "ERROR provisioning '$($AppFolder.Name)' (no staged dependencies to retry with): $_"
        }
    }

    $beforeStr = if ($null -ne $VersionBefore) { "$VersionBefore" } else { '(not present)' }
    if ($Provisioned) {
        $SuccessCount++
        $ChangeLog.Add([PSCustomObject]@{ App = $AppFolder.Name; Before = $beforeStr; After = "$PackageVersion"; Change = if ($null -eq $VersionBefore) { 'NEW' } else { 'UPDATED' } })
    }
    else {
        $ErrorCount++
        $ChangeLog.Add([PSCustomObject]@{ App = $AppFolder.Name; Before = $beforeStr; After = 'ERROR'; Change = 'ERROR' })
    }
}

Write-Log ""
Write-Log "=== Change Summary ==="
$ColW = @{ App = 30; Before = 20; After = 20; Change = 12 }
$Header = "{0,-$($ColW.App)} {1,-$($ColW.Before)} {2,-$($ColW.After)} {3,-$($ColW.Change)}" -f 'App','Before','After','Change'
$Divider = ('-' * $ColW.App) + ' ' + ('-' * $ColW.Before) + ' ' + ('-' * $ColW.After) + ' ' + ('-' * $ColW.Change)
Write-Log $Header
Write-Log $Divider
foreach ($Row in ($ChangeLog | Sort-Object App)) {
    $Line = "{0,-$($ColW.App)} {1,-$($ColW.Before)} {2,-$($ColW.After)} {3,-$($ColW.Change)}" -f $Row.App, $Row.Before, $Row.After, $Row.Change
    if ($Row.Change -in @('NEW','UPDATED')) {
        Write-Log "** $Line"
    } else {
        Write-Log "   $Line"
    }
}
Write-Log $Divider
Write-Log ""
Write-Log "=== Summary ==="
Write-Log "Provisioned  : $SuccessCount"
Write-Log "Skipped      : $SkipCount (already up-to-date or no package found)"
Write-Log "Errors       : $ErrorCount"
Write-Log "Install-BuiltinUwpApps: Complete"

# ----------------------------------------------------------------
# Image health check.
# Runs after all provisioning to verify the provisioned store is in
# the expected state. Three things are checked:
#   1. Every app folder that was processed (and did not error) has a
#      corresponding entry in Get-AppxProvisionedPackage.
#   2. No provisioned app has a lingering Deprovisioned registry entry
#      that would silently remove it at the next user logon.
#   3. Every framework dependency package in SharedDependencies is
#      present in the provisioned store -- either from the OS baseline
#      or staged as a side-effect of provisioning an app that needed it.
# ----------------------------------------------------------------
Write-Log ""
Write-Log "=== Image Health Check ==="
$HealthIssues     = [System.Collections.Generic.List[string]]::new()
$FinalPkgs        = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
$PkgExtensions2   = @('.msixbundle', '.appxbundle', '.msix', '.appx')

Write-Log ""
Write-Log "-- App packages --"
foreach ($Row in ($ChangeLog | Sort-Object App)) {
    if ($Row.Change -eq 'no package') { continue }

    if ($Row.Change -eq 'ERROR') {
        Write-Log ("  FAIL  {0,-30} provisioning error (see log above)" -f $Row.App)
        continue
    }

    # Re-derive the package name prefix from the main bundle file so we can
    # look it up in the provisioned store without storing extra state in the loop.
    $CheckPath = Join-Path -Path $PSScriptRoot -ChildPath $Row.App
    $CheckMain = Get-ChildItem -Path $CheckPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $PkgExtensions2 } | Select-Object -First 1
    $CheckPrefix = if ($null -ne $CheckMain) {
        [System.IO.Path]::GetFileNameWithoutExtension($CheckMain.Name) -replace '_[0-9]+(?:\.[0-9]+)+.*$', ''
    } else { '' }

    if (-not $CheckPrefix) {
        Write-Log ("  SKIP  {0,-30} could not derive package prefix for verification" -f $Row.App)
        continue
    }

    $CheckFound = $FinalPkgs | Where-Object { $_.PackageName -like "*$CheckPrefix*" } | Select-Object -First 1
    if ($null -eq $CheckFound) {
        Write-Log ("  FAIL  {0,-30} not found in provisioned store" -f $Row.App)
        $HealthIssues.Add("$($Row.App): not found in provisioned store")
        continue
    }

    $CheckVer = Get-PackageFileVersion $CheckFound.PackageName
    $CheckFamily = ''
    if ($CheckFound.PackageName -match '^(.+?)_[\d\.]+_[^_]+__([^_]+)$') {
        $CheckFamily = "$($Matches[1])_$($Matches[2])"
    }
    $DeprovKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$CheckFamily"
    if ($CheckFamily -and (Test-Path $DeprovKey)) {
        Write-Log ("  WARN  {0,-30} v{1} -- Deprovisioned registry entry present; app will be removed at next user logon" -f $Row.App, $CheckVer)
        $HealthIssues.Add("$($Row.App): Deprovisioned registry entry present. Fix: Remove-Item -Path '$DeprovKey' -Recurse -Force")
    }
    else {
        Write-Log ("  OK    {0,-30} v{1}" -f $Row.App, $CheckVer)
    }
}

Write-Log ""
Write-Log "-- Framework dependencies --"
if ($DepPackages.Count -gt 0) {
    $SeenPrefixes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($DepFileCheck in ($DepPackages | Sort-Object Name)) {
            $DepPfx = [System.IO.Path]::GetFileNameWithoutExtension($DepFileCheck.Name) `
                -replace '_[0-9]+(?:\.[0-9]+)+.*$', ''
            if (-not $SeenPrefixes.Add($DepPfx)) { continue }  # skip arch duplicates already reported
            $DepPkgFound = $FinalPkgs | Where-Object { $_.PackageName -like "*$DepPfx*" } |
                Select-Object -First 1
            if ($null -eq $DepPkgFound) {
                # Not in the provisioned store. Framework packages shipped with Windows or
                # registered as side-effects of provisioning an app do not always appear in
                # Get-AppxProvisionedPackage -- they live in the all-users AppX package store
                # (C:\Program Files\WindowsApps\) and are found there instead. Check there
                # before reporting a warning. This is the normal outcome when all apps succeed
                # on the first provisioning attempt (DISM satisfied deps from the OS baseline).
                $WinAppsDir  = Join-Path $env:ProgramFiles 'WindowsApps'
                $DepFolder   = Get-ChildItem -Path $WinAppsDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "$DepPfx*" } | Select-Object -First 1
                if ($null -ne $DepFolder) {
                    $DepFolderVer = Get-PackageFileVersion $DepFolder.Name
                    Write-Log ("  OK    {0,-52} v{1} (WindowsApps)" -f $DepPfx, $DepFolderVer)
                }
                else {
                    Write-Log ("  WARN  {0}" -f $DepPfx)
                    Write-Log "        not found in provisioned store or WindowsApps -- apps that depend on it may fail to register at logon"
                    $HealthIssues.Add("Framework dep not available: $DepPfx")
                }
            }
            else {
                $DepPkgVer = Get-PackageFileVersion $DepPkgFound.PackageName
                Write-Log ("  OK    {0,-52} v{1}" -f $DepPfx, $DepPkgVer)
            }
    }
}
else {
    Write-Log "  (no shared framework dependencies -- skipping dep check)"
}

Write-Log ""
if ($HealthIssues.Count -eq 0) {
    Write-Log "Health        : PASS -- all packages verified, no issues found"
}
else {
    Write-Log "Health        : FAIL -- $($HealthIssues.Count) issue(s) detected:"
    $HealthIssues | ForEach-Object { Write-Log "  - $_" }
}

Write-Log ""
Write-Log "=== Final Provisioned Packages ==="
$FinalPkgs | Sort-Object PackageName | ForEach-Object { Write-Log "  $($_.PackageName)" }

if ($ErrorCount -gt 0 -or $HealthIssues.Count -gt 0) {
    exit 1
}
exit 0
