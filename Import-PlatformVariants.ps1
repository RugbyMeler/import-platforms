[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PVWAURL,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "Source platform ZIP does not exist: $_"
        }
        if ([System.IO.Path]::GetExtension($_) -ne '.zip') {
            throw 'SourcePlatformZip must point to a ZIP file.'
        }
        $true
    })]
    [string]$SourcePlatformZip,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePlatformId,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "Configuration file does not exist: $_"
        }
        if ([System.IO.Path]::GetExtension($_) -ne '.json') {
            throw 'ConfigurationFile must point to a JSON file.'
        }
        $true
    })]
    [string]$ConfigurationFile,

    [Parameter()]
    [ValidateSet('CyberArk', 'LDAP', 'RADIUS', 'Windows', 'PKI', 'SAML')]
    [string]$Type = 'CyberArk',

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$OTP,

    [Parameter()]
    [string]$ReportPath = (Join-Path -Path $PSScriptRoot -ChildPath ("PlatformImport-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [Parameter()]
    [switch]$SkipCertificateCheck,

    [Parameter()]
    [switch]$ContinueOnError,

    [Parameter()]
    [switch]$KeepSessionOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timeStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'WARNING' { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
    }
    Write-Host "[$timeStamp] [$Level] $Message" -ForegroundColor $color
}

function Get-PlatformTargetRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlatformId
    )

    $results = @(Get-PASPlatform -Search $PlatformId -ErrorAction Stop)
    $exactMatches = @(
        $results | Where-Object {
            ($null -ne $_.PSObject.Properties['PlatformID'] -and $_.PlatformID -eq $PlatformId) -or
            ($null -ne $_.PSObject.Properties['PlatformId'] -and $_.PlatformId -eq $PlatformId) -or
            ($null -ne $_.PSObject.Properties['PlatformBaseID'] -and $_.PlatformBaseID -eq $PlatformId) -or
            ($null -ne $_.PSObject.Properties['Name'] -and $_.Name -eq $PlatformId)
        }
    )

    if ($exactMatches.Count -gt 1) {
        throw "More than one exact platform match was returned for '$PlatformId'."
    }
    if ($exactMatches.Count -eq 1) {
        return $exactMatches[0]
    }
    return $null
}

function Wait-ForPlatform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlatformId,

        [Parameter()]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 60,

        [Parameter()]
        [ValidateRange(1, 30)]
        [int]$PollIntervalSeconds = 3
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $platform = Get-PlatformTargetRecord -PlatformId $PlatformId
            if ($null -ne $platform) {
                $stopwatch.Stop()
                return $platform
            }
        }
        catch {
            Write-Verbose "Platform lookup failed while waiting: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    $stopwatch.Stop()
    throw "Platform '$PlatformId' was not returned within $TimeoutSeconds seconds."
}

function Get-PlatformNumericId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Platform
    )

    $possibleProperties = @('ID', 'Id', 'id', 'PlatformNumericID', 'PlatformNumericId')
    foreach ($propertyName in $possibleProperties) {
        $property = $Platform.PSObject.Properties[$propertyName]
        if (
            $null -ne $property -and
            $null -ne $property.Value -and
            -not [System.String]::IsNullOrWhiteSpace([string]$property.Value)
        ) {
            $numericId = 0
            if ([System.Int32]::TryParse([string]$property.Value, [ref]$numericId)) {
                return $numericId
            }
        }
    }

    $returnedProperties = $Platform.PSObject.Properties.Name -join ', '
    throw "The numeric platform ID could not be determined. Returned properties: $returnedProperties"
}

function ConvertTo-PatchOperations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Settings
    )

    $operations = @()
    foreach ($setting in $Settings) {
        if ([System.String]::IsNullOrWhiteSpace([string]$setting.Path)) {
            throw 'Every setting must contain a Path value.'
        }

        $operation = if ([System.String]::IsNullOrWhiteSpace([string]$setting.Operation)) {
            'replace'
        }
        else {
            [string]$setting.Operation
        }

        if ($operation -notin @('replace', 'remove')) {
            throw "Unsupported operation '$operation' for path '$($setting.Path)'."
        }

        $patchOperation = @{
            op   = $operation
            path = [string]$setting.Path
        }

        if ($operation -eq 'replace') {
            if ($null -eq $setting.PSObject.Properties['Value']) {
                throw "Setting '$($setting.Path)' uses replace but has no Value property."
            }
            $patchOperation['value'] = [string]$setting.Value
        }
        $operations += $patchOperation
    }
    return $operations
}

