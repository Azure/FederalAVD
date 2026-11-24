Describe 'Configure artifact policy regressions' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot

        function Get-ArtifactPolicyBlock {
            param([string]$RelativePath, [string]$Marker)

            $path = Join-Path $repoRoot "customer-examples\artifacts\$RelativePath"
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
            $start = $ast.Extent.Text.IndexOf($Marker, [StringComparison]::Ordinal)
            if ($start -lt 0) { throw "Policy configuration marker not found in '$path'." }

            # Execute only configuration, not downloads, hive mounting, logging setup or cleanup.
            $statements = $ast.EndBlock.Statements | Where-Object {
                $_.Extent.StartOffset -ge $start -and $_.Extent.Text -notmatch '^Remove-Item\b'
            }
            [scriptblock]::Create(($statements.Extent.Text -join "`n"))
        }

        function Set-PolicyRegistryValue {
            param($Scope, $RegistryKeyPath, $RegistryValue, $RegistryType, $RegistryData)
            throw 'Policy writes must be mocked.'
        }
        function Remove-PolicyRegistryValue {
            param($Scope, $RegistryKeyPath, $RegistryValue)
            throw 'Policy removals must be mocked.'
        }
        function Invoke-PolicyUpdate { throw 'Policy application must be mocked.' }
        function Write-Log { param($Category, $Message) }
        function Set-ItemProperty {
            param($Path, $Name, $Value, $Type, [switch]$Force)
            throw 'Registry writes must be mocked.'
        }
        function Invoke-WithDefaultUserHive {
            param($HivePath, [scriptblock]$ScriptBlock)
            & $ScriptBlock
        }

        function Assert-PolicyDword {
            param(
                [string]$Name,
                [int]$Value,
                [string]$Key,
                [string]$Scope = 'Computer',
                [switch]$Direct
            )
            $writes = if ($Direct) { $script:DirectWrites } else { $script:PolicyWrites }
            $entries = @($writes | Where-Object RegistryValue -EQ $Name)
            $entries.Count | Should -Be 1
            $entries[0].RegistryKeyPath | Should -Be $Key
            $entries[0].RegistryType | Should -Be 'DWORD'
            $entries[0].RegistryData | Should -Be $Value
            if (-not $Direct) { $entries[0].Scope | Should -Be $Scope }
        }
    }

    BeforeEach {
        $script:PolicyWrites = [Collections.Generic.List[hashtable]]::new()
        $script:DirectWrites = [Collections.Generic.List[hashtable]]::new()
        Mock Set-PolicyRegistryValue {
            param($Scope, $RegistryKeyPath, $RegistryValue, $RegistryType, $RegistryData)
            $script:PolicyWrites.Add(@{
                Scope = $Scope; RegistryKeyPath = $RegistryKeyPath
                RegistryValue = $RegistryValue; RegistryType = $RegistryType; RegistryData = $RegistryData
            })
        }
        Mock Set-ItemProperty {
            param($Path, $Name, $Value, $Type)
            $script:DirectWrites.Add(@{
                RegistryKeyPath = $Path; RegistryValue = $Name; RegistryType = $Type; RegistryData = $Value
            })
        }
        Mock Remove-PolicyRegistryValue {}
        Mock Invoke-PolicyUpdate {}
        Mock Test-Path { $true }
        Mock New-Item { throw 'Unexpected registry key creation.' }
    }

    Context 'RemoteApp shell' {
        BeforeAll {
            $remoteBlock = Get-ArtifactPolicyBlock `
                'Configure-RemoteDesktopPolicy\Configure-RemoteDesktopServicesPolicy.ps1' '$rdKey ='
        }
        BeforeEach {
            $MaxDisconnectionTimeMs = 10800000
            $MaxIdleTimeMs = 10800000
        }

        It 'enables the ADMX-backed shell without changing session timeout defaults' {
            $EnableRemoteApp = $true
            . $remoteBlock

            $key = 'Software\Policies\Microsoft\Windows NT\Terminal Services'
            Assert-PolicyDword 'UseShellAppRuntimeRemoteApp' 1 $key
            Assert-PolicyDword 'MaxDisconnectionTime' 10800000 $key
            Assert-PolicyDword 'MaxIdleTime' 10800000 $key
            Assert-PolicyDword 'fEnableTimeZoneRedirection' 1 $key
            @($script:PolicyWrites | Where-Object RegistryValue -EQ 'EnableEnhancedShellExperienceForRemoteApp').Count |
                Should -Be 0
            Should -Invoke Invoke-PolicyUpdate -Exactly -Times 1
        }

        It 'leaves the shell unconfigured when the switch is omitted' {
            $EnableRemoteApp = $false
            . $remoteBlock
            @($script:PolicyWrites | Where-Object RegistryValue -EQ 'UseShellAppRuntimeRemoteApp').Count |
                Should -Be 0
            $script:PolicyWrites.Count | Should -Be 3
        }
    }

    Context 'Windows Update deadlines and notifications' {
        BeforeAll {
            $updateBlock = Get-ArtifactPolicyBlock `
                'Configure-WindowsUpdatePolicy\Configure-WindowsUpdatePolicy.ps1' '$wuKey ='
        }
        BeforeEach {
            $DeferQualityUpdatesPeriodInDays = 0
            $ScheduledInstallDay = 0
            $ScheduledInstallTime = 24
        }

        It 'activates only modern deadlines with the exact notification option' {
            $DisableUpdates = $false
            . $updateBlock
            $key = 'Software\Policies\Microsoft\Windows\WindowsUpdate'
            $expected = @{
                SetComplianceDeadlineForFU = 1; SetComplianceDeadlineForQU = 1
                ConfigureDeadlineForFeatureUpdates = 7; ConfigureDeadlineForQualityUpdates = 3
                ConfigureDeadlineGracePeriodForFeatureUpdates = 2; ConfigureDeadlineGracePeriod = 2
                SetUpdateNotificationLevel = 1; UpdateNotificationLevel = 1
                NoUpdateNotificationsDuringActiveHours = 1
            }
            foreach ($name in $expected.Keys) {
                Assert-PolicyDword $name $expected[$name] $key
            }
            Assert-PolicyDword 'NoAutoUpdate' 0 "$key\AU"
            Assert-PolicyDword 'ScheduledInstallDay' 0 "$key\AU"
            Assert-PolicyDword 'ScheduledInstallTime' 24 "$key\AU"
            @($script:PolicyWrites | Where-Object RegistryValue -EQ 'SetComplianceDeadline').Count |
                Should -Be 0
            @($script:PolicyWrites | Where-Object RegistryValue -EQ 'NoUpdateNotificationDuringActiveHours').Count |
                Should -Be 0
            Should -Invoke Invoke-PolicyUpdate -Exactly -Times 1
        }

        It 'preserves the disable-updates path without adding deadline policies' {
            $DisableUpdates = $true
            . $updateBlock
            $script:PolicyWrites.Count | Should -Be 1
            Assert-PolicyDword 'NoAutoUpdate' 1 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU'
        }
    }

    Context 'Edge policy (<Mode>)' -ForEach @(
        @{ Mode = 'Registry.pol'; AdmxImported = $true }
        @{ Mode = 'registry fallback'; AdmxImported = $false }
    ) {
        BeforeAll {
            $edgeBlock = Get-ArtifactPolicyBlock `
                'Configure-EdgePolicy\Configure-EdgePolicy.ps1' 'If ($Script:AdmxImported)'
        }
        BeforeEach {
            $script:AdmxImported = $AdmxImported
            $SmartScreenAllowListDomains = @()
            $PopupsAllowedForUrls = @()
            $AllowDeveloperTools = $true
            $DefaultSearchProviderEnabled = $false
            $DefaultSearchProviderSearchURL = $null
            $ManagedSearchEngines = $null
        }

        It 'disables HTTPS upgrades using the supported policy and preserves adjacent settings' {
            . $edgeBlock
            $key = if ($AdmxImported) { 'Software\Policies\Microsoft\Edge' } else { 'HKLM:\Software\Policies\Microsoft\Edge' }
            Assert-PolicyDword 'HttpsUpgradesEnabled' 0 $key -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'HideFirstRunExperience' 1 $key -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'NonRemovableProfileEnabled' 1 $key -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'DownloadRestrictions' 4 $key -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'DeveloperToolsAvailability' 1 $key -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'DefaultSearchProviderEnabled' 0 $key -Direct:(-not $AdmxImported)
            @(@($script:PolicyWrites) + @($script:DirectWrites) |
                Where-Object RegistryValue -EQ 'AutomaticHttpsDefault').Count | Should -Be 0
            if ($AdmxImported) {
                $script:DirectWrites.Count | Should -Be 0
                Should -Invoke Invoke-PolicyUpdate -Exactly -Times 1
            } else {
                $script:PolicyWrites.Count | Should -Be 0
                Should -Invoke Invoke-PolicyUpdate -Exactly -Times 0
            }
        }
    }

    Context 'Outlook cache policy (<Mode>)' -ForEach @(
        @{ Mode = 'Registry.pol'; AdmxImported = $true }
        @{ Mode = 'registry fallback'; AdmxImported = $false }
    ) {
        BeforeAll {
            $officeBlock = Get-ArtifactPolicyBlock `
                'Configure-Office365Policy\Configure-Office365.ps1' '$EnableCachedMode ='
        }
        BeforeEach {
            $script:AdmxImported = $AdmxImported
            $CalendarSync = 'Not Configured'
            $CalendarSyncMonths = 'Not Configured'
            $CalendarSyncWindowSetting = $null
            $DisableUpdates = $false
            $cacheKey = if ($AdmxImported) {
                'Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode'
            } else {
                'HKLM:\DefaultUser\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode'
            }
        }

        It 'writes both DWORDs for <EmailCacheTime>, including required zeros' -TestCases @(
            @{ EmailCacheTime = '3 days'; Months = 0; Days = 3 }
            @{ EmailCacheTime = '1 week'; Months = 0; Days = 7 }
            @{ EmailCacheTime = '2 weeks'; Months = 0; Days = 14 }
            @{ EmailCacheTime = '1 month'; Months = 1; Days = 0 }
            @{ EmailCacheTime = '3 months'; Months = 3; Days = 0 }
            @{ EmailCacheTime = '6 months'; Months = 6; Days = 0 }
            @{ EmailCacheTime = '12 months'; Months = 12; Days = 0 }
            @{ EmailCacheTime = '24 months'; Months = 24; Days = 0 }
            @{ EmailCacheTime = '36 months'; Months = 36; Days = 0 }
            @{ EmailCacheTime = '60 months'; Months = 60; Days = 0 }
            @{ EmailCacheTime = 'All'; Months = 0; Days = 0 }
        ) {
            param($EmailCacheTime, $Months, $Days)
            . $officeBlock
            Assert-PolicyDword 'SyncWindowSetting' $Months $cacheKey -Scope User -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'SyncWindowSettingDays' $Days $cacheKey -Scope User -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'Enable' 1 $cacheKey -Scope User -Direct:(-not $AdmxImported)
        }

        It 'leaves email values untouched for Not Configured, including on reruns' {
            $EmailCacheTime = 'Not Configured'
            $SyncWindowSetting = 6
            $SyncWindowSettingDays = 7
            . $officeBlock
            @(@($script:PolicyWrites) + @($script:DirectWrites) |
                Where-Object RegistryValue -In @('SyncWindowSetting', 'SyncWindowSettingDays', 'Enable')).Count |
                Should -Be 0
        }

        It 'overwrites stale paired values when changing from days to months to All' {
            $effectiveValues = @{}
            foreach ($window in @('1 week', '1 month', 'All')) {
                $EmailCacheTime = $window
                $script:PolicyWrites.Clear()
                $script:DirectWrites.Clear()
                . $officeBlock
                $writes = if ($AdmxImported) { $script:PolicyWrites } else { $script:DirectWrites }
                foreach ($write in $writes) { $effectiveValues[$write.RegistryValue] = $write.RegistryData }
                $expectedMonths = if ($window -eq '1 month') { 1 } else { 0 }
                $expectedDays = if ($window -eq '1 week') { 7 } else { 0 }
                Assert-PolicyDword 'SyncWindowSetting' $expectedMonths $cacheKey -Scope User -Direct:(-not $AdmxImported)
                Assert-PolicyDword 'SyncWindowSettingDays' $expectedDays $cacheKey -Scope User -Direct:(-not $AdmxImported)
                $effectiveValues.SyncWindowSetting | Should -Be $expectedMonths
                $effectiveValues.SyncWindowSettingDays | Should -Be $expectedDays
            }
        }

        It 'preserves independent non-policy calendar settings and Office update controls' {
            $EmailCacheTime = 'Not Configured'
            $CalendarSync = 'Primary Calendar Only'
            $CalendarSyncMonths = '1'
            $DisableUpdates = $true
            . $officeBlock
            $calendarKey = 'HKLM:\DefaultUser\Software\Microsoft\Office\16.0\Outlook\Cached Mode'
            Assert-PolicyDword 'CalendarSyncWindowSetting' 1 $calendarKey -Direct
            Assert-PolicyDword 'CalendarSyncWindowSettingMonths' 1 $calendarKey -Direct
            $updateKey = if ($AdmxImported) {
                'SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate'
            } else {
                'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate'
            }
            Assert-PolicyDword 'HideUpdateNotifications' 1 $updateKey -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'HideEnableDisableUpdates' 1 $updateKey -Direct:(-not $AdmxImported)
            Assert-PolicyDword 'EnableAutomaticUpdates' 0 $updateKey -Direct:(-not $AdmxImported)
        }
    }
}
