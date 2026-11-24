@echo off
setlocal EnableExtensions DisableDelayedExpansion

if not defined ADTF_FILE set "ADTF_FILE=%~dp020261029\Data\20261121T140403.adtfdat"
if not defined XML_FILE set "XML_FILE=E:\temp\*.xml"

echo Input recording: "%ADTF_FILE%"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "%~dp0attach_calibration.ps1"
exit /b %errorlevel%