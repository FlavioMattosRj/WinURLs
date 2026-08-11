#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:FqdnLabelPattern = '[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
$script:FqdnPattern = "^$($script:FqdnLabelPattern)(\.$($script:FqdnLabelPattern))*$"
$script:AbsoluteUriPrefixPattern = '^[A-Za-z][A-Za-z0-9+.\-]*://'

function Get-TargetType {
    <#
    .SYNOPSIS
        Classifies a raw target string as Fqdn, WildcardFqdn, Uri, UncPath, or
        the ambiguous fallback PublishedPattern. Never resolves DNS.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetRaw
    )

    $trimmed = $TargetRaw.Trim()

    if ($trimmed -match $script:AbsoluteUriPrefixPattern) {
        $parsedUri = $null
        if ([System.Uri]::TryCreate($trimmed, [System.UriKind]::Absolute, [ref] $parsedUri)) {
            return 'Uri'
        }
    }

    if ($trimmed.StartsWith('\\')) {
        return 'UncPath'
    }

    if ($trimmed -match '^\*\.(?<rest>.+)$') {
        if ($Matches['rest'] -match $script:FqdnPattern) {
            return 'WildcardFqdn'
        }
        return 'PublishedPattern'
    }

    if (($trimmed.IndexOf('*') -lt 0) -and ($trimmed -match $script:FqdnPattern)) {
        return 'Fqdn'
    }

    return 'PublishedPattern'
}

function ConvertFrom-PublishedProtocol {
    <#
    .SYNOPSIS
        Maps a raw published-protocol string (e.g. "TCP 443",
        "TLSv1.2/HTTPS/HTTP") to a scheme classification and an inferred port.
        TLS version markers such as TLSv1.2 are never treated as a scheme.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProtocolRaw
    )

    $scheme = 'Unknown'
    $inferredPort = $null
    $portBasis = $null

    if (-not [string]::IsNullOrWhiteSpace($ProtocolRaw)) {
        $tokens = @($ProtocolRaw -split '[\s/,;]+' | Where-Object { $_ -ne '' })

        $hasHttps = [bool]($tokens | Where-Object { $_ -ieq 'HTTPS' })
        $hasHttp = [bool]($tokens | Where-Object { $_ -ieq 'HTTP' })

        if ($hasHttps) {
            $scheme = 'Https'
            $inferredPort = 443
            $portBasis = 'InferredFromPublishedProtocol'
        }
        elseif ($hasHttp) {
            $scheme = 'Http'
            $inferredPort = 80
            $portBasis = 'InferredFromPublishedProtocol'
        }
    }

    [pscustomobject]@{
        protocolRaw  = $ProtocolRaw
        scheme       = $scheme
        inferredPort = $inferredPort
        portBasis    = $portBasis
    }
}

function Get-CanonicalTargetKey {
    <#
    .SYNOPSIS
        Builds the identity key used to consolidate normalized targets:
        target type, lowercased host, and path (when applicable).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Fqdn', 'WildcardFqdn', 'Uri', 'UncPath', 'PublishedPattern')]
        [string] $TargetType,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TargetHost,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Path
    )

    $normalizedHost = if ([string]::IsNullOrEmpty($TargetHost)) { '' } else { $TargetHost.ToLowerInvariant() }
    $normalizedPath = if ([string]::IsNullOrEmpty($Path)) { '' } else { $Path }

    '{0}|{1}|{2}' -f $TargetType, $normalizedHost, $normalizedPath
}

