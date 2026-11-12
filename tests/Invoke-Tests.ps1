#Requires -Version 5.1
<#
    .SYNOPSIS
    Self-contained tests for the platform variant importer. No Pester and no real Vault needed:
    the engine runs against tests\MockPsPAS, a stand-in for psPAS that keeps a fake Vault in memory.

    .EXAMPLE
    powershell -NoProfile -File .\tests\Invoke-Tests.ps1

    .EXAMPLE
    powershell -NoProfile -File .\tests\Invoke-Tests.ps1 -IncludeGui -ScreenshotFolder C:\Temp\shots
#>
[CmdletBinding()]
param(
    # Also drive the WPF window (briefly opens it off screen).
    [switch]$IncludeGui,

    # Save PNG renderings of the window here (implies -IncludeGui).
    [string]$ScreenshotFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$workFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("import-platforms-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -Path $workFolder -ItemType Directory -Force | Out-Null

# The mock must win over any real psPAS, and saved settings must not touch the user's own.
$env:PSModulePath = (Join-Path $PSScriptRoot 'MockPsPAS') + ';' + $env:PSModulePath
$env:IMPORTPLATFORMS_SETTINGS = Join-Path $workFolder 'settings.json'

Import-Module (Join-Path $repoRoot 'lib\PlatformVariants.psm1') -Force
Import-Module psPAS -Force
if ((Get-Module psPAS).Description -notlike 'Test double*') { throw 'The mock psPAS module was not loaded; refusing to run tests against a real module.' }

$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "  [pass] $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed.Add($Name)
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "         $($_.ScriptStackTrace -split "`n" | Select-Object -First 1)" -ForegroundColor DarkGray
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -is [string] -or $Actual -is [string]) {
        if ([string]$Expected -cne [string]$Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" }
    }
    elseif ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

function Assert-True {
    param($Condition, [string]$Because = 'Condition was false.')
    if (-not $Condition) { throw $Because }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Like = '*')
    $thrown = $null
    try { & $Body } catch { $thrown = $_.Exception.Message }
    if ($null -eq $thrown) { throw "Expected an error like '$Like' but nothing was thrown." }
    if ($thrown -notlike $Like) { throw "Expected an error like '$Like' but got '$thrown'." }
}

function New-TestPackage {
    param([string]$PlatformId = 'SampleUnix', [string]$PlatformName = 'Sample Unix via SSH')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $folder = Join-Path $workFolder ("pkg-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -Path $folder -ItemType Directory | Out-Null
    @(
        "PolicyID=$PlatformId            ;Mandatory, unique"
        "PolicyName=$PlatformName"
        'ImmediateInterval=5'
        'Interval=1440'
    ) | Set-Content -LiteralPath (Join-Path $folder "Policy-$PlatformId.ini") -Encoding ASCII
    "<Device Name=`"Operating System`"><Policies><Policy ID=`"$PlatformId`" PlatformBaseID=`"$PlatformId`"/></Policies></Device>" |
        Set-Content -LiteralPath (Join-Path $folder "Policy-$PlatformId.xml") -Encoding ASCII
    $zip = Join-Path $workFolder "$PlatformId-$([guid]::NewGuid().ToString('N').Substring(0, 6)).zip"
    [System.IO.Compression.ZipFile]::CreateFromDirectory($folder, $zip)
    return $zip
}

function New-TestConfiguration {
    param([string]$Json)
    $path = Join-Path $workFolder ("config-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
    return $path
}

function Get-Vault { [System.AppDomain]::CurrentDomain.GetData('MockPsPAS.State') }
function Get-VaultPlatform { param([string]$Id) @((Get-Vault).Platforms) | Where-Object { $_.PlatformID -eq $Id } | Select-Object -First 1 }
function Reset-Vault { & (Get-Module psPAS) { Reset-MockVault } }

$credential = New-Object System.Management.Automation.PSCredential('svc_platforms', (ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))
$quiet = { param($e) }
$zip = New-TestPackage

$standardJson = @'
{
  "Owner": "PAM team",
  "Platforms": [
    {
      "PlatformId": "SampleUnix-PROD",
      "PlatformName": "Sample Unix PROD",
      "Description": "Production servers",
      "State": "Active",
      "Comment": "kept on round trip",
      "Settings": [
        { "Path": "/Policy/General/interval", "Value": 720 },
        { "Operation": "remove", "Path": "Policy/additionalPolicySettings/debug" }
      ],
      "PSM": {
        "PSMServerID": "PSMServer_PROD",
        "Connectors": [ { "PSMConnectorID": "PSM-SSH", "Enabled": true }, { "PSMConnectorID": "PSM-WinSCP" } ]
      }
    },
    { "PlatformId": "SampleUnix-TEST", "PlatformName": "Sample Unix TEST" },
    { "PlatformId": "SampleUnix-DEV", "PlatformName": "Sample Unix DEV", "Enable": true }
  ]
}
'@

Write-Host "`nConfiguration and packages" -ForegroundColor Cyan

Test-Case 'reads platform ID and name from the ZIP' {
    $info = Get-PlatformPackageInfo -Path $zip
    Assert-Equal 'SampleUnix' $info.PlatformId
    Assert-Equal 'Sample Unix via SSH' $info.PlatformName
    Assert-Equal 2 $info.Entries.Count
}

Test-Case 'rejects a file that is not a ZIP archive' {
    $fake = Join-Path $workFolder 'fake.zip'
    Set-Content -LiteralPath $fake -Value 'not a zip'
    Assert-Throws { Get-PlatformPackageInfo -Path $fake } '*not a readable ZIP*'
}

Test-Case 'entries with only the two required fields load (the original script crashed here)' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration $standardJson)
    Assert-Equal 3 $config.Platforms.Count
    $minimal = $config.Platforms[1]
    Assert-Equal '' $minimal.Description
    Assert-Equal 'Unchanged' $minimal.State
    Assert-Equal $false $minimal.ApplyChangesIfPlatformExists
    Assert-Equal 0 @($minimal.Settings).Count
    Assert-True ($null -eq $minimal.PSM)
}

