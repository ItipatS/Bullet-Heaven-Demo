# Bullet-Heaven — Technical Spec & Impact

## Thesis (one line)

A **server-authoritative** Vampire-Survivors-style bullet-heaven on Roblox — the server owns
movement, collision, damage, and death for a live horde (**1,000-mob ship cap, validated to
~3,000 at ~85 FPS**) — a class and scale of game the platform is widely assumed to be incapable
of, built on a data-oriented ECS with a hand-rolled binary network protocol.

> **The interesting part is engine-agnostic.** What's hard here — authoritative simulation,
> binary delta replication, spatial-hash collision, formula netcode, a data-oriented ECS, and a
> uniform *apply → resolve → query* data flow — is general systems engineering. Roblox is the
> runtime, not the achievement. See the README's *Transferable engineering* table.

---

## What it proves

1. **Roblox can run a thousand+ *server-authoritative* enemies at interactive framerates.** The
   server decides every mob's movement, every hit, and every death (you can actually lose). This
   is the part almost everyone fakes (client-only cosmetic mobs, or a low hard cap).
2. **Data-oriented ECS + the right spatial/replication tech beats the per-NPC model by 20–60×.**
   The same game built the idiomatic way caps at ~150 enemies; this one holds the horde smooth
   and is architecturally validated toward 10,000.
3. **At horde scale the GPU is a non-issue; the game is a *logic* and *bandwidth* problem** — and
   both were made cheap. The remaining headroom is all in controllable systems.

---

## Why it looks impossible

- **The platform's NPC model doesn't scale.** The idiomatic NPC is a `Model` + `Humanoid` (its
  own state machine, pathfinder, physics) animated by a rig. Practical ceiling ~50–200 before the
  server tick and client render collapse. "Horde" games almost always either make the mobs
  **client-only cosmetics with no server authority**, or **cap the count low**.
- **The naive version of *this* game proved the ceiling.** The starting template — R6 rigs +
  per-mob A\* + per-mob raycasts + per-entity replication — **died at ~150 mobs**.
- **Server authority is hard mode.** Computing a thousand enemies' steering, neighbor collisions,
  and damage *every tick* and *streaming the result* — without melting the server CPU or the wire
  — is the actual wall. Doing it while the player can lose is the point.

---

## Metrics (measured in Studio play-tests)

> Studio runs **server + client on one machine**, so a shipped client (separate machines) runs
> meaningfully higher. GPU figures are from the in-Studio performance overlay.

| Scenario | Result |
|---|---|
| Naive template (R6 rigs + per-mob A\*/raycasts) | **~150 mobs** ceiling |
| 10,000 cheap visuals drawn (static) | **147 FPS**, GPU **~1 ms** |
| 10,000 transforms *built* in Luau / frame (no apply) | **146 FPS** (the math is free) |
| 1,000 mobs, full game (pooled render) | **137 FPS** |
| 1,000 mobs piled on the player — before vs after separation | **25 → 96 FPS** |
| 1,500 mobs, server-authoritative + streaming | **145 idle / 124 moving** (was 61 / 5) |
| **3,000 mobs, validated** | **~85 FPS, stationary *and* moving** |
| 3,000 mobs, ground-conformed over terrain | **~80 FPS**, mobs hug slopes/wedges, 0 under-map |
| Raw 10,000 mobs (last mile) | ~10–16 FPS → client render-LOD only; server/wire already carry it |

**Headline:** ~**20×** the naive ceiling, verified server-authoritative, at **85 FPS** in the
heaviest test environment — with the GPU essentially idle, so the remaining headroom is all in
controllable logic/bandwidth.

**Why it ships at 1,000, not 3,000:** a deliberate design cap (`MAX_ZOMBIES` in `config.luau`),
not a perf wall. At a thousand bodies the bottleneck moves from mob count to *projectiles +
combat resolution* — exactly where a bullet-heaven's load belongs. The horde tech is proven well
past the gameplay it's asked to carry.

---

## How — the technique behind each order of magnitude

