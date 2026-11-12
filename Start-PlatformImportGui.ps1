#Requires -Version 5.1
<#
    .SYNOPSIS
    Graphical front end for the CyberArk platform variant importer.

    .DESCRIPTION
    Import tab          - connect to PVWA, pick the platform ZIP and the variant configuration,
                          validate, dry-run or run the import and watch the result per platform.
    Platform editor tab - build and maintain the JSON configuration without writing JSON by hand.

    The PVWA address, authentication type, user name, file locations and options are remembered
    in %APPDATA%\ImportPlatforms\settings.json. The password and one-time code are never saved.

    .PARAMETER NoShow
    Build the window but do not show it. Used by the automated tests (dot-source the script).

    .EXAMPLE
    .\Start-PlatformImportGui.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoShow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    # WPF needs a single-threaded apartment; start again in one.
    $executable = (Get-Process -Id $PID).Path
    & $executable -NoProfile -STA -File $PSCommandPath
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$script:ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'lib\PlatformVariants.psm1'
Import-Module $script:ModulePath -Force -Verbose:$false

#region Window and state ---------------------------------------------------------------------

$xamlText = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'lib\MainWindow.xaml') -Raw -Encoding UTF8
$window = [System.Windows.Markup.XamlReader]::Parse($xamlText)

$ui = @{}
foreach ($match in [regex]::Matches($xamlText, 'x:Name="(\w+)"')) {
    $name = $match.Groups[1].Value
    $ui[$name] = $window.FindName($name)
}
$window.Resources['SettingPaths'] = [string[]]@(Get-PlatformSettingPathSuggestion)

$script:Headless = [bool]$NoShow        # tests: no modal dialogs
$script:Messages = New-Object System.Collections.Generic.List[string]
$script:DialogAnswer = 'Yes'
$script:Loading = $false                # true while code (not the user) fills the controls
$script:Job = $null
$script:LastLoggedMessage = ''
$script:LastReportFolder = ''
$script:AutoSourceId = ''
$script:Plan = New-Object System.Collections.ArrayList     # platforms to create when a naming scheme is used
$script:PlanSignature = $null
$script:CommittingRow = $false
$script:PendingCommitGrid = $null
$script:StateLabels = @('Leave as PVWA creates it', 'Activate', 'Deactivate')
$script:StateValues = @('Unchanged', 'Active', 'Inactive')
$script:Editor = @{
    Platforms = New-Object System.Collections.ArrayList
    Path      = ''
    Dirty     = $false
    Extra     = [ordered]@{}
}

$brushes = New-Object System.Windows.Media.BrushConverter
$script:Brush = @{
    INFO    = $brushes.ConvertFromString('#D1D5DB')
    WARNING = $brushes.ConvertFromString('#FBBF24')
    ERROR   = $brushes.ConvertFromString('#F87171')
    SUCCESS = $brushes.ConvertFromString('#34D399')
    Muted   = $brushes.ConvertFromString('#6B7280')
    Good    = $brushes.ConvertFromString('#047857')
    Warn    = $brushes.ConvertFromString('#B45309')
    Bad     = $brushes.ConvertFromString('#B91C1C')
    Ink     = $brushes.ConvertFromString('#111827')
}

$script:ResultsTable = New-Object System.Data.DataTable
foreach ($column in @('PlatformId', 'PlatformName', 'Status', 'Message', 'Duration', 'Key')) {
    [void]$script:ResultsTable.Columns.Add($column, [string])
}
$ui.ResultsGrid.ItemsSource = $script:ResultsTable.DefaultView

$script:ValidationTable = New-Object System.Data.DataTable
[void]$script:ValidationTable.Columns.Add('Severity', [string])
[void]$script:ValidationTable.Columns.Add('Text', [string])
[void]$script:ValidationTable.Columns.Add('Index', [int])
$ui.ValidationGrid.ItemsSource = $script:ValidationTable.DefaultView

foreach ($type in @('CyberArk', 'LDAP', 'RADIUS', 'Windows')) { [void]$ui.AuthTypeBox.Items.Add($type) }
foreach ($mode in @('(default)', 'Append', 'Challenge')) { [void]$ui.OtpModeBox.Items.Add($mode) }
foreach ($label in $script:StateLabels) { [void]$ui.EdStateBox.Items.Add($label) }

#endregion

#region Shared helpers -----------------------------------------------------------------------

function Show-Message {
    # Every dialog goes through here so the tests can run without anything blocking.
    param(
        [string]$Text,
        [string]$Title = 'Platform Variant Importer',
        [string]$Buttons = 'OK',
        [string]$Icon = 'Information'
    )
    if ($script:Headless) {
        $script:Messages.Add($Text)
        if ($Buttons -eq 'OK') { return 'OK' }
        return $script:DialogAnswer
    }
    return [string][System.Windows.MessageBox]::Show($window, $Text, $Title, $Buttons, $Icon)
}

function Set-Status {
    param([string]$Text)
    $ui.StatusText.Text = $Text
}

function Get-CleanPath {
    # People paste paths with quotes around them (Explorer's "Copy as path").
    param([string]$Text)
    return ([string]$Text).Trim().Trim('"').Trim()
}

function Add-LogLine {
    param([string]$Level, [string]$Message, [datetime]$Time = (Get-Date))

    $paragraph = $ui.LogBox.Document.Blocks.FirstBlock
    $run = New-Object System.Windows.Documents.Run(('{0:HH:mm:ss}  {1}' -f $Time, $Message))
    $brush = $script:Brush[$Level]
    if ($null -eq $brush) { $brush = $script:Brush['INFO'] }
    $run.Foreground = $brush
    $paragraph.Inlines.Add($run)
    $paragraph.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    while ($paragraph.Inlines.Count -gt 6000) { [void]$paragraph.Inlines.Remove($paragraph.Inlines.FirstInline) }
    $ui.LogBox.ScrollToEnd()
    $script:LastLoggedMessage = $Message
}

function Select-File {
    param([string]$Title, [string]$Filter, [string]$Current, [switch]$Save)

    $dialog = if ($Save) { New-Object Microsoft.Win32.SaveFileDialog } else { New-Object Microsoft.Win32.OpenFileDialog }
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $current = Get-CleanPath $Current
    if ($current) {
        $folder = Split-Path -Path $current -Parent
        if ($folder -and (Test-Path -LiteralPath $folder)) { $dialog.InitialDirectory = $folder }
        if ($Save) { $dialog.FileName = Split-Path -Path $current -Leaf }
    }
    if ($dialog.ShowDialog($window)) { return $dialog.FileName }
    return $null
}

#endregion

#region Settings -----------------------------------------------------------------------------

function Get-OtpMode {
    if ($ui.OtpModeBox.SelectedIndex -le 0) { return '' }
    return [string]$ui.OtpModeBox.SelectedItem
}

function Save-UiSettings {
    if ($script:Loading) { return }
    $values = @{
        PVWAURL              = $ui.PvwaUrlBox.Text.Trim()
        AuthType             = [string]$ui.AuthTypeBox.SelectedItem
        Username             = $ui.UsernameBox.Text.Trim()
        OTPMode              = Get-OtpMode
        ConcurrentSession    = [bool]$ui.ConcurrentBox.IsChecked
        SkipCertificateCheck = [bool]$ui.SkipCertBox.IsChecked
        SourcePlatformZip    = Get-CleanPath $ui.ZipPathBox.Text
        SourcePlatformId     = $ui.SourceIdBox.Text.Trim()
        ConfigurationFile    = Get-CleanPath $ui.ConfigPathBox.Text
        VariantSource        = Get-VariantSource
        CustomName           = $ui.CustomNameBox.Text.Trim()
        ReportFolder         = Get-CleanPath $ui.ReportFolderBox.Text
        ContinueOnError      = [bool]$ui.ContinueBox.IsChecked
        DryRun               = [bool]$ui.DryRunBox.IsChecked
        EditorFile           = [string]$script:Editor.Path
        WindowMaximized      = ($window.WindowState -eq [System.Windows.WindowState]::Maximized)
    }
    if ($window.WindowState -eq [System.Windows.WindowState]::Normal -and $window.IsLoaded) {
        $values['WindowWidth'] = $window.ActualWidth
        $values['WindowHeight'] = $window.ActualHeight
        $values['WindowLeft'] = $window.Left
        $values['WindowTop'] = $window.Top
    }
    try {
        Save-PlatformImportSettings -Settings $values
    }
    catch {
        Set-Status "Settings could not be saved: $($_.Exception.Message)"
    }
}

