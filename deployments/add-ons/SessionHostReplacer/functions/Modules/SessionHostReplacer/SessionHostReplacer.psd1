@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'SessionHostReplacer.psm1'

    # Version number of this module.
    ModuleVersion = '1.0.0'

    # ID used to uniquely identify this module
    GUID = 'a7f8e3b2-c4d1-4e9a-8b6c-f2d5e7a9c1b3'

    # Author of this module
    Author = 'Azure AVD Team'

    # Company or vendor of this module
    CompanyName = 'Microsoft'

    # Copyright statement for this module
    Copyright = '(c) Microsoft Corporation. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Session Host Replacer Module - Provides core functions for AVD session host lifecycle management including authentication, configuration, logging, and Azure Table Storage operations.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.2'

    # Functions to export from this module
    FunctionsToExport = @(
        # Core utilities (from SessionHostReplacer.Core.psm1)
        'Get-ResourceManagerUri'
        'Get-GraphEndpoint'
        'Get-AccessToken'
        'Read-FunctionAppSetting'
        'Set-HostPoolNameForLogging'
        'Write-LogEntry'
        'Invoke-AzureRestMethod'
        'Invoke-AzureRestMethodWithRetry'
        'Invoke-GraphRestMethod'
        'Invoke-GraphApiWithRetry'
        'ConvertTo-CaseInsensitiveHashtable'
        'Get-VMPowerStates'
        
        # Deployment functions (from SessionHostReplacer.Deployment.psm1)
        'Get-DeploymentState'
        'Get-LastDeploymentStatus'
        'Save-DeploymentState'
        'Deploy-SessionHosts'
        'Get-Deployments'
        'Get-TemplateSpecVersionResourceId'
        'Remove-FailedDeploymentArtifacts'
        
        # Image Management functions (from SessionHostReplacer.ImageManagement.psm1)
        'Compare-ImageVersion'
        'Get-LatestImageVersion'
        
        # Planning functions (from SessionHostReplacer.Planning.psm1)
        'Get-SessionHostReplacementPlan'
        'Get-SessionHosts'
        'Get-ScalingPlanCurrentTarget'
        
        # Lifecycle functions (from SessionHostReplacer.Lifecycle.psm1)
        'Remove-SessionHosts'
        'Remove-VirtualMachine'
        'Remove-ExpiredShutdownVMs'
        'Send-DrainNotification'
        'Test-NewSessionHostsAvailable'
        
        # Device Cleanup functions (from SessionHostReplacer.DeviceCleanup.psm1)
        'Remove-DeviceFromDirectories'
        'Remove-EntraDevice'
        'Remove-IntuneDevice'
        'Confirm-SessionHostDeletions'
        
        # Monitoring functions (from SessionHostReplacer.Monitoring.psm1)
        'Update-HostPoolStatus'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
            # Tags applied to this module
            Tags = @('Azure', 'AVD', 'SessionHost', 'Automation', 'Functions')

            # ReleaseNotes of this module
            ReleaseNotes = 'Initial release - Core helper functions for Session Host Replacer'
        }
    }
}
