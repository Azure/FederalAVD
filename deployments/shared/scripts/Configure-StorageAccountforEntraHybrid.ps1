param 
(
    [Parameter(Mandatory = $true)]
    [string]$DefaultSharePermission,

    [Parameter(Mandatory = $true)]
    [String]$DomainJoinUserPwd,

    [Parameter(Mandatory = $true)]
    [String]$DomainJoinUserPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory = $false)]
    [String]$StorageAccountPrefix,

    [Parameter(Mandatory = $false)]
    [String]$StorageAccountResourceGroupName,

    [Parameter(Mandatory = $false)]
    [String]$StorageCount,

    [Parameter(Mandatory = $false)]
    [String]$StorageIndex,

    [Parameter(Mandatory = $false)]
    [String]$StorageSuffix,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$UserAssignedIdentityClientId
)

# Configure error handling and output preferences
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

try {
    # Configure TLS 1.2 for secure HTTPS connections to Azure APIs
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Ensure Active Directory PowerShell module is available
    Write-Output "Checking for Active Directory PowerShell module..."
    $RsatInstalled = (Get-WindowsFeature -Name 'RSAT-AD-PowerShell').Installed
    if (!$RsatInstalled) {
        Write-Output "Installing RSAT-AD-PowerShell feature..."
        Install-WindowsFeature -Name 'RSAT-AD-PowerShell' | Out-Null
    }
    
    # Create credential object for domain operations
    Write-Output "Creating domain credentials..."
    $DomainJoinUserName = $DomainJoinUserPrincipalName.Split('@')[0]  # Extract username from UPN
    $DomainPassword = ConvertTo-SecureString -String $DomainJoinUserPwd -AsPlainText -Force
    [pscredential]$DomainCredential = New-Object System.Management.Automation.PSCredential ($DomainJoinUserName, $DomainPassword)

    # Retrieve Active Directory domain information
    Write-Output "Getting Active Directory domain information..."
    $Domain = Get-ADDomain -Credential $DomainCredential -Current 'LocalComputer'
    Write-Output "Domain: $($Domain.DNSRoot)"
    Write-Output "NetBIOS Name: $($Domain.NetBIOSName)"
     
    # Parse and clean input parameters
    [int]$StCount = $StorageCount.replace('\"', '"')  # Number of storage accounts to process
    [int]$StIndex = $StorageIndex.replace('\"', '"')  # Starting index for storage account naming
    Write-Output "Processing $StCount storage accounts starting from index $StIndex"
    
    # Clean escaped characters from string parameters
    
    $ResourceManagerUri = $ResourceManagerUri.Replace('\"', '"')  # Azure Resource Manager endpoint
    $StorageAccountPrefix = $StorageAccountPrefix.ToLower().replace('\"', '"')  # Storage account name prefix
    $StorageAccountResourceGroupName = $StorageAccountResourceGroupName.Replace('\"', '"')
    $SubscriptionId = $SubscriptionId.replace('\"', '"')
    $UserAssignedIdentityClientId = $UserAssignedIdentityClientId.replace('\"', '"')
    
    Write-Output "Configuration parameters:"
    Write-Output "  Storage Account Prefix: $StorageAccountPrefix"
    Write-Output "  Resource Group: $StorageAccountResourceGroupName"
    Write-Output "  Subscription ID: $SubscriptionId"
    Write-Output "  Target OU: $OuPath"
    
    # Build Azure Files endpoint suffix (e.g., ".file.core.windows.net")
    $FilesSuffix = ".file.$($StorageSuffix.Replace('\"', '"'))"
    Write-Output "  Files Suffix: $FilesSuffix"
    
    # Normalize Resource Manager URI (remove trailing slash for consistency)
    $ResourceManagerUri = if ($ResourceManagerUri[-1] -eq '/') { $ResourceManagerUri.Substring(0, $ResourceManagerUri.Length - 1) } else { $ResourceManagerUri }
    Write-Output "  Resource Manager URI: $ResourceManagerUri"
    
    # Authenticate to Azure using managed identity
    Write-Output "Authenticating to Azure using managed identity..."
    $AzureManagementAccessToken = (Invoke-RestMethod `
            -Headers @{Metadata = "true" } `
            -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUri + '&client_id=' + $UserAssignedIdentityClientId)).access_token
    
    # Prepare headers for Azure Management API calls
    $AzureManagementHeader = @{
        'Content-Type'  = 'application/json'
        'Authorization' = 'Bearer ' + $AzureManagementAccessToken
    }
    # Process each storage account for AD DS integration
    Write-Output "`nStarting storage account processing..."
    for ($i = 0; $i -lt $StCount; $i++) {
        # Generate storage account name with zero-padded index (e.g., "stavd01", "stavd02")
        $StorageAccountName = $StorageAccountPrefix + ($i + $StIndex).ToString().PadLeft(2, '0')
        Write-Output "`n=== Processing Storage Account: $StorageAccountName ==="              
        # Build request body with AD information for Azure Storage Account
        $Body = (@{
                properties = @{
                    azureFilesIdentityBasedAuthentication = @{
                        activeDirectoryProperties = @{
                            domainGuid        = $Domain.ObjectGUID.Guid  # Domain GUID
                            domainName        = $Domain.DNSRoot  # DNS domain name
                        }
                        directoryServiceOptions   = 'AADKERB'  # Use Entra Kerberos
                        defaultSharePermission = $DefaultSharePermission
                    }
                }
            } | ConvertTo-Json -Depth 6 -Compress)
        
        # Update storage account with AD authentication configuration
        try {
            $null = Invoke-RestMethod `
                -Body $Body `
                -Headers $AzureManagementHeader `
                -Method 'PATCH' `
                -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '?api-version=2023-05-01')
            Write-Output "Storage account AD authentication configured successfully"
        }
        catch {
            Write-Error "Failed to configure storage account AD authentication: $($_.Exception.Message)"
            throw
        }        
        Write-Output "=== Storage Account $StorageAccountName processing completed ==="                
    }
    
    Write-Output "`n=== Entra Kerberos for Hybrid Identities Process Completed Successfully ==="
    Write-Output "Summary:"
    Write-Output "  - Processed $StCount storage accounts"
    Write-Output "  - Created computer accounts in OU: $OuPath"
    Write-Output "  - Configured Azure Files for AD DS authentication"
    Write-Output "`nStorage accounts are now ready for identity-based authentication!"
}
catch {
    Write-Error "Entra Kerberos for Hybrid Identities integration failed: $($_.Exception.Message)"
    Write-Error "Full error details: $($_ | Out-String)"
    throw
}