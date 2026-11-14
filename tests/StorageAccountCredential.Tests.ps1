Describe 'FSLogix native storage credentials' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $initializer = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\scripts\Initialize-SessionHost.ps1') -Raw
        $rotation = Get-Content -LiteralPath (Join-Path $repoRoot 'deployments\shared\scripts\Update-StorageAccountCredential.ps1') -Raw
        $initializerAst = [System.Management.Automation.Language.Parser]::ParseInput($initializer, [ref]$null, [ref]$null)
        $rotationAst = [System.Management.Automation.Language.Parser]::ParseInput($rotation, [ref]$null, [ref]$null)
        $findHelper = {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Set-StorageAccountCredential'
        }
        $helperAst = $initializerAst.Find($findHelper, $true)
        $helper = $helperAst.Extent.Text
        $rotationHelper = $rotationAst.Find($findHelper, $true).Extent.Text
        $nativeSource = $helperAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Value.StartsWith('using System;')
        }, $true).Value
        if (-not ('FederalAVD.StorageCredential' -as [type])) {
            Add-Type -TypeDefinition $nativeSource -ErrorAction Stop
        }

        # Replace only the native boundary in a test copy; never write to the real credential store.
        $declaration = @'
        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CredWrite(ref Credential credential, uint flags);
'@
        $shim = @'
        public static string LastTarget;
        public static string LastUser;
        public static string LastPassword;
        public static uint LastType;
        public static uint LastPersist;
        public static uint LastBytes;
        public static int Calls;
        public static bool Fail;

        private static bool CredWrite(ref Credential credential, uint flags)
        {
            Calls++;
            LastTarget = credential.TargetName;
            LastUser = credential.UserName;
            LastPassword = Marshal.PtrToStringUni(credential.CredentialBlob, (int)credential.CredentialBlobSize / 2);
            LastType = credential.Type;
            LastPersist = credential.Persist;
            LastBytes = credential.CredentialBlobSize;
            if (credential.Flags != 0 || flags != 0)
                throw new InvalidOperationException("Unexpected credential flags.");
            return !Fail;
        }
