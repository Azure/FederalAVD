<#
.SYNOPSIS
    Installs the WSL 2 platform or prepares one Linux distribution for all users.

.DESCRIPTION
    This artifact is intentionally run twice during an image build. The EnablePlatform phase
    installs the current Microsoft WSL MSI and enables the Windows optional features required
    by WSL 2. The image build must restart after that phase. The ProvisionDistribution phase
    either provisions one staged distribution AppX/AppxBundle for every user or stages a Rocky
    Linux WSL image for automatic per-user registration. It also configures WSL 2 as the default
    for new user profiles.

    Distribution registration and initialization remain Windows-user-specific actions.

.NOTES
    Run as Administrator or SYSTEM. This script is ASCII-only because it can be embedded in ARM.
#>

[CmdletBinding()]
param(
    [ValidateSet('EnablePlatform', 'ProvisionDistribution')]
    [string]$Phase = 'EnablePlatform',

    [ValidateSet('Ubuntu-24.04', 'Ubuntu-22.04', 'Debian', 'Kali-Linux', 'Rocky-Linux-9')]
    [string]$Distribution = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$Script:Name = 'Install-MicrosoftWSL2'
$Script:Log = $null

function New-Log {
    $logDirectory = Join-Path -Path $env:SystemRoot -ChildPath 'Logs\Software'
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    $Script:Log = Join-Path -Path $logDirectory -ChildPath "$Script:Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
}

function Write-Log {
    param(
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Category = 'Info',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t$Message"
    if ($Script:Log) {
        Add-Content -LiteralPath $Script:Log -Value $content -ErrorAction SilentlyContinue
    }
    Write-Output $content
}

function Assert-SupportedHost {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM privileges are required.'
    }

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'WSL 2 requires a 64-bit operating system.'
    }

    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        throw "Windows build $build is unsupported. WSL 2 requires build 19041 or later for this artifact."
    }
}

function Invoke-Process {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [int[]]$SuccessExitCodes = @(0, 3010),

        [int]$TimeoutMilliseconds = 1800000
    )

    Write-Log -Message "$Action command: $FilePath $ArgumentList"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $process.Kill()
        throw "$Action timed out after $($TimeoutMilliseconds / 60000) minutes."
    }
    if ($process.ExitCode -notin $SuccessExitCodes) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }

    Write-Log -Message "$Action completed with exit code $($process.ExitCode)."
}

function Get-AppxIdentityName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $manifestEntry = $archive.Entries | Where-Object {
            $_.FullName -match '(^|/)Appx(Bundle)?Manifest\.xml$'
        } | Select-Object -First 1
        if (-not $manifestEntry) {
            throw "No AppX manifest was found in '$PackagePath'."
        }

        $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
        try {
            [xml]$manifest = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $identity = $manifest.DocumentElement.SelectSingleNode('*[local-name()="Identity"]')
        $identityName = if ($identity) { $identity.GetAttribute('Name') } else { $null }
        if ([string]::IsNullOrWhiteSpace($identityName)) {
            throw "The AppX manifest in '$PackagePath' does not contain an identity name."
        }
        return [string]$identityName
    }
    finally {
        $archive.Dispose()
    }
}

