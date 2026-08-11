#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'WindowsEndpointParser.psm1'
    Import-Module $script:ModulePath -Force

    $script:FixturePath = Join-Path $PSScriptRoot 'fixtures' 'windows-endpoints-synthetic.html'
    $script:FixtureHtml = Get-Content -LiteralPath $script:FixturePath -Raw -Encoding UTF8

    $script:ExpectedWindowsUpdateTargets = @(
        'definitionupdates.microsoft.com',
        '*.prod.do.dsp.mp.microsoft.com',
        '*.dl.delivery.mp.microsoft.com',
        '*.windowsupdate.com',
        '*.delivery.mp.microsoft.com',
        '*.update.microsoft.com',
        'adl.windows.com',
        'tsfe.trafficshaping.dsp.mp.microsoft.com',
        '*.api.cdp.microsoft.com'
    )

    function New-EndpointTableHtml {
        param(
            [Parameter(Mandatory = $true)]
            [string] $RowsHtml,

            [string[]] $Headers = @('Area', 'Description', 'Protocol', 'Destination')
        )

        $headerCells = ($Headers | ForEach-Object { "<th>$_</th>" }) -join ''

        @"
<html><body>
<table>
<thead><tr>$headerCells</tr></thead>
<tbody>
$RowsHtml
</tbody>
</table>
</body></html>
"@
    }
}

Describe 'ConvertFrom-HtmlEndpointTable' {
    Context 'tags inside cells' {
        It 'strips inline tags and preserves the underlying text' {
            $html = New-EndpointTableHtml -RowsHtml @'
<tr>
    <td><strong>Sample Area</strong></td>
    <td>Some <em>description</em> text with <a href="#">a link</a> inside.</td>
    <td><code>TCP 443</code></td>
    <td><code>*.example.microsoft.com</code></td>
</tr>
'@
            $result = ConvertFrom-HtmlEndpointTable -Html $html

            $result.Count | Should -Be 1
            $result[0].area | Should -Be 'Sample Area'
            $result[0].descriptionRaw | Should -Be 'Some description text with a link inside.'
            $result[0].protocolRaw | Should -Be 'TCP 443'
            $result[0].targetRaw | Should -Be '*.example.microsoft.com'
        }
    }

    Context 'HTML entities' {
        It 'decodes HTML entities in cell text' {
            $html = New-EndpointTableHtml -RowsHtml @'
<tr>
    <td>Sample Area</td>
    <td>Company &amp; Partners &mdash; non&nbsp;breaking space test &lt;tag-like&gt;</td>
    <td>TCP 443</td>
    <td>*.example.microsoft.com</td>
</tr>
'@
            $result = ConvertFrom-HtmlEndpointTable -Html $html

            $result[0].descriptionRaw | Should -Be 'Company & Partners — non breaking space test <tag-like>'
        }
    }

    Context 'malformed rows' {
        It 'skips a malformed row without affecting valid rows around it' {
            $html = New-EndpointTableHtml -RowsHtml @'
<tr>
    <td>Sample Area</td>
    <td>Description one</td>
    <td>TCP 443</td>
    <td>first.example.microsoft.com</td>
</tr>
<tr>
    <td colspan="2">Broken row with only one cell</td>
</tr>
<tr>
    <td></td>
    <td></td>
    <td>TCP 443</td>
    <td>second.example.microsoft.com</td>
</tr>
'@
            $result = ConvertFrom-HtmlEndpointTable -Html $html

            $result.Count | Should -Be 2
            $result[0].targetRaw | Should -Be 'first.example.microsoft.com'
            $result[1].targetRaw | Should -Be 'second.example.microsoft.com'
            $result[1].effectiveDescription | Should -Be 'Description one'
        }
    }

    Context 'missing table' {
        It 'throws MicrosoftLearnDocumentStructureChanged when no table exists' {
            $html = '<html><body><p>There is no table here.</p></body></html>'

            { ConvertFrom-HtmlEndpointTable -Html $html } | Should -Throw '*MicrosoftLearnDocumentStructureChanged*'
        }
    }

    Context 'unexpected headers' {
        It 'throws MicrosoftLearnDocumentStructureChanged when the expected headers are absent' {
            $html = New-EndpointTableHtml -Headers @('Name', 'Info', 'Kind', 'Host') -RowsHtml @'
<tr>
    <td>Sample Area</td>
    <td>Description</td>
    <td>TCP 443</td>
    <td>example.microsoft.com</td>
</tr>
'@
            { ConvertFrom-HtmlEndpointTable -Html $html } | Should -Throw '*MicrosoftLearnDocumentStructureChanged*'
        }
    }

    Context 'synthetic fixture' {
        BeforeAll {
            $script:AllFixtureEntries = ConvertFrom-HtmlEndpointTable -Html $script:FixtureHtml
        }

        It 'preserves document order across the whole table' {
            $orders = $script:AllFixtureEntries | Select-Object -ExpandProperty documentOrder
            $orders | Should -Be (1..$script:AllFixtureEntries.Count)
        }
    }
}