Test-Case 'normalises settings, connectors and the legacy Enable flag' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration $standardJson)
    $prod = $config.Platforms[0]
    Assert-Equal 'Policy/General/interval' $prod.Settings[0].Path 'leading slash should be dropped'
    Assert-Equal 'replace' $prod.Settings[0].Operation
    Assert-Equal '720' $prod.Settings[0].Value
    Assert-Equal 'remove' $prod.Settings[1].Operation
    Assert-Equal $true $prod.PSM.Connectors[1].Enabled 'a connector without Enabled defaults to enabled'
    Assert-Equal 'Active' $config.Platforms[2].State 'Enable:true maps to State Active'
    Assert-Equal 'kept on round trip' $prod.Extra['Comment']
    Assert-Equal 'PAM team' $config.Extra['Owner']
}

Test-Case 'a bare array of platforms is accepted' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration '[ { "PlatformId": "A", "PlatformName": "A" }, { "PlatformId": "B", "PlatformName": "B" } ]')
    Assert-Equal 2 $config.Platforms.Count
}

Test-Case 'broken JSON gives a readable error' {
    Assert-Throws { Read-PlatformVariantConfiguration -Path (New-TestConfiguration '{ "Platforms": [ { ') } '*Could not read configuration file*'
}

Test-Case 'validation reports every problem, not only the first' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration @'
{ "Platforms": [
  { "PlatformId": "SampleUnix", "PlatformName": "Same as source" },
  { "PlatformId": "Dup", "PlatformName": "One" },
  { "PlatformId": "dup", "PlatformName": "Two" },
  { "PlatformId": "Has Space", "PlatformName": "" },
  { "PlatformId": "BadOps", "PlatformName": "Bad", "State": "Sideways",
    "Settings": [ { "Operation": "add", "Path": "x" }, { "Path": "y" }, { "Value": "z" } ],
    "PSM": { "Connectors": [ { "Enabled": true } ] } }
] }
'@)
    $issues = @(Test-PlatformVariantConfiguration -Platforms $config.Platforms -SourcePlatformId 'SampleUnix')
    $messages = ($issues | Where-Object { $_.Severity -eq 'Error' } | ForEach-Object { $_.Message }) -join "`n"
    foreach ($expected in @('same as the source', 'more than once', 'must not contain spaces', 'name is required', "State 'Sideways'", "unsupported operation 'add'", 'replace but has no value', 'has no path', 'no connector ID')) {
        Assert-True ($messages -like "*$expected*") "Missing validation message containing '$expected'."
    }
}

Test-Case 'a valid configuration has no issues' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration $standardJson)
    Assert-Equal 0 @(Test-PlatformVariantConfiguration -Platforms $config.Platforms -SourcePlatformId 'SampleUnix').Count
}

Test-Case 'an empty configuration is an error' {
    $issues = @(Test-PlatformVariantConfiguration -Platforms @() -SourcePlatformId 'X')
    Assert-Equal 1 $issues.Count
    Assert-Equal 'Error' $issues[0].Severity
}

Test-Case 'saving and reloading keeps everything, including unknown fields' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration $standardJson)
    $saved = Save-PlatformVariantConfiguration -Path (Join-Path $workFolder 'roundtrip.json') -Platforms $config.Platforms -Extra $config.Extra
    $again = Read-PlatformVariantConfiguration -Path $saved
    Assert-Equal (ConvertTo-PlatformVariantJson -Platforms $config.Platforms -Extra $config.Extra) (ConvertTo-PlatformVariantJson -Platforms $again.Platforms -Extra $again.Extra)
    $raw = Get-Content -LiteralPath $saved -Raw
    Assert-True ($raw -like '*"Comment": "kept on round trip"*') 'unknown platform field lost'
    Assert-True ($raw -like '*"Owner": "PAM team"*') 'unknown top-level field lost'
    Assert-True ($raw -notlike '*"Enable"*') 'legacy Enable should be written as State'
    $null = $raw | ConvertFrom-Json
}

