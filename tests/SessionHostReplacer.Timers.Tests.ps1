BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $shrRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer'
}

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

    It 'has one mandatory execution model with initiation and progress timeout controls' {
        $arm.parameters.PSObject.Properties.Name | Should -Not -Contain 'enableQueueContinuation'
        $arm.parameters.PSObject.Properties.Name | Should -Not -Contain 'queuePrivateDnsZoneResourceId'
        $arm.parameters.initiationEnabled.defaultValue | Should -Be $true
        $arm.parameters.continuationTimeoutHours.defaultValue | Should -Be 168
        $arm.parameters.continuationTimeoutHours.minValue | Should -Be 1
        $arm.parameters.continuationTimeoutHours.maxValue | Should -Be 720
        $form.view.outputs.parameters.initiationEnabled | Should -Be "[bool(steps('replacerConfig').initiationEnabled)]"
        $form.view.outputs.parameters.PSObject.Properties.Name | Should -Not -Contain 'enableQueueContinuation'
        $form.view.outputs.parameters.PSObject.Properties.Name | Should -Not -Contain 'queuePrivateDnsZoneResourceId'
    }

    It 'replaces the existing worker binding with the derived schedule setting after the code upload' {
        $reconciler.condition | Should -BeNullOrEmpty
        $reconciler.dependsOn | Should -Contain 'functionCode'
        $reconciler.properties.parameters.functionName.value | Should -Be 'session-host-replacer-worker'
        $reconciler.properties.parameters.schedule.value | Should -Be '%ContinuationTimerSchedule%'
        $reconciler.properties.template.variables.triggerBinding.type | Should -Be 'timerTrigger'
        $reconciler.properties.template.parameters.PSObject.Properties.Name | Should -Not -Contain 'triggerType'
        $reconciler.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'queueName'
        $reconciler.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'connection'
    }

    It 'always exposes the initiation hold with a label-based default' {
        $step = $form.view.properties.steps | Where-Object name -eq 'replacerConfig'
        $control = $step.elements | Where-Object name -eq 'initiationEnabled'
        $control.type | Should -Be 'Microsoft.Common.DropDown'
        $control.defaultValue | Should -Be 'Enabled'
        $control.constraints.required | Should -Be $true
        $control.visible | Should -BeNullOrEmpty
        $control.constraints.allowedValues.label | Should -Contain $control.defaultValue
        ($step.elements | Where-Object name -eq 'enableQueueContinuation') | Should -BeNullOrEmpty
    }

    It 'keeps the affected schedule and network explanations literal and removes queue DNS selection' {
        $step = $form.view.properties.steps | Where-Object name -eq 'replacerConfig'
        $schedule = $step.elements | Where-Object name -eq 'scheduleInfoBox'
        $infrastructure = $form.view.properties.steps | Where-Object name -eq 'infrastructure'
        $network = $infrastructure.elements | Where-Object name -eq 'zeroTrustNetworkingInfoBox'
        $schedule.options.text | Should -Match 'every five minutes for SideBySide'
        $schedule.options.text | Should -Match 'every minute for DeleteFirst'
        $schedule.options.text | Should -Match ':04, :09, :14'
        $schedule.options.text | Should -Not -Match '^\['
        $network.options.text | Should -Not -Match '^\['
        ($infrastructure.elements | Where-Object name -eq 'queuePrivateDnsZone') | Should -BeNullOrEmpty
    }

    It 'preserves the configurable initiation schedule and explicitly enables the reconciler on upgrade' {
        $arm.parameters.timerSchedule.defaultValue | Should -Be '0 0,30 * * * *'
        $initiator.properties.parameters.functionName.value | Should -Be 'session-host-replacer-initiator'
        $initiator.properties.parameters.schedule.value | Should -Be '%TimerSchedule%'
        $settings = $appParameters.functionAppAppSettings.value
        $settings | Should -Match "'InitiationEnabled', 'value', string\(parameters\('initiationEnabled'\)\)"
        $settings | Should -Match "'ContinuationTimeoutHours', 'value', string\(parameters\('continuationTimeoutHours'\)\)"
        $settings | Should -Match "'ContinuationTimerSchedule', 'value', .*continuationTimerSchedule"
        $settings | Should -Match "'AzureWebJobs\.session-host-replacer-worker\.Disabled', 'value', 'false'"
        $settings | Should -Match "'AzureWebJobs\.session-host-replacer-initiator\.Disabled', 'value', 'false'"
        $settings | Should -Match "'AzureWebJobs\.session-host-replacer\.Disabled', 'value', 'true'"
        $settings | Should -Not -Match 'EnableQueueContinuation|extensions__queues'
    }

    It 'grants only scaling-plan read/write actions and waits for assignment before installing the initiator' {
        $permissions = $arm.resources.scalingPlanPermissions.properties.template
        $permissions.resources.role.properties.permissions[0].actions | Should -Be @(
            'Microsoft.DesktopVirtualization/scalingPlans/read'
            'Microsoft.DesktopVirtualization/scalingPlans/write'
        )
        $permissions.resources.role.properties.permissions[0].dataActions.Count | Should -Be 0
        $permissions.resources.role.properties.assignableScopes | Should -Be @('[subscription().id]')
        $permissions.resources.assignment.properties.parameters.principalId.value | Should -Be "[parameters('principalId')]"
        $arm.resources.scalingPlanPermissions.subscriptionId | Should -Be "[variables('hostPoolSubscriptionId')]"
        $initiator.dependsOn | Should -Contain 'scalingPlanPermissions'
    }

    It 'requires private Blob and Table runtime storage but does not provision queue storage' {
        $appParameters.enableQueueStorage.value | Should -Be $false
        $appParameters.enableTableStorage.value | Should -Be $true
        $appParameters.PSObject.Properties.Name | Should -Not -Contain 'queuePrivateDnsZoneResourceId'
        $appParameters.blobPrivateDnsZoneResourceId.value | Should -Not -BeNullOrEmpty
        $appParameters.tablePrivateDnsZoneResourceId.value | Should -Not -BeNullOrEmpty
    }

    It 'gates automatic queue RBAC on the shared queue capability while preserving host Blob and caller-supplied roles' {
        $appTemplate = $arm.resources.functionApp.properties.template
        $appTemplate.variables.storageAccountRoleDefinitions | Should -Be (
            "[union(createArray('b7e6dc6d-f1e8-4753-8033-0f276bb0955b'), " +
            "if(parameters('enableQueueStorage'), createArray('974c5e8b-45b9-4653-ba55-5f855dd0fb88'), createArray()), " +
            "parameters('storageAccountRoleDefinitionIds'))]"
        )
        $appParameters.enableQueueStorage.value | Should -Be $false
        $appParameters.storageAccountRoleDefinitionIds.value |
            Should -Contain '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
        $appParameters.storageAccountRoleDefinitionIds.value |
            Should -Not -Contain '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
    }

    It 'keeps automatic queue access enabled by default for other shared-module callers' {
        $arm.resources.functionApp.properties.template.parameters.enableQueueStorage.defaultValue | Should -Be $true
    }

    It 'embeds the exact thin entries and always deploys the single shared lifecycle engine' {
        $files = $initiator.properties.parameters.files.value
        $match = [regex]::Match($files, "createObject\('run.ps1', variables\('([^']+)'\)")
        $match.Success | Should -Be $true
        $arm.variables.PSObject.Properties[$match.Groups[1].Value].Value |
            Should -Be (Get-Content (Join-Path $shrRoot 'functions\scheduler.ps1') -Raw)
        Get-CompiledScriptText $reconciler.properties.parameters.files.value.'run.ps1' |
            Should -Be (Get-Content (Join-Path $shrRoot 'functions\worker.ps1') -Raw)
        Get-CompiledScriptText $arm.variables.sharedFunctionFiles.'../shr-cycle.ps1' |
            Should -Be (Get-Content (Join-Path $shrRoot 'functions\run.ps1') -Raw)
        $files | Should -Match "variables\('sharedFunctionFiles'\)"
        $files | Should -Not -Match 'enableQueueContinuation'
        $arm.variables.sharedFunctionFiles.'../host.json' |
            Should -Be "[string(createObject('version', '2.0'))]"
    }

    It 'rejects a direct legacy engine invocation without durable operation context' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $shrRoot 'functions\run.ps1'), [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        foreach ($name in @('ContinuationContext', 'CycleResult')) {
            $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter.Attributes.Extent.Text -join ' ' | Should -Match 'Mandatory'
        }
    }

    It 'does not fingerprint a changed timer runtime setting <Setting>' -ForEach @(
        @{ Setting = 'TimerSchedule'; Initial = '0 0,30 * * * *'; Updated = '0 0 1 * * 1' }
        @{ Setting = 'ContinuationTimerSchedule'; Initial = '0 * * * * *'; Updated = '0 4,9,14,19,24,29,34,39,44,49,54,59 * * * *' }
        @{ Setting = 'AzureWebJobs.session-host-replacer-worker.Disabled'; Initial = 'true'; Updated = 'false' }
        @{ Setting = 'AzureWebJobs.session-host-replacer-initiator.Disabled'; Initial = 'true'; Updated = 'false' }
        @{ Setting = 'AzureWebJobs.session-host-replacer.Disabled'; Initial = 'false'; Updated = 'true' }
    ) {
        Import-Module (Join-Path $shrRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Force
        try {
            InModuleScope SessionHostReplacer.Continuation -Parameters @{
                Setting = $Setting
                Initial = $Initial
                Updated = $Updated
            } {
                param($Setting, $Initial, $Updated)
                $previous = [Environment]::GetEnvironmentVariable($Setting)
                try {
                    [Environment]::SetEnvironmentVariable($Setting, $Initial)
                    $hash = Get-ShrConfigurationHash
                    [Environment]::SetEnvironmentVariable($Setting, $Updated)
                    Get-ShrConfigurationHash | Should -Be $hash
                } finally { [Environment]::SetEnvironmentVariable($Setting, $previous) }
            }

        } finally { Remove-Module SessionHostReplacer -Force }
    }
}

