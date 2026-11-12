#Requires -Version 5.1
<#
    .SYNOPSIS
    Creates variants of a CyberArk platform from one platform ZIP and a JSON list of differences.

    .DESCRIPTION
    For every entry in the configuration file the script creates a copy of the source platform
    under a new platform ID and name (PVWA "side-by-side" import), then applies the entry's
    setting changes, PSM configuration and active/inactive state.

    Values you do not pass (PVWA address, authentication type, ZIP, configuration file, user name)
    are taken from the settings saved by the GUI or by an earlier run with -SaveSettings.
    Passwords and one-time passcodes are never saved.

    Requires psPAS 8.0 or later. Creating variants needs PVWA 14.6+, setting changes need 15.2+.
    For a graphical front end run Start-PlatformImportGui.ps1.

    .PARAMETER PVWAURL
    PVWA address, for example https://pvwa.company.com (a trailing /PasswordVault is ignored).

    .PARAMETER SourcePlatformZip
    Platform package exported from PVWA or downloaded from the CyberArk Marketplace.

    .PARAMETER SourcePlatformId
    Platform ID inside the ZIP. Optional: it is read from the ZIP when omitted.

    .PARAMETER ConfigurationFile
    JSON file describing the variants. See platforms.example.json. Not used with -VaultType.

    .PARAMETER VaultType
    Human or Machine: create the standard set of platforms for that vault type, named after
    -CustomName, without a configuration file.
      Human:   <name>-PROD, <name>-PrePROD, <name>-PROD-MAN, <name>-PrePROD-MAN
      Machine: <name>-PROD-D, <name>-PrePROD-D, <name>-PROD-RT-RL, <name>-PROD-RT-RS,
               <name>-PrePROD-RT-RL, <name>-PrePROD-RT-RS

    .PARAMETER CustomName
    First part of every platform name when -VaultType is used. Defaults to the platform ID in the ZIP.

    .PARAMETER ExcludePlatformId
    Standard platforms to leave out, as the full ID (MyApp-PROD-MAN) or the suffix in quotes
    ('-PROD-MAN'; unquoted, PowerShell would read the leading dash as a parameter name).

    .PARAMETER AdditionalPlatformId
    Extra platform IDs to create on top of the standard ones.

    .PARAMETER Type
    Authentication type: CyberArk, LDAP, RADIUS or Windows.

    .PARAMETER OTP
    One-time passcode for RADIUS. Use -OTPMode Append or Challenge if your RADIUS setup needs it.

    .PARAMETER ValidateOnly
    Check the ZIP and the configuration file and stop. Does not log on.

    .PARAMETER UseExistingSession
    Use the psPAS session already open in this PowerShell session instead of logging on.

    .PARAMETER SaveSettings
    Remember the address, authentication type, user name and file locations for next time.

    .EXAMPLE
    .\Import-PlatformVariants.ps1 -PVWAURL https://pvwa.company.com -SourcePlatformZip .\UnixSSH.zip -ConfigurationFile .\platforms.json -WhatIf

    Logs on, checks what exists and reports what would be created. Changes nothing.

    .EXAMPLE
    .\Import-PlatformVariants.ps1 -PVWAURL https://pvwa.company.com -Type LDAP -SourcePlatformZip .\UnixSSH.zip -ConfigurationFile .\platforms.json -ContinueOnError -SaveSettings

    .EXAMPLE
    .\Import-PlatformVariants.ps1 -PVWAURL https://pvwa.company.com -SourcePlatformZip .\UnixSSH.zip -VaultType Machine -CustomName MyApp -ExcludePlatformId MyApp-PrePROD-RT-RS -AdditionalPlatformId MyApp-DR

    Creates the standard machine-vault platforms named MyApp-..., except MyApp-PrePROD-RT-RS, plus MyApp-DR.

    .EXAMPLE
    .\Import-PlatformVariants.ps1

    Runs again with the saved settings, asking only for the password.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PVWAURL,

    [string]$SourcePlatformZip,

    [string]$SourcePlatformId,

    [string]$ConfigurationFile,

    [ValidateSet('Human', 'Machine')]
    [string]$VaultType,

    [string]$CustomName,

    [string[]]$ExcludePlatformId,

    [string[]]$AdditionalPlatformId,

    [ValidateSet('CyberArk', 'LDAP', 'RADIUS', 'Windows')]
    [Alias('AuthType')]
    [string]$Type,

    [PSCredential]$Credential,

    [string]$OTP,

    [ValidateSet('Append', 'Challenge')]
    [string]$OTPMode,

    [string]$ReportPath,

    [string]$LogPath,

    [switch]$ConcurrentSession,

    [switch]$SkipCertificateCheck,

    [switch]$ContinueOnError,

    [switch]$KeepSessionOpen,

    [switch]$UseExistingSession,

    [switch]$ValidateOnly,

    [switch]$SaveSettings,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'lib\PlatformVariants.psm1') -Force -Verbose:$false