- **Render: pooled rigs + batched transforms**, not per-mob Models/`Humanoid`s. The Phase-0 spike
  isolated the truth: drawing 10k is free (147 FPS); the *only* cost is applying transforms, so
  they're batched, and only what moves is moved. The single-`Part` pool validated the ceiling;
  the playable build pools richer rigs on the same driver (a drop-in swap for raw scale).
- **Nav: a flow field** — one multi-source Dijkstra flood per tick from the players' nodes →
  **O(1) next-hop per mob**, replacing per-mob A\*. Y is interpolated **along the graph edge**, so
  mobs hug ramps/drops with **zero per-mob raycasts** and never sink under the map.
- **Collision & separation: a pooled uniform-grid spatial hash** → **O(N·k)** neighbor queries
  instead of O(N²), rebuilt every tick and reused for both bullet hits and crowd separation.
- **Bullets: formula projectiles** — broadcast `{origin, velocity, t0}` once; client *and* server
  compute `pos = origin + velocity·(now−t0)` against a **server-synced clock**. ≈0 bandwidth per
  bullet; the server tests them against the hash for **authoritative** damage.
- **Replication: dense-slot, no-id, i8 deltas.** Positions stream in **slot order** (the client
  maps slot→entity once from the spawn payload — no per-mob `u32` id on the wire), each axis a
  **signed byte** of fixed-point motion (`STEP = 0.02` studs/unit → ±2.54 studs per tick), packed
  256 slots/packet under the ~900 B unreliable cap, with a periodic absolute `f32` snapshot to
  clear quantization drift and slot churn. The client is pure presentation — it interpolates and
  draws, never recomputes, so it scales and never disagrees with the server's hitboxes.
- **Authority that bites:** HP, contact + ranged damage, death, and run-end are all server-decided.

---

## It's a game, not a tech demo

On top of the horde tech: hybrid spawns with **elite/boss spikes** and a **UFO flying enemy**
(no pathfinding — hovers at range with laser bolts, or a slow player-tracking beam when
elite/boss); **XP & leveling** with a **card picker** (player stats / per-pet upgrades / passive
items); a **collection of 11 distinct pet archetypes**, each with a signature ultimate (Nova,
Barrage, Quake, Avalanche, Roar, Nine Lives, Giant Bamboo, Taste the Rainbow, Shell Nova); combat
primitives for **slow/DoT ground hazards, a sweeping aim-tracked beam, orbiting shells, armor /
thorns / regen / brief invulnerability, knockback, crit**; an economy of **passive items**, a
**Tix** meta-currency, boss/elite **card packs** and **pet drops**, and a **Tix shop**;
**DataStore persistence** (Tix + owned collection + chosen main + lifetime best-stats); and
**mobile support** (on-screen aim stick, resolution-scaled HUD). A full survive-and-build loop —
all server-authoritative.

---

## Architecture in one breath

A data-oriented **ECS (JECS)**; systems auto-loaded per folder and ordered by a **phase
scheduler**; **Blink** generating the binary network layer. The whole simulation converges on one
shape: **apply → resolve → query a derived component, with table-driven dispatch.** Effects are
applied in one place, resolved (expire + aggregate) into derived ECS components — mob slows →
`SpeedMul`, player gear + items + timed buffs → `PlayerMods` — and *read* from those components by
the hot loops, which never re-derive at the call site. Weapon kinds, ultimates, and buff math are
all dispatch tables, so content grows by adding a row, not extending a branch. Full write-up:
[`STATS.md`](STATS.md).

---

## Honest limits / next

- Raw **10,000 mobs is the last mile** — *client* render LOD/throttle. The server simulation and
  the dense-slot i8 wire format already carry it; this is optimization, not redesign.
- Numbers are Studio play-test (a shipped client runs higher).
- Single-player verified; co-op is designed in (all state per-player) but not load-tested with
  multiple live clients.
- A couple of 3D-game design edges remain (e.g. flat shots vs very short / flying mobs) — combat
  collision is now mob-size-scaled, which closed the worst of them (giant bosses being unhittable).
