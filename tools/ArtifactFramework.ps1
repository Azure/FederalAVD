# Authoring source only. Installer packages embed the helpers they use.

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

function Get-SingleFile {
    param (
        [Parameter(Mandatory = $true)][Alias('Root')][string]$Path,
        [Parameter(Mandatory = $true)][string]$Filter,
        [string]$Description = 'file',
        [switch]$Recurse
    )
    $files = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse:$Recurse -ErrorAction Stop)
    if ($files.Count -ne 1) {
        throw "Expected exactly one $Description matching '$Filter' in '$Path'; found $($files.Count)."
    }
    return $files[0]
}

function Get-InternetFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][uri]$Url,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string]$OutputFileName
    )
    if (-not $OutputFileName) { $OutputFileName = [IO.Path]::GetFileName($Url.AbsolutePath) }
    if ([string]::IsNullOrWhiteSpace($OutputFileName)) { throw 'An output filename is required for this URL.' }
    New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $outputFile = Join-Path $OutputDirectory $OutputFileName
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($Url, $outputFile) }
    finally { $client.Dispose() }
    if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) { throw "Download did not create '$outputFile'." }
    return $outputFile
}

function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][Alias('Key')][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [Alias('Type')][Microsoft.Win32.RegistryValueKind]$PropertyType = 'String'
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force -ErrorAction Stop | Out-Null
}

function Assert-SupportedHost {
    param (
        [int]$MinimumBuild = 0,
        [switch]$ClientOnly
    )
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM privileges are required.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows operating system is required.' }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt $MinimumBuild) { throw "Windows build $build is unsupported; build $MinimumBuild or later is required." }
    if ($ClientOnly) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $edition = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID
        if ([int]$os.ProductType -ne 1 -and -not ([int]$os.ProductType -eq 3 -and $edition -eq 'ServerRdsh')) {
            throw "Windows client or Enterprise multi-session is required; detected '$($os.Caption)' (EditionID '$edition')."
        }
        Write-Log -Message "Detected '$($os.Caption)' (EditionID '$edition') build $build."
    }
}

function Get-InstallerFile {
    param (
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$DownloadUrl,
        [Parameter(Mandatory = $true)][string]$DownloadDirectory
    )
    $installer = Get-ChildItem -LiteralPath $Directory -Filter $FileName -File -ErrorAction Stop | Select-Object -First 1
    if ($installer) {
        Write-Log -Message "Using pre-staged installer: '$($installer.FullName)'."
        return $installer.FullName
    }
    $downloadPath = Join-Path $DownloadDirectory $FileName
    Write-Log -Message "No local '$FileName' found in '$Directory'. Downloading from '$DownloadUrl'..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($DownloadUrl, $downloadPath) }
    finally { $client.Dispose() }
    Write-Log -Message "Downloaded to '$downloadPath' ($('{0:N1}' -f ((Get-Item $downloadPath).Length / 1MB)) MB)."
    return $downloadPath
}

function Split-ExecutableCommandLine {
    param ([Parameter(Mandatory = $true)][string]$CommandLine)
    if ($CommandLine -notmatch '^\s*"([^"]+\.exe)"\s*(.*)$' -and $CommandLine -notmatch '^\s*(.+?\.exe)\s+(.*)$') {
        throw 'Could not parse the executable command line.'
    }
    [pscustomobject]@{ FilePath = $Matches[1]; ArgumentList = $Matches[2] }
}
