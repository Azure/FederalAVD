$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\7-Zip\Deploy-7-Zip.ps1'

$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Deploy-7-Zip.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Deploy-7-Zip.ps1 contains non-ASCII content.'
}

$deploymentType = $scriptAst.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -eq 'DeploymentType'
}
$allowedDeploymentTypes = @(
    $deploymentType.Attributes |
        Where-Object { $_.TypeName.FullName -eq 'ValidateSet' } |
        ForEach-Object { $_.PositionalArguments.SafeGetValue() }
)
if (($allowedDeploymentTypes -join ',') -ne 'Install,Uninstall') {
    throw "Unexpected DeploymentType values: $($allowedDeploymentTypes -join ',')"
}

$scriptText = Get-Content -LiteralPath $sourceScriptPath -Raw
if ($scriptText -notmatch "PSChildName -match '\^\\\{\[0-9A-Fa-f-\]\{36\}\\\}\$'") {
    throw 'MSI uninstall does not require a GUID ProductCode registry subkey.'
}
if (-not $scriptText.Contains("Start-Process -FilePath 'msiexec.exe'") -or
    -not $scriptText.Contains('-ArgumentList "/x $($installedApplication.ProductCode)')) {
    throw 'MSI uninstall does not invoke msiexec.exe with /x.'
}

$tempRoot = Join-Path -Path $env:TEMP -ChildPath "FederalAVD-7zip-test-$([guid]::NewGuid())"
$originalSystemRoot = $env:SystemRoot

try {
    $packagePath = Join-Path -Path $tempRoot -ChildPath 'package'
    New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $sourceScriptPath -Destination (Join-Path $packagePath 'Deploy-7-Zip.ps1')
    Set-Content -LiteralPath (Join-Path $packagePath '7z-installer.msi') -Value '' -Encoding ASCII

    $env:SystemRoot = $tempRoot
    $env:SUPPRESS_FILELOG = '1'
    $global:sevenZipProcessCalls = @()
    $global:sevenZipProductCode = '{00000000-0000-0000-0000-000000000001}'
    $global:sevenZipInstalled = $true

    function global:Start-Process {
        param (
            [string]$FilePath,
            [string]$ArgumentList,
            [switch]$PassThru
        )

        $global:sevenZipProcessCalls += [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
        }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMs) return $true }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $process
    }

    function global:Test-Path {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$PathType
        )

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidatePath -like 'Registry::*') { return $global:sevenZipInstalled }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
    }

    function global:Get-ChildItem {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$Filter,
            [switch]$File,
            [string]$ErrorAction
        )

        if ($LiteralPath -like 'Registry::*') {
            return [pscustomobject]@{
                PSPath = 'Registry::7-Zip-Test'
                PSChildName = $global:sevenZipProductCode
            }
        }

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $candidatePath -Filter $Filter -File:$File
    }

    function global:Get-ItemProperty {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction
        )

        return [pscustomobject]@{ DisplayName = '7-Zip 26.00 (x64 edition)' }
    }

    function global:Get-Process {
        return $null
    }

    $deployScriptPath = Join-Path $packagePath 'Deploy-7-Zip.ps1'
    & $deployScriptPath -DeploymentType Install
    if ($global:sevenZipProcessCalls.Count -ne 1 -or
        $global:sevenZipProcessCalls[0].ArgumentList -notlike "*/i *7z-installer.msi*") {
        throw 'A single renamed MSI was not selected for installation.'
    }

    Set-Content -LiteralPath (Join-Path $packagePath 'second-installer.msi') -Value '' -Encoding ASCII
    $global:sevenZipProcessCalls = @()
    $ambiguityError = $null
    try { & $deployScriptPath -DeploymentType Install } catch { $ambiguityError = $_ }
    if (-not $ambiguityError -or $ambiguityError.Exception.Message -notlike 'Expected one MSI installer*') {
        throw 'Multiple MSI installers did not stop installation with an ambiguity error.'
    }
    if ($global:sevenZipProcessCalls.Count -ne 0) { throw 'Installation started despite multiple MSI files.' }
    Remove-Item -LiteralPath (Join-Path $packagePath 'second-installer.msi')

    $global:sevenZipProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall

    if ($global:sevenZipProcessCalls.Count -ne 1) {
        throw "Expected one MSI uninstall process, received $($global:sevenZipProcessCalls.Count)."
    }
    $msiUninstallCall = $global:sevenZipProcessCalls[0]
    if ($msiUninstallCall.FilePath -ne 'msiexec.exe' -or
        $msiUninstallCall.ArgumentList -ne "/x $global:sevenZipProductCode /qn /norestart") {
        throw "Unexpected MSI uninstall invocation: $($msiUninstallCall | ConvertTo-Json -Compress)"
    }

    $global:sevenZipInstalled = $false
    $global:sevenZipProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall
    if ($global:sevenZipProcessCalls.Count -ne 0) {
        throw 'Missing MSI installation was not treated as an idempotent removal.'
    }
}
finally {
    Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item function:\Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue
    Remove-Item function:\Get-Process -ErrorAction SilentlyContinue
    Remove-Variable sevenZipProcessCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable sevenZipProductCode -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable sevenZipInstalled -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Deploy-7-Zip tests passed.'

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Adobe-Acrobat-Reader-DC\Deploy-AdobeReaderDC.ps1'

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "Deploy-AdobeReaderDC.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Deploy-AdobeReaderDC.ps1 contains non-ASCII content.'
}