function Write-Note {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host ('[{0:yyyy-MM-dd HH:mm:ss}] [INFO] {1}' -f (Get-Date), $Message) -ForegroundColor $Color
}

$saved = Get-PlatformImportSettings

# Explicit parameters always win; saved settings only fill the gaps, and say so.
if (-not $PSBoundParameters.ContainsKey('PVWAURL') -and $saved.PVWAURL) {
    $PVWAURL = $saved.PVWAURL
    if (-not $ValidateOnly -and -not $UseExistingSession) { Write-Note "Using saved PVWA address $PVWAURL." }
}
if (-not $PSBoundParameters.ContainsKey('Type')) {
    $Type = if ($saved.AuthType) { $saved.AuthType } else { 'CyberArk' }
}
# Not saved-settings driven on purpose: an OTP is typed per run, so its mode is too.
$otpModeValue = if ($PSBoundParameters.ContainsKey('OTPMode')) { $OTPMode } else { '' }
if (-not $PSBoundParameters.ContainsKey('SourcePlatformZip') -and $saved.SourcePlatformZip) {
    $SourcePlatformZip = $saved.SourcePlatformZip
    Write-Note "Using saved platform ZIP $SourcePlatformZip."
}
# The naming scheme is only ever used when asked for on this command line. Which platforms get
# created must not depend on what was last clicked in the GUI.
$useScheme = $PSBoundParameters.ContainsKey('VaultType')
if ($useScheme -and $PSBoundParameters.ContainsKey('ConfigurationFile')) {
    throw 'Use either -VaultType or -ConfigurationFile, not both.'
}
if (-not $useScheme -and ($CustomName -or $ExcludePlatformId -or $AdditionalPlatformId)) {
    throw '-CustomName, -ExcludePlatformId and -AdditionalPlatformId only work together with -VaultType.'
}
if (-not $useScheme -and -not $PSBoundParameters.ContainsKey('ConfigurationFile') -and $saved.ConfigurationFile) {
    $ConfigurationFile = $saved.ConfigurationFile
    Write-Note "Using saved configuration file $ConfigurationFile."
}
$useConcurrentSession = if ($PSBoundParameters.ContainsKey('ConcurrentSession')) { [bool]$ConcurrentSession } else { [bool]$saved.ConcurrentSession }