function Set-UiFromSettings {
    param($Settings)

    $script:Loading = $true
    try {
        $ui.PvwaUrlBox.Text = $Settings.PVWAURL
        $ui.AuthTypeBox.SelectedItem = if ($ui.AuthTypeBox.Items -contains $Settings.AuthType) { $Settings.AuthType } else { 'CyberArk' }
        $ui.UsernameBox.Text = $Settings.Username
        $ui.OtpModeBox.SelectedIndex = [System.Math]::Max(0, $ui.OtpModeBox.Items.IndexOf($Settings.OTPMode))
        $ui.ConcurrentBox.IsChecked = $Settings.ConcurrentSession
        $ui.SkipCertBox.IsChecked = $Settings.SkipCertificateCheck
        $ui.ZipPathBox.Text = $Settings.SourcePlatformZip
        $ui.SourceIdBox.Text = $Settings.SourcePlatformId
        $ui.ConfigPathBox.Text = $Settings.ConfigurationFile
        $ui.CustomNameBox.Text = $Settings.CustomName
        switch ($Settings.VariantSource) {
            'File' { $ui.SourceFileRadio.IsChecked = $true }
            'Machine' { $ui.SourceMachineRadio.IsChecked = $true }
            default { $ui.SourceHumanRadio.IsChecked = $true }
        }
        $ui.ReportFolderBox.Text = if ($Settings.ReportFolder) { $Settings.ReportFolder } else { Join-Path -Path $PSScriptRoot -ChildPath 'reports' }
        $ui.ContinueBox.IsChecked = $Settings.ContinueOnError
        $ui.DryRunBox.IsChecked = $Settings.DryRun

        # Restore the window only where it is still visible (a monitor may have gone).
        if ($Settings.WindowWidth -ge $window.MinWidth -and $Settings.WindowHeight -ge $window.MinHeight) {
            $window.Width = $Settings.WindowWidth
            $window.Height = $Settings.WindowHeight
        }
        $screenLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
        $screenTop = [System.Windows.SystemParameters]::VirtualScreenTop
        $screenRight = $screenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
        $screenBottom = $screenTop + [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($Settings.WindowLeft -ge $screenLeft -and $Settings.WindowTop -ge $screenTop -and
            ($Settings.WindowLeft + 200) -lt $screenRight -and ($Settings.WindowTop + 100) -lt $screenBottom) {
            $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
            $window.Left = $Settings.WindowLeft
            $window.Top = $Settings.WindowTop
        }
        if ($Settings.WindowMaximized) { $window.WindowState = [System.Windows.WindowState]::Maximized }
    }
    finally {
        $script:Loading = $false
    }
    Update-AuthFields
}

function Update-AuthFields {
    $isRadius = ([string]$ui.AuthTypeBox.SelectedItem -eq 'RADIUS')
    $ui.OtpRow.Visibility = if ($isRadius) { 'Visible' } else { 'Collapsed' }
    if (-not $isRadius) { $ui.OtpBox.Text = '' }
}

#endregion

#region Import tab: inputs -------------------------------------------------------------------

function Update-PackageInfo {
    $path = Get-CleanPath $ui.ZipPathBox.Text
    if (-not $path) {
        $ui.PackageInfoText.Text = 'Pick the platform package exported from PVWA or downloaded from the Marketplace.'
        $ui.PackageInfoText.Foreground = $script:Brush['Muted']
        return
    }
    try {
        $info = Get-PlatformPackageInfo -Path $path
        if ($info.PlatformId) {
            $name = if ($info.PlatformName) { " ($($info.PlatformName))" } else { '' }
            $ui.PackageInfoText.Text = "Contains platform '$($info.PlatformId)'$name - $($info.Entries.Count) file(s), $([System.Math]::Ceiling($info.SizeBytes / 1KB)) KB."
            $ui.PackageInfoText.Foreground = $script:Brush['Good']
            # Follow the ZIP unless the user typed an ID of their own.
            $current = $ui.SourceIdBox.Text.Trim()
            if (-not $current -or $current -eq $script:AutoSourceId) { $ui.SourceIdBox.Text = $info.PlatformId }
            # The custom name starts as the platform ID. A different ZIP means a different
            # platform family, so the name follows it rather than keep naming the old one.
            $changedPackage = ($script:AutoSourceId -and $script:AutoSourceId -ine $info.PlatformId)
            if (-not $ui.CustomNameBox.Text.Trim() -or $changedPackage) { $ui.CustomNameBox.Text = $info.PlatformId }
            $script:AutoSourceId = $info.PlatformId
        }
        else {
            $ui.PackageInfoText.Text = 'No platform ID was found in this ZIP. Enter the platform ID below.'
            $ui.PackageInfoText.Foreground = $script:Brush['Warn']
        }
    }
    catch {
        $ui.PackageInfoText.Text = $_.Exception.Message
        $ui.PackageInfoText.Foreground = $script:Brush['Bad']
    }
}

function Get-VariantSource {
    # Where the list of platforms comes from: a naming scheme (Human, Machine) or a JSON file.
    if ($ui.SourceFileRadio.IsChecked) { return 'File' }
    if ($ui.SourceMachineRadio.IsChecked) { return 'Machine' }
    return 'Human'
}

function Update-SourcePanels {
    $fromFile = ((Get-VariantSource) -eq 'File')
    $ui.SchemePanel.Visibility = if ($fromFile) { 'Collapsed' } else { 'Visible' }
    $ui.FilePanel.Visibility = if ($fromFile) { 'Visible' } else { 'Collapsed' }
    $ui.PlanToolbar.Visibility = if ($fromFile) { 'Collapsed' } else { 'Visible' }
    $ui.EditConfigButton.Content = if ($fromFile) { 'Open in editor' } else { 'Customise in editor' }
    $ui.EditConfigButton.ToolTip = if ($fromFile) { 'Edit this file on the Platform editor tab.' } else { 'Take this list to the Platform editor to add setting changes or PSM configuration, and save it as a JSON file.' }
}

function Get-PlannedVariants {
    # The platforms the naming scheme list currently holds, as engine entries.
    foreach ($item in $script:Plan) {
        ConvertTo-PlatformVariant -Entry @{ PlatformId = $item.Id; PlatformName = $item.Id }
    }
}

function Update-ConfigSummary {
    # The one-line verdict under "Platforms to create".
    $set = {
        param([string]$Text, [string]$Tone)
        $ui.ConfigSummaryText.Text = $Text
        $ui.ConfigSummaryText.Foreground = $script:Brush[$Tone]
    }
    $source = Get-VariantSource
    try {
        if ($source -eq 'File') {
            $path = Get-CleanPath $ui.ConfigPathBox.Text
            if (-not $path) { & $set 'Pick a JSON file, or build one on the Platform editor tab.' 'Muted'; return }
            $variants = @((Read-PlatformVariantConfiguration -Path $path).Platforms)
            $fixHint = ' - open in the editor to fix.'
        }
        else {
            if (-not $ui.CustomNameBox.Text.Trim()) {
                & $set 'Enter the custom name, or pick the ZIP to use its platform ID.' 'Warn'
                return
            }
            if ($script:Plan.Count -eq 0) { & $set 'The list is empty. Add a platform or choose Reset list.' 'Warn'; return }
            $variants = @(Get-PlannedVariants)
            $fixHint = ''
        }

        $issues = @(Test-PlatformVariantConfiguration -Platforms $variants -SourcePlatformId $ui.SourceIdBox.Text.Trim())
        $errors = @($issues | Where-Object { $_.Severity -eq 'Error' })
        $warnings = $issues.Count - $errors.Count
        $text = "$($variants.Count) platform(s)"
        if ($errors.Count -gt 0) {
            $first = if ($fixHint) { $fixHint } else { ": $($errors[0].PlatformId) - $($errors[0].Message)" }
            & $set "$text, $($errors.Count) error(s)$first" 'Bad'
        }
        elseif ($warnings -gt 0) { & $set "$text, valid, $warnings warning(s)." 'Warn' }
        else { & $set "$text, valid." 'Good' }
    }
    catch {
        & $set $_.Exception.Message 'Bad'
    }
}

function Show-Plan {
    # Lists what a run would create. The same list shows the results afterwards, so it is only
    # rebuilt when the plan itself changed (or -Force), not every time a field loses focus.
    param([switch]$Force)

    if ($null -ne $script:Job) { return }
    $source = Get-VariantSource
    $variants = @()
    $stamp = ''
    try {
        if ($source -eq 'File') {
            $path = Get-CleanPath $ui.ConfigPathBox.Text
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $stamp = [string](Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
                $variants = @((Read-PlatformVariantConfiguration -Path $path).Platforms)
            }
        }
        else {
            $variants = @(Get-PlannedVariants)
        }
    }
    catch {
        $variants = @()
    }

    $signature = "$source|$stamp|" + (@($variants | ForEach-Object { "$($_.PlatformId)=$($_.PlatformName)" }) -join '|')
    if ($Force -or $signature -ne $script:PlanSignature) {
        $script:PlanSignature = $signature
        $script:ResultsTable.Rows.Clear()
        # Until there is a custom name the scheme entries are only suffixes; show where the name goes.
        $needsName = ($source -ne 'File' -and -not $ui.CustomNameBox.Text.Trim())
        foreach ($variant in $variants) {
            $id = [string]$variant.PlatformId
            $shownId = if ($needsName -and $id.StartsWith('-')) { "<name>$id" } else { $id }
            $shownName = if ($needsName -and $id.StartsWith('-')) { $shownId } else { [string]$variant.PlatformName }
            [void]$script:ResultsTable.Rows.Add($shownId, $shownName, 'Planned', '', '', $id)
        }
        $ui.RunProgress.Value = 0
        $ui.ProgressText.Text = if ($variants.Count -gt 0) { "$($variants.Count) platform(s) planned." } else { 'Not started.' }
    }
    Update-ConfigSummary
}

function Update-Plan {
    # Scheme entries follow the custom name; entries typed in as a full ID stay as they are.
    $base = $ui.CustomNameBox.Text.Trim()
    foreach ($item in $script:Plan) {
        if ($null -ne $item.Suffix) { $item.Id = "$base$($item.Suffix)" }
    }
    Show-Plan
}

function Reset-Plan {
    # Back to exactly the standard platforms of the selected vault type.
    $script:Plan.Clear()
    $source = Get-VariantSource
    if ($source -ne 'File') {
        foreach ($suffix in @(Get-PlatformNamingScheme -VaultType $source)) {
            [void]$script:Plan.Add(@{ Suffix = $suffix; Id = '' })
        }
    }
    Update-Plan
}

function Add-PlanEntry {
    $text = $ui.PlanAddBox.Text.Trim()
    if (-not $text) { return }
    # "-DR" means "<custom name>-DR" and keeps following the custom name; anything else is a full ID.
    $entry = if ($text.StartsWith('-')) { @{ Suffix = $text; Id = "$($ui.CustomNameBox.Text.Trim())$text" } } else { @{ Suffix = $null; Id = $text } }
    foreach ($item in $script:Plan) {
        if ($item.Id -ieq $entry.Id) { Set-Status "'$($entry.Id)' is already on the list."; return }
    }
    [void]$script:Plan.Add($entry)
    $ui.PlanAddBox.Text = ''
    Show-Plan
    Set-Status "Added '$($entry.Id)'."
}

function Remove-PlanEntry {
    # Key holds the real ID; after a run the rows come from the engine and only have PlatformId.
    $ids = @($ui.ResultsGrid.SelectedItems | Where-Object { $_ -is [System.Data.DataRowView] } | ForEach-Object {
            if ($_['Key'] -is [string] -and $_['Key']) { $_['Key'] } else { [string]$_['PlatformId'] }
        })
    if ($ids.Count -eq 0) { Set-Status 'Select one or more platforms in the list first.'; return }
    foreach ($id in $ids) {
        for ($index = 0; $index -lt $script:Plan.Count; $index++) {
            if ($script:Plan[$index].Id -ieq $id) { $script:Plan.RemoveAt($index); break }
        }
    }
    Show-Plan -Force
    Set-Status "Removed $($ids -join ', '). Reset list brings the standard platforms back."
}

function Get-ConnectionParameters {
    # Returns $null (after telling the user why) when something is missing.
    $url = $ui.PvwaUrlBox.Text.Trim()
    try { $null = Resolve-PvwaBaseUri -Url $url }
    catch {
        $null = Show-Message -Text $_.Exception.Message -Icon Warning
        $ui.PvwaUrlBox.Focus() | Out-Null
        return $null
    }
    $user = $ui.UsernameBox.Text.Trim()
    if (-not $user) {
        $null = Show-Message -Text 'Enter the user name to log on with.' -Icon Warning
        $ui.UsernameBox.Focus() | Out-Null
        return $null
    }
    if ($ui.PasswordBox.SecurePassword.Length -eq 0) {
        $null = Show-Message -Text 'Enter the password.' -Icon Warning
        $ui.PasswordBox.Focus() | Out-Null
        return $null
    }

    $parameters = @{
        PVWAURL              = $url
        Credential           = New-Object System.Management.Automation.PSCredential($user, $ui.PasswordBox.SecurePassword.Copy())
        AuthType             = [string]$ui.AuthTypeBox.SelectedItem
        ConcurrentSession    = [bool]$ui.ConcurrentBox.IsChecked
        SkipCertificateCheck = [bool]$ui.SkipCertBox.IsChecked
    }
    if ($parameters.AuthType -eq 'RADIUS' -and $ui.OtpBox.Text.Trim()) {
        $parameters['OTP'] = $ui.OtpBox.Text.Trim()
        $parameters['OTPMode'] = Get-OtpMode
    }
    return $parameters
}

function Test-ImportFiles {
    # Offline check of the ZIP and the list of platforms. Returns a summary object, or $null when
    # the inputs cannot even be read (the user has been told).
    param([switch]$Quiet)

    $zip = Get-CleanPath $ui.ZipPathBox.Text
    $source = Get-VariantSource
    $configPath = $null
    $platforms = $null
    try {
        if (-not $zip) { throw 'Pick the platform ZIP first.' }
        $package = Get-PlatformPackageInfo -Path $zip
        $sourceId = $ui.SourceIdBox.Text.Trim()
        if (-not $sourceId) { $sourceId = $package.PlatformId }
        if (-not $sourceId) { throw 'The platform ID could not be read from the ZIP. Enter the source platform ID.' }
        if ($package.PlatformId -and $package.PlatformId -ine $sourceId) {
            throw "The source platform ID '$sourceId' does not match the platform in the ZIP ('$($package.PlatformId)')."
        }

        if ($source -eq 'File') {
            $config = Get-CleanPath $ui.ConfigPathBox.Text
            if (-not $config) { throw 'Pick the configuration file first, or create one on the Platform editor tab.' }
            $configuration = Read-PlatformVariantConfiguration -Path $config
            $configPath = $configuration.Path
            $variants = @($configuration.Platforms)
        }
        else {
            if (-not $ui.CustomNameBox.Text.Trim()) { throw 'Enter the custom name first. It is the first part of every platform name.' }
            if ($script:Plan.Count -eq 0) { throw 'The list of platforms is empty. Add a platform or choose Reset list.' }
            $variants = @(Get-PlannedVariants)
            $platforms = $variants
        }
        $issues = @(Test-PlatformVariantConfiguration -Platforms $variants -SourcePlatformId $sourceId)
    }
    catch {
        Add-LogLine -Level ERROR -Message $_.Exception.Message
        if (-not $Quiet) { $null = Show-Message -Text $_.Exception.Message -Icon Warning }
        return $null
    }

    foreach ($issue in $issues) {
        $level = if ($issue.Severity -eq 'Error') { 'ERROR' } else { 'WARNING' }
        $prefix = if ($issue.PlatformId) { "[$($issue.PlatformId)] " } else { '' }
        Add-LogLine -Level $level -Message "$prefix$($issue.Message)"
    }
    return [PSCustomObject]@{
        ZipPath       = $package.Path
        ConfigPath    = $configPath          # set when the list comes from a file
        Platforms     = $platforms           # set when the list comes from a naming scheme
        Names         = @($variants | ForEach-Object { [string]$_.PlatformId })
        SourceId      = $sourceId
        PlatformCount = $variants.Count
        Errors        = @($issues | Where-Object { $_.Severity -eq 'Error' }).Count
        Warnings      = @($issues | Where-Object { $_.Severity -ne 'Error' }).Count
    }
}

#endregion

#region Import tab: background run -----------------------------------------------------------

function Set-Busy {
    param([bool]$Busy)
    $ui.ImportInputs.IsEnabled = -not $Busy
    $ui.RunButton.IsEnabled = -not $Busy
    $ui.ValidateButton.IsEnabled = -not $Busy
    $ui.PlanToolbar.IsEnabled = -not $Busy
    $ui.CancelButton.IsEnabled = ($Busy -and $null -ne $script:Job -and $script:Job.Mode -eq 'Import')
    $ui.RunProgress.IsIndeterminate = ($Busy -and $null -ne $script:Job -and $script:Job.Mode -ne 'Import')
}

function Start-EngineJob {
    # The engine talks to PVWA and can take minutes, so it runs in its own runspace and reports
    # back through a queue that the UI thread drains on a timer.
    param([string]$Mode, [hashtable]$Parameters)

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $sync = [hashtable]::Synchronized(@{ Cancel = $false })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace

    [void]$powershell.AddScript({
            param($ModulePath, $Mode, $Parameters, $Queue, $Sync)
            try {
                Import-Module $ModulePath -Force -ErrorAction Stop
                $onEvent = { param($item) $Queue.Enqueue($item) }.GetNewClosure()
                if ($Mode -eq 'Import') {
                    $cancelCheck = { [bool]$Sync['Cancel'] }.GetNewClosure()
                    $null = Invoke-PlatformVariantImport @Parameters -OnEvent $onEvent -CancelCheck $cancelCheck -PassThru
                }
                else {
                    $null = Test-PvwaConnection @Parameters -OnEvent $onEvent
                }
            }
            catch {
                $Queue.Enqueue([PSCustomObject]@{ Type = 'Fatal'; Time = (Get-Date); Level = 'ERROR'; Message = $_.Exception.Message; Data = $null })
            }
        }).AddArgument($script:ModulePath).AddArgument($Mode).AddArgument($Parameters).AddArgument($queue).AddArgument($sync)

    $script:Job = @{
        Mode       = $Mode
        PowerShell = $powershell
        Runspace   = $runspace
        Queue      = $queue
        Sync       = $sync
        Handle     = $powershell.BeginInvoke()
        Total      = 0
        Done       = 0
        Failed     = $false
    }
    Set-Busy $true
    $script:JobTimer.Start()
}

function Get-ResultRow {
    param([string]$PlatformId)
    foreach ($row in $script:ResultsTable.Rows) {
        if ([string]$row['PlatformId'] -ieq $PlatformId) { return $row }
    }
    return $null
}

function Receive-EngineEvent {
    param($Item)

    switch ($Item.Type) {
        'Log' {
            Add-LogLine -Level $Item.Level -Message $Item.Message -Time $Item.Time
        }
        'Start' {
            $script:ResultsTable.Rows.Clear()
            foreach ($platform in @($Item.Data.Platforms)) {
                [void]$script:ResultsTable.Rows.Add([string]$platform.PlatformId, [string]$platform.PlatformName, 'Pending', '', '')
            }
            $script:Job.Total = [int]$Item.Data.Total
            $script:Job.Done = 0
            $ui.RunProgress.Maximum = [System.Math]::Max(1, $script:Job.Total)
            $ui.RunProgress.Value = 0
            $ui.ProgressText.Text = "0 of $($script:Job.Total) platform(s) processed."
        }
        'Platform' {
            $row = Get-ResultRow -PlatformId $Item.Data.PlatformId
            if ($null -ne $row) {
                $row['Status'] = 'Running'
                $ui.ResultsGrid.ScrollIntoView($ui.ResultsGrid.Items[$script:ResultsTable.Rows.IndexOf($row)])
            }
            $ui.ProgressText.Text = "Processing '$($Item.Data.PlatformId)' ($($script:Job.Done + 1) of $($script:Job.Total))..."
        }
        'Result' {
            $row = Get-ResultRow -PlatformId $Item.Data.PlatformId
            if ($null -ne $row) {
                $row['Status'] = switch ([string]$Item.Data.Status) {
                    'WhatIf' { 'Would run' }
                    'NotRun' { 'Not run' }
                    default { [string]$Item.Data.Status }
                }
                $row['Message'] = [string]$Item.Data.Message
                $row['Duration'] = if ($null -ne $Item.Data.DurationSeconds) { ([double]$Item.Data.DurationSeconds).ToString('0.0') } else { '' }
            }
            $script:Job.Done++
            $ui.RunProgress.Value = $script:Job.Done
        }
        'Done' {
            $summary = $Item.Data
            $word = if ($summary.DryRun) { 'would be processed' } else { 'completed' }
            $text = "Finished in $($summary.DurationSeconds) s: $($summary.Completed) $word, $($summary.Skipped) skipped, $($summary.Failed) failed, $($summary.NotRun) not run."
            if ($summary.SourceImported) { $text += " Source platform '$($summary.SourceId)' was added to the Vault." }
            if ($summary.Error -and $summary.Total -eq 0) { $text = "Stopped: $($summary.Error)" }
            $ui.ProgressText.Text = $text
            Set-Status $text
            if ($summary.ReportPath) { $script:LastReportFolder = Split-Path -Path $summary.ReportPath -Parent }
            if ($summary.Error -or $summary.Failed -gt 0) { $script:Job.Failed = $true }
        }
        'ConnectionResult' {
            $version = if ($Item.Data.Version) { "PVWA $($Item.Data.Version)" } else { 'PVWA (version unknown)' }
            $text = "Connection OK - $version, logged on as $($Item.Data.User), $($Item.Data.TargetPlatformCount) target platform(s) visible."
            $ui.ProgressText.Text = $text
            Set-Status $text
        }
        'Fatal' {
            # The engine normally logs its own errors; this catches the ones raised before it could.
            if ($Item.Message -ne $script:LastLoggedMessage) { Add-LogLine -Level ERROR -Message $Item.Message -Time $Item.Time }
            $script:Job.Failed = $true
            if ($script:Job.Mode -ne 'Import') {
                $ui.ProgressText.Text = 'Connection test failed.'
                Set-Status "Connection test failed: $($Item.Message)"
            }
            elseif ($script:Job.Total -eq 0) {
                $ui.ProgressText.Text = "Stopped: $($Item.Message)"
                Set-Status "Stopped: $($Item.Message)"
            }
        }
    }
}

function Complete-EngineJob {
    $job = $script:Job
    if ($null -eq $job) { return }
    $script:JobTimer.Stop()
    try { $null = $job.PowerShell.EndInvoke($job.Handle) }
    catch { Add-LogLine -Level ERROR -Message $_.Exception.Message }
    finally {
        $job.PowerShell.Dispose()
        $job.Runspace.Dispose()
    }
    $script:Job = $null
    Set-Busy $false
    $ui.CancelButton.Content = 'Cancel'
}

function Invoke-JobTimerTick {
    $job = $script:Job
    if ($null -eq $job) { $script:JobTimer.Stop(); return }
    $item = $null
    while ($job.Queue.TryDequeue([ref]$item)) { Receive-EngineEvent -Item $item }
    if ($job.Handle.IsCompleted -and $job.Queue.IsEmpty) { Complete-EngineJob }
}

$script:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [timespan]::FromMilliseconds(120)
$script:JobTimer.add_Tick({ Invoke-JobTimerTick })

function Start-ConnectionTest {
    if ($null -ne $script:Job) { return }
    $parameters = Get-ConnectionParameters
    if ($null -eq $parameters) { return }
    Save-UiSettings
    $sourceId = $ui.SourceIdBox.Text.Trim()
    if ($sourceId) { $parameters['SourcePlatformId'] = $sourceId }
    $ui.ProgressText.Text = 'Testing the connection...'
    Add-LogLine -Level INFO -Message '--- Connection test ---'
    Start-EngineJob -Mode 'Test' -Parameters $parameters
}

function Start-Validation {
    Add-LogLine -Level INFO -Message '--- Validation (offline) ---'
    $check = Test-ImportFiles
    if ($null -eq $check) { Set-Status 'Validation failed.'; return }
    if ($check.Errors -gt 0) {
        $text = "$($check.PlatformCount) platform(s) from '$($check.SourceId)': $($check.Errors) error(s), $($check.Warnings) warning(s). See the log."
        Add-LogLine -Level ERROR -Message $text
    }
    else {
        $text = "$($check.PlatformCount) platform(s) from '$($check.SourceId)': valid, $($check.Warnings) warning(s). Nothing was sent to PVWA."
        Add-LogLine -Level SUCCESS -Message $text
    }
    $ui.ProgressText.Text = $text
    Set-Status $text
}

function Start-Import {
    if ($null -ne $script:Job) { return }

    # The editor may hold newer content than the file the import is about to read.
    $fromFile = ((Get-VariantSource) -eq 'File')
    if ($fromFile -and $script:Editor.Dirty -and $script:Editor.Path -and ($script:Editor.Path -ieq (Get-CleanPath $ui.ConfigPathBox.Text))) {
        $answer = Show-Message -Text "The Platform editor has unsaved changes to this configuration.`n`nSave them before running?" -Buttons YesNoCancel -Icon Question
        if ($answer -eq 'Cancel') { return }
        if ($answer -eq 'Yes') { if (-not (Save-EditorFile -Path $script:Editor.Path)) { return } }
    }

    $parameters = Get-ConnectionParameters
    if ($null -eq $parameters) { return }

    $check = Test-ImportFiles
    if ($null -eq $check) { return }
    if ($check.Errors -gt 0) {
        $where = if ($fromFile) { 'fix them in the Platform editor first' } else { 'correct the custom name or the list first' }
        $null = Show-Message -Text "The list of platforms has $($check.Errors) error(s). They are shown in the log; $where." -Icon Warning
        return
    }

    $dryRun = [bool]$ui.DryRunBox.IsChecked
    if (-not $dryRun) {
        # Name every platform: this is the last look before they are created in the Vault.
        $shown = @($check.Names | Select-Object -First 12 | ForEach-Object { "    $_" })
        if ($check.Names.Count -gt 12) { $shown += "    ... and $($check.Names.Count - 12) more" }
        $question = "Create or update $($check.PlatformCount) platform(s) from '$($check.SourceId)' on`n$(Resolve-PvwaBaseUri -Url $parameters.PVWAURL)`nas $($parameters.Credential.UserName)?`n`n$($shown -join "`n")"
        if ((Show-Message -Text $question -Buttons YesNo -Icon Question) -ne 'Yes') { return }
    }

    $reportFolder = Get-CleanPath $ui.ReportFolderBox.Text
    if (-not $reportFolder) {
        $reportFolder = Join-Path -Path $PSScriptRoot -ChildPath 'reports'
        $ui.ReportFolderBox.Text = $reportFolder
    }
    Save-UiSettings

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = if ($dryRun) { '-dryrun' } else { '' }
    $parameters['SourcePlatformZip'] = $check.ZipPath
    $parameters['SourcePlatformId'] = $check.SourceId
    if ($null -ne $check.Platforms) { $parameters['Platforms'] = $check.Platforms }
    else { $parameters['ConfigurationFile'] = $check.ConfigPath }
    $parameters['ReportPath'] = Join-Path -Path $reportFolder -ChildPath "PlatformImport-$stamp$suffix.csv"
    $parameters['LogPath'] = Join-Path -Path $reportFolder -ChildPath "PlatformImport-$stamp$suffix.log"
    $parameters['ContinueOnError'] = [bool]$ui.ContinueBox.IsChecked
    $parameters['WhatIf'] = $dryRun
    $script:LastReportFolder = $reportFolder

    Show-Plan -Force
    $ui.ProgressText.Text = 'Connecting...'
    Add-LogLine -Level INFO -Message $(if ($dryRun) { '--- Dry run ---' } else { '--- Import ---' })
    Start-EngineJob -Mode 'Import' -Parameters $parameters
}

#endregion

#region Platform editor ----------------------------------------------------------------------

function New-SettingsTable {
    $table = New-Object System.Data.DataTable
    $column = $table.Columns.Add('Operation', [string]); $column.DefaultValue = 'replace'; $column.AllowDBNull = $false
    $column = $table.Columns.Add('Path', [string]); $column.DefaultValue = ''; $column.AllowDBNull = $false
    $column = $table.Columns.Add('Value', [string]); $column.DefaultValue = ''; $column.AllowDBNull = $false
    return , $table
}

function New-ConnectorsTable {
    $table = New-Object System.Data.DataTable
    $column = $table.Columns.Add('PSMConnectorID', [string]); $column.DefaultValue = ''; $column.AllowDBNull = $false
    $column = $table.Columns.Add('Enabled', [bool]); $column.DefaultValue = $true; $column.AllowDBNull = $false
    return , $table
}

function New-EditorPlatform {
    # $Variant is a normalised entry from the engine, or $null for a blank one.
    param($Variant)

    $settings = New-SettingsTable
    $connectors = New-ConnectorsTable
    $item = @{
        PlatformId   = ''
        PlatformName = ''
        Description  = ''
        State        = 'Unchanged'
        Apply        = $false
        PsmEnabled   = $false
        PsmServerId  = ''
        Settings     = $settings
        Connectors   = $connectors
        Extra        = [ordered]@{}
    }

    if ($null -ne $Variant) {
        $item.PlatformId = [string]$Variant.PlatformId
        $item.PlatformName = [string]$Variant.PlatformName
        $item.Description = [string]$Variant.Description
        $item.State = [string]$Variant.State
        $item.Apply = [bool]$Variant.ApplyChangesIfPlatformExists
        $item.Extra = $Variant.Extra
        foreach ($setting in @($Variant.Settings)) {
            $value = if ($null -eq $setting.Value) { '' } else { [string]$setting.Value }
            [void]$settings.Rows.Add([string]$setting.Operation, [string]$setting.Path, $value)
        }
        if ($null -ne $Variant.PSM) {
            $item.PsmEnabled = $true
            $item.PsmServerId = [string]$Variant.PSM.PSMServerID
            foreach ($connector in @($Variant.PSM.Connectors)) {
                [void]$connectors.Rows.Add([string]$connector.PSMConnectorID, [bool]$connector.Enabled)
            }
        }
    }

    # Attached after the initial fill so loading a file does not mark it as changed.
    foreach ($table in @($settings, $connectors)) {
        $table.add_RowChanged({ Set-EditorDirty })
        $table.add_RowDeleted({ Set-EditorDirty })
    }
    return $item
}

function ConvertFrom-EditorPlatform {
    # Editor model -> normalised entry, through the same code that reads the JSON file.
    param($Item)

    $settings = @(
        foreach ($row in $Item.Settings.Rows) {
            $path = ([string]$row['Path']).Trim()
            $value = [string]$row['Value']
            if (-not $path -and -not $value) { continue }      # a row that was added but never filled in
            @{ Operation = [string]$row['Operation']; Path = $path; Value = $value }
        }
    )
    $entry = @{
        PlatformId                   = $Item.PlatformId
        PlatformName                 = $Item.PlatformName
        Description                  = $Item.Description
        State                        = $Item.State
        ApplyChangesIfPlatformExists = $Item.Apply
        Settings                     = $settings
        Extra                        = $Item.Extra
    }
    if ($Item.PsmEnabled) {
        $entry['PSM'] = @{
            PSMServerID = $Item.PsmServerId
            Connectors  = @(
                foreach ($row in $Item.Connectors.Rows) {
                    $id = ([string]$row['PSMConnectorID']).Trim()
                    if (-not $id) { continue }
                    @{ PSMConnectorID = $id; Enabled = [bool]$row['Enabled'] }
                }
            )
        }
    }
    return (ConvertTo-PlatformVariant -Entry $entry)
}

function Get-EditorVariants {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in $script:Editor.Platforms) { $list.Add((ConvertFrom-EditorPlatform -Item $item)) }
    return , $list.ToArray()
}

function Get-CurrentEditorPlatform {
    $index = $ui.PlatformList.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:Editor.Platforms.Count) { return $null }
    return $script:Editor.Platforms[$index]
}

function Complete-GridEdits {
    # A cell still being typed in has not reached the table yet.
    foreach ($grid in @($ui.SettingsGrid, $ui.ConnectorsGrid)) {
        [void]$grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true)
        [void]$grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
    }
}

function New-PlatformListItem {
    $idText = New-Object System.Windows.Controls.TextBlock
    $idText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $idText.TextTrimming = 'CharacterEllipsis'
    $nameText = New-Object System.Windows.Controls.TextBlock
    $nameText.FontSize = 12
    $nameText.Foreground = $script:Brush['Muted']
    $nameText.TextTrimming = 'CharacterEllipsis'
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add($idText)
    [void]$panel.Children.Add($nameText)
    $listItem = New-Object System.Windows.Controls.ListBoxItem
    $listItem.Content = $panel
    $listItem.Padding = New-Object System.Windows.Thickness(8, 5, 8, 5)
    $listItem.Tag = @{ Id = $idText; Name = $nameText }
    return $listItem
}

function Update-EditorView {
    # Refreshes everything derived from the model: list captions, checks, JSON preview, title.
    $variants = Get-EditorVariants
    $issues = @(Test-PlatformVariantConfiguration -Platforms $variants -SourcePlatformId $ui.SourceIdBox.Text.Trim())
    if ($variants.Count -eq 0) { $issues = @() }      # an empty new document is not worth a red error

    $withErrors = @{}
    $script:ValidationTable.Rows.Clear()
    foreach ($issue in $issues) {
        if ($issue.Severity -eq 'Error') { $withErrors[[int]$issue.Index] = $true }
        $prefix = if ($issue.PlatformId) { "$($issue.PlatformId): " } else { '' }
        [void]$script:ValidationTable.Rows.Add([string]$issue.Severity, "$prefix$($issue.Message)", [int]$issue.Index)
    }
    $errors = @($issues | Where-Object { $_.Severity -eq 'Error' }).Count
    if ($variants.Count -eq 0) { $ui.ValidationTitle.Text = 'Checks'; $ui.ValidationTitle.Foreground = $script:Brush['Ink'] }
    elseif ($errors -gt 0) { $ui.ValidationTitle.Text = "Checks - $errors error(s)"; $ui.ValidationTitle.Foreground = $script:Brush['Bad'] }
    elseif ($issues.Count -gt 0) { $ui.ValidationTitle.Text = "Checks - $($issues.Count) warning(s)"; $ui.ValidationTitle.Foreground = $script:Brush['Warn'] }
    else { $ui.ValidationTitle.Text = 'Checks - all good'; $ui.ValidationTitle.Foreground = $script:Brush['Good'] }

    for ($index = 0; $index -lt $script:Editor.Platforms.Count; $index++) {
        $item = $script:Editor.Platforms[$index]
        $captions = $ui.PlatformList.Items[$index].Tag
        $captions.Id.Text = if ($item.PlatformId.Trim()) { $item.PlatformId.Trim() } else { '(no platform ID)' }
        $captions.Id.Foreground = if ($withErrors.ContainsKey($index)) { $script:Brush['Bad'] } else { $script:Brush['Ink'] }
        $captions.Name.Text = if ($item.PlatformName.Trim()) { $item.PlatformName.Trim() } else { '(no name)' }
    }

    $ui.PlatformCountText.Text = "Variants ($($script:Editor.Platforms.Count))"
    $ui.JsonPreviewBox.Text = ConvertTo-PlatformVariantJson -Platforms $variants -Extra $script:Editor.Extra
    $fileText = if ($script:Editor.Path) { $script:Editor.Path } else { 'New configuration (not saved yet)' }
    if ($script:Editor.Dirty) { $fileText += '  *  unsaved changes' }
    $ui.EditorFileText.Text = $fileText

    $hasSelection = ($ui.PlatformList.SelectedIndex -ge 0)
    $ui.PlatformDuplicateButton.IsEnabled = $hasSelection
    $ui.PlatformRemoveButton.IsEnabled = $hasSelection
    $ui.PlatformUpButton.IsEnabled = ($ui.PlatformList.SelectedIndex -gt 0)
    $ui.PlatformDownButton.IsEnabled = ($hasSelection -and $ui.PlatformList.SelectedIndex -lt $script:Editor.Platforms.Count - 1)
}

$script:EditorTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:EditorTimer.Interval = [timespan]::FromMilliseconds(250)
$script:EditorTimer.add_Tick({
        $script:EditorTimer.Stop()
        Update-EditorView
    })

function Set-EditorDirty {
    if ($script:Loading) { return }
    $script:Editor.Dirty = $true
    # Typing fires this for every key; refresh once the user pauses.
    $script:EditorTimer.Stop()
    $script:EditorTimer.Start()
}

function Show-EditorPlatform {
    # Loads the selected variant into the detail form.
    Complete-GridEdits
    $item = Get-CurrentEditorPlatform
    $script:Loading = $true
    try {
        if ($null -eq $item) {
            $ui.EditorDetail.Visibility = 'Collapsed'
            $ui.EditorEmptyText.Visibility = 'Visible'
            $ui.SettingsGrid.ItemsSource = $null
            $ui.ConnectorsGrid.ItemsSource = $null
        }
        else {
            $ui.EdIdBox.Text = $item.PlatformId
            $ui.EdNameBox.Text = $item.PlatformName
            $ui.EdDescriptionBox.Text = $item.Description
            $ui.EdStateBox.SelectedIndex = [System.Math]::Max(0, [array]::IndexOf($script:StateValues, $item.State))
            $ui.EdApplyBox.IsChecked = $item.Apply
            $ui.EdPsmBox.IsChecked = $item.PsmEnabled
            $ui.EdPsmServerBox.Text = $item.PsmServerId
            $ui.PsmPanel.IsEnabled = $item.PsmEnabled
            $ui.SettingsGrid.ItemsSource = $item.Settings.DefaultView
            $ui.ConnectorsGrid.ItemsSource = $item.Connectors.DefaultView
            $ui.EditorEmptyText.Visibility = 'Collapsed'
            $ui.EditorDetail.Visibility = 'Visible'
        }
    }
    finally {
        $script:Loading = $false
    }
}

function Set-EditorDocument {
    # Replaces the whole editor content.
    param([object[]]$Variants, [System.Collections.IDictionary]$Extra, [string]$Path)

    $script:EditorTimer.Stop()
    $script:Loading = $true
    try {
        $ui.PlatformList.Items.Clear()
        $script:Editor.Platforms.Clear()
        foreach ($variant in @($Variants | Where-Object { $null -ne $_ })) {
            [void]$script:Editor.Platforms.Add((New-EditorPlatform -Variant $variant))
            [void]$ui.PlatformList.Items.Add((New-PlatformListItem))
        }
        $script:Editor.Extra = if ($null -ne $Extra) { $Extra } else { [ordered]@{} }
        $script:Editor.Path = $Path
        $script:Editor.Dirty = $false
    }
    finally {
        $script:Loading = $false
    }
    $ui.PlatformList.SelectedIndex = if ($script:Editor.Platforms.Count -gt 0) { 0 } else { -1 }
    Show-EditorPlatform
    Update-EditorView
}

function Open-EditorFile {
    param([string]$Path)
    try {
        $configuration = Read-PlatformVariantConfiguration -Path $Path
    }
    catch {
        $null = Show-Message -Text $_.Exception.Message -Icon Warning
        return $false
    }
    Set-EditorDocument -Variants $configuration.Platforms -Extra $configuration.Extra -Path $configuration.Path
    Set-Status "Opened $($configuration.Path)."
    Save-UiSettings
    return $true
}

function Save-EditorFile {
    param([string]$Path)

    Complete-GridEdits
    if (-not $Path) {
        $Path = Select-File -Title 'Save platform configuration' -Filter 'JSON files (*.json)|*.json' -Current $(if ($script:Editor.Path) { $script:Editor.Path } else { Join-Path $PSScriptRoot 'platforms.json' }) -Save
        if (-not $Path) { return $false }
    }
    $variants = Get-EditorVariants
    try {
        $saved = Save-PlatformVariantConfiguration -Path $Path -Platforms $variants -Extra $script:Editor.Extra
    }
    catch {
        $null = Show-Message -Text "The file could not be saved.`n$($_.Exception.Message)" -Icon Error
        return $false
    }
    $script:Editor.Path = $saved
    $script:Editor.Dirty = $false
    $script:EditorTimer.Stop()
    Update-EditorView

    $errors = @($script:ValidationTable.Rows | Where-Object { $_['Severity'] -eq 'Error' }).Count
    Set-Status $(if ($errors -gt 0) { "Saved $saved - it still has $errors error(s), see Checks." } else { "Saved $saved." })

    # First file ever saved becomes the import's configuration; an already chosen one is kept.
    $importPath = Get-CleanPath $ui.ConfigPathBox.Text
    if (-not $importPath) { $ui.ConfigPathBox.Text = $saved }
    Show-Plan
    Save-UiSettings
    return $true
}

function Confirm-EditorChanges {
    # $true when it is fine to replace or close the current document.
    if (-not $script:Editor.Dirty) { return $true }
    $answer = Show-Message -Text "The platform configuration has unsaved changes.`n`nSave them?" -Buttons YesNoCancel -Icon Question
    if ($answer -eq 'Cancel') { return $false }
    if ($answer -eq 'Yes') { return (Save-EditorFile -Path $script:Editor.Path) }
    return $true
}

function Add-EditorPlatform {
    param($Variant)
    Complete-GridEdits
    [void]$script:Editor.Platforms.Add((New-EditorPlatform -Variant $Variant))
    [void]$ui.PlatformList.Items.Add((New-PlatformListItem))
    $ui.PlatformList.SelectedIndex = $script:Editor.Platforms.Count - 1
    $script:Editor.Dirty = $true
    Update-EditorView
    $ui.PlatformList.ScrollIntoView($ui.PlatformList.SelectedItem)
    $ui.EdIdBox.Focus() | Out-Null
}

function Copy-EditorPlatform {
    $item = Get-CurrentEditorPlatform
    if ($null -eq $item) { return }
    Complete-GridEdits
    $copy = ConvertFrom-EditorPlatform -Item $item
    $copy.PlatformId = if ($copy.PlatformId) { "$($copy.PlatformId)-Copy" } else { '' }
    $copy.PlatformName = if ($copy.PlatformName) { "$($copy.PlatformName) (copy)" } else { '' }
    Add-EditorPlatform -Variant $copy
    $ui.EdIdBox.SelectAll()
}

function Remove-EditorPlatform {
    $index = $ui.PlatformList.SelectedIndex
    if ($index -lt 0) { return }
    $item = $script:Editor.Platforms[$index]
    $label = if ($item.PlatformId.Trim()) { "'$($item.PlatformId.Trim())'" } else { 'this variant' }
    if ((Show-Message -Text "Remove $label from the configuration?" -Buttons YesNo -Icon Question) -ne 'Yes') { return }
    $script:Editor.Platforms.RemoveAt($index)
    $ui.PlatformList.Items.RemoveAt($index)
    $ui.PlatformList.SelectedIndex = [System.Math]::Min($index, $script:Editor.Platforms.Count - 1)
    $script:Editor.Dirty = $true
    Show-EditorPlatform
    Update-EditorView
}

function Move-EditorPlatform {
    param([int]$Offset)
    $index = $ui.PlatformList.SelectedIndex
    $target = $index + $Offset
    if ($index -lt 0 -or $target -lt 0 -or $target -ge $script:Editor.Platforms.Count) { return }
    Complete-GridEdits
    $item = $script:Editor.Platforms[$index]
    $script:Editor.Platforms.RemoveAt($index)
    $script:Editor.Platforms.Insert($target, $item)
    # The list captions are rebuilt from the model, so only the selection has to move.
    $ui.PlatformList.SelectedIndex = $target
    $script:Editor.Dirty = $true
    Show-EditorPlatform
    Update-EditorView
}

function Add-GridRow {
    param($Grid, [string]$TableName)
    $item = Get-CurrentEditorPlatform
    if ($null -eq $item) { return }
    Complete-GridEdits
    $table = $item[$TableName]
    [void]$table.Rows.Add($table.NewRow())
    $Grid.SelectedIndex = $table.Rows.Count - 1
    $Grid.ScrollIntoView($Grid.SelectedItem)
    $Grid.Focus() | Out-Null
}

function Remove-GridRow {
    param($Grid)
    $selected = $Grid.SelectedItem
    if ($selected -isnot [System.Data.DataRowView]) { return }
    Complete-GridEdits
    $selected.Row.Table.Rows.Remove($selected.Row)
}

#endregion

#region Event wiring -------------------------------------------------------------------------

# --- settings persistence: anything the user leaves or toggles is saved straight away ---------
foreach ($name in @('PvwaUrlBox', 'UsernameBox', 'SourceIdBox')) {
    $ui[$name].add_LostFocus({ Save-UiSettings })
}
$ui.ReportFolderBox.add_LostFocus({ $ui.ReportFolderBox.Text = Get-CleanPath $ui.ReportFolderBox.Text; Save-UiSettings })
foreach ($name in @('ConcurrentBox', 'SkipCertBox', 'DryRunBox', 'ContinueBox')) {
    $ui[$name].add_Click({ Save-UiSettings })
}
$ui.AuthTypeBox.add_SelectionChanged({ Update-AuthFields; Save-UiSettings })
$ui.OtpModeBox.add_SelectionChanged({ Save-UiSettings })
$ui.DryRunBox.add_Click({ $ui.RunButton.Content = if ($ui.DryRunBox.IsChecked) { 'Run dry run' } else { 'Run import' } })

# Paths pasted with quotes ("Copy as path" in Explorer) are shown the way they are used.
$ui.ZipPathBox.add_LostFocus({ $ui.ZipPathBox.Text = Get-CleanPath $ui.ZipPathBox.Text; Update-PackageInfo; Show-Plan; Save-UiSettings })
$ui.ConfigPathBox.add_LostFocus({ $ui.ConfigPathBox.Text = Get-CleanPath $ui.ConfigPathBox.Text; Show-Plan; Save-UiSettings })
$ui.SourceIdBox.add_LostFocus({ Update-ConfigSummary })

# --- what to create: vault type switch, custom name, and the list itself ----------------------
foreach ($name in @('SourceHumanRadio', 'SourceMachineRadio', 'SourceFileRadio')) {
    $ui[$name].add_Checked({
            if ($script:Loading) { return }
            Update-SourcePanels
            # Another vault type means another standard set, so the list starts over.
            if ((Get-VariantSource) -eq 'File') { Show-Plan -Force } else { Reset-Plan }
            Save-UiSettings
        })
}
$ui.CustomNameBox.add_TextChanged({ if (-not $script:Loading) { Update-Plan } })
$ui.CustomNameBox.add_LostFocus({ Save-UiSettings })
$ui.PlanAddButton.add_Click({ Add-PlanEntry })
$ui.PlanAddBox.add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Add-PlanEntry }
    })
