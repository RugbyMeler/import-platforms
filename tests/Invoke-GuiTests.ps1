# Dot-sourced by Invoke-Tests.ps1 when -IncludeGui or -ScreenshotFolder is given.
# Builds the real window (off screen), drives it the way a user would and checks the outcome.

Write-Host "`nGUI" -ForegroundColor Cyan

Reset-Vault
Remove-Item -LiteralPath $env:IMPORTPLATFORMS_SETTINGS -ErrorAction SilentlyContinue

. (Join-Path $repoRoot 'Start-PlatformImportGui.ps1') -NoShow

$window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
$window.Left = -6000
$window.Top = 0
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Show()

function Invoke-UiPump {
    # Lets the dispatcher run (timers, layout, queued events) for a moment.
    param([int]$Milliseconds = 120)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromMilliseconds($Milliseconds)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-EngineJob {
    param([int]$TimeoutSeconds = 90)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($null -ne $script:Job -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Invoke-UiPump 100 }
    if ($null -ne $script:Job) { throw "The background job did not finish within $TimeoutSeconds seconds." }
    Invoke-UiPump 50
}

function Invoke-Click {
    param($Button)
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

function Save-Screenshot {
    param([string]$Name)
    if (-not $ScreenshotFolder) { return }
    if (-not (Test-Path -LiteralPath $ScreenshotFolder)) { New-Item -Path $ScreenshotFolder -ItemType Directory -Force | Out-Null }
    Invoke-UiPump 200
    $root = $window.Content
    $width = [int][System.Math]::Ceiling($root.ActualWidth)
    $height = [int][System.Math]::Ceiling($root.ActualHeight)
    $rectangle = New-Object System.Windows.Rect(0, 0, $width, $height)
    $visual = New-Object System.Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    $context.DrawRectangle($window.Background, $null, $rectangle)
    $context.DrawRectangle((New-Object System.Windows.Media.VisualBrush($root)), $null, $rectangle)
    $context.Close()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Create((Join-Path $ScreenshotFolder "$Name.png"))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Get-LogText {
    $range = New-Object System.Windows.Documents.TextRange($ui.LogBox.Document.ContentStart, $ui.LogBox.Document.ContentEnd)
    return $range.Text
}

function Get-ResultStatuses {
    return @($script:ResultsTable.Rows | ForEach-Object { [string]$_['Status'] })
}

function Get-ListedIds {
    return (@($script:ResultsTable.Rows | ForEach-Object { [string]$_['PlatformId'] }) -join ', ')
}

function Select-ListedPlatform {
    param([string[]]$Id)
    $ui.ResultsGrid.SelectedItems.Clear()
    foreach ($view in @($ui.ResultsGrid.Items)) {
        if ($Id -contains [string]$view['PlatformId']) { [void]$ui.ResultsGrid.SelectedItems.Add($view) }
    }
}

$guiConfig = Join-Path $workFolder 'gui-platforms.json'
$guiReports = Join-Path $workFolder 'gui-reports'

Test-Case 'window builds and every named control is found' {
    $missing = @($ui.Keys | Where-Object { $null -eq $ui[$_] -and $_ -notin @('Chrome', 'LogParagraph') })
    Assert-Equal 0 $missing.Count "Not found: $($missing -join ', ')"
    Assert-Equal 'CyberArk' ([string]$ui.AuthTypeBox.SelectedItem)
    Assert-True ($ui.ReportFolderBox.Text -like '*reports') 'report folder should default to .\reports'
}

function New-TestLogo {
    # A grey placeholder image, so the tests never need (or ship) a real company logo.
    param([string]$Path)
    $visual = New-Object System.Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    $context.DrawRectangle([System.Windows.Media.Brushes]::Gainsboro, $null, (New-Object System.Windows.Rect(0, 0, 120, 40)))
    $text = New-Object System.Windows.Media.FormattedText('LOGO', [cultureinfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight,
        (New-Object System.Windows.Media.Typeface('Segoe UI')), 22, [System.Windows.Media.Brushes]::DimGray)
    $context.DrawText($text, (New-Object System.Windows.Point(30, 5)))
    $context.Close()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(120, 40, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

Test-Case 'banner: shows the tool name and the credit' {
    Assert-Equal 'Platformer 2.0' $window.Title
    Assert-Equal 'Platformer' $ui.BannerNameText.Text
    Assert-Equal '2.0' $ui.BannerVersionText.Text
    Assert-Equal 'Made by PAS Squad' $ui.BannerCreditText.Text
    Assert-Equal 'Platformer 2.0' $script:AppName 'dialogs are titled with the same name'
    Assert-True $ui.BannerNameText.IsVisible
    Assert-True $ui.BannerCreditText.IsVisible
}

Test-Case 'banner: the logo comes from a local file, and the tool starts fine without one' {
    $logoFolder = Join-Path $workFolder 'assets'
    New-Item -Path $logoFolder -ItemType Directory -Force | Out-Null
    Assert-True ($null -eq (Find-BannerLogo -Folder $logoFolder)) 'an empty folder has no logo'
    Assert-Equal $false (Set-BannerLogo -Path '')
    Assert-Equal 'Collapsed' ([string]$ui.BannerLogo.Visibility)

    Set-Content -LiteralPath (Join-Path $logoFolder 'logo.jpg') -Value 'this is not an image'
    Assert-Equal (Join-Path $logoFolder 'logo.jpg') (Find-BannerLogo -Folder $logoFolder)
    Assert-Equal $false (Set-BannerLogo -Path (Join-Path $logoFolder 'logo.jpg')) 'a broken image is ignored, not an error'
    Assert-Equal 'Collapsed' ([string]$ui.BannerLogo.Visibility)

    New-TestLogo -Path (Join-Path $logoFolder 'logo.png')
    Assert-Equal (Join-Path $logoFolder 'logo.png') (Find-BannerLogo -Folder $logoFolder) 'PNG is preferred'
    Assert-Equal $true (Set-BannerLogo -Path (Find-BannerLogo -Folder $logoFolder))
    Assert-Equal 'Visible' ([string]$ui.BannerLogo.Visibility)
    Invoke-UiPump 200
    Assert-Equal 30 ([int]$ui.BannerLogo.ActualHeight) 'the logo is scaled to the banner'
    Assert-Equal 90 ([int]$ui.BannerLogo.ActualWidth) 'and keeps its proportions'

    # The file is read once and not held open, so it can be replaced while the tool runs.
    Remove-Item -LiteralPath (Join-Path $logoFolder 'logo.png')
    Assert-Equal 'Visible' ([string]$ui.BannerLogo.Visibility)
    New-TestLogo -Path (Join-Path $logoFolder 'logo.png')      # stays on for the screenshots
    $null = Set-BannerLogo -Path (Join-Path $logoFolder 'logo.png')
}

Test-Case 'naming: a fresh window is set to the human vault and waits for a name' {
    Assert-Equal 'Human' (Get-VariantSource)
    Assert-Equal $true $ui.SourceHumanRadio.IsChecked
    Assert-Equal 'Visible' ([string]$ui.SchemePanel.Visibility)
    Assert-Equal 'Collapsed' ([string]$ui.FilePanel.Visibility)
    Assert-Equal 'Visible' ([string]$ui.PlanToolbar.Visibility)
    Assert-Equal '<name>-PROD, <name>-PrePROD, <name>-PROD-MAN, <name>-PrePROD-MAN' (Get-ListedIds) 'without a name the list shows where it goes'
    Assert-True ($ui.ConfigSummaryText.Text -like 'Enter the custom name*') $ui.ConfigSummaryText.Text

    # Removing works on the placeholder rows too.
    Select-ListedPlatform '<name>-PROD-MAN'
    Invoke-Click $ui.PlanRemoveButton
    Assert-Equal '<name>-PROD, <name>-PrePROD, <name>-PrePROD-MAN' (Get-ListedIds)
    Invoke-Click $ui.PlanResetButton
    Assert-Equal 4 $script:ResultsTable.Rows.Count
}
Save-Screenshot '1-import-empty'

Test-Case 'editor: building a configuration from scratch produces the expected JSON' {
    $ui.MainTabs.SelectedItem = $ui.EditorTab
    Invoke-UiPump
    Invoke-Click $ui.PlatformAddButton
    $ui.EdIdBox.Text = 'SampleUnix-PROD'
    $ui.EdNameBox.Text = 'Sample Unix PROD'
    $ui.EdDescriptionBox.Text = 'Production servers'
    $ui.EdStateBox.SelectedIndex = 1
    Invoke-Click $ui.SettingAddButton
    $item = Get-CurrentEditorPlatform
    $item.Settings.Rows[0]['Path'] = 'Policy/General/interval'
    $item.Settings.Rows[0]['Value'] = '720'
    Invoke-Click $ui.SettingAddButton
    $item.Settings.Rows[1]['Operation'] = 'remove'
    $item.Settings.Rows[1]['Path'] = 'Policy/additionalPolicySettings/debug'
    Invoke-Click $ui.SettingAddButton      # left blank on purpose: must not reach the file
    $ui.EdPsmBox.IsChecked = $true
    Invoke-Click $ui.EdPsmBox
    $ui.EdPsmBox.IsChecked = $true
    $item.PsmEnabled = $true
    $ui.EdPsmServerBox.Text = 'PSMServer_PROD'
    Invoke-Click $ui.ConnectorAddButton
    $item.Connectors.Rows[0]['PSMConnectorID'] = 'PSM-SSH'

    Invoke-Click $ui.PlatformAddButton
    $ui.EdIdBox.Text = 'SampleUnix-TEST'
    $ui.EdNameBox.Text = 'Sample Unix TEST'
    Invoke-UiPump 400

    Assert-Equal 2 $script:Editor.Platforms.Count
    Assert-True $script:Editor.Dirty 'editing must mark the document as changed'
    Assert-True ($ui.EditorFileText.Text -like '*unsaved changes*')
    $preview = $ui.JsonPreviewBox.Text | ConvertFrom-Json
    Assert-Equal 'SampleUnix-PROD' $preview.Platforms[0].PlatformId
    Assert-Equal 'Active' $preview.Platforms[0].State
    Assert-Equal 2 @($preview.Platforms[0].Settings).Count 'the blank row must be left out'
    Assert-Equal 'PSMServer_PROD' $preview.Platforms[0].PSM.PSMServerID
    Assert-Equal 'PSM-SSH' $preview.Platforms[0].PSM.Connectors[0].PSMConnectorID
    Assert-Equal 'Checks - all good' $ui.ValidationTitle.Text
}

Test-Case 'editor: problems show up in the checks and on the list' {
    $ui.EdIdBox.Text = 'SampleUnix-PROD'       # duplicate of the first one
    Invoke-UiPump 400
    Assert-True ($ui.ValidationTitle.Text -like 'Checks - 1 error*') $ui.ValidationTitle.Text
    Assert-True ([string]$script:ValidationTable.Rows[0]['Text'] -like '*more than once*')
    $ui.EdIdBox.Text = 'SampleUnix-TEST'
    Invoke-UiPump 400
    Assert-Equal 'Checks - all good' $ui.ValidationTitle.Text
}

Test-Case 'editor: duplicate, move and remove keep list and model in step' {
    $ui.PlatformList.SelectedIndex = 0
    Invoke-Click $ui.PlatformDuplicateButton
    Assert-Equal 3 $script:Editor.Platforms.Count
    Assert-Equal 'SampleUnix-PROD-Copy' $script:Editor.Platforms[2].PlatformId
    Assert-Equal 2 $script:Editor.Platforms[2].Settings.Rows.Count 'settings must be copied (without the blank row)'
    Assert-Equal 2 $ui.PlatformList.SelectedIndex
    $ui.EdIdBox.Text = 'SampleUnix-DEV'
    $ui.EdNameBox.Text = 'Sample Unix DEV'
    Invoke-Click $ui.PlatformUpButton
    Assert-Equal 'SampleUnix-DEV' $script:Editor.Platforms[1].PlatformId
    Assert-Equal 1 $ui.PlatformList.SelectedIndex
    Assert-Equal 'SampleUnix-DEV' $ui.EdIdBox.Text
    Invoke-UiPump 400
    Assert-Equal 'SampleUnix-DEV' $ui.PlatformList.Items[1].Tag.Id.Text
    Assert-Equal 'SampleUnix-TEST' $ui.PlatformList.Items[2].Tag.Id.Text

    $ui.PlatformList.SelectedIndex = 2
    $script:DialogAnswer = 'No'
    Invoke-Click $ui.PlatformRemoveButton
    Assert-Equal 3 $script:Editor.Platforms.Count 'answering No must keep the variant'
    $script:DialogAnswer = 'Yes'
    Invoke-Click $ui.PlatformRemoveButton
    Assert-Equal 2 $script:Editor.Platforms.Count
    Assert-Equal 2 $ui.PlatformList.Items.Count
    Invoke-Click $ui.PlatformAddButton
    $ui.EdIdBox.Text = 'SampleUnix-TEST'
    $ui.EdNameBox.Text = 'Sample Unix TEST'
    $ui.PlatformList.SelectedIndex = 0
    Invoke-UiPump 400
}
Save-Screenshot '2-editor'

Test-Case 'editor: saving writes a file the engine reads back identically' {
    Assert-True (Save-EditorFile -Path $guiConfig)
    Assert-Equal $false $script:Editor.Dirty
    Assert-Equal $guiConfig $ui.ConfigPathBox.Text 'the first saved file becomes the import configuration'
    $read = Read-PlatformVariantConfiguration -Path $guiConfig
    Assert-Equal 3 $read.Platforms.Count
    Assert-Equal ($ui.JsonPreviewBox.Text) (ConvertTo-PlatformVariantJson -Platforms $read.Platforms -Extra $read.Extra)
    Assert-Equal 'remove' $read.Platforms[0].Settings[1].Operation
}

Test-Case 'editor: opening a hand-written file keeps unknown fields through a save' {
    $handWritten = New-TestConfiguration $standardJson
    Assert-True (Open-EditorFile -Path $handWritten)
    Assert-Equal 3 $script:Editor.Platforms.Count
    Assert-Equal 'SampleUnix-PROD' $ui.EdIdBox.Text
    Assert-Equal 1 $ui.EdStateBox.SelectedIndex
    Assert-Equal $true $ui.EdPsmBox.IsChecked
    Assert-Equal 2 $ui.ConnectorsGrid.Items.Count
    Assert-Equal $false $script:Editor.Dirty 'opening a file must not mark it as changed'
    $ui.EdDescriptionBox.Text = 'Edited in the GUI'
    Assert-True (Save-EditorFile -Path $handWritten)
    $raw = Get-Content -LiteralPath $handWritten -Raw
    Assert-True ($raw -like '*"Comment": "kept on round trip"*')
    Assert-True ($raw -like '*"Owner": "PAM team"*')
    Assert-True ($raw -like '*Edited in the GUI*')
    Assert-True (Open-EditorFile -Path $guiConfig)
}

function Find-EditableComboBox {
    param($Parent)
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child -is [System.Windows.Controls.ComboBox] -and $child.IsEditable) { return $child }
        $found = Find-EditableComboBox -Parent $child
        if ($null -ne $found) { return $found }
    }
    return $null
}

Test-Case 'editor: a setting path can be picked or typed in the grid cell itself' {
    $ui.MainTabs.SelectedItem = $ui.EditorTab
    $ui.PlatformList.SelectedIndex = 0
    Invoke-UiPump 300
    $grid = $ui.SettingsGrid
    $grid.Focus() | Out-Null
    $grid.CurrentCell = New-Object System.Windows.Controls.DataGridCellInfo($grid.Items[0], $grid.Columns[1])
    Assert-True ($grid.BeginEdit()) 'the path cell should enter edit mode'
    Invoke-UiPump 300
    $combo = Find-EditableComboBox -Parent $grid
    Assert-True ($null -ne $combo) 'the path cell should show an editable drop-down'
    Assert-True ($combo.Items.Count -gt 20) 'the drop-down should offer the known setting paths'
    Assert-Equal 'Policy/General/interval' $combo.Text
    $combo.Text = 'General/description'
    Assert-True ($grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true))
    Invoke-UiPump 500       # the row is committed and the preview refreshed without leaving the row
    Assert-Equal 'General/description' ([string]$script:Editor.Platforms[0].Settings.Rows[0]['Path'])
    Assert-True ($ui.JsonPreviewBox.Text -like '*"Path": "General/description"*') 'the preview should follow the grid'
    Assert-True $script:Editor.Dirty
    $script:Editor.Platforms[0].Settings.Rows[0]['Path'] = 'Policy/General/interval'
    Assert-True (Save-EditorFile -Path $guiConfig)
}

Test-Case 'naming: picking the ZIP names the four human-vault platforms after it' {
    $ui.MainTabs.SelectedItem = $ui.ImportTab
    $ui.ZipPathBox.Text = "`"$zip`""        # pasted with quotes, as Explorer copies it
    Update-PackageInfo
    Assert-Equal 'SampleUnix' $ui.SourceIdBox.Text
    Assert-True ($ui.PackageInfoText.Text -like "*'SampleUnix'*")
    Assert-Equal 'SampleUnix' $ui.CustomNameBox.Text 'the custom name starts as the platform ID'
    Assert-Equal 'SampleUnix-PROD, SampleUnix-PrePROD, SampleUnix-PROD-MAN, SampleUnix-PrePROD-MAN' (Get-ListedIds)
    Assert-Equal 'Planned,Planned,Planned,Planned' ((Get-ResultStatuses) -join ',')
    Assert-Equal '4 platform(s), valid.' $ui.ConfigSummaryText.Text
    Assert-Equal '4 platform(s) planned.' $ui.ProgressText.Text
}

Test-Case 'naming: a ZIP with a different platform renames the list; the same ZIP keeps a typed name' {
    $other = New-TestPackage -PlatformId 'OtherApp' -PlatformName 'Other App'
    $ui.CustomNameBox.Text = 'Typed'
    $ui.ZipPathBox.Text = $zip
    Update-PackageInfo
    Assert-Equal 'Typed' $ui.CustomNameBox.Text 'picking the same platform again must not overwrite a typed name'

    $ui.ZipPathBox.Text = $other
    Update-PackageInfo
    Assert-Equal 'OtherApp' $ui.CustomNameBox.Text 'a different platform must not keep the previous name'
    Assert-Equal 'OtherApp' $ui.SourceIdBox.Text
    Assert-Equal 'OtherApp-PROD, OtherApp-PrePROD, OtherApp-PROD-MAN, OtherApp-PrePROD-MAN' (Get-ListedIds)

    $ui.ZipPathBox.Text = $zip
    Update-PackageInfo
    Assert-Equal 'SampleUnix' $ui.CustomNameBox.Text
    Assert-Equal 'SampleUnix' $ui.SourceIdBox.Text
}

Test-Case 'naming: typing a custom name renames every platform as you type' {
    $ui.CustomNameBox.Text = 'MyApp'
    Assert-Equal 'MyApp-PROD, MyApp-PrePROD, MyApp-PROD-MAN, MyApp-PrePROD-MAN' (Get-ListedIds)
    Assert-Equal 'MyApp-PROD' ([string]$script:ResultsTable.Rows[0]['PlatformName']) 'the platform name is the same text as the ID'
}

Test-Case 'naming: the Machine switch lists the six machine-vault platforms' {
    $ui.SourceMachineRadio.IsChecked = $true
    Assert-Equal 'Machine' (Get-VariantSource)
    Assert-Equal 'MyApp-PROD-D, MyApp-PrePROD-D, MyApp-PROD-RT-RL, MyApp-PROD-RT-RS, MyApp-PrePROD-RT-RL, MyApp-PrePROD-RT-RS' (Get-ListedIds)
    Assert-Equal '6 platform(s), valid.' $ui.ConfigSummaryText.Text
    Assert-Equal 'Machine' (Get-PlatformImportSettings).VariantSource 'the switch is remembered'
}

Test-Case 'naming: platforms can be added, as a full ID or as a suffix of the custom name' {
    $ui.PlanAddBox.Text = '-DR'
    Invoke-Click $ui.PlanAddButton
    $ui.PlanAddBox.Text = 'Shared-Platform'
    Invoke-Click $ui.PlanAddButton
    Assert-Equal '' $ui.PlanAddBox.Text 'the box is cleared for the next one'
    Assert-True ((Get-ListedIds) -like '*MyApp-PrePROD-RT-RS, MyApp-DR, Shared-Platform') (Get-ListedIds)
    Assert-Equal 8 $script:ResultsTable.Rows.Count
    $ui.PlanAddBox.Text = 'myapp-dr'
    Invoke-Click $ui.PlanAddButton
    Assert-Equal 8 $script:ResultsTable.Rows.Count 'the same ID cannot be added twice'
    Assert-True ($ui.StatusText.Text -like '*already on the list*') $ui.StatusText.Text
    $ui.PlanAddBox.Text = ''
}

Test-Case 'naming: automatically added platforms can be removed, and stay removed when the name changes' {
    Select-ListedPlatform 'MyApp-PrePROD-D', 'MyApp-PROD-RT-RS'
    Invoke-Click $ui.PlanRemoveButton
    Assert-Equal 'MyApp-PROD-D, MyApp-PROD-RT-RL, MyApp-PrePROD-RT-RL, MyApp-PrePROD-RT-RS, MyApp-DR, Shared-Platform' (Get-ListedIds)
    $ui.CustomNameBox.Text = 'App2'
    Assert-Equal 'App2-PROD-D, App2-PROD-RT-RL, App2-PrePROD-RT-RL, App2-PrePROD-RT-RS, App2-DR, Shared-Platform' (Get-ListedIds) 'suffix entries follow the name; a full ID does not'
    $ui.ResultsGrid.SelectedItems.Clear()
    Invoke-Click $ui.PlanRemoveButton
    Assert-Equal 6 $script:ResultsTable.Rows.Count 'nothing selected removes nothing'
}
Save-Screenshot '5-naming-machine'

Test-Case 'naming: Reset list and switching vault type bring back the standard set' {
    Invoke-Click $ui.PlanResetButton
    Assert-Equal 'App2-PROD-D, App2-PrePROD-D, App2-PROD-RT-RL, App2-PROD-RT-RS, App2-PrePROD-RT-RL, App2-PrePROD-RT-RS' (Get-ListedIds)
    $ui.SourceHumanRadio.IsChecked = $true
    Assert-Equal 'App2-PROD, App2-PrePROD, App2-PROD-MAN, App2-PrePROD-MAN' (Get-ListedIds)
}

Test-Case 'naming: a name that cannot be a platform ID is flagged and blocks the run' {
    $ui.PvwaUrlBox.Text = 'https://pvwa.example.test/PasswordVault'
    $ui.UsernameBox.Text = 'svc_platforms'
    $ui.PasswordBox.Password = 'not-a-real-password'
    $ui.ReportFolderBox.Text = $guiReports
    Reset-Vault
    $ui.CustomNameBox.Text = 'My App'
    Assert-True ($ui.ConfigSummaryText.Text -like '4 platform(s), 4 error(s)*must not contain spaces*') $ui.ConfigSummaryText.Text
    $script:Messages.Clear()
    Invoke-Click $ui.RunButton
    Assert-True ($null -eq $script:Job)
    Assert-True ($script:Messages[-1] -like '*4 error(s)*correct the custom name*') ($script:Messages -join ' | ')

    $ui.CustomNameBox.Text = ''
    Assert-True ($ui.ConfigSummaryText.Text -like 'Enter the custom name*')
    Invoke-Click $ui.RunButton
    Assert-True ($null -eq $script:Job)
    Assert-True ($script:Messages[-1] -like 'Enter the custom name first*') $script:Messages[-1]
    Assert-Equal 0 (Get-Vault).Sessions
}

Test-Case 'naming: a run creates exactly the listed platforms, with no file involved' {
    Reset-Vault
    $ui.CustomNameBox.Text = 'MyApp'
    Select-ListedPlatform 'MyApp-PrePROD-MAN'
    Invoke-Click $ui.PlanRemoveButton
    $ui.PlanAddBox.Text = '-DR'
    Invoke-Click $ui.PlanAddButton
    Assert-Equal 'MyApp-PROD, MyApp-PrePROD, MyApp-PROD-MAN, MyApp-DR' (Get-ListedIds)

    $script:DialogAnswer = 'Yes'
    $script:Messages.Clear()
    Invoke-Click $ui.RunButton
    Assert-True ($script:Messages[-1] -like "*4 platform(s) from 'SampleUnix'*MyApp-PROD*MyApp-PrePROD*MyApp-PROD-MAN*MyApp-DR*") $script:Messages[-1]
    Assert-True ($script:Messages[-1] -notlike '*MyApp-PrePROD-MAN*') 'a removed platform must not be in the confirmation'
    Assert-True (-not $ui.PlanToolbar.IsEnabled) 'the list is locked while running'
    Wait-EngineJob
    Assert-Equal 'Completed,Completed,Completed,Completed' ((Get-ResultStatuses) -join ',')
    $created = @((Get-Vault).Platforms | Where-Object { $_.PlatformID -ne 'SampleUnix' } | ForEach-Object { $_.PlatformID })
    Assert-Equal 'MyApp-PROD, MyApp-PrePROD, MyApp-PROD-MAN, MyApp-DR' ($created -join ', ')
    Assert-True ($null -eq (Get-VaultPlatform 'MyApp-PrePROD-MAN')) 'the removed platform must not be created'
    Assert-True $ui.PlanToolbar.IsEnabled

    Show-Plan       # what a field losing focus does: the results must stay on screen
    Assert-Equal 'Completed,Completed,Completed,Completed' ((Get-ResultStatuses) -join ',')
}
Save-Screenshot '6-naming-done'

Test-Case 'naming: the generated list can be taken to the editor to add settings' {
    Assert-Equal 'Customise in editor' ([string]$ui.EditConfigButton.Content)
    Invoke-Click $ui.EditConfigButton
    Assert-Equal $ui.EditorTab $ui.MainTabs.SelectedItem
    Assert-Equal 4 $script:Editor.Platforms.Count
    Assert-Equal 'MyApp-DR' $script:Editor.Platforms[3].PlatformId
    Assert-Equal '' $script:Editor.Path 'it is a new, unsaved document'
    Assert-True $script:Editor.Dirty
    Assert-True (Open-EditorFile -Path $guiConfig)
    $ui.PasswordBox.Password = ''
    Reset-Vault
}

Test-Case 'import: choosing a JSON file lists the platforms in that file instead' {
    $ui.MainTabs.SelectedItem = $ui.ImportTab
    $ui.SourceFileRadio.IsChecked = $true
    Assert-Equal 'File' (Get-VariantSource)
    Assert-Equal 'Visible' ([string]$ui.FilePanel.Visibility)
    Assert-Equal 'Collapsed' ([string]$ui.SchemePanel.Visibility)
    Assert-Equal 'Collapsed' ([string]$ui.PlanToolbar.Visibility) 'a file is edited in the editor, not in the list'
    Assert-Equal 'Open in editor' ([string]$ui.EditConfigButton.Content)
    Assert-Equal 'SampleUnix-PROD, SampleUnix-DEV, SampleUnix-TEST' (Get-ListedIds)
    Assert-Equal 'Planned,Planned,Planned' ((Get-ResultStatuses) -join ',')
    Assert-True ($ui.ConfigSummaryText.Text -like '3 platform(s), valid*') $ui.ConfigSummaryText.Text
}

Test-Case 'import: running without a password asks for it and starts nothing' {
    $ui.PvwaUrlBox.Text = 'https://pvwa.example.test/PasswordVault'
    $ui.UsernameBox.Text = 'svc_platforms'
    $ui.ReportFolderBox.Text = $guiReports
    $script:Messages.Clear()
    Invoke-Click $ui.RunButton
    Assert-True ($null -eq $script:Job)
    Assert-True ($script:Messages[-1] -like '*password*') ($script:Messages -join ' | ')
}

Test-Case 'import: connection test reports the PVWA version' {
    $ui.PasswordBox.Password = 'not-a-real-password'
    Invoke-Click $ui.TestConnectionButton
    Assert-True ($null -ne $script:Job) 'the test should run in the background'
    Wait-EngineJob
    Assert-True ($ui.ProgressText.Text -like 'Connection OK - PVWA 15.2*') $ui.ProgressText.Text
    Assert-Equal $false (Get-Vault).Connected
    Assert-True $ui.RunButton.IsEnabled 'controls must be enabled again'
}

Test-Case 'import: a password with / and other special characters logs on, typed into the password box' {
    $typed = 'Sl/ash\back "quote'' <&> %2F ' + [char]0x20AC + ' /end'
    try {
        (Get-Vault).ExpectedPassword = $typed       # the fake PVWA refuses anything else
        $ui.PasswordBox.Password = $typed
        Invoke-Click $ui.TestConnectionButton
        Wait-EngineJob
        Assert-True ($ui.ProgressText.Text -like 'Connection OK*') $ui.ProgressText.Text
        Assert-True ((Get-Vault).LastPasswordReceived -ceq $typed) "The logon received '$((Get-Vault).LastPasswordReceived)'."
        Assert-True ((Get-LogText) -notlike '*Sl/ash*') 'the password must not appear in the log'
    }
    finally {
        (Get-Vault).ExpectedPassword = ''
        $ui.PasswordBox.Password = 'not-a-real-password'
    }
}

Test-Case 'import: a refused logon explains what was tried and where to look' {
    $ui.PasswordBox.Password = 'wrong'
    Invoke-Click $ui.TestConnectionButton
    Wait-EngineJob
    $log = Get-LogText
    Assert-True ($log -like "*Logon to https://pvwa.example.test as 'svc_platforms' with CyberArk authentication failed*") 'the log should say what was attempted'
    Assert-True ($log -like '*(ITATS004E)*') 'the log should carry PVWA''s error code'
    Assert-True ($log -like '*method you choose there is the one selected here (CyberArk)*') 'the log should point at the authentication method'
    Assert-True ($ui.StatusText.Text -like 'Connection test failed: Logon to*') $ui.StatusText.Text
    Assert-True $ui.RunButton.IsEnabled 'controls must be enabled again after a failed logon'
    $ui.PasswordBox.Password = 'not-a-real-password'
}

Test-Case 'import: a wrong password is shown as a failed connection test' {
    $ui.PasswordBox.Password = 'wrong'
    Invoke-Click $ui.TestConnectionButton
    Wait-EngineJob
    Assert-Equal 'Connection test failed.' $ui.ProgressText.Text
    Assert-True ((Get-LogText) -like '*Authentication failure*')
    $ui.PasswordBox.Password = 'not-a-real-password'
}

Test-Case 'import: dry run lists what would happen and changes nothing' {
    $ui.DryRunBox.IsChecked = $true
    $script:Messages.Clear()
    Invoke-Click $ui.RunButton
    Wait-EngineJob
    Assert-Equal 0 $script:Messages.Count 'a dry run needs no confirmation'
    Assert-Equal 'Would run,Would run,Would run' ((Get-ResultStatuses) -join ',')
    Assert-Equal 0 (Get-Vault).Platforms.Count
    Assert-True (@(Get-ChildItem -LiteralPath $guiReports -Filter '*-dryrun.csv').Count -eq 1)
    $ui.DryRunBox.IsChecked = $false
}

Test-Case 'import: declining the confirmation starts nothing' {
    Reset-Vault
    $script:DialogAnswer = 'No'
    try {
        Invoke-Click $ui.RunButton
        Assert-True ($null -eq $script:Job)
        Assert-Equal 0 (Get-Vault).Sessions
    }
    finally { $script:DialogAnswer = 'Yes' }
}

Test-Case 'import: a real run creates the variants and shows each result' {
    Reset-Vault
    $script:Messages.Clear()
    Invoke-Click $ui.RunButton
    Assert-True ($script:Messages[-1] -like "*3 platform(s) from 'SampleUnix'*https://pvwa.example.test*svc_platforms*SampleUnix-PROD*SampleUnix-TEST*") $script:Messages[-1]
    Assert-True (-not $ui.ImportInputs.IsEnabled) 'inputs are locked while running'
    Wait-EngineJob
    Assert-Equal 'Completed,Completed,Completed' ((Get-ResultStatuses) -join ',')
    Assert-Equal 4 (Get-Vault).Platforms.Count
    Assert-Equal 2 (Get-VaultPlatform 'SampleUnix-PROD').Operations.Count
    Assert-Equal 'PSMServer_PROD' (Get-VaultPlatform 'SampleUnix-PROD').PSM.PSMServerID
    Assert-True ($ui.ProgressText.Text -like 'Finished in*3 completed, 0 skipped, 0 failed*') $ui.ProgressText.Text
    Assert-True ($ui.ProgressText.Text -like "*Source platform 'SampleUnix' was added to the Vault.") 'the summary line must say the source platform was added'
    Assert-Equal 3 $ui.RunProgress.Value
    Assert-True ((Get-LogText) -like "*Platform 'SampleUnix-TEST' created.*")
    Assert-True ((Get-LogText) -notlike '*not-a-real-password*') 'password leaked into the log'
    Assert-True $ui.ImportInputs.IsEnabled
    Assert-Equal $false (Get-Vault).Connected
}
Save-Screenshot '3-import-done'

Test-Case 'import: a failure is shown per platform and the rest is marked not run' {
    Reset-Vault
    (Get-Vault).FailSettingsFor = @('SampleUnix-PROD')
    Invoke-Click $ui.RunButton
    Wait-EngineJob
    Assert-Equal 'Failed,Not run,Not run' ((Get-ResultStatuses) -join ',')
    Assert-True ([string]$script:ResultsTable.Rows[0]['Message'] -like '*not valid*')
}
Save-Screenshot '4-import-failed'

Test-Case 'import: cancel stops before the next platform' {
    Reset-Vault
    (Get-Vault).DelayMilliseconds = 400
    Invoke-Click $ui.RunButton
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Get-ResultStatuses) -notcontains 'Running' -and $stopwatch.Elapsed.TotalSeconds -lt 30) { Invoke-UiPump 50 }
    Assert-True $ui.CancelButton.IsEnabled 'Cancel is available while an import runs'
    Invoke-Click $ui.CancelButton
    Wait-EngineJob
    $statuses = Get-ResultStatuses
    Assert-Equal 'Completed' $statuses[0] 'the platform in progress is finished'
    Assert-True ($statuses -contains 'Cancelled') ($statuses -join ',')
    Assert-Equal 'Cancel' ([string]$ui.CancelButton.Content)
    Assert-Equal $false (Get-Vault).Connected
    (Get-Vault).DelayMilliseconds = 0
}

Test-Case 'import: unsaved editor changes are offered for saving before a run' {
    Reset-Vault
    $script:Editor.Platforms[2].PlatformName = 'Renamed in editor'
    $script:Editor.Dirty = $true
    $script:Messages.Clear()
    Invoke-Click $ui.RunButton
    Wait-EngineJob
    Assert-True ($script:Messages[0] -like '*unsaved changes*') ($script:Messages -join ' | ')
    Assert-Equal $false $script:Editor.Dirty
    Assert-Equal 'Renamed in editor' (Get-VaultPlatform 'SampleUnix-TEST').Name
}

Test-Case 'settings: what was entered is saved, the password is not' {
    Save-UiSettings
    $saved = Get-PlatformImportSettings
    Assert-Equal 'https://pvwa.example.test/PasswordVault' $saved.PVWAURL
    Assert-Equal 'svc_platforms' $saved.Username
    Assert-Equal $zip $saved.SourcePlatformZip
    Assert-Equal $guiConfig $saved.ConfigurationFile
    Assert-Equal 'File' $saved.VariantSource
    Assert-Equal 'MyApp' $saved.CustomName
    Assert-Equal $guiReports $saved.ReportFolder
    Assert-Equal $guiConfig $saved.EditorFile
    Assert-True ((Get-Content -LiteralPath $env:IMPORTPLATFORMS_SETTINGS -Raw) -notlike '*not-a-real-password*')
}

Test-Case 'settings: RADIUS shows the one-time code field and remembers the mode' {
    $ui.AuthTypeBox.SelectedItem = 'RADIUS'
    Assert-Equal 'Visible' ([string]$ui.OtpRow.Visibility)
    $ui.OtpModeBox.SelectedItem = 'Append'
    $ui.OtpBox.Text = '123456'
    $parameters = Get-ConnectionParameters
    Assert-Equal '123456' $parameters.OTP
    Assert-Equal 'Append' $parameters.OTPMode
    Assert-Equal 'Append' (Get-PlatformImportSettings).OTPMode
    Assert-True ((Get-Content -LiteralPath $env:IMPORTPLATFORMS_SETTINGS -Raw) -notlike '*123456*') 'the one-time code must not be saved'
    $ui.AuthTypeBox.SelectedItem = 'LDAP'
    Assert-Equal 'Collapsed' ([string]$ui.OtpRow.Visibility)
    Assert-Equal '' $ui.OtpBox.Text
}

$script:DialogAnswer = 'No'
$window.Close()

Test-Case 'settings: a new window starts with the saved values' {
    . (Join-Path $repoRoot 'Start-PlatformImportGui.ps1') -NoShow
    Assert-Equal 'https://pvwa.example.test/PasswordVault' $ui.PvwaUrlBox.Text
    Assert-Equal 'svc_platforms' $ui.UsernameBox.Text
    Assert-Equal 'LDAP' ([string]$ui.AuthTypeBox.SelectedItem)
    Assert-Equal $zip $ui.ZipPathBox.Text
    Assert-Equal 'SampleUnix' $ui.SourceIdBox.Text
    Assert-Equal $guiConfig $ui.ConfigPathBox.Text
    Assert-Equal $guiReports $ui.ReportFolderBox.Text
    Assert-Equal '' $ui.PasswordBox.Password
    Assert-Equal 3 $script:Editor.Platforms.Count 'the last edited file is reopened'
    Assert-Equal 'File' (Get-VariantSource) 'the JSON file choice is restored'
    Assert-Equal 'MyApp' $ui.CustomNameBox.Text
    Assert-True ($ui.ConfigSummaryText.Text -like '3 platform(s), valid*')
    Assert-Equal 3 $script:ResultsTable.Rows.Count

    # Back to a vault type: the standard platforms come straight back, named as before.
    $ui.SourceMachineRadio.IsChecked = $true
    Assert-Equal 6 $script:ResultsTable.Rows.Count
    Assert-Equal 'MyApp-PROD-D' ([string]$script:ResultsTable.Rows[0]['PlatformId'])
    $window.Close()
}

Test-Case 'settings: the vault type is restored and its platforms are ready without any action' {
    . (Join-Path $repoRoot 'Start-PlatformImportGui.ps1') -NoShow
    Assert-Equal 'Machine' (Get-VariantSource)
    Assert-Equal 'Visible' ([string]$ui.PlanToolbar.Visibility)
    Assert-Equal 'MyApp-PROD-D, MyApp-PrePROD-D, MyApp-PROD-RT-RL, MyApp-PROD-RT-RS, MyApp-PrePROD-RT-RL, MyApp-PrePROD-RT-RS' (Get-ListedIds)
    Assert-Equal '6 platform(s), valid.' $ui.ConfigSummaryText.Text
    $window.Close()
}
