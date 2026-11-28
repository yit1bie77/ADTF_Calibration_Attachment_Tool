param([switch]$Repair, [switch]$CheckReadability)

$ErrorActionPreference = 'Stop'

function Test-StopRequested {
    $env:ADTF_STOP_FILE -and [IO.File]::Exists($env:ADTF_STOP_FILE)
}

function Invoke-AdtfTool([string[]]$arguments, [string]$Executable = $env:DATTOOL, [switch]$AllowRepairLog, [switch]$AllowNoSamples) {
    if (Test-StopRequested) { throw [OperationCanceledException]::new() }
    $quoted = @($arguments | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' })
    $info = New-Object Diagnostics.ProcessStartInfo -Property @{
        FileName = $Executable; Arguments = ($quoted -join ' ')
        UseShellExecute = $false; CreateNoWindow = $true
        RedirectStandardOutput = $true; RedirectStandardError = $true
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(200)) {
            if (Test-StopRequested) {
                if (-not $process.HasExited) { $process.Kill() }
                $process.WaitForExit()
                throw [OperationCanceledException]::new()
            }
        }
        $details = ($stderr.Result + "`n" + $stdout.Result).Trim()
        $unexpectedStderr = $stderr.Result.Trim()
        if ($AllowRepairLog) {
            $unexpectedStderr = ($unexpectedStderr -replace '(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[(?:INFO|WARNING)\]:[^\r\n]*', '').Trim()
        }
        $unexpectedExit = $process.ExitCode -ne 0 -and -not ($AllowNoSamples -and $process.ExitCode -eq 3)
        if ($unexpectedExit -or $unexpectedStderr -or $stdout.Result -match '(?im)^\s*(?:(?:exception|error):|\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[(?:ERROR|FATAL)\]:)') {
            throw "ADTF returned exit code $($process.ExitCode). $details"
        }
        if ($AllowRepairLog) { $details } else { $stdout.Result }
    } finally { $process.Dispose() }
}

function Get-RecordingExtensions($path, $header) {
    $count = [uint32]$header.extension_count
    $offset = [uint64]$header.extension_offset
    $byteOrder = $header.header_byte_order
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($path))
    try {
        $length = [uint64]$reader.BaseStream.Length
        if ($count -eq 0) { return }
        if ($byteOrder -notin @('1', '2')) { throw "Unsupported ADTF byte order: $byteOrder" }
        if ($offset -gt $length -or (512L * $count) -gt ($length - $offset)) {
            throw 'The extension directory lies outside the recording.'
        }
        $reader.BaseStream.Position = [long]$offset
        for ($entryNumber = 0; $entryNumber -lt $count; $entryNumber++) {
            if (Test-StopRequested) { throw [OperationCanceledException]::new() }
            $entry = $reader.ReadBytes(512)
            if ($entry.Length -ne 512) { throw 'The extension directory is truncated.' }
            $name = ([Text.Encoding]::UTF8.GetString($entry, 0, 384) -split "`0", 2)[0]
            if ($byteOrder -eq '2') {
                [Array]::Reverse($entry, 384, 2)
                [Array]::Reverse($entry, 400, 8)
                [Array]::Reverse($entry, 408, 8)
            }
            $position = [BitConverter]::ToUInt64($entry, 400)
            $size = [BitConverter]::ToUInt64($entry, 408)
            [pscustomobject]@{
                Name = $name; StreamId = [BitConverter]::ToUInt16($entry, 384)
                Offset = $position; Size = $size
                InBounds = $position -le $length -and $size -le ($length - $position)
            }
        }
    } finally { $reader.Dispose() }
}

function Get-RecordingStreams([string]$path) {
    $inventory = (Invoke-AdtfTool @('--liststreams', $path, '--json')) | ConvertFrom-Json
    $inventory | ForEach-Object { $_.streams } | Where-Object { $null -ne $_ }
}

