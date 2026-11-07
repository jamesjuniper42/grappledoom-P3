version "4.0"

#include "traffic.zs"
#include "cluster.zs"
#include "leap.zs"

// ---------------------------------------------------------------------------
// Small glowing dot used to draw the rope. Lives 2 tics; the player spawns a
// fresh chain of them every tic while a hook is in flight or pulling.
// ---------------------------------------------------------------------------
class RopeBead : Actor
{
	Default
	{
		Radius 1;
		Height 1;
		+NOINTERACTION
		+NOGRAVITY
	}
	States
	{
	Spawn:
		ROPE A 2 Bright;
		Stop;
	}
}

// ---------------------------------------------------------------------------
// Player that can only move with a grappling hook (right mouse = +altattack).
// Units: 32 map units = 1 meter, 35 tics = 1 second.
// ---------------------------------------------------------------------------
class GrapplePlayer : DoomPlayer
{
	// ---------------- tuning ----------------
	const NEAR_RANGE  = 160.0;   // 5 m: hits closer than this attach instantly
	const HOOK_SPEED  = 128.0;   // units/tic the hook flies at toward a far hit point
	const MIN_FLIGHT  = 4;       // fewest tics a far hook takes to connect
	const MAX_RANGE   = 2560.0;  // hook range (80 m)
	const MAX_SPEED   = 30.2;    // 2x Doomguy's run speed (~15.1 units/tic)
	const PULL_MIN    = 10.0;    // pull starts at least this fast (units/tic)
	const PULL_ACCEL  = 4.0;     // pull speeds up by this much per tic
	const ARRIVE_DIST = 24.0;    // pull ends this close to its target
	const MAX_PULL    = 105;     // safety timeout for a pull (tics)
	const SLIDE_GROUND_KEEP = 0.985; // speed kept per tic while sliding on floor
	const SLIDE_AIR_KEEP    = 0.999; // speed kept per tic in the air
	const SLIDE_STOP  = 1.0;     // slide ends below this speed on the ground

	const GS_IDLE  = 0;
	const GS_PULL  = 1;
	const GS_SLIDE = 2;

	// ledge assist
	const LEDGE_REACH    = 96.0;  // ledge tops up to 3 m above the hit point get assisted
	const LEDGE_INSET    = 40.0;  // land this far back from the lip (player radius is 16)
	const LEDGE_STANDOFF = 20.0;  // lift straight up this far in front of the face
	// traffic cars (see traffic.zs)
	const CAR_HALF_LEN = 64.0;      // impact box of a car, half length and half width
	const CAR_HALF_WID = 32.0;
	const CAR_LAUNCH = 14.0;        // upward speed from a head-on hit
	const CAR_HIT_DMG_MAX = 35.0;   // most damage a head-on hit does
	const CAR_COOLDOWN = 12;        // tics before the next car impact can register

	const LIFT_ARRIVE    = 6.0;   // lift leg must finish close so we clear the lip

	int mstate;          // movement state
	int prevButtons;

	// hook in flight
	bool pending;
	int pendTics, pendTotal;

	// last hook result
	vector3 hookPos;
	vector3 pullTarget;  // where our feet are headed
	bool hookIsUse;
	Line hookLine;
	int hookSide;
	Actor hookTarget;      // enemy we hooked, if any (tracked while pulling)
	vector3 pullTarget2;   // second leg of a ledge climb
	bool hasSecond;
	double arriveDist;
	int carCooldown;
	vector2 fireDir;       // horizontal direction to the target when the hook was fired

	// pulling / sliding
	double pullSpeed;
	int pullTics, stuckTics;
	vector2 slideVel;
	vector2 lastDisp;

	Default
	{
		Player.DisplayName "Grapple Marine";
		Player.JumpZ 0;
		// Kill walking: WASD / arrows / strafe all produce zero thrust.
		Player.ForwardMove 0, 0;
		Player.SideMove 0, 0;
		Speed 0;
	}

