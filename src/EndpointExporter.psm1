#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:JsonExportDepth = 12
$script:CsvColumnOrder = @('canonicalKey', 'targetType', 'targetRaw', 'targetNormalized', 'host', 'path', 'isWildcard', 'hasAmbiguousWildcard', 'product', 'relationships', 'sourceName', 'sourceType')

$script:WinGetSourceDisclaimer = 'As fontes WinGet listadas neste documento representam a configuracao de repositorios (sources) efetiva desta maquina, e nao representam necessariamente as URLs de instaladores dos pacotes individuais.'
$script:NoConnectivityTestDisclaimer = 'Nenhum dos endpoints listados neste documento foi testado por conexao real; esta e uma coleta documental/de configuracao, nao um teste de conectividade.'

$script:DefaultAtomicFileWriter = {
    param([string] $TempPath, [string] $Content)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($TempPath, $Content, $utf8NoBom)
}

function Get-OptionalPropertyValue {
    [CmdletBinding()]
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

function Test-EndpointMapContract {
    <#
    .SYNOPSIS
        Validates an object against the canonical EndpointMap contract used by
        all exporters. Returns an array of violation messages (empty = valid).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $EndpointMap
    )

    $violations = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $EndpointMap) {
        $violations.Add('EndpointMap is null.')
        return $violations.ToArray()
    }

    foreach ($requiredProperty in @('schemaVersion', 'generatedAtUtc', 'coverage', 'collectors', 'windowsUpdate', 'winget', 'warnings', 'limitations')) {
        if ($null -eq $EndpointMap.PSObject.Properties[$requiredProperty]) {
            $violations.Add("Missing required property '$requiredProperty'.")
        }
    }

    if ($violations.Count -gt 0) {
        return $violations.ToArray()
    }

    foreach ($section in @('windowsUpdate', 'winget')) {
        $sectionValue = $EndpointMap.$section
        if ($null -eq $sectionValue -or $null -eq $sectionValue.PSObject.Properties['targets']) {
            $violations.Add("Missing required property '$section.targets'.")
        }
        elseif ($sectionValue.targets -isnot [array]) {
            $violations.Add("'$section.targets' must be an array.")
        }
    }

    foreach ($arrayProperty in @('collectors', 'warnings', 'limitations')) {
        if ($EndpointMap.$arrayProperty -isnot [array]) {
            $violations.Add("'$arrayProperty' must be an array.")
        }
    }

    if ($violations.Count -gt 0) {
        return $violations.ToArray()
    }

    $allTargets = @($EndpointMap.windowsUpdate.targets) + @($EndpointMap.winget.targets)
    foreach ($target in $allTargets) {
        foreach ($requiredTargetProperty in @('canonicalKey', 'targetType', 'targetRawValues', 'provenance', 'relationships')) {
            if ($null -eq $target.PSObject.Properties[$requiredTargetProperty]) {
                $key = Get-OptionalPropertyValue -InputObject $target -Name 'canonicalKey'
                $violations.Add("Target '$key' is missing required property '$requiredTargetProperty'.")
            }
        }
    }

    $violations.ToArray()
}

