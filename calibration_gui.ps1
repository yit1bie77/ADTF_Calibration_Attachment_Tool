param([switch]$BuildOnly)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form -Property @{
    Text = 'ADTF Calibration Attachment Tool'; StartPosition = 'CenterScreen'
    Size = [Drawing.Size]::new(960, 680); MinimumSize = [Drawing.Size]::new(740, 500)
    Font = [Drawing.Font]::new('Segoe UI', 10)
}
$layout = New-Object Windows.Forms.TableLayoutPanel -Property @{
    Dock = 'Fill'; Padding = [Windows.Forms.Padding]::new(12); ColumnCount = 3; RowCount = 5
}
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 148))
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute', 100))
foreach ($height in @(36, 36, 42)) {
    [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', $height))
}
[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100))
[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 30))
$form.Controls.Add($layout)

function Add-FolderRow($caption, $initialPath, $row) {
    $label = New-Object Windows.Forms.Label -Property @{ Text = $caption; Dock = 'Fill'; TextAlign = 'MiddleLeft' }
    $inputBox = New-Object Windows.Forms.TextBox -Property @{ Text = $initialPath; Dock = 'Fill'; AccessibleName = $caption }
    $browse = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...'; Dock = 'Fill'; Tag = $inputBox; AccessibleName = "Browse $caption" }
    $browse.Add_Click({
        param($sender, $eventArgs)
        $dialog = New-Object Windows.Forms.FolderBrowserDialog -Property @{ ShowNewFolderButton = $false }
        try {
            $dialog.SelectedPath = $sender.Tag.Text
            if ($dialog.ShowDialog($form) -eq 'OK') { $sender.Tag.Text = $dialog.SelectedPath }
        } finally { $dialog.Dispose() }
    })
    $layout.Controls.Add($label, 0, $row)
    $layout.Controls.Add($inputBox, 1, $row)
    $layout.Controls.Add($browse, 2, $row)
    $inputBox
}

$defaultRecordings = Join-Path $PSScriptRoot '20261029\Data'
if (-not (Test-Path -LiteralPath $defaultRecordings -PathType Container)) { $defaultRecordings = '' }
$recordingsFolder = Add-FolderRow 'Recordings folder' $defaultRecordings 0
$xmlFolder = Add-FolderRow 'Calibration XML folder' 'E:\temp' 1
$toolbar = New-Object Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Fill'; WrapContents = $false }
$layout.Controls.Add($toolbar, 0, 2)
$layout.SetColumnSpan($toolbar, 3)
$buttons = @{}
foreach ($caption in @('Load folder', 'Select all', 'Clear selection', 'Check attachment', 'Attach to selected', 'Replace to selected')) {
    $button = New-Object Windows.Forms.Button -Property @{ Text = $caption; AutoSize = $true; Height = 30 }
    $toolbar.Controls.Add($button)
    $buttons[$caption] = $button
}

$split = New-Object Windows.Forms.SplitContainer -Property @{ Dock = 'Fill'; SplitterWidth = 8 }
$layout.Controls.Add($split, 0, 3)
$layout.SetColumnSpan($split, 3)
$recordings = New-Object Windows.Forms.CheckedListBox -Property @{
    Dock = 'Fill'; CheckOnClick = $true; DisplayMember = 'Name'; IntegralHeight = $false; HorizontalScrollbar = $true
}
$split.Panel1.Controls.Add($recordings)
$output = New-Object Windows.Forms.RichTextBox -Property @{
    Dock = 'Fill'; ReadOnly = $true; BackColor = [Drawing.Color]::White; DetectUrls = $false
    Font = [Drawing.Font]::new('Consolas', 10); AccessibleName = 'Operation results'
}
$split.Panel2.Controls.Add($output)
$status = New-Object Windows.Forms.Label -Property @{ Dock = 'Fill'; TextAlign = 'MiddleLeft'; AutoEllipsis = $true }
$layout.Controls.Add($status, 0, 4)
$layout.SetColumnSpan($status, 2)
$stopButton = New-Object Windows.Forms.Button -Property @{ Text = 'Stop'; Dock = 'Fill'; Enabled = $false }
$layout.Controls.Add($stopButton, 2, 4)

