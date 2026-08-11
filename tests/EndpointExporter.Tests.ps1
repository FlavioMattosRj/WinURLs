#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'EndpointExporter.psm1'
    $script:NormalizerModulePath = Join-Path $PSScriptRoot '..' 'src' 'EndpointNormalizer.psm1'
    Import-Module $script:NormalizerModulePath -Force
    Import-Module $script:ModulePath -Force

    function New-TestEndpointMap {
        param(
            [switch] $IncludeWinGet = $true,
            [switch] $IncludeWindowsUpdate = $true,
            [string[]] $Warnings = @(),
            [string[]] $Limitations = @()
        )

        $windowsUpdateTargets = @()
        $winGetTargets = @()
        $collectors = [System.Collections.Generic.List[pscustomobject]]::new()

        if ($IncludeWindowsUpdate) {
            $core = @(
                ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw 'HTTPS' -Product WindowsUpdate -Layer CoreService
                ConvertTo-NormalizedNetworkTarget -TargetRaw '*.windowsupdate.com' -ProtocolRaw 'TLSv1.2/HTTPS/HTTP' -Product WindowsUpdate -Layer CoreService
            )
            $dependency = @(
                ConvertTo-NormalizedNetworkTarget -TargetRaw 'login.live.com*' -ProtocolRaw 'HTTPS' -Product WindowsUpdate -Layer Dependency
            )
            $windowsUpdateTargets = @(Merge-NetworkTargets -NormalizedTarget @($core + $dependency))
            $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Success'; message = $null })
        }
        else {
            $collectors.Add([pscustomobject]@{ name = 'MicrosoftLearnCollector'; status = 'Failed'; message = 'nao foi possivel acessar learn.microsoft.com' })
        }

        if ($IncludeWinGet) {
            $winget = @(
                ConvertTo-NormalizedNetworkTarget -TargetRaw 'https://cdn.winget.microsoft.com/cache' -Product WinGet
                ConvertTo-NormalizedNetworkTarget -TargetRaw 'http://legacy.example.com/mirror' -Product WinGet
            )
            $winGetTargets = @(Merge-NetworkTargets -NormalizedTarget $winget)
            $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Success'; message = $null })
        }
        else {
            $collectors.Add([pscustomobject]@{ name = 'WinGetSourceCollector'; status = 'Failed'; message = 'winget.exe nao encontrado' })
        }

        [pscustomobject]@{
            schemaVersion  = '1.0'
            generatedAtUtc = [DateTime]::UtcNow.ToString('o')
            coverage       = [pscustomobject]@{
                windowsUpdate = [pscustomobject]@{ included = [bool] $IncludeWindowsUpdate; areaCount = $(if ($IncludeWindowsUpdate) { 2 } else { 0 }); targetCount = $windowsUpdateTargets.Count }
                winget        = [pscustomobject]@{ included = [bool] $IncludeWinGet; targetCount = $winGetTargets.Count }
            }
            collectors     = @($collectors)
            windowsUpdate  = [pscustomobject]@{ targets = @($windowsUpdateTargets) }
            winget         = [pscustomobject]@{ targets = @($winGetTargets) }
            warnings       = @($Warnings)
            limitations    = @($Limitations)
        }
    }

    $script:ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WinURLs-EndpointExporter-Tests-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:ScratchDir) {
        Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Export-EndpointMapJson' {
    Context 'valid JSON (test 1)' {
        It 'writes syntactically valid JSON that round-trips the canonical structure' {
            $endpointMap = New-TestEndpointMap
            $outPath = Join-Path $script:ScratchDir 'valid.json'

            Export-EndpointMapJson -EndpointMap $endpointMap -Path $outPath

            Test-Path -LiteralPath $outPath | Should -BeTrue
            Test-Json -Path $outPath | Should -BeTrue

            $parsed = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json
            $parsed.schemaVersion | Should -Be '1.0'
            @($parsed.windowsUpdate.targets).Count | Should -Be $endpointMap.windowsUpdate.targets.Count
            @($parsed.winget.targets).Count | Should -Be $endpointMap.winget.targets.Count
        }
    }

    Context 'invalid JSON rejected (test 2)' {
        It 'throws and does not create a file when the endpoint map fails contract validation' {
            $brokenMap = [pscustomobject]@{ schemaVersion = '1.0' }
            $outPath = Join-Path $script:ScratchDir 'should-not-exist.json'

            { Export-EndpointMapJson -EndpointMap $brokenMap -Path $outPath } | Should -Throw '*EndpointMapContractInvalid*'
            Test-Path -LiteralPath $outPath | Should -BeFalse
        }
    }
}