Test-Case 'JSON writer escapes quotes, backslashes and control characters' {
    $variant = ConvertTo-PlatformVariant -Entry @{ PlatformId = 'Esc'; PlatformName = "Quote `" slash \ tab `t end"; Description = "line1`nline2" }
    $json = ConvertTo-PlatformVariantJson -Platforms @($variant)
    $back = ($json | ConvertFrom-Json).Platforms[0]
    Assert-Equal "Quote `" slash \ tab `t end" $back.PlatformName
    Assert-Equal "line1`nline2" $back.Description
}

Write-Host "`nSettings" -ForegroundColor Cyan

Test-Case 'settings survive a save and load, and passwords are never written' {
    Save-PlatformImportSettings -Settings @{ PVWAURL = 'https://pvwa.example.test'; Username = 'svc_platforms'; AuthType = 'LDAP'; SkipCertificateCheck = $true; Password = 'hunter2'; OTP = '123456'; WindowWidth = 1234.6 }
    $loaded = Get-PlatformImportSettings
    Assert-Equal 'https://pvwa.example.test' $loaded.PVWAURL
    Assert-Equal 'svc_platforms' $loaded.Username
    Assert-Equal 'LDAP' $loaded.AuthType
    Assert-Equal $true $loaded.SkipCertificateCheck
    Assert-Equal 1235 $loaded.WindowWidth
    $raw = Get-Content -LiteralPath $env:IMPORTPLATFORMS_SETTINGS -Raw
    Assert-True ($raw -notmatch 'hunter2|123456|Password|OTP"') 'a secret reached the settings file'
}

Test-Case 'saving some values keeps the others' {
    Save-PlatformImportSettings -Settings @{ SourcePlatformId = 'SampleUnix' }
    $loaded = Get-PlatformImportSettings
    Assert-Equal 'SampleUnix' $loaded.SourcePlatformId
    Assert-Equal 'svc_platforms' $loaded.Username
}

Test-Case 'a damaged settings file falls back to defaults' {
    $path = Join-Path $workFolder 'damaged.json'
    Set-Content -LiteralPath $path -Value '{ not json'
    $loaded = Get-PlatformImportSettings -Path $path
    Assert-Equal 'CyberArk' $loaded.AuthType
    Assert-Equal '' $loaded.PVWAURL
}

Test-Case 'PVWA address is normalised' {
    Assert-Equal 'https://pvwa.example.test' (Resolve-PvwaBaseUri 'pvwa.example.test')
    Assert-Equal 'https://pvwa.example.test' (Resolve-PvwaBaseUri 'https://pvwa.example.test/PasswordVault/')
    Assert-Equal 'https://pvwa.example.test' (Resolve-PvwaBaseUri ' https://pvwa.example.test/PasswordVault/v10/logon/ldap ')
    Assert-Equal 'https://pvwa.example.test:8443' (Resolve-PvwaBaseUri 'https://pvwa.example.test:8443/')
    Assert-Throws { Resolve-PvwaBaseUri '' } '*required*'
    Assert-Throws { Resolve-PvwaBaseUri 'ftp://pvwa' } '*not a valid*'
}

Write-Host "`nImport engine (against the fake Vault)" -ForegroundColor Cyan

$common = @{
    PVWAURL           = 'https://pvwa.example.test/PasswordVault'
    Credential        = $credential
    AuthType          = 'LDAP'
    ConcurrentSession = $true
    SourcePlatformZip = $zip
    OnEvent           = $quiet
    PassThru          = $true
}

Test-Case 'first run imports the source, creates every variant and applies the differences' {
    Reset-Vault
    $config = New-TestConfiguration $standardJson
    $report = Join-Path $workFolder 'run1\report.csv'
    $log = Join-Path $workFolder 'run1\run.log'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile $config -ReportPath $report -LogPath $log

    Assert-True ($null -eq $summary.Error) "Unexpected error: $($summary.Error)"
    Assert-Equal 3 $summary.Completed
    Assert-Equal 0 $summary.Failed
    Assert-Equal 4 (Get-Vault).Platforms.Count 'source + 3 variants'

    $prod = Get-VaultPlatform 'SampleUnix-PROD'
    Assert-Equal 'Sample Unix PROD' $prod.Name
    Assert-Equal 'Production servers' $prod.Description
    Assert-Equal 'SampleUnix' $prod.PlatformBaseID
    Assert-Equal 2 $prod.Operations.Count
    Assert-Equal 'Policy/General/interval' $prod.Operations[0].path
    Assert-Equal '720' $prod.Operations[0].value
    Assert-True (-not $prod.Operations[1].ContainsKey('value')) 'remove must not send a value'
    Assert-Equal 'PSMServer_PROD' $prod.PSM.PSMServerID
    Assert-Equal 2 $prod.PSM.PSMConnectors.Count
    Assert-Equal $true $prod.Active

    Assert-Equal $false (Get-VaultPlatform 'SampleUnix-TEST').Active 'State Unchanged leaves the platform as PVWA created it'
    Assert-Equal $true (Get-VaultPlatform 'SampleUnix-DEV').Active 'legacy Enable:true activates'

    Assert-Equal 'https://pvwa.example.test' (Get-Vault).LastLogon.BaseURI
    Assert-Equal 'LDAP' (Get-Vault).LastLogon.Type
    Assert-Equal $true (Get-Vault).LastLogon.ConcurrentSession
    Assert-Equal $false (Get-Vault).Connected 'session must be closed'
    Assert-True ($null -eq (Get-Vault).Stored) 'held package must be cleaned up'

    Assert-Equal 3 @(Import-Csv -LiteralPath $report).Count
    Assert-True ((Get-Content -LiteralPath $log -Raw) -like '*SampleUnix-PROD*')
    Assert-True ((Get-Content -LiteralPath $log -Raw) -notlike '*not-a-real-password*') 'password leaked into the log'
}

Test-Case 'the package is uploaded again for each variant when PVWA uses it up' {
    $uploads = @((Get-Vault).Calls | Where-Object { $_ -eq 'Import-PASPlatform -ImportFile SampleUnix' }).Count
    Assert-Equal 4 $uploads 'one import of the source plus one conflicting upload per variant'
}

Test-Case 'the package is uploaded once when PVWA keeps it' {
    Reset-Vault
    (Get-Vault).SideBySideConsumesPackage = $false
    (Get-Vault).ConflictThrows = $false
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-Equal 3 $summary.Completed
    $uploads = @((Get-Vault).Calls | Where-Object { $_ -eq 'Import-PASPlatform -ImportFile SampleUnix' }).Count
    Assert-Equal 2 $uploads 'one import of the source plus one conflicting upload'
}

Test-Case 'second run skips existing platforms and changes nothing' {
    $before = (Get-Vault).Calls.Count
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-Equal 3 $summary.Skipped
    Assert-Equal 0 $summary.Failed
    $changing = @((Get-Vault).Calls | Select-Object -Skip $before | Where-Object { $_ -notlike 'New-PASSession*' -and $_ -ne 'Close-PASSession' })
    Assert-Equal 0 $changing.Count "Unexpected calls: $($changing -join ', ')"
}

Test-Case 'existing variants do not confuse the source lookup (shared base ID)' {
    # The original matched on PlatformBaseID too, which made every re-run fail with
    # "More than one exact platform match".
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration '{ "Platforms": [ { "PlatformId": "SampleUnix-NEW", "PlatformName": "Sample Unix NEW" } ] }')
    Assert-True ($null -eq $summary.Error) "Unexpected error: $($summary.Error)"
    Assert-Equal 1 $summary.Completed
}

