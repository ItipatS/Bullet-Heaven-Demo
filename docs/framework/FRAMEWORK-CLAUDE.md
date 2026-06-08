# CLAUDE.md — VEIN framework

> Working codename **VEIN** is a placeholder. Find-replace it with the real name.
> This file is standing context for Claude Code. Read it fully before writing or
> editing anything in this repo. It defines a custom framework built *purely for
> this project* — do not import patterns from generic Roblox tutorials, model
> the conventions below instead.

---

## 1. What this project is

A large-scale, server-authoritative Roblox MMO running a single shard at ~100
concurrent players with hundreds of server-simulated mobs and projectiles. The
combat model is **tick-based** (League-of-Legends-style: discrete ability ticks,
debuff-modified damage, skillshot hitboxes) inside a **fully 3D world**.

The entire design philosophy is: **operate one layer below where most Roblox
development stops.** No engine-native gameplay systems. Custom ECS, custom
networking, custom navigation, custom spatial queries. The engine is used for
rendering, input, and raw data-model plumbing only.

## 2. Core tenets (never violate without explicit instruction)

1. **Engine-native systems are replaced, not used.** No `PathfindingService`, no
   `Humanoid:MoveTo`, no Humanoid state machine for AI, no reliance on engine
   replication for gameplay-critical state. Movement is CFrame manipulation;
   navigation is a custom node graph; networking is explicit and batched.

2. **Tick decoupling is a hard rule.** Every system owns its own clock. AI does
   not wait on rendering, networking does not wait on simulation, simulation does
   not wait on AI. Low bandwidth at high entity counts comes directly from *not*
   forcing everything to one rate.

3. **Server authority is non-negotiable.** There is exactly one source of truth
   per system, and it lives on the server. Clients reconstruct or interpolate;
   they never assert gameplay state.

4. **Correctness is verified, not claimed.** Concurrency- and scale-sensitive
   systems (matchmaking, spatial queries, networking) get stress harnesses that
   actively hunt for the failure (duplicates, stale entries, dropped entities)
   and count them. The happy path is not trusted.

5. **Server entities are pure data.** Mobs, projectiles, and most simulated
   entities create **zero `Instance`s** on the server. They are jecs entities
   with components. No parts, no physics, no Humanoid on the server side.

## 3. Tech stack & module map

| Concern | Module(s) | Notes |
|---|---|---|
| ECS | `jecs` (via `ReplicatedStorage.ecs`), `std.world` | `world` is a singleton. Only the world is global. |
| Scheduling | `std.scheduler`, `std.phases` | Phase-ordered systems. See §4. |
| Components | `std.components` | All components declared in one frozen table. |
| Entity refs | `std.ref` | Stable entity per external key (e.g. `ref(player.UserId)`). Do **not** cache handles — they invalidate. |
| Cross-system queues | `std.mailbox` | Single global mailbox; `push`/`drain` per component buffer. |
| Event collection | `std.collect` | Drains a signal into an iterable inside a system. |
| Behaviour trees | `std.bt` | `SEQUENCE`/`FALLBACK` for mob AI. |
| Throttling | `std.interval` | Simple time-gate helper. |
| Networking | Blink-generated `ServerNet` / `ClientNet` | buffer-packed events. **Do not hand-edit generated files.** Edit `Net.blink` and regenerate. |
| World gen | `Misc.WorldGen` | Deterministic voxel/heightfield generation, sparse block storage. |
| Meshing | `Misc.Mesher` | Greedy meshing, part pooling, client-side only. |
| Terrain streaming | `Server/systems/ChunkServer`, `Client/ChunkClient` | Per-player region streaming = the interest-management template. See §6 and §7. |

### Luau conventions (apply to every hot module)

- Header every gameplay/hot module with `--!optimize 2`, `--!native`, `--!strict`.
- Preallocate arrays with `table.create(n)`; keep hot tables array-like (sequential
  integer keys), not hash-like.
- **No per-tick allocation in hot loops.** Pool and reuse tables, mutate in place.
  GC pauses land directly on frame time on the single Luau thread.
- Components are created once in `std.components` and named via `jecs.Name`.

## 4. Scheduling model

Systems are registered with `scheduler.SYSTEM(fn, phases.X)` and run in a
dependency-ordered phase chain defined in `std.phases`. **The phase order is a
contract — changing it reorders the whole frame.** Current server chain:

