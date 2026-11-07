GRAPPLE YARD  -  mouse-only grappling hook mod for GZDoom

You do NOT need Doom 2. This package includes Freedoom: Phase 2
(freedoom2.wad), a free replacement for the Doom 2 IWAD. See COPYING.txt
and CREDITS.txt for its license and credits.

This package also includes GZDoom.
(For a version without GZDoom, view branch just-mod-and-freedoom)
(And if you don't want freedoom2 either, you just need GrappleMod.pk. README and run_grapple are optional)

SETUP
1. Run the game through run_grapple.bat.
   (alternatively, run: gzdoom.exe and add "-iwad freedoom2.wad -file GrappleMod.pk3 +map GRAPPLE1" to the command line)
2. If right click does nothing: open the console with ~ and type
        bind mouse2 +altattack

CONTROLS
Mouse look to aim. Right click fires the grappling hook. That is the only way
to move. Left click shoots. Hooking a door or switch opens it. The hook
can latch onto enemies (you get pulled to them), ignores the sky, and
automatically climbs onto ledges up to about 3 m above where it hits.

TROUBLESHOOTING
- Run it from a normal Windows folder (for example C:\Games\GZDoom), not a
  WSL/Linux path like \\wsl.localhost\...
- From a WSL terminal you can also run:
    ./gzdoom.exe -iwad freedoom2.wad -file GrappleMod.pk3 +map GRAPPLE1
