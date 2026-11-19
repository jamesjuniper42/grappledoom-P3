// ---------------------------------------------------------------------------
// The Worm: a Terraria-style boss for GRAPPLE6.
//
//  - WormHead hunts the nearest living player nonstop. It moves at the player's top
//    speed but turns slowly, so a miss means a wide, smooth loop back around. Terrain
//    is ignored: it is placed with SetOrigin every tic and passes through walls,
//    floors, ceilings and plateaus.
//  - When the player is inside its turning circle it slows down while turning hard
//    (a smaller circle at lower speed) so it spirals in instead of orbiting forever.
//  - 20 WormSegments follow the head's path (placed by arc length along the head's
//    recent positions). Only the head hurts on contact. Every segment fires imp
//    fireballs at the nearest player now and then.
//  - All parts share one health pool (damage to a segment is forwarded to the head).
//    When the head's health runs out the parts blow up one after another from the
//    head to the tail, and the exit door (sector tag 10) opens.
//
// Actor positions are the BOTTOM of the actor; the worm's path is stored as the
// CENTER of each part (position + half the height).
// ---------------------------------------------------------------------------
// A thin spike on top of each segment. No collision; it is only a visual and the spot the
// segment's fireballs come out of, so they start clear of the worm's own body.
class WormSpike : Actor
{
	Default
	{
		Radius 1;
		Height 1;
		+NOGRAVITY
		+NOINTERACTION
	}
	States
	{
	Spawn:
		WRMS A -1;
		Stop;
	}
}

// Fireball from a segment: the Imp fireball, but it flies through (and never hurts) the worm.
class WormBall : DoomImpBall
{
	Default
	{
		Species "WormPart";
		+THRUSPECIES
		+DONTHARMSPECIES
	}
}

class WormSegment : Actor
{
	const FIRE_MIN = 350;       // tics between imp fireballs from one segment (10-20 s)
	const FIRE_MAX = 700;

	const SPIKE_LEN = 40.0;     // sprite height at scale 1
	const SPIKE_SINK = 6.0;     // how far the spike base sits inside the body

	WormHead head;
	WormSpike spike;
	double sc;
	int fireTimer;

	Default
	{
		Health 1000;            // not used as health: damage is forwarded to the head
		Radius 34;
		Height 68;
		Mass 100000;
		Species "WormPart";
		DeathSound "world/barrelx";
		+SHOOTABLE
		+NOGRAVITY
		+NOBLOOD
		+NODAMAGETHRUST
		+NOPAIN
	}

	States
	{
	Spawn:
		WRMB A -1;
		Stop;
	Death:
		BEXP A 4 Bright
		{
			A_Scream();
			A_Explode(15, 128, 0, false, 32);
		}
		BEXP B 4 Bright;
		BEXP C 4 Bright;
		BEXP D 6 Bright;
		BEXP E 6 Bright;
		Stop;
	}

	vector3 Center()
	{
		return pos + (0, 0, Height * 0.5);
	}

	// z of the spike's base, and the tip position
	double SpikeBaseZ()
	{
		return pos.z + Height - SPIKE_SINK * sc;
	}

	vector3 SpikeTip()
	{
		return (pos.x, pos.y, SpikeBaseZ() + SPIKE_LEN * sc);
	}

	void PlaceSpike()
	{
		if (!spike)
		{
			spike = WormSpike(Spawn("WormSpike", (pos.x, pos.y, SpikeBaseZ())));
			if (!spike) return;
			spike.Scale = (sc, sc);
		}
		spike.SetOrigin((pos.x, pos.y, SpikeBaseZ()), true);
	}

	void RemoveSpike()
	{
		if (spike)
		{
			spike.Destroy();
			spike = null;
		}
	}

	override void OnDestroy()
	{
		RemoveSpike();
		Super.OnDestroy();
	}

	override int DamageMobj(Actor inflictor, Actor source, int dmg, Name mod, int flags, double ang)
	{
		if (health <= 0 || !head || head.health <= 0) return 0;
		return head.DamageMobj(inflictor, source, dmg, mod, flags, ang);
	}

	override void Tick()
	{
		// Alive segments are moved only by the head, and never run the engine's own
		// movement (it would snap a part that is below the floor back up).
		if (health <= 0)
		{
			RemoveSpike();
			Super.Tick();
			return;
		}
		if (!head || head.health <= 0 || !head.awake) return;

		fireTimer--;
		if (fireTimer <= 0)
		{
			fireTimer = random(FIRE_MIN, FIRE_MAX);
			FireAtPlayer();
		}
	}