$tempRoot = Join-Path -Path $env:TEMP -ChildPath "FederalAVD-adobe-test-$([guid]::NewGuid())"
$originalSystemRoot = $env:SystemRoot

try {
    $packagePath = Join-Path -Path $tempRoot -ChildPath 'package'
    New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $sourceScriptPath -Destination (Join-Path $packagePath 'Deploy-AdobeReaderDC.ps1')
    Set-Content -LiteralPath (Join-Path $packagePath 'reader-current.exe') -Value '' -Encoding ASCII

    $env:SystemRoot = $tempRoot
    $env:SUPPRESS_FILELOG = '1'
    $global:adobeProcessCalls = @()
    $global:adobeInstalledApplicationCount = 1

    function global:Test-Path {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$PathType
        )

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidatePath -like 'Registry::*') {
            return $global:adobeInstalledApplicationCount -gt 0
        }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
    }

    function global:Get-ChildItem {
        param (
            [string]$LiteralPath,
            [string]$Filter,
            [switch]$File,
            [string]$ErrorAction
        )

        if ($LiteralPath -notlike 'Registry::*') {
            return Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Filter $Filter -File
        }
        for ($index = 1; $index -le $global:adobeInstalledApplicationCount; $index++) {
            [pscustomobject]@{
                PSPath = "Registry::Adobe-Acrobat-Test-$index"
                PSChildName = "{AC76BA86-7AD7-1033-7B44-AC0F074E410$($index - 1)}"
            }
        }
    }

    function global:Get-ItemProperty {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction
        )

        return [pscustomobject]@{
            DisplayName = 'Adobe Acrobat (64-bit)'
            Publisher = 'Adobe'
        }
    }

    function global:Get-Process {
        return $null
    }

    function global:Get-Service {
        return $null
    }

    function global:Get-ScheduledTask {
        return $null
    }

    function global:Start-Process {
        param (
            [string]$FilePath,
            [string]$ArgumentList,
            [switch]$PassThru
        )

        $global:adobeProcessCalls += [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
        }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMs) return $true }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $process
    }

    $deployScriptPath = Join-Path $packagePath 'Deploy-AdobeReaderDC.ps1'
    & $deployScriptPath -DeploymentType Install

    if ($global:adobeProcessCalls.Count -ne 1) {
        throw "Expected one Adobe install process, received $($global:adobeProcessCalls.Count)."
    }
    $installCall = $global:adobeProcessCalls[0]
    if ($installCall.FilePath -ne (Join-Path $packagePath 'reader-current.exe') -or
        $installCall.ArgumentList -notlike '*UPDATE_MODE=0*') {
        throw "Unexpected Adobe install invocation: $($installCall | ConvertTo-Json -Compress)"
    }

    Set-Content -LiteralPath (Join-Path $packagePath 'second-installer.exe') -Value '' -Encoding ASCII
    $global:adobeProcessCalls = @()
    $installerAmbiguityError = $null
    try { & $deployScriptPath -DeploymentType Install } catch { $installerAmbiguityError = $_ }
    if (-not $installerAmbiguityError -or $installerAmbiguityError.Exception.Message -notlike 'Expected one EXE installer*') {
        throw 'Multiple EXE installers did not stop installation with an ambiguity error.'
    }
    if ($global:adobeProcessCalls.Count -ne 0) { throw 'Installation started despite multiple EXE files.' }
    Remove-Item -LiteralPath (Join-Path $packagePath 'second-installer.exe')

    $global:adobeProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall
    if ($global:adobeProcessCalls.Count -ne 1) {
        throw "Expected one Adobe uninstall process, received $($global:adobeProcessCalls.Count)."
    }
    $uninstallCall = $global:adobeProcessCalls[0]
    if ($uninstallCall.FilePath -ne 'msiexec.exe' -or
        $uninstallCall.ArgumentList -ne '/x {AC76BA86-7AD7-1033-7B44-AC0F074E4100} /qn /norestart') {
        throw "Unexpected Adobe uninstall invocation: $($uninstallCall | ConvertTo-Json -Compress)"
    }

    $global:adobeInstalledApplicationCount = 0
    $global:adobeProcessCalls = @()
    & $deployScriptPath -DeploymentType Uninstall
    if ($global:adobeProcessCalls.Count -ne 0) {
        throw 'Missing Adobe installation was not treated as an idempotent removal.'
    }

    $global:adobeInstalledApplicationCount = 2
    $ambiguityError = $null
    try {
        & $deployScriptPath -DeploymentType Uninstall
    }
    catch {
        $ambiguityError = $_
    }
    if (-not $ambiguityError -or $ambiguityError.Exception.Message -notlike 'Multiple Adobe Acrobat MSI installations matched:*') {
        throw 'Multiple Adobe MSI registrations did not stop removal with an ambiguity error.'
    }
}
finally {
    Remove-Item function:\Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue
    Remove-Item function:\Get-Process -ErrorAction SilentlyContinue
    Remove-Item function:\Get-Service -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ScheduledTask -ErrorAction SilentlyContinue
    Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable adobeProcessCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable adobeInstalledApplicationCount -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Deploy-AdobeReaderDC tests passed.'

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Microsoft-AzCLI\Deploy-AzCLI.ps1'

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "Deploy-AzCLI.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Deploy-AzCLI.ps1 contains non-ASCII content.'
}

