param (
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$SoftwareName = 'PowerShell 7'
$Script:Name = 'Deploy-PowerShell7'
#endregion

#region Supporting Functions
function Split-ExecutableCommandLine {
    param ([Parameter(Mandatory = $true)][string]$CommandLine)
    if ($CommandLine -notmatch '^\s*"([^"]+\.exe)"\s*(.*)$' -and $CommandLine -notmatch '^\s*(.+?\.exe)\s+(.*)$') {
        throw 'Could not parse the executable command line.'
    }
    [pscustomobject]@{ FilePath = $Matches[1]; ArgumentList = $Matches[2] }
}

function Invoke-ApplicationProcess {
    param (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
    # Windows PowerShell needs a retained handle to read ExitCode after WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "$Action timed out." }
    if ($null -eq $process.ExitCode) { throw "$Action did not report an exit code." }
    if ($SuccessExitCodes.Count -gt 0 -and $process.ExitCode -notin $SuccessExitCodes) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }
    return $process
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Category = 'Info'
    )
    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if ($env:SUPPRESS_FILELOG -ne '1') {
        Add-Content -LiteralPath $script:Log -Value $content -ErrorAction Stop
    }
    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    param (
        [Parameter(Position = 0)][string]$Path,
        [string]$Name = 'Artifact',
        [string]$FilePath
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    if ($FilePath) {
        $script:Log = $FilePath
        $Path = Split-Path $FilePath -Parent
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A log directory or FilePath is required.' }
        $script:Log = Join-Path $Path "$Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    }
    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Add-Content -LiteralPath $script:Log -Value "Date`t`t`tCategory`t`tDetails" -ErrorAction Stop
}

function Invoke-MsiProcess {
    param (
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int]$TimeoutMs = 600000,
        [int]$MaxAttempts = 11,
        [int]$RetryDelaySeconds = 30
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $process = Invoke-ApplicationProcess -FilePath 'msiexec.exe' -ArgumentList $ArgumentList `
            -Action $Action -TimeoutMs $TimeoutMs -SuccessExitCodes @()
        if ($process.ExitCode -ne 1618) { return $process }
        if ($attempt -eq $MaxAttempts) {
            throw "$Action failed after $MaxAttempts attempts with exit code 1618 (another installation is already in progress)."
        }
        Write-Log -Category Warning -Message "$Action returned exit code 1618. Retrying in $RetryDelaySeconds seconds (attempt $attempt of $MaxAttempts)."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Remove-MsiApplications {
    param (
        [object[]]$Applications = @(),
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000,
        [switch]$AllowMultiple,
        [switch]$VerifyRemoval,
        [string]$ArgumentListFormat = '/x {0} /qn /norestart'
    )
    if ($Applications.Count -eq 0) {
        Write-Log -Message 'No matching MSI installation was found.'
        return
    }
    if (-not $AllowMultiple -and $Applications.Count -gt 1) {
        $matchesText = ($Applications | ForEach-Object { "$($_.DisplayName) [$($_.ProductCode)]" }) -join ', '
        throw "Multiple MSI installations matched: $matchesText"
    }
    if ($AllowMultiple) { $Applications = @($Applications | Sort-Object ProductCode -Unique) }
    if (-not $ArgumentListFormat.Contains('{0}')) { throw 'MSI uninstall arguments must include the {0} ProductCode placeholder.' }
    foreach ($installedApplication in $Applications) {
        if ($installedApplication.ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
            throw "A valid MSI ProductCode is required to remove '$($installedApplication.DisplayName)'."
        }
        Write-Log -Message "Removing '$($installedApplication.DisplayName)' with ProductCode '$($installedApplication.ProductCode)'."
        $uninstaller = Invoke-MsiProcess -ArgumentList ($ArgumentListFormat -f $installedApplication.ProductCode) `
            -Action "'$($installedApplication.DisplayName)' uninstaller" -TimeoutMs $TimeoutMs
        if ($uninstaller.ExitCode -notin $SuccessExitCodes) {
            throw "'$($installedApplication.DisplayName)' uninstaller failed with exit code $($uninstaller.ExitCode)."
        }
        if ($uninstaller.ExitCode -eq 3010) { Write-Log -Category Warning -Message 'MSI removal requires a reboot.' }
        if ($VerifyRemoval) {
            if ([string]::IsNullOrWhiteSpace($installedApplication.RegistryPath)) {
                throw 'RegistryPath is required to verify MSI removal.'
            }
            if (Test-Path -LiteralPath $installedApplication.RegistryPath) {
                throw "MSI registration remains after removal: '$($installedApplication.ProductCode)'."
            }
        }
        Write-Log -Message "'$($installedApplication.DisplayName)' uninstall completed successfully."
    }
}

function Remove-AppxApplications {
    param ([Parameter(Mandatory = $true)][string[]]$Name)
    $packages = @(Get-InstalledAppxPackages -Name $Name | Sort-Object -Property @{ Expression = 'IsBundle'; Descending = $true })
    foreach ($package in $packages) {
        if (@(Get-InstalledAppxPackages -Name $Name | Where-Object PackageFullName -eq $package.PackageFullName).Count -gt 0) {
            Write-Log -Message "Removing registered package '$($package.PackageFullName)' for all users."
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        }
    }
    foreach ($package in @(Get-ProvisionedAppxPackages -Name $Name)) {
        Write-Log -Message "Removing provisioned package '$($package.PackageName)'."
        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
    }
    if (@(Get-InstalledAppxPackages -Name $Name).Count -gt 0 -or @(Get-ProvisionedAppxPackages -Name $Name).Count -gt 0) {
        throw "AppX registrations remain after removal for: $($Name -join ', ')."
    }
}

function Get-InstalledApplications {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Publisher = '*',
        [string[]]$RegistryPaths = @(
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        ),
        [string]$ProductCodePattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$',
        [switch]$RegEx,
        [switch]$WindowsInstaller
    )
    foreach ($registryPath in $RegistryPaths) {
        if (Test-Path -LiteralPath $registryPath) {
            Get-ChildItem -LiteralPath $registryPath -ErrorAction Stop | ForEach-Object {
                $application = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                $isWindowsInstaller = $application.WindowsInstaller -eq 1
                $productCode = if ($isWindowsInstaller -and $_.PSChildName -match $ProductCodePattern) { $_.PSChildName } else { '' }
                $nameMatches = if ($RegEx) { $application.DisplayName -match $Name } else { $application.DisplayName -like $Name }
                if ($nameMatches -and ($Publisher -eq '*' -or $application.Publisher -like $Publisher) -and
                    (-not $WindowsInstaller -or $productCode)) {
                    [pscustomobject]@{
                        DisplayName = $application.DisplayName
                        DisplayVersion = $application.DisplayVersion
                        Publisher = $application.Publisher
                        InstallLocation = $application.InstallLocation
                        ProductCode = $productCode
                        WindowsInstaller = $isWindowsInstaller
                        RegistryPath = $_.PSPath
                        QuietUninstallString = $application.QuietUninstallString
                        BundleCachePath = $application.BundleCachePath
                    }
                }
            }
        }
    }
}

