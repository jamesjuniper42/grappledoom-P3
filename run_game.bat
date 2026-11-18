@echo off
rem Starts the game at the title screen. New Game begins in the tutorial (GRAPPLE5).
pushd "%~dp0"
gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3
popd
pause
