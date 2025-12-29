# SessionHostReplacer Module

## Overview

This PowerShell module provides core functionality for the AVD Session Host Replacer Azure Function. By packaging the helper functions as a proper module, we improve initialization performance and follow Azure Functions best practices.

## Module Structure

```
functions/
├── Modules/
│   └── SessionHostReplacer/
│       ├── SessionHostReplacer.psm1    # Module implementation
│       └── SessionHostReplacer.psd1    # Module manifest
├── profile_new.ps1                      # Minimal profile that imports module
├── requirements.psd1                    # PowerShell Gallery dependencies
└── run.ps1                              # Function entry point
```

## Why Use a Module?

### Performance Benefits
- **Faster initialization**: Large profile.ps1 files (~1879 lines) can prevent function initialization
- **Lazy loading**: Functions loaded on-demand rather than all at startup
- **Better caching**: PowerShell can cache compiled module code

### Best Practices
- **Separation of concerns**: profile.ps1 should be minimal (initialization only)
- **Testability**: Modules can be imported and tested independently
- **Reusability**: Module functions can be used across multiple functions
- **Maintainability**: Easier to organize and document large codebases

## Exported Functions

### Authentication
- `Get-AccessToken` - Acquires tokens using managed identity

### Configuration
- `Read-FunctionAppSetting` - Reads function app settings with type conversion

### Logging
- `Write-HostDetailed` - Enhanced logging with timestamps and levels

### Azure REST API
- `Invoke-AzureRestMethod` - REST API calls with paging support
- `Invoke-AzureRestMethodWithRetry` - REST API with retry logic
- `Invoke-GraphApiWithRetry` - Graph API with endpoint fallback

### State Management
- `Get-DeploymentState` - Retrieves deployment state from Azure Table Storage
- `Save-DeploymentState` - Saves deployment state to Azure Table Storage

### Utilities
- `ConvertTo-CaseInsensitiveHashtable` - Converts objects to case-insensitive hashtables

## Deployment

The Bicep template automatically deploys the module structure:

```bicep
files: {
  'run.ps1': loadTextContent('functions/run.ps1')
  '../profile.ps1': loadTextContent('functions/profile_new.ps1')
  '../requirements.psd1': loadTextContent('functions/requirements.psd1')
  '../Modules/SessionHostReplacer/SessionHostReplacer.psm1': loadTextContent('...')
  '../Modules/SessionHostReplacer/SessionHostReplacer.psd1': loadTextContent('...')
}
```

## Usage in Functions

In your function's `run.ps1`:

```powershell
# Functions from the module are automatically available
$token = Get-AccessToken -ResourceUrl $resourceManagerUrl
$setting = Read-FunctionAppSetting HostPoolName
Write-HostDetailed "Processing host pool: $setting" -Level Information

# Use state management functions
$state = Get-DeploymentState -HostPoolName 'hp-prod-001'
Save-DeploymentState -DeploymentState $updatedState
```

## Development

To add new functions to the module:

1. Add the function to `SessionHostReplacer.psm1`
2. Add the function name to the `Export-ModuleMember` list
3. Add the function name to the `FunctionsToExport` array in `SessionHostReplacer.psd1`
4. Update this README

## Testing Locally

```powershell
# Import the module
Import-Module .\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1 -Force

# Test a function
Write-HostDetailed "Test message" -Level Information

# Check exported functions
Get-Command -Module SessionHostReplacer
```

## Version History

- **1.0.0** (2024-12-28)
  - Initial module creation
  - Converted from large profile.ps1 file
  - Includes authentication, configuration, logging, REST API, and state management functions
  - Native REST API implementation for Azure Table Storage (no Az module dependencies)

## Notes

- The module uses **native REST API calls** for Azure Table Storage operations
- **No Az.Storage or AzTable module dependencies** - all operations use managed identity with bearer tokens
- **Cloud-agnostic** - supports Azure Commercial, Government, and China clouds
- All functions support the **PowerShell pipeline** where applicable
