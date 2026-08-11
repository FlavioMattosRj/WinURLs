#Requires -Version 7.0

<#
.SYNOPSIS
    Discovers, normalizes, and exports the network endpoints required for
    Windows Update and WinGet, from official Microsoft documentation and the
    local WinGet configuration.

.DESCRIPTION
    Get-UpdateEndpointMap.ps1 orchestrates the WinURLs pipeline end to end:
    it acquires the official Microsoft Learn "Manage connection endpoints for
    Windows 11 Enterprise" document (or reads it from a local HTML file),
    parses the Windows Update endpoint table, collects the WinGet sources
    configured on this machine via read-only winget commands, normalizes both
    into the canonical network-target contract, consolidates duplicates
    across the two collectors, and exports the result as JSON, CSV, or
    Markdown.

    A failure in one collector never discards valid data already produced by
    the other. The script never performs mutating WinGet operations and never
    tests network connectivity to the discovered endpoints; it only reads
    official documentation and local configuration.

.PARAMETER WindowsEndpointDocumentUri
    The Microsoft Learn URL to fetch for the Windows Update endpoint table.
    Defaults to the official "Manage connection endpoints for Windows 11
    Enterprise" documentation page. Ignored when -InputHtmlPath is supplied.

.PARAMETER WindowsUpdateSecurityDocumentUri
    Reserved for a future, separate Windows Update security document. Not yet
    consumed by the current analysis pipeline (no parser exists for it); when
    supplied, it is recorded in the collector status message for
    traceability only.

.PARAMETER InputHtmlPath
    Path to a local HTML file to use instead of fetching
    WindowsEndpointDocumentUri over HTTPS. Useful for offline runs and tests.

.PARAMETER IncludeDependencies
    Whether to also collect the Windows Update dependency areas (Device
    authentication, Microsoft Account). Defaults to $true.

.PARAMETER IncludeWindowsUpdate
    Whether to collect Windows Update endpoints at all. Defaults to $true.

.PARAMETER IncludeWinGet
    Whether to collect WinGet configured sources at all. Defaults to $true.

.PARAMETER Format
    Output format for the exported report: Json, Csv, or Markdown. Defaults
    to Json.

.PARAMETER OutputPath
    Path of the file to write. Defaults to '.\endpoint-map.<ext>' in the
    current directory, with the extension matching -Format.

.PARAMETER EvidenceDirectory
    Directory to write collection evidence to when -IncludeEvidence is set.
    Defaults to an 'evidence' folder next to -OutputPath.

.PARAMETER IncludeEvidence
    Writes masked collection evidence (raw command output, document
    metadata) to -EvidenceDirectory. Disabled by default.

.PARAMETER Proxy
    Proxy URI forwarded to the Microsoft Learn HTTP collector only. WinGet
    manages its own proxy configuration independently and is not affected by
    this parameter.

.PARAMETER TimeoutSec
    Timeout, in seconds, applied to both the HTTP document fetch and each
    WinGet command invocation. Defaults to 30.

.PARAMETER PassThru
    Also emits the resulting endpoint-map object to the pipeline, in addition
    to writing the export file.

.EXAMPLE
    .\Get-UpdateEndpointMap.ps1

    Collects Windows Update and WinGet endpoints using the default official
    document and the local WinGet configuration, and writes
    '.\endpoint-map.json'.

.EXAMPLE
    .\Get-UpdateEndpointMap.ps1 -Format Markdown -OutputPath C:\Reports\endpoints.md

    Writes a human-readable Markdown report to a specific path.

.EXAMPLE
    .\Get-UpdateEndpointMap.ps1 -InputHtmlPath .\tests\fixtures\windows-endpoints-synthetic.html -IncludeWinGet $false -PassThru

    Runs offline against a local HTML fixture, skips WinGet collection
    entirely, and also returns the endpoint-map object on the pipeline.

.EXAMPLE
    .\Get-UpdateEndpointMap.ps1 -Proxy 'http://proxy.contoso.com:8080' -TimeoutSec 60 -Format Csv -OutputPath C:\Reports\endpoints.csv

    Fetches the Microsoft Learn document through a corporate proxy with an
    extended timeout, and exports the result as CSV.

