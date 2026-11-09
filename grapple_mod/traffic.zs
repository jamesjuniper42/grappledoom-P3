// Traffic for the GRAPPLE2 speedway: lane geometry, cars, and the car spawner.
//
// The track is a stadium shape: two straights joined by two semicircles. Cars do
// not use Doom physics to drive; each one follows its lane by distance travelled
// and is placed with SetOrigin every tic. The TRK_* constants must match
// build.py (build.py checks this). 32 map units = 1 meter, 35 tics = 1 second.

class TrackGeom
{
	const TRK_S = 6000.0;     // length of each straight
	const TRK_R = 2400.0;     // radius of the semicircles, measured at the median
	const TRK_PI = 3.14159265358979;
	const TRK_LANE0 = 192.0;  // lane offsets from the median; + is toward the outside
	const TRK_LANE1 = 64.0;
	const TRK_LANE2 = -64.0;
	const TRK_LANE3 = -192.0;
	const LANES = 4;

	// Lanes 0 and 1 run counter-clockwise, lanes 2 and 3 clockwise.
	static double LaneOffset(int lane)
	{
		switch (lane)
		{
		case 0: return TRK_LANE0;
		case 1: return TRK_LANE1;
		case 2: return TRK_LANE2;
		}
		return TRK_LANE3;
	}

	static bool LaneIsCW(int lane)
	{
		return lane >= 2;
	}

	static double LaneRadius(int lane)
	{
		return TRK_R + LaneOffset(lane);
	}

	static double LaneLength(int lane)
	{
		return 2 * TRK_S + 2 * TRK_PI * LaneRadius(lane);
	}

	// Position and heading on the counter-clockwise path of radius r, s units from
	// (-S/2, -r), which is the start of the bottom straight (heading east).
	static void PoseCCW(double s, double r, out double x, out double y, out double hdg)
	{
		double arc = TRK_PI * r;
		double total = 2 * TRK_S + 2 * arc;
		while (s >= total) s -= total;
		while (s < 0) s += total;

		if (s < TRK_S)
		{
			x = -TRK_S * 0.5 + s;
			y = -r;
			hdg = 0;
		}
		else if (s < TRK_S + arc)
		{
			double a1 = -90.0 + (s - TRK_S) / r * (180.0 / TRK_PI);
			x = TRK_S * 0.5 + r * cos(a1);
			y = r * sin(a1);
			hdg = a1 + 90.0;
		}
		else if (s < 2 * TRK_S + arc)
		{
			double t = s - TRK_S - arc;
			x = TRK_S * 0.5 - t;
			y = r;
			hdg = 180.0;
		}
		else
		{
			double a2 = 90.0 + (s - 2 * TRK_S - arc) / r * (180.0 / TRK_PI);
			x = -TRK_S * 0.5 + r * cos(a2);
			y = r * sin(a2);
			hdg = a2 + 90.0;
		}
	}

	// Position and heading in a lane, d units along its direction of travel.
	static void LanePose(int lane, double d, out double x, out double y, out double hdg)
	{
		double r = LaneRadius(lane);
		if (LaneIsCW(lane))
		{
			PoseCCW(LaneLength(lane) - d, r, x, y, hdg);
			hdg += 180.0;
		}
		else
		{
			PoseCCW(d, r, x, y, hdg);
		}
	}
}

// ---------------------------------------------------------------------------
// A car in traffic. Shootable but not solid (the player passes through it; the
// player script detects impacts). It ignores the player completely.
//
//  - drives its lane, slowing to stay behind the car ahead
//  - damaged to CAREEN_HEALTH or below: loses control, veers off at an angle and
//    explodes when it hits anything
//  - killed: explodes, hurting everything around it (including other cars)
// ---------------------------------------------------------------------------
class TrafficCar : Actor
{
	const CAREEN_HEALTH = 30;   // at or below this health the car loses control
	const CAREEN_TICS = 70;     // longest a car stays out of control before it blows up
	const ACCEL = 0.25;
	const BRAKE = 0.6;
	const SAFE_GAP = 260.0;     // start slowing when the car ahead is closer than this
	const MIN_GAP = 170.0;      // never closer than this (a car is about 144 long)
	const BLAST_DAMAGE = 70;
	const BLAST_RADIUS = 192;
	const BLAST_FULL = 48;      // full damage inside this distance

