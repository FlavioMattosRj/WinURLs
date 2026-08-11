#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'WinGetSourceCollector.psm1'
    Import-Module $script:ModulePath -Force

    $script:FixturesDir = Join-Path $PSScriptRoot 'fixtures'

    function Get-FixtureContent {
        param([string] $Name)
        Get-Content -LiteralPath (Join-Path $script:FixturesDir $Name) -Raw -Encoding UTF8
    }

}

Describe 'Find-WinGetExecutable' {
    It 'throws WinGetExecutableNotFound when winget cannot be located' {
        { Find-WinGetExecutable -Locator { $null } } | Should -Throw '*WinGetExecutableNotFound*'
    }

    It 'returns the path produced by a custom locator' {
        $result = Find-WinGetExecutable -Locator { 'C:\Fake\winget.exe' }
        $result | Should -Be 'C:\Fake\winget.exe'
    }
}

Describe 'Invoke-WinGetReadOnlyCommand' {
    Context 'whitelist enforcement' {
        It 'throws WinGetMutatingCommandBlocked and never invokes the process for a mutating command' {
            $callState = [ordered]@{ Invoked = $false }
            $invoker = { param($ExePath, $Arguments, $TimeoutSec) $callState.Invoked = $true; throw 'Should not be called' }.GetNewClosure()

            { Invoke-WinGetReadOnlyCommand -WinGetPath 'C:\Fake\winget.exe' -ArgumentList @('source', 'add', 'evil', 'https://evil.example.com') -Invoker $invoker } |
                Should -Throw '*WinGetMutatingCommandBlocked*'

            $callState.Invoked | Should -BeFalse
        }

        It 'throws WinGetMutatingCommandBlocked for --accept-source-agreements' {
            $invoker = { param($ExePath, $Arguments, $TimeoutSec) throw 'Should not be called' }

            { Invoke-WinGetReadOnlyCommand -WinGetPath 'C:\Fake\winget.exe' -ArgumentList @('source', 'list', '--accept-source-agreements') -Invoker $invoker } |
                Should -Throw '*WinGetMutatingCommandBlocked*'
        }
    }

    Context 'successful invocation' {
        It 'returns the version output captured from the injected invoker' {
            $invoker = { param($ExePath, $Arguments, $TimeoutSec) [pscustomobject]@{ ExitCode = 0; StandardOutput = "v1.7.10582`n"; StandardError = '' } }

            $result = Invoke-WinGetReadOnlyCommand -WinGetPath 'C:\Fake\winget.exe' -ArgumentList @('--version') -Invoker $invoker

            $result.exitCode | Should -Be 0
            $result.standardOutput | Should -Be "v1.7.10582`n"
        }

        It 'captures stderr content' {
            $invoker = { param($ExePath, $Arguments, $TimeoutSec) [pscustomobject]@{ ExitCode = 0; StandardOutput = ''; StandardError = 'Warning: proxy negotiation took longer than expected.' } }

            $result = Invoke-WinGetReadOnlyCommand -WinGetPath 'C:\Fake\winget.exe' -ArgumentList @('source', 'list', '--disable-interactivity') -Invoker $invoker

            $result.standardError | Should -Be 'Warning: proxy negotiation took longer than expected.'
        }

        It 'captures a non-zero exit code without throwing' {
            $invoker = { param($ExePath, $Arguments, $TimeoutSec) [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = 'Error: network unreachable.' } }

            $result = Invoke-WinGetReadOnlyCommand -WinGetPath 'C:\Fake\winget.exe' -ArgumentList @('source', 'export', '--disable-interactivity') -Invoker $invoker

            $result.exitCode | Should -Be 1
            $result.standardError | Should -Be 'Error: network unreachable.'
        }
    }
}