.EXAMPLE
    .\Get-UpdateEndpointMap.ps1 -IncludeDependencies $false -IncludeEvidence -EvidenceDirectory C:\Reports\evidence

    Collects only the core Windows Update endpoints (no dependency areas)
    and additionally writes masked collection evidence for audit purposes.

.OUTPUTS
    System.Management.Automation.PSCustomObject (only when -PassThru is
    specified) representing the canonical endpoint map that was exported.

.NOTES
    Exit codes: 0 = full success, 2 = partial success (one requested
    collector failed while another produced valid data), 10 = fatal failure
    (no valid collector data was produced, including when both collectors
    are disabled).
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WindowsEndpointDocumentUri = 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints',

    [Parameter()]
    [string] $WindowsUpdateSecurityDocumentUri,

    [Parameter()]
    [string] $InputHtmlPath,

    [Parameter()]
    [bool] $IncludeDependencies = $true,

    [Parameter()]
    [bool] $IncludeWindowsUpdate = $true,

    [Parameter()]
    [bool] $IncludeWinGet = $true,

    [Parameter()]
    [ValidateSet('Json', 'Csv', 'Markdown')]
    [string] $Format = 'Json',

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [string] $EvidenceDirectory,

    [Parameter()]
    [switch] $IncludeEvidence,

    [Parameter()]
    [string] $Proxy,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int] $TimeoutSec = 30,

    [Parameter()]
    [switch] $PassThru
)

Set-StrictMode -Version Latest

# Step 1: validate PowerShell 7. #Requires above already enforces this at
# parse time; this explicit check provides a controlled exit code (10) in
# case the directive is ever bypassed.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "Get-UpdateEndpointMap.ps1 requires PowerShell 7 or later. Current version: $($PSVersionTable.PSVersion)."
    exit 10
}

