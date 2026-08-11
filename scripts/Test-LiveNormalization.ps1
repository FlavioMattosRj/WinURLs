#Requires -Version 7.0

Import-Module "$PSScriptRoot\..\src\MicrosoftLearnCollector.psm1" -Force
Import-Module "$PSScriptRoot\..\src\WindowsEndpointParser.psm1" -Force
Import-Module "$PSScriptRoot\..\src\WinGetSourceCollector.psm1" -Force
Import-Module "$PSScriptRoot\..\src\EndpointNormalizer.psm1" -Force

$snapshot = Get-OfficialDocumentSnapshot
$windowsUpdateEntries = Get-WindowsEndpointArea -Html $snapshot.content -AreaName 'Windows Update'
$dependencyAreas = @('Device authentication', 'Microsoft Account')

$normalized = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($entry in $windowsUpdateEntries) {
    $normalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $entry.targetRaw -ProtocolRaw $entry.protocolRaw -Product WindowsUpdate -Layer CoreService))
}

foreach ($areaName in $dependencyAreas) {
    foreach ($entry in (Get-WindowsEndpointArea -Html $snapshot.content -AreaName $areaName)) {
        $normalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $entry.targetRaw -ProtocolRaw $entry.protocolRaw -Product WindowsUpdate -Layer Dependency))
    }
}

$wingetPath = Find-WinGetExecutable
$wingetResult = Get-WinGetConfiguredSources -WinGetPath $wingetPath
foreach ($source in $wingetResult.sources) {
    $normalized.Add((ConvertTo-NormalizedNetworkTarget -TargetRaw $source.arg -Product WinGet))
}

$merged = Merge-NetworkTargets -NormalizedTarget $normalized

Write-Host "Alvos normalizados (pre-merge): $($normalized.Count)" -ForegroundColor Cyan
Write-Host "Alvos canonicos (pos-merge):    $($merged.Count)" -ForegroundColor Cyan

$merged | Format-Table canonicalKey, targetType, host, port, hasAmbiguousWildcard -AutoSize

Write-Host "`nRelacionamentos por alvo:" -ForegroundColor Cyan
foreach ($item in $merged) {
    $relSummary = ($item.relationships | ForEach-Object { "$($_.product)/$($_.layer)" }) -join ', '
    "{0,-55} -> {1}" -f $item.host, $relSummary
}