if ([string]::IsNullOrWhiteSpace($SourcePlatformZip)) { throw 'No platform ZIP given. Use -SourcePlatformZip.' }
if (-not $useScheme -and [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
    throw 'Nothing to create. Use -VaultType Human or Machine for the standard platforms, or -ConfigurationFile.'
}

$schemePlatforms = $null
if ($useScheme) {
    if ([string]::IsNullOrWhiteSpace($CustomName)) {
        $CustomName = if ($SourcePlatformId) { $SourcePlatformId } else { (Get-PlatformPackageInfo -Path $SourcePlatformZip).PlatformId }
        if ([string]::IsNullOrWhiteSpace($CustomName)) { throw 'The platform ID could not be read from the ZIP. Use -CustomName.' }
        Write-Note "Using the platform ID '$CustomName' as the custom name."
    }
    $schemePlatforms = @(New-PlatformVariantSet -VaultType $VaultType -CustomName $CustomName -ExcludePlatformId $ExcludePlatformId -AdditionalPlatformId $AdditionalPlatformId)
    Write-Note "$VaultType vault, $($schemePlatforms.Count) platform(s): $(@($schemePlatforms | ForEach-Object { $_.PlatformId }) -join ', ')."
}

if ($ValidateOnly) {
    $package = Get-PlatformPackageInfo -Path $SourcePlatformZip
    $sourceId = if ($SourcePlatformId) { $SourcePlatformId } else { $package.PlatformId }
    $configuration = if ($useScheme) { [PSCustomObject]@{ Platforms = $schemePlatforms } } else { Read-PlatformVariantConfiguration -Path $ConfigurationFile }
    $issues = @(Test-PlatformVariantConfiguration -Platforms $configuration.Platforms -SourcePlatformId $sourceId)
    if ($SourcePlatformId -and $package.PlatformId -and $package.PlatformId -ine $SourcePlatformId) {
        $issues += [PSCustomObject]@{ Severity = 'Error'; Index = -1; PlatformId = ''; Message = "Source platform ID '$SourcePlatformId' does not match the platform in the ZIP ('$($package.PlatformId)')." }
    }

    Write-Note "Package: $($package.PlatformId) ($($package.PlatformName)), $($configuration.Platforms.Count) variant(s) configured."
    foreach ($issue in $issues) {
        $color = if ($issue.Severity -eq 'Error') { 'Red' } else { 'Yellow' }
        $prefix = if ($issue.PlatformId) { "[$($issue.PlatformId)] " } else { '' }
        Write-Host "  $($issue.Severity): $prefix$($issue.Message)" -ForegroundColor $color
    }
    $errorCount = @($issues | Where-Object { $_.Severity -eq 'Error' }).Count
    if ($errorCount -eq 0) { Write-Note 'The configuration is valid.' 'Green' }

    [PSCustomObject]@{
        IsValid          = ($errorCount -eq 0)
        SourcePlatformId = $sourceId
        PlatformCount    = $configuration.Platforms.Count
        PlatformIds      = @($configuration.Platforms | ForEach-Object { $_.PlatformId })
        Issues           = $issues
    }
    return
}

if (-not $UseExistingSession) {
    if ([string]::IsNullOrWhiteSpace($PVWAURL)) { throw 'No PVWA address given. Use -PVWAURL.' }
    if ($null -eq $Credential) {
        $prompt = @{ Message = "Enter the CyberArk credentials for $PVWAURL ($Type)" }
        if ($saved.Username) { $prompt['UserName'] = $saved.Username }
        $Credential = Get-Credential @prompt
        if ($null -eq $Credential) { throw 'No credentials were entered.' }
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportFolder = if ($saved.ReportFolder) { $saved.ReportFolder } else { Join-Path -Path $PSScriptRoot -ChildPath 'reports' }
    $ReportPath = Join-Path -Path $reportFolder -ChildPath "PlatformImport-$stamp.csv"
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetFullPath($ReportPath), '.log')
}

if ($SaveSettings) {
    $toSave = @{
        AuthType          = $Type
        SourcePlatformZip = (Resolve-Path -LiteralPath $SourcePlatformZip).ProviderPath
        ConcurrentSession = $useConcurrentSession
        ContinueOnError   = [bool]$ContinueOnError
    }
    if ($useScheme) {
        $toSave['VariantSource'] = $VaultType
        $toSave['CustomName'] = $CustomName
    }
    else {
        $toSave['VariantSource'] = 'File'
        $toSave['ConfigurationFile'] = (Resolve-Path -LiteralPath $ConfigurationFile).ProviderPath
    }
    if ($PVWAURL) { $toSave['PVWAURL'] = $PVWAURL }
    if ($null -ne $Credential) { $toSave['Username'] = $Credential.UserName }
    if ($otpModeValue) { $toSave['OTPMode'] = $otpModeValue }
    if ($SourcePlatformId) { $toSave['SourcePlatformId'] = $SourcePlatformId }
    Save-PlatformImportSettings -Settings $toSave
    Write-Note "Settings saved to $(Get-PlatformImportSettingsPath)."
}

$arguments = @{
    SourcePlatformZip    = $SourcePlatformZip
    SourcePlatformId     = $SourcePlatformId
    AuthType             = $Type
    OTPMode              = $otpModeValue
    ConcurrentSession    = $useConcurrentSession
    SkipCertificateCheck = [bool]$SkipCertificateCheck
    UseExistingSession   = [bool]$UseExistingSession
    KeepSessionOpen      = [bool]$KeepSessionOpen
    ContinueOnError      = [bool]$ContinueOnError
    ReportPath           = $ReportPath
    LogPath              = $LogPath
    PassThru             = $true
    WhatIf               = [bool]$WhatIfPreference
}
if ($useScheme) { $arguments['Platforms'] = $schemePlatforms } else { $arguments['ConfigurationFile'] = $ConfigurationFile }
if ($PVWAURL) { $arguments['PVWAURL'] = $PVWAURL }
if ($null -ne $Credential) { $arguments['Credential'] = $Credential }
if ($OTP) { $arguments['OTP'] = $OTP }

$summary = Invoke-PlatformVariantImport @arguments

if (@($summary.Report).Count -gt 0) {
    $table = $summary.Report | Format-Table -AutoSize -Wrap -Property PlatformId, Status, Action, Message | Out-String
    Write-Host $table.TrimEnd()
}

if ($PassThru) { $summary }

if ($summary.Error) { throw $summary.Error }
if ($summary.Failed -gt 0) { throw "$($summary.Failed) of $($summary.Total) platform(s) failed. See '$($summary.ReportPath)'." }