function Enable-WSLPlatform {
    $installer = Join-Path -Path $PSScriptRoot -ChildPath 'WSL-x64.msi'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Required WSL installer was not found: $installer"
    }

    foreach ($featureName in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
        if ($feature.State -eq 'Enabled') {
            Write-Log -Message "Windows optional feature '$featureName' is already enabled."
            continue
        }

        Write-Log -Message "Enabling Windows optional feature '$featureName' without restarting."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart
        Write-Log -Message "Feature '$featureName' state is '$($result.State)'; restart needed: $($result.RestartNeeded)."
    }

    Invoke-Process `
        -FilePath 'msiexec.exe' `
        -ArgumentList "/i `"$installer`" /quiet /qn /norestart" `
        -Action 'Install Microsoft WSL' `
        -SuccessExitCodes @(0, 1638, 3010)

    if (-not (Get-Command -Name 'wsl.exe' -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found after the Microsoft WSL installation.'
    }

    Write-Log -Message 'EnablePlatform completed. The image build customization must specify restart=true.'
}

function Set-WSL2UserDefault {
    # Stable, artifact-specific Active Setup component ID generated for Microsoft-WSL2 v1.
    $activeSetupPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{882E5A8C-CC7D-43B5-AB9D-2EF10E6859D2}'
    $stubPath = 'reg.exe ADD "HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss" /v DefaultVersion /t REG_DWORD /d 2 /f'

    New-Item -Path $activeSetupPath -Force | Out-Null
    Set-Item -Path $activeSetupPath -Value 'Configure WSL 2 default version'
    New-ItemProperty -Path $activeSetupPath -Name 'Version' -Value '1,0,0,0' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $activeSetupPath -Name 'IsInstalled' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $activeSetupPath -Name 'StubPath' -Value $stubPath -PropertyType String -Force | Out-Null

    Write-Log -Message 'Configured Active Setup to set WSL 2 as the default for each Windows user.'
}

function Set-WSLFileUserBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootstrapPath,

        [Parameter(Mandatory = $true)]
        [string]$DistributionName
    )

    # Stable, artifact-specific Active Setup component ID generated for WSL file registration v1.
    $activeSetupPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{CB23A9AC-6072-4DA4-96CF-91100CF5A176}'
    $stubPath = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BootstrapPath`""

    New-Item -Path $activeSetupPath -Force | Out-Null
    Set-Item -Path $activeSetupPath -Value "Register $DistributionName for the current user"
    New-ItemProperty -Path $activeSetupPath -Name 'Version' -Value '1,1,0,0' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $activeSetupPath -Name 'IsInstalled' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $activeSetupPath -Name 'StubPath' -Value $stubPath -PropertyType String -Force | Out-Null

    Write-Log -Message "Configured Active Setup to register '$DistributionName' for each Windows user."
}