	TrafficSpawner mgr;
	int lane;
	double dist;                // distance travelled along the lane, in its direction
	double curSpeed;            // units per tic
	double cruise;              // preferred speed
	vector2 cvel;               // world velocity this tic, used for impacts
	bool careening;
	bool selfDriven;            // true for subclasses that drive themselves (RamCar)
	int careenTics;
	double gapAhead;

	Default
	{
		Health 120;
		Radius 48;
		Height 40;
		Scale 0.5;
		Mass 600;
		DeathSound "world/barrelx";
		+SHOOTABLE
		+NOBLOOD
		+NOGRAVITY
		+NODAMAGETHRUST
	}

	States
	{
	Spawn:
		CARR A -1;
		Stop;
	Death:
		BEXP A 5 Bright
		{
			A_Scream();
			A_Explode(BLAST_DAMAGE, BLAST_RADIUS, XF_HURTSOURCE, false, BLAST_FULL);
		}
		BEXP B 5 Bright;
		BEXP C 5 Bright;
		BEXP D 10 Bright;
		BEXP E 10 Bright;
		Stop;
	}

	override void Tick()
	{
		if (health <= 0)
		{
			Super.Tick();
			return;
		}

		if (selfDriven)
		{
			Super.Tick();
			return;
		}

		if (careening)
		{
			double sp = cvel.Length();
			Vel = (cvel.x, cvel.y, 0);
			vector2 before = pos.xy;
			Super.Tick();
			if (health <= 0) return;

			careenTics++;
			double moved = (pos.xy - before).Length();
			if (moved < sp * 0.5 || careenTics >= CAREEN_TICS || HitSomething())
			{
				Detonate();
			}
			return;
		}

		DriveStep();
		Super.Tick();
	}

	// One tic of following the lane.
	void DriveStep()
	{
		double want = cruise;
		TrafficCar ahead = FindAhead();
		if (ahead && gapAhead < SAFE_GAP)
		{
			double room = max(0.0, (gapAhead - MIN_GAP) / (SAFE_GAP - MIN_GAP));
			want = min(want, ahead.curSpeed * room);
		}
		if (curSpeed < want) curSpeed = min(curSpeed + ACCEL, want);
		else curSpeed = max(curSpeed - BRAKE, want);

		dist += curSpeed;
		double total = TrackGeom.LaneLength(lane);
		if (dist >= total) dist -= total;

		double nx = 0;
		double ny = 0;
		double nh = 0;
		TrackGeom.LanePose(lane, dist, nx, ny, nh);
		cvel = (nx - pos.x, ny - pos.y);
		if (cvel.Length() > 100) cvel = (0, 0);   // first tic or a wrap: ignore the jump
		angle = nh;
		Vel = (0, 0, 0);
		SetOrigin((nx, ny, pos.z), true);
	}

	// Nearest healthy car ahead of us in our lane. Sets gapAhead.
	TrafficCar FindAhead()
	{
		gapAhead = 100000;
		if (!mgr) return null;
		double total = TrackGeom.LaneLength(lane);
		TrafficCar best = null;
		for (int i = 0; i < mgr.cars.Size(); i++)
		{
			TrafficCar c = mgr.cars[i];
			if (!c || c == self || c.lane != lane || c.health <= 0 || c.careening) continue;
			double g = c.dist - dist;
			if (g < 0) g += total;
			if (g < gapAhead)
			{
				gapAhead = g;
				best = c;
			}
		}
		return best;
	}

	override int DamageMobj(Actor inflictor, Actor source, int dmg, Name mod, int flags, double ang)
	{
		int ret = Super.DamageMobj(inflictor, source, dmg, mod, flags, ang);
		if (health > 0 && !careening && health <= CAREEN_HEALTH)
		{
			StartCareen();
		}
		return ret;
	}

	// Lose control: veer off the lane at an angle and keep going until we hit something.
	void StartCareen()
	{
		careening = true;
		careenTics = 0;
		double turn = frandom(25.0, 55.0);
		if (random(0, 1) == 0) turn = -turn;
		double a = angle + turn;
		double sp = max(curSpeed, 8.0);
		cvel = (cos(a) * sp, sin(a) * sp);
		angle = a;
	}

	// Did a careening car run into another car or a player?
	bool HitSomething()
	{
		if (mgr)
		{
			for (int i = 0; i < mgr.cars.Size(); i++)
			{
				TrafficCar c = mgr.cars[i];
				if (!c || c == self || c.health <= 0) continue;
				if ((c.pos.xy - pos.xy).Length() < 80) return true;
			}
		}
		for (int p = 0; p < MAXPLAYERS; p++)
		{
			if (!playeringame[p] || !players[p].mo) continue;
			Actor pm = players[p].mo;
			if (abs(pm.pos.z - pos.z) < Height && (pm.pos.xy - pos.xy).Length() < 56) return true;
		}
		return false;
	}

