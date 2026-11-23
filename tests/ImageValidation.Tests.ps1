BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $runPath = Join-Path $repoRoot 'deployments\add-ons\imageValidation\scripts\run.ps1'
}

Describe 'Image validation infrastructure' {
    BeforeAll {
        $compiledPath = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-ImageValidation-' + [guid]::NewGuid().ToString('N') + '.json')
        & az bicep build --file (Join-Path $repoRoot 'deployments\add-ons\imageValidation\main.bicep') --outfile $compiledPath
        if ($LASTEXITCODE -ne 0) { throw 'Image validation infrastructure did not compile.' }
        $template = Get-Content -LiteralPath $compiledPath -Raw | ConvertFrom-Json
        $app = $template.resources.functionApp.properties.parameters
        $timer = $template.resources.function.properties.parameters
        $vmTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\imageValidation\modules\validationVirtualMachine.json') -Raw | ConvertFrom-Json
    }

    AfterAll {
        if (Test-Path -LiteralPath $compiledPath) {
            Remove-Item -LiteralPath $compiledPath -Force -ErrorAction Stop
        }
    }

    It 'passes explicit resource names through to their owning resources' {
        $template.resources.rg.name | Should Be "[parameters('resourceGroupName')]"
        foreach ($binding in @(
            @{ Module = 'networkInterface'; Parameter = 'networkInterfaceName' }
            @{ Module = 'keyVault'; Parameter = 'keyVaultName' }
            @{ Module = 'templateSpec'; Parameter = 'templateSpecName' }
        )) {
            $template.resources.($binding.Module).properties.parameters.name.value |
                Should Be "[parameters('$($binding.Parameter)')]"
        }
        foreach ($name in @('functionAppName', 'storageAccountName', 'applicationInsightsName')) {
            $app.$name.value | Should Be "[parameters('$name')]"
        }
        foreach ($name in @('diskName', 'networkInterfaceName', 'virtualMachineName')) {
            $app.functionAppAppSettings.value | Should Match "parameters\('$name'\)"
        }
    }

    It 'creates a Windows Dedicated plan only when an existing plan ID is absent' {
        $template.resources.serverFarm.condition | Should Be "[empty(parameters('appServicePlanResourceId'))]"
        $plan = $template.resources.serverFarm.properties.parameters
        $plan.functionAppKind.value | Should Be 'functionapp'
        $plan.hostingPlanType.value | Should Be 'Dedicated'
        $plan.name.value | Should Be "[parameters('appServicePlanName')]"
        $plan.planPricing.value | Should Be "[format('PremiumV3_{0}', parameters('appServicePlanSku'))]"
        $app.serverFarmId | Should Match "if\(empty\(parameters\('appServicePlanResourceId'\)\)"
        $app.serverFarmId | Should Match "reference\('serverFarm'\)\.outputs\.hostingPlanId"
        $app.serverFarmId | Should Match "parameters\('appServicePlanResourceId'\)"
    }

    It 'shares the VM subnet with endpoints while keeping outbound integration separate' {
        $app.privateEndpointSubnetResourceId.value | Should Be "[parameters('subnetResourceId')]"
        $app.functionAppDelegatedSubnetResourceId.value | Should Be "[variables('integrationSubnetId')]"
        $template.resources.keyVaultPrivateEndpoint.properties.parameters.subnetResourceId.value |
            Should Be "[parameters('subnetResourceId')]"
        foreach ($variable in @('integrationSubnetId', 'blobDnsZoneId', 'appDnsZoneId', 'vaultDnsZoneId')) {
            $template.variables.$variable | Should Match "equals\(parameters\('endpointType'\), 'private'\)"
            $template.variables.$variable | Should Match "fail\('Private mode requires"
        }
    }

    It 'distinguishes private, restricted service, and unrestricted public access' {
        $app.paasPublicNetworkAccess |
            Should Be "[if(equals(parameters('endpointType'), 'private'), createObject('value', 'Disabled'), if(equals(parameters('endpointType'), 'service'), createObject('value', 'EnabledWithRestrictions'), createObject('value', 'Enabled')))]"
        $network = $template.resources.functionApp.properties.template
        $network.variables.permittedSubnetIds | Should Match "equals\(parameters\('paasPublicNetworkAccess'\), 'EnabledWithRestrictions'\)"
        foreach ($parameter in @('privateEndpointSubnetResourceId', 'functionAppDelegatedSubnetResourceId')) {
            $network.variables.permittedSubnetIds | Should Match "parameters\('$parameter'\)"
        }
        $subnetRules = $network.variables.copy | Where-Object name -eq 'permittedSubnetRestrictions'
        $subnetRules.input.vnetSubnetResourceId | Should Match "variables\('permittedSubnetIds'\)"
        $subnetRules.input.action | Should Be 'Allow'
        $network.variables.resolvedIpSecurityRestrictions | Should Match "variables\('permittedSubnetRestrictions'\)"
        $storageRules = $network.resources.storageAccount.properties.networkAcls.copy |
            Where-Object name -eq 'virtualNetworkRules'
        $storageRules.input.id | Should Match "variables\('permittedSubnetIds'\)"
        $storageRules.input.action | Should Be 'Allow'
        $network.resources.storageAccount.properties.networkAcls.defaultAction |
            Should Be "[variables('networkAccess').defaultAction]"
    }

    It 'provisions the storage key and optional disk key before Function infrastructure' {
        $keys = $template.resources.keys.properties.parameters
        $keys.keyManagementType.value | Should Be 'CustomerManagedHSM'
        $keys.keyNames.value |
            Should Be "[union(createArray(parameters('storageAccountName')), if(empty(parameters('diskEncryptionSetName')), createArray(), createArray(parameters('diskEncryptionSetName'))))]"
        $keys.keyVaultResourceId.value | Should Be "[reference('keyVault').outputs.resourceId.value]"
        $app.encryptionKeyName.value | Should Be "[parameters('storageAccountName')]"
        $app.storageEncryptionIdentityName.value | Should Be $keys.identityName.value
        ($template.resources.functionApp.dependsOn -contains 'keys') | Should Be $true
        $template.resources.diskEncryptionSet.condition | Should Be "[not(empty(parameters('diskEncryptionSetName')))]"
        ($template.resources.diskEncryptionSet.dependsOn -contains 'keys') | Should Be $true
        $app.keyManagementStorageAccounts.value | Should Be 'CustomerManagedHSM'
    }

    It 'grants the Function runtime workload permissions and scopes optional artifact identity access correctly' {
        $principal = "[reference('functionApp').outputs.functionAppPrincipalId.value]"
        $template.resources.resourceGroupRoleAssignment.properties.parameters.principalId.value | Should Be $principal
        $template.resources.resourceGroupRoleAssignment.properties.parameters.roleDefinitionId.value |
            Should Be '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
        foreach ($module in @('virtualNetworkRoleAssignment', 'keyVaultRoleAssignment', 'galleryRoleAssignment', 'templateSpecRoleAssignment')) {
            $template.resources.$module.properties.parameters.assignments.value[0].principalId | Should Be $principal
        }
        $identity = $template.resources.identityRoleAssignment
        $identity.condition | Should Be "[not(empty(parameters('artifactsUserAssignedIdentityResourceId')))]"
        $identity.subscriptionId | Should Be "[split(parameters('artifactsUserAssignedIdentityResourceId'), '/')[2]]"
        $identity.resourceGroup | Should Be "[split(parameters('artifactsUserAssignedIdentityResourceId'), '/')[4]]"
        $identity.properties.parameters.assignments.value[0].principalId | Should Be $principal
        $identity.properties.parameters.assignments.value[0].roleDefinitionId |
            Should Be 'f1a07417-d97a-45cb-824c-7a7467783830'
        $app.functionAppUserAssignedIdentityResourceId | Should BeNullOrEmpty
    }

    It 'embeds the timer source and sequences it after Function infrastructure' {
        $runContent = $timer.files.value.'run.ps1'
        if ($runContent -match "^\[variables\('([^']+)'\)\]$") {
            $runContent = $template.variables.($Matches[1])
        }
        $runContent | Should Be (Get-Content -LiteralPath $runPath -Raw)
        ($timer.files.value.PSObject.Properties.Name -contains 'requirements.psd1') | Should Be $true
        ($timer.files.value.PSObject.Properties.Name -contains '../profile.ps1') | Should Be $true
        $timer.schedule.value | Should Be "[parameters('schedule')]"
        $timer.functionName.value | Should Be 'ImageValidation'
        ($template.resources.function.dependsOn -contains 'functionApp') | Should Be $true
        $app.enableQueueStorage.value | Should Be $false
        $app.enableTableStorage.value | Should Be $false
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($runContent, [ref]$tokens, [ref]$parseErrors) | Out-Null
        $parseErrors.Count | Should Be 0
    }

    It 'forwards artifact customizations and enables them only with an artifact identity' {
        $app.functionAppAppSettings.value | Should Match "string\(parameters\('virtualMachineCustomizations'\)\)"
        $customizationType = ($template.parameters.virtualMachineCustomizations.items.'$ref' -split '/')[-1]
        $properties = $template.definitions.$customizationType.properties
        ($properties.PSObject.Properties.Name | Sort-Object) -join ',' | Should Be 'arguments,blobNameOrUri,name,successExitCodes'
        $vmTemplate.resources.customizations.condition |
            Should Be "[and(not(empty(parameters('artifactsUserAssignedIdentityResourceId'))), not(empty(parameters('vmCustomizations'))))]"
        $vmTemplate.resources.customizations.properties.parameters.customizations.value |
            Should Be "[parameters('vmCustomizations')]"
        ($vmTemplate.resources.customizations.dependsOn -contains 'virtualMachine') | Should Be $true
        $vmTemplate.resources.extension_GuestAttestation.condition |
            Should Be "[and(not(equals(parameters('securityType'), 'Standard')), variables('integrityMonitoringValidation'))]"
    }

    It 'enables monitoring only when an existing workspace is supplied' {
        $app.enableApplicationInsights.value | Should Be "[not(empty(parameters('logAnalyticsWorkspaceResourceId')))]"
        $app.logAnalyticsWorkspaceResourceId.value | Should Be "[parameters('logAnalyticsWorkspaceResourceId')]"
        $app.privateLinkScopeResourceId.value | Should Be "[parameters('privateLinkScopeResourceId')]"
    }
}

