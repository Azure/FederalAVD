Function Install-Evergreen {
    $adminCheck = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())
    $Admin = $adminCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (Get-PSRepository | Where-Object { $_.Name -eq "PSGallery" -and $_.InstallationPolicy -ne "Trusted" }) {
        if ($Admin) {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy "Trusted"
            Install-PackageProvider -Name "NuGet" -MinimumVersion 2.8.5.208 -Force
        } else {
            Install-PackageProvider -Name "NuGet" -MinimumVersion 2.8.5.208 -Force -Scope CurrentUser
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
    $command = "Get-EvergreenApp -Name $($Evergreen.name)"
    $filters = @()
    if ($Evergreen.Architecture) {
        $filters += "$_.Architecture -eq '$($Evergreen.Architecture)'"
    }
    if ($Evergreen.InstallerType) {
        $filters += "$_.InstallerType -eq '$($Evergreen.InstallerType)'"
    }
    if ($Evergreen.Language) {
        $filters += "$_.Language -eq '$($Evergreen.Language)'"
    }
    if ($Evergreen.Type) {
        $filters += "$_.Type -eq '$($Evergreen.Type)'"
    } 
    if ($filters.Count -gt 0) {
        $command += " | Where-Object {" + ($filters -join " -and ") + "}"
    }
    Return (Invoke-Command -ScriptBlock $command).Uri
}