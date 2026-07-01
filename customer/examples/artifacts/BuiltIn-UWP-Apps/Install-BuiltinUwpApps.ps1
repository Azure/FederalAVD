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

# ----------------------------------------------------------------
# Pre-provision shared framework dependencies.
# Packages in SharedDependencies\ (VCLibs, Windows App Runtime, etc.)
# must be staged as first-class provisioned packages BEFORE the app
# loop. When Add-AppxProvisionedPackage succeeds without explicit
# -DependencyPackagePath, those frameworks are NOT staged -- they are
# only resolved from the running OS at that moment. At user logon,
# AppX tries to register the app, cannot find the required framework
# version in the provisioned store, and fails (e.g. Notepad requires
# Windows App Runtime 1.7 but only 1.6 is staged).
# Pre-provisioning them here ensures they are present for every new
# user profile created from this image, regardless of which apps
# subsequently depend on them.
# ----------------------------------------------------------------
$SharedDepDir = Join-Path -Path $PSScriptRoot -ChildPath 'SharedDependencies'
if (Test-Path $SharedDepDir) {
    $PackageExtensions = @('.msixbundle', '.appxbundle', '.msix', '.appx')
    $SharedDepFiles = Get-ChildItem -Path $SharedDepDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $PackageExtensions }
    if ($SharedDepFiles.Count -gt 0) {
        Write-Log ""
        Write-Log "=== Pre-provisioning $($SharedDepFiles.Count) shared framework package(s) ==="
        foreach ($DepFile in ($SharedDepFiles | Sort-Object Name)) {
            $DepNamePrefix = [System.IO.Path]::GetFileNameWithoutExtension($DepFile.Name) -replace '_[0-9]+(?:\.[0-9]+)+.*$', ''
            $DepVersion    = Get-PackageFileVersion $DepFile.Name
            $AlreadyStaged = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageName -like "*$DepNamePrefix*" } |
                Select-Object -First 1
            if ($null -ne $AlreadyStaged) {
                $StagedVersion = Get-PackageFileVersion $AlreadyStaged.PackageName
                if ($StagedVersion -ge $DepVersion) {
                    Write-Log "SKIP (framework): $($DepFile.Name) -- provisioned version ($StagedVersion) >= staged ($DepVersion)"
                    continue
                }
            }
            try {
                Write-Log "Provisioning framework: $($DepFile.Name)"
                Add-AppxProvisionedPackage -Online -PackagePath $DepFile.FullName -SkipLicense -Regions 'all' | Out-Null
                Write-Log "OK: $($DepFile.Name)"
            }
            catch {
                # Single-arch framework packages (.appx, not .msixbundle) can fail with
                # 'Element not found' (0x80070490) when DISM cannot auto-resolve their own
                # dependencies from the running OS store. Retry with all peer shared-dep
                # packages passed explicitly as -DependencyPackagePath.
                Write-Log "First attempt failed for '$($DepFile.Name)': $_ -- retrying with peer shared dependencies."
                $PeerDeps = @($SharedDepFiles | Where-Object { $_.FullName -ne $DepFile.FullName })
                if ($PeerDeps.Count -gt 0) {
                    try {
                        Add-AppxProvisionedPackage -Online -PackagePath $DepFile.FullName `
                            -DependencyPackagePath ($PeerDeps | Select-Object -ExpandProperty FullName) `
                            -SkipLicense -Regions 'all' | Out-Null
                        Write-Log "OK: $($DepFile.Name) (with explicit peer dependencies)"
                    }
                    catch {
                        Write-Log "WARNING: Could not pre-provision framework '$($DepFile.Name)': $_ -- apps that depend on it may fail to register at logon."
                    }
                }
                else {
                    Write-Log "WARNING: Could not pre-provision framework '$($DepFile.Name)': $_ -- apps that depend on it may fail to register at logon."
                }
            }
        }
    }
    else {
        Write-Log "SharedDependencies folder is empty -- skipping framework pre-provisioning."
    }
}
else {
    Write-Log "No SharedDependencies folder found -- skipping framework pre-provisioning."
}

$SuccessCount = 0
$SkipCount    = 0
$ErrorCount   = 0

# Track per-app before/after for the change summary.
$ChangeLog = [System.Collections.Generic.List[PSCustomObject]]::new()

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

    # ----------------------------------------------------------------
    # Locate dependency packages.
    # The staging pipeline deduplicates shared framework packages
    # (VCLibs, WinAppSDK, etc.) into a sibling SharedDependencies\
    # folder at the builtin-uwp-apps root so they are stored once
    # instead of once per app. Per-app Dependencies\ folders may still
    # exist for packages unique to a single app.
    # Both locations are searched; where the same package family
    # appears in both, the highest version wins.
    # ----------------------------------------------------------------
    $DepCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    # Per-app dependencies
    Get-ChildItem -Path $AppFolder.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in $PackageExtensions -and
            $_.FullName  -match '(?i)\\dependencies\\' -and
            $_.Name      -match '(?i)_(x64|neutral)[._]'
        } |
        ForEach-Object { $DepCandidates.Add($_) }

    # Shared dependencies (dedup pool at the parent root)
    $SharedDepDir = Join-Path -Path $PSScriptRoot -ChildPath 'SharedDependencies'
    if (Test-Path -Path $SharedDepDir) {
        Get-ChildItem -Path $SharedDepDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in $PackageExtensions -and
                $_.Name      -match '(?i)_(x64|neutral)[._]'
            } |
            ForEach-Object { $DepCandidates.Add($_) }
    }

    # Deduplicate by base name (strip version), keep highest version
    $DepPackages = @(
        $DepCandidates |
            Group-Object { $_.Name -replace '_[0-9]+(?:\.[0-9]+){1,3}(?=_)', '' } |
            ForEach-Object {
                $_.Group |
                    Sort-Object { Get-PackageFileVersion $_.Name } -Descending |
                    Select-Object -First 1
            } |
            Sort-Object FullName
    )

    if ($DepPackages.Count -gt 0) {
        Write-Log "Dependencies : $($DepPackages.Count) package(s) (x64 + neutral, deduplicated)"
        $DepPackages | ForEach-Object { Write-Log "  $($_.Name)" }
    }
    else {
        Write-Log "Dependencies : none"
    }

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

if ($ErrorCount -gt 0) {
    exit 1
}
exit 0
