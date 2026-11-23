param($Timer)

$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Fix the resource manager URI since only AzureCloud contains a trailing slash
$ResourceManagerUriFixed = $env:ResourceManagerUri.TrimEnd('/')


# Azure Authentication
$AccessToken = $null
try {
    $TokenAuthURI = $env:IDENTITY_ENDPOINT + '?resource=' + $ResourceManagerUriFixed + '&api-version=2019-08-01'
    $TokenResponse = Invoke-RestMethod -Method Get -Headers @{"X-IDENTITY-HEADER" = "$env:IDENTITY_HEADER" } -Uri $TokenAuthURI
    $AccessToken = $TokenResponse.access_token
    $Header = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $AccessToken
    }

    Write-Output 'Successfully authenticated to Azure'
}
catch {
    throw [System.Exception]::new('Failed to authenticate Azure with application ID, tenant ID, subscription ID', $PSItem.Exception)
}

# Get latest compute gallery image version
$ImageDefinitionVersionsPath = ($env:imageVersionResourceId.Split('/') | Select-Object -SkipLast 1) -join '/'
$ComputeGalleryImageVersions = @()
$ComputeGalleryImageVersionsApi = Invoke-RestMethod `
    -Headers $Header `
    -Method 'Get' `
    -Uri $($ResourceManagerUriFixed + $ImageDefinitionVersionsPath + '?api-version=2024-03-03')

$ComputeGalleryImageVersions += $ComputeGalleryImageVersionsApi.value

while ($ComputeGalleryImageVersionsApi.nextLink) {
    $ComputeGalleryImageVersionsApi = Invoke-RestMethod `
        -Headers $Header `
        -Method 'GET' `
        -Uri $($ComputeGalleryImageVersionsApi.nextLink)
    
    $ComputeGalleryImageVersions += $ComputeGalleryImageVersionsApi.value
}

$LatestComputeGalleryImageVersion = $ComputeGalleryImageVersions | Sort-Object { [version]$_.name } -Descending | Select-Object -First 1
Write-Output "Latest compute gallery image version: $($LatestComputeGalleryImageVersion.name)"

# Check if the latest compute gallery image version is available and ready
$AggregatedState = ''
$ProvisioningState = ''
$StateCounter = 0

while ($AggregatedState -ne 'Completed' -or $ProvisioningState -ne 'Succeeded') {
    $ComputeGalleryImageVersion = Invoke-RestMethod `
        -Headers $Header `
        -Method 'Get' `
        -Uri $($ResourceManagerUriFixed + $LatestComputeGalleryImageVersion.id + '?api-version=2024-03-03&$expand=ReplicationStatus')

    $AggregatedState = $ComputeGalleryImageVersion.properties.replicationStatus.aggregatedState
    $ProvisioningState = $ComputeGalleryImageVersion.properties.provisioningState
    Start-Sleep -Seconds 30
    $StateCounter++
    if ($StateCounter -ge 60 -and ($AggregatedState -ne 'Completed' -or $ProvisioningState -ne 'Succeeded')) {
        throw [System.Exception]::new('Timeout waiting for compute gallery image version to be ready')
    }
    elseif ($AggregatedState -eq 'Failed' -or $ProvisioningState -eq 'Failed') {
        throw [System.Exception]::new('Compute gallery image version failed to be ready')
    }
}

# Get virtual machine
$StatusCode = $null
try {
    $VirtualMachine = Invoke-RestMethod `
        -Headers $Header `
        -Method 'Get' `
        -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:subscriptionId + '/resourceGroups/' + $env:resourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:virtualMachineName + '?api-version=2024-07-01') `
        -StatusCodeVariable StatusCode

    Write-Output "Deployed compute gallery image version: $($VirtualMachine.properties.storageProfile.imageReference.id.Split('/')[-1])"
}
catch {
    if ([int]$PSItem.Exception.Response.StatusCode -eq 404) {
        Write-Output "Virtual machine does not exist. No deletion necessary."
    }
    else {
        throw [System.Exception]::new('Failed to get virtual machine', $PSItem.Exception)
    }
}

# Delete the virtual machine
if ($StatusCode -eq 200) {
    if ($VirtualMachine.properties.storageProfile.imageReference.id -ne $LatestComputeGalleryImageVersion.id) {
        Invoke-RestMethod `
            -Headers $Header `
            -Method 'Delete' `
            -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:subscriptionId + '/resourceGroups/' + $env:resourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:virtualMachineName + '?forceDeletion=true&api-version=2024-07-01') | Out-Null

        $StatusCode = $null
        $StatusCounter = 0
        while ($StatusCode -ne 404) {
            # Get virtual machine
            try {
                $VirtualMachine = Invoke-RestMethod `
                    -Headers $Header `
                    -Method 'Get' `
                    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:subscriptionId + '/resourceGroups/' + $env:resourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:virtualMachineName + '?api-version=2024-07-01') `
                    -StatusCodeVariable StatusCode
            }
            catch {
                if ([int]$PSItem.Exception.Response.StatusCode -eq 404) {
                    break
                }
                else {
                    throw [System.Exception]::new('Failed to get virtual machine', $PSItem.Exception)
                }
            }

            Start-Sleep -Seconds 30
            $StatusCounter++
            if ($StatusCounter -ge 60) {
                throw [System.Exception]::new('Timeout waiting for virtual machine to be deleted')
            }
        }

        Write-Output 'Virtual machine was using an outdated image and has been deleted.'
    }
    else {
        Write-Output 'Virtual machine is using the latest image. No deletion necessary.'
    }
}