$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 100 }
$state = @{ Process = $null; Tasks = $null; Queue = $null; Current = $null; Mode = ''; Total = 0; Finished = 0; Issues = 0; StopFile = $null; StopRequested = $false }
$engine = Join-Path $PSHOME 'powershell.exe'
$dattool = Join-Path $PSScriptRoot 'runtime\adtf_dattool.exe'
if (-not (Test-Path -LiteralPath $dattool -PathType Leaf)) {
    $dattool = 'C:\Tools\ADTF\Releases\3.19.0\bin\adtf_dattool.exe'
}

function Write-Result($line) {
    $output.SelectionStart = $output.TextLength
    $output.SelectionColor = switch -Regex ($line) {
        '^OK$|^Verified recording:' { [Drawing.Color]::DarkGreen; break }
        '^WARNING:' { [Drawing.Color]::DarkGoldenrod; break }
        '^FAILED:|^Error:' { [Drawing.Color]::Firebrick; break }
        default { [Drawing.Color]::FromArgb(35, 42, 49) }
    }
    $output.AppendText($line + [Environment]::NewLine)
    $output.ScrollToCaret()
}

function Load-Recordings {
    $recordings.Items.Clear()
    if (-not $recordingsFolder.Text.Trim()) { $status.Text = 'Select a recordings folder.'; return }
    try {
        $folder = Get-Item -LiteralPath $recordingsFolder.Text.Trim()
        if (-not $folder.PSIsContainer) { throw 'Select a recordings folder.' }
        foreach ($file in (Get-ChildItem -LiteralPath $folder.FullName -Filter '*.adtfdat' -File | Where-Object Extension -eq '.adtfdat' | Sort-Object Name)) {
            [void]$recordings.Items.Add($file)
        }
        $status.Text = "$($recordings.Items.Count) recordings"
    } catch { $status.Text = $_.Exception.Message }
}

function Set-OperationRunning([bool]$running) {
    foreach ($control in $layout.Controls) {
        if ($control -ne $stopButton -and $control -ne $status) { $control.Enabled = -not $running }
    }
    $stopButton.Enabled = $running
}

function Start-NextRecording {
    while (-not $state.StopRequested -and $state.Queue.Count) {
        $item = $state.Queue.Dequeue()
        $state.Current = $item
        $archive = $null
        Write-Result "[$($state.Mode)] $($item.Name)"
        $status.Text = "$($state.Mode): $($item.Name) ($($state.Total - $state.Queue.Count) of $($state.Total))"
        try {
            $info = New-Object Diagnostics.ProcessStartInfo -Property @{
                FileName = $engine; UseShellExecute = $false; CreateNoWindow = $true
                RedirectStandardOutput = $true; RedirectStandardError = $true
            }
            $info.EnvironmentVariables['DATTOOL'] = $dattool
            $info.EnvironmentVariables['ADTF_STOP_FILE'] = $state.StopFile
            if ($state.Mode -eq 'Check') {
                $scriptFile = Join-Path $PSScriptRoot 'check_attachment_archive.ps1'
                $archive = Join-Path ([IO.Path]::GetTempPath()) ('adtf-gui-' + [guid]::NewGuid() + '.tar.gz')
                $info.EnvironmentVariables['CHECK_RECORDING'] = $item.FullName
                $info.EnvironmentVariables['CHECK_ARCHIVE'] = $archive
                $info.EnvironmentVariables['TARTOOL'] = Join-Path $env:SystemRoot 'System32\tar.exe'
            } else {
                $scriptFile = Join-Path $PSScriptRoot 'attach_calibration.ps1'
                $info.EnvironmentVariables['ADTF_FILE'] = $item.FullName
                $info.EnvironmentVariables['XML_FOLDER'] = $state.XmlPath
                foreach ($key in @($info.EnvironmentVariables.Keys)) {
                    if ($key -match '^XML_FILE(?:_[1-9]\d*)?$') { $info.EnvironmentVariables.Remove($key) }
                }
            }
            $info.Arguments = '-NoProfile -NonInteractive -File "{0}"' -f $scriptFile
            if ($state.Mode -eq 'Replace') { $info.Arguments += ' -Replace' }
            $state.Process = [Diagnostics.Process]::Start($info)
            $state.Tasks = @($state.Process.StandardOutput.ReadToEndAsync(), $state.Process.StandardError.ReadToEndAsync())
            $state.Archive = $archive
            return
        } catch {
            $state.Finished++
            $state.Issues++
            Write-Result ('Error: ' + $_.Exception.Message)
        }
    }
    $timer.Stop()
    Set-OperationRunning $false
    if ($state.Mode -ne 'Check') { Load-Recordings }
    if ($state.StopRequested) {
        Remove-Item -LiteralPath $state.StopFile -Force -ErrorAction SilentlyContinue
        $message = if ($state.Finished -lt $state.Total) {
            "$($state.Mode) stopped: $($state.Finished) of $($state.Total) recordings processed."
        } else {
            "Stop requested, but $($state.Mode) had already finished."
        }
        $status.Text = $message
        Write-Result $message
    } else {
        $status.Text = "$($state.Mode) complete: $($state.Total) processed, $($state.Issues) with issues."
    }
}