$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'
$global:azCliProcessCalls = @()
$global:azCliProductCode = '{00000000-0000-0000-0000-000000000002}'
$nativeUninstallPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

try {
    function global:Test-Path {
        param (
            [string]$LiteralPath,
            [string]$Path,
            [string]$ErrorAction,
            [string]$ErrorVariable
        )

        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        return $candidatePath -eq $nativeUninstallPath
    }

    function global:Get-ChildItem {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction,
            [string]$ErrorVariable
        )

        return [pscustomobject]@{
            PSPath = 'Registry::Azure-CLI-Test'
            PSChildName = $global:azCliProductCode
        }
    }

    function global:Get-ItemProperty {
        param (
            [string]$LiteralPath,
            [string]$ErrorAction
        )

        return [pscustomobject]@{
            DisplayName = 'Microsoft Azure CLI'
            DisplayVersion = '2.77.0'
            Publisher = 'Microsoft Corporation'
            PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Test'
            PSChildName = $global:azCliProductCode
            UninstallString = "MsiExec.exe /X$global:azCliProductCode"
            InstallSource = $null
            InstallLocation = $null
            InstallDate = $null
        }
    }

    function global:Start-Process {
        param (
            [string]$FilePath,
            [string]$ArgumentList,
            [switch]$PassThru
        )

        $global:azCliProcessCalls += [pscustomobject]@{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
        }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($TimeoutMs) return $true }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
        return $process
    }

    . $sourceScriptPath -DeploymentType Uninstall

    if ($global:azCliProcessCalls.Count -ne 1) {
        $detectedApplication = Get-InstalledApplication -Name 'Microsoft Azure CLI'
        throw "Expected one Azure CLI uninstall process, received $($global:azCliProcessCalls.Count). Detected application: $($detectedApplication | ConvertTo-Json -Compress)"
    }
    $uninstallCall = $global:azCliProcessCalls[0]
    if ($uninstallCall.FilePath -ne 'msiexec.exe' -or
        $uninstallCall.ArgumentList -ne "/X $global:azCliProductCode /qn") {
        throw "Unexpected Azure CLI uninstall invocation: $($uninstallCall | ConvertTo-Json -Compress)"
    }
}
finally {
    Remove-Item function:\Test-Path -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue
    Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable azCliProcessCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable azCliProductCode -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}

Write-Output 'Deploy-AzCLI tests passed.'

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$originalProgramFiles = $env:ProgramFiles
$originalSystemRoot = $env:SystemRoot
$tempRoot = Join-Path $env:TEMP "FederalAVD-exe-test-$([guid]::NewGuid())"

function Test-ExeApplicationRemoval {
    param ([string]$ScriptPath, [string]$UninstallerRelativePath, [string]$Arguments)
    $uninstallerPath = Join-Path $env:ProgramFiles $UninstallerRelativePath
    New-Item -Path (Split-Path $uninstallerPath -Parent) -ItemType Directory -Force | Out-Null
    Set-Content -Path $uninstallerPath -Value '' -Encoding ASCII
    $global:exeTestCalls = @()
    try {
        function global:Start-Process {
            param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru, [string]$ErrorAction)
            $global:exeTestCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
            $process = [pscustomobject]@{ ExitCode = 0 }
            $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
            $process | Add-Member ScriptMethod Kill { }
            return $process
        }
        & $ScriptPath -DeploymentType Uninstall
        if ($global:exeTestCalls.Count -ne 1) { throw "Expected one uninstall process for $ScriptPath." }
        if ($global:exeTestCalls[0].FilePath -ne $uninstallerPath -or $global:exeTestCalls[0].ArgumentList -ne $Arguments) {
            throw "Unexpected uninstall invocation: $($global:exeTestCalls[0] | ConvertTo-Json -Compress)"
        }
        Remove-Item -LiteralPath $uninstallerPath -Force
        $global:exeTestCalls = @()
        & $ScriptPath -DeploymentType Uninstall
        if ($global:exeTestCalls.Count) { throw "$ScriptPath removal was not idempotent." }
    }
    finally {
        Remove-Item function:\Start-Process -ErrorAction SilentlyContinue
        Remove-Variable exeTestCalls -Scope Global -ErrorAction SilentlyContinue
    }
}

