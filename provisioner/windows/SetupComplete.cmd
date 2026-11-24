@echo off
setlocal
set "Brume=C:\ProgramData\Brume"
if not exist "%Brume%\logs" mkdir "%Brume%\logs"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%Brume%\Start-JOGProvisioning.ps1" -Resume >> "%Brume%\logs\setupcomplete.log" 2>&1
exit /b 0
