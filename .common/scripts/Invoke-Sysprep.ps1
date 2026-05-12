param (
    [string]$AdminUserPw
)

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\Invoke-Sysprep.log"

function Write-Log {
    param([string]$Message)
    $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    Write-Output $Entry
}

try {
    Write-Log "Starting sysprep script"
    $Services = 'RdAgent', 'WindowsTelemetryService', 'WindowsAzureGuestAgent'
    ForEach ($Service in $Services) {
        Write-Log "Checking for service '$Service' and waiting for it to start if it exists."
        If (Get-Service | Where-Object { $_.Name -eq $Service }) {
            Write-Log "Found Service '$Service'. Checking to see if it is running."
            If ((Get-Service -Name $Service).Status -eq 'Running') {
                Write-Log "'$Service' is already running."
            }
            Else {
                $ServiceTimeout = (Get-Date).AddMinutes(5)
                While ((Get-Service -Name $Service).Status -ne 'Running') {
                    Write-Log "Waiting for $Service to start."
                    If ((Get-Date) -ge $ServiceTimeout) {
                        Write-Log "Timed out waiting for service '$Service' to start. Continuing."
                        Break
                    }
                    Start-Sleep -Seconds 5
                }
            }
        }
        Else {
            Write-Log "Service $Service not found."
        }
    }

    $Files = "$env:SystemRoot\System32\sysprep\unattend.xml", "$env:SystemRoot\Panther\Unattend.xml"
    Write-Log "Checking for cached unattend files."
    ForEach ($File in $Files) {
        if (Test-Path -Path $File) {
            Write-Log "Removing $File"
            Remove-Item $File -Force
        }
    }

    $AdminAccount = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
    If (-Not $AdminAccount.Enabled) {
        Write-Log "Enabling local administrator account '$($AdminAccount.Name)'."
        Enable-LocalUser -Name $AdminAccount.Name
    }

    # Wait for CBS (Component Based Servicing) to settle. CBS still churning after a post-update reboot will cause sysprep to fail.
    Write-Log "Checking CBS (Component Based Servicing) status before running sysprep."
    $CbsTimeout = (Get-Date).AddMinutes(30)
    do {
        $CbsBusy = $false

        # A reboot is still pending - sysprep will fail in this state. Cannot auto-recover from a run command on the image VM.
        $RebootPendingPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        foreach ($Path in $RebootPendingPaths) {
            if (Test-Path $Path) {
                Write-Log "A reboot is required before sysprep can run ($Path exists). Add an additional restart step in the orchestration after Windows Updates and re-deploy."
                Exit 1
            }
        }

        # TrustedInstaller running means CBS is actively applying packages
        if ((Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue).Status -eq 'Running') {
            Write-Log "TrustedInstaller service is running. CBS is still processing. Waiting..."
            $CbsBusy = $true
        }

        # Pending exclusive CBS sessions indicate packages are queued
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending') {
            $Exclusive = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending' -ErrorAction SilentlyContinue).Exclusive
            if ($Exclusive -gt 0) {
                Write-Log "CBS has $Exclusive pending exclusive session(s). Waiting..."
                $CbsBusy = $true
            }
        }

        if ($CbsBusy) {
            if ((Get-Date) -ge $CbsTimeout) {
                Write-Log "Timed out waiting for CBS to settle after 30 minutes. Proceeding with sysprep."
                break
            }
            Start-Sleep -Seconds 30
        }
    } while ($CbsBusy)
    Write-Log "CBS check complete. Proceeding with sysprep."

    Write-Log "Creating a Scheduled Task to start Sysprep using the local admin account credentials."
    $TaskName = "RunSysprep"
    $TaskDescription = "Runs Sysprep with OOBE, Generalize, and VM Mode as Administrator and shuts down the VM when complete."
    # Define the action to execute Sysprep
    $Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\Sysprep\sysprep.exe" -Argument "/oobe /generalize /shutdown /mode:vm"
    # Create the task trigger (run once, immediately)
    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(20)
    # Register the scheduled task
    Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription -Action $Action -User $AdminAccount.Name -Password $AdminUserPw -Trigger $Trigger -RunLevel Highest -Force | Out-Null
    $RegisteredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    If ($RegisteredTask) {
        Write-Log "Scheduled task '$TaskName' registered successfully. Sysprep will run in ~20 seconds and shut down this VM when complete."
    }
    Else {
        Write-Log "Scheduled task '$TaskName' was not found after registration. Exiting."
        Exit 1
    }
    Write-Log "Sysprep script complete. The orchestration VM will monitor this VM's power state and generalize it once it has stopped."
}
catch {
    Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    If ($_.Exception.InnerException) { Write-Log "Inner exception: $($_.Exception.InnerException.Message)" }
    Write-Log $_.ScriptStackTrace
    Exit 1
}