try {
    $env:ProgramFiles = Join-Path $tempRoot 'ProgramFiles'
    $env:SystemRoot = $tempRoot
    $env:SUPPRESS_FILELOG = '1'
    Test-ExeApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Notepad-PlusPlus\Deploy-NotepadPlusPlus.ps1') `
        -UninstallerRelativePath 'Notepad++\uninstall.exe' `
        -Arguments '/S'
    Test-ExeApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-VSCode\Deploy-VSCode.ps1') `
        -UninstallerRelativePath 'Microsoft VS Code\unins000.exe' `
        -Arguments '/VERYSILENT /NORESTART'
    Test-ExeApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Git-for-Windows\Deploy-GitforWindows.ps1') `
        -UninstallerRelativePath 'Git\unins000.exe' `
        -Arguments '/VERYSILENT /NORESTART'
}
finally {
    $env:ProgramFiles = $originalProgramFiles
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'EXE application lifecycle tests passed.'

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScriptPath = Join-Path $repoRoot 'customer-examples\artifacts\Google-Chrome-Enterprise\Deploy-GoogleChromeEnterprise.ps1'
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($sourceScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw "Deploy-GoogleChromeEnterprise.ps1 has $($parseErrors.Count) parse error(s)." }
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) { throw 'Chrome script contains non-ASCII content.' }

$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'
$global:chromeInstalled = $true
$global:chromeProcessCalls = @()
$global:chromeProductCode = '{00000000-0000-0000-0000-000000000003}'

try {
    function global:Test-Path {
        param ([string]$LiteralPath, [string]$Path, [string]$PathType)
        $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidatePath -like 'Registry::*') { return $global:chromeInstalled }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
    }
    function global:Get-ChildItem {
        param ([string]$LiteralPath, [string]$ErrorAction)
        if ($LiteralPath -like '*Wow6432Node*') { return }
        [pscustomobject]@{ PSPath = 'Registry::Chrome-Test'; PSChildName = $global:chromeProductCode }
    }
    function global:Get-ItemProperty {
        param ([string]$LiteralPath, [string]$ErrorAction)
        [pscustomobject]@{ DisplayName = 'Google Chrome'; Publisher = 'Google LLC' }
    }
    function global:Get-Process { return $null }
    function global:Start-Process {
        param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
        $global:chromeProcessCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
        $process | Add-Member ScriptMethod Kill { }
        return $process
    }

    & $sourceScriptPath -DeploymentType Uninstall
    if ($global:chromeProcessCalls.Count -ne 1) { throw "Expected one Chrome uninstall, received $($global:chromeProcessCalls.Count)." }
    $call = $global:chromeProcessCalls[0]
    if ($call.FilePath -ne 'msiexec.exe' -or $call.ArgumentList -ne "/x $global:chromeProductCode /qn /norestart") {
        throw "Unexpected Chrome uninstall invocation: $($call | ConvertTo-Json -Compress)"
    }

    $global:chromeInstalled = $false
    $global:chromeProcessCalls = @()
    & $sourceScriptPath -DeploymentType Uninstall
    if ($global:chromeProcessCalls.Count) { throw 'Missing Chrome installation was not treated as an idempotent removal.' }
}
finally {
    Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Get-Process, function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable chromeInstalled, chromeProcessCalls, chromeProductCode -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}

Write-Output 'Deploy-GoogleChromeEnterprise tests passed.'

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'

function Test-MsiApplicationRemoval {
    param (
        [string]$ScriptPath,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$ProductCode
    )

    $global:msiTestInstalled = $true
    $global:msiTestDisplayName = $DisplayName
    $global:msiTestPublisher = $Publisher
    $global:msiTestProductCode = $ProductCode
    $global:msiTestProcessCalls = @()
    $global:msiTestExitCodes = @(1618, 0)
    $global:msiTestSleepCalls = @()
    try {
        function global:Test-Path {
            param ([string]$LiteralPath, [string]$Path, [string]$PathType)
            $candidatePath = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($candidatePath -like 'Registry::*') { return $global:msiTestInstalled }
            return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidatePath
        }
        function global:Get-ChildItem {
            param ([string]$LiteralPath, [string]$ErrorAction)
            if ($LiteralPath -like '*Wow6432Node*') { return }
            [pscustomobject]@{ PSPath = 'Registry::Msi-App-Test'; PSChildName = $global:msiTestProductCode }
        }
        function global:Get-ItemProperty {
            param ([string]$LiteralPath, [string]$ErrorAction)
            [pscustomobject]@{ DisplayName = $global:msiTestDisplayName; Publisher = $global:msiTestPublisher }
        }
        function global:Start-Process {
            param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
            $global:msiTestProcessCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
            $exitCode = $global:msiTestExitCodes[[math]::Min($global:msiTestProcessCalls.Count - 1, $global:msiTestExitCodes.Count - 1)]
            $process = [pscustomobject]@{ ExitCode = $exitCode }
            $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
            $process | Add-Member ScriptMethod Kill { }
            return $process
        }
        function global:Start-Sleep {
            param ([int]$Seconds, [int]$Milliseconds)
            $global:msiTestSleepCalls += if ($Seconds) { $Seconds } else { $Milliseconds / 1000 }
        }

        & $ScriptPath -DeploymentType Uninstall
        if ($global:msiTestProcessCalls.Count -ne 2) { throw "Expected $DisplayName to retry once after exit code 1618." }
        foreach ($call in $global:msiTestProcessCalls) {
            if ($call.FilePath -ne 'msiexec.exe' -or $call.ArgumentList -ne "/x $ProductCode /qn /norestart") {
                throw "Unexpected uninstall for $DisplayName`: $($call | ConvertTo-Json -Compress)"
            }
        }
        if ($global:msiTestSleepCalls.Count -ne 1 -or $global:msiTestSleepCalls[0] -ne 30) {
            throw "Expected one 30-second retry delay for $DisplayName."
        }

        $global:msiTestProcessCalls = @()
        $global:msiTestExitCodes = @(1618)
        $global:msiTestSleepCalls = @()
        $retryFailure = $null
        try {
            & $ScriptPath -DeploymentType Uninstall
        }
        catch {
            $retryFailure = $_
        }
        if (-not $retryFailure -or $retryFailure.Exception.Message -notmatch 'failed after 11 attempts with exit code 1618') {
            throw "Expected bounded exit code 1618 retry failure for $DisplayName."
        }
        if ($global:msiTestProcessCalls.Count -ne 11 -or $global:msiTestSleepCalls.Count -ne 10) {
            throw "Expected 11 attempts and 10 delays before failing $DisplayName."
        }

        $global:msiTestProcessCalls = @()
        $global:msiTestExitCodes = @(1639)
        $global:msiTestSleepCalls = @()
        $nonRetryableFailure = $null
        try {
            & $ScriptPath -DeploymentType Uninstall
        }
        catch {
            $nonRetryableFailure = $_
        }
        if (-not $nonRetryableFailure -or $nonRetryableFailure.Exception.Message -notmatch 'failed with exit code 1639') {
            throw "Expected immediate non-retryable MSI failure for $DisplayName."
        }
        if ($global:msiTestProcessCalls.Count -ne 1 -or $global:msiTestSleepCalls.Count -ne 0) {
            throw "Expected no retry or delay for non-1618 failure from $DisplayName."
        }

        $global:msiTestInstalled = $false
        $global:msiTestProcessCalls = @()
        & $ScriptPath -DeploymentType Uninstall
        if ($global:msiTestProcessCalls.Count) { throw "$DisplayName removal was not idempotent." }
    }
    finally {
        Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Start-Process, function:\Start-Sleep -ErrorAction SilentlyContinue
        Remove-Variable msiTestInstalled, msiTestDisplayName, msiTestPublisher, msiTestProductCode, msiTestProcessCalls, msiTestExitCodes, msiTestSleepCalls -Scope Global -ErrorAction SilentlyContinue
    }
}

