@echo off
rem Join a co-op game. Usage: run_join.bat [host address]   e.g. run_join.bat 192.168.1.20
rem Two copies on one PC: run_host.bat in one window, run_join.bat 127.0.0.1 in another.
pushd "%~dp0"
set HOSTADDR=%1
if "%HOSTADDR%"=="" set /p HOSTADDR=Host address: 
gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3 -join %HOSTADDR%
popd
pause
