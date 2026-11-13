@echo off
setlocal
set "JOG=C:\ProgramData\JOG"
if not exist "%JOG%\logs" mkdir "%JOG%\logs"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%JOG%\Start-JOGProvisioning.ps1" -Resume >> "%JOG%\logs\setupcomplete.log" 2>&1
exit /b 0