try {
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\PuTTY\Deploy-PuTTY.ps1') `
        -DisplayName 'PuTTY release 0.83 (64-bit)' `
        -Publisher 'Simon Tatham' `
        -ProductCode '{00000000-0000-0000-0000-000000000004}'
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-PowerShell-7\Deploy-PowerShell7.ps1') `
        -DisplayName 'PowerShell 7-x64' `
        -Publisher 'Microsoft Corporation' `
        -ProductCode '{00000000-0000-0000-0000-000000000005}'
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Amazon-Workspaces-Client\Deploy-AmazonWorkspacesClient.ps1') `
        -DisplayName 'Amazon WorkSpaces' `
        -Publisher 'Amazon Web Services, Inc' `
        -ProductCode '{00000000-0000-0000-0000-000000000006}'
    Test-MsiApplicationRemoval `
        -ScriptPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-Edge-Enterprise\Deploy-MicrosoftEdgeEnterprise.ps1') `
        -DisplayName 'Microsoft Edge' `
        -Publisher 'Microsoft Corporation' `
        -ProductCode '{00000000-0000-0000-0000-000000000007}'
}
finally {
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}

Write-Output 'MSI application lifecycle tests passed.'

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-Power-BI-Desktop\Deploy-PowerBIDesktop.ps1'
$originalSystemRoot = $env:SystemRoot
$env:SystemRoot = $env:TEMP
$env:SUPPRESS_FILELOG = '1'
$global:powerBiInstalled = $true
$global:powerBiCalls = @()
$global:powerBiUninstaller = Join-Path $env:TEMP 'Power BI Cache\setup.exe'
try {
    function global:Test-Path {
        param ([string]$LiteralPath, [string]$Path, [string]$PathType)
        $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidate -like 'Registry::*') { return $global:powerBiInstalled }
        if ($candidate -eq $global:powerBiUninstaller) { return $true }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $candidate
    }
    function global:Get-ChildItem {
        param ([string]$LiteralPath, [string]$ErrorAction)
        if ($LiteralPath -like '*Wow6432Node*') { return }
        [pscustomobject]@{ PSPath = 'Registry::Power-BI-Test' }
    }
    function global:Get-ItemProperty {
        param ([string]$LiteralPath, [string]$ErrorAction)
        [pscustomobject]@{
            DisplayName = 'Microsoft Power BI Desktop (x64)'
            Publisher = 'Microsoft Corporation'
            QuietUninstallString = "`"$global:powerBiUninstaller`" -uninstall -quiet -norestart"
        }
    }
    function global:Start-Process {
        param ([string]$FilePath, [string]$ArgumentList, [switch]$PassThru)
        $global:powerBiCalls += [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMs) return $true }
        $process | Add-Member ScriptMethod Kill { }
        return $process
    }
    & $scriptPath -DeploymentType Uninstall
    if ($global:powerBiCalls.Count -ne 1 -or $global:powerBiCalls[0].FilePath -ne $global:powerBiUninstaller -or
        $global:powerBiCalls[0].ArgumentList -ne '-uninstall -quiet -norestart') {
        throw "Unexpected Power BI uninstall invocation: $($global:powerBiCalls | ConvertTo-Json -Compress)"
    }
    $global:powerBiInstalled = $false
    $global:powerBiCalls = @()
    & $scriptPath -DeploymentType Uninstall
    if ($global:powerBiCalls.Count) { throw 'Missing Power BI installation was not treated as success.' }
}
finally {
    Remove-Item function:\Test-Path, function:\Get-ChildItem, function:\Get-ItemProperty, function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Variable powerBiInstalled, powerBiCalls, powerBiUninstaller -Scope Global -ErrorAction SilentlyContinue
    $env:SystemRoot = $originalSystemRoot
    $env:SUPPRESS_FILELOG = $null
}
Write-Output 'Deploy-PowerBIDesktop tests passed.'

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$artifactPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\artifacts\Microsoft-WSL2'
$sourceScriptPath = Join-Path -Path $artifactPath -ChildPath 'Install-MicrosoftWSL2.ps1'
$readmePath = Join-Path -Path $artifactPath -ChildPath 'README.md'
$downloadsPath = Join-Path -Path $repoRoot -ChildPath 'customer-examples\parameters\imageManagement\downloads.json'

$rootScripts = @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File)
if ($rootScripts.Count -ne 1) {
    throw "Microsoft-WSL2 must contain exactly one root PowerShell script; found $($rootScripts.Count)."
}

$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $sourceScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Install-MicrosoftWSL2.ps1 has $($parseErrors.Count) PowerShell parse error(s)."
}
if (Get-Content -LiteralPath $sourceScriptPath | Where-Object { $_ -match '[^\x00-\x7E]' }) {
    throw 'Install-MicrosoftWSL2.ps1 contains non-ASCII content.'
}

function Get-ValidateSetValues {
    param([Parameter(Mandatory = $true)][string]$ParameterName)

    $parameter = $scriptAst.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq $ParameterName
    }
    if (-not $parameter) {
        throw "Parameter '$ParameterName' was not found."
    }

    return @(
        $parameter.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'ValidateSet' } |
            ForEach-Object { $_.PositionalArguments.SafeGetValue() }
    )
}

$phases = Get-ValidateSetValues -ParameterName 'Phase'
if (($phases -join ',') -ne 'EnablePlatform,ProvisionDistribution') {
    throw "Unexpected Phase values: $($phases -join ',')"
}

$distributions = Get-ValidateSetValues -ParameterName 'Distribution'
$expectedDistributions = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Debian', 'Kali-Linux', 'Rocky-Linux-9')
if (($distributions -join ',') -ne ($expectedDistributions -join ',')) {
    throw "Unexpected Distribution values: $($distributions -join ',')"
}

$scriptText = Get-Content -LiteralPath $sourceScriptPath -Raw
$requiredScriptText = @(
    "'Microsoft-Windows-Subsystem-Linux'",
    "'VirtualMachinePlatform'",
    "-Regions 'all'",
    "'WSL-x64.msi'",
    'DefaultVersion',
    'reg.exe ADD "HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss"',
    'Get-AppxIdentityName',
    "Get-Command -Name 'wsl.exe'",
    "-SuccessExitCodes @(0, 1638, 3010)",
    'Install-WSLFileDistribution',
    '--install --from-file $imagePath --name $distributionName --no-launch',
    "-Filter '*.wsl'",
    'WSL\$Name',
    "-ChildPath 'Distribution.wsl'",
    "{882E5A8C-CC7D-43B5-AB9D-2EF10E6859D2}",
    "{CB23A9AC-6072-4DA4-96CF-91100CF5A176}",
    ".Replace('__DISTRIBUTION_NAME__', `$Name)",
    'Set-Content -LiteralPath $bootstrapPath -Value $bootstrap -Encoding ASCII',
    '-ArgumentList "`"$stagingDirectory`" /inheritance:r'
)
foreach ($requiredText in $requiredScriptText) {
    if (-not $scriptText.Contains($requiredText)) {
        throw "Install-MicrosoftWSL2.ps1 is missing required text: $requiredText"
    }
}