function Start-Operation($mode) {
    $items = @($recordings.CheckedItems)
    if (-not $items.Count) { $status.Text = 'No ADTFDAT file is selected.'; return }
    if ($mode -ne 'Check') {
        try {
            $folder = Get-Item -LiteralPath $xmlFolder.Text.Trim()
            if (-not $folder.PSIsContainer) { throw 'Select a calibration XML folder.' }
            if (-not (Get-ChildItem -LiteralPath $folder.FullName -Filter '*.xml' -File | Where-Object Extension -eq '.xml' | Select-Object -First 1)) {
                throw 'No XML files were found in the calibration folder.'
            }
            $state.XmlPath = $folder.FullName
        } catch { $status.Text = $_.Exception.Message; return }
    }
    $output.Clear()
    $state.Queue = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($item in $items) { $state.Queue.Enqueue($item) }
    $state.Mode = $mode
    $state.Total = $items.Count
    $state.Finished = 0
    $state.Issues = 0
    $state.StopRequested = $false
    $state.StopFile = Join-Path ([IO.Path]::GetTempPath()) ('adtf-stop-' + [guid]::NewGuid())
    Set-OperationRunning $true
    $timer.Start()
    Start-NextRecording
}

$timer.Add_Tick({
    if (-not $state.Process.HasExited -or @($state.Tasks | Where-Object { -not $_.IsCompleted }).Count) { return }
    foreach ($task in $state.Tasks) {
        if ($task.IsFaulted) { Write-Result ('Error: ' + $task.Exception.GetBaseException().Message); continue }
        foreach ($line in ($task.Result -split '\r?\n')) {
            if ($line -and (-not $state.Archive -or $line -notmatch '^Archive: ')) { Write-Result $line }
        }
    }
    $cancelled = $state.StopRequested -and $state.Process.ExitCode -eq 2
    if (-not $cancelled) { $state.Finished++ }
    if (-not $cancelled -and $state.Process.ExitCode -ne 0) {
        $state.Issues++
        if ($state.Mode -ne 'Check') { Write-Result 'FAILED: Attachment was not completed.' }
    }
    $state.Process.Dispose()
    $state.Process = $null
    if ($state.Archive) { Remove-Item -LiteralPath $state.Archive -ErrorAction SilentlyContinue }
    Write-Result ''
    Start-NextRecording
})

$buttons['Load folder'].Add_Click({ Load-Recordings })
$buttons['Select all'].Add_Click({ for ($index = 0; $index -lt $recordings.Items.Count; $index++) { $recordings.SetItemChecked($index, $true) } })
$buttons['Clear selection'].Add_Click({ for ($index = 0; $index -lt $recordings.Items.Count; $index++) { $recordings.SetItemChecked($index, $false) } })
$buttons['Check attachment'].Add_Click({ Start-Operation 'Check' })
$buttons['Attach to selected'].Add_Click({ Start-Operation 'Attach' })
$buttons['Replace to selected'].Add_Click({ Start-Operation 'Replace' })
$stopButton.Add_Click({
    try {
        [IO.File]::WriteAllText($state.StopFile, '')
        $state.StopRequested = $true
        $stopButton.Enabled = $false
        $status.Text = "Stopping $($state.Mode) after the current step..."
    } catch { Write-Result ('Error: Could not request stop. ' + $_.Exception.Message) }
})
$recordingsFolder.Add_TextChanged({ $recordings.Items.Clear(); $status.Text = 'Load the selected recordings folder.' })
$form.Add_Shown({ $split.SplitterDistance = [int]($split.Width * 0.36) })
$form.Add_FormClosing({ param($sender, $eventArgs) if ($timer.Enabled) { $eventArgs.Cancel = $true } })
Load-Recordings

if (-not $BuildOnly) {
    try { [Windows.Forms.Application]::Run($form) } finally { $timer.Dispose(); $form.Dispose() }
}