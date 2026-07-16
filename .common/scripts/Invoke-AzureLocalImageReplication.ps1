param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$false)]
    [string]$UserAssignedIdentityClientId = '',

    # Full resource ID of the captured gallery image version
    # e.g. /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gallery}/images/{image}/versions/{version}
    [Parameter(Mandatory=$true)]
    [string]$ImageVersionId,

    # Azure region where the source managed disk will be created (must match the image version's primary region)
    [Parameter(Mandatory=$true)]
    [string]$DiskLocation,

    # Resource ID of the Azure Local custom location
    # e.g. /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ExtendedLocation/customLocations/{name}
    [Parameter(Mandatory=$true)]
    [string]$AzureLocalCustomLocationResourceId,

    # Resource ID of the Azure Local resource group in which to create the VM image
    # e.g. /subscriptions/{sub}/resourceGroups/{rg}
    [Parameter(Mandatory=$true)]
    [string]$AzureLocalResourceGroupId,

    # Name for the resulting Azure Local VM image
    [Parameter(Mandatory=$true)]
    [string]$AzureLocalImageName,

    # Hyper-V generation of the source image (V1 or V2)
    [Parameter(Mandatory=$false)]
    [string]$HyperVGeneration = 'V2',

    # Operating system type of the source image
    [Parameter(Mandatory=$false)]
    [string]$OsType = 'Windows'
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Level - $Message"
}

function Wait-ArmLro {
    param(
        [hashtable]$Headers,
        [string]$OperationUri,
        [int]$TimeoutMinutes = 120
    )
    $Deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds 15
        $Op = Invoke-RestMethod -Headers $Headers -Method 'GET' -Uri $OperationUri
        switch ($Op.status) {
            'Succeeded' { return $Op }
            'Failed'    { throw "Azure operation failed: $($Op.error.message)" }
            'Canceled'  { throw "Azure operation was canceled." }
        }
    }
    throw "Azure operation timed out after $TimeoutMinutes minutes."
}

