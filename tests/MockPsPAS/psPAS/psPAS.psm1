# A stand-in for psPAS used only by tests\Invoke-Tests.ps1.
# It mimics the PVWA behaviour the importer depends on, with the awkward cases switched on:
#   - uploading a ZIP whose platform already exists does NOT overwrite it; the package is held in
#     memory instead, and (when ConflictThrows is set) the upload still reports an error
#   - a side-by-side import only works while a package is held, and uses it up
# The state lives in the AppDomain so the GUI's background runspace and the test script see the
# same fake Vault.

function Get-MockState {
    $state = [System.AppDomain]::CurrentDomain.GetData('MockPsPAS.State')
    if ($null -eq $state) {
        $state = [hashtable]::Synchronized(@{})
        [System.AppDomain]::CurrentDomain.SetData('MockPsPAS.State', $state)
        Reset-MockVault
    }
    return $state
}

function Reset-MockVault {
    $state = [System.AppDomain]::CurrentDomain.GetData('MockPsPAS.State')
    if ($null -eq $state) {
        $state = [hashtable]::Synchronized(@{})
        [System.AppDomain]::CurrentDomain.SetData('MockPsPAS.State', $state)
    }
    $state.Platforms = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $state.Calls = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $state.Stored = $null
    $state.NextId = 100
    $state.Connected = $false
    $state.Sessions = 0
    $state.LastLogon = $null
    $state.Version = '15.2'
    $state.ConflictThrows = $true
    $state.SideBySideConsumesPackage = $true
    $state.FailSettingsFor = @()
    $state.DelayMilliseconds = 0
    $state.LastPasswordReceived = $null # what the logon call was given (fake test passwords only)
    $state.ExpectedPassword = ''        # when set, any other password is refused like a real PVWA would
    $state.RejectPackage = $false       # PVWA refuses the ZIP outright
    $state.ImportAsId = ''              # PVWA reads a different platform ID out of the ZIP
}

function Add-MockCall {
    param([string]$Text)
    [void](Get-MockState).Calls.Add($Text)
}

function Assert-MockSession {
    if (-not (Get-MockState).Connected) { throw 'Mock psPAS: no session. Call New-PASSession first.' }
}

function Read-MockPackageId {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $entry = $archive.Entries | Where-Object { $_.Name -like '*.ini' } | Select-Object -First 1
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }
    $id = [regex]::Match($text, '(?im)^\s*PolicyID\s*=\s*([^;\r\n]*)').Groups[1].Value.Trim()
    $name = [regex]::Match($text, '(?im)^\s*PolicyName\s*=\s*([^;\r\n]*)').Groups[1].Value.Trim()
    return @{ Id = $id; Name = $name }
}

function Find-MockPlatform {
    param([string]$PlatformId)
    foreach ($platform in @((Get-MockState).Platforms)) {
        if ($platform.PlatformID -ieq $PlatformId) { return $platform }
    }
    return $null
}

function Add-MockPlatform {
    param([string]$PlatformId, [string]$Name, [string]$BaseId, [string]$Description = '', [bool]$Active = $true)
    $state = Get-MockState
    $platform = @{
        ID             = $state.NextId
        PlatformID     = $PlatformId
        Name           = $Name
        PlatformBaseID = $BaseId
        Description    = $Description
        Active         = $Active
        Operations     = New-Object System.Collections.ArrayList
        PSM            = $null
    }
    $state.NextId++
    [void]$state.Platforms.Add($platform)
    return $platform
}

function New-PASSession {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$BaseURI,
        [PSCredential]$Credential,
        [ValidateSet('CyberArk', 'LDAP', 'Windows', 'RADIUS', 'PKI', 'PKIPN')]
        [string]$type = 'CyberArk',
        [string]$OTP,
        [ValidateSet('Append', 'Challenge')]
        [string]$OTPMode,
        [bool]$concurrentSession,
        [switch]$SkipCertificateCheck
    )
    $state = Get-MockState
    # What a real PVWA would receive: psPAS reads the password this way and sends it as JSON.
    $received = $Credential.GetNetworkCredential().Password
    $state.LastPasswordReceived = $received
    if ($received -eq 'wrong' -or ($state.ExpectedPassword -and $received -cne $state.ExpectedPassword)) {
        # Same shape as the real module: "[status] message" with PVWA's error code as the error ID.
        $failure = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception("[401] Authentication failure for User [$($Credential.UserName)].")),
            'ITATS004E', [System.Management.Automation.ErrorCategory]::AuthenticationError, $null)
        $PSCmdlet.ThrowTerminatingError($failure)
    }
    $state.Connected = $true
    $state.Sessions++
    $state.LastLogon = @{
        BaseURI              = $BaseURI
        User                 = $Credential.UserName
        Type                 = $type
        OTP                  = $OTP
        OTPMode              = $OTPMode
        ConcurrentSession    = [bool]$concurrentSession
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
    Add-MockCall "New-PASSession $BaseURI $($Credential.UserName) $type"
}

function Close-PASSession {
    [CmdletBinding()]
    param()
    (Get-MockState).Connected = $false
    Add-MockCall 'Close-PASSession'
}

function Get-PASSession {
    [CmdletBinding()]
    param()
    $state = Get-MockState
    [PSCustomObject]@{ User = $state.LastLogon.User; BaseURI = $state.LastLogon.BaseURI; ExternalVersion = [version]$state.Version }
}