Describe 'Image validation timer HTTP handling' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $runAst = [System.Management.Automation.Language.Parser]::ParseFile($runPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'Image validation timer has parse errors.' }
        $deletionLoop = $runAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.WhileStatementAst] -and
                $node.Condition.Extent.Text -eq '$StatusCode -ne 404'
        }, $true)
    }

    BeforeEach {
        $environment = @{
            ResourceManagerUri = 'https://management.azure.com/'
            IDENTITY_ENDPOINT = 'http://identity.invalid/token'
            IDENTITY_HEADER = 'test-header'
            imageVersionResourceId = '/subscriptions/test/resourceGroups/images/providers/Microsoft.Compute/galleries/test/images/test/versions/1.0.0'
            subscriptionId = 'test'
            resourceGroupName = 'validation'
            virtualMachineName = 'validation'
            acceleratedNetworking = 'False'
            bootDiagnostics = 'False'
            encryptionAtHost = 'False'
            integrityMonitoring = 'False'
            secureBoot = 'False'
            vTpm = 'False'
            tags = '{}'
            vmCustomizations = '[]'
            templateSpecResourceId = '/subscriptions/test/resourceGroups/validation/providers/Microsoft.Resources/templateSpecs/test/versions/1.0'
        }
        $originalEnvironment = @{}
        foreach ($name in $environment.Keys) {
            $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $environment[$name])
        }
        Mock Start-Sleep {}
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body)
            $requestUri = [string]$Uri
            if ($requestUri -like 'http://identity.invalid/*') {
                return @{ access_token = 'test-token' }
            }
            if ($requestUri -match '/versions\?api-version=') {
                return @{ value = @(
                    @{ name = '1.9.0'; id = '/subscriptions/test/versions/1.9.0' }
                    @{ name = '1.10.0'; id = '/subscriptions/test/versions/1.10.0' }
                ) }
            }
            if ($requestUri -match '/versions/[^/?]+\?') {
                return @{ properties = @{
                    provisioningState = 'Succeeded'
                    replicationStatus = @{ aggregatedState = 'Completed' }
                } }
            }
            if ($Method -eq 'PUT' -and $requestUri -match '/deployments/ImageValidation-') {
                return @{ properties = @{ provisioningState = 'Accepted' } }
            }
            throw "Unexpected mocked request: $Method $requestUri"
        }
        Mock Invoke-RestMethod -ParameterFilter {
            $Method -eq 'Get' -and [string]$Uri -match '/virtualMachines/'
        } -MockWith {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Simulated VM lookup failure', $response)
        }
    }

    AfterEach {
        foreach ($name in $originalEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
        }
    }

    It 'handles a missing VM and submits the numerically latest image without deleting anything' {
        & $runPath | Out-Null
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Delete' }
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $Method -eq 'PUT' -and
                ($Body | ConvertFrom-Json).properties.parameters.imageVersionResourceId.value -eq '/subscriptions/test/versions/1.10.0'
        }
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            [string]$Uri -like '*&$expand=ReplicationStatus'
        }
    }

    It 'does not treat HTTP <Status> as a missing VM' -TestCases @(
        @{ Status = 403 }
        @{ Status = 500 }
    ) {
        param($Status)
        Mock Invoke-RestMethod -ParameterFilter {
            $Method -eq 'Get' -and [string]$Uri -match '/virtualMachines/'
        } -MockWith ({
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Status)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Simulated VM lookup failure', $response)
        }.GetNewClosure())
        { & $runPath | Out-Null } | Should Throw 'Failed to get virtual machine'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'PUT' -or $Method -eq 'Delete' }
    }

    It 'ends deletion polling on an expected 404 without sleeping or retrying' {
        $deletionLoop | Should Not BeNullOrEmpty
        $ResourceManagerUriFixed = $env:ResourceManagerUri.TrimEnd('/')
        $Header = @{}
        $StatusCode = $null
        $StatusCounter = 0
        Invoke-Expression $deletionLoop.Extent.Text
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter { $Method -eq 'Get' }
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        $StatusCounter | Should Be 0
    }
}