function ConvertTo-NormalizedNetworkTarget {
    <#
    .SYNOPSIS
        Converts a single raw endpoint (targetRaw + protocolRaw) into the
        canonical network-target contract, tagged with product/authority/layer
        provenance. Never resolves DNS.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetRaw,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProtocolRaw,

        [Parameter(Mandatory = $true)]
        [ValidateSet('WindowsUpdate', 'WinGet')]
        [string] $Product,

        [Parameter()]
        [ValidateSet('CoreService', 'Dependency', 'CatalogSource')]
        [string] $Layer
    )

    if ($Product -eq 'WinGet') {
        if ([string]::IsNullOrEmpty($Layer)) {
            $Layer = 'CatalogSource'
        }
        elseif ($Layer -ne 'CatalogSource') {
            throw "Layer '$Layer' is not valid for product 'WinGet'. Expected 'CatalogSource'."
        }
        $authority = 'LocalEffectiveConfiguration'
    }
    else {
        if ([string]::IsNullOrEmpty($Layer) -or $Layer -notin @('CoreService', 'Dependency')) {
            throw "Layer is required for product 'WindowsUpdate' and must be 'CoreService' or 'Dependency'."
        }
        $authority = 'MicrosoftDocumentation'
    }

    $trimmedTarget = $TargetRaw.Trim()
    $targetType = Get-TargetType -TargetRaw $trimmedTarget
    $protocolInfo = ConvertFrom-PublishedProtocol -ProtocolRaw $ProtocolRaw

    $targetHost = $null
    $path = $null
    $query = $null
    $scheme = $protocolInfo.scheme
    $port = $protocolInfo.inferredPort
    $portBasis = $protocolInfo.portBasis

    switch ($targetType) {
        'Uri' {
            $parsedUri = [System.Uri]::new($trimmedTarget)
            $targetHost = $parsedUri.Host.ToLowerInvariant()
            $path = $parsedUri.AbsolutePath
            $query = if ([string]::IsNullOrEmpty($parsedUri.Query)) { $null } else { $parsedUri.Query }

            $lowerScheme = $parsedUri.Scheme.ToLowerInvariant()
            $scheme = switch ($lowerScheme) {
                'https' { 'Https' }
                'http' { 'Http' }
                default { $lowerScheme.Substring(0, 1).ToUpperInvariant() + $lowerScheme.Substring(1) }
            }

            $port = $parsedUri.Port
            $portBasis = if ($parsedUri.IsDefaultPort) { 'ImpliedByUriScheme' } else { 'ExplicitInUri' }
        }
        'UncPath' {
            if ($trimmedTarget -match '^\\\\(?<server>[^\\]+)(?<rest>\\.*)?$') {
                $targetHost = $Matches['server'].ToLowerInvariant()
                $path = $Matches['rest']
            }
        }
        default {
            $targetHost = $trimmedTarget.ToLowerInvariant()
        }
    }

    $isWildcard = $trimmedTarget.IndexOf('*') -ge 0
    $hasAmbiguousWildcard = $isWildcard -and ($targetType -ne 'WildcardFqdn')

    $canonicalKey = Get-CanonicalTargetKey -TargetType $targetType -TargetHost $targetHost -Path $path

    $provenanceEntry = [pscustomobject]@{
        product     = $Product
        authority   = $authority
        layer       = $Layer
        targetRaw   = $TargetRaw
        protocolRaw = $ProtocolRaw
        scheme      = $scheme
        port        = $port
        portBasis   = $portBasis
    }

    $relationshipEntry = [pscustomobject]@{
        product   = $Product
        authority = $authority
        layer     = $Layer
    }

    [pscustomobject]@{
        targetRaw            = $TargetRaw
        targetType           = $targetType
        host                 = $targetHost
        path                 = $path
        query                = $query
        isWildcard           = $isWildcard
        hasAmbiguousWildcard = $hasAmbiguousWildcard
        scheme               = $scheme
        port                 = $port
        portBasis            = $portBasis
        product              = $Product
        authority            = $authority
        layer                = $Layer
        canonicalKey         = $canonicalKey
        targetRawValues      = @($TargetRaw)
        provenance           = @($provenanceEntry)
        relationships        = @($relationshipEntry)
    }
}

function Merge-NetworkTargets {
    <#
    .SYNOPSIS
        Consolidates normalized network targets by canonical key, unioning
        provenance, relationships, and distinct raw values. Output order is
        deterministic and independent of input order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowNull()]
        $NormalizedTarget
    )

    begin {
        $buffer = [System.Collections.Generic.List[pscustomobject]]::new()
    }

    process {
        foreach ($item in @($NormalizedTarget)) {
            if ($null -ne $item) {
                $buffer.Add($item)
            }
        }
    }

    end {
        $groupsByKey = @{}

        foreach ($item in $buffer) {
            $key = $item.canonicalKey
            if (-not $groupsByKey.ContainsKey($key)) {
                $groupsByKey[$key] = [System.Collections.Generic.List[pscustomobject]]::new()
            }
            $groupsByKey[$key].Add($item)
        }

        $mergedResults = foreach ($key in $groupsByKey.Keys) {
            $group = $groupsByKey[$key]
            $first = $group[0]

            $targetRawSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $targetRawValuesList = [System.Collections.Generic.List[string]]::new()
            foreach ($raw in ($group | ForEach-Object { $_.targetRawValues } | ForEach-Object { $_ })) {
                if ($targetRawSeen.Add($raw)) {
                    $targetRawValuesList.Add($raw)
                }
            }
            $targetRawValuesList.Sort([System.StringComparer]::Ordinal)
            $targetRawValues = @($targetRawValuesList)

            $provenanceSeen = [System.Collections.Generic.HashSet[string]]::new()
            $provenanceList = [System.Collections.Generic.List[pscustomobject]]::new()
            foreach ($entry in ($group | ForEach-Object { $_.provenance } | ForEach-Object { $_ })) {
                $entryKey = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $entry.product, $entry.authority, $entry.layer, $entry.targetRaw, $entry.protocolRaw, $entry.scheme, $entry.port, $entry.portBasis
                if ($provenanceSeen.Add($entryKey)) {
                    $provenanceList.Add($entry)
                }
            }

            $relationshipSeen = [System.Collections.Generic.HashSet[string]]::new()
            $relationshipList = [System.Collections.Generic.List[pscustomobject]]::new()
            foreach ($entry in ($group | ForEach-Object { $_.relationships } | ForEach-Object { $_ })) {
                $entryKey = '{0}|{1}|{2}' -f $entry.product, $entry.authority, $entry.layer
                if ($relationshipSeen.Add($entryKey)) {
                    $relationshipList.Add($entry)
                }
            }

            [pscustomobject]@{
                canonicalKey         = $key
                targetType           = $first.targetType
                host                 = $first.host
                path                 = $first.path
                query                = $first.query
                isWildcard           = $first.isWildcard
                hasAmbiguousWildcard = [bool]($group | Where-Object { $_.hasAmbiguousWildcard })
                targetRawValues      = @($targetRawValues)
                provenance           = @($provenanceList | Sort-Object -Property product, authority, layer, targetRaw)
                relationships        = @($relationshipList | Sort-Object -Property product, authority, layer)
            }
        }

        @($mergedResults | Sort-Object -Property canonicalKey)
    }
}

Export-ModuleMember -Function ConvertTo-NormalizedNetworkTarget, ConvertFrom-PublishedProtocol, Get-TargetType, Merge-NetworkTargets, Get-CanonicalTargetKey
