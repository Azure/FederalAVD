Function Install-Evergreen {
    $adminCheck = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())
    $Admin = $adminCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    If (Get-PSRepository | Where-Object { $_.Name -eq "PSGallery" -and $_.InstallationPolicy -ne "Trusted" }) {
        Set-PSRepository -Name "PSGallery" -InstallationPolicy "Trusted"
    }
    If (-not (Get-PackageProvider | Where-Object {$_.Name -eq 'NuGet'})) {
        if ($Admin) {
            Install-PackageProvider -Name "NuGet" -Force
        } else {
            Install-PackageProvider -Name "NuGet" -Scope CurrentUser -Force
        }
    }
    $Installed = Get-Module -Name "Evergreen" -ListAvailable | `
        Sort-Object -Property @{ Expression = { [System.Version]$_.Version }; Descending = $true } | `
        Select-Object -First 1
    $Published = Find-Module -Name "Evergreen"
    if ($Null -eq $Installed -or [System.Version]$Published.Version -gt [System.Version]$Installed.Version) {
        If ($Admin) {
            Install-Module -Name "Evergreen" -Force -AllowClobber
        } else {
            Install-Module -Name "Evergreen" -Scope CurrentUser -Force -AllowClobber
        }
    }
    Import-Module -Name "Evergreen" -Force
}

function Get-EvergreenAppUri {
    param (
        [psobject]$Evergreen
    )
    $filters = @()
    if ($Evergreen.Architecture) {
        $Architecture = $Evergreen.Architecture
        $filters += '$_.Architecture -eq ''' + $Architecture + ''''
    }
    if ($Evergreen.InstallerType) {
        $InstallerType = $Evergreen.InstallerType
        $filters += '$_.InstallerType -eq ''' + $InstallerType + ''''
    }
    if ($Evergreen.Language) {
        $Language = $Evergreen.Language
        $filters += '$_.Language -eq ''' + $Language + ''''
    }
    if ($Evergreen.Type) {
        $Type = $Evergreen.Type
        $filters += '$_.Type -eq ''' + $Type + ''''
    } 
    if ($filters.Count -gt 0) {
        $WhereObject = ($filters -join ' -and ').replace('  ', ' ')
        $ScriptBlock = [scriptblock]::Create("Get-EvergreenApp -name $($Evergreen.name) | Where-Object {$($WhereObject)}")
        Return (Invoke-Command -ScriptBlock $ScriptBlock).Uri
    } Else {
        Return (Get-EvergreenApp -Name $($Evergreen.name)).Uri
    }
}