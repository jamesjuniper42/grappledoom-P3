@echo off
pushd "%~dp0"
gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3 +map GRAPPLE3
popd
pause
