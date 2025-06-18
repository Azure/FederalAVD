param (
    [string]$APIVersion,
    [string]$UserAssignedIdentityClientId,
    [string]$LogBlobContainerUri,
    [string]$AdminUserName,
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
            While ((Get-Service -Name $Service).Status -ne 'Running') {
                Write-Message -Message "Waiting for $Service to start."
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
Write-Message -Message "Creating a Scheduled Task to start Sysprep using the local admin account credentials."
$TaskName = "RunSysprep"
$TaskDescription = "Runs Sysprep with OOBE, Generalize, and VM Mode as Administrator"
# Define the action to execute Sysprep
$Action = New-ScheduledTaskAction -Execute "C:\Windows\System32\Sysprep\sysprep.exe" -Argument "/oobe /generalize /quit /mode:vm"
# Create the task trigger (run once, immediately)
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(20)
# Register the scheduled task
Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription -Action $Action -User $AdminUserName -Password $AdminUserPw -Trigger $Trigger -RunLevel Highest -Force
Do {
    Start-Sleep -Seconds 5
} Until (Get-Process | Where-Object { $_.Name -eq 'sysprep' })
Write-Message -Message "Sysprep started."
while ($true) {
    $imageState = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState
    Write-Message -Message "Current Image State: $imageState"
    if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
    Write-Message -Message "Waiting for Sysprep to complete"
    Start-Sleep -s 5
}

Get-Process | Where-Object { $_.Name -eq 'sysprep' } | Wait-Process -Timeout 300
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
        Invoke-WebRequest -Method Put -Uri $uri -Headers $headers -Body $body -UseBasicParsing
    }
}