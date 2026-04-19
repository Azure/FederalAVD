function Write-OutputWithTimeStamp {
    param(
        [parameter(ValueFromPipeline=$True, Mandatory=$True, Position=0)]
        [string]$Message
    )
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $Entry = '[' + $Timestamp + '] ' + $Message
    Write-Output $Entry
}

function Install-DesktopAppInstaller {
    # Downloads and provisions the App Installer package (which contains winget)
    # and its required VCLibs dependency. Runs as SYSTEM via Add-AppxProvisionedPackage.
    # Microsoft.UI.Xaml is assumed present on Windows 11 Multi-Session (inbox).
    $TempDir = Join-Path $env:TEMP 'WingetInstall'
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

    try {
        # VCLibs — required dependency for App Installer
        $VCLibsPath = Join-Path $TempDir 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
        Write-OutputWithTimeStamp "Downloading Microsoft.VCLibs..."
        Invoke-WebRequest -Uri 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' `
            -OutFile $VCLibsPath -UseBasicParsing

        # App Installer (winget) msixbundle
        $AppInstallerPath = Join-Path $TempDir 'Microsoft.DesktopAppInstaller.msixbundle'
        Write-OutputWithTimeStamp "Downloading App Installer (winget)..."
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' `
            -OutFile $AppInstallerPath -UseBasicParsing

        Write-OutputWithTimeStamp "Provisioning App Installer..."
        Add-AppxProvisionedPackage -Online `
            -PackagePath $AppInstallerPath `
            -DependencyPackagePath $VCLibsPath `
            -SkipLicense | Out-Null

        Write-OutputWithTimeStamp "App Installer provisioned successfully."
    } catch {
        Write-Warning "Failed to install App Installer: $_"
        return $false
    } finally {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Find-Winget {
    # winget is not on the system PATH when running as SYSTEM — search WindowsApps directly.
    $OnPath = (Get-Command -Name winget.exe -ErrorAction SilentlyContinue)?.Source
    If ($OnPath) { return $OnPath }

    return Resolve-Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" `
        -ErrorAction SilentlyContinue |
        Sort-Object -Property Path |
        Select-Object -Last 1 -ExpandProperty Path
}

Start-Transcript -Path "$env:SystemRoot\Logs\Update-UwpApps.log" -Force
Write-Output "*********************************"
Write-Output "Updating Built-In UWP Apps via winget"
Write-Output "*********************************"

$WingetPath = Find-Winget

If (-not $WingetPath) {
    Write-OutputWithTimeStamp "winget not found. Attempting to install App Installer..."
    $Installed = Install-DesktopAppInstaller
    If ($Installed) {
        $WingetPath = Find-Winget
    }
}

If (-not $WingetPath) {
    Write-Warning "winget.exe could not be found or installed. Skipping Store app updates."
    Write-OutputWithTimeStamp "This may be expected in air-gapped or restricted network environments."
    Stop-Transcript
    Exit 0
}

Write-OutputWithTimeStamp "Found winget at: $WingetPath"
Write-OutputWithTimeStamp "winget version: $(& $WingetPath --version 2>&1)"

Write-OutputWithTimeStamp "Running winget upgrade for Microsoft Store sourced packages..."
$UpgradeArgs = @(
    'upgrade'
    '--all'
    '--source', 'msstore'
    '--silent'
    '--accept-source-agreements'
    '--accept-package-agreements'
    '--include-unknown'
)

Write-Output "Executing: $WingetPath $($UpgradeArgs -join ' ')"
$Process = Start-Process -FilePath $WingetPath -ArgumentList $UpgradeArgs -Wait -PassThru -NoNewWindow

Write-OutputWithTimeStamp "winget upgrade exited with code: $($Process.ExitCode)"

# winget exit codes:
#   0            = success, all updates applied
#   -1978335189  = no applicable updates found — not an error
If ($Process.ExitCode -eq 0 -or $Process.ExitCode -eq -1978335189) {
    Write-OutputWithTimeStamp "winget upgrade completed successfully."
} Else {
    Write-Warning "winget upgrade returned exit code $($Process.ExitCode). Review the output above for details."
    Write-OutputWithTimeStamp "This may be expected in environments with restricted outbound access to the Microsoft Store CDN."
}

Stop-Transcript
