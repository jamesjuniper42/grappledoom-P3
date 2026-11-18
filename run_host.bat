@echo off
rem Host a co-op game. Usage: run_host.bat [players] [map]   e.g. run_host.bat 2 GRAPPLE4
rem Friends join with run_join.bat. The host needs UDP port 5029 open (firewall / router).
pushd "%~dp0"
set PLAYERS=%1
if "%PLAYERS%"=="" set PLAYERS=2
set MAPNAME=%2
if "%MAPNAME%"=="" set MAPNAME=GRAPPLE5
gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3 -host %PLAYERS% -skill 3 +map %MAPNAME%
popd
pause