	void FireAtPlayer()
	{
		Actor tgt = head.NearestPlayer(Center());
		if (!tgt) return;
		vector3 from = SpikeTip();       // fireballs leave from the spike tip, clear of the body
		vector3 d = (tgt.pos + (0, 0, tgt.Height * 0.6)) - from;
		double len = d.Length();
		if (len < 1.0) return;
		d = d * (1.0 / len);
		Actor b = Spawn("WormBall", from);
		if (!b) return;
		b.target = self;                 // WormBall passes through all worm parts
		b.Vel = d * b.Speed;
		b.angle = atan2(d.y, d.x);
		A_StartSound("imp/attack", CHAN_AUTO);
	}
}

class WormHead : Actor
{
	const SEG_COUNT = 20;
	const SEG_SPACING = 56.0;       // distance between segment centers along the path
	const WORM_SPEED = 30.2;        // the player's top speed (2x Doomguy's run speed)
	const MIN_SPEED_FRAC = 0.45;    // speed kept while turning as hard as it can
	const SPEED_ACCEL = 1.0;        // speed change per tic
	const TURN_RATE = 2.0;          // degrees of turn per tic: a 27 m circle at full speed
	const PITCH_RATE = 1.5;         // degrees per tic up or down
	const MAX_PITCH = 70.0;
	const WAKE_TICS = 175;          // it lies still this long after the level starts
	const CONTACT_DAMAGE = 25;
	const CONTACT_COOLDOWN = 20;    // tics before it can hurt the same player again
	const BASE_HEALTH = 2400;       // for one player; +50% for each extra player
	const EXIT_TAG = 10;            // door sector opened when the worm dies

	Array<WormSegment> segs;
	Array<double> hist;             // recent head centers, oldest first, stored as x,y,z triples
	double yaw;
	double tilt;
	double spd;
	bool awake;
	bool dying;
	int wakeTics;
	int deathTics;
	int killed;
	int cool[MAXPLAYERS];

	Default
	{
		Health 1;                   // set in PostBeginPlay from the player count
		Radius 44;
		Height 88;
		Mass 1000000;
		Species "WormPart";
		DeathSound "world/barrelx";
		+SHOOTABLE
		+NOGRAVITY
		+NOBLOOD
		+NODAMAGETHRUST
		+NOPAIN
	}

	States
	{
	Spawn:
		WRMH A -1;
		Stop;
	Death:
		BEXP A 4 Bright
		{
			A_Scream();
			A_Explode(40, 256, 0, false, 64);
		}
		BEXP B 4 Bright;
		BEXP C 4 Bright;
		BEXP D 6 Bright;
		BEXP E 6 Bright;
		Stop;
	}

	vector3 Center()
	{
		return pos + (0, 0, Height * 0.5);
	}

	void PushHist(vector3 v)
	{
		hist.Push(v.x);
		hist.Push(v.y);
		hist.Push(v.z);
	}

	int HistCount()
	{
		return hist.Size() / 3;
	}

	vector3 HistAt(int i)
	{
		return (hist[i * 3], hist[i * 3 + 1], hist[i * 3 + 2]);
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();

		int n = 0;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (playeringame[i]) n++;
		}
		health = int(BASE_HEALTH * (1.0 + 0.5 * max(0, n - 1)));

		yaw = angle;
		tilt = 0;

		// pre-fill the path with a straight line behind the head so the body starts stretched out
		vector3 c = Center();
		vector3 back = (cos(yaw), sin(yaw), 0);
		for (int k = 90; k >= 1; k--)
		{
			PushHist(c - back * (k * 20.0));
		}
		PushHist(c);