$bootstrapMatch = [regex]::Match($scriptText, '(?s)\$bootstrap\s*=\s*@''\r?\n(?<Content>.*?)\r?\n''@')
if (-not $bootstrapMatch.Success) {
    throw 'The embedded Rocky Linux registration bootstrap was not found.'
}
$bootstrapTokens = $null
$bootstrapParseErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $bootstrapMatch.Groups['Content'].Value,
    [ref]$bootstrapTokens,
    [ref]$bootstrapParseErrors
) | Out-Null
if ($bootstrapParseErrors.Count -gt 0) {
    throw "The embedded Rocky Linux registration bootstrap has $($bootstrapParseErrors.Count) PowerShell parse error(s)."
}

$identityFunctionAst = $scriptAst.Find({
    param($ast)
    $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'Get-AppxIdentityName'
}, $true)
if (-not $identityFunctionAst) {
    throw 'Get-AppxIdentityName function AST was not found.'
}

$identityTestRoot = Join-Path -Path $env:TEMP -ChildPath "FederalAVD-WSL2-identity-$([guid]::NewGuid())"
try {
    $metadataPath = Join-Path -Path $identityTestRoot -ChildPath 'content\AppxMetadata'
    New-Item -Path $metadataPath -ItemType Directory -Force | Out-Null
    $manifestPath = Join-Path -Path $metadataPath -ChildPath 'AppxBundleManifest.xml'
    @'
<?xml version="1.0" encoding="utf-8"?>
<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle">
  <Identity Name="FederalAVD.WSL2.TestDistribution" Publisher="CN=FederalAVD" Version="1.0.0.0" />
</Bundle>
'@ | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $testPackagePath = Join-Path -Path $identityTestRoot -ChildPath 'TestDistribution.AppxBundle'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Join-Path -Path $identityTestRoot -ChildPath 'content'),
        $testPackagePath
    )

    Invoke-Expression $identityFunctionAst.Extent.Text
    $actualIdentity = Get-AppxIdentityName -PackagePath $testPackagePath
    if ($actualIdentity -ne 'FederalAVD.WSL2.TestDistribution') {
        throw "Unexpected AppX identity '$actualIdentity'."
    }
}
finally {
    Remove-Item function:\Get-AppxIdentityName -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $identityTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$downloads = Get-Content -LiteralPath $downloadsPath -Raw | ConvertFrom-Json
$downloadExpectations = @{
    MicrosoftWSL2 = @('WSL-x64.msi', 'Microsoft-WSL2')
    WSLUbuntu2404 = @('Ubuntu-24.04.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Ubuntu-24.04')
    WSLUbuntu2204 = @('Ubuntu-22.04.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Ubuntu-22.04')
    WSLDebian = @('Debian.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Debian')
    WSLKaliLinux = @('Kali-Linux.AppxBundle', 'Microsoft-WSL2\DistributionPackages\Kali-Linux')
    WSLRockyLinux9 = @('Rocky-9-WSL-Base.latest.x86_64.wsl', 'Microsoft-WSL2\DistributionPackages\Rocky-Linux-9')
}
foreach ($entryName in $downloadExpectations.Keys) {
    $entry = $downloads.$entryName
    if (-not $entry) {
        throw "downloads.json is missing '$entryName'."
    }

    $expectedFileName = $downloadExpectations[$entryName][0]
    $expectedFolder = $downloadExpectations[$entryName][1]
    if ($entry.DestinationFileName -ne $expectedFileName) {
        throw "'$entryName' has unexpected DestinationFileName '$($entry.DestinationFileName)'."
    }
    if (@($entry.DestinationFolders) -notcontains $expectedFolder) {
        throw "'$entryName' does not target '$expectedFolder'."
    }
}

$readmeText = Get-Content -LiteralPath $readmePath -Raw
foreach ($requiredText in @('"restart": true', 'FSLogix Profile Container', 'Windows 11 Enterprise multi-session', 'Per-user boundary', 'WSLRockyLinux9', 'wsl.exe --install --from-file', '.CHECKSUM')) {
    if (-not $readmeText.Contains($requiredText)) {
        throw "Microsoft-WSL2 README is missing required guidance: $requiredText"
    }
}

Write-Output 'Install-MicrosoftWSL2 tests passed.'

$repoRoot = Split-Path -Parent $PSScriptRoot
$msiArtifactScripts = @(
    'customer-examples\artifacts\7-Zip\Deploy-7-Zip.ps1'
    'customer-examples\artifacts\Adobe-Acrobat-Reader-DC\Deploy-AdobeReaderDC.ps1'
    'customer-examples\artifacts\Amazon-Workspaces-Client\Deploy-AmazonWorkspacesClient.ps1'
    'customer-examples\artifacts\DoD-InstallRoot\Deploy-InstallRoot.ps1'
    'customer-examples\artifacts\Google-Chrome-Enterprise\Deploy-GoogleChromeEnterprise.ps1'
    'customer-examples\artifacts\Microsoft-AVD-Multimedia-Redirection\Install-MicrosoftAVDMultimediaRedirection.ps1'
    'customer-examples\artifacts\Microsoft-AzCLI\Deploy-AzCLI.ps1'
    'customer-examples\artifacts\Microsoft-Edge-Enterprise\Deploy-MicrosoftEdgeEnterprise.ps1'
    'customer-examples\artifacts\Microsoft-PowerShell-7\Deploy-PowerShell7.ps1'
    'customer-examples\artifacts\PuTTY\Deploy-PuTTY.ps1'
)

Describe 'MSI exit code 1618 handling' {
    foreach ($relativePath in $msiArtifactScripts) {
        It "retries only after MSI reports contention in $relativePath" {
            $content = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw

            $content | Should Not Match 'Wait-MsiexecIdle'
            $content | Should Match 'function Invoke-MsiProcess'
            $content | Should Match '\$process\.ExitCode -ne 1618'
            $content | Should Match '\[int\]\$MaxAttempts = 11'
            $content | Should Match '\[int\]\$RetryDelaySeconds = 30'
            $content | Should Match 'Start-Sleep -Seconds \$RetryDelaySeconds'
        }
    }

    It 'does not wait for MSI before running the VS Code EXE installer' {
        $vscodeScript = Get-Content -LiteralPath (Join-Path $repoRoot 'customer-examples\artifacts\Microsoft-VSCode\Deploy-VSCode.ps1') -Raw
        $vscodeScript | Should Not Match 'Wait-MsiexecIdle|Invoke-MsiProcess'
    }

    It 'does not combine the equivalent quiet and qn options' {
        $artifactScripts = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'customer-examples\artifacts') -Filter '*.ps1' -File -Recurse
        foreach ($artifactScript in $artifactScripts) {
            $content = Get-Content -LiteralPath $artifactScript.FullName -Raw
            $content | Should Not Match '(?i)/quiet\s+/qn|/qn\s+/quiet'
        }
    }
}

Describe 'InstallRoot MSI application lifecycle' {
    BeforeAll {
        $artifactPath = Join-Path $repoRoot 'customer-examples\artifacts\DoD-InstallRoot'
        $scriptPath = Join-Path $artifactPath 'Deploy-InstallRoot.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
    }

    It 'uses one Deploy entry point' {
        @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File).Count | Should Be 1
        Test-Path -LiteralPath $scriptPath | Should Be $true
    }

    It 'exposes install and uninstall deployment types' {
        $content | Should Match "\[ValidateSet\('Install', 'Uninstall'\)\]"
        $content | Should Match "\[string\]\`$DeploymentType = 'Install'"
        $content | Should Match "\`$DeploymentType -eq 'Uninstall'"
    }

    It 'uses configurable success codes for install and uninstall' {
        $content | Should Match '\[int\[\]\]\$SuccessExitCodes = @\(0, 3010\)'
        ([regex]::Matches($content, '-notin \$SuccessExitCodes|-in \$SuccessExitCodes')).Count | Should Be 2
    }
}
