param([switch]$Repair)

$ErrorActionPreference = 'Stop'

function Test-StopRequested {
    $env:ADTF_STOP_FILE -and [IO.File]::Exists($env:ADTF_STOP_FILE)
}

function Invoke-Dattool([string[]]$arguments, [switch]$AllowRepairLog) {
    if (Test-StopRequested) { throw [OperationCanceledException]::new() }
    $quoted = @($arguments | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' })
    $info = New-Object Diagnostics.ProcessStartInfo -Property @{
        FileName = $env:DATTOOL; Arguments = ($quoted -join ' ')
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
        if ($process.ExitCode -ne 0 -or $unexpectedStderr -or $stdout.Result -match '(?im)^\s*(?:(?:exception|error):|\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[(?:ERROR|FATAL)\]:)') {
            throw "ADTF returned exit code $($process.ExitCode). $details"
        }
        if ($AllowRepairLog) { $details } else { $stdout.Result }
    } finally { $process.Dispose() }
}

function Get-Streams($path) {
    $inventory = (Invoke-Dattool @('--liststreams', $path, '--json')) | ConvertFrom-Json
    $inventory | ForEach-Object { $_.streams } | Where-Object { $null -ne $_ }
}

$scratch = $null
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
        $outputName = if ($outputFolder -eq $inputFile.DirectoryName) { $inputFile.BaseName + '.repaired.adtfdat' } else { $inputFile.Name }
        $destination = Join-Path $outputFolder $outputName
        if (Test-Path -LiteralPath $destination) { throw "Repair output already exists: $destination" }
        $scratch = Join-Path $outputFolder ('.adtf-repair-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $scratch | Out-Null
        $pending = Join-Path $scratch 'repair.adtfdat'
        Write-Output "Reference: $($reference.FullName)"
        $partialRepair = $false
        try {
            $details = Invoke-Dattool @('--repair', $inputFile.FullName, '--output', $pending, '--reference', $reference.FullName) -AllowRepairLog
        } catch {
            $details = $_.Exception.Message
            if ($details -notmatch 'ios_base::failbit set: iostream stream error' -or
                -not (Test-Path -LiteralPath $pending -PathType Leaf) -or
                (Get-Item -LiteralPath $pending).Length -eq 0) { throw }
            $partialRepair = $true
        }
        if ($details.Trim()) { Write-Output $details.Trim() }
        $partialRepair = $partialRepair -or $details -match 'Stopped processing at file offset'
        $unverified = $false
        try {
            $null = Get-Streams $pending
        } catch [OperationCanceledException] {
            throw
        } catch {
            if (-not $partialRepair -or -not (Test-Path -LiteralPath $pending -PathType Leaf) -or
                (Get-Item -LiteralPath $pending).Length -eq 0) { throw }
            $unverified = $true
            Write-Output "WARNING: The repair output could not be reopened: $($_.Exception.Message)"
        }
        if (Test-StopRequested) { throw [OperationCanceledException]::new() }
        [IO.File]::Move($pending, $destination)
        if ($unverified) {
            Write-Output "WARNING: Saved unverified repair output: $destination"
            exit 1
        }
        if ($partialRepair) {
            Write-Output "WARNING: Saved readable repair output; recovery may be incomplete: $destination"
            exit 0
        }
        Write-Output "OK: Repaired recording: $destination"
        exit 0
    }
    $streams = @(Get-Streams $env:CHECK_RECORDING)
    if (-not $streams.Count) {
        Write-Output 'WARNING: No streams were listed.'
        exit 1
    }

    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('adtf-stream-check-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $copy = Join-Path $scratch 'stream.adtfdat'
    try {
        $copyArguments = @('--create', $copy, '--input', $env:CHECK_RECORDING) + @(
            foreach ($stream in $streams) { '--stream'; $stream.stream }
        )
        $null = Invoke-Dattool $copyArguments
        $readback = @(Get-Streams $copy)
        foreach ($stream in $streams) {
            $matching = @($readback | Where-Object { $_.stream -ceq $stream.stream })
            if ($matching.Count -ne 1 -or $matching[0].item_count -ne $stream.item_count) {
                throw "Item count mismatch for '$($stream.stream)': expected $($stream.item_count), got $($matching.item_count -join ',')."
            }
        }
        foreach ($stream in $streams) {
            Write-Output "OK: $($stream.stream) ($($stream.item_count) items)"
        }
        Write-Output "Streams checked: $($streams.Count); with issues: 0."
        exit 0
    } catch [OperationCanceledException] {
        throw
    } catch {
        Write-Output "WARNING: The combined stream check could not be verified. Retrying streams individually. $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force }
    }

    $issues = 0
    foreach ($stream in $streams) {
        try {
            $null = Invoke-Dattool @('--create', $copy, '--input', $env:CHECK_RECORDING, '--stream', $stream.stream)
            $readback = @(Get-Streams $copy | Where-Object { $_.stream -ceq $stream.stream })
            if ($readback.Count -ne 1 -or $readback[0].item_count -ne $stream.item_count) {
                throw "Expected $($stream.item_count) items, but ADTF reported $($readback.item_count -join ',') after copying."
            }
            Write-Output "OK: $($stream.stream) ($($stream.item_count) items)"
        } catch [OperationCanceledException] {
            throw
        } catch {
            $issues++
            Write-Output "FAILED: $($stream.stream): $($_.Exception.Message)"
        } finally {
            if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Force }
        }
    }
    Write-Output "Streams checked: $($streams.Count); with issues: $issues."
    if ($issues) { exit 1 }
} catch [OperationCanceledException] {
    if ($Repair) { Write-Output 'Repair stopped.' } else { Write-Output 'Stream check stopped.' }
    exit 2
} catch {
    Write-Output "FAILED: $($_.Exception.Message)"
    exit 1
} finally {
    if ($scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}