param (
    [string]$AdminUserPw
)

function Write-OutputWithTimeStamp {
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("Info", "Warning", "Error")]
        $Category = 'Info',

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Message
    )    
    $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
    $content = '[' + $Timestamp + '] ' + $Message
    Switch ($Category) {
        'Info' { Write-Output $content }
        'Error' { Write-Error $Content }
        'Warning' { Write-Warning $Content }
    }
}

Write-OutputWithTimeStamp -Message "Starting sysprep script"
$Services = 'RdAgent', 'WindowsTelemetryService', 'WindowsAzureGuestAgent'        
ForEach ($Service in $Services) {
    Write-OutputWithTimeStamp -Message "Checking for service '$Service' and waiting for it to start if it exists."
    If (Get-Service | Where-Object { $_.Name -eq $Service }) {
        Write-OutputWithTimeStamp -Message "Found Service '$Service'. Checking to see if it is running."
        If ((Get-Service -Name $Service).Status -eq 'Running') {
            Write-OutputWithTimeStamp -Message "'$Service' is already running."
        }
        Else {
            $ServiceTimeout = (Get-Date).AddMinutes(5)
            While ((Get-Service -Name $Service).Status -ne 'Running') {
                Write-OutputWithTimeStamp -Message "Waiting for $Service to start."
                If ((Get-Date) -ge $ServiceTimeout) {
                    Write-OutputWithTimeStamp -Category "Warning" -Message "Timed out waiting for service '$Service' to start. Continuing."
                    Break
                }
                Start-Sleep -Seconds 5
            }
        }
    }
    Else {
        Write-OutputWithTimeStamp -Message "Service $Service not found."
    }
}

$Files = "$env:SystemRoot\System32\sysprep\unattend.xml", "$env:SystemRoot\Panther\Unattend.xml"
Write-OutputWithTimeStamp -Message "Checking for files cached unattend files."
ForEach ($File in $Files) {
    if (Test-Path -Path $File) {
        Write-OutputWithTimeStamp "Removing $File"
        Remove-Item $File -Force
    }
}

$AdminAccount = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
If (-Not $AdminAccount.Enabled) {
    Write-OutputWithTimeStamp -Message "Enabling local administrator account '$($AdminAccount.Name)'."
    Enable-LocalUser -Name $AdminAccount.Name
}

Write-OutputWithTimeStamp -Message "Creating a Scheduled Task to start Sysprep using the local admin account credentials."
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
    Write-OutputWithTimeStamp -Message "Scheduled task '$TaskName' registered successfully. Sysprep will run in ~20 seconds and shut down this VM when complete."
}
Else {
    Write-OutputWithTimeStamp -Category "Error" -Message "Scheduled task '$TaskName' was not found after registration. Exiting."
    Exit 1
}
Write-OutputWithTimeStamp -Message "Sysprep script complete. The orchestration VM will monitor this VM's power state and generalize it once it has stopped."