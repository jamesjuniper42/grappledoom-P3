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

MAPS
GRAPPLE1  small test yard (run_grapple.bat).
GRAPPLE2  the speedway (run_speedway.bat): a huge four-lane loop under open sky with
          traffic. Two lanes drive each way. Shoot cars to make them swerve and blow up.
          Hook a car head-on and you get launched and hurt; hit one from behind and you
          take on its speed. Or in the console: map GRAPPLE2

CLUSTER DEMON  a fast cacodemon variant (placed in both maps). Flies at 3x run speed, slows
          to 0.5x within 20 m, fires twice as often. Its shot explodes like a rocket, then
          throws three gravity-affected bomblets that each explode on impact.

LEAPER  a mancubus (speedway only) that leaps 5 m high and 10 m forward at you when you are
          more than 30 m away. It cannot shoot while in the air.

INVINCIBILITY  open the console (~) and type  invincible  to toggle it on and off.
          (The built-in  god  command does the same thing.)

SKID CANNON  the starting weapon (replaces the pistol). Fires plasma-style bolts at the
          plasma rifle's rate. A bolt that hits the floor slides along it in the direction it
          was fired until it hits a wall or an enemy.

RAM CAR  (speedway) a dark car with two imps on the roof that tries to run you over. It cannot
          turn well at speed, so dodge it and it swings out wide before the next run. It backs
          up when it hits a wall. Shoot the imps; the car itself is armored. Kill both and the
          car swerves off and explodes.

SPEEDWAY GOAL  grab the blue keycard in the middle of the infield (hook over the wall), then
          open the blue door of the exit room in the top-left corner outside the loop and press
          the exit switch inside.

GRAPPLE3  the town (run_town.bat): survive 5 waves. Reach each bright beacon tower in order
          (the on-screen message says where); enemies appear when you get there. Cacodemons and
          ram cars; enemies drop health and ammo. After wave 5 the exit door in the north-west
          corner opens.

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