Describe 'Export-EndpointMapCsv' {
    Context 'multiple schemes (test 3)' {
        It 'writes one row per target with https and http schemes both represented' {
            $endpointMap = New-TestEndpointMap
            $outPath = Join-Path $script:ScratchDir 'multi-scheme.csv'

            Export-EndpointMapCsv -EndpointMap $endpointMap -Path $outPath

            $rows = Import-Csv -LiteralPath $outPath

            $rows.Count | Should -Be (@($endpointMap.windowsUpdate.targets).Count + @($endpointMap.winget.targets).Count)

            $httpsRow = $rows | Where-Object { $_.targetNormalized -eq 'https://cdn.winget.microsoft.com/cache' }
            $httpRow = $rows | Where-Object { $_.targetNormalized -eq 'http://legacy.example.com/mirror' }

            $httpsRow | Should -Not -BeNullOrEmpty
            $httpRow | Should -Not -BeNullOrEmpty

            $wildcardRow = $rows | Where-Object { $_.targetRaw -eq 'login.live.com*' }
            $wildcardRow.hasAmbiguousWildcard | Should -Be 'True'
            $wildcardRow.relationships | Should -Match 'WindowsUpdate/Dependency'
        }
    }
}

Describe 'Export-EndpointMapMarkdown' {
    Context 'complete success (test 4)' {
        It 'renders every required section when both collectors succeed' {
            $endpointMap = New-TestEndpointMap -Warnings @('exemplo de warning') -Limitations @('exemplo de limitacao')
            $outPath = Join-Path $script:ScratchDir 'complete.md'

            Export-EndpointMapMarkdown -EndpointMap $endpointMap -Path $outPath

            $content = Get-Content -LiteralPath $outPath -Raw

            $content | Should -Match '(?m)^# Mapa de Endpoints'
            $content | Should -Match 'Gerado em \(UTC\)'
            $content | Should -Match '## Cobertura'
            $content | Should -Match '## Status dos Coletores'
            $content | Should -Match '## Windows Update'
            $content | Should -Match '## WinGet'
            $content | Should -Match '## Dependencias'
            $content | Should -Match '## Warnings'
            $content | Should -Match 'exemplo de warning'
            $content | Should -Match '## Limitacoes'
            $content | Should -Match 'exemplo de limitacao'
            $content | Should -Match '## Proveniencia Documental'
            $content | Should -Match 'MicrosoftDocumentation'
            $content | Should -Match 'LocalEffectiveConfiguration'
            $content | Should -Match 'nao representam necessariamente as URLs de instaladores'
            $content | Should -Match 'foi testado por conexao real'
            $content | Should -Match 'adl\.windows\.com'
            $content | Should -Match 'login\.live\.com\*'
            $content | Should -Match 'cdn\.winget\.microsoft\.com'
        }
    }

    Context 'partial success (test 5)' {
        It 'still renders a complete, non-throwing report when WinGet collection failed' {
            $endpointMap = New-TestEndpointMap -IncludeWinGet:$false

            $outPath = Join-Path $script:ScratchDir 'partial.md'

            { Export-EndpointMapMarkdown -EndpointMap $endpointMap -Path $outPath } | Should -Not -Throw

            $content = Get-Content -LiteralPath $outPath -Raw

            $content | Should -Match '## Status dos Coletores'
            $content | Should -Match 'WinGetSourceCollector'
            $content | Should -Match 'Failed'
            $content | Should -Match 'winget\.exe nao encontrado'
            $content | Should -Match 'Nenhuma fonte WinGet disponivel'
            $content | Should -Match '## Windows Update'
            $content | Should -Match 'adl\.windows\.com'
        }
    }

    Context 'non-ASCII characters (test 6)' {
        It 'preserves accented characters through the UTF-8 write and read cycle' {
            $endpointMap = New-TestEndpointMap -Warnings @('Atencao: verificacao manual necessaria para configuracao nao padrao') -Limitations @('Nao ha garantia de cobertura total dos endpoints regionais (ex.: edicoes em portugues)')
            $outPath = Join-Path $script:ScratchDir 'nonascii.md'

            Export-EndpointMapMarkdown -EndpointMap $endpointMap -Path $outPath

            $bytes = [System.IO.File]::ReadAllBytes($outPath)
            $bytes[0] | Should -Not -Be 0xEF

            $content = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::UTF8)
            $content | Should -Match 'Atencao'
            $content | Should -Match 'edicoes em portugues'
        }

        It 'preserves genuinely non-ASCII accented text end to end' {
            $endpointMap = New-TestEndpointMap -Warnings @('Atenção: configuração não testada em edições regionais') -Limitations @()
            $outPath = Join-Path $script:ScratchDir 'accents.md'

            Export-EndpointMapMarkdown -EndpointMap $endpointMap -Path $outPath

            $content = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::UTF8)
            $content | Should -Match 'Atenção'
            $content | Should -Match 'configuração não testada'
            $content | Should -Match 'edições regionais'
        }
    }
}