```
PreSimulation → EarlyUpdate → Input → GameLogic
  → Physics → PhysicsKnockback → PhysicsGravity → PhysicsTerrain → PhysicsCollision
  → AIBehavior → AIStateMachine → AIMovement → AICombat
  → Combat → Health → Inventory → Economy
  → NetworkDelta → NetworkReliable → Cleanup → LateUpdate → Debug
Heartbeat branch: WorldManagement → Spawning / Environment
```

### Decoupled clocks (target rates)

A system runs on a phase's event but **gates its real work on its own accumulator**
(see `ChunkServer`/`Network` patterns: accumulate `dt`, act when it crosses the
interval, reset). Target rates:

| Clock | Rate | What runs here |
|---|---|---|
| AI think | ~8 Hz | mob decision-making, target selection |
| Simulation | ~20 Hz | movement, combat resolution, ability ticks |
| Network | ~12 Hz | transform deltas + batched events; periodic full snapshots |
| Effects / render | ~60 Hz | client-side interpolation and VFX only |

Server thinks slowly, moves at medium rate; client renders smoothly off a
decoupled clock and interpolates between server updates.

## 5. Spatial query subsystem (the core primitive)

This is the load-bearing performance structure. It is a **uniform spatial hash on
the XZ plane**, rebuilt every tick, queried by every system that needs "what is
near here."

- **Index space, never predicates.** The grid buckets entities by cell position
  only. Volatile facts (debuffs, faction, health, Y height) are **never** indexed —
  they are checked as predicates in the narrow phase on the small candidate set.
- **2D grid for a 3D game.** Entities spread across XZ but not vertically, so the
  index is XZ. **Do not add a Y axis to the index** — it produces mostly-empty
  vertical cells for zero benefit. Y is resolved trivially in the narrow phase on
  candidates only.
- **Rebuild per tick.** `clear()` then re-`insert()` every queryable entity from
  `world:query(Transform, Collidable)` in a phase before `Combat` (e.g.
  `GameLogic`). No spawn/death grid hooks — the ECS already knows who is alive.
- **Broad phase → narrow phase.** A hitbox computes the cell range its AABB
  covers (inflate by max entity radius), pulls candidate ids from those cells,
  then runs the exact shape test + ECS predicate checks on the survivors only.
- **Nearest queries** expand in rings outward from the caster's cell, stopping
  one ring past the first hit (so a far corner of the current ring can't beat a
  closer entity in the next ring).

The `query(shape) → ids` primitive is consumed by, at minimum: skillshot/AoE
resolution, target acquisition (homing, aggro), and **per-player interest
management** (§7). Build it once; point many systems at it.

A reference implementation lives in `std/spatialhash.luau` (packed integer cell
keys, pooled cell arrays, `clear`/`insert`/`query`). Match its conventions.

## 6. Mob simulation

- Mobs are jecs entities (server tables). No Humanoid brain, no `Instance`s server-side.
- **Navigation = hand-painted node graph**, baked offline (plugin-authored). Bake
  node positions, adjacency, edge costs, and height/edge validity at author time
  using raycasts. **At runtime, never raycast for navigation** — walk the baked graph.
  Runtime raycast is allowed only for ground-snapping the visual position.
- Pathfinding: A* over the baked graph. For many mobs converging on a shared
  target (player aggro), prefer a **flow field** (one Dijkstra pass from the target,
  every mob reads its direction) over N independent A* runs.
- **Tiered LOD + fixed per-tick budget.** Hot (near players): full sim. Warm:
  reduced tick. Cold: dormant, state only, not simulated. Process a fixed N mobs
  per tick on a round-robin so frame cost is bounded regardless of mob count.

## 7. Networking & interest management (Blink)

- All networking goes through Blink events defined in `Net.blink` and the generated
  `ServerNet`/`ClientNet`. Edit the `.blink` schema and regenerate; never edit
  generated output.
- Transforms are **CFrame-only**, streamed as buffer-packed deltas with periodic
  full snapshots. Reliable for spawn/despawn and snapshots; unreliable acceptable
  for high-frequency deltas where loss is tolerable.
- Batch aggressively. Accumulate into a buffer over the tick and flush on the
  network clock (see `ServerNet.StepReplication` on `Heartbeat`, and the
  `MAX_BATCH_SIZE` batching in `Network.luau`).