Describe 'ConvertFrom-WinGetSourceExport' {
    It 'parses a single JSON object fixture' {
        $result = ConvertFrom-WinGetSourceExport -RawExport (Get-FixtureContent 'winget-source-export-single.json')

        $result.Count | Should -Be 1
        $result[0].name | Should -Be 'winget'
        $result[0].arg | Should -Be 'https://cdn.winget.microsoft.com/cache'
        $result[0].trustLevel | Should -Be 'Trusted'
        $result[0].acquisitionMethod | Should -Be 'WinGetSourceExport'
        $result[0].confidence | Should -Be 'Full'
    }

    It 'parses a JSON array fixture' {
        $result = ConvertFrom-WinGetSourceExport -RawExport (Get-FixtureContent 'winget-source-export-array.json')

        $result.Count | Should -Be 2
        ($result | Select-Object -ExpandProperty name) | Should -Be @('winget', 'msstore')
    }

    It 'parses concatenated JSON objects surrounded by warning text' {
        $result = ConvertFrom-WinGetSourceExport -RawExport (Get-FixtureContent 'winget-source-export-concatenated.txt')

        $result.Count | Should -Be 2
        ($result | Select-Object -ExpandProperty name) | Should -Be @('winget', 'msstore')
        ($result | Select-Object -ExpandProperty arg) | Should -Be @('https://cdn.winget.microsoft.com/cache', 'https://storeedgefd.dsx.mp.microsoft.com/v9.0')
    }

    It 'respects braces, escaped quotes, and backslashes inside JSON string values' {
        $raw = '{"Arg":"https://example.microsoft.com","Data":null,"Explicit":false,"Identifier":"id-1","Name":"Contoso \"Elite\" {Test} C:\\Sources\\A","TrustLevel":"Trusted","Type":"Microsoft.Rest"}{"Arg":"https://example2.microsoft.com","Data":null,"Explicit":false,"Identifier":"id-2","Name":"Second Source","TrustLevel":"Trusted","Type":"Microsoft.Rest"}'

        $result = ConvertFrom-WinGetSourceExport -RawExport $raw

        $result.Count | Should -Be 2
        $result[0].name | Should -Be 'Contoso "Elite" {Test} C:\Sources\A'
        $result[1].name | Should -Be 'Second Source'
    }

    It 'throws WinGetSourceExportParseFailed for content with no JSON' {
        { ConvertFrom-WinGetSourceExport -RawExport 'This is not JSON at all.' } | Should -Throw '*WinGetSourceExportParseFailed*'
    }
}

Describe 'ConvertFrom-WinGetSourceList' {
    It 'extracts sources from an English-locale listing without relying on header text' {
        $result = ConvertFrom-WinGetSourceList -RawList (Get-FixtureContent 'winget-source-list-en.txt')

        $result.Count | Should -Be 3
        $result | ForEach-Object { $_.acquisitionMethod | Should -Be 'WinGetSourceListFallback' }
    }

    It 'extracts sources from a Portuguese-locale listing identically' {
        $enResult = ConvertFrom-WinGetSourceList -RawList (Get-FixtureContent 'winget-source-list-en.txt')
        $ptResult = ConvertFrom-WinGetSourceList -RawList (Get-FixtureContent 'winget-source-list-pt.txt')

        ($ptResult | Select-Object -ExpandProperty arg) | Should -Be ($enResult | Select-Object -ExpandProperty arg)
    }

    It 'preserves the full URL path' {
        $result = ConvertFrom-WinGetSourceList -RawList (Get-FixtureContent 'winget-source-list-en.txt')

        ($result | Select-Object -ExpandProperty arg) | Should -Contain 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'
    }

    It 'recognizes a UNC path source and preserves the original line' {
        $result = ConvertFrom-WinGetSourceList -RawList (Get-FixtureContent 'winget-source-list-en.txt')

        $uncEntry = $result | Where-Object { $_.arg -eq '\\fileserver\share\wingetsources' }
        $uncEntry | Should -Not -BeNullOrEmpty
        $uncEntry.rawLine | Should -Match 'corp'
    }

    It 'marks confidence Partial when a line contains more than one candidate match' {
        $ambiguousLine = 'mirror  https://primary.example.com/source  https://secondary.example.com/source  Microsoft.Rest'

        $result = ConvertFrom-WinGetSourceList -RawList $ambiguousLine

        $result.Count | Should -Be 1
        $result[0].confidence | Should -Be 'Partial'
    }
}

Describe 'Protect-WinGetEvidence' {
    It 'masks sensitive keys in structured evidence while preserving other fields' {
        $evidence = [ordered]@{
            exitCode = 0
            Token    = 'super-secret-token'
            Password = 'hunter2'
            note     = 'not sensitive'
        }

        $result = Protect-WinGetEvidence -Evidence $evidence

        $result.Token | Should -Be '***MASKED***'
        $result.Password | Should -Be '***MASKED***'
        $result.note | Should -Be 'not sensitive'
        $result.exitCode | Should -Be 0
    }

    It 'masks sensitive key: value lines inside free-text strings' {
        $stderrText = @"
Connecting to proxy...
Authorization: Bearer abc.def.ghi
ApiKey=12345-abcde
Everything else is fine.
"@

        $result = Protect-WinGetEvidence -Evidence $stderrText

        $result | Should -Not -Match 'abc\.def\.ghi'
        $result | Should -Not -Match '12345-abcde'
        $result | Should -Match 'Everything else is fine\.'
    }
}

