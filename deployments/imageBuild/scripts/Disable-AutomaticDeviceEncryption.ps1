$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Disable-AutomaticDeviceEncryption.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

function Write-BitLockerVolumeState {
    param(
        [Parameter(Mandatory = $true)]
        $Volume
    )

    $KeyProtectorTypes = @(
        $Volume.KeyProtector |
            ForEach-Object { [string]$_.KeyProtectorType } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $KeyProtectorSummary = if ($KeyProtectorTypes.Count -gt 0) {
        $KeyProtectorTypes -join ', '
    }
    else {
        'None'
    }

    Write-Log ("BitLocker state: mount point {0}, volume status {1}, protection status {2}, encrypted {3}%, method {4}, protector types {5}." -f `
        $Volume.MountPoint, $Volume.VolumeStatus, $Volume.ProtectionStatus, `
        $Volume.EncryptionPercentage, $Volume.EncryptionMethod, $KeyProtectorSummary)
}

try {
    Write-Log 'Checking the operating system volume for automatic device encryption.'

    if ($null -eq (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        throw 'Get-BitLockerVolume is unavailable. The image build cannot inspect automatic device encryption.'
    }

    $SystemDrive = $env:SystemDrive
    $Volume = Get-BitLockerVolume -MountPoint $SystemDrive -ErrorAction Stop
    if ($null -eq $Volume) {
        throw "Get-BitLockerVolume returned no result for the operating system volume '$SystemDrive'."
    }

    Write-BitLockerVolumeState -Volume $Volume
    if ([string]$Volume.VolumeStatus -eq 'FullyDecrypted' -and [int]$Volume.EncryptionPercentage -eq 0) {
        Write-Log "The operating system volume '$SystemDrive' is already fully decrypted."
        exit 0
    }

    if ([string]$Volume.VolumeStatus -eq 'DecryptionInProgress') {
        Write-Log "Decryption is already in progress on '$SystemDrive'. The image build will continue while it completes."
        exit 0
    }

    Write-Log "Starting full decryption of '$SystemDrive'. The image build will continue while it completes."
    Disable-BitLocker -MountPoint $SystemDrive -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 2
    Write-BitLockerVolumeState -Volume (Get-BitLockerVolume -MountPoint $SystemDrive -ErrorAction Stop)
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        Write-Log "Inner exception: $($_.Exception.InnerException.Message)"
    }
    Write-Log $_.ScriptStackTrace
    exit 1
}
