<#      
    .DESCRIPTION
    Main script to perform customizations via the Azure VM Image Builder Service. This script is used to download and execute customizers on the VM image being built and is significantly
    faster than using individual customizers scripts within the image template because the VM directly performs the download versus the Azure Image Builder service performing the download and
    then sending the download to the VM. This script is used in the 'Customize' phase of the image template.

    .PARAMETER APIVersion
    The API version to use to get an access token for the storage account(s) via the VM Instance Metadata Service. Default is '2018-02-01'.

    .PARAMETER BlobStorageSuffix
    The suffix of the blob storage account of the azure environment where you are building the image. Default is 'core.windows.net'.  For Azure US Government, use 'core.usgovcloudapi.net'.
    
    .PARAMETER Customizers
    A JSON formatted array of customizers to execute. Each customizer is an object with the following keys:
    - Name: The name of the customizer. (required)
    - Uri: The URI of the customizer. (required)
    - Arguments: The arguments to pass to the customizer. (optional)

    .PARAMETER UserAssignedIdentityClientId
    The client ID of the user assigned identity to use to get an access token for the storage account(s) via the VM Instance Metadata Service.

    .EXAMPLE
    $Customizers = '[{"name":"FSLogix","Uri":"https://saimageassetsusgvaa4a449.blob.core.usgovcloudapi.net/artifacts/FSLogix.zip"},{"name":"LGPO","Uri":"https://saimageassetsusgvaa4a449.blob.core.usgovcloudapi.net/artifacts/LGPO.zip"}]'
#>

[CmdletBinding()]
param(
    [string] $APIVersion = '2018-02-01',
    [string] $BlobStorageSuffix,
    [string] $Customizers = '[]',
    [string] $UserAssignedIdentityClientId
)
$ErrorActionPreference = 'Stop'
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
Start-Transcript -Path "$env:SystemRoot\Logs\$($Script:Name).log" -Force
Write-Output "Starting '$PSCommandPath'."
Write-Output "Current working dir: $((Get-Location).Path)"
[array]$Customizers = $Customizers | ConvertFrom-Json
ForEach ($Customizer in $Customizers) {
    $Name = $Customizer.Name
    $Uri = $Customizer.Uri
    $Arguments = $Customizer.Arguments
    Write-Output "Processing '$Name' customizer."
    $TempDir = Join-Path $Env:TEMP -ChildPath $Name
    New-Item -Path $TempDir -ItemType Directory -Force | Out-Null  
    $WebClient = New-Object System.Net.WebClient
    If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
        $StorageEndpoint = ($Uri -split '://')[0] + '://' + ($Uri -split '/')[2] + '/'
        $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
        $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
        $WebClient.Headers.Add('x-ms-version', '2017-11-09')
        $WebClient.Headers.Add("Authorization", "Bearer $AccessToken")
    }
    Write-Output "Downloading '$Uri' to '$TempDir'."
    $SourceFileName = ($Uri -Split '/')[-1]
    $DestFile = Join-Path -Path $TempDir -ChildPath $SourceFileName
    $WebClient.DownloadFile("$Uri", "$DestFile")
    Start-Sleep -Seconds 5
    $WebClient = $null
    If (!(Test-Path -Path $DestFile)) { Write-Error "Failed to download $SourceFileName"; Exit 1 }
    Write-Output 'Finished downloading'
    $Extension = [System.IO.Path]::GetExtension($DestFile).ToLower().Replace('.','')
    switch ($Extension) {
        'exe' {
            If ($Arguments) {
                Write-Output "Executing '$DestFile $Arguments'"
                Start-Process -FilePath $DestFile -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
            }
            Else {
                Write-Output "Executing '$DestFile'"
                Start-Process -FilePath $DestFile -NoNewWindow -Wait -PassThru
            }                          
        } # end exe
        'msi' {
            If ($Arguments) {
                If ($Arguments -notcontains $SourceFileName) {
                    $Arguments = "/i $DestFile $Arguments"
                }
                Write-Output "Executing 'msiexec.exe $Arguments'"
                Start-Process -FilePath msiexec.exe -ArgumentList $Arguments -Wait
            }
            Else {
                Write-Output "Executing 'msiexec.exe /i $DestFile /qn'"
                Start-Process -FilePath msiexec.exe -ArgumentList "/i $DestFile /qn" -Wait
            }            
        } # end msi
        'bat' {
            If ($Arguments) {
                Write-Output "Executing 'cmd.exe $DestFile $Arguments'"
                Start-Process -FilePath cmd.exe -ArgumentList "$DestFile $Arguments" -Wait
            }
            Else {
                Write-Output "Executing 'cmd.exe $DestFile'"
                Start-Process -FilePath cmd.exe -ArgumentList $DestFile -Wait
            }
        } # end bat
        'ps1' {
            If ($Arguments) {
                Write-Output "Calling PowerShell Script '$DestFile' with arguments '$Arguments'"
                & $DestFile $Arguments
            }
            Else {
                Write-Output "Calling PowerShell Script '$DestFile'"
                & $DestFile
            }
        } # end ps1
        'zip' {
            $DestinationPath = Join-Path -Path $TempDir -ChildPath $([System.IO.Path]::GetFileNameWithoutExtension($SourceFileName))
            Write-Output "Extracting '$DestFile' to '$DestinationPath'."
            Expand-Archive -Path $DestFile -DestinationPath $DestinationPath -Force
            Write-Output "Finding PowerShell script in root of '$DestinationPath'."
            $PSScript = Get-ChildItem -Path $DestinationPath -Filter '*.ps1' | Select-Object -First 1 -ExpandProperty FullName
            If ($null -ne $PSScript) {
                If ($Arguments) {
                    Write-Output "Calling PowerShell Script '$PSScript' with arguments '$Arguments'"
                    & $PSScript $Arguments
                }
                Else {
                    Write-Output "Calling PowerShell Script '$PSScript'"         
                    & $PSScript
                }
            }
        } # end zip
    }
}
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "Ending '$PSCommandPath'."
Stop-Transcript