	override void Tick()
	{
		if (!player || player.mo != self || player.playerstate != PST_LIVE)
		{
			StopGrapple();
			Super.Tick();
			return;
		}

		// right mouse press (edge triggered)
		int btn = player.cmd.buttons;
		if ((btn & BT_ALTATTACK) && !(prevButtons & BT_ALTATTACK))
		{
			FireHook();
		}
		prevButtons = btn;
		CheckCarHits();

		// hook in flight
		if (pending)
		{
			pendTics++;
			if (hookTarget) UpdateActorTarget();
			vector3 hand = HandPos();
			DrawRope(hand + (hookPos - hand) * (double(pendTics) / pendTotal));
			if (pendTics >= pendTotal)
			{
				pending = false;
				HookArrived();
			}
		}

		vector3 before = pos;
		double expected = 0;

		if (mstate == GS_PULL)
		{
			if (hookTarget && hookTarget.health > 0) UpdateActorTarget();
			vector3 d = pullTarget - pos;
			double dist = d.Length();
			if (dist < arriveDist && hasSecond)
			{
				// lift leg done: now slide over the lip onto the ledge
				pullTarget = pullTarget2;
				hasSecond = false;
				arriveDist = ARRIVE_DIST;
				pullTics = 0;
				stuckTics = 0;
				d = pullTarget - pos;
				dist = d.Length();
			}
			if (dist < arriveDist || pullTics >= MAX_PULL || stuckTics >= 3)
			{
				EndPull();
			}
			else
			{
				pullSpeed = min(pullSpeed + PULL_ACCEL, MAX_SPEED);
				expected = min(pullSpeed, dist);
				Vel = d * (expected / dist);
				pullTics++;
				DrawRope(hookPos);
			}
		}

		if (mstate == GS_SLIDE)
		{
			// We own horizontal velocity while sliding, so the engine's floor
			// friction never matters: we set it, the engine moves us (with wall
			// sliding), then we measure how far we really went.
			Vel.XY = slideVel;
		}

		Super.Tick();

		vector2 disp = pos.xy - before.xy;

		if (mstate == GS_PULL && expected > 0)
		{
			double moved = (pos - before).Length();
			if (moved < expected * 0.3) stuckTics++;
			else stuckTics = 0;
			lastDisp = disp;
		}
		else if (mstate == GS_SLIDE)
		{
			bool ground = (pos.z - floorz) < 1.0;
			slideVel = disp * (ground ? SLIDE_GROUND_KEEP : SLIDE_AIR_KEEP);
			ClampSlide();
			if (ground && slideVel.Length() < SLIDE_STOP)
			{
				mstate = GS_IDLE;
				slideVel = (0, 0);
			}
		}
	}

	// ---------------- traffic collisions ----------------

	// Did we run into a car, or did one run into us? Cars are not solid, so we
	// test our position against each car's impact box (its length is along its angle).
	void CheckCarHits()
	{
		if (carCooldown > 0)
		{
			carCooldown--;
			return;
		}
		ThinkerIterator it = ThinkerIterator.Create("TrafficCar");
		TrafficCar c;
		while (c = TrafficCar(it.Next()))
		{
			if (c.health <= 0) continue;
			if (pos.z > c.pos.z + c.Height || pos.z + Height < c.pos.z) continue;
			vector2 w = pos.xy - c.pos.xy;
			double fx = cos(c.angle);
			double fy = sin(c.angle);
			double lx = w.x * fx + w.y * fy;       // along the car: positive is ahead of it
			double ly = -w.x * fy + w.y * fx;      // across the car
			if (abs(lx) > CAR_HALF_LEN + Radius || abs(ly) > CAR_HALF_WID + Radius) continue;
			CarHit(c, lx);
			carCooldown = CAR_COOLDOWN;
			return;
		}
	}

	// lx > 0 means we are at the car's front: a head-on hit launches us and hurts.
	// Otherwise (rear-end or side) we simply take on the car's speed, which kills
	// our momentum.
	void CarHit(TrafficCar c, double lx)
	{
		vector2 pv = (0, 0);
		if (mstate == GS_PULL) pv = lastDisp;
		else if (mstate == GS_SLIDE) pv = slideVel;

		vector2 toCar = c.pos.xy - pos.xy;
		double tl = toCar.Length();
		if (tl < 0.01) return;
		toCar = toCar * (1.0 / tl);
		vector2 rel = pv - c.cvel;
		double closing = rel.x * toCar.x + rel.y * toCar.y;
		if (closing < 2.0) return;                 // already moving apart

		if (mstate == GS_PULL) EndPull();

		if (lx > 0)
		{
			double dmg = min(CAR_HIT_DMG_MAX, 6.0 + closing * 1.2);
			slideVel = pv * 0.4 + c.cvel * 0.8;
			ClampSlide();
			mstate = GS_SLIDE;
			Vel.Z = CAR_LAUNCH;
			DamageMobj(c, c, int(dmg), 'Melee');
		}
		else
		{
			slideVel = c.cvel;
			ClampSlide();
			mstate = (slideVel.Length() > SLIDE_STOP) ? GS_SLIDE : GS_IDLE;
		}
	}

	// ---------------- hook ----------------

