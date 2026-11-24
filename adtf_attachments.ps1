# Reads the attached_files extension through "dattool --dump", which only touches the file header.
# "dattool --export" scans the complete recording, which takes minutes for recordings of tens of GB.
# Returns $true when the archive was written to $destination, $false when the recording has no attachments.
function Read-AttachedArchive($dattool, $recording, $destination) {
    $info = New-Object Diagnostics.ProcessStartInfo -Property @{
        FileName = $dattool; UseShellExecute = $false; CreateNoWindow = $true
        RedirectStandardOutput = $true; RedirectStandardError = $true
        Arguments = '--dump "{0}" --extension attached_files' -f $recording
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $errorTask = $process.StandardError.ReadToEndAsync()
        $text = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $errorText = $errorTask.Result
        if ($process.ExitCode -ne 0) {
            $message = ($errorText + $text).Trim()
            if ($message -cmatch "^exception: no extension with name '?attached_files'?( found)?\.?$") { return $false }
            throw "Cannot read existing attachments: $message"
        }
    } finally { $process.Dispose() }

    $hex = New-Object Text.StringBuilder
    foreach ($match in [regex]::Matches($text, '(?m)^[0-9a-f]{8}  ([0-9a-f ]*)\|')) {
        [void]$hex.Append($match.Groups[1].Value.Replace(' ', ''))
    }
    if (-not $hex.Length) { throw 'The attachment archive in the recording is empty.' }
    $bytes = [Runtime.Remoting.Metadata.W3cXsd2001.SoapHexBinary]::Parse($hex.ToString()).Value
    [IO.File]::WriteAllBytes($destination, $bytes)
    $true
}