- **Interest management is mandatory and is just the spatial grid pointed at a
  player.** Each client receives only entities in the cells near it — never the
  full entity set. `ChunkServer` already implements this pattern for terrain
  (`REGION_RADIUS_CHUNKS` around the player, per-player `loaded`/`pending`,
  shift-on-move, unload-on-leave, join-boost fast streaming). **Mirror that exact
  pattern for entities** (mobs/players/projectiles): per-player subscription set =
  grid query around the player; diff against last tick; send adds, send removes.

## 8. Combat model

- **Tick-based.** Abilities resolve on discrete ticks, not per frame. Debuffs are
  data: stat lookups + modifier stacks. "Mob has debuff X → ability does more
  damage" is a predicate + multiplier in the narrow phase, not a special case.
- **Server-authoritative resolution.** Ability outcomes are computed on the server
  from validated state. Skillshot hitboxes are resolved via the spatial grid
  (§5): broad-phase candidates → exact shape + faction/debuff/Y predicates → hits.
- Clients display and predict for feel, but never decide what was hit.

## 9. Player model

- Keep the Roblox Humanoid rig **for visuals/animation only** on players. Strip the
  brain: no `MoveTo`, set `Humanoid.EvaluateStateMachine = false`, no engine
  pathfinding. Movement is driven explicitly.
- Roblox has no native server-authoritative player movement. Default stance for
  this project: **client-authoritative movement + hard server validation**
  (max-speed × dt, teleport thresholds, nav/collision sanity), with all **ability
  resolution server-authoritative on validated positions.** A client lying within
  plausible bounds cannot corrupt combat integrity.
- If a system genuinely needs full server-authoritative player movement, that is a
  deliberate, large piece of work (server simulation + client prediction +
  reconciliation) — do not introduce it casually.

## 10. Performance discipline (single Luau thread)

- The one server thread is the real budget. Bandwidth, instances, and player rigs
  are already characterized as cheap; CPU per tick is the constraint.
- The dominant hot path is expected to be **skillshot spatial queries** — protect
  it with the grid (§5), faction/team filtering before the shape test, and
  broad/narrow separation.
- Pool tables, mutate in place, no per-tick allocation in hot loops, `table.create`
  with known sizes, `--!native` on hot modules.
- **Parallel Luau / Actors** is the escape hatch *only* for independent,
  read-heavy work like spatial-query resolution across partitioned cells, and only
  when the profiler demands it. Do not reach for it preemptively.

## 11. Do / Don't for Claude Code

**Do**
- Put the source of truth on the server, one place per system.
- Decouple every system onto its own accumulator-gated clock.
- Represent simulated entities as pure jecs data; tag queryable ones with a
  `Collidable`/`Targetable` component.
- Resolve hitboxes via broad-phase grid query → narrow-phase predicates.
- Implement per-player interest management for any replicated entity stream.
- Add a stress/correctness harness for any concurrency- or scale-sensitive system.
- Edit `Net.blink` and regenerate for networking changes.

**Don't**
- Use `PathfindingService`, `Humanoid:MoveTo`, or the Humanoid state machine for AI.
- Create server-side `Instance`s for mobs/projectiles/entities.
- Rely on engine replication for gameplay-critical state.
- Index the spatial grid by volatile data (debuffs, faction, health) **or by Y**.
- Trust client-reported positions for ability resolution.
- Hand-edit Blink-generated `ServerNet`/`ClientNet`.
- Introduce per-tick heap allocation inside hot loops.

## 12. File layout (observed)

```
src/
  jecs.luau                      -- jecs re-export
  std/                           -- the framework core
    world.luau  scheduler.luau  phases.luau  components.luau
    ref.luau  mailbox.luau  collect.luau  bt.luau  interval.luau
    spatialhash.luau             -- spatial query primitive (§5)
    ClientNet.luau  (generated)  -- Blink client
  Server/
    ServerNet.luau (generated)   -- Blink server
    main/init.server.luau        -- start(systems)
    systems/                     -- one file per system, registered via scheduler.SYSTEM
  Client/
    main.client.luau
    ChunkClient.luau  Sky.client.luau
  Misc/
    WorldGen.luau  Mesher.luau
Net.blink                        -- Blink schema (source of truth for networking)
```
