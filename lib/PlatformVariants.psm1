#Requires -Version 5.1
<#
    PlatformVariants.psm1
    Engine shared by Import-PlatformVariants.ps1 (command line) and Start-PlatformImportGui.ps1 (GUI).

    Creates "variant" copies of a CyberArk platform package and applies per-variant differences:
      1. make sure the source platform exists (import the ZIP when it does not)
      2. upload the ZIP again so PVWA holds it in memory (it conflicts with the existing platform)
      3. import the held package side by side under a new platform ID and name   (PVWA 14.6+)
      4. apply setting changes                                                   (PVWA 15.2+)
      5. apply PSM configuration and the active/inactive state
#>

Set-StrictMode -Version Latest

$script:AuthTypes = @('CyberArk', 'LDAP', 'RADIUS', 'Windows')
$script:PlatformStates = @('Unchanged', 'Active', 'Inactive')
$script:SettingOperations = @('replace', 'remove')

# Naming convention: the suffixes that turn one custom name into the standard set of platforms
# for a vault type ("MyApp" + "-PROD" = "MyApp-PROD"). Change the convention here; the GUI switch,
# the command line and the tests all read this table.
$script:NamingSchemes = [ordered]@{
    Human   = @('-PROD', '-PrePROD', '-PROD-MAN', '-PrePROD-MAN')
    Machine = @('-PROD-D', '-PrePROD-D', '-PROD-RT-RL', '-PROD-RT-RS', '-PrePROD-RT-RL', '-PrePROD-RT-RS')
}
$script:EventSink = $null
$script:LogFile = $null

# Setting paths offered as suggestions in the editor. Free text is always accepted, because the
# valid set depends on the PVWA version and on the platform itself.
$script:KnownSettingPaths = @(
    'General/name'
    'General/description'
    'General/status'
    'General/platformBaseId'
    'General/platformBaseProtocol'
    'General/platformBaseType'
    'Policy/General/policyType'
    'Policy/General/immediateInterval'
    'Policy/General/interval'
    'Policy/General/maxConcurrentConnections'
    'Policy/General/searchForUsages'
    'Policy/General/looselyConnectedDevices'
    'Policy/General/allowedSafes'
    'Policy/cpmPlugin/dllName'
    'Policy/cpmPlugin/exeName'
    'Policy/cpmPlugin/scriptName'
    'Policy/cpmPlugin/scriptEngine'
    'Policy/cpmPlugin/xmlFile'
    'Policy/cpmPlugin/activationMethod'
    'Policy/cpmPlugin/protocolValidationEx'
    'Policy/cpmPlugin/protocolValidationFileCategories'
    'Policy/cpmPlugin/supportedBitness'
    'Policy/cpmPlugin/supportedTechnology'
    'Policy/additionalPolicySettings/promptsFilename'
    'Policy/additionalPolicySettings/processFilename'
    'Policy/additionalPolicySettings/port'
    'Policy/additionalPolicySettings/protocol'
    'Policy/additionalPolicySettings/changeCommand'
    'Policy/additionalPolicySettings/reconcileCommand'
    'Policy/additionalPolicySettings/connectionCommand'
    'Policy/additionalPolicySettings/dsn'
    'Policy/additionalPolicySettings/reconcileIsWinAccount'
    'Policy/additionalPolicySettings/reconcileWinExtraConnectionString'
    'Policy/additionalPolicySettings/useSsl'
    'Policy/additionalPolicySettings/restartAppPool'
    'Policy/additionalPolicySettings/commit'
    'Policy/additionalPolicySettings/debug'
    'Policy/additionalPolicySettings/disableAddressResolving'
    'Policy/additionalPolicySettings/verifyMachineNameBeforeAction'
    'Policy/additionalPolicySettings/wmiCommandStatementFile'
    'Policy/additionalPolicySettings/wmiReconcileCommandStatementFile'
    'Policy/additionalPolicySettings/wmiRegistryReturnCodePath'
    'Policy/additionalPolicySettings/unlockUserOnReconcile'
    'Policy/additionalPolicySettings/changePasswordInResetMode'
    'Policy/additionalPolicySettings/convertFqdnToIP'
    'Policy/additionalPolicySettings/commandForbiddenCharacters'
    'Policy/additionalPolicySettings/commandBlackList'
    'Policy/additionalPolicySettings/allowDomainUserAdHocAccess'
    'Policy/additionalPolicySettings/domainUserAdHocAccessLimit'
    'Policy/additionalPolicySettings/adHocConnectionTimeout'
    'Policy/additionalPolicySettings/adHocUserNamePrefix'
    'Policy/additionalPolicySettings/adHocUserNameSuffix'
)

#region Small helpers ------------------------------------------------------------------------

function Get-ObjectProperty {
    # Reads a property from a PSCustomObject or a dictionary without tripping StrictMode.
    param($InputObject, [string]$Name, $Default = $null)

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            if ([string]$key -ieq $Name) { return $InputObject[$key] }
        }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-ObjectList {
    # Same as Get-ObjectProperty but always returns an array (never $null, never a bare scalar).
    param($InputObject, [string]$Name)

    $value = Get-ObjectProperty -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return , @() }
    if ($value -is [string] -or $value -is [System.Collections.IDictionary]) { return , @($value) }
    return , @($value | Where-Object { $null -ne $_ })
}

function Test-ObjectProperty {
    param($InputObject, [string]$Name)

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) {
            if ([string]$key -ieq $Name) { return $true }
        }
        return $false
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function ConvertTo-Boolean {
    param($Value, [bool]$Default = $false)

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if ($text -match '^(true|yes|on|1)$') { return $true }
    if ($text -match '^(false|no|off|0)$') { return $false }
    return $Default
}

function ConvertTo-SettingText {
    # JSON true/false become 'true'/'false' rather than PowerShell's 'True'/'False'.
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return ([string]$Value).ToLowerInvariant() }
    return [string]$Value
}

function Resolve-ExistingFile {
    param([string]$Path, [string]$Label, [string]$Extension)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is required." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label does not exist: $Path" }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    if ($Extension -and [System.IO.Path]::GetExtension($resolved) -ine $Extension) {
        throw "$Label must be a $Extension file: $Path"
    }
    return $resolved
}

function Resolve-PvwaBaseUri {
    <#
        .SYNOPSIS
        Normalises what people paste as "the PVWA address" into the base URI psPAS expects
        (scheme and host, without /PasswordVault).
    #>
    [CmdletBinding()]
    param([string]$Url)

    $text = ([string]$Url).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'The PVWA address is required.' }
    if ($text -notmatch '^[a-zA-Z][a-zA-Z0-9+.\-]*://') { $text = "https://$text" }

    $uri = $null
    if (-not [System.Uri]::TryCreate($text, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('https', 'http') -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "The PVWA address '$Url' is not a valid http(s) address."
    }

    $path = $uri.AbsolutePath.TrimEnd('/') -replace '(?i)/PasswordVault(/.*)?$', ''
    return ($uri.GetLeftPart([System.UriPartial]::Authority) + $path)
}

#endregion

#region Persistent settings ------------------------------------------------------------------

function Get-PlatformImportSettingsPath {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:IMPORTPLATFORMS_SETTINGS)) {
        return $env:IMPORTPLATFORMS_SETTINGS
    }
    return (Join-Path -Path ([System.Environment]::GetFolderPath('ApplicationData')) -ChildPath 'ImportPlatforms\settings.json')
}

function Get-PlatformImportSettingDefaults {
    # Only the keys listed here are ever written to disk. Passwords and OTPs are deliberately absent.
    return [ordered]@{
        PVWAURL              = ''
        AuthType             = 'CyberArk'
        Username             = ''
        OTPMode              = ''
        ConcurrentSession    = $true
        SkipCertificateCheck = $false
        SourcePlatformZip    = ''
        SourcePlatformId     = ''
        ConfigurationFile    = ''
        VariantSource        = 'Human'      # Human, Machine (naming scheme) or File (ConfigurationFile)
        CustomName           = ''
        ReportFolder         = ''
        ContinueOnError      = $false
        DryRun               = $false
        EditorFile           = ''
        WindowWidth          = 0
        WindowHeight         = 0
        WindowLeft           = -1
        WindowTop            = -1
        WindowMaximized      = $false
    }
}