Describe 'SHR mode-specific continuation schedules' {
    BeforeAll {
        $fixture = Join-Path $TestDrive 'shr-schedules.bicepparam'
        $entryPath = [IO.Path]::GetRelativePath($TestDrive, (Join-Path $shrRoot 'main.bicep')).Replace('\', '/')
        $vectors = @(foreach ($offset in 0..59) {
            "  offset$offset`: continuationTimerSchedule('SideBySide', '0 $offset,$(($offset + 30) % 60) 8-17 * * 1-5')"
        })
        $content = @(
            'using none'
            "import { continuationTimerSchedule } from '$entryPath'"
            'param schedules = {'
            $vectors
            "  deleteFirst: continuationTimerSchedule('DeleteFirst', '0 3,33 8-17 * * 1-5')"
            "  wildcard: continuationTimerSchedule('SideBySide', '0 * * * * *')"
            "  stepped: continuationTimerSchedule('SideBySide', '0 */15 * * * *')"
            "  range: continuationTimerSchedule('SideBySide', '0 3-58/5 * * * *')"
            "  numericStep: continuationTimerSchedule('SideBySide', '0 3/5 * * * *')"
            "  unordered: continuationTimerSchedule('SideBySide', '0 33,3 * * * *')"
            "  whitespace: continuationTimerSchedule('SideBySide', '  0   3,33   * * * *  ')"
            '}'
        )
        Set-Content -LiteralPath $fixture -Value $content -Encoding ascii
        $raw = & az bicep build-params --file $fixture --stdout
        if ($LASTEXITCODE -ne 0) { throw 'SHR continuation schedule vectors did not compile.' }
        $schedules = (($raw | ConvertFrom-Json).parametersJson | ConvertFrom-Json).parameters.schedules.value
    }

    It 'keeps DeleteFirst on the existing minute timer' {
        $schedules.deleteFirst | Should -Be '0 * * * * *'
    }

    It 'builds explicit SideBySide minute lists for all 60 initiation offsets' {
        foreach ($offset in 0..59) {
            $fields = $schedules."offset$offset" -split ' '
            $fields.Count | Should -Be 6
            $fields[0] | Should -Be '0'
            ($fields[2..5] -join ' ') | Should -Be '* * * *'
            $minutes = @($fields[1] -split ',' | ForEach-Object { [int]$_ })
            $minutes.Count | Should -Be 12
            $minutes | Should -Contain (($offset + 1) % 60)
            $minutes | Should -Not -Contain $offset
            foreach ($index in 0..11) {
                (($minutes[($index + 1) % 12] - $minutes[$index] + 60) % 60) | Should -Be 5
            }
        }
        $schedules.offset3 | Should -Be '0 4,9,14,19,24,29,34,39,44,49,54,59 * * * *'
        $schedules.offset59 | Should -Be '0 0,5,10,15,20,25,30,35,40,45,50,55 * * * *'
    }

    It 'anchors custom schedules on the first minute term without inheriting initiation hours or days' {
        $schedules.wildcard | Should -Be $schedules.offset0
        $schedules.stepped | Should -Be $schedules.offset0
        $schedules.range | Should -Be $schedules.offset3
        $schedules.numericStep | Should -Be $schedules.offset3
        $schedules.unordered | Should -Be $schedules.offset3
        $schedules.whitespace | Should -Be $schedules.offset3
    }
}