	void Detonate()
	{
		Die(null, null);
	}
}

class TrafficCarRed : TrafficCar
{
	States
	{
	Spawn:
		CARR A -1;
		Stop;
	}
}

class TrafficCarBlue : TrafficCar
{
	States
	{
	Spawn:
		CARB A -1;
		Stop;
	}
}

class TrafficCarYellow : TrafficCar
{
	States
	{
	Spawn:
		CARY A -1;
		Stop;
	}
}

class TrafficCarGreen : TrafficCar
{
	States
	{
	Spawn:
		CARG A -1;
		Stop;
	}
}

// ---------------------------------------------------------------------------
// Placed once in the map (editor number 30001; arg0 = cars per lane). Spawns the
// traffic when the level starts, then tops it back up as cars blow up.
// ---------------------------------------------------------------------------
class TrafficSpawner : Actor
{
	Array<TrafficCar> cars;
	int perLane;
	int timer;

	Default
	{
		+NOINTERACTION
	}

	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}

	override void PostBeginPlay()
	{
		Super.PostBeginPlay();
		perLane = (args[0] > 0) ? args[0] : 12;
		for (int l = 0; l < TrackGeom.LANES; l++)
		{
			double total = TrackGeom.LaneLength(l);
			double spacing = total / perLane;
			for (int i = 0; i < perLane; i++)
			{
				double d = spacing * i + frandom(0, spacing * 0.4);
				double x = 0;
				double y = 0;
				double h = 0;
				TrackGeom.LanePose(l, d, x, y, h);
				// keep the area around the player start clear
				if (abs(x) < 700 && abs(y + TrackGeom.TRK_R) < 400) continue;
				SpawnCar(l, d);
			}
		}
	}

	override void Tick()
	{
		Super.Tick();
		timer++;
		if ((timer % 70) != 0) return;

		for (int i = cars.Size() - 1; i >= 0; i--)
		{
			if (!cars[i] || cars[i].health <= 0) cars.Delete(i);
		}
		for (int l = 0; l < TrackGeom.LANES; l++)
		{
			int n = 0;
			for (int j = 0; j < cars.Size(); j++)
			{
				if (cars[j].lane == l) n++;
			}
			if (n < perLane - 2) TrySpawn(l);
		}
	}

	TrafficCar SpawnCar(int l, double d)
	{
		double x = 0;
		double y = 0;
		double h = 0;
		TrackGeom.LanePose(l, d, x, y, h);

		class<Actor> cls = "TrafficCarRed";
		switch (random(0, 3))
		{
		case 1: cls = "TrafficCarBlue"; break;
		case 2: cls = "TrafficCarYellow"; break;
		case 3: cls = "TrafficCarGreen"; break;
		}

		TrafficCar c = TrafficCar(Spawn(cls, (x, y, 0)));
		if (!c) return null;
		c.mgr = self;
		c.lane = l;
		c.dist = d;
		c.cruise = frandom(9.0, 14.0);
		c.curSpeed = c.cruise;
		c.angle = h;
		cars.Push(c);
		return c;
	}

	// Add a car at a random spot in lane l that is out of sight of the players
	// and not on top of another car.
	void TrySpawn(int l)
	{
		double total = TrackGeom.LaneLength(l);
		for (int attempt = 0; attempt < 6; attempt++)
		{
			double d = frandom(0, total);
			if (SpotIsClear(l, d, total))
			{
				SpawnCar(l, d);
				return;
			}
		}
	}

	bool SpotIsClear(int l, double d, double total)
	{
		for (int i = 0; i < cars.Size(); i++)
		{
			TrafficCar c = cars[i];
			if (!c || c.lane != l) continue;
			double g = abs(c.dist - d);
			g = min(g, total - g);
			if (g < 500) return false;
		}
		double x = 0;
		double y = 0;
		double h = 0;
		TrackGeom.LanePose(l, d, x, y, h);
		for (int p = 0; p < MAXPLAYERS; p++)
		{
			if (!playeringame[p] || !players[p].mo) continue;
			if ((players[p].mo.pos.xy - (x, y)).Length() < 2000) return false;
		}
		return true;
	}
}
