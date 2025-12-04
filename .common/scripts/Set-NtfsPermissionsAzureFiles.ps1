<#
.SYNOPSIS
    Sets NTFS permissions on Azure File Shares using REST API and SDDL strings.

.DESCRIPTION
    This script configures NTFS permissions on Azure File Shares by:
    1. Converting group names/objects from JSON to Security Identifiers (SIDs)
    2. Building SDDL (Security Descriptor Definition Language) strings
    3. Creating Azure Storage Account computer objects in Active Directory
    4. Setting permissions via Azure Files REST API

    Supports both single and sharded storage account scenarios.

.PARAMETER AdminGroups
    JSON array of administrator groups (strings or objects with GroupName/DomainName/SID properties)

.PARAMETER Shares
    JSON array of file share names to configure

.PARAMETER ShardAzureFilesStorage
    Boolean string ("true"/"false") indicating if storage accounts are sharded per user group

.PARAMETER StorageAccountPrefix
    Prefix for storage account names (e.g., "stavd")

.PARAMETER StorageCount
    Number of storage accounts to process

.PARAMETER StorageIndex
    Starting index for storage account numbering

.PARAMETER StorageSuffix
    Storage endpoint suffix (e.g., "core.windows.net")

.PARAMETER UserGroups
    JSON array of user groups (strings or objects with groupName/domainName/sid properties)

.PARAMETER UserAssignedIdentityClientId
    Client ID of the user-assigned managed identity for Azure API authentication

.EXAMPLE
    .\Set-NtfsPermissions-sa.ps1 -Shares '["profiles","office"]' -UserGroups '["Domain Users"]'

.NOTES
    Requires:
    - Active Directory PowerShell module
    - User-assigned managed identity with appropriate permissions
    - Storage accounts with Azure Files enabled
#>

param 
(       
    [string]$AdminGroups,

    [String]$Shares,

    [string]$ShardAzureFilesStorage,    

    [String]$StorageAccountPrefix,

    [String]$StorageCount,

    [String]$StorageIndex,

    [String]$StorageSuffix,

    [string]$UserAssignedIdentityClientId,
    
    [String]$UserGroups
)

# Configure error handling and output preferences
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

#region Functions

function Convert-EntraIdObjectIdToSid {
    [CmdletBinding()]
    param([String] $ObjectId)

    $bytes = [Guid]::Parse($ObjectId).ToByteArray()
    $array = New-Object 'UInt32[]' 4

    [Buffer]::BlockCopy($bytes, 0, $array, 0, 16)
    $EntraIdSid = "S-1-12-1-$array".Replace(' ', '-')

    return $EntraIdSid
}