	void FireHook()
	{
		if (pending) return;

		FLineTraceData t;
		LineTrace(angle, MAX_RANGE, pitch, TRF_NOSKY, player.viewheight, 0, 0, t);

		// Nothing hit: do nothing. Enemies and other shootable actors are valid anchors.
		if (t.HitType == TRACE_HitNone || t.HitType == TRACE_HasHitSky || t.HitType == TRACE_CrossingPortal) return;
		if (t.HitType == TRACE_HitActor && !t.HitActor) return;

		// Open sky is not terrain.
		if (t.HitType == TRACE_HitCeiling && t.HitSector
			&& t.HitSector.GetTexture(Sector.ceiling) == skyflatnum) return;
		if (t.HitType == TRACE_HitFloor && t.HitSector
			&& t.HitSector.GetTexture(Sector.floor) == skyflatnum) return;

		vector3 eye = (pos.x, pos.y, pos.z + player.viewheight);
		vector3 hit = t.HitLocation;
		vector3 dir = hit - eye;
		double dist = dir.Length();
		if (dist < 1.0) return;
		dir = dir * (1.0 / dist);

		// A new hook releases any pull in progress (keeping momentum), so the old
		// target can't fight the new one while this hook is in flight.
		if (mstate == GS_PULL) EndPull();

		hookPos = hit;
		hookLine = t.HitLine;
		hookSide = t.LineSide;
		hookTarget = null;
		if (t.HitType == TRACE_HitActor) hookTarget = t.HitActor;
		hasSecond = false;
		arriveDist = ARRIVE_DIST;

		// Doors and buttons: lines with a "player use" special.
		hookIsUse = (t.HitType == TRACE_HitWall && t.HitLine
			&& t.HitLine.special != 0 && (t.HitLine.activation & SPAC_Use));

		// Where should our feet end up?
		if (hookTarget)
		{
			UpdateActorTarget();
		}
		else if (t.HitType == TRACE_HitFloor)
		{
			pullTarget = hit;
			// A floor hit well above our feet (the infield behind a wall, say): lift
			// straight up first so we clear the wall instead of ramming its face.
			if (hit.z - pos.z > 24.0)
			{
				Sector here = level.PointInSector(pos.xy);
				double liftTo = hit.z + 4;
				if (here && here.ceilingplane.ZatPoint(pos.xy) - liftTo >= Height)
				{
					pullTarget2 = hit;
					pullTarget = (pos.x, pos.y, liftTo);
					hasSecond = true;
					arriveDist = LIFT_ARRIVE;
				}
			}
		}
		else if (t.HitType == TRACE_HitCeiling)
		{
			pullTarget = (hit.x - dir.x * 20, hit.y - dir.y * 20, hit.z - Height - 2);
		}
		else
		{
			// eyes end up just in front of the hit point
			pullTarget = (hit.x - dir.x * 24, hit.y - dir.y * 24, hit.z - player.viewheight);
		}
		Sector s = level.PointInSector(pullTarget.xy);
		if (s)
		{
			pullTarget.z = max(pullTarget.z, s.floorplane.ZatPoint(pullTarget.xy));
		}

		// Ledge assist: climbing a step or ledge face instead of hanging under its lip.
		if (t.HitType == TRACE_HitWall && !hookIsUse)
		{
			TryLedgeAssist(t.HitLine, t.LineSide, hit);
		}

		// Remember which way the target lies, so HookArrived can tell if we slid past it
		// while a far hook was in flight.
		fireDir = pullTarget.xy - pos.xy;
		double fl = fireDir.Length();
		if (fl > 0.5) fireDir = fireDir * (1.0 / fl);
		else fireDir = (0, 0);

		A_StartSound("weapons/sshotf", CHAN_AUTO);

		pendTics = 0;
		pendTotal = (dist <= NEAR_RANGE) ? 0 : max(MIN_FLIGHT, int(ceil(dist / HOOK_SPEED)));
		if (pendTotal == 0)
		{
			HookArrived();
		}
		else
		{
			pending = true;
		}
	}

	// Aim the pull at an enemy, standing off by both radii so we stop at it
	// instead of shoving into its body. Called every tic while the hook is on it.
	void UpdateActorTarget()
	{
		if (!hookTarget) return;
		vector3 eye = (pos.x, pos.y, pos.z + player.viewheight);
		vector3 c = hookTarget.pos + (0, 0, hookTarget.Height * 0.5);
		vector3 d = c - eye;
		double len = d.Length();
		if (len < 1.0) return;
		d = d * (1.0 / len);
		hookPos = c;

		double stand = hookTarget.Radius + Radius + 8;
		if (len < stand + 4)
		{
			pullTarget = pos;   // already touching: nothing to pull
			return;
		}
		pullTarget = c - d * stand;
		pullTarget.z -= player.viewheight;
		Sector s = level.PointInSector(pullTarget.xy);
		if (s)
		{
			pullTarget.z = max(pullTarget.z, s.floorplane.ZatPoint(pullTarget.xy));
		}
	}