function Set-PlatformDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$NumericPlatformId,

        [Parameter(Mandatory = $true)]
        [object]$PlatformConfiguration
    )

    if ($null -ne $PlatformConfiguration.Settings -and @($PlatformConfiguration.Settings).Count -gt 0) {
        $operations = ConvertTo-PatchOperations -Settings @($PlatformConfiguration.Settings)
        Write-Log "Applying $($operations.Count) setting change(s)."
        Set-PASPlatform -Id $NumericPlatformId -Operations $operations -Confirm:$false -WhatIf:$WhatIfPreference
    }

    if ($null -ne $PlatformConfiguration.PSM) {
        $psmParameters = @{
            ID      = $NumericPlatformId
            Confirm = $false
            WhatIf  = $WhatIfPreference
        }

        if (-not [System.String]::IsNullOrWhiteSpace([string]$PlatformConfiguration.PSM.PSMServerID)) {
            $psmParameters['PSMServerID'] = [string]$PlatformConfiguration.PSM.PSMServerID
        }

        if ($null -ne $PlatformConfiguration.PSM.Connectors) {
            $connectors = @()
            foreach ($connector in @($PlatformConfiguration.PSM.Connectors)) {
                if ([System.String]::IsNullOrWhiteSpace([string]$connector.PSMConnectorID)) {
                    throw 'Each PSM connector must contain PSMConnectorID.'
                }
                $connectors += [PSCustomObject]@{
                    PSMConnectorID = [string]$connector.PSMConnectorID
                    Enabled        = [bool]$connector.Enabled
                }
            }
            $psmParameters['PSMConnectors'] = $connectors
        }

        Write-Log 'Applying PSM configuration.'
        Set-PASPlatformPSMConfig @psmParameters
    }
}

function Test-PlatformConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Platforms
    )

    $seenPlatformIds = @{}
    foreach ($platform in $Platforms) {
        if ([System.String]::IsNullOrWhiteSpace([string]$platform.PlatformId)) {
            throw 'Every platform entry must contain PlatformId.'
        }
        if ([System.String]::IsNullOrWhiteSpace([string]$platform.PlatformName)) {
            throw "Platform '$($platform.PlatformId)' does not contain PlatformName."
        }

        $normalizedId = ([string]$platform.PlatformId).ToLowerInvariant()
        if ($seenPlatformIds.ContainsKey($normalizedId)) {
            throw "Duplicate PlatformId found: $($platform.PlatformId)"
        }
        $seenPlatformIds[$normalizedId] = $true
    }
}

$sessionCreated = $false
$report = [System.Collections.Generic.List[object]]::new()

