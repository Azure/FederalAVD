$ErrorActionPreference = 'Stop'
$Name = 'Image-Manifest'
$LogFile = "$env:SystemRoot\Logs\$Name.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting '$Name' script."

    $Sep = '=' * 80

    # OS version
    Write-Log $Sep
    Write-Log 'OPERATING SYSTEM'
    Write-Log $Sep
    $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Log "ProductName:    $($os.ProductName)"
    Write-Log "Edition:        $($os.EditionID)"
    Write-Log "DisplayVersion: $($os.DisplayVersion)"
    Write-Log "Build:          $($os.CurrentBuildNumber).$($os.UBR)"
    if ($os.InstallDate) {
        $installDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$os.InstallDate).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss UTC')
        Write-Log "InstallDate:    $installDate"
    }

    # Installed applications (registry-based; avoids Win32_Product which triggers MSI repair)
    Write-Log $Sep
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName.Trim() -ne '' } |
        Select-Object DisplayName, DisplayVersion, Publisher |
        Sort-Object DisplayName -Unique
    Write-Log "INSTALLED APPLICATIONS ($($apps.Count) found)"
    Write-Log $Sep
    Write-Log ('{0,-60} {1,-25} {2}' -f 'Name', 'Version', 'Publisher')
    Write-Log ('-' * 110)
    foreach ($app in $apps) {
        Write-Log ('{0,-60} {1,-25} {2}' -f $app.DisplayName, $app.DisplayVersion, $app.Publisher)
    }

    # Windows hotfixes / patches
    Write-Log $Sep
    $hotfixes = Get-HotFix -ErrorAction SilentlyContinue |
        Select-Object HotFixID, Description, InstalledOn |
        Sort-Object InstalledOn
    Write-Log "WINDOWS HOTFIXES ($($hotfixes.Count) found)"
    Write-Log $Sep
    Write-Log ('{0,-15} {1,-40} {2}' -f 'HotFixID', 'Description', 'InstalledOn')
    Write-Log ('-' * 80)
    foreach ($hf in $hotfixes) {
        Write-Log ('{0,-15} {1,-40} {2}' -f $hf.HotFixID, $hf.Description, $hf.InstalledOn)
    }

    Write-Log $Sep
    Write-Log "Completed '$Name' script."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}
