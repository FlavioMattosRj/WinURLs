#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'EndpointNormalizer.psm1'
    Import-Module $script:ModulePath -Force
    $script:ModuleSource = Get-Content -LiteralPath $script:ModulePath -Raw
}

Describe 'Get-TargetType' {
    It 'classifies a plain FQDN' {
        Get-TargetType -TargetRaw 'adl.windows.com' | Should -Be 'Fqdn'
    }

    It 'classifies a wildcard FQDN' {
        Get-TargetType -TargetRaw '*.windowsupdate.com' | Should -Be 'WildcardFqdn'
    }

    It 'classifies an absolute URI' {
        Get-TargetType -TargetRaw 'https://cdn.winget.microsoft.com/cache' | Should -Be 'Uri'
    }

    It 'classifies a UNC path' {
        Get-TargetType -TargetRaw '\\fileserver\share\wingetsources' | Should -Be 'UncPath'
    }

    It 'classifies an ambiguous trailing-asterisk pattern as PublishedPattern' {
        Get-TargetType -TargetRaw 'login.live.com*' | Should -Be 'PublishedPattern'
    }
}

Describe 'ConvertFrom-PublishedProtocol' {
    It 'maps HTTPS to inferred port 443' {
        $result = ConvertFrom-PublishedProtocol -ProtocolRaw 'HTTPS'
        $result.scheme | Should -Be 'Https'
        $result.inferredPort | Should -Be 443
        $result.portBasis | Should -Be 'InferredFromPublishedProtocol'
    }

    It 'maps HTTP to inferred port 80' {
        $result = ConvertFrom-PublishedProtocol -ProtocolRaw 'HTTP'
        $result.scheme | Should -Be 'Http'
        $result.inferredPort | Should -Be 80
        $result.portBasis | Should -Be 'InferredFromPublishedProtocol'
    }

    It 'prefers HTTPS when TLSv1.2/HTTPS/HTTP are combined and never treats TLSv1.2 as a scheme' {
        $result = ConvertFrom-PublishedProtocol -ProtocolRaw 'TLSv1.2/HTTPS/HTTP'
        $result.scheme | Should -Be 'Https'
        $result.inferredPort | Should -Be 443
    }

    It 'does not treat a bare TLS version marker as a scheme' {
        $result = ConvertFrom-PublishedProtocol -ProtocolRaw 'TLSv1.2'
        $result.scheme | Should -Be 'Unknown'
        $result.inferredPort | Should -BeNullOrEmpty
        $result.portBasis | Should -BeNullOrEmpty
    }

    It 'handles an empty protocol without throwing' {
        { ConvertFrom-PublishedProtocol -ProtocolRaw '' } | Should -Not -Throw
        $result = ConvertFrom-PublishedProtocol -ProtocolRaw ''
        $result.scheme | Should -Be 'Unknown'
        $result.inferredPort | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-NormalizedNetworkTarget' {
    Context 'FQDN (test 1)' {
        It 'normalizes a plain FQDN for Windows Update' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'

            $result.targetRaw | Should -Be 'adl.windows.com'
            $result.targetType | Should -Be 'Fqdn'
            $result.host | Should -Be 'adl.windows.com'
            $result.product | Should -Be 'WindowsUpdate'
            $result.authority | Should -Be 'MicrosoftDocumentation'
            $result.layer | Should -Be 'CoreService'
        }
    }

    Context 'wildcard (test 2)' {
        It 'normalizes a wildcard FQDN and preserves the wildcard' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw '*.windowsupdate.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'

            $result.targetType | Should -Be 'WildcardFqdn'
            $result.host | Should -Be '*.windowsupdate.com'
            $result.isWildcard | Should -BeTrue
            $result.hasAmbiguousWildcard | Should -BeFalse
        }
    }

    Context 'URI with path (test 3)' {
        It 'preserves the path and query of a URI' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://cdn.winget.microsoft.com/cache/v1?channel=stable' -Product 'WinGet'

            $result.targetType | Should -Be 'Uri'
            $result.host | Should -Be 'cdn.winget.microsoft.com'
            $result.path | Should -Be '/cache/v1'
            $result.query | Should -Be '?channel=stable'
        }
    }

    Context 'URI with port (test 4)' {
        It 'preserves an explicit port present in the URI' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://example.com:8443/path' -Product 'WinGet'

            $result.port | Should -Be 8443
            $result.portBasis | Should -Be 'ExplicitInUri'
        }

        It 'infers the default port when the URI has none explicit' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://example.com/path' -Product 'WinGet'

            $result.port | Should -Be 443
            $result.portBasis | Should -Be 'ImpliedByUriScheme'
        }
    }

    Context 'UNC (test 5)' {
        It 'normalizes a UNC path source for WinGet' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw '\\fileserver\share\wingetsources' -Product 'WinGet'

            $result.targetType | Should -Be 'UncPath'
            $result.host | Should -Be 'fileserver'
            $result.path | Should -Be '\share\wingetsources'
            $result.product | Should -Be 'WinGet'
            $result.authority | Should -Be 'LocalEffectiveConfiguration'
            $result.layer | Should -Be 'CatalogSource'
        }
    }

    Context 'TLSv1.2/HTTPS/HTTP (test 6)' {
        It 'infers HTTPS/443 from a combined protocol string on a non-URI target' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'tsfe.trafficshaping.dsp.mp.microsoft.com' -ProtocolRaw 'TLSv1.2/HTTPS/HTTP' -Product 'WindowsUpdate' -Layer 'CoreService'

            $result.scheme | Should -Be 'Https'
            $result.port | Should -Be 443
            $result.portBasis | Should -Be 'InferredFromPublishedProtocol'
        }
    }

    Context 'empty protocol (test 7)' {
        It 'normalizes without a protocol and without throwing' {
            { ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw '' -Product 'WindowsUpdate' -Layer 'CoreService' } | Should -Not -Throw

            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw '' -Product 'WindowsUpdate' -Layer 'CoreService'
            $result.scheme | Should -Be 'Unknown'
            $result.port | Should -BeNullOrEmpty
        }
    }

    Context 'login.live.com* pattern (test 8)' {
        It 'preserves the trailing asterisk and flags ambiguity instead of stripping it' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'login.live.com*' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'Dependency'

            $result.targetRaw | Should -Be 'login.live.com*'
            $result.targetType | Should -Be 'PublishedPattern'
            $result.host | Should -Be 'login.live.com*'
            $result.isWildcard | Should -BeTrue
            $result.hasAmbiguousWildcard | Should -BeTrue
        }
    }

    Context 'uppercase host (test 9)' {
        It 'lowercases the host while preserving targetRaw casing' {
            $result = ConvertTo-NormalizedNetworkTarget -TargetRaw 'ADL.WINDOWS.COM' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'

            $result.targetRaw | Should -Be 'ADL.WINDOWS.COM'
            $result.host | Should -Be 'adl.windows.com'
        }
    }
}

