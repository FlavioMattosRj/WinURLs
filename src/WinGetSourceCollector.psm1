#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:MaskedValueText = '***MASKED***'
$script:SensitiveEvidenceKeyPattern = '(?i)(Authorization|Headers?|Token|Secret|Password|Credential|ApiKey)'
$script:SensitiveInlinePattern = '(?im)^(?<prefix>[^\r\n:=]*(?:Authorization|Headers?|Token|Secret|Password|Credential|ApiKey)[^\r\n:=]*[:=]\s*)(?<value>.+)$'

$script:AllowedWinGetArgumentSets = @(
    , @('--version')
    , @('source', 'list', '--disable-interactivity')
    , @('source', 'export', '--disable-interactivity')
)

$script:ForbiddenWinGetArgumentTokens = @(
    'add', 'edit', 'update', 'remove', 'reset', '--accept-source-agreements'
)

$script:DefaultWinGetLocator = {
    $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        $command = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($command) { return $command.Source }
    return $null
}

$script:DefaultWinGetInvoker = {
    param(
        [string] $ExePath,
        [string[]] $Arguments,
        [int] $TimeoutSec
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExePath
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        try { $process.Kill($true) } catch { }
        throw "WinGet command timed out after $TimeoutSec second(s)."
    }

    [pscustomobject]@{
        ExitCode       = $process.ExitCode
        StandardOutput = $stdoutTask.GetAwaiter().GetResult()
        StandardError  = $stderrTask.GetAwaiter().GetResult()
    }
}

function Write-WinGetModuleError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet] $Cmdlet,

        [Parameter(Mandatory = $true)]
        [string] $ErrorId,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $exception = [System.InvalidOperationException]::new("$($ErrorId): $Message")
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        $exception,
        $ErrorId,
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $null
    )
    $Cmdlet.ThrowTerminatingError($errorRecord)
}

function Get-PropertyValueOrNull {
    [CmdletBinding()]
    param(
        [Parameter()]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Find-WinGetExecutable {
    <#
    .SYNOPSIS
        Locates the winget executable using an injectable locator scriptblock,
        so tests never depend on WinGet actually being installed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [scriptblock] $Locator = $script:DefaultWinGetLocator
    )

    $found = & $Locator

    if ($found -is [array]) {
        $found = $found | Select-Object -First 1
    }

    if ([string]::IsNullOrWhiteSpace($found)) {
        Write-WinGetModuleError -Cmdlet $PSCmdlet -ErrorId 'WinGetExecutableNotFound' -Message 'winget.exe could not be located on this system.'
    }

    [string] $found
}

function Assert-AllowedWinGetArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet] $Cmdlet
    )

    foreach ($token in $ArgumentList) {
        if ($script:ForbiddenWinGetArgumentTokens -icontains $token) {
            Write-WinGetModuleError -Cmdlet $Cmdlet -ErrorId 'WinGetMutatingCommandBlocked' -Message "The argument '$token' is not permitted by the read-only WinGet invocation layer."
        }
    }

    $normalized = $ArgumentList -join ' '
    $isAllowed = $false
    foreach ($allowedSet in $script:AllowedWinGetArgumentSets) {
        if (($allowedSet -join ' ') -eq $normalized) {
            $isAllowed = $true
            break
        }
    }

    if (-not $isAllowed) {
        Write-WinGetModuleError -Cmdlet $Cmdlet -ErrorId 'WinGetMutatingCommandBlocked' -Message "The argument list '$normalized' is not an allowed read-only WinGet command."
    }
}

function Invoke-WinGetReadOnlyCommand {
    <#
    .SYNOPSIS
        Executes a whitelisted, read-only WinGet command through an injectable
        invoker, capturing exit code, standard output, and standard error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WinGetPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $ArgumentList,

        [Parameter()]
        [scriptblock] $Invoker = $script:DefaultWinGetInvoker,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int] $TimeoutSec = 60
    )

    Assert-AllowedWinGetArgument -ArgumentList $ArgumentList -Cmdlet $PSCmdlet

    $invocationResult = & $Invoker $WinGetPath $ArgumentList $TimeoutSec

    [pscustomobject]@{
        argumentList   = $ArgumentList
        exitCode       = $invocationResult.ExitCode
        standardOutput = $invocationResult.StandardOutput
        standardError  = $invocationResult.StandardError
        executedAtUtc  = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-TopLevelJsonSpan {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text
    )

    $spans = [System.Collections.Generic.List[string]]::new()
    $length = $Text.Length
    $depth = 0
    $inString = $false
    $escapeNext = $false
    $spanStart = -1

    for ($i = 0; $i -lt $length; $i++) {
        $ch = $Text[$i]

        if ($depth -eq 0 -and -not $inString) {
            if ($ch -eq '{' -or $ch -eq '[') {
                $spanStart = $i
                $depth = 1
            }
            continue
        }

        if ($inString) {
            if ($escapeNext) {
                $escapeNext = $false
            }
            elseif ($ch -eq '\') {
                $escapeNext = $true
            }
            elseif ($ch -eq '"') {
                $inString = $false
            }
            continue
        }

        switch ($ch) {
            '"' { $inString = $true }
            '{' { $depth++ }
            '[' { $depth++ }
            '}' {
                $depth--
                if ($depth -eq 0) {
                    $spans.Add($Text.Substring($spanStart, $i - $spanStart + 1))
                    $spanStart = -1
                }
            }
            ']' {
                $depth--
                if ($depth -eq 0) {
                    $spans.Add($Text.Substring($spanStart, $i - $spanStart + 1))
                    $spanStart = -1
                }
            }
        }
    }

    $spans.ToArray()
}

