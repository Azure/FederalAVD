<#

.SYNOPSIS
Set up a VM as session host to existing/new host pool.

.DESCRIPTION
This script installs RD agent and verify that it is successfully registered as session host to existing/new host pool.

#>
param(
    [Parameter(mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $false)]
    [string]$RegistrationInfoToken="",

    [Parameter(mandatory = $false)] 
    [pscredential]$RegistrationInfoTokenCredential = $null,

    [Parameter(Mandatory = $false)]
    [bool]$AadJoin = $false,

    [Parameter(Mandatory = $false)]
    [bool]$AadJoinPreview = $false,

    [Parameter(Mandatory = $false)]
    [string]$MdmId = "",

    [Parameter(Mandatory = $false)]
    [string]$SessionHostConfigurationLastUpdateTime = "",

    [Parameter(mandatory = $false)] 
    [switch]$EnableVerboseMsiLogging,
    
    [Parameter(Mandatory = $false)]
    [bool]$UseAgentDownloadEndpoint = $false
)
$ScriptPath = [system.io.path]::GetDirectoryName($PSCommandPath)

# Dot sourcing Functions.ps1 file
. (Join-Path $ScriptPath "Functions.ps1")
. (Join-Path $ScriptPath "AvdFunctions.ps1")

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

# Checking if RDInfragent is registered or not in rdsh vm
Write-Log -Message "Checking whether VM was Registered with RDInfraAgent"
$RegistryCheckObj = IsRDAgentRegistryValidForRegistration

$RegistrationInfoTokenValue = ""
if ($null -eq $RegistrationInfoTokenCredential) {
    $RegistrationInfoTokenValue = $RegistrationInfoToken
} else {
    $RegistrationInfoTokenValue = $RegistrationInfoTokenCredential.GetNetworkCredential().Password
}

if ($RegistryCheckObj.result)
{
    Write-Log -Message "VM was already registered with RDInfraAgent, script execution was stopped"
}
else
{
    Write-Log -Message "Creating a folder inside rdsh vm for extracting deployagent zip file"
    $DeployAgentLocation = "C:\DeployAgent"
    ExtractDeploymentAgentZipFile -ScriptPath $ScriptPath -DeployAgentLocation $DeployAgentLocation

    Write-Log -Message "Changing current folder to Deployagent folder: $DeployAgentLocation"
    Set-Location "$DeployAgentLocation"

    Write-Log -Message "VM not registered with RDInfraAgent, script execution will continue"

    Write-Log "AgentInstaller is $DeployAgentLocation\RDAgentBootLoaderInstall, InfraInstaller is $DeployAgentLocation\RDInfraAgentInstall"

    if ($AadJoinPreview) {
        Write-Log "Azure ad join preview flag enabled"
        $registryPath = "HKLM:\SOFTWARE\Microsoft\RDInfraAgent\AzureADJoin"
        if (Test-Path -Path $registryPath) {
            Write-Log "Setting reg key JoinAzureAd"
            New-ItemProperty -Path $registryPath -Name JoinAzureAD -PropertyType DWord -Value 0x01
        } else {
            Write-Log "Creating path for azure ad join registry keys: $registryPath"
            New-item -Path $registryPath -Force | Out-Null
            Write-Log "Setting reg key JoinAzureAD"
            New-ItemProperty -Path $registryPath -Name JoinAzureAD -PropertyType DWord -Value 0x01
        }
        if ($MdmId) {
            Write-Log "Setting reg key MDMEnrollmentId"
            New-ItemProperty -Path $registryPath -Name MDMEnrollmentId -PropertyType String -Value $MdmId
        }
    }

    InstallRDAgents -AgentBootServiceInstallerFolder "$DeployAgentLocation\RDAgentBootLoaderInstall" -AgentInstallerFolder "$DeployAgentLocation\RDInfraAgentInstall" -RegistrationToken $RegistrationInfoTokenValue -EnableVerboseMsiLogging:$EnableVerboseMsiLogging -UseAgentDownloadEndpoint $UseAgentDownloadEndpoint

    Write-Log -Message "The agent installation code was successfully executed and RDAgentBootLoader, RDAgent installed inside VM for existing hostpool: $HostPoolName"

    $RootFolder = "C:\"
    Write-Log -Message "Changing current folder to root folder: $RootFolder"
    Set-Location "$RootFolder"
    
    Remove-Item -Path $DeployAgentLocation -Force -Confirm:$false -Recurse -ErrorAction Continue
    Write-Log -Message "Remove deploy agent folder after agent installation."
}