function Get-InstalledAppxPackages {
    param ([Parameter(Mandatory = $true)][string[]]$Name)
    Get-AppxPackage -AllUsers -PackageTypeFilter Bundle, Main -ErrorAction Stop |
        Where-Object { $_.Name -in $Name }
}

function Get-ProvisionedAppxPackages {
    param ([Parameter(Mandatory = $true)][string[]]$Name)
    Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Where-Object { $_.DisplayName -in $Name }
}

function Assert-DeploymentHost {
    param ([string[]]$RequiredCommands = @())
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
        throw 'Run this artifact with 64-bit Windows PowerShell 5.1.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'An elevated administrator or SYSTEM context is required.'
    }
    foreach ($command in $RequiredCommands) {
        Get-Command -Name $command -ErrorAction Stop | Out-Null
    }
}

function Assert-NoRunningProcesses {
    param ([Parameter(Mandatory = $true)][string[]]$Name)
    $processes = @(Get-Process -ErrorAction Stop | Where-Object ProcessName -in $Name)
    if ($processes.Count -gt 0) {
        throw "Application processes are running (PID(s): $($processes.Id -join ', ')). Close these sessions before installation or removal; no processes were terminated."
    }
}

function Assert-SafeDirectory {
    param ([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing a directory with a reparse-point ancestor: '$Path'."
        }
        $item = $item.Parent
    }
    if (@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) {
        throw "Refusing a directory containing reparse points: '$Path'."
    }
}