function ConvertFrom-WinGetSourceExport {
    <#
    .SYNOPSIS
        Parses the JSON produced by 'winget source export', accepting a single
        object, a JSON array, concatenated objects, or newline-separated
        objects, optionally surrounded by warning text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RawExport
    )

    $spans = @(Get-TopLevelJsonSpan -Text $RawExport)

    if ($spans.Count -eq 0) {
        Write-WinGetModuleError -Cmdlet $PSCmdlet -ErrorId 'WinGetSourceExportParseFailed' -Message 'No JSON content was found in the WinGet source export output.'
    }

    $parsedObjects = [System.Collections.Generic.List[object]]::new()

    foreach ($span in $spans) {
        try {
            $parsed = ConvertFrom-Json -InputObject $span -ErrorAction Stop
        }
        catch {
            Write-WinGetModuleError -Cmdlet $PSCmdlet -ErrorId 'WinGetSourceExportParseFailed' -Message "Failed to parse a JSON fragment from the WinGet source export output: $($_.Exception.Message)"
        }

        if ($null -eq $parsed) {
            continue
        }

        if ($parsed -is [array]) {
            foreach ($item in $parsed) {
                if ($null -ne $item) {
                    $parsedObjects.Add($item)
                }
            }
        }
        else {
            $parsedObjects.Add($parsed)
        }
    }

    if ($parsedObjects.Count -eq 0) {
        Write-WinGetModuleError -Cmdlet $PSCmdlet -ErrorId 'WinGetSourceExportParseFailed' -Message 'No source objects were found in the WinGet source export output.'
    }

    foreach ($obj in $parsedObjects) {
        [pscustomobject]@{
            arg               = Get-PropertyValueOrNull -InputObject $obj -Name 'Arg'
            data              = Get-PropertyValueOrNull -InputObject $obj -Name 'Data'
            explicit          = Get-PropertyValueOrNull -InputObject $obj -Name 'Explicit'
            identifier        = Get-PropertyValueOrNull -InputObject $obj -Name 'Identifier'
            name              = Get-PropertyValueOrNull -InputObject $obj -Name 'Name'
            trustLevel        = Get-PropertyValueOrNull -InputObject $obj -Name 'TrustLevel'
            type              = Get-PropertyValueOrNull -InputObject $obj -Name 'Type'
            acquisitionMethod = 'WinGetSourceExport'
            confidence        = 'Full'
            rawLine           = $null
        }
    }
}

function ConvertFrom-WinGetSourceList {
    <#
    .SYNOPSIS
        Fallback parser for 'winget source list' free-text output. Extracts an
        http/https URL or a UNC path from each line without depending on
        column headers, so it works across locales.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RawList
    )

    $combinedPattern = '(?:https?://\S+)|(?:\\\\\S+)'
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($line in ($RawList -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $lineMatches = [regex]::Matches($line, $combinedPattern)
        if ($lineMatches.Count -eq 0) {
            continue
        }

        $confidence = if ($lineMatches.Count -eq 1) { 'Full' } else { 'Partial' }

        $results.Add([pscustomobject]@{
            arg               = $lineMatches[0].Value
            data              = $null
            explicit          = $null
            identifier        = $null
            name              = $null
            trustLevel        = $null
            type              = $null
            acquisitionMethod = 'WinGetSourceListFallback'
            confidence        = $confidence
            rawLine           = $line
        })
    }

    $results.ToArray()
}

