param(
    [string]$AdtfRoot = (Join-Path $PSScriptRoot 'adtf_file_library'),
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'dist\adtf_dattool_gui_iss'),
    [string]$DevEssentialRoot = 'C:\Tools\ADTF\Releases\3.19.0\pkg\dev_essential'
)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$bin = Join-Path $AdtfRoot 'bin'
$dattool = Join-Path $bin 'adtf_dattool.exe'
$sdkConfig = Join-Path $DevEssentialRoot 'lib\cmake\dev_essential\dev_essential-config.cmake'
foreach ($required in @($compiler, $dattool, $sdkConfig)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file not found: $required" }
}

$scanBuild = Join-Path $PSScriptRoot 'dist\sample_scan_build'
$adtfConfigDir = (Resolve-Path -LiteralPath (Join-Path $AdtfRoot 'lib\cmake\adtf_file')).Path
$sdkConfigDir = (Get-Item -LiteralPath $sdkConfig).DirectoryName
& cmake -S (Join-Path $PSScriptRoot 'sample_scan') -B $scanBuild -G 'Visual Studio 17 2022' -A x64 "-Dadtf_file_DIR=$adtfConfigDir" "-Ddev_essential_DIR=$sdkConfigDir"
if ($LASTEXITCODE -ne 0) { throw "Sample scanner configuration failed (exit $LASTEXITCODE)." }
& cmake --build $scanBuild --config RelWithDebInfo
if ($LASTEXITCODE -ne 0) { throw "Sample scanner build failed (exit $LASTEXITCODE)." }

$package = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder)
$runtime = Join-Path $package 'runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$launcher = Join-Path $package 'adtf_dattool_gui_iss.exe'
& $compiler /nologo /target:winexe /platform:x64 /reference:System.Windows.Forms.dll "/out:$launcher" (Join-Path $PSScriptRoot 'CalibrationLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed (exit $LASTEXITCODE)." }

foreach ($name in @('calibration_gui.ps1', 'check_attachment_archive.ps1', 'check_adtf_streams.ps1', 'attach_calibration.ps1', 'adtf_attachments.ps1', 'PACKAGE.md')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $package -Force
}
Copy-Item -LiteralPath $dattool -Destination $runtime -Force
Copy-Item -LiteralPath (Join-Path $scanBuild 'RelWithDebInfo\adtf_sample_scan.exe') -Destination $runtime -Force
Get-ChildItem -LiteralPath $bin -Filter '*.dll' -File | Where-Object Name -Match '^(?:concrt|msvcp|vcruntime)140.*\.dll$' |
    Copy-Item -Destination $runtime -Force
$license = Join-Path $AdtfRoot 'LICENSE'
if (Test-Path -LiteralPath $license -PathType Leaf) {
    Copy-Item -LiteralPath $license -Destination (Join-Path $runtime 'ADTF-LICENSE.txt') -Force
}
Write-Output $launcher