try {
    if ($Repair) {
        $inputFile = Get-Item -LiteralPath $env:CHECK_RECORDING
        $reference = Get-Item -LiteralPath $env:ADTF_REPAIR_REFERENCE
        if ($reference.PSIsContainer -or $reference.Extension -ne '.adtfdat') { throw 'Select an ADTFDAT reference recording.' }
        if ($inputFile.FullName -eq $reference.FullName) { throw 'The reference must be different from the recording being repaired.' }
        $outputFolder = $inputFile.DirectoryName
        if ($env:ADTF_REPAIR_OUTPUT_FOLDER) {
            $folder = Get-Item -LiteralPath $env:ADTF_REPAIR_OUTPUT_FOLDER
            if (-not $folder.PSIsContainer -or $folder.PSProvider.Name -ne 'FileSystem') { throw 'Choose a repair output folder.' }
            $outputFolder = $folder.FullName
        }
        $outputName = $inputFile.BaseName + '_rep.adtfdat'
        $destination = Join-Path $outputFolder $outputName
        if (Test-Path -LiteralPath $destination) { throw "Repair output already exists: $destination" }
        Write-Output "Reference: $($reference.FullName)"
        Write-Output "Repair output: $destination"
        try {
            $details = Invoke-AdtfTool @('--repair', $inputFile.FullName, '--output', $destination, '--reference', $reference.FullName) -AllowRepairLog
        } catch {
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                Write-Output "WARNING: Repair left output that may be incomplete: $destination"
            }
            throw
        }
        if ($details.Trim()) { Write-Output $details.Trim() }
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw "ADTF did not create repair output: $destination" }
        if ($details -match 'Stopped processing at file offset') {
            Write-Output "WARNING: Recovery may be incomplete: $destination"
            exit 0
        }
        Write-Output "OK: Repaired recording: $destination"
        exit 0
    }
    $path = $env:CHECK_RECORDING
    if ($CheckReadability) {
        $scanner = Join-Path $PSScriptRoot 'runtime\adtf_sample_scan.exe'
        if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
            $scanner = Join-Path $PSScriptRoot 'dist\adtf_dattool_gui_iss\runtime\adtf_sample_scan.exe'
        }
        if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) { throw 'Sample scanner not found. Rebuild the GUI package.' }
        $result = (Invoke-AdtfTool @($path) -Executable $scanner -AllowNoSamples).Trim()
        Write-Output $result
        if ($result -like 'WARNING:*') { exit 1 }
        exit 0
    }
    $dump = Invoke-AdtfTool @('--dump', $path, '--header')
    $header = @{}
    foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match '^(extension_count|extension_offset|header_byte_order|chunk_count|data_size|file_duration|file_time|version_id):\s*(\S+)$') {
            $header[$Matches[1]] = $Matches[2]
        }
    }
    if ($header.Count -ne 8) { throw 'ADTF did not report the expected header metadata.' }
    Write-Output ('Header: {0} duration | {1:N0} chunks | {2:N2} GiB of data' -f $header.file_duration, [uint64]$header.chunk_count, ([uint64]$header.data_size / 1GB))
    Write-Output "  Created: $($header.file_time) | Format version: $($header.version_id)"
    $extensions = @(Get-RecordingExtensions $path $header)
    $indexes = @($extensions | Where-Object Name -Match '^index(?:_add)?\d+$')
    $masterIndex = $indexes | Where-Object Name -EQ 'index0' | Select-Object -First 1
    $indexDetail = if ($masterIndex) { ' | index0: {0:N0} bytes' -f $masterIndex.Size } else { '' }
    Write-Output "Index: $($indexes.Count) entries$indexDetail"
    $otherExtensions = @($extensions | Where-Object Name -NotMatch '^index(?:_add)?\d+$')
    Write-Output "Extensions: $($otherExtensions.Count) non-index entries"
    foreach ($entry in $otherExtensions) {
        Write-Output ('  {0}: {1:N0} bytes' -f $entry.Name, $entry.Size)
    }
    $invalid = @($extensions | Where-Object { -not $_.InBounds })
    foreach ($entry in $invalid) { Write-Output "FAILED: $($entry.Name) points outside the recording." }

    $streams = @(Get-RecordingStreams $path)
    $emptyStreams = @($streams | Where-Object item_count -EQ 0)
    Write-Output "Streams: $($streams.Count) ($($emptyStreams.Count) empty)"
    foreach ($stream in $streams) {
        Write-Output ('  {0}: {1:N0} items' -f $stream.stream, [uint64]$stream.item_count)
    }
    if ($invalid.Count) { exit 1 }
    if (-not $masterIndex -or -not $streams.Count -or $emptyStreams.Count -eq $streams.Count) {
        if (-not $masterIndex) { Write-Output 'WARNING: Master index (index0) not found.' }
        if (-not $streams.Count) { Write-Output 'WARNING: No streams were listed.' }
        elseif ($emptyStreams.Count -eq $streams.Count) { Write-Output 'WARNING: All listed streams are empty.' }
        exit 1
    }
    Write-Output 'OK: Metadata checks passed.'
} catch [OperationCanceledException] {
    if ($Repair) { Write-Output 'Repair stopped.' }
    elseif ($CheckReadability) { Write-Output 'Sample readability check stopped.' }
    else { Write-Output 'Recording analysis stopped.' }
    exit 2
} catch {
    Write-Output "FAILED: $($_.Exception.Message)"
    exit 1
}