Try {
    Write-Log "Starting Azure Local image replication."
    Write-Log "Image version : $ImageVersionId"
    Write-Log "Target RG     : $AzureLocalResourceGroupId"
    Write-Log "Image name    : $AzureLocalImageName"

    # Fix trailing slash on resource manager URI (only AzureCloud includes a trailing slash)
    $Rm = if ($ResourceManagerUri[-1] -eq '/') {
        $ResourceManagerUri.Substring(0, $ResourceManagerUri.Length - 1)
    } else {
        $ResourceManagerUri
    }

    # Acquire an access token from the managed identity endpoint
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$Rm"
    if (-not [string]::IsNullOrEmpty($UserAssignedIdentityClientId)) {
        $TokenUri += "&client_id=$UserAssignedIdentityClientId"
    }
    $Token   = (Invoke-RestMethod -Headers @{ Metadata = "true" } -Uri $TokenUri).access_token
    $Headers = @{
        'Content-Type'  = 'application/json'
        'Authorization' = "Bearer $Token"
    }

    # --- Parse resource IDs ---
    # ImageVersionId: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gal}/images/{img}/versions/{ver}
    $VersionParts          = $ImageVersionId.TrimStart('/') -split '/'
    $DiskSubscriptionId    = $VersionParts[1]
    $DiskResourceGroupName = $VersionParts[3]

    # AzureLocalResourceGroupId: /subscriptions/{sub}/resourceGroups/{rg}
    $AzLocalParts             = $AzureLocalResourceGroupId.TrimStart('/') -split '/'
    $AzLocalSubscriptionId    = $AzLocalParts[1]
    $AzLocalResourceGroupName = $AzLocalParts[3]

    # Generate a short unique suffix for the temporary disk name (max 80 chars, alphanumeric + hyphens)
    $DiskSuffix     = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $DiskName       = "tmp-azl-$DiskSuffix"
    $DiskResourceId = "/subscriptions/$DiskSubscriptionId/resourceGroups/$DiskResourceGroupName/providers/Microsoft.Compute/disks/$DiskName"
    $DiskApiVersion = '2024-03-02'
    $DiskPutUri     = "$Rm$DiskResourceId`?api-version=$DiskApiVersion"

    # -----------------------------------------------------------------------
    # Step 1: Create a temporary managed disk from the gallery image version
    # The disk must be created in the same subscription and resource group as
    # the source gallery, and in the same Azure region as the image version.
    # -----------------------------------------------------------------------
    Write-Log "Creating temporary managed disk '$DiskName' in '$DiskResourceGroupName'."
    $DiskBody = [ordered]@{
        location   = $DiskLocation
        sku        = [ordered]@{ name = 'Standard_LRS' }
        properties = [ordered]@{
            creationData = [ordered]@{
                createOption         = 'FromImage'
                galleryImageReference = [ordered]@{ id = $ImageVersionId }
            }
        }
    } | ConvertTo-Json -Depth 10

    $DiskResponse = Invoke-WebRequest -Headers $Headers -Method 'PUT' -Uri $DiskPutUri `
        -Body $DiskBody -ContentType 'application/json' -UseBasicParsing

    if ($DiskResponse.StatusCode -eq 202) {
        $AsyncUri = $DiskResponse.Headers['Azure-AsyncOperation']
        if ($AsyncUri) {
            Write-Log "Waiting for managed disk creation (async)..."
            Wait-ArmLro -Headers $Headers -OperationUri $AsyncUri -TimeoutMinutes 60 | Out-Null
        }
    }

    # Confirm disk provisioning state
    $Disk = Invoke-RestMethod -Headers $Headers -Method 'GET' -Uri $DiskPutUri
    if ($Disk.properties.provisioningState -ne 'Succeeded') {
        throw "Managed disk provisioning failed. State: '$($Disk.properties.provisioningState)'."
    }
    Write-Log "Managed disk created successfully."

    # -----------------------------------------------------------------------
    # Step 2: Grant read SAS access to the managed disk
    # -----------------------------------------------------------------------
    Write-Log "Granting SAS read access to managed disk."
    $SasUri  = "$Rm$DiskResourceId/beginGetAccess?api-version=$DiskApiVersion"
    # Request 24-hour SAS; Azure Local downloads the image in the background and needs
    # the URL to remain valid for the full download, which can take several hours for
    # large images over constrained network links.
    $SasBody = [ordered]@{ access = 'Read'; durationInSeconds = 86400 } | ConvertTo-Json

    $SasResponse = Invoke-WebRequest -Headers $Headers -Method 'POST' -Uri $SasUri `
        -Body $SasBody -ContentType 'application/json' -UseBasicParsing

    $SasUrl = ''
    if ($SasResponse.StatusCode -in @(200, 201)) {
        $SasUrl = ($SasResponse.Content | ConvertFrom-Json).accessSAS
    } elseif ($SasResponse.StatusCode -eq 202) {
        $AsyncUri = if ($SasResponse.Headers['Azure-AsyncOperation']) {
            $SasResponse.Headers['Azure-AsyncOperation']
        } else {
            $SasResponse.Headers['Location']
        }
        Write-Log "Waiting for SAS grant (async)..."
        $SasResult = Wait-ArmLro -Headers $Headers -OperationUri $AsyncUri -TimeoutMinutes 10
        # The access SAS is nested in the LRO result properties
        $SasUrl = if ($SasResult.properties.output.accessSAS) {
            $SasResult.properties.output.accessSAS
        } elseif ($SasResult.accessSAS) {
            $SasResult.accessSAS
        } else {
            ''
        }
    }

    if ([string]::IsNullOrEmpty($SasUrl)) {
        throw "Failed to obtain SAS URL for managed disk '$DiskName'."
    }
    Write-Log "SAS URL obtained."

    # -----------------------------------------------------------------------
    # Step 3: Retrieve the Azure Local instance location from the custom location
    # -----------------------------------------------------------------------
    Write-Log "Querying Azure Local custom location for region information."
    $CustomLocationUri = "$Rm$AzureLocalCustomLocationResourceId`?api-version=2021-08-15"
    $CustomLocation    = Invoke-RestMethod -Headers $Headers -Method 'GET' -Uri $CustomLocationUri
    $AzLocalLocation   = $CustomLocation.location
    Write-Log "Azure Local region: $AzLocalLocation"

    # -----------------------------------------------------------------------
    # Step 4: Create the Azure Local VM image
    # Resource type: Microsoft.AzureStackHCI/galleryImages
    # -----------------------------------------------------------------------
    Write-Log "Creating Azure Local VM image '$AzureLocalImageName'."
    $HciImageResourceId = "/subscriptions/$AzLocalSubscriptionId/resourceGroups/$AzLocalResourceGroupName/providers/Microsoft.AzureStackHCI/galleryImages/$AzureLocalImageName"
    $HciImageUri        = "$Rm$HciImageResourceId`?api-version=2024-01-01"

    $HciBody = [ordered]@{
        location         = $AzLocalLocation
        extendedLocation = [ordered]@{
            name = $AzureLocalCustomLocationResourceId
            type = 'CustomLocation'
        }
        properties = [ordered]@{
            imagePath        = $SasUrl
            osType           = $OsType
            hyperVGeneration = $HyperVGeneration
        }
    } | ConvertTo-Json -Depth 10

    $HciResponse = Invoke-WebRequest -Headers $Headers -Method 'PUT' -Uri $HciImageUri `
        -Body $HciBody -ContentType 'application/json' -UseBasicParsing

    if ($HciResponse.StatusCode -eq 202) {
        $AsyncUri = if ($HciResponse.Headers['Azure-AsyncOperation']) {
            $HciResponse.Headers['Azure-AsyncOperation']
        } else {
            $HciResponse.Headers['Location']
        }
        if ($AsyncUri) {
            Write-Log "Waiting for Azure Local VM image creation (this may take up to 2 hours for large images)..."
            Wait-ArmLro -Headers $Headers -OperationUri $AsyncUri -TimeoutMinutes 120 | Out-Null
        }
    }

    # Confirm HCI image provisioning state
    $HciImage = Invoke-RestMethod -Headers $Headers -Method 'GET' -Uri $HciImageUri
    if ($HciImage.properties.provisioningState -ne 'Succeeded') {
        throw "Azure Local VM image provisioning failed. State: '$($HciImage.properties.provisioningState)'."
    }
    Write-Log "Azure Local VM image created successfully: $HciImageResourceId"

    # -----------------------------------------------------------------------
    # Step 5: Revoke SAS access and delete the temporary managed disk
    # Failures here are non-fatal; the disk is not needed after this point.
    # -----------------------------------------------------------------------
    Write-Log "Revoking SAS access on temporary managed disk."
    Try {
        $EndSasUri = "$Rm$DiskResourceId/endGetAccess?api-version=$DiskApiVersion"
        Invoke-RestMethod -Headers $Headers -Method 'POST' -Uri $EndSasUri -Body '{}' `
            -ContentType 'application/json' | Out-Null
        Write-Log "SAS access revoked."
    } Catch {
        Write-Log "WARNING - Could not revoke SAS access: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "Deleting temporary managed disk '$DiskName'."
    Try {
        Invoke-RestMethod -Headers $Headers -Method 'DELETE' -Uri $DiskPutUri | Out-Null
        Write-Log "Managed disk deletion initiated."
    } Catch {
        Write-Log "WARNING - Could not delete managed disk '$DiskName': $($_.Exception.Message)" 'WARN'
    }

    Write-Log "Azure Local image replication completed successfully."
}
Catch {
    Write-Error "Azure Local image replication failed: $($_.Exception.Message)"
    throw
}
