$repoRoot = Split-Path -Parent $PSScriptRoot
$shrRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer'

Describe 'SHR mandatory two-timer deployment contract' {
    BeforeAll {
        $arm = Get-Content (Join-Path $shrRoot 'main.json') -Raw | ConvertFrom-Json
        $form = Get-Content (Join-Path $shrRoot 'uiFormDefinition.json') -Raw | ConvertFrom-Json
        $initiator = $arm.resources.functionCode
        $reconciler = $arm.resources.workerCode
        $appParameters = $arm.resources.functionApp.properties.parameters
        function Get-CompiledScriptText {
            param([string] $Reference)
            $match = [regex]::Match($Reference, "variables\('([^']+)'\)")
            if (-not $match.Success) { throw "Expected a compiled text variable: $Reference" }
            $arm.variables.PSObject.Properties[$match.Groups[1].Value].Value
        }
    }

    It 'has one mandatory execution model with initiation and fixed deadline controls' {
        $arm.parameters.PSObject.Properties.Name | Should Not Contain 'enableQueueContinuation'
        $arm.parameters.PSObject.Properties.Name | Should Not Contain 'azureQueuePrivateDnsZoneResourceId'
        $arm.parameters.initiationEnabled.defaultValue | Should Be $true
        $arm.parameters.continuationTimeoutHours.defaultValue | Should Be 72
        $arm.parameters.continuationTimeoutHours.minValue | Should Be 1
        $arm.parameters.continuationTimeoutHours.maxValue | Should Be 720
        $form.view.outputs.parameters.initiationEnabled | Should Be "[bool(steps('replacerConfig').initiationEnabled)]"
        $form.view.outputs.parameters.PSObject.Properties.Name | Should Not Contain 'enableQueueContinuation'
        $form.view.outputs.parameters.PSObject.Properties.Name | Should Not Contain 'azureQueuePrivateDnsZoneResourceId'
    }

    It 'replaces the existing worker binding with an unconditional minute timer after the code upload' {
        $reconciler.condition | Should BeNullOrEmpty
        $reconciler.dependsOn | Should Contain 'functionCode'
        $reconciler.properties.parameters.functionName.value | Should Be 'session-host-replacer-worker'
        $reconciler.properties.parameters.schedule.value | Should Be '0 * * * * *'
        $reconciler.properties.template.variables.triggerBinding.type | Should Be 'timerTrigger'
        $reconciler.properties.template.parameters.PSObject.Properties.Name | Should Not Contain 'triggerType'
        $reconciler.properties.parameters.PSObject.Properties.Name | Should Not Contain 'queueName'
        $reconciler.properties.parameters.PSObject.Properties.Name | Should Not Contain 'connection'
    }

    It 'always exposes the initiation hold with a label-based default' {
        $step = $form.view.properties.steps | Where-Object name -eq 'replacerConfig'
        $control = $step.elements | Where-Object name -eq 'initiationEnabled'
        $control.type | Should Be 'Microsoft.Common.DropDown'
        $control.defaultValue | Should Be 'Enabled'
        $control.constraints.required | Should Be $true
        $control.visible | Should BeNullOrEmpty
        $control.constraints.allowedValues.label | Should Contain $control.defaultValue
        ($step.elements | Where-Object name -eq 'enableQueueContinuation') | Should BeNullOrEmpty
    }

    It 'keeps the affected schedule and network explanations literal and removes queue DNS selection' {
        $step = $form.view.properties.steps | Where-Object name -eq 'replacerConfig'
        $schedule = $step.elements | Where-Object name -eq 'scheduleInfoBox'
        $infrastructure = $form.view.properties.steps | Where-Object name -eq 'infrastructure'
        $network = $infrastructure.elements | Where-Object name -eq 'zeroTrustNetworkingInfoBox'
        $schedule.options.text | Should Match 'reconciliation timer runs every minute'
        $schedule.options.text | Should Not Match '^\['
        $network.options.text | Should Not Match '^\['
        ($infrastructure.elements | Where-Object name -eq 'azureQueuePrivateDnsZone') | Should BeNullOrEmpty
    }

    It 'preserves the configurable initiation schedule and explicitly enables the reconciler on upgrade' {
        $arm.parameters.timerSchedule.defaultValue | Should Be '0 0,30 * * * *'
        $initiator.properties.parameters.functionName.value | Should Be 'session-host-replacer'
        $initiator.properties.parameters.schedule.value | Should Be '%TimerSchedule%'
        $settings = $appParameters.functionAppAppSettings.value
        $settings | Should Match "'InitiationEnabled', 'value', string\(parameters\('initiationEnabled'\)\)"
        $settings | Should Match "'ContinuationTimeoutHours', 'value', string\(parameters\('continuationTimeoutHours'\)\)"
        $settings | Should Match "'AzureWebJobs\.session-host-replacer-worker\.Disabled', 'value', 'false'"
        $settings | Should Not Match 'EnableQueueContinuation|extensions__queues'
    }

    It 'requires private Blob and Table runtime storage but does not provision queue storage' {
        $appParameters.enableQueueStorage.value | Should Be $false
        $appParameters.enableTableStorage.value | Should Be $true
        $appParameters.PSObject.Properties.Name | Should Not Contain 'azureQueuePrivateDnsZoneResourceId'
        $appParameters.azureBlobPrivateDnsZoneResourceId.value | Should Not BeNullOrEmpty
        $appParameters.azureTablePrivateDnsZoneResourceId.value | Should Not BeNullOrEmpty
    }

    It 'gates automatic queue RBAC on the shared queue capability while preserving host Blob and caller-supplied roles' {
        $appTemplate = $arm.resources.functionApp.properties.template
        $appTemplate.variables.storageAccountRoleDefinitions | Should Be (
            "[union(createArray('b7e6dc6d-f1e8-4753-8033-0f276bb0955b'), " +
            "if(parameters('enableQueueStorage'), createArray('974c5e8b-45b9-4653-ba55-5f855dd0fb88'), createArray()), " +
            "parameters('storageAccountRoleDefinitionIds'))]"
        )
        $appParameters.enableQueueStorage.value | Should Be $false
        $appParameters.storageAccountRoleDefinitionIds.value |
            Should Contain '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
        $appParameters.storageAccountRoleDefinitionIds.value |
            Should Not Contain '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
    }

    It 'keeps automatic queue access enabled by default for other shared-module callers' {
        $arm.resources.functionApp.properties.template.parameters.enableQueueStorage.defaultValue | Should Be $true
    }

    It 'embeds the exact thin entries and always deploys the single shared lifecycle engine' {
        $files = $initiator.properties.parameters.files.value
        $match = [regex]::Match($files, "createObject\('run.ps1', variables\('([^']+)'\)")
        $match.Success | Should Be $true
        $arm.variables.PSObject.Properties[$match.Groups[1].Value].Value |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\scheduler.ps1') -Raw)
        Get-CompiledScriptText $reconciler.properties.parameters.files.value.'run.ps1' |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\worker.ps1') -Raw)
        Get-CompiledScriptText $arm.variables.sharedFunctionFiles.'../shr-cycle.ps1' |
            Should Be (Get-Content (Join-Path $shrRoot 'functions\run.ps1') -Raw)
        $files | Should Match "variables\('sharedFunctionFiles'\)"
        $files | Should Not Match 'enableQueueContinuation'
        $arm.variables.sharedFunctionFiles.'../host.json' |
            Should Be "[string(createObject('version', '2.0'))]"
    }

    It 'rejects a direct legacy engine invocation without durable operation context' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $shrRoot 'functions\run.ps1'), [ref]$tokens, [ref]$errors)
        $errors | Should BeNullOrEmpty
        foreach ($name in @('ContinuationContext', 'CycleResult')) {
            $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter.Attributes.Extent.Text -join ' ' | Should Match 'Mandatory'
        }
    }

    It 'does not fingerprint a changed initiation schedule as an operation configuration change' {
        Import-Module (Join-Path $shrRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Force
        try {
            InModuleScope SessionHostReplacer.Continuation {
                $previous = $env:TimerSchedule
                try {
                    $env:TimerSchedule = '0 0,30 * * * *'
                    $hash = Get-ShrConfigurationHash
                    $env:TimerSchedule = '0 0 1 * * 1'
                    Get-ShrConfigurationHash | Should Be $hash
                } finally { $env:TimerSchedule = $previous }
            }
        } finally { Remove-Module SessionHostReplacer -Force }
    }
}
