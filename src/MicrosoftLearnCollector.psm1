#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:DefaultLearnUri = 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints'
$script:DefaultAllowedHosts = @('learn.microsoft.com')
$script:DefaultUserAgent = 'WinURLs-OfficialDocumentCollector/1.0'
$script:MinimumContentLength = 256

function Get-ContentSha256 {
    <#
    .SYNOPSIS
        Computes the deterministic SHA-256 hash of a text content string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content,

        [Parameter()]
        [System.Text.Encoding] $Encoding = [System.Text.Encoding]::UTF8
    )

    $bytes = $Encoding.GetBytes($Content)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
}

function Test-OfficialDocumentUri {
    <#
    .SYNOPSIS
        Validates that a URI uses HTTPS and resolves to an allowed host.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [string[]] $AllowedHost
    )

    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref] $parsedUri)) {
        return $false
    }

    if ($parsedUri.Scheme -ne 'https') {
        return $false
    }

    foreach ($allowed in $AllowedHost) {
        if ($parsedUri.Host -ieq $allowed) {
            return $true
        }
    }

    return $false
}

function Get-ResponseHeaderValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        $Response,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if (-not $Response.Headers) {
        return $null
    }

    foreach ($key in $Response.Headers.Keys) {
        if ($key -ieq $Name) {
            $value = $Response.Headers[$key]
            if ($value -is [array]) {
                return ($value -join ', ')
            }
            return $value
        }
    }

    return $null
}

function Get-FinalUriFromResponse {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        $Response,

        [Parameter(Mandatory = $true)]
        [string] $FallbackUri
    )

    try {
        $requestUri = $Response.BaseResponse.RequestMessage.RequestUri
        if ($requestUri) {
            return $requestUri.AbsoluteUri
        }
    }
    catch {
        # Falls through to the fallback URI below.
    }

    return $FallbackUri
}

function Get-OfficialDocumentSnapshot {
    <#
    .SYNOPSIS
        Acquires a point-in-time snapshot of an official Microsoft Learn document,
        either over HTTPS or from a local HTML fixture, without parsing its content.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Http')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'Http')]
        [ValidateNotNullOrEmpty()]
        [string] $Uri = $script:DefaultLearnUri,

        [Parameter(ParameterSetName = 'File', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $InputHtmlPath,

        [Parameter(ParameterSetName = 'Http')]
        [ValidateRange(1, 3600)]
        [int] $TimeoutSec = 30,

        [Parameter(ParameterSetName = 'Http')]
        [string] $Proxy,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $AllowedHost = $script:DefaultAllowedHosts,

        [Parameter(ParameterSetName = 'Http')]
        [ValidateNotNullOrEmpty()]
        [string] $UserAgent = $script:DefaultUserAgent
    )

    $retrievedAtUtc = [DateTime]::UtcNow.ToString('o')

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not (Test-Path -LiteralPath $InputHtmlPath -PathType Leaf)) {
            throw "InputHtmlPath was not found: '$InputHtmlPath'."
        }

        $content = Get-Content -LiteralPath $InputHtmlPath -Raw -Encoding UTF8

        if ([string]::IsNullOrEmpty($content) -or $content.Length -lt $script:MinimumContentLength) {
            throw "Content read from '$InputHtmlPath' is empty or too small (length: $($content.Length))."
        }

        return [pscustomobject]@{
            requestedUri      = $InputHtmlPath
            finalUri          = $InputHtmlPath
            statusCode        = $null
            contentType       = 'text/html'
            retrievedAtUtc    = $retrievedAtUtc
            etag              = $null
            lastModified      = $null
            contentSha256     = Get-ContentSha256 -Content $content
            content           = $content
            acquisitionMethod = 'File'
        }
    }

    if (-not (Test-OfficialDocumentUri -Uri $Uri -AllowedHost $AllowedHost)) {
        throw "Requested URI is not authorized (host must be one of: $($AllowedHost -join ', ')): '$Uri'."
    }

    $invokeParams = @{
        Uri                = $Uri
        TimeoutSec         = $TimeoutSec
        UserAgent          = $UserAgent
        MaximumRedirection = 5
        ErrorAction        = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Proxy') -and $Proxy) {
        $invokeParams['Proxy'] = $Proxy
    }

    try {
        $response = Invoke-WebRequest @invokeParams
    }
    catch {
        throw "Failed to retrieve document from '$Uri': $($_.Exception.Message)"
    }

    $finalUriValue = Get-FinalUriFromResponse -Response $response -FallbackUri $Uri

    if (-not (Test-OfficialDocumentUri -Uri $finalUriValue -AllowedHost $AllowedHost)) {
        throw "Redirected URI is not authorized (host must be one of: $($AllowedHost -join ', ')): '$finalUriValue'."
    }

    $contentType = Get-ResponseHeaderValue -Response $response -Name 'Content-Type'
    if ([string]::IsNullOrWhiteSpace($contentType) -or ($contentType -notmatch '(?i)text/html')) {
        throw "Unexpected content type received from '$finalUriValue': '$contentType'."
    }

    $content = $response.Content
    if ([string]::IsNullOrEmpty($content) -or $content.Length -lt $script:MinimumContentLength) {
        throw "Retrieved content from '$finalUriValue' is empty or too small (length: $($content.Length))."
    }

    [pscustomobject]@{
        requestedUri      = $Uri
        finalUri          = $finalUriValue
        statusCode        = [int] $response.StatusCode
        contentType       = $contentType
        retrievedAtUtc    = $retrievedAtUtc
        etag              = Get-ResponseHeaderValue -Response $response -Name 'ETag'
        lastModified      = Get-ResponseHeaderValue -Response $response -Name 'Last-Modified'
        contentSha256     = Get-ContentSha256 -Content $content
        content           = $content
        acquisitionMethod = 'Http'
    }
}

Export-ModuleMember -Function Get-OfficialDocumentSnapshot, Get-ContentSha256, Test-OfficialDocumentUri