function Get-PlatformImportSettings {
    <#
        .SYNOPSIS
        Returns the saved settings merged over the defaults. Never throws: a missing or damaged
        file simply yields the defaults.
    #>
    [CmdletBinding()]
    param([string]$Path = (Get-PlatformImportSettingsPath))

    $settings = Get-PlatformImportSettingDefaults
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $settings }

    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Settings file '$Path' could not be read: $($_.Exception.Message)"
        return $settings
    }

    foreach ($key in @($settings.Keys)) {
        if (-not (Test-ObjectProperty -InputObject $saved -Name $key)) { continue }
        $value = Get-ObjectProperty -InputObject $saved -Name $key
        $default = $settings[$key]
        if ($default -is [bool]) {
            $settings[$key] = ConvertTo-Boolean -Value $value -Default $default
        }
        elseif ($default -is [int]) {
            $number = 0.0
            if ([double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$number)) {
                $settings[$key] = [int][System.Math]::Round($number)
            }
        }
        elseif ($null -ne $value) {
            $settings[$key] = [string]$value
        }
    }
    return $settings
}

function Save-PlatformImportSettings {
    <#
        .SYNOPSIS
        Saves the given values over what is already stored. Unknown keys are ignored, so a
        password can never end up in the file by accident.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Settings,

        [string]$Path = (Get-PlatformImportSettingsPath)
    )

    $merged = Get-PlatformImportSettings -Path $Path
    foreach ($key in @($merged.Keys)) {
        if (-not (Test-ObjectProperty -InputObject $Settings -Name $key)) { continue }
        $value = Get-ObjectProperty -InputObject $Settings -Name $key
        $default = $merged[$key]
        if ($default -is [bool]) { $merged[$key] = ConvertTo-Boolean -Value $value -Default $default }
        elseif ($default -is [int]) { $merged[$key] = [int][System.Math]::Round([double]$value) }
        else { $merged[$key] = [string]$value }
    }

    $directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    # Write next to the target and swap, so a crash mid-write cannot leave a half file behind.
    $temporary = "$Path.tmp"
    $json = ConvertTo-PrettyJson -Value $merged
    [System.IO.File]::WriteAllText($temporary, $json + [System.Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force -WhatIf:$false
}

#endregion

#region JSON writer --------------------------------------------------------------------------

function ConvertTo-JsonString {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        switch ($character) {
            '"' { [void]$builder.Append('\"') }
            '\' { [void]$builder.Append('\\') }
            "`n" { [void]$builder.Append('\n') }
            "`r" { [void]$builder.Append('\r') }
            "`t" { [void]$builder.Append('\t') }
            default {
                if ([int]$character -lt 32) { [void]$builder.AppendFormat('\u{0:x4}', [int]$character) }
                else { [void]$builder.Append($character) }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-PrettyJson {
    <#
        .SYNOPSIS
        Two-space indented JSON with stable key order. Windows PowerShell's ConvertTo-Json output
        is valid but awkward to read and to diff, and this file is meant to be edited by hand too.
    #>
    param($Value, [int]$Level = 0)

    $indent = '  ' * $Level
    $inner = '  ' * ($Level + 1)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return ([string]$Value).ToLowerInvariant() }
    if ($Value -is [string] -or $Value -is [char]) { return (ConvertTo-JsonString -Text ([string]$Value)) }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([System.IConvertible]$Value).ToString([cultureinfo]::InvariantCulture)
    }

    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = New-Object System.Collections.Generic.List[string]
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in @($Value.Keys)) {
                $pairs.Add($inner + (ConvertTo-JsonString -Text ([string]$key)) + ': ' + (ConvertTo-PrettyJson -Value $Value[$key] -Level ($Level + 1)))
            }
        }
        else {
            foreach ($property in $Value.PSObject.Properties) {
                $pairs.Add($inner + (ConvertTo-JsonString -Text $property.Name) + ': ' + (ConvertTo-PrettyJson -Value $property.Value -Level ($Level + 1)))
            }
        }
        if ($pairs.Count -eq 0) { return '{}' }
        return "{`r`n" + ($pairs -join ",`r`n") + "`r`n$indent}"
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            $items.Add($inner + (ConvertTo-PrettyJson -Value $item -Level ($Level + 1)))
        }
        if ($items.Count -eq 0) { return '[]' }
        return "[`r`n" + ($items -join ",`r`n") + "`r`n$indent]"
    }

    return (ConvertTo-JsonString -Text ([string]$Value))
}

#endregion

#region Platform package ---------------------------------------------------------------------

function Get-PlatformPackageInfo {
    <#
        .SYNOPSIS
        Reads the platform ID and name out of a CyberArk platform ZIP without importing it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-ExistingFile -Path $Path -Label 'Source platform ZIP' -Extension '.zip'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $platformId = $null
    $platformName = $null
    $entryNames = @()

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($resolved)
    }
    catch {
        throw "'$resolved' is not a readable ZIP archive. $($_.Exception.Message)"
    }

    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })

        $readEntry = {
            param($Entry)
            $reader = New-Object System.IO.StreamReader($Entry.Open())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }

        $iniEntry = $archive.Entries | Where-Object { $_.Name -like 'Policy-*.ini' } | Select-Object -First 1
        if ($null -eq $iniEntry) {
            $iniEntry = $archive.Entries | Where-Object { $_.Name -like '*.ini' } | Select-Object -First 1
        }
        if ($null -ne $iniEntry) {
            $text = & $readEntry $iniEntry
            $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline'
            $match = [regex]::Match($text, '^[ \t]*PolicyID[ \t]*=[ \t]*([^;\r\n]*)', $options)
            if ($match.Success) { $platformId = $match.Groups[1].Value.Trim() }
            $match = [regex]::Match($text, '^[ \t]*PolicyName[ \t]*=[ \t]*([^;\r\n]*)', $options)
            if ($match.Success) { $platformName = $match.Groups[1].Value.Trim() }
        }

        if ([string]::IsNullOrWhiteSpace($platformId)) {
            $xmlEntry = $archive.Entries | Where-Object { $_.Name -like 'Policy-*.xml' } | Select-Object -First 1
            if ($null -ne $xmlEntry) {
                $text = & $readEntry $xmlEntry
                $match = [regex]::Match($text, '<Policy\b[^>]*?\bID\s*=\s*"([^"]+)"', 'IgnoreCase')
                if ($match.Success) { $platformId = $match.Groups[1].Value.Trim() }
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($platformId)) { $platformId = $null }
    if ([string]::IsNullOrWhiteSpace($platformName)) { $platformName = $null }

    return [PSCustomObject]@{
        Path         = $resolved
        SizeBytes    = (Get-Item -LiteralPath $resolved).Length
        PlatformId   = $platformId
        PlatformName = $platformName
        Entries      = $entryNames
    }
}

#endregion

#region Variant configuration ----------------------------------------------------------------

