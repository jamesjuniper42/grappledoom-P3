// Wave survival for GRAPPLE3 (the town).
//
//  - WaveTrigger (editor number 30007): a zone marker. arg0 = wave number (1..5),
//    arg1 = trigger radius in map units (default 1100).
//  - WaveSpawn (30006): where one enemy of a wave appears. arg0 = wave number,
//    arg1 = what: 0 = Cluster Demon (cacodemon), 1 = Ram Car.
//  - WaveDirector (30005): one per map. Waves go in order. Wave N starts when a player
//    comes within the radius of trigger N, and trigger N only works after wave N-1 has
//    been cleared. Nothing stops the player from leaving during a wave; the enemies
//    follow. When the last wave is cleared the exit door (sector tag EXIT_TAG) opens.
//
// Units: 32 map units = 1 meter, 35 tics = 1 second.

class WaveSpawn : Actor
{
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
}

class WaveTrigger : Actor
{
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
}

class WaveDirector : Actor
{
	const LAST_WAVE = 5;
	const DEFAULT_RADIUS = 1100.0;
	const EXIT_TAG = 10;
	const DEMON_HEIGHT = 96.0;    // demons appear this far above the marker's floor

	int timer;
	int nextWave;                 // wave the next trigger starts; 0 = all done
	int curWave;
	bool waveActive;
	Array<Actor> foes;

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
		nextWave = 1;
	}

	override void Tick()
	{
		Super.Tick();
		timer++;
		if (timer == 70)
		{
			Announce("SURVIVE 5 WAVES. Head for the bright beacon tower to start wave 1.");
		}
		if (nextWave > 0 && !waveActive)
		{
			CheckTrigger();
		}
		else if (waveActive && (timer % 10) == 0)
		{
			CheckCleared();
		}
	}

	void Announce(String msg)
	{
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (playeringame[i] && players[i].mo) players[i].mo.A_PrintBold(msg, 4.0);
		}
	}

	Actor NearestPlayer(vector2 from)
	{
		Actor best = null;
		double bestDist = 1e9;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i] || !players[i].mo || players[i].mo.health <= 0) continue;
			double d = (players[i].mo.pos.xy - from).Length();
			if (d < bestDist)
			{
				bestDist = d;
				best = players[i].mo;
			}
		}
		return best;
	}

	void CheckTrigger()
	{
		ThinkerIterator it = ThinkerIterator.Create("WaveTrigger");
		WaveTrigger t;
		while (t = WaveTrigger(it.Next()))
		{
			if (t.args[0] != nextWave) continue;
			double zoneR = (t.args[1] > 0) ? t.args[1] : DEFAULT_RADIUS;
			Actor p = NearestPlayer(t.pos.xy);
			if (p && (p.pos.xy - t.pos.xy).Length() < zoneR)
			{
				StartWave(nextWave);
				return;
			}
		}
	}

	void StartWave(int n)
	{
		curWave = n;
		waveActive = true;
		foes.Clear();

		ThinkerIterator it = ThinkerIterator.Create("WaveSpawn");
		WaveSpawn s;
		while (s = WaveSpawn(it.Next()))
		{
			if (s.args[0] != n) continue;
			Actor f = SpawnFoe(s);
			if (f) foes.Push(f);
		}
		Announce(String.Format("WAVE %d of %d", n, LAST_WAVE));
	}

	Actor SpawnFoe(WaveSpawn s)
	{
		bool isCar = (s.args[1] == 1);
		vector3 at = s.pos;
		if (!isCar) at.z += DEMON_HEIGHT;

		Actor a;
		if (isCar) a = Spawn("RamCar", at);
		else a = Spawn("ClusterDemon", at);
		if (!a) return null;
		a.angle = s.angle;
		Spawn("TeleportFog", a.pos);

		if (!isCar)
		{
			// wake it up and point it at the nearest player
			Actor p = NearestPlayer(s.pos.xy);
			if (p)
			{
				a.target = p;
				a.SetStateLabel("See");
			}
		}
		return a;
	}

	bool FoeDead(Actor f)
	{
		if (!f || f.health <= 0) return true;
		RamCar r = RamCar(f);
		return r && r.exploded;
	}

	void CheckCleared()
	{
		for (int i = 0; i < foes.Size(); i++)
		{
			if (!FoeDead(foes[i])) return;
		}

		waveActive = false;
		foes.Clear();
		if (curWave >= LAST_WAVE)
		{
			nextWave = 0;
			level.ExecuteSpecial(11, null, null, false, EXIT_TAG, 16);   // Door_Open on the exit door
			Announce("ALL WAVES CLEARED! The exit door in the north-west corner is open.");
			return;
		}

		nextWave = curWave + 1;
		String hint = "";
		switch (nextWave)
		{
		case 2: hint = "the east side of the ring road"; break;
		case 3: hint = "the town in the middle (grapple over the wall)"; break;
		case 4: hint = "the north side of the ring road"; break;
		case 5: hint = "the west side of the ring road"; break;
		}
		Announce(String.Format("Wave %d cleared! Next: the beacon at %s.", curWave, hint));
	}
}