Describe 'Get-WindowsEndpointArea' {
    Context 'Windows Update area on the synthetic fixture' {
        BeforeAll {
            $script:WindowsUpdateEntries = Get-WindowsEndpointArea -Html $script:FixtureHtml -AreaName 'Windows Update'
        }

        It 'returns exactly the nine dated endpoints' {
            $script:WindowsUpdateEntries.Count | Should -Be 9
        }

        It 'preserves targetRaw literally and in document order' {
            $actualTargets = @($script:WindowsUpdateEntries | Select-Object -ExpandProperty targetRaw)
            ($actualTargets -join '|') | Should -Be ($script:ExpectedWindowsUpdateTargets -join '|')
        }

        It 'propagates the description from the first row to the continuation rows' {
            $firstDescription = $script:WindowsUpdateEntries[0].effectiveDescription
            $firstDescription | Should -Not -BeNullOrEmpty
            $script:WindowsUpdateEntries[0].descriptionRaw | Should -Be $firstDescription

            foreach ($entry in $script:WindowsUpdateEntries[1..8]) {
                $entry.descriptionRaw | Should -BeNullOrEmpty
                $entry.effectiveDescription | Should -Be $firstDescription
            }
        }

        It 'does not capture endpoints from neighboring areas' {
            $actualTargets = @($script:WindowsUpdateEntries | Select-Object -ExpandProperty targetRaw)
            $actualTargets | Should -Not -Contain '*.insider.windows.com'
            $actualTargets | Should -Not -Contain 'tsfe.insider.trafficshaping.dsp.mp.microsoft.com'
            $actualTargets | Should -Not -Contain '*.wub.microsoft.com'
            ($script:WindowsUpdateEntries | Select-Object -ExpandProperty area -Unique) | Should -Be 'Windows Update'
        }
    }

    Context 'area header/link row without a protocol' {
        It 'excludes a row that has destination-like link text but no protocol' {
            $html = New-EndpointTableHtml -RowsHtml @'
<tr>
    <td>Sample Area</td>
    <td></td>
    <td></td>
    <td><a href="#">Learn how to turn off traffic to all of the following endpoints for Sample Area.</a></td>
</tr>
<tr>
    <td></td>
    <td>Real description.</td>
    <td>TCP 443</td>
    <td>real.example.microsoft.com</td>
</tr>
'@
            $result = Get-WindowsEndpointArea -Html $html -AreaName 'Sample Area'

            $result.Count | Should -Be 1
            $result[0].targetRaw | Should -Be 'real.example.microsoft.com'
            $result[0].effectiveDescription | Should -Be 'Real description.'
        }
    }

    Context 'missing area' {
        It 'throws MicrosoftLearnDocumentStructureChanged when the requested area does not exist' {
            { Get-WindowsEndpointArea -Html $script:FixtureHtml -AreaName 'Nonexistent Area' } |
                Should -Throw '*MicrosoftLearnDocumentStructureChanged*'
        }
    }

    Context 'empty area' {
        It 'throws MicrosoftLearnDocumentStructureChanged when the area has no valid destinations' {
            $html = New-EndpointTableHtml -RowsHtml @'
<tr>
    <td>Empty Area</td>
    <td>Area with no valid destinations.</td>
    <td>TCP 443</td>
    <td></td>
</tr>
'@
            { Get-WindowsEndpointArea -Html $html -AreaName 'Empty Area' } |
                Should -Throw '*MicrosoftLearnDocumentStructureChanged*'
        }
    }
}

Describe 'Get-WindowsUpdatePublishedTargets' {
    Context 'dependencies disabled' {
        It 'returns only the Windows Update area' {
            $result = Get-WindowsUpdatePublishedTargets -Html $script:FixtureHtml

            $result.Count | Should -Be 9
            ($result | Select-Object -ExpandProperty area -Unique) | Should -Be 'Windows Update'
        }
    }

    Context 'dependencies enabled' {
        BeforeAll {
            $script:ResultWithDependencies = Get-WindowsUpdatePublishedTargets -Html $script:FixtureHtml -IncludeDependencies
        }

        It 'also returns Device authentication and Microsoft Account areas' {
            $areas = @($script:ResultWithDependencies | Select-Object -ExpandProperty area -Unique)

            $areas | Should -Contain 'Windows Update'
            $areas | Should -Contain 'Device authentication'
            $areas | Should -Contain 'Microsoft Account'
            $areas.Count | Should -Be 3
        }

        It 'preserves an unusual trailing-asterisk destination literally' {
            $targets = @($script:ResultWithDependencies | Select-Object -ExpandProperty targetRaw)
            $targets | Should -Contain 'login.live.com*'
        }
    }
}