function ConvertTo-PlatformVariant {
    <#
        .SYNOPSIS
        Turns one raw "Platforms" entry (from JSON or from the editor) into the normalised shape
        used everywhere else. Every optional field gets a value, so callers never have to guess.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Entry
    )

    $knownProperties = @('PlatformId', 'PlatformName', 'Description', 'State', 'Enable', 'ApplyChangesIfPlatformExists', 'Settings', 'PSM')

    # State replaces the old boolean "Enable": true meant activate, false meant leave alone.
    $state = 'Unchanged'
    if (Test-ObjectProperty -InputObject $Entry -Name 'State') {
        $rawState = ([string](Get-ObjectProperty -InputObject $Entry -Name 'State')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rawState)) {
            $state = $rawState
            foreach ($candidate in $script:PlatformStates) {
                if ($candidate -ieq $rawState) { $state = $candidate }
            }
        }
    }
    elseif (ConvertTo-Boolean -Value (Get-ObjectProperty -InputObject $Entry -Name 'Enable')) {
        $state = 'Active'
    }

    $settings = New-Object System.Collections.Generic.List[object]
    foreach ($setting in (Get-ObjectList -InputObject $Entry -Name 'Settings')) {
        $operation = ([string](Get-ObjectProperty -InputObject $setting -Name 'Operation')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($operation)) { $operation = 'replace' }
        $path = ([string](Get-ObjectProperty -InputObject $setting -Name 'Path')).Trim().TrimStart('/')
        $value = $null
        if (Test-ObjectProperty -InputObject $setting -Name 'Value') {
            $value = ConvertTo-SettingText -Value (Get-ObjectProperty -InputObject $setting -Name 'Value')
        }
        $settings.Add([PSCustomObject]@{ Operation = $operation; Path = $path; Value = $value })
    }

    $psm = $null
    $rawPsm = Get-ObjectProperty -InputObject $Entry -Name 'PSM'
    if ($null -ne $rawPsm) {
        $connectors = New-Object System.Collections.Generic.List[object]
        foreach ($connector in (Get-ObjectList -InputObject $rawPsm -Name 'Connectors')) {
            $connectors.Add([PSCustomObject]@{
                    PSMConnectorID = ([string](Get-ObjectProperty -InputObject $connector -Name 'PSMConnectorID')).Trim()
                    Enabled        = ConvertTo-Boolean -Value (Get-ObjectProperty -InputObject $connector -Name 'Enabled') -Default $true
                })
        }
        $psm = [PSCustomObject]@{
            PSMServerID = ([string](Get-ObjectProperty -InputObject $rawPsm -Name 'PSMServerID')).Trim()
            Connectors  = $connectors.ToArray()
        }
    }

    # Anything we do not recognise is carried along untouched so a round trip through the editor
    # does not silently delete someone's "Comment" or "Owner" field.
    $extra = [ordered]@{}
    # An entry that is already normalised (or comes from the editor) carries its unknown fields
    # in an "Extra" dictionary; a raw JSON entry carries them as ordinary properties.
    $sourceExtra = Get-ObjectProperty -InputObject $Entry -Name 'Extra'
    $hasExtraDictionary = ($sourceExtra -is [System.Collections.IDictionary])
    if ($hasExtraDictionary) {
        foreach ($key in @($sourceExtra.Keys)) { $extra[[string]$key] = $sourceExtra[$key] }
    }
    if ($Entry -isnot [System.Collections.IDictionary]) {
        foreach ($property in $Entry.PSObject.Properties) {
            if ($knownProperties -contains $property.Name) { continue }
            if ($hasExtraDictionary -and $property.Name -ieq 'Extra') { continue }
            $extra[$property.Name] = $property.Value
        }
    }

    return [PSCustomObject]@{
        PlatformId                   = ([string](Get-ObjectProperty -InputObject $Entry -Name 'PlatformId')).Trim()
        PlatformName                 = ([string](Get-ObjectProperty -InputObject $Entry -Name 'PlatformName')).Trim()
        Description                  = [string](Get-ObjectProperty -InputObject $Entry -Name 'Description')
        State                        = $state
        ApplyChangesIfPlatformExists = ConvertTo-Boolean -Value (Get-ObjectProperty -InputObject $Entry -Name 'ApplyChangesIfPlatformExists')
        Settings                     = $settings.ToArray()
        PSM                          = $psm
        Extra                        = $extra
    }
}

function Read-PlatformVariantConfiguration {
    <#
        .SYNOPSIS
        Loads a variant configuration file and returns normalised platform entries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-ExistingFile -Path $Path -Label 'Configuration file' -Extension '.json'
    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'The file is empty.' }
        $document = $raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read configuration file '$resolved'. $($_.Exception.Message)"
    }

    $extra = [ordered]@{}
    if ($document -is [System.Array]) {
        # A bare array of platforms is accepted as shorthand for { "Platforms": [...] }.
        $entries = @($document | Where-Object { $null -ne $_ })
    }
    else {
        $entries = Get-ObjectList -InputObject $document -Name 'Platforms'
        foreach ($property in $document.PSObject.Properties) {
            if ($property.Name -ine 'Platforms') { $extra[$property.Name] = $property.Value }
        }
    }

    $platforms = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $platforms.Add((ConvertTo-PlatformVariant -Entry $entry))
    }

    return [PSCustomObject]@{
        Path      = $resolved
        Platforms = $platforms.ToArray()
        Extra     = $extra
    }
}

function Test-PlatformVariantConfiguration {
    <#
        .SYNOPSIS
        Checks normalised platform entries and returns every problem found, instead of stopping at
        the first one. An empty result means the configuration is good to run.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Platforms,

        [string]$SourcePlatformId
    )

    $issues = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Severity, [int]$Index, [string]$PlatformId, [string]$Message)
        $issues.Add([PSCustomObject]@{ Severity = $Severity; Index = $Index; PlatformId = $PlatformId; Message = $Message })
    }

    $entries = @($Platforms | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) {
        & $add 'Error' -1 '' 'The configuration does not contain any platforms.'
        return $issues.ToArray()
    }

    $seenIds = @{}
    $seenNames = @{}
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $platform = $entries[$index]
        $id = [string]$platform.PlatformId
        $label = if ([string]::IsNullOrWhiteSpace($id)) { "#$($index + 1)" } else { $id }

        if ([string]::IsNullOrWhiteSpace($id)) {
            & $add 'Error' $index $label 'Platform ID is required.'
        }
        else {
            if ($id -match '\s') { & $add 'Error' $index $label 'Platform ID must not contain spaces.' }
            if ($id -match '[\\/:*?"<>|]') { & $add 'Error' $index $label 'Platform ID must not contain any of \ / : * ? " < > |' }
            if (-not [string]::IsNullOrWhiteSpace($SourcePlatformId) -and $id -ieq $SourcePlatformId) {
                & $add 'Error' $index $label "Platform ID is the same as the source platform '$SourcePlatformId'."
            }
            $key = $id.ToLowerInvariant()
            if ($seenIds.ContainsKey($key)) { & $add 'Error' $index $label "Platform ID is used more than once (also entry #$($seenIds[$key] + 1))." }
            else { $seenIds[$key] = $index }
        }

        if ([string]::IsNullOrWhiteSpace([string]$platform.PlatformName)) {
            & $add 'Error' $index $label 'Platform name is required.'
        }
        else {
            $key = ([string]$platform.PlatformName).ToLowerInvariant()
            if ($seenNames.ContainsKey($key)) { & $add 'Warning' $index $label "Platform name '$($platform.PlatformName)' is used more than once; PVWA normally requires unique names." }
            else { $seenNames[$key] = $index }
        }

        if ($script:PlatformStates -notcontains $platform.State) {
            & $add 'Error' $index $label "State '$($platform.State)' is not valid. Use Unchanged, Active or Inactive."
        }

        $seenPaths = @{}
        $settingNumber = 0
        foreach ($setting in @($platform.Settings)) {
            $settingNumber++
            if ([string]::IsNullOrWhiteSpace([string]$setting.Path)) {
                & $add 'Error' $index $label "Setting #$settingNumber has no path."
                continue
            }
            if ($script:SettingOperations -notcontains $setting.Operation) {
                & $add 'Error' $index $label "Setting '$($setting.Path)' uses unsupported operation '$($setting.Operation)'. Use replace or remove."
            }
            elseif ($setting.Operation -eq 'replace' -and $null -eq $setting.Value) {
                & $add 'Error' $index $label "Setting '$($setting.Path)' uses replace but has no value."
            }
            $key = ([string]$setting.Path).ToLowerInvariant()
            if ($seenPaths.ContainsKey($key)) { & $add 'Warning' $index $label "Setting '$($setting.Path)' is listed more than once; the last one wins." }
            else { $seenPaths[$key] = $true }
        }

        if ($null -ne $platform.PSM) {
            $seenConnectors = @{}
            $connectorNumber = 0
            foreach ($connector in @($platform.PSM.Connectors)) {
                $connectorNumber++
                if ([string]::IsNullOrWhiteSpace([string]$connector.PSMConnectorID)) {
                    & $add 'Error' $index $label "PSM connector #$connectorNumber has no connector ID."
                    continue
                }
                $key = ([string]$connector.PSMConnectorID).ToLowerInvariant()
                if ($seenConnectors.ContainsKey($key)) { & $add 'Warning' $index $label "PSM connector '$($connector.PSMConnectorID)' is listed more than once." }
                else { $seenConnectors[$key] = $true }
            }
            if ([string]::IsNullOrWhiteSpace([string]$platform.PSM.PSMServerID) -and @($platform.PSM.Connectors).Count -eq 0) {
                & $add 'Warning' $index $label 'PSM is switched on but neither a PSM server ID nor a connector is set, so nothing will change.'
            }
        }
    }

    # Callers wrap this in @(), so it is returned unrolled.
    return $issues.ToArray()
}