	// Ledge assist. If the hook hit the face of a step or ledge whose top is within
	// LEDGE_REACH above the hit point (and there is headroom), pull in two legs:
	// 1) straight up in front of the face until our feet clear the lip,
	// 2) over the lip onto the ledge. Returns true if the assist was set up.
	bool TryLedgeAssist(Line ln, int side, vector3 hit)
	{
		if (!ln || !ln.frontsector || !ln.backsector) return false;   // one-sided: no ledge

		// Horizontal normal of the wall pointing toward us (front side is on the right).
		vector2 n = (ln.delta.y, -ln.delta.x);
		double nl = n.Length();
		if (nl < 0.01) return false;
		n = n * (1.0 / nl);
		if (side != 0) n = (-n.x, -n.y);

		vector2 topXY = hit.xy - n * LEDGE_INSET;
		vector2 liftXY = hit.xy + n * LEDGE_STANDOFF;
		Sector topSec = level.PointInSector(topXY);
		Sector nearSec = level.PointInSector(liftXY);
		if (!topSec || !nearSec) return false;

		double topZ = topSec.floorplane.ZatPoint(topXY);
		double rise = topZ - hit.z;
		if (rise <= 0 || rise > LEDGE_REACH) return false;                 // not a ledge we can reach
		if (topSec.ceilingplane.ZatPoint(topXY) - topZ < Height) return false; // no room to stand up there

		double liftZ = topZ + 2;
		if (nearSec.ceilingplane.ZatPoint(liftXY) - liftZ < Height) return false; // would hit the ceiling lifting

		pullTarget = (liftXY.x, liftXY.y, liftZ);
		pullTarget2 = (topXY.x, topXY.y, topZ);
		hasSecond = true;
		arriveDist = LIFT_ARRIVE;
		return true;
	}

	void HookArrived()
	{
		if (hookIsUse)
		{
			if (hookLine) hookLine.Activate(self, hookSide, SPAC_Use);
			A_StartSound("weapons/sshotl", CHAN_AUTO);
			return;
		}
		// Overshoot guard: a far hook takes its flight time to attach, and we keep
		// sliding meanwhile. If we've gone past the target since firing, pulling now
		// would yank us backwards (yo-yo), so let the hook miss and keep sliding.
		vector2 toNow = pullTarget.xy - pos.xy;
		if (fireDir.Length() > 0.5 && toNow.Length() > 1.0
			&& (fireDir.x * toNow.x + fireDir.y * toNow.y) < 0)
		{
			hookTarget = null;
			hasSecond = false;
			return;
		}
		BeginPull();
	}

	void BeginPull()
	{
		mstate = GS_PULL;
		bNoGravity = true;
		pullTics = 0;
		stuckTics = 0;
		pullSpeed = max(PULL_MIN, slideVel.Length());
		lastDisp = slideVel;   // if the target is already in reach, keep sliding instead of stopping
		A_StartSound("weapons/sshotl", CHAN_AUTO);
	}

	void EndPull()
	{
		bNoGravity = false;
		hasSecond = false;
		hookTarget = null;
		slideVel = lastDisp;
		ClampSlide();
		Vel.Z = clamp(Vel.Z, -MAX_SPEED, 12.0);
		if (slideVel.Length() < SLIDE_STOP)
		{
			mstate = GS_IDLE;
			slideVel = (0, 0);
		}
		else
		{
			mstate = GS_SLIDE;
		}
	}

	void StopGrapple()
	{
		if (mstate == GS_PULL) bNoGravity = false;
		hasSecond = false;
		hookTarget = null;
		mstate = GS_IDLE;
		pending = false;
		slideVel = (0, 0);
	}

	void ClampSlide()
	{
		double sp = slideVel.Length();
		if (sp > MAX_SPEED) slideVel = slideVel * (MAX_SPEED / sp);
	}

	// ---------------- rope visuals ----------------

	vector3 HandPos()
	{
		return (
			pos.x + cos(angle) * 14 + cos(angle - 90) * 9,
			pos.y + sin(angle) * 14 + sin(angle - 90) * 9,
			pos.z + player.viewheight - 9);
	}

	void DrawRope(vector3 tip)
	{
		vector3 hand = HandPos();
		vector3 d = tip - hand;
		double len = d.Length();
		if (len < 16) return;
		int n = int(min(len / 28.0, 96));
		for (int i = 1; i <= n; i++)
		{
			Spawn("RopeBead", hand + d * (double(i) / n));
		}
	}
}
