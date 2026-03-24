configuration AddSessionHost
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$HostPoolName,

        [Parameter(Mandatory = $false)]
        [string]$RegistrationInfoToken = "",

        [Parameter(Mandatory = $false)]
        [PSCredential]$RegistrationInfoTokenCredential = $null,

        [Parameter(Mandatory = $false)]
        [bool]$AadJoin = $false,

        [Parameter(Mandatory = $false)]
        [bool]$AadJoinPreview = $false,

        [Parameter(Mandatory = $false)]
        [string]$MdmId = "",

        [Parameter(Mandatory = $false)]
        [string]$SessionHostConfigurationLastUpdateTime = "",

        [Parameter(Mandatory = $false)]
        [bool]$EnableVerboseMsiLogging = $false,
        
        [Parameter(Mandatory = $false)]
        [bool]$UseAgentDownloadEndpoint = $false
    )

    $ErrorActionPreference = 'Stop'
    
    $ScriptPath = [system.io.path]::GetDirectoryName($PSCommandPath)
    . (Join-Path $ScriptPath "Functions.ps1")

    $rdshIsServer = isRdshServer

    Node localhost
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
            ConfigurationMode = "ApplyOnly"
        }

        if ($rdshIsServer)
        {
            "$(get-date) - rdshIsServer = true: $rdshIsServer" | out-file c:\windows\temp\rdshIsServerResult.txt -Append
            WindowsFeature RDS-RD-Server
            {
                Ensure = "Present"
                Name = "RDS-RD-Server"
            }

            Script ExecuteRdAgentInstallServer
            {
                DependsOn = "[WindowsFeature]RDS-RD-Server"
                GetScript = {
                    return @{'Result' = ''}
                }
                SetScript = {
                    . (Join-Path $using:ScriptPath "Functions.ps1")
                    try {
                        & "$using:ScriptPath\Script-SetupSessionHost.ps1" -HostPoolName $using:HostPoolName -RegistrationInfoToken $using:RegistrationInfoToken -RegistrationInfoTokenCredential $using:RegistrationInfoTokenCredential -AadJoin $using:AadJoin -AadJoinPreview $using:AadJoinPreview -MdmId $using:MdmId -SessionHostConfigurationLastUpdateTime $using:SessionHostConfigurationLastUpdateTime -UseAgentDownloadEndpoint $using:UseAgentDownloadEndpoint -EnableVerboseMsiLogging:($using:EnableVerboseMsiLogging)
                    }
                    catch {
                        $ErrMsg = $PSItem | Format-List -Force | Out-String
                        Write-Log -Err $ErrMsg
                        throw [System.Exception]::new("Some error occurred in DSC ExecuteRdAgentInstallServer SetScript: $ErrMsg", $PSItem.Exception)
                    }
                }
                TestScript = {
                    . (Join-Path $using:ScriptPath "Functions.ps1")
                    
                    try {
                        return (& "$using:ScriptPath\Script-TestSetupSessionHost.ps1" -HostPoolName $using:HostPoolName)
                    }
                    catch {
                        $ErrMsg = $PSItem | Format-List -Force | Out-String
                        Write-Log -Err $ErrMsg
                        throw [System.Exception]::new("Some error occurred in DSC ExecuteRdAgentInstallServer TestScript: $ErrMsg", $PSItem.Exception)
                    }
                }
            }
        }
        else
        {
            "$(get-date) - rdshIsServer = false: $rdshIsServer" | out-file c:\windows\temp\rdshIsServerResult.txt -Append
            Script ExecuteRdAgentInstallClient
            {
                GetScript = {
                    return @{'Result' = ''}
                }
                SetScript = {
                    . (Join-Path $using:ScriptPath "Functions.ps1")
                    try {
                        & "$using:ScriptPath\Script-SetupSessionHost.ps1" -HostPoolName $using:HostPoolName -RegistrationInfoToken $using:RegistrationInfoToken -RegistrationInfoTokenCredential $using:RegistrationInfoTokenCredential -AadJoin $using:AadJoin -AadJoinPreview $using:AadJoinPreview -MdmId $using:MdmId -SessionHostConfigurationLastUpdateTime $using:SessionHostConfigurationLastUpdateTime -UseAgentDownloadEndpoint $using:UseAgentDownloadEndpoint -EnableVerboseMsiLogging:($using:EnableVerboseMsiLogging)
                    }
                    catch {
                        $ErrMsg = $PSItem | Format-List -Force | Out-String
                        Write-Log -Err $ErrMsg
                        throw [System.Exception]::new("Some error occurred in DSC ExecuteRdAgentInstallClient SetScript: $ErrMsg", $PSItem.Exception)
                    }
                }
                TestScript = {
                    . (Join-Path $using:ScriptPath "Functions.ps1")
                    
                    try {
                        return (& "$using:ScriptPath\Script-TestSetupSessionHost.ps1" -HostPoolName $using:HostPoolName)
                    }
                    catch {
                        $ErrMsg = $PSItem | Format-List -Force | Out-String
                        Write-Log -Err $ErrMsg
                        throw [System.Exception]::new("Some error occurred in DSC ExecuteRdAgentInstallClient TestScript: $ErrMsg", $PSItem.Exception)
                    }

                }
            }
        }
    }
}
# SIG # Begin signature block
# MIIoZAYJKoZIhvcNAQcCoIIoVTCCKFECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCQDVHUP8nRpbh7
# 7qUh2wf0Om2ZSMXyYaZaoiGTXdfZ/qCCDWowggY1MIIEHaADAgECAhMzAAAACpL4
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
# 8Qud9TGCGlAwghpMAgEBMIGcMIGEMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMS4wLAYDVQQDEyVXaW5kb3dzIEludGVybmFsIEJ1aWxkIFRvb2xz
# IFBDQSAyMDIwAhMzAAAACpL4r6C9LAWMAAAAAAAKMA0GCWCGSAFlAwQCAQUAoIHU
# MBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgor
# BgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDVkCjGtCeYmgALnNw+izL7tFAPKeLx
# OVYvF25dJtdD1TBoBgorBgEEAYI3AgEMMVowWKA6gDgAVwBpAG4AZABvAHcAcwAg
# AEIAdQBpAGwAZAAgAFQAbwBvAGwAcwAgAEkAbgB0AGUAcgBuAGEAbKEagBhodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEApWmva1DQ/ngM
# OdvRuBMwrFoN2ZppnmyppbPQi1uRPhIKwKc8Z3y3HmVUgLGoM8WG2pWzoZQOhF/7
# hWmPrWw6OPn6zUF+ZnzNIDJrYTmkeh4ZMNij688vqnt9xzOg2bjJC3XhS/1I5UbA
# Kne622y/9riKWfPixXBL1PLygC8/FgIY/n6fqFDaLVhMvOSxH7zmoDJHmhZwgW7c
# bG6M/9jqAjdh4kDjPRoQTFXouGHRAELK78bszKrnsFUPEn9Zu96kGAHTrNS5SJ1c
# igYWvSdnHXNlv4Jd2I3sTJu0ojykpruIW497eNTUUC7X2i7E6CtoSC87zJthgf2y
# HB0Yg09ciKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCC
# F4YwgheCAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkE
# ggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDjccFNTllh
# p54uJs3VxMrnD3sIvSPfdd/nNgSaFNfdegIGaSTol8FaGBMyMDI1MTIxMTA5MTIx
# OS4yODZaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25z
# IExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2QjA1LTA1RTAtRDk0
# NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggco
# MIIFEKADAgECAhMzAAACEUUYOZtDz/xsAAEAAAIRMA0GCSqGSIb3DQEBCwUAMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgxM1oXDTI2
# MTExMzE4NDgxM1owgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRl
# ZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZCMDUtMDVFMC1EOTQ3MSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAz7m7MxAdL5Vayrk7jsMo3GnhN85ktHCZEvEcj4BI
# ccHKd/NKC7uPvpX5dhO63W6VM5iCxklG8qQeVVrPaKvj8dYYJC7DNt4NN3XlVdC/
# voveJuPPhTJ/u7X+pYmV2qehTVPOOB1/hpmt51SzgxZczMdnFl+X2e1PgutSA5CA
# h9/Xz5NW0CxnYVz8g0Vpxg+Bq32amktRXr8m3BSEgUs8jgWRPVzPHEczpbhloGGE
# fHaROmHhVKIqN+JhMweEjU2NXM2W6hm32j/QH/I/KWqNNfYchHaG0xJljVTYoUKP
# pcQDuhH9dQKEgvGxj2U5/3Fq1em4dO6Ih04m6R+ttxr6Y8oRJH9ZhZ3sciFBIvZh
# 7E2YFXOjP4MGybSylQTPDEFAtHHgpkskeEUhsPDR9VvWWhekhQx3qXaAKh+AkLmz
# /hpE3e0y+RIKO2AREjULJAKgf+R9QnNvqMeMkz9PGrjsijqWGzB2k2JNyaUYKlbm
# QweOabsCioiY2fJbimjVyFAGk5AeYddUFxvJGgRVCH7BeBPKAq7MMOmSCTOMZ0Sw
# 6zyNx4Uhh5Y0uJ0ZOoTKnB3KfdN/ba/eKHFeEhi3WqAfzTxiy0rMvhsfsXZK7zoc
# lqaRvVl8Q48J174+eyriypY9HhU+ohgiYi4uQGDDVdTDeKDtoC/hD2Cn+ARzwE1r
# FfECAwEAAaOCAUkwggFFMB0GA1UdDgQWBBRifUUDwOnqIcvfb53+yV0EZn7OcDAf
# BgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQ
# hk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQl
# MjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBe
# MFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Nl
# cnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAM
# BgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQE
# AwIHgDANBgkqhkiG9w0BAQsFAAOCAgEApEKdnMeIIUiU6PatZ/qbrwiDzYUMKRcz
# C4Bp/XY1S9NmHI+2c3dcpwH2SOmDfdvIIqt7mRrgvBPYOvJ9CtZS5eeIrsObC0b0
# ggKTv2wrTgWG+qktqNFEhQeipdURNLN68uHAm5edwBytd1kwy5r6B93klxDsldOm
# VWtw/ngj7knN09muCmwr17JnsMFcoIN/H59s+1RYN7Vid4+7nj8FcvYy9rbZOMnd
# BzsTiosF1M+aMIJX2k3EVFVsuDL7/R5ppI9Tg7eWQOWKMZHPdsA3ZqWzDuhJqTzo
# FSQShnZenC+xq/z9BhHPFFbUtfjAoG6EDPjSQJYXmogja8OEa19xwnh3wVufeP+c
# k+/0gxNi7g+kO6WaOm052F4siD8xi6Uv75L7798lHvPThcxHHsgXqMY592d1wUof
# 3tL/eDaQ0UhnYCU8yGkU2XJnctONnBKAvURAvf2qiIWDj4Lpcm0zA7VuofuJR1Tp
# uyc5p1ja52bNZBBVqAOwyDhAmqWsJXAjYXnssC/fJkee314Fh+GIyMgvAPRScgqR
# ZqV16dTBYvoe+w1n/wWs/ySTUsxDw4T/AITcu5PAsLnCVpArDrFLRTFyut+eHUoG
# 6UYZfj8/RsuQ42INse1pb/cPm7G2lcLJtkIKT80xvB1LiaNvPTBVEcmNSvFUM0xr
# XZXcYcxVXiYwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqG
# SIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkg
# MjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKC
# AgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4X
# YDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTz
# xXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7
# uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlw
# aQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedG
# bsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXN
# xF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03
# dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9
# ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5
# UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReT
# wDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZ
# MBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8
# RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAE
# VTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAww
# CgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQD
# AgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb
# 186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29t
# L3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoG
# CCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZI
# hvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9
# MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2Lpyp
# glYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OO
# PcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8
# DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA
# 0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1Rt
# nWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjc
# ZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq7
# 7EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJ
# C4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328
# y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYID
# VjCCAj4CAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25z
# IExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2QjA1LTA1RTAtRDk0
# NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcG
# BSsOAwIaAxUAKyp8q2VdgAq1VGkzd7PZwV6zNc2ggYMwgYCkfjB8MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQg
# VGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAOzkfg4wIhgPMjAy
# NTEyMTAyMzE3MzRaGA8yMDI1MTIxMTIzMTczNFowdDA6BgorBgEEAYRZCgQBMSww
# KjAKAgUA7OR+DgIBADAHAgEAAgIcaTAHAgEAAgISpTAKAgUA7OXPjgIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQB2biPf86XebnbLNVx+dltdMNpU3ucZJhxO
# M9mpzK6ulroxzhLxPHM6N7WYLIdQurim4zUd6T4FmrfCmCC93L+S467S7ea3b/7B
# 9zxPbkdUB1bAxs3d732GPHH0uunh+uy0/Qb8xBulWHPOZUI1PcLYyVAuKk49tpC/
# i6plTy0k2aAfDmVjlvAYh/hj7eWIMUMYVVBVZOJH50M6IoXSg3IRBwzv7ldaeo7t
# HBvM4a/Tpf3IAHvXWWwz1tpgYfmDWoimnTpA/5AopZiStLMUE0dW56027M3y9PhW
# loy9+d1YwOENXDOAvm2t7XngU9c60ap3PQA/cylZDDE2uP3Kl7SaMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIRRRg5m0PP
# /GwAAQAAAhEwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQguPJ8mwJrE+Iyo9Vkaxw6XK+tRriBICH3
# u9ViqSIKfzYwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCAsrTOpmu+HTq1a
# XFwvlhjF8p2nUCNNCEX/OWLHNDMmtzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACEUUYOZtDz/xsAAEAAAIRMCIEIJzo+PCM95Us4eya
# Ru3y8FIj4oX9VTbP/u/cNltufeUuMA0GCSqGSIb3DQEBCwUABIICALXlJ+dlsoRp
# gBZHg1pkUyDftuNPvLZuJQ9qxjc2rtH5hF/q04JFs9ZimSt6o4Gr7MpKV8Trp8sL
# f+HrIrV+mTUEY09RpjzL+Bt6QsP2FDzAtw7/M5l5MuvNkWfDN/WEIkVDmyAufDRd
# 3cN2Ghxg6VzVyU2ZNa8KjRxHq+a/hm8evHjaFyfVN8lTDkxC4jB16yorj1tcZ6XG
# qoOOgEKRnvH9ZrqjAjq/wWXTgZvQ0m9eOIhRpvS2TXgA+tHkHcWBz+OgI4V0S2qa
# NFkiZWoMRYyAySr+/Mm0lpL/ejY+4JNMcwvtpXP6k21Qw/RTK9IHeCge2OBR2NHA
# SZ9zaUKTlkE++zxLfHCY70n2Z/BgniyS6uay+BVXqmJGVkCRjF4L6yfYQXuIYwB0
# jHII73dTV0Vu9gCxbI2MFIGpMjRHzZbhI9SRDAPXOsrqLsc+lrDTDIkGia6iNg+Z
# +bSyZ+i4l/OccAQBRask0ARtULyFK4n+qqC6e7yUdSHQtkS2eXoCjFaPmBIh3fhU
# enk+1J+aDV5pDYpagF2q5wxGyLgh14Fied8aQ3deYu3bYiiTLR3Ft/ZuUG3BnAdI
# PgQTkX+uezS/Riv50x4y1kL4mGPOeTbwjiOq7yh4fOpGmOeJu2nmeoVLNtps0UxK
# MJd9+o71/T8nDrYMSjuvAs55Mz5fS9vv
# SIG # End signature block
