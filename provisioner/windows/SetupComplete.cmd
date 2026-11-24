@echo off
setlocal
set "MIST=C:\ProgramData\MIST"
if not exist "%MIST%\logs" mkdir "%MIST%\logs"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MIST%\Start-JOGProvisioning.ps1" -Resume >> "%MIST%\logs\setupcomplete.log" 2>&1
exit /b 0
