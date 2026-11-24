param([switch]$Replace)

$ErrorActionPreference = 'Stop'

$dattool = $env:DATTOOL
if (-not $dattool) { $dattool = 'C:\Tools\ADTF\Releases\3.19.0\bin\adtf_dattool.exe' }
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
. (Join-Path $PSScriptRoot 'adtf_attachments.ps1')
$work = $null
$modified = $false
$verified = $false
$hadOriginal = $false
$originalArchive = $null

function Write-AttachedArchive($recordingPath, $archive) {
    $modify = Start-Process -FilePath $dattool -ArgumentList ('--modify "{0}" --extension attached_files' -f $recordingPath) `
        -RedirectStandardInput $archive -NoNewWindow -Wait -PassThru
    $modify.ExitCode -eq 0
}

function Exit-IfStopped {
    if ($env:ADTF_STOP_FILE -and [IO.File]::Exists($env:ADTF_STOP_FILE)) { exit 2 }
}

function Copy-GzipArchive($source, $destination, [switch]$Compress) {
    $inputStream = [IO.File]::OpenRead($source)
    try {
        $outputStream = [IO.File]::Create($destination)
        try {
            if ($Compress) {
                $gzip = [IO.Compression.GZipStream]::new($outputStream, [IO.Compression.CompressionMode]::Compress)
                try { $inputStream.CopyTo($gzip) } finally { $gzip.Dispose() }
            } else {
                $gzip = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
                try { $gzip.CopyTo($outputStream) } finally { $gzip.Dispose() }
            }
        } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
}

function Get-ArchiveEntries($archive) {
    $entries = & $tar -tf $archive
    if ($LASTEXITCODE -ne 0) { throw "Cannot read archive: $archive" }
    $entries | ForEach-Object { $_ -replace '^(\./)+', '' }
}

try {
    Exit-IfStopped
    foreach ($tool in @($dattool, $tar)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Tool not found: $tool" }
    }
    $recording = Get-Item -LiteralPath $env:ADTF_FILE
    if ($recording.PSIsContainer -or $recording.Extension -ne '.adtfdat') {
        throw 'ADTF_FILE must point to a .adtfdat recording.'
    }
    $xmlFiles = @(Get-ChildItem Env: | Where-Object { $_.Name -match '^XML_FILE_[1-9]\d*$' -and $_.Value } |
        ForEach-Object { Get-Item -LiteralPath $_.Value })
    if ($env:XML_FOLDER) {
        $xmlFiles = @(Get-ChildItem -LiteralPath $env:XML_FOLDER -Filter '*.xml' -File | Where-Object Extension -eq '.xml')
        if (-not $xmlFiles.Count) { throw "No XML files in: $env:XML_FOLDER" }
    } elseif (-not $xmlFiles.Count) {
        if (-not $env:XML_FILE) { throw 'Set XML_FILE or at least one XML_FILE_n variable.' }
        $xmlFiles = @(Get-ChildItem -Path $env:XML_FILE -File | Where-Object Extension -eq '.xml')
        if (-not $xmlFiles.Count) { throw "No XML files match: $env:XML_FILE" }
    }
    $newEntries = @{}
    foreach ($xml in $xmlFiles) {
        if ($xml.PSIsContainer -or $xml.Extension -ne '.xml') { throw "Not an XML file: $($xml.FullName)" }
        $entry = 'calibration_folder/' + $xml.Name
        if ($newEntries.ContainsKey($entry)) { throw "Duplicate XML filename: $($xml.Name)" }
        $newEntries[$entry] = $xml.FullName
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('adtf-attach-' + [guid]::NewGuid())
    $staging = Join-Path $work 'calibration_folder'
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $originalArchive = Join-Path $work 'original.tar.gz'
    $updatedTar = Join-Path $work 'updated.tar'
    $updatedArchive = Join-Path $work 'updated.tar.gz'
    $verificationArchive = Join-Path $work 'verified.tar.gz'
    $tarSources = @()

    $hadOriginal = Read-AttachedArchive $dattool $recording.FullName $originalArchive
    Exit-IfStopped
    if ($hadOriginal) {
        $existingEntries = @(Get-ArchiveEntries $originalArchive)
        Exit-IfStopped
        if ($Replace) {
            $candidateEntries = @($newEntries.Keys | Sort-Object)
            $attachedXml = @($existingEntries | Where-Object { $_ -match '\.xml$' } | Sort-Object)
            $timestampedPath = '^calibration_folder/[0-9]{8}T[0-9]{6}_(?<camera>[^/]+\.xml)$'
            $removedEntries = New-Object 'System.Collections.Generic.List[string]'
            $renamedEntries = New-Object 'System.Collections.Generic.List[string]'
            foreach ($entry in $candidateEntries) {
                $oldEntry = $null
                if ($existingEntries -ccontains $entry) {
                    $oldEntry = $entry
                } elseif ($entry -cmatch $timestampedPath) {
                    $camera = $Matches.camera
                    $matchingEntries = @($attachedXml | Where-Object {
                        $_ -cmatch $timestampedPath -and $Matches.camera -ceq $camera
                    })
                    if ($matchingEntries.Count -gt 1) {
                        throw "Ambiguous replacement for $entry. Matching attachments: $($matchingEntries -join ', ')"
                    }
                    if ($matchingEntries.Count -eq 1) { $oldEntry = $matchingEntries[0] }
                }
                if (-not $oldEntry) { $newEntries.Remove($entry); continue }
                if ($removedEntries -ccontains $oldEntry) {
                    throw "Multiple selected XML files match $oldEntry. Keep only the intended replacement in the calibration folder."
                }
                $removedEntries.Add($oldEntry)
                if ($oldEntry -cne $entry) { $renamedEntries.Add("Replaced $oldEntry with $entry") }
            }
            if (-not $newEntries.Count) {
                $attachedPaths = if ($attachedXml.Count) { $attachedXml -join ', ' } else { '(none)' }
                throw ("No existing calibration XML paths match the selected folder by exact path or camera suffix.`n" +
                    "XML paths in recording: $attachedPaths`nXML paths offered: $($candidateEntries -join ', ')")
            }
            $exclusions = foreach ($entry in $removedEntries) { '--exclude=' + $entry.Replace('[', '[[]') }
            $tarSources = @($exclusions) + "@$originalArchive"
            & $tar -cf $updatedTar @tarSources
            if ($LASTEXITCODE -ne 0) { throw 'Cannot rebuild the attachment archive.' }
            $tarSources = @()
            $retainedEntries = @($existingEntries | Where-Object { $removedEntries -cnotcontains $_ })
        } else {
            foreach ($entry in $newEntries.Keys) {
                if ($existingEntries -contains $entry) { throw "Attachment already exists: $entry" }
            }
            Copy-GzipArchive $originalArchive $updatedTar
        }
        $tarMode = '-rf'
    } else {
        if ($Replace) { throw 'This recording has no attachment archive to replace calibration XML in.' }
        $tarMode = '-cf'
    }

    foreach ($entry in $newEntries.Keys) {
        Exit-IfStopped
        Copy-Item -LiteralPath $newEntries[$entry] -Destination $staging
    }
    & $tar $tarMode $updatedTar -C $work @($newEntries.Keys)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot pack the XML attachments.' }
    Exit-IfStopped
    Copy-GzipArchive $updatedTar $updatedArchive -Compress

    # The recording is modified in place (no copy); stopping is only possible before this point.
    Exit-IfStopped
    $modified = $true
    if (-not (Write-AttachedArchive $recording.FullName $updatedArchive)) { throw 'Cannot write the attachment archive.' }
    if (-not (Read-AttachedArchive $dattool $recording.FullName $verificationArchive)) {
        throw 'The modified recording has no attachment archive.'
    }
    if ((Get-FileHash -LiteralPath $updatedArchive).Hash -ne (Get-FileHash -LiteralPath $verificationArchive).Hash) {
        $writtenSize = (Get-Item -LiteralPath $updatedArchive).Length
        $readSize = (Get-Item -LiteralPath $verificationArchive).Length
        throw "The archive in the modified recording differs from the archive written ($writtenSize bytes written, $readSize bytes read back)."
    }
    $entries = @(Get-ArchiveEntries $verificationArchive)
    if ($Replace) {
        $expectedEntries = $retainedEntries + @($newEntries.Keys)
        if (Compare-Object -ReferenceObject $expectedEntries -DifferenceObject $entries -CaseSensitive) {
            throw 'Verification found missing or unexpected attachment entries after replacement.'
        }
    }
    foreach ($entry in $newEntries.Keys) {
        if ($entries -cnotcontains $entry) { throw "Verification did not find: $entry" }
    }

    $verified = $true
    Write-Output "Verified recording: $($recording.FullName)"
    if ($Replace) { $renamedEntries | Write-Output }
    $entries
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($modified -and -not $verified) {
        if ($hadOriginal -and (Write-AttachedArchive $recording.FullName $originalArchive)) {
            [Console]::Error.WriteLine('The original attachment archive was restored.')
        } else {
            [Console]::Error.WriteLine('The recording may have been modified. Restore it from your backup.')
        }
    }
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}