function Get-ApplicationDirectories {
    param (
        [Parameter(Mandatory = $true)][string[]]$RootPath,
        [Parameter(Mandatory = $true)][string]$DirectoryNamePattern,
        [Parameter(Mandatory = $true)][string]$ExecutableName,
        [Parameter(Mandatory = $true)][int]$MajorVersion,
        [Parameter(Mandatory = $true)][string]$Publisher
    )
    foreach ($parent in $RootPath) {
        if (Test-Path -LiteralPath $parent -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop |
                    Where-Object Name -Match $DirectoryNamePattern)) {
                $executable = Join-Path $directory.FullName $ExecutableName
                if (Test-Path -LiteralPath $executable -PathType Leaf) {
                    $version = (Get-Item -LiteralPath $executable -ErrorAction Stop).VersionInfo
                    if ($version.FileMajorPart -ne $MajorVersion -or $version.CompanyName -ne $Publisher) {
                        throw "Unrecognized executable in '$($directory.FullName)'; refusing to remove this directory."
                    }
                    $directory.FullName
                }
            }
        }
    }
}

function Set-MachinePath {
    param ([string[]]$RemovePaths = @(), [string]$AddPath)
    $entries = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -notin $RemovePaths
            }
    )
    if (-not [string]::IsNullOrWhiteSpace($AddPath)) {
        $normalizedAddPath = [Environment]::ExpandEnvironmentVariables($AddPath).TrimEnd('\')
        if ($normalizedAddPath -notin @($entries | ForEach-Object {
            [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
        })) {
            $entries = @($AddPath) + $entries
        }
    }
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Machine')
}

function Invoke-RegistrationScript {
    param (
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [hashtable]$Parameters = @{},
        [switch]$AllowMissing
    )
    if (Test-Path -LiteralPath $ScriptPath -PathType Leaf) {
        & $ScriptPath @Parameters -ErrorAction Stop
    }
    elseif (-not $AllowMissing) {
        throw "Registration script is missing: '$ScriptPath'."
    }
}

function Test-ApplicationPayload {
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RequiredFiles,
        [Parameter(Mandatory = $true)][string]$ExecutableName,
        [Parameter(Mandatory = $true)][string]$SignerSubjectPattern,
        [Parameter(Mandatory = $true)][string]$ValidationArguments,
        [int]$TimeoutMs = 60000
    )
    Assert-SafeDirectory -Path $Path
    foreach ($name in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $name) -PathType Leaf)) {
            throw "Application payload is missing '$name'."
        }
    }
    $executable = Join-Path $Path $ExecutableName
    $signature = Get-AuthenticodeSignature -LiteralPath $executable -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $SignerSubjectPattern) {
        throw "The staged '$ExecutableName' must have a valid signature matching '$SignerSubjectPattern'."
    }
    $process = Start-Process -FilePath $executable -ArgumentList $ValidationArguments -PassThru -NoNewWindow
    # Windows PowerShell needs a retained handle to read ExitCode after WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMs)) {
        $process.Kill()
        throw 'The staged application smoke test timed out.'
    }
    if ($null -eq $process.ExitCode) {
        throw 'The staged application smoke test did not report an exit code.'
    }
    if ($process.ExitCode -ne 0) {
        throw "The staged application smoke test failed (exit code $($process.ExitCode))."
    }
}

function New-ApplicationShortcut {
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$Arguments,
        [string]$Description
    )
    $shortcutDirectory = Split-Path $Path -Parent
    New-Item -Path $shortcutDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Arguments = $Arguments
    $shortcut.Description = $Description
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Save()
}

