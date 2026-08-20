param 
(        
    [Parameter(Mandatory = $true)]
    [String]$DomainJoinUserPwd,

    [Parameter(Mandatory = $true)]
    [String]$DomainJoinUserPrincipalName,

    [Parameter(Mandatory = $false)]
    [String]$HostPoolName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("AES256", "RC4")]
    [String]$KerberosEncryptionType,

    [Parameter(Mandatory = $false)]
    [String]$OuPath,

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
    $OuPath = $OuPath.Replace('\"', '"')  # Target OU for computer accounts
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
        
        # Retrieve or generate Kerberos key for the storage account
        Write-Output "Checking for existing Kerberos key..."
        $KerberosKey = ((Invoke-RestMethod `
                    -Headers $AzureManagementHeader `
                    -Method 'POST' `
                    -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/listKeys?api-version=2023-05-01&$expand=kerb')).keys | Where-Object { $_.Keyname -contains 'kerb1' }).Value
                
        if (!$KerberosKey) {
            # Generate new Kerberos key if none exists
            Write-Output "Kerberos Key not found, generating new kerb1 key..."
            $null = Invoke-RestMethod `
                -Body (@{keyName = 'kerb1' } | ConvertTo-Json) `
                -Headers $AzureManagementHeader `
                -Method 'POST' `
                -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/regenerateKey?api-version=2023-05-01')
            
            # Retrieve the newly generated key
            $Key = ((Invoke-RestMethod `
                        -Headers $AzureManagementHeader `
                        -Method 'POST' `
                        -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/listKeys?api-version=2023-05-01&$expand=kerb')).keys | Where-Object { $_.Keyname -contains 'kerb1' }).Value
        } 
        else {
            Write-Output "Existing Kerberos key found and will be used"
            $Key = $KerberosKey
        }
        
        # Convert Kerberos key to secure password for AD computer account
        Write-Output "Preparing computer account password from Kerberos key..."
        $ComputerPassword = ConvertTo-SecureString -String $Key.Replace("'", "") -AsPlainText -Force
        
        # Create Service Principal Name (SPN) for SMB/CIFS access
        # Format: cifs/storageaccount.file.core.windows.net
        Write-Output "Creating Service Principal Name (SPN)..."
        $SPN = 'cifs/' + $StorageAccountName + $FilesSuffix
        Write-Output "SPN: $SPN"
        
        # Create description for the computer account
        $Description = "FSLogix for $HostPoolName"

        # Check for existing computer account and clean up if necessary
        Write-Output "Checking for existing computer account in Active Directory..."
        $Computer = Get-ADComputer -Credential $DomainCredential -Filter { Name -eq $StorageAccountName } -ErrorAction SilentlyContinue
        if ($Computer) {
            Write-Output "Existing computer account found. Removing to ensure clean setup..."
            Remove-ADComputer -Credential $DomainCredential -Identity $StorageAccountName -Confirm:$false
        }
        else {
            Write-Output "No existing computer account found."
        }
        
        # Create new computer account in Active Directory
        Write-Output "Creating new computer account in AD..."
        Write-Output "  Target OU: $OuPath"
        Write-Output "  SPN: $SPN"
        try {
            $ComputerObject = New-ADComputer -Credential $DomainCredential -Name $StorageAccountName -Path $OuPath -ServicePrincipalNames $SPN -AccountPassword $ComputerPassword -Description $Description -PassThru
            Write-Output "Computer account created successfully with SID: $($ComputerObject.SID.Value)"
        }
        catch {
            Write-Error "Failed to create computer account: $($_.Exception.Message)"
            throw
        }
        
        # Configure Azure Storage Account for AD DS authentication
        Write-Output "Configuring Azure Storage Account for AD DS authentication..."
        
        # Determine SAM account name based on encryption type
        $SamAccountName = switch ($KerberosEncryptionType) {
            'AES256' { $StorageAccountName }  # For AES256, use computer name
            'RC4' { $ComputerObject.SamAccountName }  # For RC4, use full SAM account name
        }
        Write-Output "Using SAM Account Name: $SamAccountName"
        
        # Build request body with AD information for Azure Storage Account
        $Body = (@{
                properties = @{
                    azureFilesIdentityBasedAuthentication = @{
                        activeDirectoryProperties = @{
                            accountType       = 'Computer'  # Computer account type
                            azureStorageSid   = $ComputerObject.SID.Value  # Computer account SID
                            domainGuid        = $Domain.ObjectGUID.Guid  # Domain GUID
                            domainName        = $Domain.DNSRoot  # DNS domain name
                            domainSid         = $Domain.DomainSID.Value  # Domain SID
                            forestName        = $Domain.Forest  # Forest name
                            netBiosDomainName = $Domain.NetBIOSName  # NetBIOS domain name
                            samAccountName    = $samAccountName  # SAM account name
                        }
                        directoryServiceOptions   = 'AD'  # Use Active Directory (not Azure AD DS)
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
                
        # Configure AES256 encryption if specified (enhanced security)
        if ($KerberosEncryptionType -eq 'AES256') {
            Write-Output "Configuring AES256 Kerberos encryption (enhanced security)..."
            
            # Set Kerberos encryption type on the computer account in AD
            $DistinguishedName = 'CN=' + $StorageAccountName + ',' + $OuPath
            try {
                Set-ADComputer -Credential $DomainCredential -Identity $DistinguishedName -KerberosEncryptionType 'AES256' | Out-Null
                Write-Output "AES256 encryption type set on computer account"
            }
            catch {
                Write-Error "Failed to set AES256 encryption on computer account: $($_.Exception.Message)"
                throw
            }
            
            # Regenerate Kerberos keys after setting encryption type
            # This ensures keys are compatible with AES256 encryption
            Write-Output "Regenerating Kerberos keys for AES256 compatibility..."
            
            # Regenerate kerb1 key
            try {
                $null = Invoke-RestMethod `
                    -Body (@{keyName = 'kerb1' } | ConvertTo-Json) `
                    -Headers $AzureManagementHeader `
                    -Method 'POST' `
                    -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/regenerateKey?api-version=2023-05-01')
                Write-Output "kerb1 key regenerated"
            }
            catch {
                Write-Error "Failed to regenerate kerb1 key: $($_.Exception.Message)"
                throw
            }
            
            # Regenerate kerb2 key
            try {
                $null = Invoke-RestMethod `
                    -Body (@{keyName = 'kerb2' } | ConvertTo-Json) `
                    -Headers $AzureManagementHeader `
                    -Method 'POST' `
                    -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/regenerateKey?api-version=2023-05-01')
                Write-Output "kerb2 key regenerated"
            }
            catch {
                Write-Error "Failed to regenerate kerb2 key: $($_.Exception.Message)"
                throw
            }

            # Retrieve the new kerb1 key for password update
            try {
                $Key = ((Invoke-RestMethod `
                            -Headers $AzureManagementHeader `
                            -Method 'POST' `
                            -Uri $($ResourceManagerUri + '/subscriptions/' + $SubscriptionId + '/resourceGroups/' + $StorageAccountResourceGroupName + '/providers/Microsoft.Storage/storageAccounts/' + $StorageAccountName + '/listKeys?api-version=2023-05-01&$expand=kerb')).keys | Where-Object { $_.Keyname -contains 'kerb1' }).Value
            }
            catch {
                Write-Error "Failed to retrieve new kerb1 key: $($_.Exception.Message)"
                throw
            }
            
            # Update computer account password with new AES256-compatible key
            Write-Output "Updating computer account password with new AES256-compatible key..."
            try {
                $NewPassword = ConvertTo-SecureString -String $Key -AsPlainText -Force
                Set-ADAccountPassword -Credential $DomainCredential -Identity $DistinguishedName -Reset -NewPassword $NewPassword | Out-Null
                Write-Output "Computer account password updated successfully"
            }
            catch {
                Write-Error "Failed to update computer account password: $($_.Exception.Message)"
                throw
            }
            
            Write-Output "AES256 Kerberos encryption configuration completed successfully"
        }
        
        Write-Output "=== Storage Account $StorageAccountName processing completed ==="                
    }
    
    Write-Output "`n=== AD DS Integration Process Completed Successfully ==="
    Write-Output "Summary:"
    Write-Output "  - Processed $StCount storage accounts"
    Write-Output "  - Created computer accounts in OU: $OuPath"
    Write-Output "  - Configured Azure Files for AD DS authentication"
    if ($KerberosEncryptionType -eq 'AES256') {
        Write-Output "  - Applied AES256 Kerberos encryption for enhanced security"
    }
    Write-Output "`nStorage accounts are now ready for identity-based authentication!"
}
catch {
    Write-Error "AD DS integration failed: $($_.Exception.Message)"
    Write-Error "Full error details: $($_ | Out-String)"
    throw
}