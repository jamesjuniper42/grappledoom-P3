// The Leaper: a Mancubus that jumps at you from far away.
//
//  - Built on the stock Mancubus (Fatso), so it uses the loaded IWAD's mancubus
//    sprites and sounds (Freedoom's under Freedoom).
//  - When the target is more than 30 m away and in sight, it leaps: 5 m high at
//    the peak and 10 m forward along the ground, toward where the target is at
//    takeoff. Then a cooldown applies.
//  - It cannot shoot mid-jump: the Leap state never runs A_Chase (the only place
//    attacks start), and pain flinches are switched off until it lands.
//
// Units: 32 map units = 1 meter, 35 tics = 1 second.

class LeapMancubus : Fatso
{
	const LEAP_HEIGHT = 160.0;    // 5 m peak height
	const LEAP_DIST = 320.0;      // 10 m forward travel
	const LEAP_RANGE = 960.0;     // 30 m: only leap from farther than this
	const LEAP_COOLDOWN = 70;     // tics after landing before it can leap again
	const LEAP_MAX_TICS = 90;     // safety: give up waiting for a landing

	int leapTics;
	int leapCooldown;
	bool leaping;

	Default
	{
		Tag "Leaper";
	}

	States
	{
	See:
		FATT A 4 { return ChaseOrLeap(); }
		FATT A 4 { return ChaseOrLeap(); }
		FATT B 4 { return ChaseOrLeap(); }
		FATT B 4 { return ChaseOrLeap(); }
		FATT C 4 { return ChaseOrLeap(); }
		FATT C 4 { return ChaseOrLeap(); }
		FATT D 4 { return ChaseOrLeap(); }
		FATT D 4 { return ChaseOrLeap(); }
		FATT E 4 { return ChaseOrLeap(); }
		FATT E 4 { return ChaseOrLeap(); }
		FATT F 4 { return ChaseOrLeap(); }
		FATT F 4 { return ChaseOrLeap(); }
		Loop;
	Leap:
		FATT G 1 { return LeapTick(); }
		Loop;
	}

	// Normal chasing, unless a leap is due.
	State ChaseOrLeap()
	{
		if (leapCooldown > 0) leapCooldown--;
		if (leapCooldown <= 0 && target && pos.z <= floorz + 1
			&& Distance3D(target) > LEAP_RANGE && CheckSight(target))
		{
			BeginLeap();
			return ResolveState("Leap");
		}
		A_Chase();
		return null;
	}

	// Pick launch velocities so the peak is LEAP_HEIGHT and the flat distance is
	// LEAP_DIST on level ground, using this actor's real gravity per tic.
	void BeginLeap()
	{
		A_FaceTarget();
		double g = GetGravity();
		double vz = sqrt(2.0 * g * LEAP_HEIGHT);
		double airTime = 2.0 * vz / g;
		double hs = LEAP_DIST / airTime;
		Vel = (cos(angle) * hs, sin(angle) * hs, vz);
		bNoPain = true;     // no flinching (and no state change) mid-jump
		leaping = true;
		leapTics = 0;
	}

	// Runs every tic while airborne. No attacks start from here.
	State LeapTick()
	{
		leapTics++;
		bool landed = leapTics > 3 && vel.z <= 0 && pos.z <= floorz + 1;
		if (landed || leapTics > LEAP_MAX_TICS)
		{
			bNoPain = false;
			leaping = false;
			leapCooldown = LEAP_COOLDOWN;
			Vel = (0, 0, Vel.z);
			return ResolveState("See");
		}
		return null;
	}
}