function Get-PASPlatform {
    [CmdletBinding()]
    param([string]$Search)
    Assert-MockSession
    $state = Get-MockState
    if ($state.DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $state.DelayMilliseconds }
    foreach ($platform in @($state.Platforms)) {
        # A platform that exists in the Vault but is not a target platform this user can list.
        if ($platform.ContainsKey('Hidden') -and $platform.Hidden) { continue }
        # Like the real search, this matches the base ID and the name too.
        if ($Search -and "$($platform.PlatformID) $($platform.Name) $($platform.PlatformBaseID)" -notlike "*$Search*") { continue }
        [PSCustomObject]@{
            ID             = $platform.ID
            PlatformID     = $platform.PlatformID
            Name           = $platform.Name
            PlatformBaseID = $platform.PlatformBaseID
            Active         = $platform.Active
        }
    }
}

function Import-PASPlatform {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Import')]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [ValidatePattern('\.zip$')]
        [string]$ImportFile,

        [Parameter(Mandatory = $true, ParameterSetName = 'SideBySide')]
        [string]$PlatformId,

        [Parameter(Mandatory = $true, ParameterSetName = 'SideBySide')]
        [string]$PlatformName,

        [Parameter(ParameterSetName = 'SideBySide')]
        [string]$Description
    )
    Assert-MockSession
    $state = Get-MockState

    if ($PSCmdlet.ParameterSetName -eq 'Import') {
        $package = Read-MockPackageId -Path $ImportFile
        if ($state.ImportAsId) { $package.Id = $state.ImportAsId }
        Add-MockCall "Import-PASPlatform -ImportFile $($package.Id)"
        if ($state.RejectPackage) { throw 'Mock psPAS: [400] The platform package is not valid.' }
        if ($null -ne (Find-MockPlatform -PlatformId $package.Id)) {
            $state.Stored = $package
            if ($state.ConflictThrows) { throw "Mock psPAS: [409] Platform '$($package.Id)' already exists." }
            return
        }
        $null = Add-MockPlatform -PlatformId $package.Id -Name $package.Name -BaseId $package.Id
        return [PSCustomObject]@{ PlatformID = $package.Id }
    }

    Add-MockCall "Import-PASPlatform -PlatformId $PlatformId"
    if ($null -eq $state.Stored) { throw 'Mock psPAS: [404] There is no stored platform to import.' }
    if ($null -ne (Find-MockPlatform -PlatformId $PlatformId)) { throw "Mock psPAS: [409] Platform '$PlatformId' already exists." }
    if ($PlatformId -like '*REJECT*') { throw "Mock psPAS: [400] Platform ID '$PlatformId' was rejected." }
    $null = Add-MockPlatform -PlatformId $PlatformId -Name $PlatformName -BaseId $state.Stored.Id -Description $Description -Active $false
    if ($state.SideBySideConsumesPackage) { $state.Stored = $null }
    return [PSCustomObject]@{ PlatformId = $PlatformId; PlatformName = $PlatformName }
}

function Get-PASStoredPlatform {
    [CmdletBinding()]
    param()
    Assert-MockSession
    $stored = (Get-MockState).Stored
    if ($null -eq $stored) { throw 'Mock psPAS: [404] No stored platform.' }
    [PSCustomObject]@{
        StoredPlatformDetails      = [PSCustomObject]@{ Id = $stored.Id; BaseId = $stored.Id; Name = $stored.Name; Version = '1' }
        ConflictedPlatformsDetails = @()
    }
}

function Remove-PASStoredPlatform {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Assert-MockSession
    (Get-MockState).Stored = $null
    Add-MockCall 'Remove-PASStoredPlatform'
}

function Set-PASPlatform {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [int]$id,
        [hashtable[]]$operations
    )
    Assert-MockSession
    $state = Get-MockState
    $platform = @($state.Platforms) | Where-Object { $_.ID -eq $id } | Select-Object -First 1
    if ($null -eq $platform) { throw "Mock psPAS: [404] Platform $id not found." }
    Add-MockCall "Set-PASPlatform $($platform.PlatformID) x$($operations.Count)"
    if ($state.FailSettingsFor -contains $platform.PlatformID) { throw "Mock psPAS: [400] Setting path is not valid for '$($platform.PlatformID)'." }
    foreach ($operation in $operations) { [void]$platform.Operations.Add($operation) }
}

function Set-PASPlatformPSMConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ID,
        [AllowEmptyString()]
        [string]$PSMServerID,
        [AllowEmptyCollection()]
        [PSObject[]]$PSMConnectors
    )
    Assert-MockSession
    $platform = @((Get-MockState).Platforms) | Where-Object { $_.ID -eq $ID } | Select-Object -First 1
    if ($null -eq $platform) { throw "Mock psPAS: [404] Platform $ID not found." }
    Add-MockCall "Set-PASPlatformPSMConfig $($platform.PlatformID)"
    $platform.PSM = @{ PSMServerID = $PSMServerID; PSMConnectors = @($PSMConnectors) }
}

function Enable-PASPlatform {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$TargetPlatform, [Parameter(Mandatory = $true)][int]$ID)
    Assert-MockSession
    $platform = @((Get-MockState).Platforms) | Where-Object { $_.ID -eq $ID } | Select-Object -First 1
    if ($platform.Active) { throw "Mock psPAS: [400] Platform is already active." }
    $platform.Active = $true
    Add-MockCall "Enable-PASPlatform $($platform.PlatformID)"
}

function Disable-PASPlatform {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$TargetPlatform, [Parameter(Mandatory = $true)][int]$ID)
    Assert-MockSession
    $platform = @((Get-MockState).Platforms) | Where-Object { $_.ID -eq $ID } | Select-Object -First 1
    if (-not $platform.Active) { throw "Mock psPAS: [400] Platform is already inactive." }
    $platform.Active = $false
    Add-MockCall "Disable-PASPlatform $($platform.PlatformID)"
}

Export-ModuleMember -Function *
