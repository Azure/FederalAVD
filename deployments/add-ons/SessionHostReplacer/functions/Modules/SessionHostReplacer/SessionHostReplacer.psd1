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
        'Get-ResourceManagerUri'
        'Get-GraphEndpoint'
        'Get-AccessToken'
        'Read-FunctionAppSetting'
        'Set-HostPoolNameForLogging'
        'Write-HostDetailed'
        'Invoke-AzureRestMethodWithRetry'
        'Invoke-GraphApiWithRetry'
        'Invoke-AzureRestMethod'
        'Get-DeploymentState'
        'Get-LastDeploymentStatus'
        'Save-DeploymentState'
        'ConvertTo-CaseInsensitiveHashtable'
        'Deploy-SessionHosts'
        'Get-LatestImageVersion'
        'Get-HostPoolDecisions'
        'Get-RunningDeployments'
        'Get-SessionHosts'
        'Get-TemplateSpecVersionResourceId'
        'Remove-SessionHosts'
        'Remove-EntraDevice'
        'Remove-IntuneDevice'
        'Send-DrainNotification'
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