Test-Case 'ApplyChangesIfPlatformExists updates an existing platform and respects its current state' {
    $json = '{ "Platforms": [ { "PlatformId": "SampleUnix-PROD", "PlatformName": "Sample Unix PROD", "ApplyChangesIfPlatformExists": true, "State": "Active",
        "Settings": [ { "Path": "General/description", "Value": "Updated" } ] } ] }'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $json)
    Assert-Equal 1 $summary.Completed
    Assert-Equal 'Updated' $summary.Report[0].Action
    Assert-Equal 3 (Get-VaultPlatform 'SampleUnix-PROD').Operations.Count
    Assert-True (@((Get-Vault).Calls | Where-Object { $_ -eq 'Enable-PASPlatform SampleUnix-PROD' }).Count -eq 1) 'an already active platform must not be activated again'
}

Test-Case 'State Inactive deactivates' {
    $json = '{ "Platforms": [ { "PlatformId": "SampleUnix-PROD", "PlatformName": "Sample Unix PROD", "ApplyChangesIfPlatformExists": true, "State": "Inactive" } ] }'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $json)
    Assert-Equal 1 $summary.Completed
    Assert-Equal $false (Get-VaultPlatform 'SampleUnix-PROD').Active
}

Test-Case 'dry run reports what would happen and changes nothing' {
    Reset-Vault
    $report = Join-Path $workFolder 'dry\report.csv'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson) -ReportPath $report -WhatIf
    Assert-Equal $true $summary.DryRun
    Assert-Equal 3 $summary.Completed
    Assert-Equal 'WhatIf' $summary.Report[0].Status
    Assert-Equal 0 (Get-Vault).Platforms.Count
    $changing = @((Get-Vault).Calls | Where-Object { $_ -notlike 'New-PASSession*' -and $_ -ne 'Close-PASSession' })
    Assert-Equal 0 $changing.Count "Unexpected calls: $($changing -join ', ')"
    Assert-True (Test-Path -LiteralPath $report) 'a dry run still writes its report'
    Assert-Equal $false (Get-Vault).Connected
}

Test-Case 'a failure stops the run by default and marks the rest as not run' {
    Reset-Vault
    (Get-Vault).FailSettingsFor = @('SampleUnix-PROD')
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-Equal 1 $summary.Failed
    Assert-Equal 2 $summary.NotRun
    Assert-True ($summary.Error -like '*SampleUnix-PROD*')
    Assert-True ($null -eq (Get-VaultPlatform 'SampleUnix-TEST')) 'later platforms must not be created'
    Assert-Equal $false (Get-Vault).Connected 'session must be closed after a failure'
}

Test-Case 'ContinueOnError carries on after a failure' {
    Reset-Vault
    (Get-Vault).FailSettingsFor = @('SampleUnix-PROD')
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson) -ContinueOnError
    Assert-Equal 1 $summary.Failed
    Assert-Equal 2 $summary.Completed
    Assert-True ($null -eq $summary.Error)
}

Test-Case 'without -PassThru a failure is thrown' {
    Reset-Vault
    (Get-Vault).FailSettingsFor = @('SampleUnix-PROD')
    $arguments = $common.Clone(); $arguments.Remove('PassThru')
    Assert-Throws { Invoke-PlatformVariantImport @arguments -ConfigurationFile (New-TestConfiguration $standardJson) } '*SampleUnix-PROD*'
}

