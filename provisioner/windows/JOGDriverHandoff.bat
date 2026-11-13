@echo off
setlocal

rem First-logon bridge: install the detected model pack (plus the VMD base pack), then continue the existing root-level setup.
set "SCRIPT_DIR=%~dp0"
set "DRIVER_SCRIPT=%SCRIPT_DIR%Install-JOGDriverPack.ps1"
set "DRIVER_SHARE=\\10.99.0.1\Drivers"

rem Require the companion installer before starting the handoff.
if not exist "%DRIVER_SCRIPT%" (
    echo [JOG] Missing driver installer: "%DRIVER_SCRIPT%"
    exit /b 2
)

rem Install drivers while the device is still connected to the isolated JOG network.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DRIVER_SCRIPT%" -ShareRoot "%DRIVER_SHARE%"
if errorlevel 1 (
    echo [JOG] Driver installation failed. The existing first-run flow was not started.
    exit /b 1
)

rem Hand control to the existing root-level first-run script after driver installation succeeds.
if not exist "C:\firstrun.bat" (
    echo [JOG] Missing C:\firstrun.bat; driver installation succeeded, but setup cannot continue.
    exit /b 3
)

call "C:\firstrun.bat"
exit /b %ERRORLEVEL%
