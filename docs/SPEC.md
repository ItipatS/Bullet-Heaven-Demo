# JECS Bullet-Heaven — Technical Spec & Impact

## Thesis (one line)

A **server-authoritative** Vampire-Survivors-style bullet-heaven running **~3,000 live
enemies at 80+ FPS** on Roblox — with the server owning movement, collision, damage and
death — a class and scale of game Roblox is widely assumed to be incapable of.

---

## What it proves

1. **Roblox can run thousands of *server-authoritative* enemies at interactive framerates.**
   The server decides every mob's movement, every hit, and every death (you can actually
   lose). This is the part almost everyone fakes.
2. **Data-oriented ECS + the right spatial/replication tech beats Roblox's per-NPC model by
   20–60×.** The same game built the "normal" way caps at ~150 enemies; this one holds 3,000
   smooth and is architecturally validated toward 10,000.
3. **At horde scale the GPU is a non-issue; the whole game is a *logic* and *bandwidth*
   problem** — and both were made cheap.

---

## Why it looks impossible

- **Roblox's NPC model doesn't scale.** The idiomatic NPC is a `Model` + `Humanoid` (its own
  state machine, pathfinder, and physics) animated by a rig. Practical ceiling: **~50–200**
  before the server tick and client render collapse. "Horde" games on the platform almost
  always either (a) make the mobs **client-only cosmetics with no server authority**, or
  (b) cap the count low.
- **The naive version of *this* game proved the ceiling.** The starting template — R6 rigs +
  per-mob A\* + per-mob raycasts + per-entity network replication — **died at ~150 mobs**.
- **Server authority is the hard mode.** Computing 3,000 enemies' steering, neighbor
  collisions, and damage *every tick* and *streaming the result* — without melting the server
  CPU or the wire — is the actual wall. Doing it while the player can lose is the point.

---

## Metrics (measured in Studio play-tests)

> Studio runs **server + client on one machine**, so a shipped client (separate machines)
> runs meaningfully higher. GPU figures are from the in-Studio performance overlay.

| Scenario | Result |
|---|---|
| Naive template (R6 rigs + per-mob A\*/raycasts) | **~150 mobs** ceiling |
| 10,000 cheap visuals drawn (static) | **147 FPS**, GPU **~1 ms** |
| 10,000 transforms *built* in Luau / frame (no apply) | **146 FPS** (the math is free) |
| 1,000 mobs, full game (pooled render) | **137 FPS** |
| 1,000 mobs piled on the player — before vs after separation | **25 → 96 FPS** |
| **1,500 mobs, server-authoritative + streaming** | **145 FPS idle / 124 moving** (was 61 / 5) |
| **3,000 mobs (current build)** | **~85 FPS, stationary *and* moving** |
| 3,000 mobs, ground-conformed over terrain | **~80 FPS**, mobs hug slopes/wedges, 0 under-map |
| Raw 10,000 mobs (last mile pending) | ~10–16 FPS → needs render-LOD + dense-slot bandwidth |

**Headline:** **20×** the naive ceiling, verified server-authoritative, at **85 FPS** in the
heaviest test environment — with the GPU essentially idle, meaning the remaining headroom is
all in controllable logic/bandwidth.

---

## How — the technique behind each order of magnitude

- **Render: pooled single `Part`s + `WorldRoot:BulkMoveTo`**, not rigs/Models. The Phase-0
  spike isolated the truth: drawing 10k is free (147 FPS), the *only* cost is applying
  transforms — so we batch them and move only what matters.
- **Nav: a flow field** — one multi-source Dijkstra flood per tick from the players' nodes →
  **O(1) next-hop lookup per mob**, replacing per-mob A\*. Y is interpolated **along the
  graph edge**, so mobs hug ramps/drops with **zero per-mob raycasts** and never sink under
  the map.
- **Collision & separation: a pooled uniform-grid spatial hash** → **O(N·k)** neighbor
  queries instead of O(N²), reused every tick for both bullet hits and crowd separation.
- **Bullets: formula projectiles** — broadcast `{origin, velocity, t0}` once; client *and*
  server compute `pos = origin + velocity·(now−t0)` against a **server-synced clock**. ~0
  bandwidth per bullet; the server tests them against the hash for **authoritative** damage.
- **Replication: the client is pure presentation.** The server owns positions and streams
  them (f16 deltas + periodic f32 snapshots); the client interpolates and draws — no
  client-side recompute, raycasts, or simulation, so it scales and never disagrees with the
  hitboxes.
- **Authority that bites:** HP, contact damage, death, and run-end are all server-decided.

---

## It's a game, not a tech demo

On top of the horde tech: hybrid spawns with **elite/boss spikes**, **XP & leveling**, a
**3-card upgrade picker** (global player stats + crit + per-weapon upgrades, each tagged),
**multiple weapons** as orbiting pets (piercing bubbles + 3-shot scatter, 3 slots, earned via
"New Weapon" drops), an **ultimate skill** (bubble nova) with a cooldown UI, and **player HP →
death → game-over → restart**. A full survive-and-build run loop.

---

## Honest limits / next

- **3,000 is verified smooth; raw 10,000 is the last mile** — render LOD/throttle + dense-slot
  i8 replication (the architecture is in place; this is optimization, not redesign).
- Numbers are Studio play-test (a shipped client runs higher).
- Single-player verified; co-op is designed in (per-player state) but not load-tested.
- A couple of 3D-game design edges noted for later (e.g., flat shots vs very short / flying
  mobs).