function Get-WinGetConfiguredSources {
    <#
    .SYNOPSIS
        Discovers the WinGet sources configured on this machine using only
        read-only commands, preferring the structured 'source export' output
        and falling back to 'source list' text parsing when export fails.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $WinGetPath,

        [Parameter()]
        [scriptblock] $Invoker,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int] $TimeoutSec = 60
    )

    if (-not $PSBoundParameters.ContainsKey('WinGetPath') -or [string]::IsNullOrWhiteSpace($WinGetPath)) {
        $WinGetPath = Find-WinGetExecutable
    }

    $invokeParams = @{
        WinGetPath = $WinGetPath
        TimeoutSec = $TimeoutSec
    }
    if ($PSBoundParameters.ContainsKey('Invoker')) {
        $invokeParams['Invoker'] = $Invoker
    }

    $versionResult = Invoke-WinGetReadOnlyCommand @invokeParams -ArgumentList @('--version')
    $listResult = Invoke-WinGetReadOnlyCommand @invokeParams -ArgumentList @('source', 'list', '--disable-interactivity')
    $exportResult = Invoke-WinGetReadOnlyCommand @invokeParams -ArgumentList @('source', 'export', '--disable-interactivity')

    $sources = $null
    $acquisitionMethod = $null

    if ($exportResult.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($exportResult.standardOutput)) {
        try {
            $sources = @(ConvertFrom-WinGetSourceExport -RawExport $exportResult.standardOutput)
            $acquisitionMethod = 'WinGetSourceExport'
        }
        catch {
            Write-Verbose "WinGet source export parsing failed, falling back to source list: $($_.Exception.Message)"
            $sources = $null
        }
    }

    if (-not $sources -or $sources.Count -eq 0) {
        if ($listResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($listResult.standardOutput)) {
            Write-WinGetModuleError -Cmdlet $PSCmdlet -ErrorId 'WinGetSourcesUnavailable' -Message 'Neither WinGet source export nor source list produced usable output.'
        }

        $sources = @(ConvertFrom-WinGetSourceList -RawList $listResult.standardOutput)
        $acquisitionMethod = 'WinGetSourceListFallback'

        if ($sources.Count -eq 0) {
            Write-WinGetModuleError -Cmdlet $PSCmdlet -ErrorId 'WinGetSourcesUnavailable' -Message 'No sources could be parsed from WinGet source list output.'
        }
    }

    $evidence = Protect-WinGetEvidence -Evidence ([ordered]@{
        version = $versionResult
        list    = $listResult
        export  = $exportResult
    })

    [pscustomobject]@{
        winGetPath        = $WinGetPath
        winGetVersion     = ([string] $versionResult.standardOutput).Trim()
        retrievedAtUtc    = [DateTime]::UtcNow.ToString('o')
        acquisitionMethod = $acquisitionMethod
        sources           = $sources
        evidence          = $evidence
    }
}

function Protect-WinGetEvidenceValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        $Value
    )

    if ($null -eq $Value) {
        return $Value
    }

    if ($Value -is [string]) {
        $evaluator = { param($m) $m.Groups['prefix'].Value + $script:MaskedValueText }
        return [regex]::Replace($Value, $script:SensitiveInlinePattern, [System.Text.RegularExpressions.MatchEvaluator] $evaluator)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $masked = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if ($key -match $script:SensitiveEvidenceKeyPattern) {
                $masked[$key] = $script:MaskedValueText
            }
            else {
                $masked[$key] = Protect-WinGetEvidenceValue -Value $Value[$key]
            }
        }
        return [pscustomobject] $masked
    }

    if (($Value -is [System.Collections.IEnumerable]) -and (-not ($Value -is [string]))) {
        return @(foreach ($item in $Value) { Protect-WinGetEvidenceValue -Value $item })
    }

    if ($Value -is [pscustomobject]) {
        $maskedProps = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match $script:SensitiveEvidenceKeyPattern) {
                $maskedProps[$property.Name] = $script:MaskedValueText
            }
            else {
                $maskedProps[$property.Name] = Protect-WinGetEvidenceValue -Value $property.Value
            }
        }
        return [pscustomobject] $maskedProps
    }

    return $Value
}

function Protect-WinGetEvidence {
    <#
    .SYNOPSIS
        Recursively masks values associated with sensitive keys (Authorization,
        Header(s), Token, Secret, Password, Credential, ApiKey) in captured
        WinGet command evidence, whether structured or free text.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Evidence
    )

    Protect-WinGetEvidenceValue -Value $Evidence
}

Export-ModuleMember -Function Find-WinGetExecutable, Invoke-WinGetReadOnlyCommand, ConvertFrom-WinGetSourceExport, ConvertFrom-WinGetSourceList, Get-WinGetConfiguredSources, Protect-WinGetEvidence
