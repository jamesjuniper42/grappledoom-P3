GRAPPLE YARD  -  mouse-only grappling hook mod for GZDoom

You do NOT need Doom 2. This package includes Freedoom: Phase 2
(freedoom2.wad), a free replacement for the Doom 2 IWAD. See COPYING.txt
and CREDITS.txt for its license and credits.

(If you don't want freedoom2, you just need GrappleMod.pk. README and run_grapple are optional)

SETUP
1. Download GZDoom (4.14 or newer) from https://zdoom.org/downloads and
   unzip it.
2. Copy ALL files from this package into the same folder as gzdoom.exe.
3. Double-click run_grapple.bat.
   (Or run: gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3 +map GRAPPLE1)
4. If right click does nothing: open the console with ~ and type
        bind mouse2 +altattack

CONTROLS
Mouse look to aim. Right click fires the grappling hook. That is the only way
to move. Left click shoots. Hooking a door or switch opens it. The hook
ignores enemies and the sky.

TROUBLESHOOTING
- Run it from a normal Windows folder (for example C:\Games\GZDoom), not a
  WSL/Linux path like \\wsl.localhost\...
- From a WSL terminal you can also run:
    ./gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3 +map GRAPPLE1