$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'

$Body = @{
    properties = @{
        mode         = 'Incremental'
        parameters   = @{
            acceleratedNetworking                   = @{ value = [bool]::Parse($env:acceleratedNetworking) }
            artifactsContainerUri                   = @{ value = $env:artifactsContainerUri }
            artifactsUserAssignedIdentityResourceId = @{ value = $env:artifactsUserAssignedIdentityResourceId }
            bootDiagnostics                         = @{ value = [bool]::Parse($env:bootDiagnostics) }
            diskAccessResourceId                    = @{ value = $env:diskAccessResourceId }
            diskControllerType                      = @{ value = $env:diskControllerType }
            diskEncryptionSetResourceId             = @{ value = $env:diskEncryptionSetResourceId }
            diskName                                = @{ value = $env:diskName }
            diskNetworkAccess                       = @{ value = $env:diskNetworkAccess }
            encryptionAtHost                        = @{ value = [bool]::Parse($env:encryptionAtHost) }
            hibernation                             = @{ value = $false }
            imageVersionResourceId                  = @{ value = $LatestComputeGalleryImageVersion.id }
            integrityMonitoring                     = @{ value = [bool]::Parse($env:integrityMonitoring) }
            keyVaultResourceId                      = @{ value = $env:keyVaultResourceId }
            licenseType                             = @{ value = $env:licenseType }
            location                                = @{ value = $env:location }
            networkInterfaceName                    = @{ value = $env:networkInterfaceName }
            privateIPAddress                        = @{ value = $env:privateIPAddress }
            secureBoot                              = @{ value = [bool]::Parse($env:secureBoot) }
            securityType                            = @{ value = $env:securityType }
            subnetResourceId                        = @{ value = $env:subnetResourceId }
            tags                                    = @{ value = ($env:tags | ConvertFrom-Json -Depth 5) }
            virtualMachineName                      = @{ value = $env:virtualMachineName }
            virtualMachineSize                      = @{ value = $env:virtualMachineSize }
            vmCustomizations                        = @{ value = ($env:vmCustomizations | ConvertFrom-Json -Depth 5) }
            vTpm                                    = @{ value = [bool]::Parse($env:vTpm) }
        }
        templateLink = @{
            id = $env:templateSpecResourceId
        }
    }
} | ConvertTo-Json -Depth 20

Invoke-RestMethod `
    -Headers $Header `
    -Method 'PUT' `
    -Body $Body `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:subscriptionId + '/resourcegroups/' + $env:resourceGroupName + '/providers/Microsoft.Resources/deployments/ImageValidation-' + $Timestamp + '?api-version=2020-10-01') | Out-Null

Write-Output "Deployment submitted for new image validation virtual machine. Check deployment status in the portal for more details. Deployment name is: ImageValidation-$Timestamp"