Write-Log -Message "Session Host Configuration Last Update Time: $SessionHostConfigurationLastUpdateTime"
$rdInfraAgentRegistryPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDInfraAgent"
if (Test-path $rdInfraAgentRegistryPath) {
    Write-Log -Message ("Write SessionHostConfigurationLastUpdateTime '$SessionHostConfigurationLastUpdateTime' to $rdInfraAgentRegistryPath")
    Set-ItemProperty -Path $rdInfraAgentRegistryPath -Name "SessionHostConfigurationLastUpdateTime" -Value $SessionHostConfigurationLastUpdateTime
}

if ($AadJoin -and -not $AadJoinPreview) {
    # 6 Minute sleep to guarantee intune metadata logging
    Write-Log -Message ("Configuration.ps1 complete, sleeping for 6 minutes")
    Start-Sleep -Seconds 360
    Write-Log -Message ("Configuration.ps1 complete, waking up from 6 minute sleep")
}

$SessionHostName = GetAvdSessionHostName
Write-Log -Message "Successfully registered VM '$SessionHostName' to HostPool '$HostPoolName'"
# SIG # Begin signature block
# MIIoSwYJKoZIhvcNAQcCoIIoPDCCKDgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCyZLBEW4Jf42lj
# rbgpqGp2svNWPGiyT6Z7Wz1C9KZZ3aCCDWowggY1MIIEHaADAgECAhMzAAAACpL4
# r6C9LAWMAAAAAAAKMA0GCSqGSIb3DQEBDAUAMIGEMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS4wLAYDVQQDEyVXaW5kb3dzIEludGVybmFsIEJ1
# aWxkIFRvb2xzIFBDQSAyMDIwMB4XDTI1MDMyMDE4NDcwOVoXDTI2MDMxODE4NDcw
# OVowgYQxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLjAsBgNV
# BAMTJVdpbmRvd3MgSW50ZXJuYWwgQnVpbGQgVG9vbHMgQ29kZVNpZ24wggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCx1VuXknj80ebbqGe5EGRcYHmn2qTd
# f1M/Aw40lAemaAxrHtFDjwJVUnd3Ag05RDmRuUdMJEYzVx435bnq62NHNskaZbEA
# JJop9sYtwr4mptX0WzbdMk0Gqf55UheVi9ZkXVdy+HvxEcpUhrkbvTGl5XEzh0id
# HHfbWu5uT60uHei4i+7qKwxlqcCEGS0RUz3xvuOga0iAY01XSS4UknZnOb1BbsaU
# Oh8f9Rkee6SkUwHxZirT6q5FDAGfF1UZ1rf4VzKI58FhTUL8z2DhrZ9/5Van2iJq
# v3e6GrHxhhcigljbUTOX1dBN9Ec2bbAnzZDe5N8r+KdJgbUadhFDhpF1AgMBAAGj
# ggGcMIIBmDAgBgNVHSUEGTAXBggrBgEFBQcDAwYLKwYBBAGCN0w3AQEwHQYDVR0O
# BBYEFDV254M7V2+4bbAYWAtQopT/XlB6MEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTQ1ODIwNCs1MDM5NDMw
# HwYDVR0jBBgwFoAUoH7qzmTrA0eRsqGw6GOA4/ZOZaEwaAYDVR0fBGEwXzBdoFug
# WYZXaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvV2luZG93cyUy
# MEludGVybmFsJTIwQnVpbGQlMjBUb29scyUyMFBDQSUyMDIwMjAuY3JsMHUGCCsG
# AQUFBwEBBGkwZzBlBggrBgEFBQcwAoZZaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9XaW5kb3dzJTIwSW50ZXJuYWwlMjBCdWlsZCUyMFRvb2xz
# JTIwUENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQwFAAOC
# AgEAQdd3sT666hE30zx1cTXQWBBKnnEHeg8MzYzHk2Efe1ybivfSO2TPl4uWNOXC
# 58GMuCo4KZ85zhY/hDpiev1jYTIBWPtVUZ079XX0d/OwjxJlkVk9P1qetwBXJCp6
# Tt2g1Z7wZkNEoCgJKZdnYPzvvrIlCs+9PzXpJUinFrvr2JdZfw2ZZ38M63BxWmcz
# g1BgiOaYzskFgwL6HxXwty5ZmPc1rPmrKFd3VrabXI9yGO8fHdr0o+CA1Kri0mb5
# QXTuk1hYmGVtotgrMS3y+pEeAe/6Mg+0MK/tWBJTqRmI7y/O+mQglNl/NKUB9t+G
# 7YLhrz3dPCNORZaSPdE20M31hNorzVydSNRiZdYJNtM2bAUUnmmZhNrrf9XqbmfH
# 4xhYrzOUMSXLwXQOaiNkpiw1tvyGYXYnjlZYx36QdzCijILYZpxqvu4ybuaZ7kCU
# A70GhvSvt2l7v24rNY9o8eOlrK1Lu6kgZVLSIdXfcwYXq7hfH4R/xdmbCwRgz4Df
# GTFZzfiqZoXZEp8SiGdxuDpRca9WqjmIS9KsiDhcynQ9wySAUCa6oZSDfIvFCPIZ
# VVetGvvtUMN1Yonv6lfPkdmeSlU1CjLV3ecVZzKzAOeNoy98HZp1zPzkeion0tBe
# Qnl2vzJbrWThKTSQgb0RWW98cn578NgTqOB41rtQWPCxgiswggctMIIFFaADAgEC
# AhMzAAAAVlq1acsdlGgsAAAAAABWMA0GCSqGSIb3DQEBDAUAMH4xCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBT
# ZXJ2aWNlcyBQYXJ0bmVyIFJvb3QwHhcNMjAwMjA1MjIzNDEyWhcNMzUwMjA1MjI0
# NDEyWjCBhDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEuMCwG
# A1UEAxMlV2luZG93cyBJbnRlcm5hbCBCdWlsZCBUb29scyBQQ0EgMjAyMDCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJeO8Bi8BZ0LmiWJmxhr8XqilrM9
# 8Le3i6/bgnolF1sE2w8obZr5HmO8FnkT+2TPpVMWsvnz8NaybPtns+i1a3lX+F85
# uM2pX+kBnaUPjRNZ4Nr4eYZeTNsu+fvJkkuFg1dcQqRypLdSbpSz4NSb6rjFxF7i
# Z2A7JnhVaR2eKSmFMCNH8fLz10ORthw/YwS1xvw/Lm5TU+YSRQWfydS+wgfMPapg
# oXtrOp28UH+HXoySBu0uQYC6azrB/eTPNiDQO4TlAJdWzV4yvLSpEKIVisUZTAQL
# cE9wVumQQvG8HKIF3v5hr+U/5aDEOJaqlNPqff99mYSuajKHQWPV4wJUHMohX93j
# nz7HhtJLhf/UeVglNcKayiiTI0NcCJbyPxD1/nCy2F3wnTmrF43lHJHHeNIunrNI
# sI6OhbELkWIZiVp83Dt9/5db2ULbdf564qRZAO2VUlvD0dFA1Ii9GZbqSThenYsY
# 0gnmZ1QIMJVJIt0zPUY1E0W+n/zkEedBM+jbaBw6De+zBNxTjpDg3qf1nRibmXGW
# SXv3uvyqzW+EnAozTUdr1LCCbsQTlEH+gzHG9nQy4zl1gTbbPMF77Lokxhueg/kr
# sHlsSGDI/GIBYu4fVvlU6uzAfahuQaFnIj5WHNkN6qwIFDFmNvpPRk+yOoMLAAm9
# XHKK1BxyOKixu/VTAgMBAAGjggGbMIIBlzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYB
# BAGCNxUBBAMCAQAwHQYDVR0OBBYEFKB+6s5k6wNHkbKhsOhjgOP2TmWhMFQGA1Ud
# IARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wGQYJKwYBBAGCNxQCBAwe
# CgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBSNuOM2u9Xe
# l8uvDk17vlofCBv6BjBRBgNVHR8ESjBIMEagRKBChkBodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NybC9NaWNTZXJQYXJSb290XzIwMTAtMDgtMjQuY3Js
# MF4GCCsGAQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNTZXJQYXJSb290XzIwMTAtMDgtMjQuY3J0
# MA0GCSqGSIb3DQEBDAUAA4ICAQBhSN9+w4ld9lyw3LwLhTlDV2sWMjpAjfOdbLFa
# tPpsSjVGHLBrfL+Y97dUfqCYNMYS5ByP41eRtKvrkby60pPxDjow8L/3tOVZmENd
# BU3vn28f7wCNy5gilO444fz4cBbUUQHnc94nMsODly3N6ohm5gGq7p0h9klLX/l5
# hbe2Rxl5UsJo3EuK8yqP7xz7thbL4QosQNsKiEFM91o8Q/Frdt+/gni6OTWVjCNM
# YHVB4CWttzJyvP8A1IzH0HEBG95Rdd9HMeudsYOHRuM4A0elUvRqOnsfqP7Zs46X
# NtBogW/IacvPGeuy3AHXIgMfFk35P9Mrt/ipDuqPy07faWLr0d+2++fWGv0yMSEf
# 0VWsMIYUK7fnmO+WK2j74KO/hFj3c+G/psecslWdT6zpeLntMB0IkqxN+Gw+qzc9
# 1vol2TEMHP2pITosnXYt33nZ9XR9YQmvMHBxwcF6qUALem5nOYMu574bCK6iOJdF
# SMfaUiLGppk7LOID0saA965KSWyxcpsxgvGnovjeUV1rJkN/NyPI3m5+t5w0v54J
# V2iCjgnsuF90m0cb2E3UUdEsbC6gBppQ/038OBoWMeVcd2ppmwP5O5vL5s4fCUp5
# p/og24gdqwrLJMZ+dHYVf3MsRqm7Lx3OVuxTuqbguRui+FdJtoBR/dMGFCWho1JE
# 8Qud9TGCGjcwghozAgEBMIGcMIGEMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMS4wLAYDVQQDEyVXaW5kb3dzIEludGVybmFsIEJ1aWxkIFRvb2xz
# IFBDQSAyMDIwAhMzAAAACpL4r6C9LAWMAAAAAAAKMA0GCWCGSAFlAwQCAQUAoIHU
# MBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgor
# BgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCSY61hYgJ+XsWz8mCsNLN55DnbmUuY
# riaxECCaHzbQrzBoBgorBgEEAYI3AgEMMVowWKA6gDgAVwBpAG4AZABvAHcAcwAg
# AEIAdQBpAGwAZAAgAFQAbwBvAGwAcwAgAEkAbgB0AGUAcgBuAGEAbKEagBhodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEACj/f+hLnQ9hQ
# czD3Oi+dy7zWaJk9EyPBNSa9OYOeSByvANWmUNiQY/wT++mMmLWYwMOcQBE189/1
# XJvsTR49wRhbXgx0Pt0R/XmsI0PwXtL3Kl5tMNQcYBokNHZhJ6eEQ4f9PuefiONQ
# PQC8AiVJsHFhYhf7Gfd6MNbkYE3ofwq+/Pijfo6vN0X06neW+o0to5fVJENvDFSn
# BM4TSBIQjZAFEPwuW8AEQS8ADLUU6ZFymHzy5Xr/s4jVkuBBbl/P1dQPSIN6WDh/
# zeCrl3NmWKvdUeX+JiRdFeckSNaRabDrPpVoRwX/UKZE9nApr5rxU9drbi5N/N9a
# Ml891uOY86GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCC
# F20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEE
# ggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCA2K+Uo1PgO
# qrRUUHIDLcJzLrLevsAwnIXzNZpAWymlFgIGaSc7lQv2GBMyMDI1MTIxMTA5MTIy
# Ny41MzhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIB
# AgITMwAAAgcsETmJzYX7xQABAAACBzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNTAxMzAxOTQyNTJaFw0yNjA0MjIxOTQy
# NTJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYD
# VQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDFP/96dPmcfgODe3/nuFveuBst/JmSxSkOn89ZFytHQm344iLoPqkVws+CiUej
# QabKf+/c7KU1nqwAmmtiPnG8zm4Sl9+RJZaQ4Dx3qtA9mdQdS7Chf6YUbP4Z++8l
# aNbTQigJoXCmzlV34vmC4zpFrET4KAATjXSPK0sQuFhKr7ltNaMFGclXSnIhcnSc
# j9QUDVLQpAsJtsKHyHN7cN74aEXLpFGc1I+WYFRxaTgqSPqGRfEfuQ2yGrAbWjJY
# OXueeTA1MVKhW8zzSEpfjKeK/t2XuKykpCUaKn5s8sqNbI3bHt/rE/pNzwWnAKz+
# POBRbJxIkmL+n/EMVir5u8uyWPl1t88MK551AGVh+2H4ziR14YDxzyCG924gaonK
# jicYnWUBOtXrnPK6AS/LN6Y+8Kxh26a6vKbFbzaqWXAjzEiQ8EY9K9pYI/KCygix
# jDwHfUgVSWCyT8Kw7mGByUZmRPPxXONluMe/P8CtBJMpuh8CBWyjvFfFmOSNRK8E
# TkUmlTUAR1CIOaeBqLGwscShFfyvDQrbChmhXib4nRMX5U9Yr9d7VcYHn6eZJsgy
# zh5QKlIbCQC/YvhFK42ceCBDMbc+Ot5R6T/Mwce5jVyVCmqXVxWOaQc4rA2nV7on
# MOZC6UvCG8LGFSZBnj1loDDLWo/I+RuRok2j/Q4zcMnwkQIDAQABo4IBSTCCAUUw
# HQYDVR0OBBYEFHK1UmLCvXrQCvR98JBq18/4zo0eMB8GA1UdIwQYMBaAFJ+nFV0A
# XmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQ
# Q0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIw
# VGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYD
# VR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEB
# CwUAA4ICAQDju0quPbnix0slEjD7j2224pYOPGTmdDvO0+bNRCNkZqUv07P04nf1
# If3Y/iJEmUaU7w12Fm582ImpD/Kw2ClXrNKLPTBO6nfxvOPGtalpAl4wqoGgZxvp
# xb2yEunG4yZQ6EQOpg1dE9uOXoze3gD4Hjtcc75kca8yivowEI+rhXuVUWB7vog4
# TGUxKdnDvpk5GSGXnOhPDhdId+g6hRyXdZiwgEa+q9M9Xctz4TGhDgOKFsYxFhXN
# JZo9KRuGq6evhtyNduYrkzjDtWS6gW8akR59UhuLGsVq+4AgqEY8WlXjQGM2OTky
# BnlQLpB8qD7x9jRpY2Cq0OWWlK0wfH/1zefrWN5+be87Sw2TPcIudIJn39bbDG7a
# wKMVYDHfsPJ8ZvxgWkZuf6ZZAkph0eYGh3IV845taLkdLOCvw49Wxqha5Dmi2Ojh
# 8Gja5v9kyY3KTFyX3T4C2scxfgp/6xRd+DGOhNVPvVPa/3yRUqY5s5UYpy8Dnbpp
# V7nQO2se3HvCSbrb+yPyeob1kUfMYa9fE2bEsoMbOaHRgGji8ZPt/Jd2bPfdQoBH
# cUOqPwjHBUIcSc7xdJZYjRb4m81qxjma3DLjuOFljMZTYovRiGvEML9xZj2pHRUy
# v+s5v7VGwcM6rjNYM4qzZQM6A2RGYJGU780GQG0QO98w+sucuTVrfTCCB3EwggVZ
# oAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jv
# c29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4
# MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvX
# JHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa
# /rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AK
# OG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rbo
# YiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIck
# w+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbni
# jYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F
# 37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZ
# fD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIz
# GHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR
# /bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1
# Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUC
# AwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0O
# BBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkr
# BgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUw
# AwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBN
# MEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0
# cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoG
# CCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01p
# Y1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9
# /Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5
# bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvf
# am++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn
# 0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlS
# dYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0
# j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5
# JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakUR
# R6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4
# O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVn
# K+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoI
# Yn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSB
# zjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjg2MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQDTvVU/Yj9lUSyeDCaiJ2Da
# 5hUiS6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqG
# SIb3DQEBCwUAAgUA7OTV+TAiGA8yMDI1MTIxMTA1MzI0MVoYDzIwMjUxMjEyMDUz
# MjQxWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDs5NX5AgEAMAcCAQACAgbRMAcC
# AQACAhM5MAoCBQDs5id5AgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAIk1
# 0Yb3Jt9NOVFVt5FYyGnhKXbne2deMPPmH86/pKp1W5WeQNJhyTsVo4Aqx5B2eT0L
# 0esauvLJqd5hkOyc6yl5J/+XfcUKW69jbxV+8r202z2/IhiEk0liFcz743sek8dD
# TXY+Pe2AF1eMZmeZ0406Q+kHT9z4nFTkFzyzUGCs2IBgALvXociFW5O1TSU7O97r
# gtfHu7QPdOXjbN/Q/6/RyZ3aZfLBXNlSoHGk1OrLr7Ml58mmWogAoqlgoejKsmaZ
# Bp3jjISPG1yeFqq7ATzITwEbnKwjiLNqIAE7k0xlNtoV8+G8b/LsX9vupSwV7Y+H
# uwr9AsdITSwsCUTNQkExggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAgcsETmJzYX7xQABAAACBzANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBy
# eGEkd4QE9fvDCTPe75nvoyIBizjORegF36ojK1fOizCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EIC/31NHQds1IZ5sPnv59p+v6BjBDgoDPIwiAmn0PHqezMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIHLBE5ic2F
# +8UAAQAAAgcwIgQgkO1oiMM46VhWTEMWujTYtOY9fjPcPK1FEHXEYybMatIwDQYJ
# KoZIhvcNAQELBQAEggIAokR1PKZpoRV+mAhy27uqdtYmQrOwcg0QzFZiJbJ8eHRq
# q83lTRIKTXu81wmowki0PrIiOuj9gU49pSgGKjn9Wii5/gHx1yihbWAuUt7digr8
# gAvLu8UdtsQr/wfyiqQB+PE6sX2NrBIaEvNYiqJ0x7lWVyFAcbk/oWrSCIy+UvJ7
# OoXsUyW2gDhSA6jwVu6wlNFPrv+lv0xaXFzxUFmI8sIGnkw5idKXGdGu8Af+XvFX
# jPCjPp3gAJDZCPkrojMemJ6l6+O7ZJ5Nt4eKXVNvTL60tvfZeGAfG47s0uwNx3jb
# CP1cc+WB8cL8rGrnnpk0TvmiUTp/wwJcJ4Lz61ZHsmruobBX52vrXre89VBqGCrJ
# EGOIQddBuo66GNxZEzl34Q0zla+dH080cIrwcIbwZ0wHgmY77GpTq4AC8Ppg3+sv
# eG3opRb4b7DLYLhclYCvZ291taUIpv9bf2TsRjCYmn+dnMQ+VUcGtnc9bod+/Vtw
# q25mzmmEE79UThwk0WK4e7rF3us0KA+WAigXPPpsBE3ECHWOYF2RUok+EAamXNdd
# BwpVb0nJo+8W/a1yZ74zJovtr4Hb7miXQoCPVBHraGGTUK76WJHZYyBRGu9HnH10
# d2uh8aN7V0yhaezSFz9XCAF9GVLImASfVYrqTsYIrPj2cCMfsqEaZNfb9wuWZuI=
# SIG # End signature block
