// The Ram Car: a vehicle enemy. A dark car with two imps riding on the roof.
//
//  - It tries to ram the player. Its steering is limited, and the faster it goes the
//    less it can turn, so when the player dodges it sweeps out a long arc before it
//    can come back for another run.
//  - If it hits terrain it backs up while swinging its nose around, then drives forward
//    at an angle.
//  - The riders (RamImp) are separate shootable actors with their own health. Each
//    shoots imp fireballs at the player. The car body itself cannot be hurt.
//  - When both riders are dead the car loses control, careens off in a random direction
//    and explodes (like the traffic cars do).
//
// Player/car impacts reuse GrapplePlayer.CheckCarHits, because RamCar is a TrafficCar.
// Units: 32 map units = 1 meter, 35 tics = 1 second.

class RamCar : TrafficCar
{
	const MAX_SPEED = 14.0;      // forward top speed, units per tic
	const REV_SPEED = 7.0;       // reverse speed
	const ACCEL_FWD = 0.35;
	const BRAKE_RATE = 0.8;
	const TURN_SLOW = 3.5;       // degrees per tic of heading change when crawling
	const TURN_FAST = 1.6;       // ...and at top speed (the harder you go, the wider you swing)
	const WAKE_RANGE = 4000.0;   // only hunts a player closer than this
	const REV_TICS = 30;         // basic reverse duration
	const BLOCK_RATIO = 0.5;     // moved less than this fraction of expected = blocked
	const DEATH_TICS = 70;       // longest it careens before exploding
	const RIDER_Z = 38.0;        // roof height for the riders' feet
	const RIDER_OFS = 22.0;      // riders sit this far ahead of / behind the center

	RamImp riderFront;
	RamImp riderBack;
	double spd;                  // signed speed along the heading (negative = reversing)
	int phase;                   // 0 = driving, 1 = reversing, 2 = out of control
	int phaseTics;
	int revSide;                 // which way the nose swings while reversing
	int commit;                  // committed turn direction when the target is behind us
	int blockedRecently;         // counts quick repeat collisions so it backs up longer
	int sinceBlock;

	Default
	{
		Tag "Ram Car";
		Health 1000;
		+INVULNERABLE
	}

	States
	{
	Spawn:
		CARK A -1;
		Stop;
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		selfDriven = true;
		riderFront = RamImp(Spawn("RamImp", pos + (RIDER_OFS, 0, RIDER_Z)));
		riderBack = RamImp(Spawn("RamImp", pos + (-RIDER_OFS, 0, RIDER_Z)));
		if (riderFront) riderFront.car = self;
		if (riderBack) riderBack.car = self;
		sinceBlock = 999;
	}

	override void Tick()
	{
		if (health <= 0)
		{
			Super.Tick();
			return;
		}

		if (phase != 2 && !RiderAlive(riderFront) && !RiderAlive(riderBack))
		{
			StartCareenDeath();
		}

		sinceBlock++;
		vector2 before = pos.xy;

		if (phase == 2) DeathStep();
		else DriveStepRam();

		vel = (cos(angle) * spd, sin(angle) * spd, 0);
		Super.Tick();
		if (health <= 0) return;

		double moved = (pos.xy - before).Length();
		cvel = pos.xy - before;
		PositionRiders();

		if (phase == 2)
		{
			phaseTics++;
			if (moved < abs(spd) * BLOCK_RATIO || phaseTics >= DEATH_TICS || HitSomething())
			{
				Explode();
			}
			return;
		}

		// ran into terrain?
		if (abs(spd) > 3.0 && moved < abs(spd) * BLOCK_RATIO)
		{
			OnBlocked();
		}
	}

	bool RiderAlive(RamImp r)
	{
		return r && r.health > 0;
	}

