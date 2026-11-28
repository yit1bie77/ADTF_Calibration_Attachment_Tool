# ISS ADTF Data Tool

Run `adtf_dattool_gui_iss.exe` from the packaged folder. Keep the scripts and `runtime` directory beside the executable. The package contains no recordings or calibration data.

To extract calibration XMLs, select the recordings, choose a **Calibration XML folder**, and click **Extract calibration files**. XMLs are saved directly in that folder with their original filenames. Existing files are skipped, and recordings are not modified.

In **Streams**, select recordings and click **Analyze recording** to display each file's ADTF header, index and extension entries, and stream inventory. This quick check does not read samples.

Click **Check sample readability** to have ADTF read and deserialize all samples in each selected recording. The scan reports read errors or a premature end, without modifying the recording or writing a copy. Scan time still depends on recording size and read speed. A pass confirms readability, not sample value correctness or checksums. Select split recording files individually to check each one.

In **Streams**, repaired recordings are saved as `<original-name>_rep.adtfdat`. Choose a separate **Repair output folder**, or leave it blank to save each copy beside its original. Existing outputs are not overwritten. If ADTF stops early, check the repair warnings before using the output.

To replace calibration XML, select the folder with the corrected files, check the target recordings, and choose **Replace to selected**. The tool matches an exact `calibration_folder/<filename>.xml` path first. For filenames like `YYYYMMDDTHHMMSS_camera.xml`, it can also match by the case-sensitive camera suffix after the timestamp. It removes the matched XML and keeps the new filename. Ambiguous matches are rejected. Other attachments are left unchanged. **Attach to selected** and **Replace to selected** modify the selected recording in place, with no copy, so make a backup first. The tool reads the existing attachments from the file header only, writes the new archive, and verifies it by reading it back; if verification fails, it restores the previous archive when there was one. Recordings with no matching XML are not changed. Because nothing is copied or scanned, the operation takes seconds regardless of recording size.

The app targets 64-bit Windows 10/11 with Windows PowerShell 5.1, .NET Framework 4.8, and the Windows `tar.exe` utility available. It uses the bundled ADTF executable rather than requiring a separate ADTF installation.

The launcher sets `RemoteSigned` for its PowerShell process only. No administrator rights or system-wide policy changes are needed. If you received the package as a ZIP from a trusted source, check its Windows Properties for an **Unblock** option before extracting it. If scripts are still blocked, run `Get-ExecutionPolicy -List` in Windows PowerShell. A policy set under `MachinePolicy` or `UserPolicy` takes precedence; contact your IT administrator for an approved way to run the tool.

To rebuild from source, run `.\build_calibration_package.ps1` in Windows PowerShell with CMake and the Visual Studio 2022 x64 C++ tools installed. The default output is `dist\adtf_dattool_gui_iss`. Use `-AdtfRoot` to select a compatible ADTF File Library other than the bundled one. Use `-DevEssentialRoot` to point to a compatible Dev Essential SDK if it is not installed under `C:\Tools\ADTF\Releases\3.19.0\pkg\dev_essential`.

Confirm the ADTF and runtime redistribution terms before sharing the package.