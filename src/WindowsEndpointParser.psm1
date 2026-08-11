#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:RequiredTableHeaders = @('Area', 'Description', 'Protocol', 'Destination')
$script:WindowsUpdateAreaName = 'Windows Update'
$script:DependencyAreaNames = @('Device authentication', 'Microsoft Account')

function Write-DocumentStructureChangedError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet] $Cmdlet,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $exception = [System.InvalidOperationException]::new("MicrosoftLearnDocumentStructureChanged: $Message")
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        $exception,
        'MicrosoftLearnDocumentStructureChanged',
        [System.Management.Automation.ErrorCategory]::InvalidData,
        $null
    )
    $Cmdlet.ThrowTerminatingError($errorRecord)
}

function ConvertTo-PlainCellText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $InnerHtml
    )

    $withoutTags = [regex]::Replace($InnerHtml, '<[^>]+>', ' ')
    $decoded = [System.Net.WebUtility]::HtmlDecode($withoutTags)
    [regex]::Replace($decoded, '\s+', ' ').Trim()
}

function Find-EndpointTableHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Html,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet] $Cmdlet
    )

    $tableMatches = [regex]::Matches($Html, '<table[^>]*>(?<table>.*?)</table>', 'Singleline, IgnoreCase')

    if ($tableMatches.Count -eq 0) {
        Write-DocumentStructureChangedError -Cmdlet $Cmdlet -Message 'No <table> element was found in the supplied HTML.'
    }

    foreach ($tableMatch in $tableMatches) {
        $tableHtml = $tableMatch.Groups['table'].Value
        $firstRowMatch = [regex]::Match($tableHtml, '<tr[^>]*>(?<row>.*?)</tr>', 'Singleline, IgnoreCase')
        if (-not $firstRowMatch.Success) {
            continue
        }

        $headerCellMatches = [regex]::Matches($firstRowMatch.Groups['row'].Value, '<t[dh][^>]*>(?<cell>.*?)</t[dh]>', 'Singleline, IgnoreCase')
        $headerTexts = @(foreach ($cellMatch in $headerCellMatches) {
            ConvertTo-PlainCellText -InnerHtml $cellMatch.Groups['cell'].Value
        })

        if ($headerTexts.Count -ne $script:RequiredTableHeaders.Count) {
            continue
        }

        $isMatch = $true
        for ($h = 0; $h -lt $script:RequiredTableHeaders.Count; $h++) {
            if ($headerTexts[$h] -ine $script:RequiredTableHeaders[$h]) {
                $isMatch = $false
                break
            }
        }

        if ($isMatch) {
            return $tableHtml
        }
    }

    Write-DocumentStructureChangedError -Cmdlet $Cmdlet -Message "No table matching the expected headers ($($script:RequiredTableHeaders -join ', ')) was found."
}

function ConvertFrom-HtmlEndpointTable {
    <#
    .SYNOPSIS
        Parses the Area / Description / Protocol / Destination endpoint table
        out of a raw Microsoft Learn HTML document, one entry per data row.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Html
    )

    $tableHtml = Find-EndpointTableHtml -Html $Html -Cmdlet $PSCmdlet

    $rowMatches = [regex]::Matches($tableHtml, '<tr[^>]*>(?<row>.*?)</tr>', 'Singleline, IgnoreCase')

    if ($rowMatches.Count -le 1) {
        Write-DocumentStructureChangedError -Cmdlet $PSCmdlet -Message 'The endpoint table does not contain any data rows.'
    }

    $currentArea = $null
    $currentAreaDescription = $null
    $documentOrder = 0
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    for ($i = 1; $i -lt $rowMatches.Count; $i++) {
        $rowHtml = $rowMatches[$i].Groups['row'].Value
        $cellMatches = [regex]::Matches($rowHtml, '<t[dh][^>]*>(?<cell>.*?)</t[dh]>', 'Singleline, IgnoreCase')

        if ($cellMatches.Count -ne $script:RequiredTableHeaders.Count) {
            Write-Verbose "Skipping malformed row at position $i (expected $($script:RequiredTableHeaders.Count) cells, found $($cellMatches.Count))."
            continue
        }

        $cellTexts = @(foreach ($cellMatch in $cellMatches) {
            ConvertTo-PlainCellText -InnerHtml $cellMatch.Groups['cell'].Value
        })

        $areaCell = $cellTexts[0]
        $descriptionCell = $cellTexts[1]
        $protocolCell = $cellTexts[2]
        $destinationCell = $cellTexts[3]

        if (-not [string]::IsNullOrWhiteSpace($areaCell)) {
            $currentArea = $areaCell
            $currentAreaDescription = $null
        }

        if ([string]::IsNullOrWhiteSpace($currentArea)) {
            Write-Verbose "Skipping row at position $i because no area has been established yet."
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($descriptionCell)) {
            $currentAreaDescription = $descriptionCell
        }

        $documentOrder++

        $results.Add([pscustomobject]@{
            area                  = $currentArea
            descriptionRaw        = $descriptionCell
            effectiveDescription  = $currentAreaDescription
            protocolRaw           = $protocolCell
            targetRaw             = $destinationCell
            documentOrder         = $documentOrder
        })
    }

    if ($results.Count -eq 0) {
        Write-DocumentStructureChangedError -Cmdlet $PSCmdlet -Message 'No valid endpoint rows were parsed from the table.'
    }

    $results.ToArray()
}

function Get-WindowsEndpointArea {
    <#
    .SYNOPSIS
        Returns the parsed endpoint entries belonging to a single named area,
        requiring at least one entry with both a protocol and a destination.
        Rows with a destination but no protocol are area header/link rows
        (a pattern seen on the real Microsoft Learn page) and are excluded.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Html,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $AreaName
    )

    $allEntries = ConvertFrom-HtmlEndpointTable -Html $Html

    $areaEntries = @($allEntries | Where-Object { $_.area -ieq $AreaName })

    if ($areaEntries.Count -eq 0) {
        Write-DocumentStructureChangedError -Cmdlet $PSCmdlet -Message "Area '$AreaName' was not found in the endpoint table."
    }

    $validEntries = @($areaEntries | Where-Object {
        (-not [string]::IsNullOrWhiteSpace($_.targetRaw)) -and (-not [string]::IsNullOrWhiteSpace($_.protocolRaw))
    })

    if ($validEntries.Count -eq 0) {
        Write-DocumentStructureChangedError -Cmdlet $PSCmdlet -Message "Area '$AreaName' exists but has no valid destinations."
    }

    $validEntries
}

function Get-WindowsUpdatePublishedTargets {
    <#
    .SYNOPSIS
        Returns the Windows Update endpoint entries, optionally including the
        Device authentication and Microsoft Account dependency areas.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Html,

        [Parameter()]
        [switch] $IncludeDependencies
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in (Get-WindowsEndpointArea -Html $Html -AreaName $script:WindowsUpdateAreaName)) {
        $results.Add($entry)
    }

    if ($IncludeDependencies) {
        foreach ($dependencyAreaName in $script:DependencyAreaNames) {
            foreach ($entry in (Get-WindowsEndpointArea -Html $Html -AreaName $dependencyAreaName)) {
                $results.Add($entry)
            }
        }
    }

    $results.ToArray()
}

Export-ModuleMember -Function ConvertFrom-HtmlEndpointTable, Get-WindowsEndpointArea, Get-WindowsUpdatePublishedTargets