		for (int j = 0; j < SEG_COUNT; j++)
		{
			WormSegment s = WormSegment(Spawn("WormSegment", pos));
			if (!s) continue;
			s.head = self;
			s.fireTimer = random(WormSegment.FIRE_MIN, WormSegment.FIRE_MAX);
			double sc = 1.0 - 0.02 * j;            // the tail tapers a little
			s.Scale = (sc, sc);
			s.sc = sc;
			s.A_SetSize(34.0 * sc, 68.0 * sc);
			segs.Push(s);
		}
		PlaceSegments();
	}

	Actor NearestPlayer(vector3 from)
	{
		Actor best = null;
		double bestDist = 1e9;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i] || !players[i].mo || players[i].mo.health <= 0) continue;
			double d = (players[i].mo.pos - from).Length();
			if (d < bestDist)
			{
				bestDist = d;
				best = players[i].mo;
			}
		}
		return best;
	}

	void Announce(String msg)
	{
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (playeringame[i] && players[i].mo) players[i].mo.A_PrintBold(msg, 4.0);
		}
	}

	override void Tick()
	{
		if (health <= 0)
		{
			DeathTick();
			Super.Tick();
			return;
		}

		if (!awake)
		{
			wakeTics++;
			if (wakeTics >= WAKE_TICS)
			{
				awake = true;
				Announce("THE WORM AWAKENS");
			}
			return;
		}

		Actor tgt = NearestPlayer(Center());
		if (tgt) Steer(tgt);
		Advance();
		PlaceSegments();
		ContactDamage();
	}

	// Turn toward the target, slowly. Speed drops as the heading error grows so a
	// target inside the turning circle gets spiraled in on.
	void Steer(Actor tgt)
	{
		vector3 toTgt = (tgt.pos + (0, 0, tgt.Height * 0.5)) - Center();
		double hd = toTgt.xy.Length();

		double wantYaw = atan2(toTgt.y, toTgt.x);
		double err = deltaangle(yaw, wantYaw);
		yaw += clamp(err, -TURN_RATE, TURN_RATE);

		double wantTilt = clamp(atan2(toTgt.z, max(hd, 1.0)), -MAX_PITCH, MAX_PITCH);
		tilt += clamp(wantTilt - tilt, -PITCH_RATE, PITCH_RATE);

		double frac = 1.0 - (1.0 - MIN_SPEED_FRAC) * clamp((abs(err) - 25.0) / 85.0, 0.0, 1.0);
		double goal = WORM_SPEED * frac;
		if (spd < goal) spd = min(spd + SPEED_ACCEL, goal);
		else spd = max(spd - 2.0 * SPEED_ACCEL, goal);
	}

	void Advance()
	{
		vector3 dir = (cos(yaw) * cos(tilt), sin(yaw) * cos(tilt), sin(tilt));
		vector3 c = Center() + dir * spd;
		PushHist(c);
		if (HistCount() > 320) hist.Delete(0, 240);
		Vel = (0, 0, 0);
		SetOrigin(c - (0, 0, Height * 0.5), true);
		angle = yaw;
	}

	// Put every segment on the head's recent path, SEG_SPACING apart by arc length.
	void PlaceSegments()
	{
		int n = HistCount();
		if (n < 2) return;
		double need = SEG_SPACING;
		double acc = 0;
		int idx = 0;
		vector3 prev = HistAt(n - 1);
		for (int i = n - 2; i >= 0 && idx < segs.Size(); i--)
		{
			vector3 cur = HistAt(i);
			vector3 stp = cur - prev;
			double sl = stp.Length();
			while (idx < segs.Size() && acc + sl >= need)
			{
				double f = (need - acc) / max(sl, 0.001);
				SetSeg(idx, prev + stp * f);
				idx++;
				need += SEG_SPACING;
			}
			acc += sl;
			prev = cur;
		}
		while (idx < segs.Size())
		{
			SetSeg(idx, HistAt(0));
			idx++;
		}
	}

	void SetSeg(int idx, vector3 center)
	{
		WormSegment s = segs[idx];
		if (!s || s.health <= 0) return;
		s.SetOrigin(center - (0, 0, s.Height * 0.5), true);
		s.PlaceSpike();
	}

	// Only the head hurts on contact.
	void ContactDamage()
	{
		for (int p = 0; p < MAXPLAYERS; p++)
		{
			if (cool[p] > 0) cool[p]--;
			if (cool[p] > 0) continue;
			if (!playeringame[p] || !players[p].mo || players[p].mo.health <= 0) continue;
			Actor pm = players[p].mo;
			vector3 d = (pm.pos + (0, 0, pm.Height * 0.5)) - Center();
			if (d.Length() >= Radius + pm.Radius + 8.0) continue;

			pm.DamageMobj(self, self, CONTACT_DAMAGE, 'Melee');
			cool[p] = CONTACT_COOLDOWN;
			GrapplePlayer gp = GrapplePlayer(pm);
			if (gp)
			{
				vector2 away = pm.pos.xy - pos.xy;
				if (away.Length() > 0.01) gp.Knock(away.Unit() * 18.0, 6.0);
			}
		}
	}

	// Blow the parts up one after another from the head to the tail.
	void DeathTick()
	{
		if (!dying)
		{
			dying = true;
			Announce("THE WORM IS DEAD! The exit door is open.");
			level.ExecuteSpecial(11, null, null, false, EXIT_TAG, 16);   // Door_Open
		}
		deathTics++;
		int upTo = deathTics / 3;
		while (killed <= upTo && killed < segs.Size())
		{
			WormSegment s = segs[killed];
			if (s && s.health > 0) s.Die(null, null);
			killed++;
		}
	}
}