$ui.PlanRemoveButton.add_Click({ Remove-PlanEntry })
$ui.PlanResetButton.add_Click({ Reset-Plan; Show-Plan -Force; Set-Status 'The list is back to the standard platforms.' })
$ui.ResultsGrid.add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Delete -and $null -eq $script:Job -and (Get-VariantSource) -ne 'File') {
            $e.Handled = $true
            Remove-PlanEntry
        }
    })

$ui.BrowseZipButton.add_Click({
        $path = Select-File -Title 'Select the platform ZIP' -Filter 'Platform packages (*.zip)|*.zip|All files (*.*)|*.*' -Current $ui.ZipPathBox.Text
        if ($path) { $ui.ZipPathBox.Text = $path; Update-PackageInfo; Show-Plan; Save-UiSettings }
    })
$ui.BrowseConfigButton.add_Click({
        $path = Select-File -Title 'Select the platform configuration' -Filter 'JSON files (*.json)|*.json|All files (*.*)|*.*' -Current $ui.ConfigPathBox.Text
        if ($path) { $ui.ConfigPathBox.Text = $path; Show-Plan; Save-UiSettings }
    })
$ui.BrowseReportButton.add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Folder for the CSV reports and log files'
        $current = Get-CleanPath $ui.ReportFolderBox.Text
        if ($current -and (Test-Path -LiteralPath $current)) { $dialog.SelectedPath = $current }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.ReportFolderBox.Text = $dialog.SelectedPath; Save-UiSettings }
    })

