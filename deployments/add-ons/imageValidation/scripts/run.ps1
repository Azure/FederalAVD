param($Timer)

$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Fix the resource manager URI since only AzureCloud contains a trailing slash
$ResourceManagerUriFixed = $env:ResourceManagerUri.TrimEnd('/')


# Azure Authentication
$AccessToken = $null
try
{
    $TokenAuthURI = $env:IDENTITY_ENDPOINT + '?resource=' + $ResourceManagerUriFixed + '&api-version=2019-08-01'
    $TokenResponse = Invoke-RestMethod -Method Get -Headers @{"X-IDENTITY-HEADER"="$env:IDENTITY_HEADER"} -Uri $TokenAuthURI
    $AccessToken = $TokenResponse.access_token
    $Header = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AccessToken
    }
}
catch
{
    throw [System.Exception]::new('Failed to authenticate Azure with application ID, tenant ID, subscription ID', $PSItem.Exception)
}

# Get latest compute gallery image version
$ImageDefinitionVersionsPath = ($env:imageVersionResourceId.Split('/') | Select-Object -SkipLast 1) -join '/'
$ComputeGalleryImageVersions = Invoke-RestMethod `
    -Headers $Header `
    -Method 'Get' `
    -Uri $($ResourceManagerUriFixed + $ImageDefinitionVersionsPath + '?api-version=2024-03-03')

$LatestComputeGalleryImageVersion = $ComputeGalleryImageVersions.value | Sort-Object { [version]$_.name } -Descending | Select-Object -First 1

$StatusCode = $null
try {
	# Get virtual machine
	$VirtualMachine = Invoke-RestMethod `
		-Headers $Header `
		-Method 'Get' `
		-Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:subscriptionId + '/resourceGroups/' + $env:resourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:virtualMachineName + '?api-version=2024-07-01')
}
catch  {
	if ($_.Exception.Response.StatusCode -eq 'NotFound') {
		$StatusCode = 'NotFound'
    }
    else {
        throw $_.Exception.Message
    }
}


if ($StatusCode -eq 'NotFound'){
	Write-Output "Virtual machine does not exist. No deletion necessary."
} 
elseif ($VirtualMachine.properties.storageProfile.imageReference.id.Split('/')[-1] -ne $LatestComputeGalleryImageVersion.name) {
	# Delete the virtual machine
	Invoke-RestMethod `
		-Headers $Header `
		-Method 'Delete' `
		-Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:subscriptionId + '/resourceGroups/' + $env:resourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:virtualMachineName + '?forceDeletion=true&api-version=2024-07-01') | Out-Null

    Write-Output 'Deleted existing virtual machine'
}

$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'

$Body = @{
	properties = @{
		mode = 'Incremental'
		parameters = @{
			acceleratedNetworking = @{ value = [bool]$env:acceleratedNetworking }
			artifactsContainerUri = @{ value = $env:artifactsContainerUri }
			artifactsUserAssignedIdentityResourceId = @{ value = $env:artifactsUserAssignedIdentityResourceId }
			bootDiagnostics = @{ value = [bool]$env:bootDiagnostics }
			diskAccessResourceId = @{ value = $env:diskAccessResourceId }
			diskControllerType = @{ value = $env:diskControllerType }
			diskEncryptionSetResourceId = @{ value = $env:diskEncryptionSetResourceId }
			diskName = @{ value = $env:diskName }
			diskNetworkAccess = @{ value = $env:diskNetworkAccess }
			encryptionAtHost = @{ value = [bool]$env:encryptionAtHost }
			hibernation = @{ value = $false }
			imageVersionResourceId = @{ value = $env:imageVersionResourceId }
			integrityMonitoring = @{ value = [bool]$env:integrityMonitoring }
			keyVaultResourceId = @{ value = $env:keyVaultResourceId }
			licenseType = @{ value = $env:licenseType }
			location = @{ value = $env:location }
			networkInterfaceName = @{ value = $env:networkInterfaceName }
			privateIPAddress = @{ value = $env:privateIPAddress }
			secureBoot = @{ value = [bool]$env:secureBoot }
			securityType = @{ value = $env:securityType }
			subnetResourceId = @{ value = $env:subnetResourceId }
			tags = @{ value = ($env:tags | ConvertFrom-Json -Depth 5) }
			virtualMachineName = @{ value = $env:virtualMachineName }
			virtualMachineSize = @{ value = $env:virtualMachineSize }
			vmCustomizations = @{ value = ($env:vmCustomizations | ConvertFrom-Json -Depth 5) }
			vTpm = @{ value = [bool]$env:vTpm }
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

Write-Output 'Deployed new image validation virtual machine'