function ConvertTo-PlatformVariantDocument {
    # Normalised entries -> the ordered structure that is written to disk.
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Platforms,

        [System.Collections.IDictionary]$Extra
    )

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($platform in @($Platforms | Where-Object { $null -ne $_ })) {
        $item = [ordered]@{
            PlatformId                   = [string]$platform.PlatformId
            PlatformName                 = [string]$platform.PlatformName
            Description                  = [string]$platform.Description
            State                        = [string]$platform.State
            ApplyChangesIfPlatformExists = [bool]$platform.ApplyChangesIfPlatformExists
        }

        $settings = @($platform.Settings | Where-Object { $null -ne $_ })
        if ($settings.Count -gt 0) {
            $item['Settings'] = @(
                foreach ($setting in $settings) {
                    $entry = [ordered]@{ Operation = [string]$setting.Operation; Path = [string]$setting.Path }
                    if ($setting.Operation -ne 'remove') { $entry['Value'] = $setting.Value }
                    $entry
                }
            )
        }

        if ($null -ne $platform.PSM) {
            $psm = [ordered]@{}
            if (-not [string]::IsNullOrWhiteSpace([string]$platform.PSM.PSMServerID)) { $psm['PSMServerID'] = [string]$platform.PSM.PSMServerID }
            $connectors = @($platform.PSM.Connectors | Where-Object { $null -ne $_ })
            if ($connectors.Count -gt 0) {
                $psm['Connectors'] = @(
                    foreach ($connector in $connectors) {
                        [ordered]@{ PSMConnectorID = [string]$connector.PSMConnectorID; Enabled = [bool]$connector.Enabled }
                    }
                )
            }
            $item['PSM'] = $psm
        }

        if ($platform.Extra -is [System.Collections.IDictionary]) {
            foreach ($key in @($platform.Extra.Keys)) {
                if (-not $item.Contains([string]$key)) { $item[[string]$key] = $platform.Extra[$key] }
            }
        }
        $list.Add($item)
    }

    $document = [ordered]@{}
    if ($null -ne $Extra) {
        foreach ($key in @($Extra.Keys)) {
            if ([string]$key -ine 'Platforms') { $document[[string]$key] = $Extra[$key] }
        }
    }
    $document['Platforms'] = $list.ToArray()
    return $document
}

function ConvertTo-PlatformVariantJson {
    <#
        .SYNOPSIS
        Renders normalised platform entries as the JSON text that goes into the configuration file.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Platforms,

        [System.Collections.IDictionary]$Extra
    )

    return (ConvertTo-PrettyJson -Value (ConvertTo-PlatformVariantDocument -Platforms $Platforms -Extra $Extra))
}

function Save-PlatformVariantConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Platforms,

        [System.Collections.IDictionary]$Extra
    )

    $json = ConvertTo-PlatformVariantJson -Platforms $Platforms -Extra $Extra
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Path $fullPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    [System.IO.File]::WriteAllText($fullPath, $json + [System.Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    return $fullPath
}

function Get-PlatformNamingScheme {
    <#
        .SYNOPSIS
        The standard platform names per vault type, as suffixes added to a custom name.
        Without -VaultType it returns the whole table (vault type -> suffixes).
    #>
    [CmdletBinding()]
    param(
        [string]$VaultType
    )

    if ([string]::IsNullOrWhiteSpace($VaultType)) {
        $copy = [ordered]@{}
        foreach ($key in @($script:NamingSchemes.Keys)) { $copy[$key] = @($script:NamingSchemes[$key]) }
        return $copy
    }
    foreach ($key in @($script:NamingSchemes.Keys)) {
        if ($key -ieq $VaultType) { return @($script:NamingSchemes[$key]) }
    }
    throw "Unknown vault type '$VaultType'. Use one of: $(@($script:NamingSchemes.Keys) -join ', ')."
}

function New-PlatformVariantSet {
    <#
        .SYNOPSIS
        Builds the standard set of platforms for a vault type from one custom name, ready to pass
        to Invoke-PlatformVariantImport -Platforms. Platform ID and platform name are the same.

        .EXAMPLE
        New-PlatformVariantSet -VaultType Human -CustomName MyApp
        # MyApp-PROD, MyApp-PrePROD, MyApp-PROD-MAN, MyApp-PrePROD-MAN
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultType,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CustomName,

        # Standard platforms to leave out: the full ID (MyApp-PROD-MAN) or just the suffix (-PROD-MAN).
        [string[]]$ExcludePlatformId,

        # Extra platform IDs to create on top of the standard ones.
        [string[]]$AdditionalPlatformId
    )

    $base = ([string]$CustomName).Trim()
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'A custom name is required to build the platform names.' }

    $suffixes = @(Get-PlatformNamingScheme -VaultType $VaultType)
    $excluded = @($ExcludePlatformId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    foreach ($item in $excluded) {
        # A typo here would silently create the platform that was meant to be left out.
        if (@($suffixes | Where-Object { $_ -ieq $item -or "$base$_" -ieq $item }).Count -eq 0) {
            throw "Cannot exclude '$item': it is not one of the standard $VaultType platforms ($(@($suffixes | ForEach-Object { "$base$_" }) -join ', '))."
        }
    }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($suffix in $suffixes) {
        $name = "$base$suffix"
        if (@($excluded | Where-Object { $_ -ieq $suffix -or $_ -ieq $name }).Count -gt 0) { continue }
        $names.Add($name)
    }
    foreach ($item in @($AdditionalPlatformId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $name = $item.Trim()
        if (@($names | Where-Object { $_ -ieq $name }).Count -eq 0) { $names.Add($name) }
    }

    return @($names | ForEach-Object { ConvertTo-PlatformVariant -Entry @{ PlatformId = $_; PlatformName = $_ } })
}

function Get-PlatformSettingPathSuggestion {
    [CmdletBinding()]
    param()
    return $script:KnownSettingPaths
}

#endregion

#region Engine: logging and events -----------------------------------------------------------

function Send-EngineEvent {
    # Everything the engine has to say goes through here: to the log file, and then either to the
    # caller's callback (GUI) or to the console.
    param(
        [string]$Type,
        [string]$Level = 'INFO',
        [string]$Message = '',
        $Data = $null
    )

    $item = [PSCustomObject]@{
        Type    = $Type
        Time    = Get-Date
        Level   = $Level
        Message = $Message
        Data    = $Data
    }

    if ($Type -eq 'Log') {
        $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f $item.Time, $Level, $Message
        if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
            try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false } catch { }
        }
        if ($null -eq $script:EventSink) {
            $color = switch ($Level) {
                'WARNING' { 'Yellow' }
                'ERROR' { 'Red' }
                'SUCCESS' { 'Green' }
                default { 'Cyan' }
            }
            Write-Host $line -ForegroundColor $color
        }
    }

    if ($null -ne $script:EventSink) {
        try { & $script:EventSink $item } catch { Write-Verbose "Event callback failed: $($_.Exception.Message)" }
    }
}

function Write-EngineLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    Send-EngineEvent -Type 'Log' -Level $Level -Message $Message
}

#endregion

#region Engine: PVWA access ------------------------------------------------------------------

function Initialize-PsPas {
    param([bool]$RequireSettings)

    if (-not (Get-Module -ListAvailable -Name psPAS)) {
        throw 'The psPAS module is not installed. Run: Install-Module psPAS -Scope CurrentUser'
    }
    Import-Module psPAS -ErrorAction Stop -Verbose:$false
    $module = Get-Module -Name psPAS | Select-Object -First 1
    Write-EngineLog "Using psPAS version $($module.Version)."

    $importCommand = Get-Command -Name Import-PASPlatform -Module psPAS -ErrorAction SilentlyContinue
    if ($null -eq $importCommand -or -not $importCommand.Parameters.ContainsKey('PlatformName')) {
        throw "psPAS $($module.Version) cannot import platforms side by side. Update it first: Update-Module psPAS (version 8.0 or later)."
    }
    foreach ($name in @('Get-PASPlatform', 'Set-PASPlatformPSMConfig', 'Enable-PASPlatform', 'Disable-PASPlatform')) {
        if ($null -eq (Get-Command -Name $name -Module psPAS -ErrorAction SilentlyContinue)) {
            throw "psPAS $($module.Version) has no $name command. Update it first: Update-Module psPAS"
        }
    }
    if ($RequireSettings -and $null -eq (Get-Command -Name Set-PASPlatform -Module psPAS -ErrorAction SilentlyContinue)) {
        throw "The configuration contains setting changes, which need Set-PASPlatform from psPAS 8.0 or later (installed: $($module.Version)). Run: Update-Module psPAS"
    }
}