function Write-AtomicUtf8File {
    <#
    .SYNOPSIS
        Writes content to a temp file in the destination's own directory and
        atomically renames it over the destination, so a failed or partial
        write never corrupts a pre-existing file. The temp file is always
        removed, whether the write succeeds or fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content,

        [Parameter()]
        [scriptblock] $Writer = $script:DefaultAtomicFileWriter
    )

    $resolvedDirectory = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrEmpty($resolvedDirectory)) {
        $resolvedDirectory = (Get-Location).ProviderPath
    }

    if (-not (Test-Path -LiteralPath $resolvedDirectory -PathType Container)) {
        throw "Write-AtomicUtf8File: destination directory does not exist: '$resolvedDirectory'."
    }

    $tempPath = Join-Path -Path $resolvedDirectory -ChildPath ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [System.Guid]::NewGuid().ToString('N') + '.tmp')

    try {
        & $Writer $tempPath $Content
        [System.IO.File]::Move($tempPath, $Path, $true)
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Export-EndpointMapJson {
    <#
    .SYNOPSIS
        Writes the EndpointMap as canonical, UTF-8, atomically-written JSON,
        after validating it against the contract.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $EndpointMap,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [scriptblock] $Writer
    )

    $violations = @(Test-EndpointMapContract -EndpointMap $EndpointMap)
    if ($violations.Count -gt 0) {
        throw "EndpointMapContractInvalid: the endpoint map failed contract validation:`n - $($violations -join "`n - ")"
    }

    $json = ConvertTo-Json -InputObject $EndpointMap -Depth $script:JsonExportDepth

    $writeParams = @{ Path = $Path; Content = $json }
    if ($PSBoundParameters.ContainsKey('Writer')) {
        $writeParams['Writer'] = $Writer
    }

    Write-AtomicUtf8File @writeParams
}

function ConvertTo-EndpointMapCsvRow {
    <#
    .SYNOPSIS
        Flattens one canonical (merged) network target into a single CSV row,
        joining array-valued fields with semicolons.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        $Target
    )

    process {
        $targetRawJoined = (@($Target.targetRawValues) -join ';')

        $primaryScheme = Get-OptionalPropertyValue -InputObject (@($Target.provenance) | Select-Object -First 1) -Name 'scheme'

        $targetNormalized = switch ($Target.targetType) {
            'Uri' {
                $schemePrefix = if ($primaryScheme -and $primaryScheme -ne 'Unknown') { $primaryScheme.ToLowerInvariant() } else { 'https' }
                '{0}://{1}{2}{3}' -f $schemePrefix, $Target.host, [string] $Target.path, [string] $Target.query
            }
            'UncPath' { '\\{0}{1}' -f $Target.host, [string] $Target.path }
            default { [string] $Target.host }
        }

        $products = @($Target.relationships | Select-Object -ExpandProperty product -Unique)
        $relationshipsJoined = (@($Target.relationships | ForEach-Object { "$($_.product)/$($_.layer)" }) -join ';')

        $sourceNames = @($Target.provenance | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'sourceName' } | Where-Object { -not [string]::IsNullOrEmpty($_) }) | Sort-Object -Unique
        $sourceTypes = @($Target.provenance | ForEach-Object { Get-OptionalPropertyValue -InputObject $_ -Name 'sourceType' } | Where-Object { -not [string]::IsNullOrEmpty($_) }) | Sort-Object -Unique

        [pscustomobject]@{
            canonicalKey         = $Target.canonicalKey
            targetType           = $Target.targetType
            targetRaw            = $targetRawJoined
            targetNormalized     = $targetNormalized
            host                 = [string] $Target.host
            path                 = [string] $Target.path
            isWildcard           = $Target.isWildcard
            hasAmbiguousWildcard = $Target.hasAmbiguousWildcard
            product              = ($products -join ';')
            relationships        = $relationshipsJoined
            sourceName           = ($sourceNames -join ';')
            sourceType           = ($sourceTypes -join ';')
        }
    }
}

function Export-EndpointMapCsv {
    <#
    .SYNOPSIS
        Writes one CSV row per canonical network target (Windows Update and
        WinGet combined), atomically, as UTF-8.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $EndpointMap,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [scriptblock] $Writer
    )

    $violations = @(Test-EndpointMapContract -EndpointMap $EndpointMap)
    if ($violations.Count -gt 0) {
        throw "EndpointMapContractInvalid: the endpoint map failed contract validation:`n - $($violations -join "`n - ")"
    }

    $allTargets = @($EndpointMap.windowsUpdate.targets) + @($EndpointMap.winget.targets)
    $rows = @($allTargets | ConvertTo-EndpointMapCsvRow)

    $csvLines = if ($rows.Count -eq 0) {
        , ($script:CsvColumnOrder -join ',')
    }
    else {
        @($rows | Select-Object -Property $script:CsvColumnOrder | ConvertTo-Csv -NoTypeInformation)
    }

    $csvContent = ($csvLines -join "`r`n") + "`r`n"

    $writeParams = @{ Path = $Path; Content = $csvContent }
    if ($PSBoundParameters.ContainsKey('Writer')) {
        $writeParams['Writer'] = $Writer
    }

    Write-AtomicUtf8File @writeParams
}

function ConvertTo-MarkdownTableCell {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    ($Text -replace '\|', '\|') -replace '\r?\n', ' '
}

function Add-EndpointMarkdownTable {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        $Lines,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array] $Targets,

        [Parameter(Mandatory = $true)]
        [string] $EmptyMessage
    )

    if (@($Targets).Count -eq 0) {
        $Lines.Add($EmptyMessage)
        return
    }

    $Lines.Add('| Alvo | Tipo | Wildcard Ambiguo | TargetRaw |')
    $Lines.Add('|---|---|---|---|')

    foreach ($target in ($Targets | Sort-Object -Property canonicalKey)) {
        $displayHost = if ($target.host) { $target.host } else { $target.canonicalKey }
        $wildcardFlag = if ($target.hasAmbiguousWildcard) { 'Sim' } else { 'Nao' }
        $rawJoined = (@($target.targetRawValues) -join '; ')
        $Lines.Add( ('| {0} | {1} | {2} | {3} |' -f (ConvertTo-MarkdownTableCell -Text $displayHost), (ConvertTo-MarkdownTableCell -Text $target.targetType), $wildcardFlag, (ConvertTo-MarkdownTableCell -Text $rawJoined)) )
    }
}

