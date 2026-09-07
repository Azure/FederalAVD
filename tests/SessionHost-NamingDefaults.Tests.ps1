Describe 'Session host resource naming defaults' {
    It 'uses stable shared defaults independent of resource type abbreviations' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sharedNaming = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\modules\orchestration\naming\hostPool.bicep') -Raw

        $sharedNaming | Should Match "virtualMachineNameConv\s+=.*: 'SHNAME'"
        $sharedNaming | Should Match "virtualMachineDiskNameConv\s+=.*: 'SHNAME-osdisk'"
        $sharedNaming | Should Match "virtualMachineNicNameConv\s+=.*: 'SHNAME-nic'"
    }

    It 'uses the same defaults in the Session Hosts template' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostsBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHosts\main.bicep') -Raw

        $sessionHostsBicep | Should Match "param virtualMachineNameConv string = 'SHNAME'"
        $sessionHostsBicep | Should Match "param virtualMachineDiskNameConv string = 'SHNAME-osdisk'"
        $sessionHostsBicep | Should Match "param virtualMachineNicNameConv string = 'SHNAME-nic'"
    }

    It 'uses the same defaults in the Session Host Replacer template' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostReplacerBicep = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\main.bicep') -Raw

        $sessionHostReplacerBicep | Should Match "param virtualMachineNameConv string = 'SHNAME'"
        $sessionHostReplacerBicep | Should Match "param virtualMachineDiskNameConv string = 'SHNAME-osdisk'"
        $sessionHostReplacerBicep | Should Match "param virtualMachineNicNameConv string = 'SHNAME-nic'"
    }

    It 'uses the same defaults in the standard host pool form' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $standardForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\hostpools\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $standardNamingStep = $standardForm.view.properties.steps | Where-Object { $_.name -eq 'tagsAndNaming' }
        $standardNamingSection = $standardNamingStep.elements | Where-Object { $_.name -eq 'naming' }
        $vmControl = $standardNamingSection.elements | Where-Object { $_.name -eq 'vmNameConvOverride' }
        $diskControl = $standardNamingSection.elements | Where-Object { $_.name -eq 'diskNameConvOverride' }
        $nicControl = $standardNamingSection.elements | Where-Object { $_.name -eq 'nicNameConvOverride' }

        $vmControl.defaultValue | Should Be 'SHNAME'
        $diskControl.defaultValue | Should Be 'SHNAME-osdisk'
        $nicControl.defaultValue | Should Be 'SHNAME-nic'
        $vmControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $diskControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $nicControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
    }

    It 'preserves tag precedence in the Session Hosts form fallbacks' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostsForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHosts\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $sessionHostsAdvancedStep = $sessionHostsForm.view.properties.steps | Where-Object { $_.name -eq 'advanced' }
        $sessionHostsNamingSection = $sessionHostsAdvancedStep.elements | Where-Object { $_.name -eq 'sessionHostNaming' }
        $vmControl = $sessionHostsNamingSection.elements | Where-Object { $_.name -eq 'virtualMachineNameConvOverride' }
        $diskControl = $sessionHostsNamingSection.elements | Where-Object { $_.name -eq 'diskNameConvOverride' }
        $nicControl = $sessionHostsNamingSection.elements | Where-Object { $_.name -eq 'networkInterfaceNameConvOverride' }

        $vmControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNameConv, 'SHNAME')]"
        $diskControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineDiskNameConv, 'SHNAME-osdisk')]"
        $nicControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNicNameConv, 'SHNAME-nic')]"
        $vmControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $diskControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $nicControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
    }

    It 'preserves tag precedence in the Session Host Replacer form fallbacks' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $sessionHostReplacerForm = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\uiFormDefinition.json') -Raw | ConvertFrom-Json
        $sessionHostReplacerAdvancedStep = $sessionHostReplacerForm.view.properties.steps | Where-Object { $_.name -eq 'advanced' }
        $sessionHostReplacerNamingSection = $sessionHostReplacerAdvancedStep.elements | Where-Object { $_.name -eq 'sessionHostNaming' }
        $vmControl = $sessionHostReplacerNamingSection.elements | Where-Object { $_.name -eq 'virtualMachineNameConvOverride' }
        $diskControl = $sessionHostReplacerNamingSection.elements | Where-Object { $_.name -eq 'diskNameConvOverride' }
        $nicControl = $sessionHostReplacerNamingSection.elements | Where-Object { $_.name -eq 'networkInterfaceNameConvOverride' }

        $vmControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNameConv, 'SHNAME')]"
        $diskControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineDiskNameConv, 'SHNAME-osdisk')]"
        $nicControl.defaultValue | Should Be "[coalesce(steps('basics').hostsRGProps.tags.virtualMachineNicNameConv, 'SHNAME-nic')]"
        $vmControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $diskControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
        $nicControl.PSObject.Properties['placeholder'] | Should BeNullOrEmpty
    }
}