Describe 'Get-WinGetConfiguredSources' {
    Context 'export succeeds' {
        It 'uses the export as the primary structured source and captures the version' {
            $invoker = {
                param($ExePath, $Arguments, $TimeoutSec)
                $key = $Arguments -join ' '
                switch ($key) {
                    '--version' { [pscustomobject]@{ ExitCode = 0; StandardOutput = "v1.7.10582`n"; StandardError = '' } }
                    'source list --disable-interactivity' { [pscustomobject]@{ ExitCode = 0; StandardOutput = 'unused'; StandardError = '' } }
                    'source export --disable-interactivity' { [pscustomobject]@{ ExitCode = 0; StandardOutput = '{"Arg":"https://cdn.winget.microsoft.com/cache","Data":null,"Explicit":false,"Identifier":"id","Name":"winget","TrustLevel":"Trusted","Type":"Microsoft.PreIndexed.Package"}'; StandardError = '' } }
                    default { throw "Unexpected arguments: $key" }
                }
            }

            $result = Get-WinGetConfiguredSources -WinGetPath 'C:\Fake\winget.exe' -Invoker $invoker

            $result.acquisitionMethod | Should -Be 'WinGetSourceExport'
            $result.winGetVersion | Should -Be 'v1.7.10582'
            $result.sources.Count | Should -Be 1
            $result.sources[0].name | Should -Be 'winget'
        }
    }

    Context 'export fails, falls back to list' {
        It 'falls back to source list parsing when export returns a non-zero exit code' {
            $invoker = {
                param($ExePath, $Arguments, $TimeoutSec)
                $key = $Arguments -join ' '
                switch ($key) {
                    '--version' { [pscustomobject]@{ ExitCode = 0; StandardOutput = "v1.7.10582`n"; StandardError = '' } }
                    'source list --disable-interactivity' {
                        [pscustomobject]@{
                            ExitCode       = 0
                            StandardOutput = "Name    Argument                                       Type`n------------------------------------------------------------`nwinget  https://cdn.winget.microsoft.com/cache          Microsoft.PreIndexed.Package`n"
                            StandardError  = ''
                        }
                    }
                    'source export --disable-interactivity' { [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = 'Error: source export failed.' } }
                    default { throw "Unexpected arguments: $key" }
                }
            }

            $result = Get-WinGetConfiguredSources -WinGetPath 'C:\Fake\winget.exe' -Invoker $invoker

            $result.acquisitionMethod | Should -Be 'WinGetSourceListFallback'
            $result.sources.Count | Should -Be 1
            $result.sources[0].arg | Should -Be 'https://cdn.winget.microsoft.com/cache'
        }
    }

    Context 'both export and list fail' {
        It 'throws WinGetSourcesUnavailable' {
            $invoker = {
                param($ExePath, $Arguments, $TimeoutSec)
                $key = $Arguments -join ' '
                switch ($key) {
                    '--version' { [pscustomobject]@{ ExitCode = 0; StandardOutput = "v1.7.10582`n"; StandardError = '' } }
                    'source list --disable-interactivity' { [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = 'Error: no network.' } }
                    'source export --disable-interactivity' { [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = 'Error: no network.' } }
                    default { throw "Unexpected arguments: $key" }
                }
            }

            { Get-WinGetConfiguredSources -WinGetPath 'C:\Fake\winget.exe' -Invoker $invoker } | Should -Throw '*WinGetSourcesUnavailable*'
        }
    }

    Context 'mutating command safety' {
        It 'never invokes a mutating WinGet command across the whole discovery flow' {
            $calls = [System.Collections.Generic.List[string]]::new()

            $invoker = {
                param($ExePath, $Arguments, $TimeoutSec)
                $calls.Add($Arguments -join ' ')
                $key = $Arguments -join ' '
                switch ($key) {
                    '--version' { [pscustomobject]@{ ExitCode = 0; StandardOutput = "v1.7.10582`n"; StandardError = '' } }
                    'source list --disable-interactivity' { [pscustomobject]@{ ExitCode = 0; StandardOutput = 'unused'; StandardError = '' } }
                    'source export --disable-interactivity' { [pscustomobject]@{ ExitCode = 0; StandardOutput = '{"Arg":"https://cdn.winget.microsoft.com/cache","Name":"winget"}'; StandardError = '' } }
                    default { throw "Unexpected arguments: $key" }
                }
            }.GetNewClosure()

            $null = Get-WinGetConfiguredSources -WinGetPath 'C:\Fake\winget.exe' -Invoker $invoker

            $calls.Count | Should -Be 3
            foreach ($call in $calls) {
                foreach ($forbidden in @('add', 'edit', 'update', 'remove', 'reset', '--accept-source-agreements')) {
                    $call | Should -Not -Match ([regex]::Escape($forbidden))
                }
            }
        }
    }
}
