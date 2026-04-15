param (
    [string]$APIVersion,
    [string]$UserAssignedIdentityClientId,
    [string]$LogBlobContainerUri,
    [string]$AdminUserPw
)
Function Write-Message {
    param (
        [string]$Message
    )
    $Date = Get-Date -Format 'yyyy/MM/dd'
    $Time = Get-Date -Format 'HH:mm:ss'
    $Content = "[$Date $Time] $Message"
    Write-Output $Content
}
Write-Message -Message "Starting sysprep script"
$Services = 'RdAgent', 'WindowsTelemetryService', 'WindowsAzureGuestAgent'        
ForEach ($Service in $Services) {
    Write-Message -Message "Checking for service '$Service' and waiting for it to start if it exists."
    If (Get-Service | Where-Object { $_.Name -eq $Service }) {
        Write-Message -Message "Found Service '$Service'. Checking to see if it is running."
        If ((Get-Service -Name $Service).Status -eq 'Running') {
            Write-Message -Message "'$Service' is already running."
        }
        Else {
            $ServiceTimeout = (Get-Date).AddMinutes(5)
            While ((Get-Service -Name $Service).Status -ne 'Running') {
                Write-Message -Message "Waiting for $Service to start."
                If ((Get-Date) -ge $ServiceTimeout) {
                    Write-Message -Message "WARNING: Timed out waiting for service '$Service' to start. Continuing."
                    Break
                }
                Start-Sleep -Seconds 5
            }
        }
    }
    Else {
        Write-Message -Message "Service $Service not found."
    }
}

$Files = "$env:SystemRoot\System32\sysprep\unattend.xml", "$env:SystemRoot\Panther\Unattend.xml"
Write-Message -Message "Checking for files cached unattend files."
ForEach ($File in $Files) {
    if (Test-Path -Path $File) {
        Write-Message "Removing $File"
        Remove-Item $File -Force
    }
}
$AdminAccount = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
If (-Not $AdminAccount.Enabled) {
    Enable-LocalUser -Name $AdminAccount.Name
}

Write-Message -Message "Creating a Scheduled Task to start Sysprep using the local admin account credentials."
$TaskName = "RunSysprep"
$TaskDescription = "Runs Sysprep with OOBE, Generalize, and VM Mode as Administrator"
# Define the action to execute Sysprep
$Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\Sysprep\sysprep.exe" -Argument "/oobe /generalize /quit /mode:vm"
# Create the task trigger (run once, immediately)
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(20)
# Register the scheduled task
Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription -Action $Action -User $AdminAccount.Name -Password $AdminUserPw -Trigger $Trigger -RunLevel Highest -Force | Out-Null
$RegisteredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
If ($RegisteredTask) {
    Write-Message -Message "Scheduled task '$TaskName' registered successfully."
} Else {
    Write-Message -Message "ERROR: Scheduled task '$TaskName' was not found after registration. Exiting."
    Exit 1
}
$SysprepTimeout = (Get-Date).AddMinutes(5)
Do {
    Start-Sleep -Seconds 5
    If ((Get-Date) -ge $SysprepTimeout) {
        Write-Message -Message "ERROR: Timed out waiting for sysprep process to start. Exiting."
        Exit 1
    }
    $TaskInfo = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
    If ($TaskInfo.LastTaskResult -ne 0 -and $TaskInfo.LastRunTime -ne (Get-Date -Date '11/30/1999')) {
        Write-Message -Message "ERROR: Scheduled task failed to start sysprep. LastTaskResult: 0x$("{0:X8}" -f $TaskInfo.LastTaskResult). Check credentials passed via AdminUserPw parameter."
        Exit 1
    }
    $Sysprep = Get-Process | Where-Object { $_.Name -eq 'sysprep' }
} Until ($Sysprep)
Write-Message -Message "Sysprep started at $($Sysprep.StartTime)"
$ImageStateTimeout = (Get-Date).AddMinutes(10)
while ($true) {
    $imageState = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
    Write-Message -Message "Current Image State: $imageState"
    if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
    If ((Get-Date) -ge $ImageStateTimeout) {
        Write-Message -Message "ERROR: Timed out waiting for Sysprep to reach generalize state. Final image state: $imageState. Exiting."
        Exit 1
    }
    Write-Message -Message "Waiting for Sysprep to complete"
    Start-Sleep -s 5
}
$SysprepProcess = Get-Process | Where-Object { $_.Name -eq 'sysprep' }
If ($SysprepProcess) {
    $Exited = $SysprepProcess | Wait-Process -Timeout 300 -PassThru
    If (-Not $Exited) {
        Write-Message -Message "WARNING: Sysprep process did not exit within 300 seconds after image state was reached."
    }
}
Write-Message -Message "Sysprep complete"
Get-ScheduledTask | Where-Object { $_.TaskName -eq $TaskName } | Unregister-ScheduledTask -Confirm:$false

If ($LogBlobContainerUri -ne '') {
    Write-Message -Message "Uploading logs to blob storage: $LogBlobContainerUri"
    $StorageEndpoint = ($LogBlobContainerUri -split "://")[0] + "://" + ($LogBlobContainerUri -split "/")[2] + "/"
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
    $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
 
    ForEach ($LogFile in (Get-ChildItem -Path "$env:SystemRoot\System32\Sysprep\Panther" -Filter *.log -ErrorAction SilentlyContinue)) {
        $FileName = $LogFile.Name
        $FilePath = $LogFile.FullName
        $FileSize = (Get-Item $FilePath).length
        $Uri = "$LogBlobContainerUri$FileName"
        Write-Message -Message "Uploading '$FilePath' to '$Uri'"
        $headers = @{
            "Authorization"  = "Bearer $AccessToken"
            "x-ms-blob-type" = "BlockBlob"
            "Content-Length" = $FileSize
            "x-ms-version"   = "2020-10-02"
        }    
        $body = [System.IO.File]::ReadAllBytes($FilePath)    
        Invoke-WebRequest -Method Put -Uri $uri -Headers $headers -Body $body -UseBasicParsing | out-null
    }
}