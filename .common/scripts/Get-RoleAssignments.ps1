param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceManagerUri,

    [Parameter(Mandatory=$true)]
    [string[]]$ResourceIds,

    [Parameter(Mandatory=$true)]
    [string]$UserAssignedIdentityClientId,

    [Parameter(Mandatory=$true)]
    [string]$PrincipalId,

    [Parameter(Mandatory=$true)]
    [string]$RoleDefinitionId
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

[array]$ResIds = $ResourceIds.replace('\"', '"') | ConvertFrom-Json

Try {
    # Fix the resource manager URI since only AzureCloud contains a trailing slash
    $ResourceManagerUriFixed = if($ResourceManagerUri[-1] -eq '/'){$ResourceManagerUri.Substring(0,$ResourceManagerUri.Length - 1)} else {$ResourceManagerUri}

    # Get an access token for Azure resources
    $AzureManagementAccessToken = (Invoke-RestMethod -Headers @{Metadata="true"} -Uri $('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' + $ResourceManagerUriFixed + '&client_id=' + $UserAssignedIdentityClientId)).access_token

    # Set header for Azure Management API
    $AzureManagementHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $AzureManagementAccessToken
    }

    # Loop through each resource ID to find the role assignment
    Write-Output "Searching for role assignment for Principal '$PrincipalId' with Role '$RoleDefinitionId' across $($ResIds.Count) resource(s)"
    
    $StartTime = Get-Date
    $TimeoutSeconds = 180
    $FoundRoleAssignments = @{}
    $Attempt = 1

    do {
        Write-Output "Attempt $Attempt - Checking for role assignment across all resources..."
        
        foreach ($ResourceId in $ResIds) {
            # Skip if we already found the role assignment for this resource
            if ($FoundRoleAssignments.ContainsKey($ResourceId)) {
                continue
            }
            
            Write-Output "  Checking resource id: $ResourceId"
            
            # Construct the API URL for role assignments for the specific resource
            $RoleAssignmentsUri = $ResourceManagerUriFixed + $ResourceId + '/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
            
            try {
                # Query role assignments for the resource
                $RoleAssignments = Invoke-RestMethod -Headers $AzureManagementHeader -Method 'GET' -Uri $RoleAssignmentsUri

                # Look for the specific role assignment matching both PrincipalId and RoleDefinitionId
                $TargetRoleAssignment = $RoleAssignments.value.properties | Where-Object { 
                    $_.principalId -eq $PrincipalId -and 
                    $_.roleDefinitionId -eq $RoleDefinitionId 
                }

                if ($TargetRoleAssignment) {
                    $FoundRoleAssignments[$ResourceId] = $TargetRoleAssignment
                    Write-Output "  Role assignment found on resource id '$ResourceId'"
                } else {
                    Write-Output "  Role assignment not found on resource id '$ResourceId'"
                }
            }
            catch {
                Write-Warning "  Failed to query role assignments for resource id '$ResourceId': $($_.Exception.Message)"
                continue
            }
        }
        $ElapsedTime = (Get-Date) - $StartTime
        # Check if we found role assignments for all resources
        $AllResourcesHaveAssignment = $FoundRoleAssignments.Count -eq $ResIds.Count
        
        if ($AllResourcesHaveAssignment) {
            Write-Output "Role assignment found on all $($ResIds.Count) resources after $($ElapsedTime.TotalSeconds) seconds."
            break
        }

        if ($ElapsedTime.TotalSeconds -ge $TimeoutSeconds) {
            break
        }

        $MissingCount = $ResIds.Count - $FoundRoleAssignments.Count
        Write-Output "Role assignment found on $($FoundRoleAssignments.Count)/$($ResIds.Count) resources. Still missing $MissingCount. Waiting 5 seconds before retry..."
        Start-Sleep -Seconds 5
        $Attempt++
    } while ($ElapsedTime.TotalSeconds -lt $TimeoutSeconds)

    if ($FoundRoleAssignments.Count -eq 0) {
        $ErrorMessage = "Role assignment not found on any resources after $TimeoutSeconds seconds. Principal ID: '$PrincipalId', Role Definition ID: '$RoleDefinitionId', Resources checked: $($ResIds -join ', ')"
        Write-Error $ErrorMessage
        throw $ErrorMessage
    } elseif ($FoundRoleAssignments.Count -lt $ResIds.Count) {
        $MissingResources = $ResIds | Where-Object { -not $FoundRoleAssignments.ContainsKey($_) }
        $ErrorMessage = "Role assignment not found on all resources after $TimeoutSeconds seconds. Principal ID: '$PrincipalId', Role Definition ID: '$RoleDefinitionId'. Missing on resources: $($MissingResources -join ', ')"
        Write-Error $ErrorMessage
        throw $ErrorMessage
    }
}
catch {
    Write-Error "Error querying role assignments: $($_.Exception.Message)"
    throw
}