Test-Case 'a rejected side-by-side import reports both PVWA messages' {
    Reset-Vault
    $json = '{ "Platforms": [ { "PlatformId": "SampleUnix-REJECT", "PlatformName": "Rejected" } ] }'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $json)
    Assert-Equal 1 $summary.Failed
    Assert-True ($summary.Report[0].Message -like '*was rejected*') $summary.Report[0].Message
    Assert-True ($summary.Report[0].Message -like '*already exists*') 'the upload message should be included to help diagnosis'
}

Test-Case 'an invalid configuration stops before logging on' {
    Reset-Vault
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration '{ "Platforms": [ { "PlatformId": "SampleUnix", "PlatformName": "x" } ] }')
    Assert-True ($summary.Error -like '*1 error(s)*') $summary.Error
    Assert-Equal 0 (Get-Vault).Sessions
}

Test-Case 'a source ID that does not match the ZIP is refused' {
    Reset-Vault
    $summary = Invoke-PlatformVariantImport @common -SourcePlatformId 'SomethingElse' -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like '*does not match the platform in the ZIP*') $summary.Error
    Assert-Equal 0 (Get-Vault).Sessions
}

Test-Case 'an old PVWA is refused before anything is created' {
    Reset-Vault
    (Get-Vault).Version = '14.2'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like '*14.6 or later*') $summary.Error
    Assert-Equal 0 (Get-Vault).Platforms.Count
    Assert-Equal $false (Get-Vault).Connected
}

Test-Case 'setting changes are refused on a PVWA older than 15.2, but plain variants still work' {
    Reset-Vault
    (Get-Vault).Version = '14.6'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like '*15.2 or later*') $summary.Error
    Assert-Equal 0 (Get-Vault).Platforms.Count
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration '{ "Platforms": [ { "PlatformId": "SampleUnix-A", "PlatformName": "A" } ] }')
    Assert-Equal 1 $summary.Completed
}

Test-Case 'a wrong password is reported and nothing is processed' {
    Reset-Vault
    $bad = New-Object System.Management.Automation.PSCredential('svc_platforms', (ConvertTo-SecureString 'wrong' -AsPlainText -Force))
    $arguments = $common.Clone(); $arguments['Credential'] = $bad
    $summary = Invoke-PlatformVariantImport @arguments -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like '*Authentication failure*') $summary.Error
    Assert-Equal 0 $summary.Report.Count
}

Test-Case 'cancelling stops before the next platform' {
    Reset-Vault
    $script:seen = 0
    $cancel = { $script:seen++; $script:seen -gt 1 }
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson) -CancelCheck $cancel
    Assert-Equal $true $summary.Cancelled
    Assert-Equal 1 $summary.Completed
    Assert-Equal 2 $summary.NotRun
}

Test-Case 'connection test reports version and source platform, and logs off' {
    Reset-Vault
    $result = Test-PvwaConnection -PVWAURL 'pvwa.example.test' -Credential $credential -SourcePlatformId 'SampleUnix' -OnEvent $quiet
    Assert-Equal '15.2' ([string]$result.Version)
    Assert-Equal $false $result.SourcePlatformExists
    Assert-Equal $false (Get-Vault).Connected
}

Test-Case 'OTP is only accepted with RADIUS' {
    Reset-Vault
    Assert-Throws { Test-PvwaConnection -PVWAURL 'pvwa.example.test' -Credential $credential -AuthType LDAP -OTP '123456' -OnEvent $quiet } '*only be used with RADIUS*'
    $null = Test-PvwaConnection -PVWAURL 'pvwa.example.test' -Credential $credential -AuthType RADIUS -OTP '123456' -OTPMode Append -OnEvent $quiet
    Assert-Equal 'Append' (Get-Vault).LastLogon.OTPMode
}

Write-Host "`nSource platform not in the Vault" -ForegroundColor Cyan

Test-Case 'the ZIP is imported first, the variants are made from it, and the run says so' {
    Reset-Vault
    $events = New-Object System.Collections.Generic.List[object]
    $collect = { param($e) $events.Add($e) }.GetNewClosure()
    $arguments = $common.Clone(); $arguments['OnEvent'] = $collect
    $summary = Invoke-PlatformVariantImport @arguments -ConfigurationFile (New-TestConfiguration $standardJson)

    Assert-True ($null -eq $summary.Error) "Unexpected error: $($summary.Error)"
    Assert-Equal $true $summary.SourceImported
    Assert-Equal 'SampleUnix' $summary.SourceId
    Assert-Equal 3 $summary.Completed

    $source = Get-VaultPlatform 'SampleUnix'
    Assert-True ($null -ne $source) 'the source platform must now exist'
    Assert-Equal 0 $source.Operations.Count 'the source platform itself is left exactly as imported'
    Assert-True ($null -eq $source.PSM)
    foreach ($id in @('SampleUnix-PROD', 'SampleUnix-TEST', 'SampleUnix-DEV')) {
        Assert-Equal 'SampleUnix' (Get-VaultPlatform $id).PlatformBaseID
    }

    # Order matters: plain import of the source, then a colliding upload, then side by side.
    $calls = @((Get-Vault).Calls | Where-Object { $_ -like 'Import-PASPlatform*' })
    Assert-Equal 'Import-PASPlatform -ImportFile SampleUnix' $calls[0]
    Assert-Equal 'Import-PASPlatform -ImportFile SampleUnix' $calls[1]
    Assert-Equal 'Import-PASPlatform -PlatformId SampleUnix-PROD' $calls[2]

    $log = ($events | Where-Object { $_.Type -eq 'Log' } | ForEach-Object { $_.Message }) -join "`n"
    Assert-True ($log -like "*'SampleUnix' is not in this Vault*") 'the log must say the source was missing'
    Assert-True ($log -like "*was added by this run*") 'the log must say the source was added'
}