Function Convert-DomainGroupToSid {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string]$DomainName,

        [Parameter(Mandatory = $true)]    
        [string]$GroupName
    )
    [string]$DomainSid = ''
    Try {
        $DomainSid = (New-Object System.Security.Principal.NTAccount("$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value           
    }
    Catch {
        Try {
            $DomainSid = (New-Object System.Security.Principal.NTAccount($DomainName, "$GroupName")).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        Catch {
            throw "Failed to convert group name $GroupName' to SID."
        }
    }          
    Return $DomainSid
}    

Function Set-AzureFileSharePermissions {
    param(
        [string]$ClientId,    
        [string]$FileShareName,
        [string]$StorageAccountName,
        [string]$StorageSuffix,
        [string]$SDDLString
    )

    try {
        Write-Output "[Set-AzureFileSharePermissions]: Setting NTFS permissions on Azure File Share: $FileShareName"        
        $ResourceUrl = 'https://' + $StorageAccountName + '.file.' + $StorageSuffix + '/'
        Write-Output "[Set-AzureFileSharePermissions]: Resource URL: $ResourceUrl"
        # Get access token for Azure Files
        Write-Output "[Set-AzureFileSharePermissions]: Getting access token for Azure File Storage Account"
        $AccessToken = (Invoke-RestMethod -Headers @{Metadata = "true" } -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceUrl + '&client_id=' + $ClientId)).access_token

        # Step 1: Create Permission - Convert SDDL to permission key
        Write-Output "[Set-AzureFileSharePermissions]: Creating permission key from SDDL"
        $Headers = @{
            'Authorization'            = 'Bearer ' + $AccessToken
            'Content-Type'             = 'application/json'
            'x-ms-date'                = (Get-Date).ToUniversalTime().ToString('R')
            'x-ms-version'             = '2024-11-04'
            'x-ms-file-request-intent' = 'backup'
        }
        
        $Body = @{
            permission = $SDDLString
            format     = 'sddl'
        } | ConvertTo-Json
        
        $Uri = $($ResourceUrl + $FileShareName + '?restype=share&comp=filepermission')
        Write-Output "[Set-AzureFileSharePermissions]: Creating permission with URI: $Uri"

        $Response = Invoke-WebRequest -Body $Body -Headers $Headers -Method 'PUT' -Uri $Uri -UseBasicParsing
        $PermissionKey = $Response.Headers["x-ms-file-permission-key"]
        
        if (-not $PermissionKey) {
            throw "Failed to create permission key. Response Headers: $($Response.Headers | ConvertTo-Json -Depth 3)"
        }
        
        Write-Output "[Set-AzureFileSharePermissions]: Permission key created: $PermissionKey"

        # Step 2: Get Directory Properties to ensure directory exists
        Write-Output "[Set-AzureFileSharePermissions]: Getting directory properties"
        $Headers = @{
            'Authorization'            = 'Bearer ' + $AccessToken
            'x-ms-version'             = '2024-11-04'
            'x-ms-date'                = (Get-Date).ToUniversalTime().ToString('R')
            'x-ms-file-request-intent' = 'backup'
        }
        
        $GetUri = $($ResourceUrl + $FileShareName + '?restype=directory')
        try {
            Invoke-WebRequest -Headers $Headers -Method 'GET' -Uri $GetUri -UseBasicParsing | Out-Null
            Write-Output "[Set-AzureFileSharePermissions]: Directory properties retrieved successfully"
        }
        catch {
            Write-Output "[Set-AzureFileSharePermissions]: Directory may not exist or error getting properties: $($_.Exception.Message)"
        }

        # Step 3: Set Directory Properties with the permission key
        Write-Output "[Set-AzureFileSharePermissions]: Setting directory properties with permission key"
        $Headers = @{
            'Authorization'             = 'Bearer ' + $AccessToken
            'x-ms-date'                 = (Get-Date).ToUniversalTime().ToString('R')
            'x-ms-version'              = '2024-11-04'
            'x-ms-file-request-intent'  = 'backup'
            'x-ms-file-creation-time'   = 'preserve'
            'x-ms-file-last-write-time' = 'preserve'
            'x-ms-file-change-time'     = 'now'
            'x-ms-file-permission-key'  = $PermissionKey
        }
        
        $SetUri = $($ResourceUrl + $FileShareName + '?restype=directory&comp=properties')
        Write-Output "[Set-AzureFileSharePermissions]: Setting properties with URI: $SetUri"
        
        Invoke-WebRequest -Headers $Headers -Method 'PUT' -Uri $SetUri -UseBasicParsing | Out-Null
        Write-Output "[Set-AzureFileSharePermissions]: Successfully set NTFS permissions on file share root"
    }
    catch {
        Write-Error "[Set-AzureFileSharePermissions]: Failed to set NTFS permissions: $($_.Exception.Message)"
        Write-Error "[Set-AzureFileSharePermissions]: Full error: $($_ | Out-String)"
        throw
    }
}

#endregion Functions

#region Main Script
Start-Transcript -Path "c:\Windows\Logs\Set-NtfsPermissionsAzureFiles-$(Get-Date -Format 'yyyyMMdd-HHmm').log" -Force
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $DefaultDomain = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty Domain
    Write-Output "Default Domain: $DefaultDomain"
  
    # Convert Admin Groups to SIDs if provided
    [array]$AdminGroupSids = @() 
    if ($AdminGroups -and $AdminGroups -ne '[]') {
        Write-Output "Processing Admin Groups..."
        [array]$AdminGroupsArray = $AdminGroups.replace('\"', '"') | ConvertFrom-Json
        ForEach ($AdminGroup in $AdminGroupsArray) {
            Write-Output "  Admin Group: $AdminGroup"
            $output = [guid]::Empty
            if ([guid]::TryParse($AdminGroup, [ref]$output)) {
                # It's a valid GUID, convert to SID
                $sid = Convert-EntraIdObjectIdToSid -ObjectId $AdminGroup
                Write-Output "Converted Admin Group with ObjectId '$AdminGroup' to SID '$sid'"
                $AdminGroupSids += $sid
            }
            Else {
                # Not a GUID, treat as group name
                $sid = Convert-DomainGroupToSID -DomainName $DefaultDomain -GroupName $AdminGroup
                Write-Output "Converted Admin Group with GroupName '$AdminGroup' to SID '$sid'"
                $AdminGroupSids += $sid
            }
        }
    }
    
    # Convert User Groups to SIDs if provided
    [array]$UserGroupSids = @()
    if ($UserGroups -and $UserGroups -ne '[]') {
        [array]$UserGroupsArray = $UserGroups.replace('\"', '"') | ConvertFrom-Json
        Write-Output "Processing User Groups..."
        ForEach ($UserGroup in $UserGroupsArray) {
            Write-Output "User Group: $UserGroup"
            $output = [guid]::Empty
            if ([guid]::TryParse($UserGroup, [ref]$output)) {
                # It's a valid GUID, convert to SID
                $sid = Convert-EntraIdObjectIdToSid -ObjectId $UserGroup
                Write-Output "Converted User Group with ObjectId '$UserGroup' to SID '$sid'"
                $UserGroupSids += $sid
            }
            Else {
                # Not a GUID, treat as group name
                $sid = Convert-DomainGroupToSID -DomainName $DefaultDomain -GroupName $UserGroup
                Write-Output "Converted User Group with GroupName '$UserGroup' to SID '$sid'"
                $UserGroupSids += $sid
            }
        }
    }

    # Base SDDL string with default permissions:
    # O:BA = Owner: Built-in Administrators
    # G:SY = Group: System
    # D:PAI = DACL: Protected, Auto-Inherited
    # (A;OICIIO;0x1301bf;;;CO) = Allow Object/Container Inherit, Creator Owner: Modify
    # (A;OICI;FA;;;SY) = Allow Object/Container Inherit, System: Full Access
    # (A;OICI;FA;;;BA) = Allow Object/Container Inherit, Built-in Administrators: Full Access
    $SDDLStartString = 'O:BAG:SYD:PAI(A;OICIIO;0x1301bf;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    $SDDLBuiltInUsersString = '(A;;0x1301bf;;;BU)'

    # Build SDDL entries for admin groups if provided
    if ($AdminGroupSids.Count -gt 0) {
        $SDDLAdminGroupsString = @()
        ForEach ($GroupSid in $AdminGroupSids) {    
            $SDDLAdminGroupsString += '(A;OICI;FA;;;' + $GroupSid + ')'
        }
    }

    # Build SDDL entries for user groups if provided
    if ($UserGroupSids.Count -gt 0) {
        $SDDLUserGroupsString = @()
        ForEach ($GroupSid in $UserGroupSids) {    
            # Add ACE (Access Control Entry) for user group with Modify permissions
            # (A;;0x1301bf;;;SID) = Allow, Modify rights (0x1301bf), for specific SID
            $SDDLUserGroupsString += '(A;;0x1301bf;;;' + $GroupSid + ')'
        }
    }
   
    # Parse and clean configuration parameters
    [array]$Shares = $Shares.Replace('\"', '"') | ConvertFrom-Json  
    [int]$StCount = $StorageCount.replace('\"', '"')  # Number of storage accounts to process
    [int]$StIndex = $StorageIndex.replace('\"', '"')  # Starting index for storage account naming
    $StorageAccountPrefix = $StorageAccountPrefix.ToLower().replace('\"', '"')  # Storage account name prefix     
    $UserAssignedIdentityClientId = $UserAssignedIdentityClientId.replace('\"', '"')  # Managed identity for Azure API calls    
    # Build Azure Files endpoint suffix
    $FilesSuffix = ".file.$($StorageSuffix.Replace('\"', '"'))" 
    # Process each storage account in the range
    for ($i = 0; $i -lt $StCount; $i++) {
        # Generate storage account name with zero-padded index (e.g., "stavd01", "stavd02")
        $StorageAccountName = $StorageAccountPrefix + ($i + $StIndex).ToString().PadLeft(2, '0')
        Write-Output "Processing Storage Account Name: $StorageAccountName"
        
        # Build UNC path and HTTPS URL for the storage account
        $FileServer = '\\' + $StorageAccountName + $FilesSuffix  # UNC: \\stavd01.file.core.windows.net
        $ResourceUrl = 'https://' + $StorageAccountName + $FilesSuffix  # HTTPS: https://stavd01.file.core.windows.net
        if ($AdminGroupSids.Count -eq 0 -and $UserGroupSids.Count -eq 0) {
            Write-Output "No Admin or User Groups provided, Setting default permissions for $StorageAccountName"
            $SDDLString = ($SDDLStartString + $SDDLBuiltInUsersString) -replace ' ', ''
            foreach ($Share in $Shares) {
                Set-AzureFileSharePermissions -FileShareName $Share -StorageAccountName $StorageAccountName -StorageSuffix $StorageSuffix -SDDLString $SDDLString -ClientId $UserAssignedIdentityClientId
                Write-Output "Successfully set default NTFS permissions on file share '$Share' in storage account '$StorageAccountName'"
            }            
        }
        Elseif ($ShardAzureFilesStorage -eq 'true') {
            # Check if storage is sharded (different user groups per storage account)
            # SHARDED MODE: Each storage account gets a specific user group
            foreach ($Share in $Shares) {
                if ($AdminGroupSids.Count -gt 0 -and $UserGroupSids.Count -gt 0) {
                    Write-Output "Admin Groups provided, building SDDL String with Admin Groups"
                    # Build SDDL with admin groups + specific user group for this storage account index
                    $SDDLString = ($SDDLStartString + $SDDLAdminGroupsString + $SDDLUserGroupsString[$i]) -replace ' ', ''
                }
                Else {
                    Write-Output "Admin Groups not provided, building SDDL string without Admin Groups"
                    # Build SDDL with only the specific user group for this storage account index
                    $SDDLString = ($SDDLStartString + $SDDLUserGroupsString[$i]) -replace ' ', ''
                }
                Set-AzureFileSharePermissions -FileShareName $Share -StorageAccountName $StorageAccountName -StorageSuffix $StorageSuffix -SDDLString $SDDLString -ClientId $UserAssignedIdentityClientId
                Write-Output "Successfully set NTFS permissions on file share '$Share' in storage account '$StorageAccountName'"                
            }
        }
        Else {
            # NON-SHARDED MODE: All storage accounts get the same user groups
            foreach ($Share in $Shares) {
                $FileShare = $FileServer + '\' + $Share
                Write-Output "Processing File Share: $FileShare"
                if ($AdminGroupSids.Count -gt 0 -and $UserGroupSids.Count -gt 0) {
                    Write-Output "Admin Groups provided, building SDDL string with Admin Groups"
                    # Build SDDL with admin groups + all user groups
                    $SDDLString = ($SDDLStartString + $SDDLAdminGroupsString + $SDDLUserGroupsString) -replace ' ', ''
                }
                Else {
                    Write-Output "Admin Groups not provided, building SDDL string without Admin Groups"
                    # Build SDDL with only user groups
                    $SDDLString = ($SDDLStartString + $SDDLUserGroupsString) -replace ' ', ''
                }
                # Apply permissions to the file share using Azure Files REST API
                Set-AzureFileSharePermissions -FileShareName $Share -StorageAccountName $StorageAccountName -StorageSuffix $StorageSuffix -SDDLString $SDDLString -ClientId $UserAssignedIdentityClientId
                Write-Output "Successfully set NTFS permissions on file share '$Share' in storage account '$StorageAccountName'"                
            }
        }
    }
    Write-Output "Completed setting NTFS permissions on all specified Azure File Shares."
    Stop-Transcript
}       
catch {
    throw
}
#endregion Main Script