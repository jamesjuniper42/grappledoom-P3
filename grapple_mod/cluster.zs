// The Cluster Demon: a fast, aggressive Cacodemon variant.
//
//  - Built on the stock Cacodemon, so it uses the loaded IWAD's cacodemon sprites
//    and sounds (Freedoom's version under Freedoom).
//  - Flies at 3x Doomguy's run speed, but slows to 0.5x once it is within 20 m of
//    its target.
//  - Attacks about twice as often as a Cacodemon.
//  - Its shot explodes like a rocket on impact, then throws out three bomblets
//    that arc forward under gravity (randomly spread) and each explode on impact.
//
// Units: 32 map units = 1 meter, 35 tics = 1 second. Doomguy runs at about
// 15.1 units per tic.

class ClusterDemon : Cacodemon
{
	const FAST_SPEED = 45.3;    // 3 x 15.1
	const SLOW_SPEED = 7.55;    // 0.5 x 15.1
	const SLOW_RANGE = 640.0;   // 20 m: slow down inside this distance to the target
	const SPEED_STEP = 3.0;     // speed change per tic, so it brakes smoothly

	Default
	{
		Tag "Cluster Demon";
		Speed 45.3;
	}

	States
	{
	// One-tic frames: A_Chase moves the monster by Speed units each time it runs, so
	// the Speed value is its speed in units per tic. (A Cacodemon uses 3-tic frames
	// and Speed 8, about 2.7 units per tic.)
	See:
		HEAD A 1
		{
			UpdateChaseSpeed();
			A_Chase();
		}
		Loop;

	// Winds up in 9 tics where a Cacodemon takes 15, and with 1-tic chase frames it
	// retries the attack check every tic, so it fires roughly twice as often.
	Missile:
		HEAD B 3 A_FaceTarget;
		HEAD C 3 A_FaceTarget;
		HEAD D 3 Bright FireCluster();
		Goto See;
	}

	// Fast when far, slow when close. Eases between the two.
	void UpdateChaseSpeed()
	{
		double want = FAST_SPEED;
		if (target && Distance3D(target) < SLOW_RANGE) want = SLOW_SPEED;
		if (Speed < want) Speed = min(Speed + SPEED_STEP, want);
		else Speed = max(Speed - SPEED_STEP, want);
	}

	void FireCluster()
	{
		if (!target) return;
		A_SpawnProjectile("ClusterBall", 32);
	}
}

// ---------------------------------------------------------------------------
// The demon's shot. On impact it explodes with a rocket's splash radius, then
// calls SpawnBurst() to throw out the bomblets.
// ---------------------------------------------------------------------------
class ClusterBall : Actor
{
	const BLAST_DAMAGE = 70;    // at the center; falls off with distance
	const BLAST_RADIUS = 128;   // same splash radius as a rocket
	const BURST_COUNT = 3;

	Default
	{
		Radius 6;
		Height 8;
		Speed 14;
		Damage 4;
		Projectile;
		SeeSound "caco/attack";
		DeathSound "weapons/rocklx";
	}

	States
	{
	Spawn:
		BAL2 AB 4 Bright;
		Loop;
	Death:
		MISL B 8 Bright
		{
			// flags 0: the explosion does not hurt the demon that fired it
			A_Explode(BLAST_DAMAGE, BLAST_RADIUS, 0, false, BLAST_RADIUS / 4);
			SpawnBurst();
		}
		MISL C 6 Bright;
		MISL D 4 Bright;
		Stop;
	}

	// Throw BURST_COUNT bomblets forward along the direction this shot was flying
	// (its angle), each with a random sideways spread, speed and lift, so they land
	// in different places. They start just back from the impact point and slightly
	// up so they are not spawned inside the wall or floor they hit.
	virtual void SpawnBurst()
	{
		for (int i = 0; i < BURST_COUNT; i++)
		{
			Actor b = Spawn("ClusterBomblet", pos + (-cos(angle) * 8, -sin(angle) * 8, 6));
			if (!b) continue;
			double a = angle + frandom(-30.0, 30.0);
			double sp = frandom(7.0, 13.0);
			b.target = target;          // credited to the demon; never hits it
			b.angle = a;
			b.Vel = (cos(a) * sp, sin(a) * sp, frandom(6.0, 11.0));
		}
	}
}

// ---------------------------------------------------------------------------
// A bomblet: affected by gravity, explodes on impact exactly like the main shot
// (same Death state), but does not burst again.
// ---------------------------------------------------------------------------
class ClusterBomblet : ClusterBall
{
	Default
	{
		Radius 5;
		Height 6;
		Damage 3;
		Gravity 0.7;
		Scale 0.8;
		-NOGRAVITY
	}

	States
	{
	Spawn:
		BAL1 AB 3 Bright;
		Loop;
	}

	override void SpawnBurst()
	{
	}
}
