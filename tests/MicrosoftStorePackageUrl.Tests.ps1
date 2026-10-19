$updaterPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'deployments\Update-ImageArtifacts.ps1'
$updaterAst = [Management.Automation.Language.Parser]::ParseFile($updaterPath, [ref]$null, [ref]$null)
$resolver = $updaterAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MicrosoftStorePackageUrl'
}, $true)
. ([scriptblock]::Create($resolver.Extent.Text))

Describe 'Direct Microsoft Store package link resolver' {
    BeforeEach {
        # Pester 3 mocks called from another script do not share the test's script scope.
        $global:FederalAvdStoreResolverTest = @{
            SyncCalls = 0
            Scenario = 'normal'
            Requests = [Collections.Generic.List[xml]]::new()
        }
        Mock Invoke-RestMethod {
            $fulfillment = @{
                WuCategoryId = '11111111-1111-1111-1111-111111111111'
                PackageFamilyName = 'Example.App_abcdefghijklm'
            }
            if ($global:FederalAvdStoreResolverTest.Scenario -eq 'string-fulfillment') {
                $fulfillment = $fulfillment | ConvertTo-Json -Compress
            }
            if ($global:FederalAvdStoreResolverTest.Scenario -eq 'no-category') {
                $fulfillment = @{}
            }
            @{ Product = @{ DisplaySkuAvailabilities = @(
                @{ Sku = @{ Properties = @{ FulfillmentData = $fulfillment } } }
                @{ Sku = @{ Properties = @{ FulfillmentData = $fulfillment } } }
            ) } }
        }
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Body)
            [xml]$request = [Text.Encoding]::UTF8.GetString($Body)
            $global:FederalAvdStoreResolverTest.Requests.Add($request)
            $operation = $request.Envelope.Body.FirstChild
            $ns = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'
            $payload = switch ($operation.LocalName) {
                'GetCookie' {
                    if ($global:FederalAvdStoreResolverTest.Scenario -eq 'bad-cookie') {
                        '<GetCookieResult />'
                    } else {
                        '<GetCookieResult><Expiration>2099-01-01T00:00:00Z</Expiration><EncryptedData>test-cookie</EncryptedData></GetCookieResult>'
                    }
                }
                'SyncUpdates' {
                    $global:FederalAvdStoreResolverTest.SyncCalls++
                    if ($global:FederalAvdStoreResolverTest.Scenario -eq 'fault') {
                        return @{ Content = '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Reason>Test SOAP fault</s:Reason></s:Fault></s:Body></s:Envelope>' }
                    }
                    if ($global:FederalAvdStoreResolverTest.Scenario -eq 'truncated') {
                        '<SyncUpdatesResult><Truncated>true</Truncated></SyncUpdatesResult>'
                    } elseif ($global:FederalAvdStoreResolverTest.SyncCalls -eq 1) {
                        $base = '<UpdateIdentity UpdateID="22222222-2222-2222-2222-222222222222" RevisionNumber="7" />'
                        $base += '<AppxMetadata PackageMoniker="Example.App_1.0.0.0_x64__abcdefghijklm" />'
                        $baseX86 = $base.Replace('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333').Replace('_x64_', '_x86_')
                        $baseNeutral = $base.Replace('22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444').Replace('_x64_', '_neutral_')
                        $base = [Security.SecurityElement]::Escape($base)
                        $baseX86 = [Security.SecurityElement]::Escape($baseX86)
                        $baseNeutral = [Security.SecurityElement]::Escape($baseNeutral)
                        @"
<SyncUpdatesResult><NewUpdates>
  <UpdateInfo><ID>10</ID><IsLeaf>false</IsLeaf><Xml>$base</Xml></UpdateInfo>
  <UpdateInfo><ID>11</ID><IsLeaf>true</IsLeaf><Xml>$baseX86</Xml></UpdateInfo>
  <UpdateInfo><ID>12</ID><IsLeaf>true</IsLeaf><Xml>$baseNeutral</Xml></UpdateInfo>
</NewUpdates><Truncated>false</Truncated>
<NewCookie><Expiration>2099-01-01T00:00:00Z</Expiration><EncryptedData>refreshed-cookie</EncryptedData></NewCookie>
</SyncUpdatesResult>
"@
                    } elseif ($global:FederalAvdStoreResolverTest.SyncCalls -eq 2) {
                        $files = '<Files><File FileName="example.msix" Digest="test-digest" DigestAlgorithm="SHA1" Size="123" />'
                        $files += '<File FileName="blockmap.cab" Digest="block-digest" DigestAlgorithm="SHA1" Size="10" /></Files>'
                        if ($global:FederalAvdStoreResolverTest.Scenario -eq 'missing-files') {
                            $files = '<ExtendedProperties />'
                        }
                        $files = [Security.SecurityElement]::Escape($files)
                        @"
<SyncUpdatesResult><NewUpdates /><Truncated>false</Truncated><ExtendedUpdateInfo><Updates>
<Update><ID>10</ID><Xml>$files</Xml></Update>
<Update><ID>11</ID><Xml>$files</Xml></Update>
<Update><ID>12</ID><Xml>$files</Xml></Update>
</Updates></ExtendedUpdateInfo></SyncUpdatesResult>
"@
                    } else {
                        throw 'Unexpected extra sync request.'
                    }
                }
                'GetExtendedUpdateInfo2' {
                    $identity = $operation.updateIDs.UpdateIdentity
                    if ($identity.UpdateID -notmatch '^[234]{8}-[234]{4}-[234]{4}-[234]{4}-[234]{12}$' -or
                        $identity.RevisionNumber -ne '7' -or $identity.NamespaceURI -ne $ns) {
                        throw 'Update identity must be sent as namespaced child elements, not attributes.'
                    }
                    $digest = 'test-digest'
                    $url = 'https://tlu.dl.delivery.mp.microsoft.com/package'
                    if ($global:FederalAvdStoreResolverTest.Scenario -eq 'wrong-digest') {
                        $digest = 'TEST-DIGEST'
                    }
                    if ($global:FederalAvdStoreResolverTest.Scenario -eq 'bad-url') {
                        $url = 'https://microsoft.com.example.org/package'
                    }
                    @"
<GetExtendedUpdateInfo2Result><FileLocations>
<FileLocation><FileDigest>block-digest</FileDigest><Url>https://tlu.dl.delivery.mp.microsoft.com/blockmap</Url></FileLocation>
<FileLocation><FileDigest>$digest</FileDigest><Url>$url</Url></FileLocation>
</FileLocations></GetExtendedUpdateInfo2Result>
"@
                }
                default { throw "Unexpected SOAP operation: $($operation.LocalName)" }
            }
            @{ Content = "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope'><s:Body><Response xmlns='$ns'>$payload</Response></s:Body></s:Envelope>" }
        }
    }

    AfterAll {
        Remove-Variable -Name FederalAvdStoreResolverTest -Scope Global
    }

    It 'joins metadata across responses, filters architecture, and selects files by digest' {
        $links = @(Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 -Architecture x64)
        $links.Count | Should Be 2
        @($links | Where-Object Architecture -eq x64).Count | Should Be 1
        @($links | Where-Object Architecture -eq neutral).Count | Should Be 1
        @($links | Where-Object Architecture -eq x86).Count | Should Be 0
        $links[0].FileName | Should Be 'example.msix'
        $links[0].Size | Should Be 123
        $links[0].Url | Should Be 'https://tlu.dl.delivery.mp.microsoft.com/package'
        $links[0].IsEncrypted | Should Be $false
        $links[0].IsMainPackage | Should Be $true
        $links[0].PackageFamilyName | Should Be 'Example.App_abcdefghijklm'
        $global:FederalAvdStoreResolverTest.SyncCalls | Should Be 2
        $second = $global:FederalAvdStoreResolverTest.Requests[2].Envelope.Body.SyncUpdates
        $second.cookie.EncryptedData.InnerText | Should Be 'refreshed-cookie'
        $installed = @($second.parameters.InstalledNonLeafUpdateIDs.ChildNodes | ForEach-Object InnerText)
        ($installed -contains '10') | Should Be $true
        ($installed -contains '11') | Should Be $false
        @($second.parameters.OtherCachedUpdateIDs.int).Count | Should Be 3
    }

    It 'accepts a Store URL with query parameters and RP ring' {
        $links = @(Get-MicrosoftStorePackageUrl -Uri 'https://apps.microsoft.com/detail/9wzdncrfhvn5?hl=en-US' -Ring RP)
        $links[0].ProductId | Should Be '9WZDNCRFHVN5'
        $global:FederalAvdStoreResolverTest.Requests[1].Envelope.Body.SyncUpdates.parameters.ProductsParameters.DeviceAttributes |
            Should Match 'FlightRing=RP;'
    }

    It 'accepts JSON-string fulfillment metadata and deduplicates categories' {
        $global:FederalAvdStoreResolverTest.Scenario = 'string-fulfillment'
        @(Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5).Count | Should Be 3
        $global:FederalAvdStoreResolverTest.SyncCalls | Should Be 2
    }

    It 'rejects non-Store URLs before making requests' {
        $message = ''
        try {
            Get-MicrosoftStorePackageUrl -ProductId 'https://example.org/9WZDNCRFHVN5'
        } catch {
            $message = $_.Exception.Message
        }
        $message | Should Match 'Specify a 12-character Store product ID'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
    }

    It 'reports missing catalog delivery categories' {
        $global:FederalAvdStoreResolverTest.Scenario = 'no-category'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'no Store delivery category'
    }

    It 'reports missing delivery cookies' {
        $global:FederalAvdStoreResolverTest.Scenario = 'bad-cookie'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'did not return a cookie'
    }

    It 'reports SOAP faults' {
        $global:FederalAvdStoreResolverTest.Scenario = 'fault'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'Test SOAP fault'
    }

    It 'does not silently return partial lists when metadata is missing' {
        $global:FederalAvdStoreResolverTest.Scenario = 'missing-files'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'without an update identity or file list'
    }

    It 'bounds synchronization when the service keeps truncating' {
        $global:FederalAvdStoreResolverTest.Scenario = 'truncated'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'did not complete in 20 requests'
        $global:FederalAvdStoreResolverTest.SyncCalls | Should Be 20
    }

    It 'compares base64 digests case-sensitively' {
        $global:FederalAvdStoreResolverTest.Scenario = 'wrong-digest'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'no download location'
    }

    It 'rejects non-Microsoft download locations' {
        $global:FederalAvdStoreResolverTest.Scenario = 'bad-url'
        { Get-MicrosoftStorePackageUrl -ProductId 9WZDNCRFHVN5 } | Should Throw 'unexpected download URL'
    }
}