function Get-EndpointMapMarkdownContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        $EndpointMap
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('# Mapa de Endpoints - Windows Update e WinGet')
    $lines.Add('')
    $lines.Add("Gerado em (UTC): $($EndpointMap.generatedAtUtc)")
    $lines.Add('')

    $lines.Add('## Cobertura')
    $lines.Add('')
    $wuCoverage = $EndpointMap.coverage.windowsUpdate
    $wgCoverage = $EndpointMap.coverage.winget
    $lines.Add("- Windows Update incluido: $([bool] $wuCoverage.included) (areas: $($wuCoverage.areaCount), alvos: $($wuCoverage.targetCount))")
    $lines.Add("- WinGet incluido: $([bool] $wgCoverage.included) (alvos: $($wgCoverage.targetCount))")
    $lines.Add('')

    $lines.Add('## Status dos Coletores')
    $lines.Add('')
    $lines.Add('| Coletor | Status | Mensagem |')
    $lines.Add('|---|---|---|')
    foreach ($collector in @($EndpointMap.collectors)) {
        $message = Get-OptionalPropertyValue -InputObject $collector -Name 'message'
        $lines.Add( ('| {0} | {1} | {2} |' -f (ConvertTo-MarkdownTableCell -Text $collector.name), (ConvertTo-MarkdownTableCell -Text $collector.status), (ConvertTo-MarkdownTableCell -Text $message)) )
    }
    $lines.Add('')

    $lines.Add('## Windows Update')
    $lines.Add('')
    $coreTargets = @($EndpointMap.windowsUpdate.targets | Where-Object { @($_.relationships | Where-Object { $_.layer -eq 'CoreService' }).Count -gt 0 })
    Add-EndpointMarkdownTable -Lines $lines -Targets $coreTargets -EmptyMessage 'Nenhum destino de Windows Update (CoreService) disponivel.'
    $lines.Add('')

    $lines.Add('## Dependencias')
    $lines.Add('')
    $dependencyTargets = @($EndpointMap.windowsUpdate.targets | Where-Object { @($_.relationships | Where-Object { $_.layer -eq 'Dependency' }).Count -gt 0 })
    Add-EndpointMarkdownTable -Lines $lines -Targets $dependencyTargets -EmptyMessage 'Nenhuma dependencia adicional identificada.'
    $lines.Add('')

    $lines.Add('## WinGet')
    $lines.Add('')
    Add-EndpointMarkdownTable -Lines $lines -Targets @($EndpointMap.winget.targets) -EmptyMessage 'Nenhuma fonte WinGet disponivel.'
    $lines.Add('')

    $lines.Add('## Warnings')
    $lines.Add('')
    if (@($EndpointMap.warnings).Count -eq 0) {
        $lines.Add('Nenhum warning registrado.')
    }
    else {
        foreach ($warning in @($EndpointMap.warnings)) {
            $lines.Add("- $warning")
        }
    }
    $lines.Add('')

    $lines.Add('## Limitacoes')
    $lines.Add('')
    if (@($EndpointMap.limitations).Count -eq 0) {
        $lines.Add('Nenhuma limitacao adicional registrada.')
    }
    else {
        foreach ($limitation in @($EndpointMap.limitations)) {
            $lines.Add("- $limitation")
        }
    }
    $lines.Add('')

    $lines.Add('## Proveniencia Documental')
    $lines.Add('')
    $allTargets = @($EndpointMap.windowsUpdate.targets) + @($EndpointMap.winget.targets)
    $authorities = @($allTargets | ForEach-Object { $_.provenance } | ForEach-Object { $_.authority } | Sort-Object -Unique)
    if ($authorities -contains 'MicrosoftDocumentation') {
        $lines.Add('- **MicrosoftDocumentation**: dados extraidos da documentacao oficial publicada em learn.microsoft.com.')
    }
    if ($authorities -contains 'LocalEffectiveConfiguration') {
        $lines.Add('- **LocalEffectiveConfiguration**: dados extraidos da configuracao efetiva do WinGet nesta maquina (winget source list/export), podendo divergir entre maquinas.')
    }
    if ($authorities.Count -eq 0) {
        $lines.Add('Nenhuma proveniencia documental disponivel nesta execucao.')
    }
    $lines.Add('')

    $lines.Add('## Avisos Importantes')
    $lines.Add('')
    $lines.Add("- $script:WinGetSourceDisclaimer")
    $lines.Add("- $script:NoConnectivityTestDisclaimer")
    $lines.Add('')

    $lines -join "`n"
}

function Export-EndpointMapMarkdown {
    <#
    .SYNOPSIS
        Writes the EndpointMap as a human-readable Markdown report, atomically,
        as UTF-8.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $EndpointMap,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [scriptblock] $Writer
    )

    $violations = @(Test-EndpointMapContract -EndpointMap $EndpointMap)
    if ($violations.Count -gt 0) {
        throw "EndpointMapContractInvalid: the endpoint map failed contract validation:`n - $($violations -join "`n - ")"
    }

    $content = Get-EndpointMapMarkdownContent -EndpointMap $EndpointMap

    $writeParams = @{ Path = $Path; Content = $content }
    if ($PSBoundParameters.ContainsKey('Writer')) {
        $writeParams['Writer'] = $Writer
    }

    Write-AtomicUtf8File @writeParams
}

Export-ModuleMember -Function Export-EndpointMapJson, Export-EndpointMapCsv, Export-EndpointMapMarkdown, Write-AtomicUtf8File, ConvertTo-EndpointMapCsvRow, Test-EndpointMapContract