Test-Case 'a second run finds the source and does not import it again' {
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration '{ "Platforms": [ { "PlatformId": "SampleUnix-EXTRA", "PlatformName": "Extra" } ] }')
    Assert-Equal $false $summary.SourceImported
    Assert-Equal 1 $summary.Completed
    Assert-Equal 1 @((Get-Vault).Platforms | Where-Object { $_.PlatformID -eq 'SampleUnix' }).Count 'still exactly one source platform'
}

Test-Case 'dry run says the source would be imported, and imports nothing' {
    Reset-Vault
    $events = New-Object System.Collections.Generic.List[object]
    $arguments = $common.Clone(); $arguments['OnEvent'] = { param($e) $events.Add($e) }.GetNewClosure()
    $summary = Invoke-PlatformVariantImport @arguments -ConfigurationFile (New-TestConfiguration $standardJson) -WhatIf
    Assert-Equal $false $summary.SourceImported
    Assert-Equal 3 $summary.Completed
    Assert-Equal 0 (Get-Vault).Platforms.Count
    $log = ($events | Where-Object { $_.Type -eq 'Log' } | ForEach-Object { $_.Message }) -join "`n"
    Assert-True ($log -like '*A real run imports it from the ZIP first*') $log
}

Test-Case 'PVWA refuses the ZIP: the run stops before any variant, with the reason' {
    Reset-Vault
    (Get-Vault).RejectPackage = $true
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like "*'SampleUnix' is not in this Vault and importing it from the ZIP failed*no variants were created*not valid*") $summary.Error
    Assert-Equal $false $summary.SourceImported
    Assert-Equal 0 (Get-Vault).Platforms.Count
    Assert-Equal 0 $summary.Report.Count
    Assert-Equal 0 @((Get-Vault).Calls | Where-Object { $_ -like 'Import-PASPlatform -PlatformId*' }).Count 'no side-by-side import may be attempted'
    Assert-Equal $false (Get-Vault).Connected
}

Test-Case 'the source exists but is not a visible target platform: clear message, nothing left behind' {
    Reset-Vault
    & (Get-Module psPAS) { $hidden = Add-MockPlatform -PlatformId 'SampleUnix' -Name 'Hidden one' -BaseId 'SampleUnix'; $hidden.Hidden = $true }
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like "*already exists, but it is not among the target platforms*") $summary.Error
    Assert-Equal 1 (Get-Vault).Platforms.Count 'nothing may be created'
    Assert-True ($null -eq (Get-Vault).Stored) 'the package PVWA held must be cleaned up'
    Assert-Equal $false (Get-Vault).Connected
}

Test-Case 'PVWA reads a different platform ID out of the ZIP: that ID becomes the source' {
    Reset-Vault
    (Get-Vault).ImportAsId = 'SampleUnixV2'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($null -eq $summary.Error) "Unexpected error: $($summary.Error)"
    Assert-Equal 'SampleUnixV2' $summary.SourceId
    Assert-Equal 3 $summary.Completed
    Assert-Equal 'SampleUnixV2' (Get-VaultPlatform 'SampleUnix-PROD').PlatformBaseID
    Assert-Equal 'SampleUnixV2' $summary.Report[0].SourcePlatformId
}

Test-Case 'a variant that would collide with the ID PVWA gave the source is refused' {
    Reset-Vault
    (Get-Vault).ImportAsId = 'SampleUnix-PROD'
    $summary = Invoke-PlatformVariantImport @common -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like "*A variant uses the platform ID 'SampleUnix-PROD'*") $summary.Error
    Assert-Equal 1 (Get-Vault).Platforms.Count 'only the source was imported'
    Assert-Equal $true $summary.SourceImported 'the summary must admit that the source was added'
}

Write-Host "`nStandard platform names (Human / Machine vault)" -ForegroundColor Cyan

Test-Case 'human vault: the four standard names, in order' {
    $ids = @(New-PlatformVariantSet -VaultType Human -CustomName 'MyApp' | ForEach-Object { $_.PlatformId })
    Assert-Equal 'MyApp-PROD, MyApp-PrePROD, MyApp-PROD-MAN, MyApp-PrePROD-MAN' ($ids -join ', ')
}

Test-Case 'machine vault: the six standard names, in order' {
    $ids = @(New-PlatformVariantSet -VaultType Machine -CustomName 'MyApp' | ForEach-Object { $_.PlatformId })
    Assert-Equal 'MyApp-PROD-D, MyApp-PrePROD-D, MyApp-PROD-RT-RL, MyApp-PROD-RT-RS, MyApp-PrePROD-RT-RL, MyApp-PrePROD-RT-RS' ($ids -join ', ')
}