Import-Module (Join-Path $PSScriptRoot 'src/MicrosoftLearnCollector.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/WindowsEndpointParser.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/WinGetSourceCollector.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/EndpointNormalizer.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'src/EndpointExporter.psm1') -ErrorAction Stop

function Get-PropertyValueSafely {
    param(
        [Parameter()]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Write-CollectorError {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Code,

        [Parameter(Mandatory = $true)]
        [string] $CollectorName,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $structured = [pscustomobject]@{
        code      = $Code
        message   = $ErrorRecord.Exception.Message
        collector = $CollectorName
        exception = $ErrorRecord.Exception
    }

    $newErrorRecord = [System.Management.Automation.ErrorRecord]::new(
        $ErrorRecord.Exception,
        $Code,
        [System.Management.Automation.ErrorCategory]::NotSpecified,
        $structured
    )

    Write-Error -ErrorRecord $newErrorRecord

    $structured
}

# Step 2: establish the canonical document scaffold. Populated incrementally
# as each collector runs, so a well-formed (possibly partial) report can
# always be produced even when one or both collectors fail.
$generatedAtUtc = [DateTime]::UtcNow.ToString('o')
$collectors = [System.Collections.Generic.List[pscustomobject]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$limitations = [System.Collections.Generic.List[string]]::new()
$windowsUpdateNormalized = [System.Collections.Generic.List[pscustomobject]]::new()
$winGetNormalized = [System.Collections.Generic.List[pscustomobject]]::new()
$windowsUpdateAreaCount = 0
$windowsUpdateSucceeded = $false
$winGetSucceeded = $false
$winGetEvidence = $null

if (-not [string]::IsNullOrWhiteSpace($WindowsUpdateSecurityDocumentUri)) {
    Write-Verbose "WindowsUpdateSecurityDocumentUri was supplied ('$WindowsUpdateSecurityDocumentUri') but is not yet consumed by this pipeline; it is recorded for traceability only."
    $limitations.Add("WindowsUpdateSecurityDocumentUri ('$WindowsUpdateSecurityDocumentUri') was supplied but is not yet analyzed by this version of the pipeline.")
}

# Steps 3-5: acquire, parse, and normalize Windows Update endpoints.
if ($IncludeWindowsUpdate) {
    Write-Verbose 'Collecting Windows Update endpoints from Microsoft Learn documentation.'
    try {
        $snapshotParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($InputHtmlPath)) {
            $snapshotParams['InputHtmlPath'] = $InputHtmlPath
        }
        else {
            $snapshotParams['Uri'] = $WindowsEndpointDocumentUri
            $snapshotParams['TimeoutSec'] = $TimeoutSec
            if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
                $snapshotParams['Proxy'] = $Proxy
            }
        }

        $snapshot = Get-OfficialDocumentSnapshot @snapshotParams

        Write-Verbose "Parsing Windows Update endpoint table (acquisitionMethod=$($snapshot.acquisitionMethod))."
        $coreEntries = Get-WindowsEndpointArea -Html $snapshot.content -AreaName 'Windows Update'
        $windowsUpdateAreaCount++
        foreach ($entry in $coreEntries) {
            $windowsUpdateNormalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $entry.targetRaw -ProtocolRaw $entry.protocolRaw -Product WindowsUpdate -Layer CoreService))
        }

        if ($IncludeDependencies) {
            foreach ($dependencyAreaName in @('Device authentication', 'Microsoft Account')) {
                try {
                    $dependencyEntries = Get-WindowsEndpointArea -Html $snapshot.content -AreaName $dependencyAreaName
                    $windowsUpdateAreaCount++
                    foreach ($entry in $dependencyEntries) {
                        $windowsUpdateNormalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $entry.targetRaw -ProtocolRaw $entry.protocolRaw -Product WindowsUpdate -Layer Dependency))
                    }
                }
                catch {
                    $warnings.Add("Dependency area '$dependencyAreaName' could not be parsed and was skipped: $($_.Exception.Message)")
                    Write-Warning "Dependency area '$dependencyAreaName' could not be parsed and was skipped: $($_.Exception.Message)"
                }
            }
        }
        else {
            $limitations.Add('Dependency areas (Device authentication, Microsoft Account) were excluded because IncludeDependencies was set to false.')
        }

        $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Success'; code = $null; message = $null })
        $windowsUpdateSucceeded = $true
    }
    catch {
        $structured = Write-CollectorError -Code 'WindowsUpdateCollectionFailed' -CollectorName 'MicrosoftLearnCollector' -ErrorRecord $_
        $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Failed'; code = $structured.code; message = $structured.message })
        $warnings.Add("MicrosoftLearnCollector failed and Windows Update data is excluded from this report: $($structured.message)")
        Write-Warning "Windows Update collection failed: $($structured.message)"
    }
}
else {
    $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Skipped'; code = $null; message = 'IncludeWindowsUpdate was set to false.' })
}

# Steps 6-7: collect and normalize WinGet configured sources.
if ($IncludeWinGet) {
    Write-Verbose 'Collecting WinGet configured sources.'
    try {
        $wingetPath = Find-WinGetExecutable
        $wingetResult = Get-WinGetConfiguredSources -WinGetPath $wingetPath -TimeoutSec $TimeoutSec

        foreach ($source in $wingetResult.sources) {
            $winGetNormalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $source.arg -Product WinGet))
        }

        $winGetEvidence = Get-PropertyValueSafely -InputObject $wingetResult -Name 'evidence'

        $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Success'; code = $null; message = $null })
        $winGetSucceeded = $true
    }
    catch {
        $structured = Write-CollectorError -Code 'WinGetCollectionFailed' -CollectorName 'WinGetSourceCollector' -ErrorRecord $_
        $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Failed'; code = $structured.code; message = $structured.message })
        $warnings.Add("WinGetSourceCollector failed and WinGet data is excluded from this report: $($structured.message)")
        Write-Warning "WinGet collection failed: $($structured.message)"
    }
}
else {
    $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Skipped'; code = $null; message = 'IncludeWinGet was set to false.' })
}

# Step 8: consolidate both collectors' normalized targets by canonical key.
Write-Verbose 'Consolidating normalized targets by canonical key.'
$allNormalized = @($windowsUpdateNormalized) + @($winGetNormalized)
$merged = @(Merge-NetworkTargets -NormalizedTarget $allNormalized)
$windowsUpdateTargets = @($merged | Where-Object { @($_.relationships | Where-Object { $_.product -eq 'WindowsUpdate' }).Count -gt 0 })
$winGetTargets = @($merged | Where-Object { @($_.relationships | Where-Object { $_.product -eq 'WinGet' }).Count -gt 0 })

