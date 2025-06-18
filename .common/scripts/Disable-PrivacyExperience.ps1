Function Set-RegistryValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name,
        [Parameter()]
        [string]
        $Path,
        [Parameter()]
        [string]$PropertyType,
        [Parameter()]
        $Value
    )


    # Create the registry Key(s) if necessary.
    If (!(Test-Path -Path $Path)) {
        Write-Host "[Set-RegistryValue]: Creating Registry Key: $Path"
        New-Item -Path $Path -Force | Out-Null
    }
    # Check for existing registry setting
    $RemoteValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    If ($RemoteValue) {
        # Get current Value
        $CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
        Write-Host "[Set-RegistryValue]: Current Value of $($Path)\$($Name) : $CurrentValue"
        If ($Value -ne $CurrentValue) {
            Write-Host "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
        }
        Else {
            Write-Host "[Set-RegistryValue]: Value of $($Path)\$($Name) is already set to $Value"
        }           
    }
    Else {
        Write-Host "[Set-RegistryValue]: Setting Value of $($Path)\$($Name) : $Value"
        New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force | Out-Null
    }
}

#endregion Functions

Set-RegistryValue -Name 'DisablePrivacyExperience' -Path 'HKLM:\Software\Policies\Microsoft\Windows\OOBE' -PropertyType DWORD -Value 1