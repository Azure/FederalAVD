param 
(       
    [Parameter(Mandatory = $false)]
    [string]$AdminGroupNames,

    [Parameter(Mandatory = $true)]
    [String]$Shares,

    [Parameter(Mandatory = $true)]
    [String]$DomainJoinUserPwd,

    [Parameter(Mandatory = $true)]
    [String]$DomainJoinUserPrincipalName,

    [Parameter(Mandatory = $false)]
    [String]$NetAppServers,

    [Parameter(Mandatory = $false)]
    [String]$UserGroupNames
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

Function Update-ACL {
    Param (
        [Parameter(Mandatory = $false)]
        [Array]$AdminGroups,
        [Parameter(Mandatory = $true)]
        [pscredential]$Credential,
        [Parameter(Mandatory = $true)]
        [String]$FileShare,
        [Parameter(Mandatory = $true)]
        [Array]$UserGroups
    )
    # Map Drive
    Write-Output "[Update-ACL]: Mapping Drive to $FileShare"
    New-PSDrive -Name 'Z' -PSProvider 'FileSystem' -Root $FileShare -Credential $Credential | Out-Null
    # Set recommended NTFS permissions on the file share
    Write-Output "[Update-ACL]: Getting Existing ACL for $FileShare"
    $ACL = Get-Acl -Path 'Z:'
    $CreatorOwner = [System.Security.Principal.Ntaccount]("Creator Owner")
    Write-Output "[Update-ACL]: Purging Existing Access Control Entries for 'Creater Owner' from ACL"
    $ACL.PurgeAccessRules($CreatorOwner)
    $AuthenticatedUsers = [System.Security.Principal.Ntaccount]("Authenticated Users")
    Write-Output "[Update-ACL]: Purging Existing Access Control Entries for 'Authenticated Users' from ACL"
    $ACL.PurgeAccessRules($AuthenticatedUsers)
    $Users = [System.Security.Principal.Ntaccount]("Users")
    Write-Output "[Update-ACL]: Purging Existing Access Control Entries for 'Users' from ACL"
    $ACL.PurgeAccessRules($Users)
    If ($AdminGroups.Count -gt 0) {
        ForEach ($Group in $AdminGroups) {
            Write-Output "[Update-ACL]: Adding ACE '$($Group):Full Control' to ACL."
            $Ntaccount = [System.Security.Principal.Ntaccount]("$Group")
            $ACE = ([System.Security.AccessControl.FileSystemAccessRule]::new("$Ntaccount", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
            $ACL.SetAccessRule($ACE)
        }
    }
    ForEach ($Group in $UserGroups) {
        Write-Output "[Update-ACL]: Adding ACE '$($Group):Modify (This Folder Only)' to ACL."
        $Ntaccount = [System.Security.Principal.Ntaccount]("$Group")
        $ACE = ([System.Security.AccessControl.FileSystemAccessRule]::new("$Ntaccount", "Modify", "None", "None", "Allow"))
        $ACL.SetAccessRule($ACE)
    }
    Write-Output "[Update-ACL]: Adding ACE 'Creator Owner:Modify (Subfolder and Files Only)' to ACL."
    $ACE = ([System.Security.AccessControl.FileSystemAccessRule]::new("$CreatorOwner", "Modify", "ContainerInherit,ObjectInherit", "InheritOnly", "Allow"))
    $ACL.SetAccessRule($ACE)
    Write-Output "[Update-ACL]: Applying the following ACL to $($FileShare):"
    Write-Output "$($ACL.access | Format-Table | Out-String)"
    $ACL | Set-Acl -Path 'Z:' | Out-Null
    Start-Sleep -Seconds 5 | Out-Null
    $ACL = Get-Acl -Path 'Z:'
    Write-Output "[Update-ACL]: Current ACL of $($FileShare):"
    Write-Output "$($ACL.access | Format-Table | Out-String)"
    # Unmount file share
    Write-Output "[Update-ACL]: Unmapping Drive from $FileShare"
    Remove-PSDrive -Name 'Z' -PSProvider 'FileSystem' -Force | Out-Null
    Start-Sleep -Seconds 5 | Out-Null
}

try {   

    # Convert Parameters passed as a JSON String to an array and remove any backslashes
    if ($AdminGroupNames -and $AdminGroupNames.Trim() -and $AdminGroupNames.Trim() -ne '[]') {
        $AdminGroups = $AdminGroupNames.replace('\"', '"') | ConvertFrom-Json
    }   
    if ($UserGroupNames -and $UserGroupNames.Trim() -and $UserGroupNames.Trim() -ne '[]') {
        $UserGroups = $UserGroupNames.replace('\"', '"') | ConvertFrom-Json
    }
    [array]$NetAppServers = $NetAppServers.replace('\"', '"') | ConvertFrom-Json
    [array]$Shares = $Shares.replace('\"', '"') | ConvertFrom-JsonString

    # Create Domain credential
    $DomainJoinUserName = $DomainJoinUserPrincipalName.Split('@')[0]
    $DomainPassword = ConvertTo-SecureString -String $DomainJoinUserPwd -AsPlainText -Force
    [pscredential]$DomainCredential = New-Object System.Management.Automation.PSCredential ($DomainJoinUserName, $DomainPassword)
  
    $ProfileShare = "\\$($NetAppServers[0])\$($Shares[0])"
    Write-Output "Processing Profile Share: $ProfileShare"
    if ($AdminGroupNames.Count -gt 0) {
        Write-Output "Admin Groups and UserGroups provided, executing Update-ACL with Admin Groups and UserGroups"
        Update-ACL -AdminGroups $AdminGroupNames -Credential $DomainCredential -FileShare $ProfileShare -UserGroups $UserGroupNames
    }
    Else {
        Write-Output "UserGroups provided, executing Update-ACL with UserGroups only"
        Update-ACL -Credential $DomainCredential -FileShare $ProfileShare -UserGroups $UserGroupNames
    }
            
    If ($NetAppServers.Count -gt 1 -and $Shares.Count -gt 1) {
        $OfficeShare = "\\" + $NetAppServers[1] + "\" + $Shares[1]
        Write-Output "Processing Office Share: $OfficeShare"
        If ($AdminGroupNames.Count -gt 0) {
            Write-Output "Admin Groups and UserGroups provided, executing Update-ACL with Admin Groups and UserGroups"
            Update-ACL -AdminGroups $AdminGroupNames -Credential $DomainCredential -FileShare $OfficeShare -UserGroups $UserGroupNames
        }
        Else {
            Write-Output "UserGroups provided, executing Update-ACL with UserGroups only"
            Update-ACL -Credential $DomainCredential -FileShare $OfficeShare -UserGroups $UserGroupNames
        }
    }
}
catch {
    throw
}