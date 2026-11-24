# ADTF Calibration Attachment Tool

Run `ADTF Calibration Attachment Tool.exe` from the packaged folder. Keep the scripts and `runtime` directory beside the executable. The package contains no recordings or calibration data.

To replace calibration XML, select the folder with the corrected files, check the target recordings, and choose **Replace to selected**. The tool matches an exact `calibration_folder/<filename>.xml` path first. For filenames like `YYYYMMDDTHHMMSS_camera.xml`, it can also match by the case-sensitive camera suffix after the timestamp. It removes the matched XML and keeps the new filename. Ambiguous matches are rejected. Other attachments are left unchanged. **Attach to selected** and **Replace to selected** modify the selected recording in place, with no copy, so make a backup first. The tool reads the existing attachments from the file header only, writes the new archive, and verifies it by reading it back; if verification fails, it restores the previous archive when there was one. Recordings with no matching XML are not changed. Because nothing is copied or scanned, the operation takes seconds regardless of recording size.

The app targets 64-bit Windows 10/11 with Windows PowerShell 5.1, .NET Framework 4.8, and the Windows `tar.exe` utility available. It uses the bundled ADTF executable rather than requiring a separate ADTF installation.

The launcher sets `RemoteSigned` for its PowerShell process only. No administrator rights or system-wide policy changes are needed. If you received the package as a ZIP from a trusted source, check its Windows Properties for an **Unblock** option before extracting it. If scripts are still blocked, run `Get-ExecutionPolicy -List` in Windows PowerShell. A policy set under `MachinePolicy` or `UserPolicy` takes precedence; contact your IT administrator for an approved way to run the tool.

To rebuild from source, run `.\build_calibration_package.ps1` in Windows PowerShell. The default output is `dist\ADTF Calibration Attachment Tool`; use `-AdtfRoot` to point to a different location of the ADTF 3.19.0 release.

Confirm the ADTF and runtime redistribution terms before sharing the package.