Test-Case 'generated platforms use the same text as ID and name, and change nothing else' {
    $set = @(New-PlatformVariantSet -VaultType Human -CustomName '  MyApp  ')
    Assert-Equal 'MyApp-PROD' $set[0].PlatformId 'the custom name is trimmed'
    Assert-Equal 'MyApp-PROD' $set[0].PlatformName
    Assert-Equal 'Unchanged' $set[0].State
    Assert-Equal $false $set[0].ApplyChangesIfPlatformExists
    Assert-Equal 0 @($set[0].Settings).Count
    Assert-True ($null -eq $set[0].PSM)
    Assert-Equal 0 @(Test-PlatformVariantConfiguration -Platforms $set -SourcePlatformId 'SampleUnix').Count
}

Test-Case 'standard platforms can be left out by full ID or by suffix, and extra ones added' {
    $ids = @(New-PlatformVariantSet -VaultType Machine -CustomName 'MyApp' -ExcludePlatformId 'MyApp-PROD-D', '-prepROD-rt-rs' -AdditionalPlatformId 'MyApp-DR', ' Other ', 'MyApp-PROD-RT-RL' | ForEach-Object { $_.PlatformId })
    Assert-Equal 'MyApp-PrePROD-D, MyApp-PROD-RT-RL, MyApp-PROD-RT-RS, MyApp-PrePROD-RT-RL, MyApp-DR, Other' ($ids -join ', ') 'an extra that is already on the list is not added twice'
}

Test-Case 'a mistyped exclusion is an error, not a silently created platform' {
    Assert-Throws { New-PlatformVariantSet -VaultType Human -CustomName 'MyApp' -ExcludePlatformId 'MyApp-PROD-MANN' } "*Cannot exclude 'MyApp-PROD-MANN'*"
}

Test-Case 'an empty custom name or an unknown vault type is refused' {
    Assert-Throws { New-PlatformVariantSet -VaultType Human -CustomName '   ' } '*custom name is required*'
    Assert-Throws { New-PlatformVariantSet -VaultType Robot -CustomName 'MyApp' } "*Unknown vault type 'Robot'*"
}

Test-Case 'a custom name that cannot be a platform ID is caught by validation' {
    $issues = @(Test-PlatformVariantConfiguration -Platforms @(New-PlatformVariantSet -VaultType Human -CustomName 'My App') -SourcePlatformId 'SampleUnix')
    Assert-Equal 4 @($issues | Where-Object { $_.Message -like '*must not contain spaces*' }).Count
}

Test-Case 'the engine creates a generated set without any configuration file' {
    Reset-Vault
    $summary = Invoke-PlatformVariantImport @common -Platforms (New-PlatformVariantSet -VaultType Machine -CustomName 'MyApp')
    Assert-True ($null -eq $summary.Error) "Unexpected error: $($summary.Error)"
    Assert-Equal 6 $summary.Completed
    $created = @((Get-Vault).Platforms | Where-Object { $_.PlatformID -ne 'SampleUnix' } | ForEach-Object { $_.PlatformID })
    Assert-Equal 'MyApp-PROD-D, MyApp-PrePROD-D, MyApp-PROD-RT-RL, MyApp-PROD-RT-RS, MyApp-PrePROD-RT-RL, MyApp-PrePROD-RT-RS' ($created -join ', ')
    Assert-Equal 'MyApp-PROD-D' (Get-VaultPlatform 'MyApp-PROD-D').Name
    Assert-Equal 'SampleUnix' (Get-VaultPlatform 'MyApp-PROD-D').PlatformBaseID
    Assert-Equal 0 @((Get-Vault).Calls | Where-Object { $_ -like 'Set-PAS*' -or $_ -like 'Enable-*' -or $_ -like 'Disable-*' }).Count 'names only: no settings, PSM or state change'
}

Test-Case 'running the same generated set again skips what exists' {
    $summary = Invoke-PlatformVariantImport @common -Platforms (New-PlatformVariantSet -VaultType Machine -CustomName 'MyApp')
    Assert-Equal 6 $summary.Skipped
    Assert-Equal 7 (Get-Vault).Platforms.Count
}

Test-Case 'the engine needs exactly one of a list and a configuration file' {
    Reset-Vault
    $summary = Invoke-PlatformVariantImport @common
    Assert-True ($summary.Error -like '*Nothing to create*') $summary.Error
    $summary = Invoke-PlatformVariantImport @common -Platforms (New-PlatformVariantSet -VaultType Human -CustomName 'MyApp') -ConfigurationFile (New-TestConfiguration $standardJson)
    Assert-True ($summary.Error -like '*not both*') $summary.Error
    Assert-Equal 0 (Get-Vault).Sessions
}

Test-Case 'entries that are already normalised pass through unchanged' {
    $config = Read-PlatformVariantConfiguration -Path (New-TestConfiguration $standardJson)
    $again = @($config.Platforms | ForEach-Object { ConvertTo-PlatformVariant -Entry $_ })
    Assert-Equal (ConvertTo-PlatformVariantJson -Platforms $config.Platforms) (ConvertTo-PlatformVariantJson -Platforms $again)
    Assert-Equal 'kept on round trip' $again[0].Extra['Comment']
    Assert-True (-not $again[0].Extra.Contains('Extra')) 'the Extra dictionary must not be nested into itself'
}

