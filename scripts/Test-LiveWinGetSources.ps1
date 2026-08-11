#Requires -Version 7.0

Import-Module "$PSScriptRoot\..\src\WinGetSourceCollector.psm1" -Force

try {
    $wingetPath = Find-WinGetExecutable
    Write-Host "winget encontrado em: $wingetPath" -ForegroundColor Cyan
}
catch {
    Write-Host "FALHA ao localizar winget.exe: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

try {
    $result = Get-WinGetConfiguredSources -WinGetPath $wingetPath

    $result | Select-Object winGetPath, winGetVersion, acquisitionMethod, retrievedAtUtc | Format-List

    Write-Host "Fontes encontradas: $($result.sources.Count)" -ForegroundColor Cyan
    $result.sources | Format-Table name, arg, type, acquisitionMethod, confidence -AutoSize

    Write-Host "Evidencia (stdout/stderr/exitCode mascarados quando sensiveis):" -ForegroundColor Cyan
    $result.evidence | Format-List
}
catch {
    Write-Host "FALHA: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