	// nearest living player within WAKE_RANGE
	Actor FindPlayer()
	{
		Actor best = null;
		double bestDist = WAKE_RANGE;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i] || !players[i].mo || players[i].mo.health <= 0) continue;
			double d = Distance2D(players[i].mo);
			if (d < bestDist)
			{
				bestDist = d;
				best = players[i].mo;
			}
		}
		return best;
	}

	static double AngleDiff(double from, double to)
	{
		double d = to - from;
		while (d > 180) d -= 360;
		while (d < -180) d += 360;
		return d;
	}

	// Steering and throttle for one tic.
	void DriveStepRam()
	{
		Actor tgt = FindPlayer();
		double want = 0;
		double turnDir = 0;

		if (phase == 1)
		{
			// backing out: swing the nose around while going backwards
			want = -REV_SPEED;
			turnDir = revSide;
			phaseTics--;
			if (phaseTics <= 0)
			{
				phase = 0;
			}
		}
		else if (tgt)
		{
			double dist = Distance2D(tgt);
			// aim a little ahead of a moving player
			double lead = min(dist / max(abs(spd), 6.0), 14.0) * 0.5;
			vector2 aim = tgt.pos.xy + tgt.vel.xy * lead;
			double dang = AngleDiff(angle, atan2(aim.y - pos.y, aim.x - pos.x));
			double side = (dang >= 0) ? 1 : -1;

			// when the target is behind us, pick a side and stick with it so we
			// sweep one wide arc instead of dithering
			if (abs(dang) > 120)
			{
				if (commit == 0) commit = int(side);
				side = commit;
			}
			else if (abs(dang) < 70)
			{
				commit = 0;
			}
			turnDir = side;

			want = MAX_SPEED;
			if (abs(dang) > 100) want = MAX_SPEED * 0.75;     // lift off a little in the swing
			else if (abs(dang) > 45) want = MAX_SPEED * 0.9;
		}

		// throttle
		if (spd < want) spd = min(spd + ((spd < 0) ? BRAKE_RATE : ACCEL_FWD), want);
		else spd = max(spd - ((spd > 0) ? BRAKE_RATE : ACCEL_FWD), want);

		// steering: more turn at low speed, less at high speed, none when stopped
		double frac = clamp(abs(spd) / MAX_SPEED, 0.0, 1.0);
		double rate = TURN_SLOW + (TURN_FAST - TURN_SLOW) * frac;
		rate *= clamp(abs(spd) / 3.0, 0.0, 1.0);
		angle += turnDir * rate;
	}

	// Hit a wall or step.
	void OnBlocked()
	{
		if (phase == 1)
		{
			// blocked while backing up: give up reversing and go forward again
			phase = 0;
			spd = 2.0;
			sinceBlock = 0;
			return;
		}

		// repeated hits close together: back up longer and swing the other way
		if (sinceBlock < 60) blockedRecently++;
		else blockedRecently = 0;
		sinceBlock = 0;

		phase = 1;
		phaseTics = REV_TICS + min(blockedRecently, 3) * 10;
		spd = -2.0;

		// swing the nose toward the player if we know where it is, else random
		Actor tgt = FindPlayer();
		if (tgt && blockedRecently == 0)
		{
			double dang = AngleDiff(angle, atan2(tgt.pos.y - pos.y, tgt.pos.x - pos.x));
			revSide = (dang >= 0) ? 1 : -1;
		}
		else
		{
			revSide = (random(0, 1) == 0) ? 1 : -1;
		}
	}

	void PositionRiders()
	{
		double fx = cos(angle);
		double fy = sin(angle);
		if (RiderAlive(riderFront))
		{
			riderFront.SetOrigin(pos + (fx * RIDER_OFS, fy * RIDER_OFS, RIDER_Z), true);
		}
		if (RiderAlive(riderBack))
		{
			riderBack.SetOrigin(pos + (-fx * RIDER_OFS, -fy * RIDER_OFS, RIDER_Z), true);
		}
	}

	// Both riders dead: lose control and veer off in a random direction.
	void StartCareenDeath()
	{
		phase = 2;
		phaseTics = 0;
		angle += frandom(-70.0, 70.0);
		spd = max(abs(spd), 9.0);
	}

	void DeathStep()
	{
		// straight line, no steering
	}

	void Explode()
	{
		if (RiderAlive(riderFront)) riderFront.Die(null, null);
		if (RiderAlive(riderBack)) riderBack.Die(null, null);
		bInvulnerable = false;
		Detonate();
	}
}

// ---------------------------------------------------------------------------
// An imp riding on a RamCar. Uses the IWAD's imp sprites and sounds. It is moved by
// its car, turns to face the player and throws imp fireballs.
// ---------------------------------------------------------------------------
class RamImp : Actor
{
	RamCar car;
	int atkCooldown;
	bool firing;

	Default
	{
		Tag "Imp Rider";
		Health 60;
		Radius 18;
		Height 52;
		Mass 100;
		PainChance 160;
		SeeSound "imp/sight";
		PainSound "imp/pain";
		DeathSound "imp/death1";
		ActiveSound "imp/active";
		+SHOOTABLE
		+NOGRAVITY
		+NODAMAGETHRUST
	}

	States
	{
	Spawn:
		TROO A 1 { firing = false; }
		Loop;
	Missile:
		TROO E 8 A_FaceTarget;
		TROO F 8 A_FaceTarget;
		TROO G 6 ThrowBall();
		Goto Spawn;
	Pain:
		TROO H 2;
		TROO H 2 A_Pain;
		Goto Spawn;
	Death:
		TROO I 8 { bNoGravity = false; }
		TROO J 8 A_Scream;
		TROO K 6;
		TROO L 6 A_NoBlocking;
		TROO M -1;
		Stop;
	}

	override void Tick()
	{
		Super.Tick();
		if (health <= 0) return;

		// nearest living player
		Actor best = null;
		double bestDist = 100000;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i] || !players[i].mo || players[i].mo.health <= 0) continue;
			double d = Distance2D(players[i].mo);
			if (d < bestDist)
			{
				bestDist = d;
				best = players[i].mo;
			}
		}
		target = best;
		if (atkCooldown > 0) atkCooldown--;
		if (!target) return;

		if (!firing)
		{
			A_FaceTarget(25);
			if (atkCooldown <= 0 && bestDist < 1600 && bestDist > 96 && CheckSight(target))
			{
				firing = true;
				atkCooldown = random(40, 80);
				SetStateLabel("Missile");
			}
		}
	}

	void ThrowBall()
	{
		if (!target) return;
		A_SpawnProjectile("DoomImpBall", 24);
	}
}
