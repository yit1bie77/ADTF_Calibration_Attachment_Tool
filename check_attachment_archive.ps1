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