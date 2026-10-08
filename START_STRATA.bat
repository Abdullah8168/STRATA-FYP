@echo off
REM ----------------------------------------------------------------------
REM STRATA - start the whole demo with one double-click.
REM
REM Before: 1) laptop on normal Wi-Fi (with internet)
REM         2) Ethernet cable laptop <-> Pi plugged in
REM         3) Pi powered on
REM Then double-click this file. Two windows open:
REM   "STRATA BLOCKCHAIN - keep open" and "STRATA TUNNEL - keep open"
REM Keep both open while you use the app. Close them when you are done.
REM ----------------------------------------------------------------------
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "host_node\scripts\demo_payment_up.ps1"
echo.
echo Phone: connect to Wi-Fi STRATA-Pi-01 (password strata2026), turn mobile data off,
echo open the STRATA app, Nearby Hosts.
echo.
pause