function Install-WSLFileDistribution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$PackageDirectory
    )

    $packages = @(Get-ChildItem -LiteralPath $PackageDirectory -Filter '*.wsl' -File -ErrorAction SilentlyContinue)
    if ($packages.Count -ne 1) {
        throw "Expected exactly one WSL image in '$PackageDirectory', found $($packages.Count)."
    }

    $stagingDirectory = Join-Path -Path $env:ProgramData -ChildPath "WSL\$Name"
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null
    Invoke-Process `
        -FilePath 'icacls.exe' `
        -ArgumentList "`"$stagingDirectory`" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX" `
        -Action "Secure the $Name staging directory" `
        -SuccessExitCodes @(0)

    $stagedImagePath = Join-Path -Path $stagingDirectory -ChildPath 'Distribution.wsl'
    Copy-Item -LiteralPath $packages[0].FullName -Destination $stagedImagePath -Force

    $bootstrapPath = Join-Path -Path $stagingDirectory -ChildPath 'Register-Distribution.ps1'
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$distributionName = '__DISTRIBUTION_NAME__'
$imagePath = Join-Path -Path $env:ProgramData -ChildPath 'WSL\__DISTRIBUTION_NAME__\Distribution.wsl'
$logDirectory = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'FederalAVD\Logs'
$logPath = Join-Path -Path $logDirectory -ChildPath 'Register-Rocky-Linux-9.log'
$runPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'FederalAVD-Rocky-Linux-9'
$retryCommand = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""

try {
    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 's')] Starting per-user WSL registration."

    $lxssPath = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss'
    New-Item -Path $lxssPath -Force | Out-Null
    New-ItemProperty -Path $lxssPath -Name 'DefaultVersion' -Value 2 -PropertyType DWord -Force | Out-Null

    $wslPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wslPath -PathType Leaf)) {
        throw "wsl.exe was not found at '$wslPath'."
    }
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw "The staged Rocky Linux image was not found at '$imagePath'."
    }

    $installedDistributions = @(& $wslPath --list --quiet 2>$null) | ForEach-Object {
        ([string]$_).Replace([char]0, '').Trim()
    } | Where-Object { $_ }

    if ($installedDistributions -notcontains $distributionName) {
        & $wslPath --install --from-file $imagePath --name $distributionName --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "Rocky Linux registration failed with exit code $LASTEXITCODE."
        }
    }

    $installedDistributions = @(& $wslPath --list --quiet 2>$null) | ForEach-Object {
        ([string]$_).Replace([char]0, '').Trim()
    } | Where-Object { $_ }
    if ($installedDistributions -notcontains $distributionName) {
        throw "'$distributionName' was not listed after registration."
    }

    Remove-ItemProperty -Path $runPath -Name $runName -ErrorAction SilentlyContinue
    Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 's')] Registration completed successfully."
    exit 0
}
catch {
    New-Item -Path $runPath -Force | Out-Null
    New-ItemProperty -Path $runPath -Name $runName -Value $retryCommand -PropertyType String -Force | Out-Null
    Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 's')] ERROR: $($_.Exception.Message)"
    exit 1
}
'@
    $bootstrap = $bootstrap.Replace('__DISTRIBUTION_NAME__', $Name)
    Set-Content -LiteralPath $bootstrapPath -Value $bootstrap -Encoding ASCII

    Set-WSLFileUserBootstrap -BootstrapPath $bootstrapPath -DistributionName $Name
    Write-Log -Message "Staged '$Name' for automatic per-user registration from '$($packages[0].Name)'."
}

function Install-WSLDistribution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $featureStates = @(
        Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux'
        Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    )
    $disabledFeatures = @($featureStates | Where-Object { $_.State -ne 'Enabled' })
    if ($disabledFeatures.Count -gt 0) {
        throw 'The WSL optional features are not fully enabled. Run EnablePlatform with restart=true before ProvisionDistribution.'
    }

    $distributionDefinitions = @{
        'Ubuntu-24.04' = @{
            Folder = 'Ubuntu-24.04'
            Type = 'Appx'
        }
        'Ubuntu-22.04' = @{
            Folder = 'Ubuntu-22.04'
            Type = 'Appx'
        }
        'Debian' = @{
            Folder = 'Debian'
            Type = 'Appx'
        }
        'Kali-Linux' = @{
            Folder = 'Kali-Linux'
            Type = 'Appx'
        }
        'Rocky-Linux-9' = @{
            Folder = 'Rocky-Linux-9'
            Type = 'WslFile'
        }
    }

    $definition = $distributionDefinitions[$Name]
    $packageDirectory = Join-Path -Path $PSScriptRoot -ChildPath "DistributionPackages\$($definition.Folder)"
    if ($definition.Type -eq 'WslFile') {
        Install-WSLFileDistribution -Name $Name -PackageDirectory $packageDirectory
        return
    }

    $packages = @(Get-ChildItem -LiteralPath $packageDirectory -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.appx', '.appxbundle', '.msix', '.msixbundle')
    })
    if ($packages.Count -ne 1) {
        throw "Expected exactly one distribution package in '$packageDirectory', found $($packages.Count)."
    }

    $identityName = Get-AppxIdentityName -PackagePath $packages[0].FullName
    Write-Log -Message "Selected distribution package identity: '$identityName'."

    $existing = Get-AppxProvisionedPackage -Online | Where-Object {
        $_.DisplayName -eq $identityName -or $_.PackageName -like "${identityName}_*"
    } | Select-Object -First 1

    if ($existing) {
        Write-Log -Message "Distribution '$Name' is already provisioned as '$($existing.PackageName)'."
    }
    else {
        Write-Log -Message "Provisioning '$Name' for all users from '$($packages[0].Name)'."
        Add-AppxProvisionedPackage `
            -Online `
            -PackagePath $packages[0].FullName `
            -SkipLicense `
            -Regions 'all' | Out-Null

        $existing = Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -eq $identityName -or $_.PackageName -like "${identityName}_*"
        } | Select-Object -First 1
        if (-not $existing) {
            throw "Distribution '$Name' was not found in the provisioned package store after installation."
        }
        Write-Log -Message "Distribution '$Name' provisioned successfully as '$($existing.PackageName)'."
    }

    Set-WSL2UserDefault
    Write-Log -Message 'Each user completes distribution initialization and creates a Linux account on first launch.'
}

New-Log
Write-Log -Message "Starting phase '$Phase' with distribution '$Distribution'."
Assert-SupportedHost

switch ($Phase) {
    'EnablePlatform' {
        Enable-WSLPlatform
    }
    'ProvisionDistribution' {
        Install-WSLDistribution -Name $Distribution
    }
}

Write-Log -Message "Phase '$Phase' completed successfully."
