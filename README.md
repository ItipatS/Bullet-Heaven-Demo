# JECS Bullet-Heaven — Server-Authoritative Horde at Scale

A Vampire-Survivors-style **bullet-heaven** on Roblox that runs **~3,000 live enemies at
~85 FPS** with the **server owning movement, collision, damage, and death** — a scale and a
kind of authority Roblox is widely assumed to be incapable of. Built on **JECS** (Luau ECS).

> Full write-up & technique breakdown: [`docs/SPEC.md`](docs/SPEC.md)

## Demo
- **Place:** https://www.roblox.com/games/104444037041931/RPGJECS-DEMO
- **Video:** [![Watch the video](https://img.youtube.com/vi/eprIcdV42WM/0.jpg)](https://youtu.be/eprIcdV42WM)

> Note: the linked demo/video show the earlier ~150-mob RPG template this grew out of; the
> current build is the 3,000-mob bullet-heaven described below.

---

## What it proves
- Roblox **can** run thousands of **server-authoritative** enemies at interactive framerates
  (the server decides every hit and death — you can actually lose). Most "horde" games fake
  this with client-only cosmetic mobs or cap at ~50–200.
- The right **data-oriented ECS + spatial + replication** stack beats Roblox's per-NPC model
  by **20–60×**.
- At horde scale the **GPU is a non-issue** — it's a *logic + bandwidth* problem, and both
  were made cheap.

## Why that's hard
The idiomatic Roblox NPC is a `Model` + `Humanoid` (its own state machine, pathfinder, and
physics) — practical ceiling **~50–200**. The **naive version of this exact game** (R6 rigs +
per-mob A\* + per-mob raycasts + per-entity replication) **capped at ~150**. The wall isn't
*drawing* the horde — it's *deciding and streaming* 3,000 enemies' steering, collisions, and
damage every tick without melting the server or the wire, while the player can die.

## Metrics (Studio play-test; a shipped client runs higher)
| Scenario | Result |
|---|---|
| Naive template ceiling | **~150 mobs** |
| 10,000 cheap visuals drawn (static) | **147 FPS**, GPU **~1 ms** |
| 1,000 piled on player → with separation | **25 → 96 FPS** |
| 1,500 server-authoritative + streaming | **145 idle / 124 moving** (was 61 / 5) |
| **3,000 mobs (current build)** | **~85 FPS, moving *and* still** |
| raw 10,000 (last mile pending) | ~10–16 FPS |

**Headline: ~20× the naive ceiling, server-authoritative, at 85 FPS — with the GPU idle.**

## How (one technique per order of magnitude)
- **Render** — a recycled pool driven by one `WorldRoot:BulkMoveTo`/frame (drawing is free;
  the only cost is *applying* transforms, so we batch them). The validated single-`Part` pool
  proved the 10k ceiling; the playable build pools **zombie rigs** (anchored root + jointed
  limbs, procedural walk) on the same driver for fidelity — same technique, richer mob.
- **Nav** — a **flow field** (one multi-source Dijkstra flood/tick) → **O(1) next-hop per
  mob** instead of per-mob A\*; Y interpolated along the graph edge → **no per-mob raycasts**,
  never sinks under the map.
- **Collision / separation** — a pooled **uniform-grid spatial hash** → **O(N·k)**, reused
  for bullet hits and crowd separation.
- **Bullets** — **formula projectiles**: broadcast `{origin, velocity, t0}` once; both ends
  compute `pos = origin + velocity·(now−t0)` off a server-synced clock (~0 wire/bullet); the
  server tests them against the hash for **authoritative** damage.
- **Replication** — the **client is pure presentation**: the server streams positions (f16
  deltas + periodic snapshots); the client interpolates and draws, so it scales and never
  disagrees with the hitboxes.

## It's a game, not a tech demo
A **main menu** gates the run, then a **wave spawner** ramps hordes with **elite/boss
spikes** and a **UFO flying enemy** (ignores pathfinding — hovers and attacks at range with
laser bolts, or a slow player-tracking beam as an elite/boss). Kills feed **XP & leveling**
→ a **3-card upgrade picker** tagged by category (*player stat / pet stat / perk*). You build
a loadout of up to **3 of 5 pet weapons** — projectile (piercing bubbles, 3-shot scatter),
**aura**, **melee cone**, **stone-drop** — each a real archetype with a **signature skill on
Q / E / R** (Nova, Barrage, Quake, Avalanche, Roar). **Bosses always drop a pet** + a big XP
orb + currency; **hearts** heal; a **Tix** meta-currency drops in three tiers and **persists
across sessions via DataStore** (alongside lifetime best-stats). Round it out with **player
HP, contact + ranged damage, knockback, hit-flash, fly-to-player pickup FX, and death →
game-over → restart**. A full survive-and-build run loop, all server-authoritative.

A single **pet registry** is the source of truth for every pet (base stats, perks, skill) —
both the loadout/upgrade UI and the real combat math read the same data, so they never drift.

## Architecture (JECS ECS)
- **Systems** auto-loaded per folder, registered via `scheduler.SYSTEM(fn, phase)`:
  - `horde` — one server batch: flow-field steer + spatial-hash separation + edge-Y, then
    position streaming (no per-mob raycasts/LOS)
  - `ufo` — flying-enemy brain: hover at range, laser bolts / player-tracking beam, own stream
  - `combat` — pet auto-fire (4 weapon kinds) + skills, formula-bubble sim vs the hash, crit,
    contact + ranged damage, death/rewards
  - `exp` / `progression` — tiered EXP pickup & merge, XP/levels, the registry-driven cards
  - `petdrops` / `healthdrops` / `tixdrops` — boss pet pickups, heart heals, Tix currency
  - `profile` — DataStore persistence (Tix + lifetime best-stats); `players` — gated spawns
  - client `syncMobs` (pooled zombie rigs) / `syncUFO` / `syncBubbles` / `syncPet` /
    `syncCards` / `syncHealth` / `syncTix` / `syncPetDrops` / `weaponpanel` / `skillbar` /
    `mainmenu` — pure-presentation rendering + UI
- **Networking** via Blink (schema-generated, never hand-edited) — formula projectiles +
  position deltas + periodic snapshots + compact event channels for drops/skills/currency.
- **Single source of truth:** `std/petRegistry.luau` (pet data) feeds both UI and combat.

## Honest limits
- 3,000 is **verified smooth** with the single-`Part` pool; raw 10,000 is the **last mile**
  (client render LOD/throttle + dense-slot i8 replication — optimization, not redesign).
- The playable build trades some of that headroom for **zombie rigs** (richer visuals, ~7×
  the parts); the single-`Part` renderer is a drop-in swap when raw scale matters.
- Numbers are Studio play-test; a shipped client runs higher.
- Single-player verified; co-op is designed in (per-player state) but not load-tested.
