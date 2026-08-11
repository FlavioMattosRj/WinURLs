#Requires -Version 7.0

Import-Module "$PSScriptRoot\..\src\MicrosoftLearnCollector.psm1" -Force
Import-Module "$PSScriptRoot\..\src\WindowsEndpointParser.psm1" -Force
Import-Module "$PSScriptRoot\..\src\WinGetSourceCollector.psm1" -Force
Import-Module "$PSScriptRoot\..\src\EndpointNormalizer.psm1" -Force
Import-Module "$PSScriptRoot\..\src\EndpointExporter.psm1" -Force

$collectors = [System.Collections.Generic.List[pscustomobject]]::new()
$normalized = [System.Collections.Generic.List[pscustomobject]]::new()
$areaCount = 0

try {
    $snapshot = Get-OfficialDocumentSnapshot
    $windowsUpdateEntries = Get-WindowsEndpointArea -Html $snapshot.content -AreaName 'Windows Update'
    $areaCount++
    foreach ($entry in $windowsUpdateEntries) {
        $normalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $entry.targetRaw -ProtocolRaw $entry.protocolRaw -Product WindowsUpdate -Layer CoreService))
    }
    foreach ($areaName in @('Device authentication', 'Microsoft Account')) {
        foreach ($entry in (Get-WindowsEndpointArea -Html $snapshot.content -AreaName $areaName)) {
            $normalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $entry.targetRaw -ProtocolRaw $entry.protocolRaw -Product WindowsUpdate -Layer Dependency))
        }
        $areaCount++
    }
    $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Success'; message = $null })
}
catch {
    $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Failed'; message = $_.Exception.Message })
}

try {
    $wingetPath = Find-WinGetExecutable
    $wingetResult = Get-WinGetConfiguredSources -WinGetPath $wingetPath
    foreach ($source in $wingetResult.sources) {
        $normalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $source.arg -Product WinGet))
    }
    $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Success'; message = $null })
}
catch {
    $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Failed'; message = $_.Exception.Message })
}

$merged = @(Merge-NetworkTargets -NormalizedTarget $normalized)
$windowsUpdateTargets = @($merged | Where-Object { @($_.relationships | Where-Object { $_.product -eq 'WindowsUpdate' }).Count -gt 0 })
$winGetTargets = @($merged | Where-Object { @($_.relationships | Where-Object { $_.product -eq 'WinGet' }).Count -gt 0 })

$endpointMap = [pscustomobject]@{
    schemaVersion  = '1.0'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    coverage       = [pscustomobject]@{
        windowsUpdate = [pscustomobject]@{ included = ($windowsUpdateTargets.Count -gt 0); areaCount = $areaCount; targetCount = $windowsUpdateTargets.Count }
        winget        = [pscustomobject]@{ included = ($winGetTargets.Count -gt 0); targetCount = $winGetTargets.Count }
    }
    collectors     = @($collectors)
    windowsUpdate  = [pscustomobject]@{ targets = $windowsUpdateTargets }
    winget         = [pscustomobject]@{ targets = $winGetTargets }
    warnings       = @()
    limitations    = @('WinGet reflete apenas a configuracao local desta maquina no momento da coleta.')
}

$outDir = Join-Path $PSScriptRoot '..\out'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Export-EndpointMapJson -EndpointMap $endpointMap -Path (Join-Path $outDir 'endpoint-map.json')
Export-EndpointMapCsv -EndpointMap $endpointMap -Path (Join-Path $outDir 'endpoint-map.csv')
Export-EndpointMapMarkdown -EndpointMap $endpointMap -Path (Join-Path $outDir 'endpoint-map.md')

Write-Host "Alvos normalizados: $($normalized.Count); canonicos: $($merged.Count)" -ForegroundColor Cyan
Write-Host "Arquivos gerados em: $outDir" -ForegroundColor Cyan
Get-ChildItem -Path $outDir | Format-Table Name, Length -AutoSize
