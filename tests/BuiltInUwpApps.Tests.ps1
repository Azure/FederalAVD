BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $sourceInstaller = Join-Path $repoRoot 'customer-examples\artifacts\BuiltIn-UWP-Apps\Install-BuiltinUwpApps.ps1'
}

Describe 'Built-in UWP image-provisioned upgrade selection' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        function New-TestProvisionedPackage {
            param([string]$Name, [string]$Version)
            [pscustomobject]@{PackageName="${Name}_${Version}_neutral__8wekyb3d8bbwe"}
        }
        function New-TestUwpPayload {
            param([string]$Folder, [string]$Name, [string]$Version = '2.0.0.0')
            $appFolder = Join-Path $packageRoot $Folder
            [IO.Directory]::CreateDirectory($appFolder) | Out-Null
            $stage = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory((Join-Path $stage 'AppxMetadata')) | Out-Null
            "<Bundle><Identity Name=`"$Name`" Version=`"$Version`" /></Bundle>" |
                Set-Content -LiteralPath (Join-Path $stage 'AppxMetadata\AppxBundleManifest.xml') -Encoding ascii
            $path = Join-Path $appFolder "${Name}_${Version}_neutral.msixbundle"
            [IO.Compression.ZipFile]::CreateFromDirectory($stage, $path)
            Remove-Item -LiteralPath $stage -Recurse -Force
            $global:uwpTestState.Payloads[$path] = @{Name=$Name; Version=$Version}
        }
    }
    BeforeEach {
        $oldSuppress = $env:SUPPRESS_FILELOG
        $oldExitCode = $global:LASTEXITCODE
        $env:SUPPRESS_FILELOG = '1'
        $packageRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
        $installer = Join-Path $packageRoot 'Install-BuiltinUwpApps.ps1'
        Copy-Item -LiteralPath $sourceInstaller -Destination $installer
        $global:uwpTestState = @{
            Packages=@(); Payloads=@{}; AddCalls=@(); RemoveCalls=@()
            InventoryCalls=0; FailInventoryAt=0; FailAdd=$false
            RequireDependencies=$false; Deprovisioned=$false; FreshVersion=''
        }
        Mock Get-AppxProvisionedPackage {
            $global:uwpTestState.InventoryCalls++
            if ($global:uwpTestState.InventoryCalls -eq $global:uwpTestState.FailInventoryAt) {
                Write-Error 'Cannot read provisioned inventory' -ErrorAction Stop
            }
            if ($global:uwpTestState.InventoryCalls -eq 2 -and $global:uwpTestState.FreshVersion) {
                $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' $global:uwpTestState.FreshVersion)
            }
            $global:uwpTestState.Packages
        }
        Mock Add-AppxProvisionedPackage {
            $global:uwpTestState.AddCalls += [pscustomobject]@{
                PackagePath=$PackagePath; Dependencies=@($DependencyPackagePath)
                Regions=$Regions; StubPackageOption=$StubPackageOption
            }
            if ($global:uwpTestState.FailAdd -or
                ($global:uwpTestState.RequireDependencies -and -not $DependencyPackagePath)) {
                throw 'Simulated missing framework'
            }
            $payload = $global:uwpTestState.Payloads[$PackagePath]
            $global:uwpTestState.Packages += New-TestProvisionedPackage $payload.Name $payload.Version
            foreach ($path in $DependencyPackagePath) {
                $name = [IO.Path]::GetFileName($path) -replace '_[0-9]+(?:\.[0-9]+)+.*$', ''
                $global:uwpTestState.Packages += New-TestProvisionedPackage $name '1.0.0.0'
            }
        }
        Mock Remove-AppxProvisionedPackage {
            $global:uwpTestState.RemoveCalls += $PackageName
            $global:uwpTestState.Packages = @($global:uwpTestState.Packages | Where-Object PackageName -ne $PackageName)
        }
        Mock Test-Path { $global:uwpTestState.Deprovisioned } -ParameterFilter { $Path -like 'HKLM:\*' }
        Mock Remove-Item { $global:uwpTestState.Deprovisioned = $false } -ParameterFilter { $Path -like 'HKLM:\*' }
        New-TestUwpPayload 'Calculator' 'Microsoft.WindowsCalculator'
    }
    AfterEach {
        $env:SUPPRESS_FILELOG = $oldSuppress
        $global:LASTEXITCODE = $oldExitCode
        Remove-Variable uwpTestState -Scope Global
    }

    It 'skips absent image apps by default without changing provisioning or removal records' {
        $global:uwpTestState.Deprovisioned = $true
        $output = & $installer
        $LASTEXITCODE | Should -Be 0
        $output -join "`n" | Should -Match 'not provisioned in this image'
        $output -join "`n" | Should -Match 'not provisioned'
        $output -join "`n" | Should -Match 'Health\s+: PASS'
        $global:uwpTestState.AddCalls.Count | Should -Be 0
        $global:uwpTestState.RemoveCalls.Count | Should -Be 0
        $global:uwpTestState.Deprovisioned | Should -Be $true
        Assert-MockCalled Remove-Item -Times 0 -Exactly -Scope It -ParameterFilter { $Path -like 'HKLM:\*' }
    }
    It 'upgrades an existing older provisioned app and preserves provisioning prerequisites' {
        $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' '1.0.0.0')
        $output = & $installer
        $LASTEXITCODE | Should -Be 0
        $global:uwpTestState.RemoveCalls.Count | Should -Be 1
        $global:uwpTestState.AddCalls.Count | Should -Be 1
        $global:uwpTestState.AddCalls[0].Regions | Should -Be 'all'
        $global:uwpTestState.AddCalls[0].StubPackageOption | Should -Be 'InstallFull'
        $global:uwpTestState.Packages[0].PackageName | Should -Match '_2\.0\.0\.0_'
        $output -join "`n" | Should -Match 'UPDATED'
    }
    It 'never downgrades or replaces equal versions even with InstallMissing' {
        foreach ($version in '2.0.0.0','3.0.0.0') {
            $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' $version)
            & $installer -InstallMissing | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        $global:uwpTestState.AddCalls.Count | Should -Be 0
        $global:uwpTestState.RemoveCalls.Count | Should -Be 0
    }
    It 'compares the fresh inventory version rather than a stale initial snapshot' {
        $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' '1.0.0.0')
        $global:uwpTestState.FreshVersion = '3.0.0.0'
        & $installer | Out-Null
        $LASTEXITCODE | Should -Be 0
        $global:uwpTestState.AddCalls.Count | Should -Be 0
        $global:uwpTestState.RemoveCalls.Count | Should -Be 0
    }
    It 'does not mistake a similarly named app for the staged identity' {
        $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculatorPreview' '1.0.0.0')
        & $installer | Out-Null
        $LASTEXITCODE | Should -Be 0
        $global:uwpTestState.AddCalls.Count | Should -Be 0
        $global:uwpTestState.RemoveCalls.Count | Should -Be 0
    }
    It 'installs absent apps only with the explicit opt-in' {
        $output = & $installer -InstallMissing
        $LASTEXITCODE | Should -Be 0
        $global:uwpTestState.AddCalls.Count | Should -Be 1
        $global:uwpTestState.RemoveCalls.Count | Should -Be 0
        $output -join "`n" | Should -Match 'NEW'
    }
    It 'updates present apps while intentionally skipping absent apps in the same package' {
        New-TestUwpPayload 'Paint' 'Microsoft.Paint'
        $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' '1.0.0.0')
        $output = & $installer
        $LASTEXITCODE | Should -Be 0
        $global:uwpTestState.AddCalls.Count | Should -Be 1
        $global:uwpTestState.Packages.Count | Should -Be 1
        $output -join "`n" | Should -Match "'Paint' is not provisioned"
        $output -join "`n" | Should -Match 'Health\s+: PASS'
    }
    It 'keeps the staged dependency retry for eligible upgrades' {
        $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' '1.0.0.0')
        $global:uwpTestState.RequireDependencies = $true
        $deps = Join-Path $packageRoot 'SharedDependencies'
        [IO.Directory]::CreateDirectory($deps) | Out-Null
        Set-Content -LiteralPath (Join-Path $deps 'Microsoft.VCLibs_1.0.0.0_x64.appx') -Value 'fake dependency'
        & $installer | Out-Null
        $LASTEXITCODE | Should -Be 0
        $global:uwpTestState.AddCalls.Count | Should -Be 2
        $global:uwpTestState.AddCalls[1].Dependencies.Count | Should -Be 1
    }
    It 'surfaces failed eligible upgrades with a nonzero exit code' {
        $global:uwpTestState.Packages = @(New-TestProvisionedPackage 'Microsoft.WindowsCalculator' '1.0.0.0')
        $global:uwpTestState.FailAdd = $true
        $output = & $installer
        $LASTEXITCODE | Should -Be 1
        $output -join "`n" | Should -Match 'Health\s+: FAIL'
    }
    It 'does not treat failed inventory queries as absent apps or successful validation' {
        foreach ($call in 1,2) {
            $global:uwpTestState.InventoryCalls = 0
            $global:uwpTestState.FailInventoryAt = $call
            { & $installer } | Should -Throw -ExpectedMessage '*Cannot read provisioned inventory*'
        }
        $global:uwpTestState.AddCalls.Count | Should -Be 0
        $global:uwpTestState.RemoveCalls.Count | Should -Be 0
    }
}
