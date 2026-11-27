BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $templates = @{}
    foreach ($name in @('sessionHostReplacer', 'imageValidation', 'fslogixProfileManagement')) {
        $path = Join-Path $repoRoot "deployments\add-ons\$name\main.json"
        $templates[$name] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
    }
    $app = $templates.sessionHostReplacer.resources.functionApp.properties.template
    $plan = $templates.sessionHostReplacer.resources.hostingPlan.properties.template
    $function = $templates.sessionHostReplacer.resources.functionCode.properties.template
    $extensions = @{}
    $extensionDirectory = Join-Path $repoRoot 'deployments\shared\modules\resourceModules\compute\virtualMachines\extensions'
    foreach ($file in Get-ChildItem -LiteralPath $extensionDirectory -Filter *.bicep) {
        $output = Join-Path $TestDrive "$($file.BaseName).json"
        $diagnostics = @(& az bicep build --file $file.FullName --outfile $output 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Extension compilation failed: $($file.FullName): $($diagnostics -join [Environment]::NewLine)"
        }
        $extensions[$file.BaseName] = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 100
    }
}

Describe 'Function App and VM extension module ownership' {
    It 'keeps app infrastructure composition separate from plan and code resources' {
        $resourceTypes = @($app.resources.PSObject.Properties.Value.type)
        $resourceTypes | Should -Contain 'Microsoft.Storage/storageAccounts'
        $resourceTypes | Should -Contain 'Microsoft.Web/sites'
        $resourceTypes | Should -Not -Contain 'Microsoft.Web/serverfarms'
        $resourceTypes | Should -Not -Contain 'Microsoft.Web/sites/functions'
        $app.parameters.serverFarmId.type | Should -Be 'string'
    }

    It 'keeps the hosting plan a single independently scoped resource' {
        @($plan.resources).Count | Should -Be 1
        $plan.resources[0].type | Should -Be 'Microsoft.Web/serverfarms'
        $plan.outputs.hostingPlanId.type | Should -Be 'string'
        $templates.sessionHostReplacer.resources.hostingPlan.resourceGroup |
            Should -Be "[variables('aspResourceGroupName')]"
        $templates.sessionHostReplacer.resources.functionApp.resourceGroup |
            Should -Be "[parameters('functionAppResourceGroupName')]"
    }

    It 'preserves existing-plan adoption in <Consumer>' -TestCases @(
        @{ Consumer = 'sessionHostReplacer'; Module = 'hostingPlan'; Parameter = 'existingAppServicePlanResourceId' }
        @{ Consumer = 'imageValidation'; Module = 'serverFarm'; Parameter = 'appServicePlanResourceId' }
        @{ Consumer = 'fslogixProfileManagement'; Module = 'serverFarm'; Parameter = 'appServicePlanResourceId' }
    ) {
        param($Consumer, $Module, $Parameter)

        $templates[$Consumer].resources.$Module.condition |
            Should -Be "[empty(parameters('$Parameter'))]"
        ($templates[$Consumer].resources.functionApp.properties.parameters.serverFarmId | ConvertTo-Json -Compress) |
            Should -Match ([regex]::Escape("parameters('$Parameter')"))
    }

    It 'keeps timer code deployment independent of app infrastructure' {
        @($function.resources).Count | Should -Be 1
        $function.resources[0].type | Should -Be 'Microsoft.Web/sites/functions'
        $function.parameters.functionAppName.type | Should -Be 'string'
        $function.variables.triggerBinding.type | Should -Be 'timerTrigger'
        $function.variables.triggerBinding.name | Should -Be 'Timer'
        $function.variables.triggerBinding.schedule | Should -Match 'fail\('
    }

    It 'preserves separate initiator and worker schedules and serializes shared-file writes' {
        $replacer = $templates.sessionHostReplacer
        $replacer.resources.functionCode.properties.parameters.schedule.value | Should -Be '%TimerSchedule%'
        $replacer.resources.workerCode.properties.parameters.schedule.value | Should -Be '%ContinuationTimerSchedule%'
        $replacer.resources.workerCode.dependsOn | Should -Contain 'functionCode'
        $replacer.resources.functionCode.properties.parameters.files.value | Should -Match 'sharedFunctionFiles'
        $replacer.variables.sharedFunctionFiles.PSObject.Properties.Name |
            Should -Contain '../host.json'
        $replacer.resources.workerCode.properties.parameters.files.value.PSObject.Properties.Name |
            Should -Not -Contain '../host.json'
    }

    It 'keeps <Name> under the VM family with one extension resource' -TestCases @(
        @{ Name = 'amdGpuDriver' }
        @{ Name = 'azureMonitorAgent' }
        @{ Name = 'customScriptExtension' }
        @{ Name = 'domainJoin' }
        @{ Name = 'entraLogin' }
        @{ Name = 'guestAttestation' }
        @{ Name = 'nvidiaGpuDriver' }
        @{ Name = 'deploy' }
    ) {
        param($Name)

        @($extensions[$Name].resources).Count | Should -Be 1
        $extensions[$Name].resources[0].type | Should -Be 'Microsoft.Compute/virtualMachines/extensions'
        $extensions[$Name].parameters.virtualMachineName.type | Should -Be 'string'
    }
}
