param($Timer)

$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Fix the resource manager URI since only AzureCloud contains a trailing slash
$ResourceManagerUriFixed = $env:ResourceManagerUri.TrimEnd('/')

# Get an access token for Azure resources
$AzureManagementAccessToken = (Invoke-RestMethod `
    -Headers @{Metadata="true"} `
    -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

# Set header for Azure Management API
$AzureManagementHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $AzureManagementAccessToken
}

# Get latest compute gallery image version
$ComputeGalleryImageVersions = Invoke-RestMethod `
    -Headers $AzureManagementHeader `
    -Method 'Get' `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:SubscriptionId + '/resourceGroups/' + $env:ResourceGroupName + '/providers/Microsoft.Compute/galleries/' + $env:ComputeGalleryName + '/images/' + $env:ComputeGalleryImageName + '/versions?api-version=2024-03-03')

$LatestComputeGalleryImageVersion = $ComputeGalleryImageVersions.value | Sort-Object { [version]$_.name } -Descending | Select-Object -First 1

# Get virtual machine
$VirtualMachine = Invoke-RestMethod `
    -Headers $AzureManagementHeader `
    -Method 'Get' `
    -Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:SubscriptionId + '/resourceGroups/' + $env:ResourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:VmName + '?api-version=2024-07-01')


if ($VirtualMachine.properties.storageProfile.imageReference.version -ne $LatestComputeGalleryImageVersion.name) {
	# Delete the virtual machine
	Invoke-RestMethod `
		-Headers $AzureManagementHeader `
		-Method 'Delete' `
		-Uri $($ResourceManagerUriFixed + '/subscriptions/' + $env:SubscriptionId + '/resourceGroups/' + $env:ResourceGroupName + '/providers/Microsoft.Compute/virtualMachines/' + $env:VmName + '?forceDeletion=true&api-version=2024-07-01') | Out-Null

    Write-Output 'Deleted existing virtual machine'

	# Deploy the virtual machine to run the tool
	$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'

	$Body = @{
		properties = @{
			mode = 'Incremental'
			parameters = @{
				DeleteOlderThanDays = @{ value = $([convert]::ToInt32($env:DeleteOlderThanDays, 10)) }
				DiskName = @{ value = $env:DiskName }
				FileShareResourceId = @{ value = $env:FileShareResourceId }
				KeyVaultResourceId = @{ value = $env:KeyVaultResourceId }
				NicName = @{ value = $env:NicName }
				SubnetResourceId = @{ value = $env:SubnetResourceId }
				UserAssignedIdentityResourceId = @{ value = $env:UserAssignedIdentityResourceId }
				VmName = @{ value = $env:VmName }
				VmSize = @{ value = $env:VmSize }
			}
			templateLink = @{
				id = $env:TemplateSpecResourceId
			}
		}
	} | ConvertTo-Json -Depth 5

	Invoke-RestMethod `
		-Headers $AzureManagementHeader `
		-Method 'PUT' `
		-Body $Body `
		-Uri $($ResourceManagerUriFixed +  '/subscriptions/' + $env:SubscriptionId + '/resourcegroups/' + $env:ResourceGroupName + '/providers/Microsoft.Resources/deployments/ImageValidation-' + $Timestamp + '?api-version=2020-10-01') | Out-Null
	
	Write-Output 'Deployed new image validation virtual machine'
}