Write-Host "`nCommand line script" -ForegroundColor Cyan

$cli = Join-Path $repoRoot 'Import-PlatformVariants.ps1'
# Without this the script would write its reports into the repository's own reports folder.
Save-PlatformImportSettings -Settings @{ ReportFolder = (Join-Path $workFolder 'cli-default-reports') }

Test-Case 'command line run works end to end and remembers its settings' {
    Reset-Vault
    $config = New-TestConfiguration $standardJson
    $report = Join-Path $workFolder 'cli\report.csv'
    $result = & $cli -PVWAURL 'https://pvwa.example.test' -Credential $credential -SourcePlatformZip $zip -ConfigurationFile $config -ReportPath $report -SaveSettings -PassThru 6>$null
    Assert-Equal 3 $result.Completed
    Assert-Equal 4 (Get-Vault).Platforms.Count
    Assert-True (Test-Path -LiteralPath $report)
    $saved = Get-PlatformImportSettings
    Assert-Equal 'https://pvwa.example.test' $saved.PVWAURL
    Assert-Equal 'svc_platforms' $saved.Username
    Assert-Equal $config $saved.ConfigurationFile
}

Test-Case 'command line falls back to the saved address and files' {
    Reset-Vault
    $result = & $cli -Credential $credential -PassThru 6>$null
    Assert-Equal 3 $result.Completed
    Assert-Equal 'https://pvwa.example.test' (Get-Vault).LastLogon.BaseURI
}

Test-Case 'command line -ValidateOnly checks the files without logging on' {
    Reset-Vault
    $result = & $cli -SourcePlatformZip $zip -ConfigurationFile (New-TestConfiguration $standardJson) -ValidateOnly 6>$null
    Assert-Equal $true $result.IsValid
    Assert-Equal 0 (Get-Vault).Sessions
}

Test-Case 'command line -WhatIf changes nothing' {
    Reset-Vault
    $result = & $cli -Credential $credential -WhatIf -PassThru 6>$null
    Assert-Equal $true $result.DryRun
    Assert-Equal 0 (Get-Vault).Platforms.Count
}

Test-Case 'command line throws when a platform fails' {
    Reset-Vault
    (Get-Vault).FailSettingsFor = @('SampleUnix-PROD')
    Assert-Throws { & $cli -Credential $credential 6>$null } '*SampleUnix-PROD*'
}

Test-Case 'command line -VaultType creates the standard platforms without a configuration file' {
    Reset-Vault
    $result = & $cli -Credential $credential -SourcePlatformZip $zip -VaultType Machine -CustomName 'MyApp' -ExcludePlatformId '-PrePROD-RT-RS' -AdditionalPlatformId 'MyApp-DR' -PassThru 6>$null
    Assert-Equal 6 $result.Completed
    $created = @((Get-Vault).Platforms | Where-Object { $_.PlatformID -ne 'SampleUnix' } | ForEach-Object { $_.PlatformID })
    Assert-Equal 'MyApp-PROD-D, MyApp-PrePROD-D, MyApp-PROD-RT-RL, MyApp-PROD-RT-RS, MyApp-PrePROD-RT-RL, MyApp-DR' ($created -join ', ')
}

Test-Case 'command line -VaultType without -CustomName names the platforms after the ZIP' {
    $result = & $cli -SourcePlatformZip $zip -VaultType Human -ValidateOnly 6>$null
    Assert-Equal $true $result.IsValid
    Assert-Equal 'SampleUnix-PROD, SampleUnix-PrePROD, SampleUnix-PROD-MAN, SampleUnix-PrePROD-MAN' ($result.PlatformIds -join ', ')
}

Test-Case 'command line refuses mixed or incomplete naming options' {
    Assert-Throws { & $cli -Credential $credential -SourcePlatformZip $zip -VaultType Human -ConfigurationFile (New-TestConfiguration $standardJson) 6>$null } '*not both*'
    Assert-Throws { & $cli -Credential $credential -SourcePlatformZip $zip -CustomName 'MyApp' 6>$null } '*only work together with -VaultType*'
}

Test-Case 'command line never picks a naming scheme from saved settings' {
    # The GUI may have left "Human" selected; an unattended script run must not act on that.
    Reset-Vault
    Save-PlatformImportSettings -Settings @{ VariantSource = 'Human'; CustomName = 'FromTheGui' }
    $result = & $cli -Credential $credential -PassThru 6>$null
    Assert-Equal 0 @((Get-Vault).Platforms | Where-Object { $_.PlatformID -like 'FromTheGui*' }).Count
    Assert-Equal 3 $result.Completed 'it still runs the saved configuration file'
}

if ($IncludeGui -or $ScreenshotFolder) {
    . (Join-Path $PSScriptRoot 'Invoke-GuiTests.ps1')
}

Write-Host ''
Remove-Item -LiteralPath $workFolder -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed.Count -gt 0) {
    Write-Host "$($script:Passed) passed, $($script:Failed.Count) FAILED:" -ForegroundColor Red
    $script:Failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "$($script:Passed) passed, 0 failed." -ForegroundColor Green
exit 0