try {
    Write-Log 'Checking psPAS module.'
    if (-not (Get-Module -ListAvailable -Name psPAS)) {
        throw 'The psPAS module is not installed. Run: Install-Module psPAS -Scope CurrentUser'
    }

    Import-Module psPAS -ErrorAction Stop
    $module = Get-Module psPAS
    Write-Log "Using psPAS version $($module.Version)."

    Write-Log 'Reading platform configuration.'
    try {
        $configuration = Get-Content -LiteralPath $ConfigurationFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Could not read configuration file '$ConfigurationFile'. $($_.Exception.Message)"
    }

    $platforms = @($configuration.Platforms)
    if ($platforms.Count -eq 0) {
        throw 'The configuration does not contain any Platforms entries.'
    }
    Test-PlatformConfiguration -Platforms $platforms

    if ($null -eq $Credential) {
        $Credential = Get-Credential -Message 'Enter the CyberArk Vault credentials'
    }

    $sessionParameters = @{
        BaseURI    = $PVWAURL.TrimEnd('/')
        Credential = $Credential
        Type       = $Type
    }
    if (-not [System.String]::IsNullOrWhiteSpace($OTP)) {
        $sessionParameters['OTP'] = $OTP
    }
    if ($SkipCertificateCheck) {
        $sessionParameters['SkipCertificateCheck'] = $true
    }

    Write-Log 'Connecting to CyberArk PVWA.'
    New-PASSession @sessionParameters
    $sessionCreated = $true
    Write-Log 'Connected to CyberArk PVWA.' -Level SUCCESS

    Write-Log "Checking source platform '$SourcePlatformId'."
    $sourcePlatform = Get-PlatformTargetRecord -PlatformId $SourcePlatformId

    if ($null -eq $sourcePlatform) {
        Write-Log "Source platform does not exist. Importing '$SourcePlatformZip'."
        if ($PSCmdlet.ShouldProcess($SourcePlatformZip, 'Import source CyberArk platform package')) {
            Import-PASPlatform -ImportFile $SourcePlatformZip -Confirm:$false
        }

        if ($WhatIfPreference) {
            Write-Log 'WhatIf mode enabled. Source platform was not imported, so variant processing cannot continue.' -Level WARNING
            return
        }

        $sourcePlatform = Wait-ForPlatform -PlatformId $SourcePlatformId
        Write-Log "Source platform '$SourcePlatformId' imported." -Level SUCCESS
    }
    else {
        Write-Log "Source platform '$SourcePlatformId' already exists. ZIP import skipped." -Level WARNING
    }

    foreach ($platformConfiguration in $platforms) {
        $newPlatformId = [string]$platformConfiguration.PlatformId
        $newPlatformName = [string]$platformConfiguration.PlatformName
        $description = [string]$platformConfiguration.Description
        $startTime = Get-Date
        $status = 'Started'
        $message = ''
        $numericPlatformId = $null

        try {
            Write-Log "Processing platform '$newPlatformId'."
            if ($newPlatformId.Equals($SourcePlatformId, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Target PlatformId '$newPlatformId' is the same as SourcePlatformId '$SourcePlatformId'."
            }

            $targetPlatform = Get-PlatformTargetRecord -PlatformId $newPlatformId
            if ($null -eq $targetPlatform) {
                Write-Log "Creating side-by-side platform '$newPlatformId'."
                $importParameters = @{
                    PlatformId   = $newPlatformId
                    PlatformName = $newPlatformName
                    Confirm      = $false
                    WhatIf       = $WhatIfPreference
                }
                if (-not [System.String]::IsNullOrWhiteSpace($description)) {
                    $importParameters['Description'] = $description
                }

                if ($PSCmdlet.ShouldProcess($newPlatformId, "Create side-by-side platform from '$SourcePlatformId'")) {
                    Import-PASPlatform @importParameters
                }

                if ($WhatIfPreference) {
                    $status = 'WhatIf'
                    $message = "Platform would be created from source '$SourcePlatformId'."
                    Write-Log $message -Level WARNING
                    continue
                }

                $targetPlatform = Wait-ForPlatform -PlatformId $newPlatformId
                Write-Log "Platform '$newPlatformId' created." -Level SUCCESS
            }
            else {
                $applyChangesIfExists = $false
                if ($null -ne $platformConfiguration.PSObject.Properties['ApplyChangesIfPlatformExists']) {
                    $applyChangesIfExists = [bool]$platformConfiguration.ApplyChangesIfPlatformExists
                }
                if (-not $applyChangesIfExists) {
                    $status = 'Skipped'
                    $message = 'Platform already exists and ApplyChangesIfPlatformExists is false.'
                    Write-Log $message -Level WARNING
                    continue
                }
                Write-Log 'Platform already exists. Applying configured changes.' -Level WARNING
            }

            $numericPlatformId = Get-PlatformNumericId -Platform $targetPlatform
            Write-Log "Numeric platform ID is '$numericPlatformId'."
            Set-PlatformDifferences -NumericPlatformId $numericPlatformId -PlatformConfiguration $platformConfiguration

            $enablePlatform = $false
            if ($null -ne $platformConfiguration.PSObject.Properties['Enable']) {
                $enablePlatform = [bool]$platformConfiguration.Enable
            }
            if ($enablePlatform) {
                Write-Log "Enabling platform '$newPlatformId'."
                Enable-PASPlatform -TargetPlatform -Id $numericPlatformId -Confirm:$false -WhatIf:$WhatIfPreference
            }

            $status = if ($WhatIfPreference) { 'WhatIf' } else { 'Completed' }
            $message = 'Platform processing completed.'
            Write-Log "Platform '$newPlatformId' completed." -Level SUCCESS
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            Write-Log "Platform '$newPlatformId' failed. $message" -Level ERROR
            if (-not $ContinueOnError) {
                throw
            }
        }
        finally {
            $endTime = Get-Date
            $report.Add([PSCustomObject]@{
                PlatformId       = $newPlatformId
                PlatformName     = $newPlatformName
                NumericId        = $numericPlatformId
                SourcePlatformId = $SourcePlatformId
                Status           = $status
                Message          = $message
                Started          = $startTime
                Finished         = $endTime
                DurationSeconds  = [System.Math]::Round(($endTime - $startTime).TotalSeconds, 2)
            })
        }
    }
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    throw
}
finally {
    if ($report.Count -gt 0) {
        try {
            $reportDirectory = Split-Path -Path $ReportPath -Parent
            if (-not [System.String]::IsNullOrWhiteSpace($reportDirectory) -and -not (Test-Path -LiteralPath $reportDirectory)) {
                New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
            }
            $report | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
            Write-Log "Execution report written to '$ReportPath'."
        }
        catch {
            Write-Log "Could not write execution report. $($_.Exception.Message)" -Level ERROR
        }
    }

    if ($sessionCreated -and -not $KeepSessionOpen) {
        try {
            Close-PASSession
            Write-Log 'CyberArk session closed.'
        }
        catch {
            Write-Log "Could not close the CyberArk session. $($_.Exception.Message)" -Level WARNING
        }
    }
}
