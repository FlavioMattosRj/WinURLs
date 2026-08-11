#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'MicrosoftLearnCollector.psm1'
    Import-Module $script:ModulePath -Force

    $script:FixturePath = Join-Path $PSScriptRoot 'fixtures' 'minimal-learn-page.html'
    $script:ValidHtmlContent = Get-Content -LiteralPath $script:FixturePath -Raw -Encoding UTF8

    function New-FakeWebResponse {
        param(
            [int] $StatusCode = 200,
            [string] $ContentType = 'text/html; charset=utf-8',
            [string] $Content = $script:ValidHtmlContent,
            [hashtable] $ExtraHeaders = @{},
            [string] $FinalUri = 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints'
        )

        $headers = @{ 'Content-Type' = $ContentType }
        foreach ($key in $ExtraHeaders.Keys) {
            $headers[$key] = $ExtraHeaders[$key]
        }

        [pscustomobject]@{
            StatusCode   = $StatusCode
            Headers      = $headers
            Content      = $Content
            BaseResponse = [pscustomobject]@{
                RequestMessage = [pscustomobject]@{
                    RequestUri = [uri] $FinalUri
                }
            }
        }
    }
}

Describe 'Get-ContentSha256' {
    It 'produces a deterministic hash for identical content' {
        $hash1 = Get-ContentSha256 -Content 'hello world'
        $hash2 = Get-ContentSha256 -Content 'hello world'
        $hash1 | Should -Be $hash2
    }

    It 'produces different hashes for different content' {
        $hash1 = Get-ContentSha256 -Content 'hello world'
        $hash2 = Get-ContentSha256 -Content 'hello world!'
        $hash1 | Should -Not -Be $hash2
    }

    It 'returns a 64-character lowercase hex string' {
        $hash = Get-ContentSha256 -Content 'hello world'
        $hash | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'Test-OfficialDocumentUri' {
    It 'accepts an https URI on an allowed host' {
        Test-OfficialDocumentUri -Uri 'https://learn.microsoft.com/en-us/windows/' -AllowedHost @('learn.microsoft.com') | Should -BeTrue
    }

    It 'rejects a host not in the allow-list' {
        Test-OfficialDocumentUri -Uri 'https://evil.example.com/' -AllowedHost @('learn.microsoft.com') | Should -BeFalse
    }

    It 'rejects a non-https scheme' {
        Test-OfficialDocumentUri -Uri 'http://learn.microsoft.com/' -AllowedHost @('learn.microsoft.com') | Should -BeFalse
    }

    It 'rejects a malformed URI' {
        Test-OfficialDocumentUri -Uri 'not a uri' -AllowedHost @('learn.microsoft.com') | Should -BeFalse
    }
}

Describe 'Get-OfficialDocumentSnapshot (HTTP acquisition)' {
    Context 'valid HTTP response' {
        It 'returns a populated snapshot object' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                New-FakeWebResponse -ExtraHeaders @{
                    'ETag'          = '"abc123"'
                    'Last-Modified' = 'Tue, 04 Aug 2026 10:00:00 GMT'
                }
            }

            $result = Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints'

            $result.acquisitionMethod | Should -Be 'Http'
            $result.requestedUri | Should -Be 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints'
            $result.finalUri | Should -Be 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints'
            $result.statusCode | Should -Be 200
            $result.contentType | Should -Be 'text/html; charset=utf-8'
            $result.etag | Should -Be '"abc123"'
            $result.lastModified | Should -Be 'Tue, 04 Aug 2026 10:00:00 GMT'
            $result.content | Should -Be $script:ValidHtmlContent
            $result.contentSha256 | Should -Be (Get-ContentSha256 -Content $script:ValidHtmlContent)
            $result.retrievedAtUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        }
    }

    Context 'HTTP error' {
        It 'throws when Invoke-WebRequest reports an HTTP error status' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                throw [System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 500 (Internal Server Error).')
            }

            { Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints' } |
                Should -Throw '*Failed to retrieve document*'
        }
    }

    Context 'timeout' {
        It 'throws when the request times out' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                throw [System.Threading.Tasks.TaskCanceledException]::new('The operation was canceled.')
            }

            { Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints' -TimeoutSec 1 } |
                Should -Throw '*Failed to retrieve document*'
        }
    }

    Context 'unauthorized final redirect' {
        It 'throws when the final URI host is not in the allow-list' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                New-FakeWebResponse -FinalUri 'https://malicious.example.com/en-us/windows/privacy/manage-windows-11-endpoints'
            }

            { Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints' } |
                Should -Throw '*Redirected URI is not authorized*'
        }
    }

    Context 'unexpected content type' {
        It 'throws when the response content type is not HTML' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                New-FakeWebResponse -ContentType 'application/json'
            }

            { Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints' } |
                Should -Throw '*Unexpected content type*'
        }
    }

    Context 'empty content' {
        It 'throws when the response content is empty' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                New-FakeWebResponse -Content ''
            }

            { Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints' } |
                Should -Throw '*empty or too small*'
        }

        It 'throws when the response content is excessively small' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                New-FakeWebResponse -Content '<html>too short</html>'
            }

            { Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints' } |
                Should -Throw '*empty or too small*'
        }
    }

    Context 'missing optional metadata' {
        It 'does not fail when ETag and Last-Modified headers are absent' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest {
                New-FakeWebResponse
            }

            $result = Get-OfficialDocumentSnapshot -Uri 'https://learn.microsoft.com/en-us/windows/privacy/manage-windows-11-endpoints'

            $result.etag | Should -BeNullOrEmpty
            $result.lastModified | Should -BeNullOrEmpty
            $result.statusCode | Should -Be 200
        }
    }

    Context 'unauthorized requested host' {
        It 'throws before invoking the request when the requested host is not allowed' {
            Mock -ModuleName MicrosoftLearnCollector Invoke-WebRequest { New-FakeWebResponse }

            { Get-OfficialDocumentSnapshot -Uri 'https://evil.example.com/page' } |
                Should -Throw '*Requested URI is not authorized*'

            Should -Invoke -ModuleName MicrosoftLearnCollector Invoke-WebRequest -Times 0
        }
    }
}

Describe 'Get-OfficialDocumentSnapshot (File acquisition)' {
    Context 'reading from a local fixture' {
        It 'returns a snapshot sourced from disk' {
            $result = Get-OfficialDocumentSnapshot -InputHtmlPath $script:FixturePath

            $result.acquisitionMethod | Should -Be 'File'
            $result.requestedUri | Should -Be $script:FixturePath
            $result.finalUri | Should -Be $script:FixturePath
            $result.statusCode | Should -BeNullOrEmpty
            $result.contentType | Should -Be 'text/html'
            $result.etag | Should -BeNullOrEmpty
            $result.lastModified | Should -BeNullOrEmpty
            $result.content | Should -Be $script:ValidHtmlContent
            $result.contentSha256 | Should -Be (Get-ContentSha256 -Content $script:ValidHtmlContent)
        }

        It 'throws when the file does not exist' {
            $missingPath = Join-Path $PSScriptRoot 'fixtures' 'does-not-exist.html'

            { Get-OfficialDocumentSnapshot -InputHtmlPath $missingPath } | Should -Throw '*was not found*'
        }
    }
}