'@
        if (-not $nativeSource.Contains($declaration)) {
            throw 'The test native boundary no longer matches the production declaration.'
        }
        $testSource = $nativeSource.Replace($declaration, $shim).
            Replace('namespace FederalAVD', 'namespace FederalAVD.CredentialTests').
            Replace('Marshal.GetLastWin32Error()', '87')
        if (-not ('FederalAVD.CredentialTests.StorageCredential' -as [type])) {
            Add-Type -TypeDefinition $testSource -ErrorAction Stop
        }
        . ([scriptblock]::Create($helper.Replace('FederalAVD.StorageCredential', 'FederalAVD.CredentialTests.StorageCredential')))
        $testRotation = $rotation.Replace('FederalAVD.StorageCredential', 'FederalAVD.CredentialTests.StorageCredential')

        function Get-CredentialRunCommandScript {
            param($Node, $Variables)
            if ($Node -is [array]) {
                foreach ($child in $Node) { Get-CredentialRunCommandScript $child $Variables }
            }
            elseif ($Node -is [pscustomobject]) {
                if ($null -ne $Node.PSObject.Properties['variables']) { $Variables = $Node.variables }
                if ($Node.type -eq 'Microsoft.Compute/virtualMachines/runCommands') {
                    $script = $Node.properties.source.script
                    # Bicep hoists script literals into variables; SHR escapes the embedded template.
                    if ($script -match "^\[\[?variables\('([^']+)'\)\]$") {
                        $script = $Variables.PSObject.Properties[$Matches[1]].Value
                        if ($null -eq $script) { throw 'The embedded script variable could not be resolved.' }
                    }
                    if ($script -like '*CredWriteW*') { $script }
                }
                foreach ($property in $Node.PSObject.Properties) {
                    Get-CredentialRunCommandScript $property.Value $Variables
                }
            }
        }
    }

    It 'keeps identical credential functions inside both standalone scripts' {
        if ([string]::IsNullOrWhiteSpace($helper) -or $helper -cne $rotationHelper -or
            $initializer.Contains('Set-StorageAccountCredential.ps1') -or
            $rotation.Contains('Set-StorageAccountCredential.ps1')) {
            throw 'Both scripts must contain the same credential function without an external helper dependency.'
        }
    }

    It 'preserves <Case> password bytes and the SMB credential contract' -TestCases @(
        @{ Case = 'a leading slash'; Password = '/abc123+xyz==' }
        @{ Case = 'a quoted-looking prefix'; Password = '/"abc+123==' }
        @{ Case = 'a middle slash'; Password = 'abc/123+xyz==' }
        @{ Case = 'ordinary Base64'; Password = 'abc123+xyz==' }
        @{ Case = 'Unicode'; Password = "/abc$([char]0x00e9)+xyz==" }
    ) {
        param($Case, $Password)
        [FederalAVD.CredentialTests.StorageCredential]::Calls = 0
        [FederalAVD.CredentialTests.StorageCredential]::Fail = $false
        Set-StorageAccountCredential -TargetName 'fslogixtest.file.core.usgovcloudapi.net' `
            -UserName 'localhost\fslogixtest' -Password $Password
        if ([FederalAVD.CredentialTests.StorageCredential]::Calls -ne 1 -or
            [FederalAVD.CredentialTests.StorageCredential]::LastPassword -cne $Password -or
            [FederalAVD.CredentialTests.StorageCredential]::LastBytes -ne ($Password.Length * 2) -or
            [FederalAVD.CredentialTests.StorageCredential]::LastTarget -ne 'fslogixtest.file.core.usgovcloudapi.net' -or
            [FederalAVD.CredentialTests.StorageCredential]::LastUser -ne 'localhost\fslogixtest' -or
            [FederalAVD.CredentialTests.StorageCredential]::LastType -ne 2 -or
            [FederalAVD.CredentialTests.StorageCredential]::LastPersist -ne 2) {
            throw 'The native credential arguments did not preserve the password, identity, type or persistence.'
        }
    }

    It 'uses the Windows CREDENTIALW ABI and a checked Unicode CredWriteW result' {
        $type = [FederalAVD.StorageCredential]
        $credentialType = $type.GetNestedType('Credential', [Reflection.BindingFlags]::NonPublic)
        $size = [Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($credentialType))
        $expectedSize = if ([IntPtr]::Size -eq 8) { 80 } else { 52 }
        if ($size -ne $expectedSize) { throw "Unexpected CREDENTIALW size: $size" }
        $native = $type.GetMethod('CredWrite', [Reflection.BindingFlags]'Static,NonPublic')
        $import = $native.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false)[0]
        if ($import.EntryPoint -ne 'CredWriteW' -or -not $import.SetLastError -or
            $import.CharSet -ne [Runtime.InteropServices.CharSet]::Unicode) {
            throw 'CredWriteW must use Unicode and preserve the native error code.'
        }
        if (-not $nativeSource.Contains('finally') -or
            -not $nativeSource.Contains('Marshal.ZeroFreeCoTaskMemUnicode(passwordBuffer)')) {
            throw 'The unmanaged password buffer is not cleared and freed in finally.'
        }
    }

    It 'fails explicitly on a native error without including the password' {
        $password = '/dummy-sensitive-value=='
        [FederalAVD.CredentialTests.StorageCredential]::Fail = $true
        $failure = $null
        try {
            Set-StorageAccountCredential -TargetName 'credential-test.invalid' -UserName 'localhost\test' -Password $password
        }
        catch [System.Management.Automation.MethodInvocationException] {
            $failure = $_.Exception.GetBaseException()
        }
        finally {
            [FederalAVD.CredentialTests.StorageCredential]::Fail = $false
        }
        if ($failure -isnot [System.ComponentModel.Win32Exception] -or $failure.NativeErrorCode -ne 87 -or
            $failure.Message.Contains($password)) {
            throw 'The native failure was not surfaced as a sanitized Win32 error.'
        }
    }

    It 'rejects oversized credentials before reaching Windows' {
        [FederalAVD.CredentialTests.StorageCredential]::Calls = 0
        $failure = $null
        try {
            Set-StorageAccountCredential -TargetName 'credential-test.invalid' -UserName 'localhost\test' -Password ('x' * 1281)
        }
        catch [System.Management.Automation.MethodInvocationException] {
            $failure = $_.Exception.GetBaseException()
        }
        if ($failure -isnot [ArgumentException] -or [FederalAVD.CredentialTests.StorageCredential]::Calls -ne 0) {
            throw 'An oversized password reached the credential API.'
        }
    }

    It 'routes local and remote initialization through the writer after policy setup' {
        if ($initializer -match 'cmdkey' -or
            $initializer.IndexOf('$secedit = Start-Process') -gt $initializer.IndexOf('Set-StorageAccountCredential -TargetName') -or
            -not $initializer.Contains('-Password $LocalStorageAccountKeysArray[$i]') -or
            -not $initializer.Contains('-Password $RemoteStorageAccountKeysArray[$i]') -or
            -not $initializer.Contains('-SensitiveValues')) {
            throw 'Initialization must use the native writer after policy setup and keep keys out of logs.'
        }
    }

    It 'updates a credential during rotation without passing its key to a child process' {
        Mock Start-Process {
            param($FilePath, $ArgumentList)
            if ($FilePath -ne 'secedit.exe' -or $ArgumentList.Contains('/rotation-test-key==')) {
                throw 'An unexpected process or secret-bearing command line was started.'
            }
            [pscustomobject]@{ ExitCode = 0 }
        }
        $oldTemp = $env:TEMP
        try {
            $env:TEMP = $TestDrive
            & ([scriptblock]::Create($testRotation)) `
                -StorageAccountName 'rotationtest' -StorageAccountSuffix 'core.usgovcloudapi.net' `
                -StorageAccountKey '/rotation-test-key=='
        }
        finally { $env:TEMP = $oldTemp }
        if ([FederalAVD.CredentialTests.StorageCredential]::LastTarget -ne 'rotationtest.file.core.usgovcloudapi.net' -or
            [FederalAVD.CredentialTests.StorageCredential]::LastUser -ne 'localhost\rotationtest' -or
            [FederalAVD.CredentialTests.StorageCredential]::LastPassword -ne '/rotation-test-key==') {
            throw 'Key rotation did not update the expected credential.'
        }
    }

    It 'stops rotation when credential-storage policy setup fails' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } }
        [FederalAVD.CredentialTests.StorageCredential]::Calls = 0
        $oldTemp = $env:TEMP
        $failure = $null
        try {
            $env:TEMP = $TestDrive
            & ([scriptblock]::Create($testRotation)) `
                -StorageAccountName 'rotationtest' -StorageAccountSuffix 'core.windows.net' -StorageAccountKey '/dummy=='
        }
        catch [System.Management.Automation.RuntimeException] { $failure = $_ }
        finally { $env:TEMP = $oldTemp }
        if ($null -eq $failure -or $failure.Exception.Message -notlike '*exit code 5*' -or
            [FederalAVD.CredentialTests.StorageCredential]::Calls -ne 0) {
            throw 'Rotation continued after policy setup failed.'
        }
    }

    It 'embeds a self-contained writer in <Template>' -TestCases @(
        @{ Template = 'deployments\hostpools\hostpool.json' }
        @{ Template = 'deployments\hostpoolPoc\hostpoolPoc.json' }
        @{ Template = 'deployments\add-ons\sessionHosts\main.json' }
        @{ Template = 'deployments\add-ons\sessionHostReplacer\main.json' }
        @{ Template = 'deployments\add-ons\updateStorageAccountKeyOnSessionHosts\main.json' }
    ) {
        param($Template)
        $templateObject = Get-Content -LiteralPath (Join-Path $repoRoot $Template) -Raw | ConvertFrom-Json
        $scripts = @(Get-CredentialRunCommandScript $templateObject)
        if ($scripts.Count -eq 0) { throw "No embedded credential writer found in $Template" }
        $source = if ($Template -like '*updateStorageAccountKey*') { $rotation } else { $initializer }
        foreach ($script in $scripts) {
            if ($script -cne $source -or $script.Contains('Set-StorageAccountCredential.ps1') -or $script -match 'cmdkey') {
                throw "Embedded script does not match the standalone source in $Template"
            }
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$errors)
            if ($errors.Count -gt 0) { throw ($errors | Out-String) }
        }
    }
}