Describe 'Write-AtomicUtf8File' {
    Context 'nonexistent path (test 7)' {
        It 'throws when the destination directory does not exist' {
            $badPath = Join-Path $script:ScratchDir 'no-such-subdir\file.txt'

            { Write-AtomicUtf8File -Path $badPath -Content 'hello' } | Should -Throw
        }
    }

    Context 'failure during write (test 8)' {
        It 'throws and removes the temp file when the writer fails' {
            $outPath = Join-Path $script:ScratchDir 'write-failure.txt'
            $failingWriter = { param($TempPath, $Content) throw 'Simulated disk failure' }

            { Write-AtomicUtf8File -Path $outPath -Content 'new content' -Writer $failingWriter } | Should -Throw '*Simulated disk failure*'

            Test-Path -LiteralPath $outPath | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:ScratchDir -Filter '*.tmp' -Force) | Should -BeNullOrEmpty
        }
    }

    Context 'previous final file must not be corrupted (test 9)' {
        It 'leaves the pre-existing destination file untouched when the write fails' {
            $outPath = Join-Path $script:ScratchDir 'preserve-original.txt'
            Set-Content -LiteralPath $outPath -Value 'ORIGINAL CONTENT' -NoNewline -Encoding utf8

            $failingWriter = { param($TempPath, $Content) throw 'Simulated disk failure' }

            { Write-AtomicUtf8File -Path $outPath -Content 'CORRUPTED CONTENT' -Writer $failingWriter } | Should -Throw

            (Get-Content -LiteralPath $outPath -Raw) | Should -Be 'ORIGINAL CONTENT'
        }
    }

    Context 'no leftover temp file after success (test 10)' {
        It 'leaves no temp file behind after a successful write' {
            $outPath = Join-Path $script:ScratchDir 'clean-success.txt'

            Write-AtomicUtf8File -Path $outPath -Content 'final content'

            (Get-Content -LiteralPath $outPath -Raw) | Should -Be 'final content'
            @(Get-ChildItem -LiteralPath $script:ScratchDir -Filter '*.tmp' -Force) | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-EndpointMapCsvRow' {
    It 'joins array-valued fields with semicolons and preserves distinct raw values' {
        $a = ConvertTo-NormalizedNetworkTarget -TargetRaw 'adl.windows.com' -ProtocolRaw 'HTTPS' -Product WindowsUpdate -Layer CoreService
        $b = ConvertTo-NormalizedNetworkTarget -TargetRaw 'ADL.WINDOWS.COM' -ProtocolRaw 'HTTPS' -Product WinGet
        $merged = @(Merge-NetworkTargets -NormalizedTarget @($a, $b))[0]

        $row = ConvertTo-EndpointMapCsvRow -Target $merged

        $row.targetRaw | Should -Match ';'
        $row.targetRaw -split ';' | Should -Contain 'adl.windows.com'
        $row.targetRaw -split ';' | Should -Contain 'ADL.WINDOWS.COM'
        $row.relationships -split ';' | Should -HaveCount 2
    }
}
