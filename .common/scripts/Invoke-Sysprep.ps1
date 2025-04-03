param (
    [string]$APIVersion,
    [string]$UserAssignedIdentityClientId,
    [string]$LogBlobContainerUri
)

$Services = 'RdAgent', 'WindowsTelemetryService', 'WindowsAzureGuestAgent'        
ForEach ($Service in $Services) {
    If (Get-Service | Where-Object { $_.Name -eq $Service }) {
        While ((Get-Service -Name $Service).Status -ne 'Running') {
            Write-Output ">>> Waiting for $Service to start..."
            Start-Sleep -Seconds 5
        }
    }
}
$Files = "$env:SystemRoot\System32\sysprep\unattend.xml", "$env:SystemRoot\Panther\Unattend.xml"
ForEach ($file in $Files) {
    if (Test-Path -Path $File) {
        Write-Output ">>> Removing $file"
        Remove-Item $file -Force
    }
}
Write-Output '>>> Sysprepping VM ...'
Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" -ArgumentList "/generalize /oobe /quit /mode:vm" -Wait
while ($true) {
    $imageState = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState
    Write-Output $imageState
    if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
    Start-Sleep -s 5
}
Write-Output ">>> Sysprep complete ..."

If ($LogBlobContainerUri -ne '') {
    $StorageEndpoint = ($LogBlobContainerUri -split "://")[0] + "://" + ($LogBlobContainerUri -split "/")[2] + "/"
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
    $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
 
    ForEach ($LogFile in (Get-ChildItem -Path "$env:SystemRoot\System32\Sysprep\Panther" -Filter *.log -ErrorAction SilentlyContinue)) {
        $FileName = $LogFile.Name
        $FilePath = $LogFile.FullName
        $FileSize = (Get-Item $FilePath).length
        $Uri = "$LogBlobContainerUri$FileName"
        Write-Output ">>> Uploading '$FilePath' to '$Uri'"
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