Describe 'Merge-NetworkTargets' {
    Context 'duplicate with two provenances (test 10)' {
        It 'merges the same target seen from two different provenances, unioning provenance and relationships' {
            $a = ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'
            $b = ConvertTo-NormalizedNetworkTarget -TargetRaw 'ADL.WINDOWS.COM' -ProtocolRaw 'HTTPS' -Product 'WinGet'

            $merged = @(Merge-NetworkTargets -NormalizedTarget @($a, $b))

            $merged.Count | Should -Be 1
            $merged[0].targetRawValues.Count | Should -Be 2
            $merged[0].targetRawValues | Should -Contain 'adl.windows.com'
            $merged[0].targetRawValues | Should -Contain 'ADL.WINDOWS.COM'
            $merged[0].provenance.Count | Should -Be 2
            $merged[0].relationships.Count | Should -Be 2
            ($merged[0].relationships | Select-Object -ExpandProperty product) | Should -Contain 'WindowsUpdate'
            ($merged[0].relationships | Select-Object -ExpandProperty product) | Should -Contain 'WinGet'
        }
    }

    Context 'two different paths must not be merged (test 11)' {
        It 'keeps two URIs with the same host but different paths as separate entries' {
            $a = ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://cdn.winget.microsoft.com/cache' -Product 'WinGet'
            $b = ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://cdn.winget.microsoft.com/fonts' -Product 'WinGet'

            $merged = @(Merge-NetworkTargets -NormalizedTarget @($a, $b))

            $merged.Count | Should -Be 2
            ($merged | Select-Object -ExpandProperty path) | Should -Be @('/cache', '/fonts')
        }
    }

    Context 'input order independence (test 12)' {
        It 'produces the same merged result regardless of input order' {
            $a = ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'
            $b = ConvertTo-NormalizedNetworkTarget -TargetRaw '*.windowsupdate.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'
            $c = ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://cdn.winget.microsoft.com/cache' -Product 'WinGet'

            $mergedForward = @(Merge-NetworkTargets -NormalizedTarget @($a, $b, $c))
            $mergedReversed = @(Merge-NetworkTargets -NormalizedTarget @($c, $b, $a))

            $forwardKeys = $mergedForward | Select-Object -ExpandProperty canonicalKey
            $reversedKeys = $mergedReversed | Select-Object -ExpandProperty canonicalKey

            ($forwardKeys -join '|') | Should -Be ($reversedKeys -join '|')
        }
    }
}

Describe 'No DNS resolution is ever performed (test 13)' {
    BeforeAll {
        Mock -CommandName Resolve-DnsName -MockWith { throw 'DNS resolution must never be called by EndpointNormalizer.' }
    }

    It 'does not reference DNS resolution APIs in the module source' {
        $script:ModuleSource | Should -Not -Match 'Resolve-DnsName'
        $script:ModuleSource | Should -Not -Match '\[System\.Net\.Dns\]'
        $script:ModuleSource | Should -Not -Match 'GetHostEntry|GetHostAddresses'
    }

    It 'never invokes DNS resolution while normalizing and merging a full batch of targets' {
        $targets = @(
            ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'
            ConvertTo-NormalizedNetworkTarget -TargetRaw '*.windowsupdate.com' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'CoreService'
            ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://cdn.winget.microsoft.com/cache' -Product 'WinGet'
            ConvertTo-NormalizedNetworkTarget -TargetRaw '\\fileserver\share\wingetsources' -Product 'WinGet'
            ConvertTo-NormalizedNetworkTarget -TargetRaw 'login.live.com*' -ProtocolRaw 'HTTPS' -Product 'WindowsUpdate' -Layer 'Dependency'
        )

        { Merge-NetworkTargets -NormalizedTarget $targets } | Should -Not -Throw
        Should -Invoke -CommandName Resolve-DnsName -Times 0
    }
}
