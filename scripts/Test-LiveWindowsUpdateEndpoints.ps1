#Requires -Version 7.0

Import-Module "$PSScriptRoot\..\src\MicrosoftLearnCollector.psm1" -Force
Import-Module "$PSScriptRoot\..\src\WindowsEndpointParser.psm1" -Force

$snapshot = Get-OfficialDocumentSnapshot
$targets = Get-WindowsUpdatePublishedTargets -Html $snapshot.content -IncludeDependencies

$targets | Format-Table area, protocolRaw, targetRaw -AutoSize
Write-Host "Total: $($targets.Count) entradas (esperado: 11 -> 9 Windows Update + 1 Device authentication + 1 Microsoft Account)"