function Register-InstalledApplication {
    param (
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$Publisher,
        [Parameter(Mandatory = $true)][string]$InstallLocation,
        [Parameter(Mandatory = $true)][string]$DisplayIcon,
        [Parameter(Mandatory = $true)][string]$UninstallString
    )
    New-Item -Path $RegistryPath -Force -ErrorAction Stop | Out-Null
    $properties = @{
        DisplayName = $DisplayName
        DisplayVersion = $DisplayVersion
        Publisher = $Publisher
        InstallLocation = $InstallLocation
        DisplayIcon = $DisplayIcon
        UninstallString = $UninstallString
        QuietUninstallString = $UninstallString
    }
    foreach ($name in $properties.Keys) {
        New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value $properties[$name] -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
    foreach ($name in @('NoModify', 'NoRepair')) {
        New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }
}

#endregion

## MAIN

$ErrorActionPreference = 'Stop'
Assert-DeploymentHost -RequiredCommands @('Get-AppxPackage', 'Remove-AppxPackage', 'Get-AppxProvisionedPackage', 'Remove-AppxProvisionedPackage')
$sourcePath = $PSCommandPath
$packageRoot = $PSScriptRoot
$installPath = Join-Path $env:ProgramFiles 'PowerShell\7'
$shortcutPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PowerShell 7.lnk'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PowerShell7.Zip'
$directoryRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique |
    ForEach-Object { Join-Path $_ 'PowerShell' }
$appxNames = @('Microsoft.PowerShell', 'Microsoft.PowerShellPreview')
$stagingPath = $null
New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Deploy-PowerShell7'
Write-Log -Category Info -Message "Starting '$PSCommandPath'."

try {
    if ($DeploymentType -eq 'Install') {
        $archives = @(Get-ChildItem -LiteralPath $packageRoot -Filter '*.zip' -File -ErrorAction Stop)
        if ($archives.Count -ne 1) {
            throw "Expected one PowerShell x64 ZIP in '$packageRoot'; found $($archives.Count)."
        }
        $stagingPath = Join-Path ([IO.Path]::GetTempPath()) "PowerShell7-$([guid]::NewGuid())"
        Expand-Archive -LiteralPath $archives[0].FullName -DestinationPath $stagingPath -ErrorAction Stop
        Test-ApplicationPayload -Path $stagingPath -ExecutableName 'pwsh.exe' `
            -RequiredFiles @('pwsh.exe', 'pwsh.deps.json', 'pwsh.runtimeconfig.json', 'System.Management.Automation.dll',
                'RegisterManifest.ps1', 'PowerShell.Core.Instrumentation.man', 'PowerShell.Core.Instrumentation.dll') `
            -SignerSubjectPattern '(^|, )CN=Microsoft Corporation(,|$)' `
            -ValidationArguments '-NoLogo -NoProfile -NonInteractive -Command "if ($PSVersionTable.PSVersion.Major -ne 7 -or $PSVersionTable.PSVersion.PreReleaseLabel -or -not [Environment]::Is64BitProcess) { exit 1 }"'
    }

    Assert-NoRunningProcesses -Name 'pwsh'
    $zipDirectories = @(Get-ApplicationDirectories -RootPath $directoryRoots -DirectoryNamePattern '^7(?:[-.].*)?$' `
        -ExecutableName 'pwsh.exe' -MajorVersion 7 -Publisher 'Microsoft Corporation')
    foreach ($directory in $zipDirectories) {
        Assert-SafeDirectory -Path $directory
    }
    $bundleApplications = @(Get-InstalledApplications -Name '^PowerShell 7(?:\D|$)' -RegEx -Publisher 'Microsoft*' |
        Where-Object { $_.BundleCachePath -and -not $_.WindowsInstaller })
    foreach ($application in $bundleApplications) {
        if (-not (Test-Path -LiteralPath $application.RegistryPath)) { continue }
        if ([string]::IsNullOrWhiteSpace($application.QuietUninstallString)) {
            throw "A registered quiet uninstall command is required to remove '$($application.DisplayName)'."
        }
        $command = Split-ExecutableCommandLine -CommandLine $application.QuietUninstallString
        if ($command.FilePath -ne $application.BundleCachePath -or
            [IO.Path]::GetExtension($command.FilePath) -ne '.exe' -or
            -not (Test-Path -LiteralPath $command.FilePath -PathType Leaf)) {
            throw "The registered bundle uninstaller is missing or does not match BundleCachePath for '$($application.DisplayName)'."
        }
        Write-Log -Message "Removing '$($application.DisplayName)' with its registered bundle uninstaller."
        $uninstaller = Invoke-ApplicationProcess -FilePath $command.FilePath `
            -ArgumentList "$($command.ArgumentList) /norestart" -Action "'$($application.DisplayName)' bundle uninstaller" `
            -SuccessExitCodes $SuccessExitCodes
        if ($uninstaller.ExitCode -eq 3010) { Write-Log -Category Warning -Message 'Bundle removal requires a reboot.' }
        if (Test-Path -LiteralPath $application.RegistryPath) {
            throw "Bundle registration remains after removal: '$($application.DisplayName)'."
        }
    }
    $msiApplications = @(Get-InstalledApplications -Name '^PowerShell 7(?:\D|$)' -RegEx -Publisher 'Microsoft*' -WindowsInstaller)
    Remove-MsiApplications -Applications $msiApplications -SuccessExitCodes $SuccessExitCodes -AllowMultiple -VerifyRemoval
    Remove-AppxApplications -Name $appxNames
    foreach ($directory in $zipDirectories) {
        if (Test-Path -LiteralPath (Join-Path $directory 'pwsh.exe') -PathType Leaf) {
            Invoke-RegistrationScript -ScriptPath (Join-Path $directory 'RegisterManifest.ps1') `
                -Parameters @{ Path = $directory; Unregister = $true } -AllowMissing
            Write-Log -Category Warning -Message "Removing PowerShell directory '$directory', including any machine-wide profiles or modules stored inside it."
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
        }
    }
    $removePaths = @($zipDirectories + $installPath | Sort-Object -Unique)
    if ($DeploymentType -eq 'Install') {
        $removePaths = @($removePaths | Where-Object { $_ -ne $installPath })
    }
    Set-MachinePath -RemovePaths $removePaths
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $uninstallKey) {
        Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction Stop
    }
    Write-Log -Message 'PowerShell 7 stable and preview removal completed. Windows PowerShell 5.1 is unchanged.'

    if ($DeploymentType -eq 'Install') {
        if (Test-Path -LiteralPath $installPath) {
            if (@(Get-ChildItem -LiteralPath $installPath -Force -ErrorAction Stop).Count -gt 0) {
                throw "Residual files remain in '$installPath'. Back up and relocate them before installing; no new files were mixed into the old installation."
            }
            Assert-SafeDirectory -Path $installPath
            Remove-Item -LiteralPath $installPath -Force -ErrorAction Stop
        }
        # A fresh destination inherits Program Files ACLs instead of retaining Temp permissions.
        New-Item -Path $installPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Get-ChildItem -LiteralPath $stagingPath -Force -ErrorAction Stop |
            Copy-Item -Destination $installPath -Recurse -Force -ErrorAction Stop
        Invoke-RegistrationScript -ScriptPath (Join-Path $installPath 'RegisterManifest.ps1') -Parameters @{ Path = $installPath }
        Set-MachinePath -AddPath $installPath
        $executable = Join-Path $installPath 'pwsh.exe'
        New-ApplicationShortcut -Path $shortcutPath -TargetPath $executable -WorkingDirectory $installPath `
            -Arguments '-WorkingDirectory ~' -Description $SoftwareName
        $uninstaller = Join-Path $installPath 'Deploy-PowerShell7.ps1'
        Copy-Item -LiteralPath $sourcePath -Destination $uninstaller -Force -ErrorAction Stop
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uninstallCommand = "`"$windowsPowerShell`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$uninstaller`" -DeploymentType Uninstall"
        Register-InstalledApplication -RegistryPath $uninstallKey -DisplayName 'PowerShell 7 (x64, ZIP)' `
            -DisplayVersion (Get-Item -LiteralPath $executable).VersionInfo.ProductVersion -Publisher 'Microsoft Corporation' `
            -InstallLocation $installPath -DisplayIcon "$executable,0" -UninstallString $uninstallCommand
        Write-Log -Message "Installed stable x64 PowerShell 7 to '$installPath'. New processes/sign-ins will see the machine PATH update."
    }
}
finally {
    if ($stagingPath -and (Test-Path -LiteralPath $stagingPath)) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction Stop
    }
}

Write-Log -Category Info -message "Completed '$SoftwareName' $DeploymentType."
exit 0