$ui.TestConnectionButton.add_Click({ Start-ConnectionTest })
$ui.ValidateButton.add_Click({ Start-Validation })
$ui.RunButton.add_Click({ Start-Import })
$ui.CancelButton.add_Click({
        if ($null -ne $script:Job) {
            $script:Job.Sync['Cancel'] = $true
            $ui.CancelButton.IsEnabled = $false
            $ui.CancelButton.Content = 'Cancelling...'
            Add-LogLine -Level WARNING -Message 'Cancel requested. The platform in progress will be finished first.'
        }
    })
$ui.ClearLogButton.add_Click({ $ui.LogBox.Document.Blocks.FirstBlock.Inlines.Clear() })
$ui.OpenReportButton.add_Click({
        $folder = if ($script:LastReportFolder) { $script:LastReportFolder } else { Get-CleanPath $ui.ReportFolderBox.Text }
        if ($folder -and (Test-Path -LiteralPath $folder)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`"" }
        else { Set-Status 'No report has been written yet.' }
    })
$ui.EditConfigButton.add_Click({
        if ((Get-VariantSource) -ne 'File') {
            # Hand the generated list to the editor as a new, unsaved document.
            if (-not (Confirm-EditorChanges)) { return }
            Set-EditorDocument -Variants @(Get-PlannedVariants) -Extra ([ordered]@{}) -Path ''
            $script:Editor.Dirty = ($script:Editor.Platforms.Count -gt 0)
            Update-EditorView
            $ui.MainTabs.SelectedItem = $ui.EditorTab
            Set-Status 'The list is in the editor. Save it as a JSON file, then choose "Use this file for the import".'
            return
        }
        $path = Get-CleanPath $ui.ConfigPathBox.Text
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $alreadyOpen = ($script:Editor.Path -and $script:Editor.Path -ieq (Resolve-Path -LiteralPath $path).ProviderPath)
            if (-not $alreadyOpen) {
                if (-not (Confirm-EditorChanges)) { return }
                if (-not (Open-EditorFile -Path $path)) { return }
            }
        }
        $ui.MainTabs.SelectedItem = $ui.EditorTab
    })

# --- editor: toolbar -------------------------------------------------------------------------
$ui.EditorNewButton.add_Click({
        if (-not (Confirm-EditorChanges)) { return }
        Set-EditorDocument -Variants @() -Extra ([ordered]@{}) -Path ''
        Set-Status 'New configuration.'
    })
$ui.EditorOpenButton.add_Click({
        if (-not (Confirm-EditorChanges)) { return }
        $path = Select-File -Title 'Open platform configuration' -Filter 'JSON files (*.json)|*.json|All files (*.*)|*.*' -Current $(if ($script:Editor.Path) { $script:Editor.Path } else { $ui.ConfigPathBox.Text })
        if ($path) { $null = Open-EditorFile -Path $path }
    })
$ui.EditorSaveButton.add_Click({ $null = Save-EditorFile -Path $script:Editor.Path })
$ui.EditorSaveAsButton.add_Click({ $null = Save-EditorFile -Path '' })
$ui.EditorUseButton.add_Click({
        if ($script:Editor.Dirty -or -not $script:Editor.Path) {
            if (-not (Save-EditorFile -Path $script:Editor.Path)) { return }
        }
        $ui.ConfigPathBox.Text = $script:Editor.Path
        if ($ui.SourceFileRadio.IsChecked) { Show-Plan -Force } else { $ui.SourceFileRadio.IsChecked = $true }
        Save-UiSettings
        $ui.MainTabs.SelectedItem = $ui.ImportTab
    })

# --- editor: list of variants ----------------------------------------------------------------
$ui.PlatformList.add_SelectionChanged({
        if ($script:Loading) { return }
        Show-EditorPlatform
        Update-EditorView
    })
$ui.PlatformAddButton.add_Click({ Add-EditorPlatform -Variant $null })
$ui.PlatformDuplicateButton.add_Click({ Copy-EditorPlatform })
$ui.PlatformRemoveButton.add_Click({ Remove-EditorPlatform })
$ui.PlatformUpButton.add_Click({ Move-EditorPlatform -Offset -1 })
$ui.PlatformDownButton.add_Click({ Move-EditorPlatform -Offset 1 })

# --- editor: fields of the selected variant --------------------------------------------------
$ui.EdIdBox.add_TextChanged({
        $item = Get-CurrentEditorPlatform
        if ($script:Loading -or $null -eq $item) { return }
        $item.PlatformId = $ui.EdIdBox.Text
        Set-EditorDirty
    })
$ui.EdNameBox.add_TextChanged({
        $item = Get-CurrentEditorPlatform
        if ($script:Loading -or $null -eq $item) { return }
        $item.PlatformName = $ui.EdNameBox.Text
        Set-EditorDirty
    })
$ui.EdDescriptionBox.add_TextChanged({
        $item = Get-CurrentEditorPlatform
        if ($script:Loading -or $null -eq $item) { return }
        $item.Description = $ui.EdDescriptionBox.Text
        Set-EditorDirty
    })
$ui.EdStateBox.add_SelectionChanged({
        $item = Get-CurrentEditorPlatform
        if ($script:Loading -or $null -eq $item -or $ui.EdStateBox.SelectedIndex -lt 0) { return }
        $item.State = $script:StateValues[$ui.EdStateBox.SelectedIndex]
        Set-EditorDirty
    })
$ui.EdApplyBox.add_Click({
        $item = Get-CurrentEditorPlatform
        if ($null -eq $item) { return }
        $item.Apply = [bool]$ui.EdApplyBox.IsChecked
        Set-EditorDirty
    })
$ui.EdPsmBox.add_Click({
        $item = Get-CurrentEditorPlatform
        if ($null -eq $item) { return }
        $item.PsmEnabled = [bool]$ui.EdPsmBox.IsChecked
        $ui.PsmPanel.IsEnabled = $item.PsmEnabled
        Set-EditorDirty
    })
$ui.EdPsmServerBox.add_TextChanged({
        $item = Get-CurrentEditorPlatform
        if ($script:Loading -or $null -eq $item) { return }
        $item.PsmServerId = $ui.EdPsmServerBox.Text
        Set-EditorDirty
    })

$ui.SettingAddButton.add_Click({ Add-GridRow -Grid $ui.SettingsGrid -TableName 'Settings' })
$ui.SettingRemoveButton.add_Click({ Remove-GridRow -Grid $ui.SettingsGrid })
$ui.ConnectorAddButton.add_Click({ Add-GridRow -Grid $ui.ConnectorsGrid -TableName 'Connectors' })
$ui.ConnectorRemoveButton.add_Click({ Remove-GridRow -Grid $ui.ConnectorsGrid })

# A grid row normally reaches its table only when the user leaves the row. Committing it as soon
# as a cell is done keeps the JSON preview and the checks in step with what is on screen.
$commitRowAfterCell = {
    param($sender, $e)
    if ($script:CommittingRow -or $e.EditAction -ne [System.Windows.Controls.DataGridEditAction]::Commit) { return }
    $script:PendingCommitGrid = $sender
    $null = $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] {
            $grid = $script:PendingCommitGrid
            if ($null -eq $grid) { return }
            $script:CommittingRow = $true
            try { [void]$grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) }
            finally { $script:CommittingRow = $false }
        })
}
$ui.SettingsGrid.add_CellEditEnding($commitRowAfterCell)
$ui.ConnectorsGrid.add_CellEditEnding($commitRowAfterCell)

$ui.ValidationGrid.add_MouseDoubleClick({
        $selected = $ui.ValidationGrid.SelectedItem
        if ($selected -is [System.Data.DataRowView]) {
            $index = [int]$selected['Index']
            if ($index -ge 0 -and $index -lt $script:Editor.Platforms.Count) { $ui.PlatformList.SelectedIndex = $index }
        }
    })

# --- window ----------------------------------------------------------------------------------
$ui.MainTabs.add_SelectionChanged({
        param($sender, $e)
        # Only react to the tab control itself, not to combo boxes and lists inside the tabs.
        if ($e.OriginalSource -ne $ui.MainTabs) { return }
        if ($ui.MainTabs.SelectedItem -eq $ui.EditorTab) { Update-EditorView }
        else { Update-ConfigSummary }
    })

$window.add_PreviewKeyDown({
        param($sender, $e)
        $control = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)
        if ($control -and $e.Key -eq [System.Windows.Input.Key]::S -and $ui.MainTabs.SelectedItem -eq $ui.EditorTab) {
            $e.Handled = $true
            $null = Save-EditorFile -Path $script:Editor.Path
        }
    })

$window.add_Closing({
        param($sender, $e)
        if ($null -ne $script:Job -and $script:Job.Mode -eq 'Import') {
            $answer = Show-Message -Text "An import is still running.`n`nClosing now stops it after the platform in progress. Close anyway?" -Buttons YesNo -Icon Warning
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        }
        if (-not (Confirm-EditorChanges)) { $e.Cancel = $true; return }
        Save-UiSettings
        if ($null -ne $script:Job) {
            # Ask the engine to stop and give it a moment to log off cleanly.
            $script:Job.Sync['Cancel'] = $true
            $null = $script:Job.Handle.AsyncWaitHandle.WaitOne(15000)
            $script:JobTimer.Stop()
        }
    })

# An error in an event handler should be shown, not take the whole window down.
$window.Dispatcher.add_UnhandledException({
        param($sender, $e)
        $e.Handled = $true
        $message = $e.Exception.Message
        if ($null -ne $e.Exception.InnerException) { $message = $e.Exception.InnerException.Message }
        try { Add-LogLine -Level ERROR -Message "Unexpected error: $message" } catch { }
        Set-Status "Unexpected error: $message"
    })

#endregion

#region Start --------------------------------------------------------------------------------

$script:Settings = Get-PlatformImportSettings
Set-UiFromSettings -Settings $script:Settings
$ui.RunButton.Content = if ($ui.DryRunBox.IsChecked) { 'Run dry run' } else { 'Run import' }
$ui.SettingsPathText.Text = "Settings: $(Get-PlatformImportSettingsPath)"
Update-PackageInfo
Update-SourcePanels
if ((Get-VariantSource) -eq 'File') { Show-Plan -Force } else { Reset-Plan }

# Reopen what was being edited last time; otherwise show the import's configuration.
$reopened = $false
foreach ($candidate in @($script:Settings.EditorFile, $script:Settings.ConfigurationFile)) {
    if (-not $reopened -and $candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        try {
            $configuration = Read-PlatformVariantConfiguration -Path $candidate
            Set-EditorDocument -Variants $configuration.Platforms -Extra $configuration.Extra -Path $configuration.Path
            $reopened = $true
        }
        catch { }
    }
}
if (-not $reopened) { Set-EditorDocument -Variants @() -Extra ([ordered]@{}) -Path '' }
Set-Status 'Ready.'

if ($NoShow) { return }

$window.add_ContentRendered({
        # Put the cursor where the user most likely continues.
        if (-not $ui.PvwaUrlBox.Text) { $ui.PvwaUrlBox.Focus() | Out-Null }
        elseif (-not $ui.UsernameBox.Text) { $ui.UsernameBox.Focus() | Out-Null }
        else { $ui.PasswordBox.Focus() | Out-Null }
    })
$null = $window.ShowDialog()

#endregion
