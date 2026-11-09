// The Skid Cannon: replaces the starting pistol.
//
//  - Fires slow-ish glowing bolts (a projectile, not hitscan) at about the plasma
//    rifle's rate: one shot every 3 tics while the button is held.
//  - A bolt that hits the floor does not explode. It turns into a ground-hugger
//    and keeps sliding in the horizontal direction it was fired, with no vertical
//    motion, until it hits a wall, a tall step or an enemy, where it explodes like
//    a normal shot.
//  - Uses the plasma rifle's sprites and sounds from the loaded IWAD, and needs no
//    ammo.
//
// Units: 32 map units = 1 meter, 35 tics = 1 second.

class SkidCannon : DoomWeapon
{
	Default
	{
		Weapon.SelectionOrder 1900;
		Weapon.AmmoUse 0;
		Weapon.AmmoGive 0;
		Inventory.PickupMessage "You got the Skid Cannon!";
		Tag "Skid Cannon";
	}

	States
	{
	Ready:
		PLSG A 1 A_WeaponReady;
		Loop;
	Deselect:
		PLSG A 1 A_Lower;
		Loop;
	Select:
		PLSG A 1 A_Raise;
		Loop;
	// Same cycle as the plasma rifle: the shot fires on the 3-tic frame and A_ReFire
	// jumps straight back to it while the button is held, so the rate is one shot
	// per 3 tics. The 20-tic frame is only the cool-down after the button is released.
	Fire:
		PLSG A 3 FireSkid();
		PLSG B 20 A_ReFire;
		Goto Ready;
	Flash:
		PLSF A 4 Bright A_Light1;
		Goto LightDone;
		PLSF B 4 Bright A_Light1;
		Goto LightDone;
	Spawn:
		PLAS A -1;
		Stop;
	}

	action void FireSkid()
	{
		if (player == null) return;
		State flash = invoker.FindState('Flash');
		if (flash != null) player.SetSafeFlash(invoker, flash, random(0, 1));
		SpawnPlayerMissile("SkidBolt");
	}
}

class SkidBolt : Actor
{
	const HOVER = 4.0;        // how far above the floor it travels while sliding
	const STEP_UP = 24.0;     // floor rises up to this much are climbed; more is a wall
	const SLIDE_LIFE = 175;   // tics (5 s) of sliding before it burns out

	bool sliding;
	int slideTics;

	Default
	{
		Radius 13;
		Height 8;
		Speed 25;
		Damage 5;
		Projectile;
		+RANDOMIZE
		+ZDOOMTRANS
		RenderStyle "Add";
		Alpha 0.75;
		SeeSound "weapons/plasmaf";
		DeathSound "weapons/plasmax";
	}

	States
	{
	Spawn:
		PLSS AB 6 Bright;
		Loop;
	Death:
		PLSE ABCDE 4 Bright;
		Stop;
	}

	override void Tick()
	{
		if (!sliding)
		{
			// About to reach the floor this tic: start sliding instead of exploding.
			if (vel.z < 0 && pos.z + vel.z <= floorz)
			{
				StartSlide();
			}
		}
		else if (bMissile)
		{
			slideTics++;
			if (slideTics > SLIDE_LIFE)
			{
				// Stop sliding BEFORE exploding. Otherwise this branch runs again next
				// tic and returns early, so Super.Tick() never runs, the Death state
				// never advances and the bolt hangs there forever.
				sliding = false;
				ExplodeMissile(null, null);
				return;
			}
			// Follow the ground: look at the floor under the next position. A small
			// rise or drop is followed; a big rise is left alone so the move into it
			// is blocked and the bolt explodes against it like a wall.
			vector2 nextXY = pos.xy + vel.xy;
			Sector nextSec = Level.PointInSector(nextXY);
			if (nextSec)
			{
				double nextFloor = nextSec.floorplane.ZAtPoint(nextXY);
				if (nextFloor - floorz <= STEP_UP) SetZ(nextFloor + HOVER);
			}
		}

		Super.Tick();

		// Re-snap to the floor under the new position (covers slopes and drops). Skipped
		// once the bolt has exploded (a missile that has hit something loses +MISSILE).
		if (sliding && bMissile) SetZ(floorz + HOVER);
	}

	void StartSlide()
	{
		vector2 flat = vel.xy;
		double len = flat.Length();
		if (len < 0.5)
		{
			// fired straight down: nothing to slide along
			ExplodeMissile(null, null);
			return;
		}
		sliding = true;
		slideTics = 0;
		vel = (flat.x / len * Speed, flat.y / len * Speed, 0);
		SetZ(floorz + HOVER);
	}
}