function Connect-Pvwa {
    param(
        [string]$PVWAURL,
        [PSCredential]$Credential,
        [string]$AuthType,
        [string]$OTP,
        [string]$OTPMode,
        [bool]$ConcurrentSession,
        [bool]$SkipCertificateCheck
    )

    $baseUri = Resolve-PvwaBaseUri -Url $PVWAURL
    if ($baseUri -like 'http://*') {
        Write-EngineLog 'The PVWA address uses http, so the credentials travel unencrypted.' -Level WARNING
    }
    if ($null -eq $Credential) { throw 'Credentials are required to connect to PVWA.' }
    if (-not [string]::IsNullOrWhiteSpace($OTP) -and $AuthType -ne 'RADIUS') {
        throw "A one-time passcode can only be used with RADIUS authentication (selected: $AuthType)."
    }

    $parameters = @{
        BaseURI     = $baseUri
        Credential  = $Credential
        type        = $AuthType
        ErrorAction = 'Stop'
        WhatIf      = $false
        Confirm     = $false
    }
    if ($ConcurrentSession) { $parameters['concurrentSession'] = $true }
    if ($SkipCertificateCheck) { $parameters['SkipCertificateCheck'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($OTP)) {
        $parameters['OTP'] = $OTP
        if (-not [string]::IsNullOrWhiteSpace($OTPMode)) { $parameters['OTPMode'] = $OTPMode }
    }

    Write-EngineLog "Connecting to $baseUri as '$($Credential.UserName)' ($AuthType)."
    try {
        $null = New-PASSession @parameters
    }
    catch {
        throw (Get-LogonFailureMessage -ErrorRecord $_ -BaseUri $baseUri -UserName $Credential.UserName -AuthType $AuthType)
    }
    Write-EngineLog 'Connected to CyberArk PVWA.' -Level SUCCESS
}

function Get-LogonFailureMessage {
    <#
        A refused logon used to surface as PVWA's bare "Authentication failure", which says nothing
        about what was attempted. This states it, and points at what differs most often between a
        logon that works on the PVWA page and one that fails here: the authentication method.

        The password itself is never part of the message. It is handed to psPAS untouched, and psPAS
        sends it as a JSON string, so characters such as / \ " < & reach PVWA exactly as typed.
    #>
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$BaseUri,
        [string]$UserName,
        [string]$AuthType
    )

    $reason = [string]$ErrorRecord.Exception.Message
    # psPAS puts PVWA's own error code (ITATS004E, PASWS013E, ...) in the error ID.
    $code = ([string]$ErrorRecord.FullyQualifiedErrorId -split ',')[0]
    if ($code -cmatch '^[A-Z]{3,8}\d{3,4}[A-Z]?$' -and $reason -notlike "*$code*") { $reason = "$reason ($code)" }

    $message = "Logon to $BaseUri as '$UserName' with $AuthType authentication failed. PVWA said: $reason"

    $rejected = ($reason -match '(?i)authentication failure|ITATS|\[40[13]\]|unauthorized|invalid (user|credential|password)|incorrect')
    if ($rejected) {
        $message += " -- The password was sent exactly as typed; no character is changed. If the same user name and password work on the PVWA logon page, check that the authentication method you choose there is the one selected here ($AuthType), and that the user name is written the same way."
        if ($AuthType -eq 'RADIUS') { $message += ' For RADIUS, also check the one-time code and whether it must be appended or sent as a challenge.' }
    }
    return $message
}

function Disconnect-Pvwa {
    try {
        $null = Close-PASSession -ErrorAction Stop
        Write-EngineLog 'CyberArk session closed.'
    }
    catch {
        Write-EngineLog "Could not close the CyberArk session. $($_.Exception.Message)" -Level WARNING
    }
}

function Get-PvwaVersion {
    # Returns $null when the version is unknown (for example after -SkipVersionCheck).
    try {
        $session = Get-PASSession -ErrorAction Stop
        $raw = [string](Get-ObjectProperty -InputObject $session -Name 'ExternalVersion')
        $match = [regex]::Match($raw, '\d+(\.\d+){1,3}')
        if (-not $match.Success) { return $null }
        $version = [version]$match.Value
        if ($version -eq [version]'0.0') { return $null }
        return $version
    }
    catch {
        return $null
    }
}

function Get-TargetPlatformIndex {
    # One call for every target platform, keyed by platform ID (case-insensitive).
    $index = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($platform in @(Get-PASPlatform -ErrorAction Stop)) {
        $id = [string](Get-ObjectProperty -InputObject $platform -Name 'PlatformID')
        if (-not [string]::IsNullOrWhiteSpace($id)) { $index[$id] = $platform }
    }
    return , $index
}

function Find-TargetPlatform {
    param([string]$PlatformId)

    # Only the platform ID counts as a match. Matching on name or base ID (as the search does)
    # would return every variant, because they all share the source's base ID.
    $isMatch = { [string](Get-ObjectProperty -InputObject $_ -Name 'PlatformID') -ieq $PlatformId }

    $found = @(Get-PASPlatform -Search $PlatformId -ErrorAction Stop | Where-Object $isMatch)
    if ($found.Count -eq 0) {
        # The search is a free-text match and may not index the ID the way we need.
        $found = @(Get-PASPlatform -ErrorAction Stop | Where-Object $isMatch)
    }
    if ($found.Count -eq 0) { return $null }
    return $found[0]
}

