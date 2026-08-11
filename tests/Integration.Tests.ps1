#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'Get-UpdateEndpointMap.ps1'
    $script:FixtureHtmlPath = Join-Path $PSScriptRoot 'fixtures' 'windows-endpoints-synthetic.html'
    $script:NonexistentHtmlPath = Join-Path $PSScriptRoot 'fixtures' 'does-not-exist.html'

    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'MicrosoftLearnCollector.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WindowsEndpointParser.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'WinGetSourceCollector.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EndpointNormalizer.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EndpointExporter.psm1') -Force

    # Pester's Mock -ModuleName does not intercept calls made by a separately
    # &-invoked .ps1 file. Running the script inside InModuleScope for the one
    # module that needs simulated behavior makes command resolution for that
    # module's functions go through Pester's mock, while unrelated modules
    # (and the real Windows Update HTML pipeline, driven via -InputHtmlPath)
    # continue to resolve normally. `exit` inside the wrapped script only
    # terminates that scope, not the whole test process, and $LASTEXITCODE is
    # still set correctly for the caller to inspect.
    function Invoke-OrchestratorWithWinGetMock {
        param(
            [hashtable] $ScriptParams = @{}
        )

        $scriptPathCopy = $script:ScriptPath
        $output = InModuleScope WinGetSourceCollector {
            param($ScriptPath, $Params)
            & $ScriptPath @Params
        } -Parameters @{ ScriptPath = $scriptPathCopy; Params = $ScriptParams }

        [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    }

    function Invoke-OrchestratorWithLearnMock {
        param(
            [hashtable] $ScriptParams = @{}
        )

        $scriptPathCopy = $script:ScriptPath
        $output = InModuleScope MicrosoftLearnCollector {
            param($ScriptPath, $Params)
            & $ScriptPath @Params
        } -Parameters @{ ScriptPath = $scriptPathCopy; Params = $ScriptParams }

        [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    }

    function Invoke-OrchestratorPlain {
        param(
            [hashtable] $ScriptParams = @{}
        )

        $output = & $script:ScriptPath @ScriptParams
        [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    }

    function New-FakeWinGetResult {
        [pscustomobject]@{
            winGetPath        = 'C:\Fake\winget.exe'
            winGetVersion     = 'v1.7.10582'
            retrievedAtUtc    = [DateTime]::UtcNow.ToString('o')
            acquisitionMethod = 'WinGetSourceExport'
            sources           = @(
                [pscustomobject]@{ arg = 'https://cdn.winget.microsoft.com/cache'; data = $null; explicit = $false; identifier = 'id1'; name = 'winget'; trustLevel = 'Trusted'; type = 'Microsoft.PreIndexed.Package'; acquisitionMethod = 'WinGetSourceExport'; confidence = 'Full'; rawLine = $null }
                [pscustomobject]@{ arg = 'https://storeedgefd.dsx.mp.microsoft.com/v9.0'; data = $null; explicit = $false; identifier = 'id2'; name = 'msstore'; trustLevel = 'Trusted'; type = 'Microsoft.Rest'; acquisitionMethod = 'WinGetSourceExport'; confidence = 'Full'; rawLine = $null }
            )
            evidence          = [pscustomobject]@{
                version = [pscustomobject]@{ argumentList = @('--version'); exitCode = 0; standardOutput = 'v1.7.10582'; standardError = ''; executedAtUtc = [DateTime]::UtcNow.ToString('o') }
                list    = [pscustomobject]@{ argumentList = @('source', 'list', '--disable-interactivity'); exitCode = 0; standardOutput = 'unused'; standardError = ''; executedAtUtc = [DateTime]::UtcNow.ToString('o') }
                export  = [pscustomobject]@{ argumentList = @('source', 'export', '--disable-interactivity'); exitCode = 0; standardOutput = 'unused'; standardError = ''; executedAtUtc = [DateTime]::UtcNow.ToString('o') }
            }
        }
    }

    $script:ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WinURLs-Integration-Tests-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:ScratchDir) {
        Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-UpdateEndpointMap.ps1' {
    Context 'complete success (test 1)' {
        It 'exits 0 and produces both Windows Update and WinGet data' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { 'C:\Fake\winget.exe' }
            Mock -ModuleName WinGetSourceCollector -CommandName Get-WinGetConfiguredSources { New-FakeWinGetResult }

            $outPath = Join-Path $script:ScratchDir 'complete.json'
            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; PassThru = $true }

            $run.ExitCode | Should -Be 0
            $run.Output.coverage.windowsUpdate.included | Should -BeTrue
            $run.Output.coverage.winget.included | Should -BeTrue
            @($run.Output.windowsUpdate.targets).Count | Should -Be 13
            @($run.Output.winget.targets).Count | Should -Be 2
            (Test-Path -LiteralPath $outPath) | Should -BeTrue
        }
    }

    Context 'Windows Update only (test 2)' {
        It 'exits 0 and skips WinGet entirely, without touching winget.exe' {
            $outPath = Join-Path $script:ScratchDir 'wu-only.json'
            $run = Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false; PassThru = $true }

            $run.ExitCode | Should -Be 0
            @($run.Output.windowsUpdate.targets).Count | Should -Be 13
            @($run.Output.winget.targets).Count | Should -Be 0
            ($run.Output.collectors | Where-Object { $_.name -eq 'WinGetSourceCollector' }).status | Should -Be 'Skipped'
        }
    }

    Context 'WinGet only (test 3)' {
        It 'exits 0 and skips Windows Update entirely, without fetching the document' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { 'C:\Fake\winget.exe' }
            Mock -ModuleName WinGetSourceCollector -CommandName Get-WinGetConfiguredSources { New-FakeWinGetResult }

            $outPath = Join-Path $script:ScratchDir 'winget-only.json'
            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ OutputPath = $outPath; IncludeWindowsUpdate = $false; PassThru = $true }

            $run.ExitCode | Should -Be 0
            @($run.Output.windowsUpdate.targets).Count | Should -Be 0
            @($run.Output.winget.targets).Count | Should -Be 2
            ($run.Output.collectors | Where-Object { $_.name -eq 'MicrosoftLearnCollector' }).status | Should -Be 'Skipped'
        }
    }

    Context 'partial failure (test 4)' {
        It 'exits 2 and preserves the Windows Update data produced before the WinGet failure' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { throw 'Simulated: winget.exe not found' }

            $outPath = Join-Path $script:ScratchDir 'partial.json'
            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; PassThru = $true; WarningAction = 'SilentlyContinue'; ErrorAction = 'SilentlyContinue' }

            $run.ExitCode | Should -Be 2
            @($run.Output.windowsUpdate.targets).Count | Should -Be 13
            @($run.Output.winget.targets).Count | Should -Be 0

            $wuStatus = $run.Output.collectors | Where-Object { $_.name -eq 'MicrosoftLearnCollector' }
            $wgStatus = $run.Output.collectors | Where-Object { $_.name -eq 'WinGetSourceCollector' }
            $wuStatus.status | Should -Be 'Success'
            $wgStatus.status | Should -Be 'Failed'
            $wgStatus.code | Should -Be 'WinGetCollectionFailed'
            $wgStatus.message | Should -Match 'winget.exe not found'
        }
    }

    Context 'total failure (test 5)' {
        It 'exits 10 and produces no target data from either collector' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { throw 'Simulated: winget.exe not found' }

            $outPath = Join-Path $script:ScratchDir 'total-failure.json'
            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ InputHtmlPath = $script:NonexistentHtmlPath; OutputPath = $outPath; PassThru = $true; WarningAction = 'SilentlyContinue'; ErrorAction = 'SilentlyContinue' }

            $run.ExitCode | Should -Be 10
            @($run.Output.windowsUpdate.targets).Count | Should -Be 0
            @($run.Output.winget.targets).Count | Should -Be 0
            ($run.Output.collectors | Where-Object { $_.name -eq 'MicrosoftLearnCollector' }).status | Should -Be 'Failed'
            ($run.Output.collectors | Where-Object { $_.name -eq 'WinGetSourceCollector' }).status | Should -Be 'Failed'
        }
    }

    Context 'IncludeDependencies false (test 6)' {
        It 'excludes dependency areas and records a limitation' {
            $outPath = Join-Path $script:ScratchDir 'no-deps.json'
            $run = Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false; IncludeDependencies = $false; PassThru = $true }

            @($run.Output.windowsUpdate.targets).Count | Should -Be 9
            $dependencyRelated = $run.Output.windowsUpdate.targets | Where-Object { @($_.relationships | Where-Object { $_.layer -eq 'Dependency' }).Count -gt 0 }
            $dependencyRelated | Should -BeNullOrEmpty
            ($run.Output.limitations -join ' ') | Should -Match 'IncludeDependencies'
        }
    }

    Context 'JSON output (test 7)' {
        It 'writes syntactically valid JSON to the requested path' {
            $outPath = Join-Path $script:ScratchDir 'format.json'
            Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false; Format = 'Json' } | Out-Null

            Test-Path -LiteralPath $outPath | Should -BeTrue
            Test-Json -Path $outPath | Should -BeTrue
        }
    }

    Context 'PassThru (test 8)' {
        It 'emits nothing to the output stream without -PassThru' {
            $outPath = Join-Path $script:ScratchDir 'no-passthru.json'
            $run = Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false }
            $run.Output | Should -BeNullOrEmpty
        }

        It 'emits the endpoint map object with -PassThru' {
            $outPath = Join-Path $script:ScratchDir 'passthru.json'
            $run = Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false; PassThru = $true }
            $run.Output | Should -Not -BeNullOrEmpty
            $run.Output.schemaVersion | Should -Be '1.0'
        }
    }

    Context 'proxy forwarded to the HTTP collector (test 9)' {
        It 'passes -Proxy through to Get-OfficialDocumentSnapshot' {
            Mock -ModuleName MicrosoftLearnCollector -CommandName Get-OfficialDocumentSnapshot {
                [pscustomobject]@{
                    requestedUri = $Uri; finalUri = $Uri; statusCode = 200; contentType = 'text/html'
                    retrievedAtUtc = [DateTime]::UtcNow.ToString('o'); etag = $null; lastModified = $null
                    contentSha256 = 'deadbeef'; content = (Get-Content -LiteralPath $script:FixtureHtmlPath -Raw)
                    acquisitionMethod = 'Http'
                }
            }

            $outPath = Join-Path $script:ScratchDir 'proxy.json'
            Invoke-OrchestratorWithLearnMock -ScriptParams @{ OutputPath = $outPath; IncludeWinGet = $false; Proxy = 'http://proxy.example.com:8080' } | Out-Null

            Should -Invoke -ModuleName MicrosoftLearnCollector -CommandName Get-OfficialDocumentSnapshot -ParameterFilter {
                $Proxy -eq 'http://proxy.example.com:8080'
            }
        }
    }

    Context 'evidence disabled by default (test 10)' {
        It 'writes no evidence file when -IncludeEvidence is not specified' {
            $subDir = Join-Path $script:ScratchDir 'no-evidence'
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
            $outPath = Join-Path $subDir 'no-evidence.json'

            Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false } | Out-Null

            Test-Path -LiteralPath (Join-Path $subDir 'evidence') | Should -BeFalse
        }

        It 'writes an evidence file when -IncludeEvidence is specified' {
            $subDir = Join-Path $script:ScratchDir 'with-evidence'
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
            $outPath = Join-Path $subDir 'with-evidence.json'
            $evidenceDir = Join-Path $subDir 'evidence'

            Invoke-OrchestratorPlain -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = $outPath; IncludeWinGet = $false; IncludeEvidence = $true; EvidenceDirectory = $evidenceDir } | Out-Null

            Test-Path -LiteralPath (Join-Path $evidenceDir 'evidence.json') | Should -BeTrue
        }
    }

    Context 'exit codes (test 11)' {
        It 'returns 0 for full success' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { 'C:\Fake\winget.exe' }
            Mock -ModuleName WinGetSourceCollector -CommandName Get-WinGetConfiguredSources { New-FakeWinGetResult }

            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = (Join-Path $script:ScratchDir 'exit-full.json') }
            $run.ExitCode | Should -Be 0
        }

        It 'returns 2 for partial success' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { throw 'Simulated failure' }

            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ InputHtmlPath = $script:FixtureHtmlPath; OutputPath = (Join-Path $script:ScratchDir 'exit-partial.json'); WarningAction = 'SilentlyContinue'; ErrorAction = 'SilentlyContinue' }
            $run.ExitCode | Should -Be 2
        }

        It 'returns 10 for total failure' {
            Mock -ModuleName WinGetSourceCollector -CommandName Find-WinGetExecutable { throw 'Simulated failure' }

            $run = Invoke-OrchestratorWithWinGetMock -ScriptParams @{ InputHtmlPath = $script:NonexistentHtmlPath; OutputPath = (Join-Path $script:ScratchDir 'exit-fatal.json'); WarningAction = 'SilentlyContinue'; ErrorAction = 'SilentlyContinue' }
            $run.ExitCode | Should -Be 10
        }

        It 'returns 10 when both collectors are disabled' {
            $run = Invoke-OrchestratorPlain -ScriptParams @{ OutputPath = (Join-Path $script:ScratchDir 'exit-none.json'); IncludeWindowsUpdate = $false; IncludeWinGet = $false; WarningAction = 'SilentlyContinue'; ErrorAction = 'SilentlyContinue' }
            $run.ExitCode | Should -Be 10
        }
    }
}