# Step 9: determine coverage/status and the overall exit code.
$attemptedCount = 0
$succeededCount = 0
if ($IncludeWindowsUpdate) { $attemptedCount++; if ($windowsUpdateSucceeded) { $succeededCount++ } }
if ($IncludeWinGet) { $attemptedCount++; if ($winGetSucceeded) { $succeededCount++ } }

if ($attemptedCount -eq 0) {
    $warnings.Add('No collector was enabled (IncludeWindowsUpdate and IncludeWinGet are both false); no data was collected.')
    $exitCode = 10
}
elseif ($succeededCount -eq 0) {
    $exitCode = 10
}
elseif ($succeededCount -lt $attemptedCount) {
    $exitCode = 2
}
else {
    $exitCode = 0
}

$endpointMap = [pscustomobject]@{
    schemaVersion  = '1.0'
    generatedAtUtc = $generatedAtUtc
    coverage       = [pscustomobject]@{
        windowsUpdate = [pscustomobject]@{ included = $windowsUpdateSucceeded; areaCount = $windowsUpdateAreaCount; targetCount = $windowsUpdateTargets.Count }
        winget        = [pscustomobject]@{ included = $winGetSucceeded; targetCount = $winGetTargets.Count }
    }
    collectors     = @($collectors)
    windowsUpdate  = [pscustomobject]@{ targets = $windowsUpdateTargets }
    winget         = [pscustomobject]@{ targets = $winGetTargets }
    warnings       = @($warnings)
    limitations    = @($limitations)
}

# Step 10: export.
$extensionByFormat = @{ Json = 'json'; Csv = 'csv'; Markdown = 'md' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Get-Location).ProviderPath "endpoint-map.$($extensionByFormat[$Format])"
}

try {
    Write-Verbose "Exporting endpoint map as $Format to '$OutputPath'."
    switch ($Format) {
        'Json' { Export-EndpointMapJson -EndpointMap $endpointMap -Path $OutputPath }
        'Csv' { Export-EndpointMapCsv -EndpointMap $endpointMap -Path $OutputPath }
        'Markdown' { Export-EndpointMapMarkdown -EndpointMap $endpointMap -Path $OutputPath }
    }

    if ($IncludeEvidence) {
        if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
            $EvidenceDirectory = Join-Path (Split-Path -Path $OutputPath -Parent) 'evidence'
        }
        if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
        }

        $evidence = [pscustomobject]@{
            generatedAtUtc = $generatedAtUtc
            windowsUpdate  = if ($windowsUpdateSucceeded) {
                [pscustomobject]@{
                    requestedUri      = $snapshot.requestedUri
                    finalUri          = $snapshot.finalUri
                    statusCode        = $snapshot.statusCode
                    contentType       = $snapshot.contentType
                    retrievedAtUtc    = $snapshot.retrievedAtUtc
                    etag              = $snapshot.etag
                    lastModified      = $snapshot.lastModified
                    contentSha256     = $snapshot.contentSha256
                    acquisitionMethod = $snapshot.acquisitionMethod
                }
            } else { $null }
            winget         = $winGetEvidence
        }

        $evidencePath = Join-Path $EvidenceDirectory 'evidence.json'
        Write-AtomicUtf8File -Path $evidencePath -Content (ConvertTo-Json -InputObject $evidence -Depth 12)
        Write-Verbose "Evidence written to '$evidencePath'."
    }
}
catch {
    $structured = Write-CollectorError -Code 'EndpointMapExportFailed' -CollectorName 'EndpointExporter' -ErrorRecord $_
    Write-Warning "Export failed: $($structured.message)"
    exit 10
}

# Step 11: return the object with -PassThru.
if ($PassThru) {
    Write-Output $endpointMap
}

# Step 12: set the exit code.
Write-Verbose "Get-UpdateEndpointMap.ps1 finished with exit code $exitCode."
exit $exitCode