function Wait-TargetPlatform {
    param(
        [string]$PlatformId,
        [int]$TimeoutSeconds = 60,
        [int]$PollIntervalSeconds = 2
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($true) {
        try {
            $platform = Find-TargetPlatform -PlatformId $PlatformId
            if ($null -ne $platform) { return $platform }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    $detail = if ($lastError) { " Last lookup error: $lastError" } else { '' }
    throw "Platform '$PlatformId' was not returned by PVWA within $TimeoutSeconds seconds.$detail"
}

function Get-TargetPlatformNumericId {
    param($Platform)

    foreach ($name in @('ID', 'PlatformNumericID')) {
        $value = Get-ObjectProperty -InputObject $Platform -Name $name
        $number = 0
        if ($null -ne $value -and [int]::TryParse([string]$value, [ref]$number)) { return $number }
    }
    $names = @($Platform.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
    throw "The numeric platform ID could not be determined. Returned properties: $names"
}

function Get-StoredPlatformId {
    # ID of the package PVWA currently holds in memory, or $null when there is none.
    if ($null -eq (Get-Command -Name Get-PASStoredPlatform -Module psPAS -ErrorAction SilentlyContinue)) { return $null }
    try {
        $stored = Get-PASStoredPlatform -ErrorAction Stop
    }
    catch {
        return $null
    }
    $details = Get-ObjectProperty -InputObject $stored -Name 'StoredPlatformDetails'
    $id = [string](Get-ObjectProperty -InputObject $details -Name 'Id')
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return $id
}

function New-SideBySidePlatform {
    <#
        Side-by-side import only works on a package PVWA is holding in memory, and it only holds a
        package after an upload that conflicted with an existing platform (for up to five minutes).
        So: make sure the package is held, uploading it again when it is not, then import it under
        the new ID. Returns $true when a package was uploaded.
    #>
    param(
        [string]$ZipPath,
        [string]$SourcePlatformId,
        $Variant
    )

    $uploaded = $false
    $uploadError = $null
    $storedId = Get-StoredPlatformId
    if ($null -eq $storedId -or $storedId -ine $SourcePlatformId) {
        if ($null -ne $storedId) {
            Write-EngineLog "PVWA is holding a different package ('$storedId'); it will be replaced." -Level WARNING
        }
        Write-EngineLog "Uploading the package so PVWA holds it for side-by-side import."
        try {
            $null = Import-PASPlatform -ImportFile $ZipPath -Confirm:$false -WhatIf:$false -ErrorAction Stop
        }
        catch {
            # PVWA may answer a conflicting upload with an error even though it kept the package,
            # so this is only fatal if the side-by-side import below fails as well.
            $uploadError = $_.Exception.Message
        }
        $uploaded = $true
    }

    $parameters = @{
        PlatformId   = [string]$Variant.PlatformId
        PlatformName = [string]$Variant.PlatformName
        Confirm      = $false
        WhatIf       = $false
        ErrorAction  = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Variant.Description)) {
        $parameters['Description'] = [string]$Variant.Description
    }

    try {
        $null = Import-PASPlatform @parameters
    }
    catch {
        $message = $_.Exception.Message
        if ($uploadError) { $message = "$message (the package upload before it reported: $uploadError)" }
        throw "Side-by-side import failed. $message"
    }
    return $uploaded
}

function Set-TargetPlatformDifference {
    # Applies settings, PSM configuration and state. Returns short descriptions of what was done.
    param(
        $Variant,
        [int]$NumericId,
        $Platform,
        [bool]$DryRun
    )

    $done = New-Object System.Collections.Generic.List[string]
    $verb = if ($DryRun) { 'Would apply' } else { 'Applying' }

    $settings = @($Variant.Settings | Where-Object { $null -ne $_ })
    if ($settings.Count -gt 0) {
        $operations = New-Object System.Collections.Generic.List[hashtable]
        foreach ($setting in $settings) {
            $operation = @{ op = [string]$setting.Operation; path = [string]$setting.Path }
            if ($setting.Operation -eq 'replace') { $operation['value'] = [string]$setting.Value }
            $operations.Add($operation)
        }
        Write-EngineLog "$verb $($operations.Count) setting change(s)."
        if (-not $DryRun) {
            $null = Set-PASPlatform -id $NumericId -operations ([hashtable[]]$operations.ToArray()) -Confirm:$false -WhatIf:$false -ErrorAction Stop
        }
        $done.Add("$($operations.Count) setting(s)")
    }

    if ($null -ne $Variant.PSM) {
        $parameters = @{ ID = $NumericId; Confirm = $false; WhatIf = $false; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace([string]$Variant.PSM.PSMServerID)) {
            $parameters['PSMServerID'] = [string]$Variant.PSM.PSMServerID
        }
        $connectors = @($Variant.PSM.Connectors | Where-Object { $null -ne $_ })
        if ($connectors.Count -gt 0) {
            $parameters['PSMConnectors'] = @(
                foreach ($connector in $connectors) {
                    [PSCustomObject]@{ PSMConnectorID = [string]$connector.PSMConnectorID; Enabled = [bool]$connector.Enabled }
                }
            )
        }
        if ($parameters.ContainsKey('PSMServerID') -or $parameters.ContainsKey('PSMConnectors')) {
            Write-EngineLog "$verb PSM configuration."
            if (-not $DryRun) { $null = Set-PASPlatformPSMConfig @parameters }
            $done.Add('PSM')
        }
    }

    if ($Variant.State -ne 'Unchanged') {
        $wantActive = ($Variant.State -eq 'Active')
        $isActive = $null
        if (Test-ObjectProperty -InputObject $Platform -Name 'Active') {
            $isActive = ConvertTo-Boolean -Value (Get-ObjectProperty -InputObject $Platform -Name 'Active')
        }
        if ($null -ne $isActive -and $isActive -eq $wantActive) {
            Write-EngineLog "Platform is already $($Variant.State.ToLowerInvariant())."
        }
        elseif ($wantActive) {
            Write-EngineLog $(if ($DryRun) { 'Would activate the platform.' } else { 'Activating the platform.' })
            if (-not $DryRun) { $null = Enable-PASPlatform -TargetPlatform -ID $NumericId -Confirm:$false -WhatIf:$false -ErrorAction Stop }
            $done.Add('activated')
        }
        else {
            Write-EngineLog $(if ($DryRun) { 'Would deactivate the platform.' } else { 'Deactivating the platform.' })
            if (-not $DryRun) { $null = Disable-PASPlatform -TargetPlatform -ID $NumericId -Confirm:$false -WhatIf:$false -ErrorAction Stop }
            $done.Add('deactivated')
        }
    }

    return $done.ToArray()
}

#endregion

#region Engine: public entry points ----------------------------------------------------------

function Test-PvwaConnection {
    <#
        .SYNOPSIS
        Logs on, reports who and what we are talking to, and logs off again. Changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PVWAURL,

        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential,

        [ValidateSet('CyberArk', 'LDAP', 'RADIUS', 'Windows')]
        [string]$AuthType = 'CyberArk',

        [string]$OTP,

        [ValidateSet('', 'Append', 'Challenge')]
        [string]$OTPMode = '',

        [switch]$ConcurrentSession,
        [switch]$SkipCertificateCheck,
        [string]$SourcePlatformId,
        [scriptblock]$OnEvent
    )

    $script:EventSink = $OnEvent
    $script:LogFile = $null
    $connected = $false
    try {
        Initialize-PsPas -RequireSettings $false
        Connect-Pvwa -PVWAURL $PVWAURL -Credential $Credential -AuthType $AuthType -OTP $OTP -OTPMode $OTPMode `
            -ConcurrentSession ([bool]$ConcurrentSession) -SkipCertificateCheck ([bool]$SkipCertificateCheck)
        $connected = $true

        $version = Get-PvwaVersion
        if ($null -ne $version) {
            Write-EngineLog "PVWA version $version."
            if ($version -lt [version]'14.6') {
                Write-EngineLog 'Side-by-side platform import needs PVWA 14.6 or later.' -Level WARNING
            }
            elseif ($version -lt [version]'15.2') {
                Write-EngineLog 'Setting changes need PVWA 15.2 or later; creating variants and PSM configuration will work.' -Level WARNING
            }
        }
        else {
            Write-EngineLog 'PVWA did not report its version.' -Level WARNING
        }

        $index = Get-TargetPlatformIndex
        Write-EngineLog "$($index.Count) target platform(s) visible to this user."

        $sourceExists = $null
        if (-not [string]::IsNullOrWhiteSpace($SourcePlatformId)) {
            $sourceExists = $index.ContainsKey($SourcePlatformId)
            if ($sourceExists) { Write-EngineLog "Source platform '$SourcePlatformId' exists." -Level SUCCESS }
            else { Write-EngineLog "Source platform '$SourcePlatformId' does not exist yet; it will be imported from the ZIP." }
        }

        $result = [PSCustomObject]@{
            BaseURI              = Resolve-PvwaBaseUri -Url $PVWAURL
            User                 = $Credential.UserName
            Version              = $version
            TargetPlatformCount  = $index.Count
            SourcePlatformExists = $sourceExists
        }
        Send-EngineEvent -Type 'ConnectionResult' -Message 'Connection test succeeded.' -Data $result
        return $result
    }
    catch {
        Write-EngineLog $_.Exception.Message -Level ERROR
        throw
    }
    finally {
        if ($connected) { Disconnect-Pvwa }
        $script:EventSink = $null
    }
}

function Invoke-PlatformVariantImport {
    <#
        .SYNOPSIS
        Creates the platform variants described in a configuration file from one platform ZIP.

        .DESCRIPTION
        -WhatIf performs a dry run: it logs on, looks at what exists and reports what would be
        done, without changing anything in the Vault.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$PVWAURL,

        [PSCredential]$Credential,

        [ValidateSet('CyberArk', 'LDAP', 'RADIUS', 'Windows')]
        [string]$AuthType = 'CyberArk',

        [string]$OTP,

        [ValidateSet('', 'Append', 'Challenge')]
        [string]$OTPMode = '',

        [switch]$ConcurrentSession,
        [switch]$SkipCertificateCheck,

        # Use the psPAS session that is already open instead of logging on.
        [switch]$UseExistingSession,
        [switch]$KeepSessionOpen,

        [Parameter(Mandatory = $true)]
        [string]$SourcePlatformZip,

        [string]$SourcePlatformId,

        # What to create: either a JSON configuration file, or the platform entries themselves
        # (for example from New-PlatformVariantSet). Exactly one of the two.
        [string]$ConfigurationFile,

        [object[]]$Platforms,

        [string]$ReportPath,
        [string]$LogPath,
        [switch]$ContinueOnError,

        [ValidateRange(5, 600)]
        [int]$PlatformTimeoutSeconds = 60,

        [scriptblock]$OnEvent,
        [scriptblock]$CancelCheck,
        [switch]$PassThru
    )

    # The dry run is handled here rather than by passing -WhatIf down, so that every skipped
    # action is logged the same way for the console and the GUI, and so the report and the log
    # file are still written.
    $dryRun = [bool]$WhatIfPreference
    $WhatIfPreference = $false

    $script:EventSink = $OnEvent
    $script:LogFile = $null

    $report = New-Object System.Collections.Generic.List[object]
    $variants = @()
    $sourceId = $SourcePlatformId
    $sessionCreated = $false
    $packageUploaded = $false
    $sourceImported = $false
    $cancelled = $false
    $fatalError = $null
    $writtenReport = $null
    $runStarted = Get-Date

    $newRow = {
        param($Variant, [string]$Status, [string]$Message)
        [PSCustomObject]@{
            PlatformId       = [string]$Variant.PlatformId
            PlatformName     = [string]$Variant.PlatformName
            NumericId        = $null
            SourcePlatformId = $sourceId
            Action           = 'None'
            Status           = $Status
            Message          = $Message
            Started          = $null
            Finished         = $null
            DurationSeconds  = $null
        }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $logFull = [System.IO.Path]::GetFullPath($LogPath)
            $logDirectory = Split-Path -Path $logFull -Parent
            if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null }
            $script:LogFile = $logFull
        }

        if ($dryRun) { Write-EngineLog 'Dry run: nothing will be changed in the Vault.' -Level WARNING }

        # --- inputs -------------------------------------------------------------------------
        $zipPath = Resolve-ExistingFile -Path $SourcePlatformZip -Label 'Source platform ZIP' -Extension '.zip'
        $fromList = $PSBoundParameters.ContainsKey('Platforms')
        if ($fromList -and -not [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
            throw 'Pass either -Platforms or -ConfigurationFile, not both.'
        }
        if (-not $fromList -and [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
            throw 'Nothing to create: pass -Platforms or -ConfigurationFile.'
        }

        $package = Get-PlatformPackageInfo -Path $zipPath
        if ($package.SizeBytes -gt 20MB) {
            throw "The platform ZIP is $([System.Math]::Round($package.SizeBytes / 1MB, 1)) MB; PVWA accepts at most 20 MB."
        }
        if ([string]::IsNullOrWhiteSpace($sourceId)) {
            if ([string]::IsNullOrWhiteSpace($package.PlatformId)) {
                throw 'The platform ID could not be read from the ZIP. Specify the source platform ID.'
            }
            $sourceId = $package.PlatformId
            Write-EngineLog "Source platform ID '$sourceId' read from the ZIP."
        }
        elseif (-not [string]::IsNullOrWhiteSpace($package.PlatformId) -and $package.PlatformId -ine $sourceId) {
            # The side-by-side import relies on the ZIP colliding with the source platform, so a
            # mismatch would import the ZIP as a brand new platform instead.
            throw "The source platform ID '$sourceId' does not match the platform in the ZIP ('$($package.PlatformId)')."
        }

        if ($fromList) {
            $variants = @($Platforms | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-PlatformVariant -Entry $_ })
            Write-EngineLog "Creating $($variants.Count) platform(s) from the given list: $(@($variants | ForEach-Object { $_.PlatformId }) -join ', ')."
        }
        else {
            $configPath = Resolve-ExistingFile -Path $ConfigurationFile -Label 'Configuration file' -Extension '.json'
            Write-EngineLog "Reading configuration '$configPath'."
            $configuration = Read-PlatformVariantConfiguration -Path $configPath
            $variants = @($configuration.Platforms)
        }

        $issues = @(Test-PlatformVariantConfiguration -Platforms $variants -SourcePlatformId $sourceId)
        foreach ($issue in $issues) {
            $level = if ($issue.Severity -eq 'Error') { 'ERROR' } else { 'WARNING' }
            $prefix = if ([string]::IsNullOrWhiteSpace($issue.PlatformId)) { '' } else { "[$($issue.PlatformId)] " }
            Write-EngineLog "$prefix$($issue.Message)" -Level $level
        }
        $errorCount = @($issues | Where-Object { $_.Severity -eq 'Error' }).Count
        if ($errorCount -gt 0) { throw "The configuration has $errorCount error(s); nothing was changed." }

        Send-EngineEvent -Type 'Start' -Message "Processing $($variants.Count) platform(s)." -Data ([PSCustomObject]@{
                Total            = $variants.Count
                SourcePlatformId = $sourceId
                DryRun           = $dryRun
                Platforms        = @($variants | ForEach-Object { [PSCustomObject]@{ PlatformId = $_.PlatformId; PlatformName = $_.PlatformName } })
            })

        # --- connection ---------------------------------------------------------------------
        $needsSettings = @($variants | Where-Object { @($_.Settings).Count -gt 0 }).Count -gt 0
        Initialize-PsPas -RequireSettings $needsSettings

        if ($UseExistingSession) {
            Write-EngineLog 'Using the existing psPAS session.'
        }
        else {
            Connect-Pvwa -PVWAURL $PVWAURL -Credential $Credential -AuthType $AuthType -OTP $OTP -OTPMode $OTPMode `
                -ConcurrentSession ([bool]$ConcurrentSession) -SkipCertificateCheck ([bool]$SkipCertificateCheck)
            $sessionCreated = $true
        }

        # Fail on an unsupported PVWA before creating anything, not half way through.
        $version = Get-PvwaVersion
        if ($null -ne $version) {
            Write-EngineLog "PVWA version $version."
            if ($version -lt [version]'14.6') {
                throw "Side-by-side platform import needs PVWA 14.6 or later (connected to $version)."
            }
            if ($needsSettings -and $version -lt [version]'15.2') {
                throw "The configuration contains setting changes, which need PVWA 15.2 or later (connected to $version). Remove the Settings entries or upgrade."
            }
        }

        # --- source platform ----------------------------------------------------------------
        $existing = Get-TargetPlatformIndex
        $sourceExists = $existing.ContainsKey($sourceId)
        if ($sourceExists) {
            Write-EngineLog "Source platform '$sourceId' already exists."
        }
        elseif ($dryRun) {
            Write-EngineLog "Source platform '$sourceId' is not in this Vault. A real run imports it from the ZIP first and leaves it in the Vault." -Level WARNING
        }
        else {
            # A side-by-side import needs the source platform to exist in this Vault: PVWA only
            # holds a package that collided with an existing platform. A ZIP that comes from
            # another Vault is therefore imported as-is first, and stays.
            Write-EngineLog "Source platform '$sourceId' is not in this Vault. Importing it from '$zipPath' first; it stays in the Vault afterwards." -Level WARNING
            $imported = $null
            try {
                $imported = Import-PASPlatform -ImportFile $zipPath -Confirm:$false -WhatIf:$false -ErrorAction Stop
            }
            catch {
                $reason = $_.Exception.Message
                $heldId = Get-StoredPlatformId
                if ($null -ne $heldId -and $heldId -ieq $sourceId) {
                    # PVWA kept the package, which it only does when the platform already exists.
                    $packageUploaded = $true
                    throw "PVWA reports that platform '$sourceId' already exists, but it is not among the target platforms this user can see (it may be a group or dependent platform). No variants were created. PVWA said: $reason"
                }
                throw "Source platform '$sourceId' is not in this Vault and importing it from the ZIP failed, so no variants were created. PVWA said: $reason"
            }

            # PVWA's answer is the authority on which platform the ZIP holds.
            $reportedId = ([string](Get-ObjectProperty -InputObject $imported -Name 'PlatformID')).Trim()
            if ($reportedId -and $reportedId -ine $sourceId) {
                Write-EngineLog "PVWA imported the ZIP as '$reportedId', not '$sourceId' as read from the ZIP. Using '$reportedId' as the source platform." -Level WARNING
                $sourceId = $reportedId
                $sourceImported = $true
                if (@($variants | Where-Object { $_.PlatformId -ieq $sourceId }).Count -gt 0) {
                    throw "A variant uses the platform ID '$sourceId', which is the ID PVWA gave the source platform. No variants were created."
                }
            }

            try {
                $existing[$sourceId] = Wait-TargetPlatform -PlatformId $sourceId -TimeoutSeconds $PlatformTimeoutSeconds
            }
            catch {
                $sourceImported = $true
                throw "PVWA accepted the ZIP, but source platform '$sourceId' did not appear among the target platforms, so no variants were created. $($_.Exception.Message)"
            }
            $sourceImported = $true
            Write-EngineLog "Source platform '$sourceId' imported." -Level SUCCESS
        }

        # --- variants -----------------------------------------------------------------------
        $position = 0
        $stopAfterFailure = $false
        foreach ($variant in $variants) {
            $position++
            $row = & $newRow $variant 'NotRun' ''

            if ($stopAfterFailure) {
                $row.Message = 'Not processed because an earlier platform failed.'
                $report.Add($row)
                Send-EngineEvent -Type 'Result' -Data $row
                continue
            }
            if (-not $cancelled -and $null -ne $CancelCheck) {
                try { $cancelled = [bool](& $CancelCheck) } catch { $cancelled = $false }
                if ($cancelled) { Write-EngineLog 'Cancelled. The remaining platforms are left untouched.' -Level WARNING }
            }
            if ($cancelled) {
                $row.Status = 'Cancelled'
                $row.Message = 'Cancelled before this platform was processed.'
                $report.Add($row)
                Send-EngineEvent -Type 'Result' -Data $row
                continue
            }

            $row.Started = Get-Date
            $row.Status = 'Running'
            Send-EngineEvent -Type 'Platform' -Data $row
            Write-EngineLog "[$position/$($variants.Count)] Processing platform '$($variant.PlatformId)'."

            try {
                $platform = $null
                $proceed = $true

                if ($existing.ContainsKey($variant.PlatformId)) {
                    $platform = $existing[$variant.PlatformId]
                    if ($variant.ApplyChangesIfPlatformExists) {
                        Write-EngineLog 'Platform already exists. Applying the configured changes.' -Level WARNING
                        $row.Action = 'Updated'
                    }
                    else {
                        $row.Status = 'Skipped'
                        $row.Message = 'Platform already exists and ApplyChangesIfPlatformExists is false.'
                        Write-EngineLog $row.Message -Level WARNING
                        $proceed = $false
                    }
                }
                elseif ($dryRun) {
                    Write-EngineLog "Would create '$($variant.PlatformId)' ($($variant.PlatformName)) side by side with '$sourceId'."
                    $row.Action = 'Created'
                }
                else {
                    Write-EngineLog "Creating '$($variant.PlatformId)' ($($variant.PlatformName)) side by side with '$sourceId'."
                    if (New-SideBySidePlatform -ZipPath $zipPath -SourcePlatformId $sourceId -Variant $variant) {
                        $packageUploaded = $true
                    }
                    $platform = Wait-TargetPlatform -PlatformId $variant.PlatformId -TimeoutSeconds $PlatformTimeoutSeconds
                    $existing[$variant.PlatformId] = $platform
                    $row.Action = 'Created'
                    Write-EngineLog "Platform '$($variant.PlatformId)' created." -Level SUCCESS
                }

                if ($proceed) {
                    $numericId = 0
                    if ($null -ne $platform) {
                        $numericId = Get-TargetPlatformNumericId -Platform $platform
                        $row.NumericId = $numericId
                    }
                    $changes = @(Set-TargetPlatformDifference -Variant $variant -NumericId $numericId -Platform $platform -DryRun $dryRun)

                    $parts = @()
                    if ($row.Action -eq 'Created') { $parts += $(if ($dryRun) { 'would be created' } else { 'created' }) }
                    if ($changes.Count -gt 0) { $parts += $changes }
                    if ($parts.Count -eq 0) { $parts += 'nothing to change' }
                    $row.Message = ($parts -join '; ')
                    $row.Status = if ($dryRun) { 'WhatIf' } else { 'Completed' }
                    if (-not $dryRun) { Write-EngineLog "Platform '$($variant.PlatformId)' completed." -Level SUCCESS }
                }
            }
            catch {
                $row.Status = 'Failed'
                $row.Message = $_.Exception.Message
                Write-EngineLog "Platform '$($variant.PlatformId)' failed. $($row.Message)" -Level ERROR
                if (-not $ContinueOnError) {
                    $stopAfterFailure = $true
                    $fatalError = "Stopped after platform '$($variant.PlatformId)' failed: $($row.Message)"
                }
            }
            finally {
                $row.Finished = Get-Date
                $row.DurationSeconds = [System.Math]::Round(($row.Finished - $row.Started).TotalSeconds, 2)
                $report.Add($row)
                Send-EngineEvent -Type 'Result' -Data $row
            }
        }
    }
    catch {
        $fatalError = $_.Exception.Message
        Write-EngineLog $fatalError -Level ERROR
    }
    finally {
        # The package PVWA holds in memory expires by itself after five minutes; tidying it up
        # straight away just avoids confusing the next person who imports a platform.
        if ($packageUploaded) {
            try {
                $storedId = Get-StoredPlatformId
                if ($null -ne $storedId -and $storedId -ieq $sourceId) {
                    $null = Remove-PASStoredPlatform -Confirm:$false -WhatIf:$false -ErrorAction Stop
                }
            }
            catch { Write-Verbose "Stored package clean-up failed: $($_.Exception.Message)" }
        }

        if ($report.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($ReportPath)) {
            try {
                $reportFull = [System.IO.Path]::GetFullPath($ReportPath)
                $reportDirectory = Split-Path -Path $reportFull -Parent
                if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null }
                $report | Export-Csv -LiteralPath $reportFull -NoTypeInformation -Encoding UTF8
                $writtenReport = $reportFull
                Write-EngineLog "Report written to '$reportFull'."
            }
            catch {
                Write-EngineLog "Could not write the report. $($_.Exception.Message)" -Level ERROR
            }
        }

        if ($sessionCreated -and -not $KeepSessionOpen) { Disconnect-Pvwa }
    }

    $count = { param([string]$Status) @($report | Where-Object { $_.Status -eq $Status }).Count }
    $summary = [PSCustomObject]@{
        DryRun          = $dryRun
        Total           = @($variants).Count
        Completed       = (& $count 'Completed') + (& $count 'WhatIf')
        Skipped         = & $count 'Skipped'
        Failed          = & $count 'Failed'
        NotRun          = (& $count 'NotRun') + (& $count 'Cancelled')
        Cancelled       = $cancelled
        Error           = $fatalError
        SourceId        = $sourceId
        SourceImported  = $sourceImported      # this run had to add the source platform to the Vault
        ReportPath      = $writtenReport
        LogPath         = $script:LogFile
        DurationSeconds = [System.Math]::Round(((Get-Date) - $runStarted).TotalSeconds, 1)
        Report          = $report.ToArray()
    }

    $level = if ($summary.Failed -gt 0 -or $fatalError) { 'ERROR' } elseif ($summary.NotRun -gt 0) { 'WARNING' } else { 'SUCCESS' }
    $doneWord = if ($dryRun) { 'would be processed' } else { 'completed' }
    if ($sourceImported) {
        Write-EngineLog "Source platform '$sourceId' was not in this Vault and was added by this run." -Level WARNING
    }
    Write-EngineLog ("Finished: {0} {1}, {2} skipped, {3} failed, {4} not run." -f $summary.Completed, $doneWord, $summary.Skipped, $summary.Failed, $summary.NotRun) -Level $level
    Send-EngineEvent -Type 'Done' -Message 'Finished.' -Data $summary

    $script:EventSink = $null
    $script:LogFile = $null

    if ($fatalError -and -not $PassThru) { throw $fatalError }
    if ($PassThru) { return $summary }
}

#endregion

Export-ModuleMember -Function @(
    'Resolve-PvwaBaseUri'
    'Get-PlatformImportSettingsPath'
    'Get-PlatformImportSettings'
    'Save-PlatformImportSettings'
    'Get-PlatformPackageInfo'
    'ConvertTo-PlatformVariant'
    'Read-PlatformVariantConfiguration'
    'Test-PlatformVariantConfiguration'
    'ConvertTo-PlatformVariantJson'
    'Save-PlatformVariantConfiguration'
    'Get-PlatformSettingPathSuggestion'
    'Get-PlatformNamingScheme'
    'New-PlatformVariantSet'
    'Test-PvwaConnection'
    'Invoke-PlatformVariantImport'
)
