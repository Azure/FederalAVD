# Azure Functions profile.ps1
#
# This profile is loaded at function app startup. Keep it minimal - use modules for heavy lifting.
#

# Configure TLS 1.2 and 1.3 support for secure connections
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Determine the correct path to the Modules directory
# In Azure Functions, profile.ps1 is in the parent directory, so modules are at ./Modules

$ModulePath = (Get-ChildItem -Path $PSScriptRoot -Filter SessionHostReplacer.psd1 -Recurse).FullName

if ($modulePath) {
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Information "SessionHostReplacer module loaded successfully from $modulePath" -InformationAction Continue
} else {
    Write-Error "Module not found"
    throw "Failed to load SessionHostReplacer module"
}
