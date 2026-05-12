param (
    # The App Name to pass to the WUA API as the calling application.
    [Parameter()]
    [String]$AppName = "Windows Update API Script",
    # The search criteria to be used.
    [Parameter()]
    [String]$Criteria = "IsInstalled=0 and Type='Software' and IsHidden=0",
    [Parameter()]
    [bool]$ExcludePreviewUpdates = $true,
    [Parameter()]
    [ValidateSet("MU", "WSUS")]
    [string]$Service = 'MU',
    # The http/https fqdn for the Windows Server Update Server
    [Parameter()]
    [string]$WSUSServer
)
  
Function ConvertFrom-InstallationResult {
    [CmdletBinding()]
    param (
        [Parameter()]
        [int]$Result
    )        
    switch ($Result) {
        2 { $Text = 'Succeeded' }
        3 { $Text = 'Succeeded with errors' }
        4 { $Text = 'Failed' }
        5 { $Text = 'Cancelled' }
        Default { $Text = "Unexpected ($Result)" }
    }        
    Return $Text
}

$LogFile = "$env:SystemRoot\Logs\Install-Updates.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting Windows Update Script with the following parameters:"
    Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)

    Switch ($Service.ToUpper()) {
        'MU' { $ServerSelection = 3; $ServiceId = "7971f918-a847-4430-9279-4a52d1efe18d" }
        'WSUS' { $ServerSelection = 1 }
    }        
    If ($Service -eq 'MU') {
        $UpdateServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
        $UpdateServiceManager.ClientApplicationID = $AppName
        $null = $UpdateServiceManager.AddService2($ServiceId, 7, "")
        $null = cmd /c reg.exe ADD "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AllowMUUpdateService /t REG_DWORD /d 1 /f '2>&1'
        Write-Log "Added Registry entry to configure Microsoft Update. Exit Code: [$LastExitCode]"
    }
    Elseif ($Service -eq 'WSUS' -and $WSUSServer) {
        $null = cmd /c reg.exe ADD "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d $WSUSServer /f '2>&1'
        $null = cmd /c reg.exe ADD "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d $WSUSServer /f '2>&1'
        Write-Log "Added Registry entry to configure WSUS Server. Exit Code: [$LastExitCode]"
    }        
    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSession.ClientApplicationID = $AppName   
    $UpdateSearcher = New-Object -ComObject Microsoft.Update.Searcher
    $UpdateSearcher.ServerSelection = $ServerSelection
    If ($ServerSelection -eq 3) {
        $UpdateSearcher.ServiceId = $ServiceId
    }
    Write-Log -Message "Searching for Updates..."
    $SearchResult = $null
    $SearchAttempts = 0
    $SearchMaxAttempts = 5
    do {
        $SearchAttempts++
        try {
            $SearchResult = $UpdateSearcher.Search($Criteria)
        } catch {
            if ($SearchAttempts -lt $SearchMaxAttempts -and $_.Exception.HResult -eq [int]'0x8024001E') {
                Write-Log "Search attempt $SearchAttempts/$SearchMaxAttempts failed (WU_E_SERVICE_NOT_REGISTERED). Retrying in 30s..."
                Start-Sleep -Seconds 30
            } else {
                throw
            }
        }
    } while ($null -eq $SearchResult -and $SearchAttempts -lt $SearchMaxAttempts)
    If ($($SearchResult.Updates).Count -gt 0) {
        Write-Log "List of applicable items found for this computer:"
        For ($i = 0; $i -lt $($SearchResult.Updates).Count; $i++) {
            $Update = $SearchResult.Updates[$i]
            Write-Log "$($i + 1) > $($update.Title)"
        }
        $AtLeastOneAdded = $false
        $ExclusiveAdded = $false   
        $UpdatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        Write-Log "Checking search results:"
        For ($i = 0; $i -lt $($SearchResult.Updates).Count; $i++) {
            $Update = $SearchResult.Updates[$i]
            $AddThisUpdate = $false        
            If ($ExclusiveAdded) {
                Write-Log "$($i + 1) > skipping: '$($update.Title)' because an exclusive update has already been selected."
            }
            Else {
                $AddThisUpdate = $true
            }        
            if ($ExcludePreviewUpdates -and $update.Title -like '*Preview*') {
                Write-Log "$($i + 1) > Skipping: '$($update.Title)' because it is a preview update."
                $AddThisUpdate = $false
            }        
            If ($AddThisUpdate) {
                $PropertyTest = 0
                $ErrorActionPreference = 'SilentlyContinue'
                $PropertyTest = $Update.InstallationBehavior.Impact
                $ErrorActionPreference = 'Stop'
                If ($PropertyTest -eq 2) {
                    If ($AtLeastOneAdded) {
                        Write-Log "$($i + 1) > skipping: '$($update.Title)' because it is exclusive and other updates are being installed first."
                        $AddThisUpdate = $false
                    }
                }
            }
            If ($AddThisUpdate) {
                Write-Log "$($i + 1) > adding: '$($update.Title)'"
                $UpdatesToDownload.Add($Update) | out-null
                $AtLeastOneAdded = $true
                $ErrorActionPreference = 'SilentlyContinue'
                $PropertyTest = $Update.InstallationBehavior.Impact
                $ErrorActionPreference = 'Stop'
                If ($PropertyTest -eq 2) {
                    Write-Log "This update is exclusive; skipping remaining updates"
                    $ExclusiveAdded = $true
                }
            }
        }        
        $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        Write-Log "Downloading updates..."
        $Downloader = $UpdateSession.CreateUpdateDownloader()
        $Downloader.Updates = $UpdatesToDownload
        $Downloader.Download()
        Write-Log "Successfully downloaded updates:"        
        For ($i = 0; $i -lt $UpdatesToDownload.Count; $i++) {
            $Update = $UpdatesToDownload[$i]
            If ($Update.IsDownloaded -eq $true) {
                Write-Log "$($i + 1) > $($update.title)"
                $UpdatesToInstall.Add($Update) | out-null
            }
        }        
        If ($UpdatesToInstall.Count -gt 0) {
            Write-Log "Now installing updates..."
            $Installer = New-Object -ComObject Microsoft.Update.Installer
            $Installer.Updates = $UpdatesToInstall
            $InstallationResult = $Installer.Install()
            $Text = ConvertFrom-InstallationResult -Result $InstallationResult.ResultCode
            Write-Log "Installation Result: $($Text)"        
            If ($InstallationResult.RebootRequired) {
                Write-Log "Atleast one update requires a reboot to complete the installation."
            }
        }
    }
    Else {
        Write-Log "No missing updates found."
    }

    If ($service -eq 'MU') {
        Reg.exe DELETE "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AllowMUUpdateService /f
    }
    Elseif ($Service -eq 'WSUS' -and $WSUSServer) {
        reg.exe DELETE "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f
        reg.exe DELETE "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}