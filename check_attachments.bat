@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "RECORDINGS_DIR=C:\workspace\ADTF\Tools\checkAttachment\20261029\Data"
if not "%~1"=="" set "RECORDINGS_DIR=%~1"

set "OUTPUT_DIR=%~dp0attachments"
set "DATTOOL=C:\Tools\ADTF\Releases\3.19.0\bin\adtf_dattool.exe"
set "TARTOOL=%SystemRoot%\System32\tar.exe"

if not exist "%DATTOOL%" (
    echo ADTF tool not found: "%DATTOOL%" 1>&2
    exit /b 2
)
if not exist "%TARTOOL%" (
    echo TAR tool not found: "%TARTOOL%" 1>&2
    exit /b 2
)

pushd "%RECORDINGS_DIR%" 2>nul
if errorlevel 1 (
    echo Cannot access folder: "%RECORDINGS_DIR%" 1>&2
    exit /b 2
)

set "FOUND="
set "FAILED="

for %%F in (*.adtfdat) do if exist "%%~fF" if not exist "%%~fF\" (
    if not exist "%OUTPUT_DIR%\." mkdir "%OUTPUT_DIR%"
    if not exist "%OUTPUT_DIR%\." (
        echo Cannot create output folder: "%OUTPUT_DIR%" 1>&2
        popd
        exit /b 2
    )
    set "FOUND=1"
    echo Checking "%%~fF"
    set "CHECK_RECORDING=%%~fF"
    set "CHECK_ARCHIVE=%OUTPUT_DIR%\%%~nF.attachments.tar.gz"
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0check_attachment_archive.ps1"
    if errorlevel 1 set "FAILED=1"
    echo.
)

if not defined FOUND echo No .adtfdat files found in "%RECORDINGS_DIR%".
popd
if defined FAILED exit /b 1
exit /b 0