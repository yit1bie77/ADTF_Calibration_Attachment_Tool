param([switch]$Extract)

$recording = $env:CHECK_RECORDING
$archive = $env:CHECK_ARCHIVE

function Exit-IfStopped {
    if ($env:ADTF_STOP_FILE -and [IO.File]::Exists($env:ADTF_STOP_FILE)) { exit 2 }
}

Exit-IfStopped
. (Join-Path $PSScriptRoot 'adtf_attachments.ps1')
try {
    $hasArchive = Read-AttachedArchive $env:DATTOOL $recording $archive
} catch {
    Write-Host $_.Exception.Message
    Write-Host 'WARNING: Could not read attachments.' -ForegroundColor Yellow
    exit 1
}
Exit-IfStopped
if (-not $hasArchive) {
    Write-Host 'FAILED: No calibration XML file was attached.' -ForegroundColor Red
    exit 1
}

Write-Output ('Archive: "{0}"' -f $archive)
$entries = & $env:TARTOOL -tf $archive
Exit-IfStopped
if ($LASTEXITCODE -ne 0) {
    Write-Host 'WARNING: Could not list the attachment archive.' -ForegroundColor Yellow
    exit 1
}

if ($Extract) {
    $ErrorActionPreference = 'Stop'
    $issues = 0
    $saved = 0
    try {
        $folder = Get-Item -LiteralPath $env:XML_FOLDER
        if (-not $folder.PSIsContainer -or $folder.PSProvider.Name -ne 'FileSystem') { throw 'Choose a calibration XML folder.' }
        foreach ($entry in @($entries | Where-Object { $_ -like '*.xml' } | Select-Object -Unique)) {
            Exit-IfStopped
            $name = [IO.Path]::GetFileName($entry)
            $temp = $null
            try {
                if ($entry -match '[*?\[\]"\\]' -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                    @($entries -ceq $entry).Count -ne 1) { throw 'Unsupported or ambiguous archive path.' }
                $destination = Join-Path $folder.FullName $name
                if (Test-Path -LiteralPath $destination) { throw "File already exists: $destination" }
                $temp = Join-Path $folder.FullName ('.adtf-extract-' + [guid]::NewGuid() + '.tmp')
                $info = New-Object Diagnostics.ProcessStartInfo -Property @{
                    FileName = $env:TARTOOL; Arguments = '-xOf "{0}" -- "{1}"' -f $archive, $entry
                    UseShellExecute = $false; CreateNoWindow = $true
                    RedirectStandardOutput = $true; RedirectStandardError = $true
                }
                $file = [IO.File]::Open($temp, [IO.FileMode]::CreateNew)
                try {
                    $process = [Diagnostics.Process]::Start($info)
                    try {
                        $errors = $process.StandardError.ReadToEndAsync()
                        $process.StandardOutput.BaseStream.CopyTo($file)
                        $process.WaitForExit()
                        if ($process.ExitCode -ne 0) { throw $errors.Result }
                        if ($file.Length -eq 0) { throw 'Archive entry is empty or is not a regular file.' }
                    } finally { $process.Dispose() }
                } finally { $file.Dispose() }
                Exit-IfStopped
                [IO.File]::Move($temp, $destination)
                $saved++
                Write-Output "OK: Extracted $destination"
            } catch {
                $issues++
                Write-Output "WARNING: Skipped '$entry': $($_.Exception.Message)"
            } finally {
                if ($temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not ($saved + $issues)) { Write-Output 'FAILED: No calibration XML file was attached.'; exit 1 }
        if ($issues) { exit 1 }
        exit 0
    } catch { Write-Output "FAILED: $($_.Exception.Message)"; exit 1 }
}

$entries
$xmlNames = @($entries | ForEach-Object {
    $name = [IO.Path]::GetFileName($_)
    if ($name.EndsWith('.xml', [StringComparison]::OrdinalIgnoreCase)) { $name }
})
if ($xmlNames.Count -eq 0) {
    Write-Host 'FAILED: No calibration XML file was attached.' -ForegroundColor Red
    exit 1
}

$recordingName = [IO.Path]::GetFileNameWithoutExtension($recording)
$recordingDate = $null
foreach ($dateMatch in [regex]::Matches($recordingName, '(?<![0-9])[0-9]{8}(?![0-9])')) {
    $parsedDate = [datetime]::MinValue
    if ([datetime]::TryParseExact($dateMatch.Value, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
        $recordingDate = $dateMatch.Value
        break
    }
}
if (-not $recordingDate) {
    Write-Host 'WARNING: Recording filename has no valid YYYYMMDD date.' -ForegroundColor Yellow
    exit 1
}

$datePattern = '(?<![0-9])' + $recordingDate + '(?:(?:[01][0-9]|2[0-3])[0-5][0-9](?:[0-5][0-9])?)?(?![0-9])'

if ($xmlNames -match $datePattern) {
    Write-Host 'OK' -ForegroundColor Green
    exit 0
}

Write-Host ('WARNING: XML attachments were found, but none of their filenames match the recording date ({0}).' -f $recordingDate) -ForegroundColor Yellow
exit 1