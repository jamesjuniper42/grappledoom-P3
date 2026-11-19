// ---------------------------------------------------------------------------
// Co-op revive. A dead player stays down (the use key no longer respawns them while a
// teammate is alive) and a red X flashes above the corpse. A living player who runs over
// the corpse revives them: the downed player is "reborn" through the engine's normal co-op
// respawn, and the new body is moved to the corpse's spot with 30% of max health.
// Server cvar revive_enabled (default true) turns it on or off. Inventory resets as with any
// co-op respawn.
// ---------------------------------------------------------------------------
class ReviveX : Actor
{
	Default
	{
		Radius 1;
		Height 1;
		+NOGRAVITY
		+NOINTERACTION
		+BRIGHT
	}
	States
	{
	Spawn:
		REVX A -1;
		Stop;
	}
}

// Carries the revive spot from the corpse to the player's new body.
class ReviveMarker : Actor
{
	int pnum;
	int hp;
	int life;

	Default
	{
		Radius 1;
		Height 1;
		+NOGRAVITY
		+NOINTERACTION
		+INVISIBLE
	}
	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}

	override void Tick()
	{
		life++;
		if (life > 175) Destroy();    // the respawn did not happen: forget it
	}
}
