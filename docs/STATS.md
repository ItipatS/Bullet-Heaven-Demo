# Stats & combat data flow: store → register → apply → resolve → consume

This maps the whole stat/combat pipeline. The design rule the codebase holds everywhere:

> **Apply in one place → resolve into a derived ECS component → read that component.**
> Nothing re-derives "is this active / what's the effective value" at the call site, and content
> grows by *adding a row or a field*, never by extending a branch.

That single discipline is what keeps a system with player stats, passive items, per-pet weapon
upgrades, gear defense, and timed buffs — all interacting — readable and extensible.

| File | Role |
|---|---|
| `std/petRegistry.luau` | **Single source of truth** for pets: base stats, upgrade trees, ultimate meta. Pure data, shared client+server. |
| `std/itemRegistry.luau` | **Single source of truth** for passive items: each item's `apply(state, level)`. |
| `std/playerState.luau` | **Live per-player run state**: global stats, passive-item multipliers, gear defense, and the player's actual weapon instances. The "save game" of a run. |
| `std/statuses.luau` | **Mob status resolver**: applies `Slow`, ticks expiry, folds into the derived `SpeedMul`. |
| `std/playerBuffs.luau` | **Player modifier resolver**: folds gear + items + timed buffs into the derived `PlayerMods` component. |
| `systems/progression.luau` | **Registers & offers** upgrades (cards), applies the chosen one. |
| `systems/combat.luau` | **Consumes** the resolved components every tick to fire / damage. |
| `systems/profile.luau` | **Persists** the meta layer (DataStore): Tix, owned collection, chosen main, best-stats. |

---

## 1. The layers of state

**Player-global** (one set per player, affects everything) — in the `State` table:
`level, xp, xpNext, hp, maxHp, dead, playing, runStart, damageMult, critChance, critDamage,
hpRegen, pickupRange, walkSpeed, haste, expMult, tixDropRate, tix`.

**Passive items** (run-only buffs) — `items` is the owned `id → level`; the derived multipliers
`itemDmg, itemAtkSize, itemKnock, itemPickup, itemHaste, itemCrit, itemCritDmg, itemSkillCd` are
**recomputed from `items`** on every change (`recomputeItems`: reset to identity, then re-apply
each owned item via `itemRegistry`).

**Gear defense** (summed from the run's pets) — `armor, reflect, regenBonus`, recomputed by
`recomputeDefense` whenever the loadout or a weapon level changes.

**Pet (weapon) instances** — one `Weapon` per pet in the run, affecting only that pet:
`id, name, kind, fireCd, dmg, pierce, radius, speed, life, shots, spread, split, knock, color, cd,
level, maxLevel` + behavior flags the upgrade trees toggle (`aoeRadius, splitPierce, skillBubbles,
skillRepeat, boomerang, chain, dot, slowFactor, armor, reflect, regenBonus`). Stored in
`State.weapons` (≤ `MAX_WEAPONS = 10`).

**Timed effects** (live on **ECS components**, not the State table) — mob `Slow {factor, untilT}`
and player `Buffs {[kind] = {mag, untilT}}`. These are the inputs to the resolver stage (§4).

> The split is deliberate: `State` owns **resources & the run loadout** (hp, weapons, owned/squad,
> tix). Everything that is a **modifier** ends up resolved onto an ECS component that combat reads.

---

## 2. STORE — where the numbers physically are

```
PlayerState.states[player] = State {            -- one per player (playerState.luau)
  damageMult = 1.0, critChance = 0.05, ...       -- player-global stats
  hpRegen = 0, walkSpeed = 16, haste = 1, tix = 0,
  items = { spinach = 2, clover = 1 },           -- owned items (id → level)
  itemDmg = 1.3, itemCrit = 0.05, ...            -- DERIVED from items (recomputeItems)
  armor = 0.15, reflect = 0.2, regenBonus = 1,   -- DERIVED from gear (recomputeDefense)
  owned = { axolotl = true, ... },               -- the persisted COLLECTION
  squad = { "turtle" },                          -- menu loadout; [1] = your MAIN
  weapons = {                                     -- the RUN's pet INSTANCES (built from squad + grown in-run)
    Weapon{ id="turtle", kind="orbit", dmg=8, ... },
    ...
  },
}
```

A **pet instance** is `Registry.make(id)` → `table.clone`s the registry `base` and stamps
`id/name/kind`. From that moment it's **independent** of the registry — upgrades mutate the
*instance*, never the template — so a fresh run is always clean. *Registry = template;
State.weapons = the live, upgraded copies.*

The **timed-effect** state lives on the player/mob **entity** (players are ECS entities via
`ref(UserId)`): `world:set(e, Buffs, …)` / `world:set(mobE, Slow, …)`.

---

## 3. REGISTER — where upgrades & content are declared

- **Player-global cards** → `progression.luau` `GLOBAL` table: `{ title, desc, apply(s) }` that
  mutates `State` (`Power` → `s.damageMult += …`, `Regeneration` → `s.hpRegen += …`, etc.).
- **Pet upgrades** → on the pet in `petRegistry.luau` as a level tree: each level applies a fixed
  behavioral upgrade to a *weapon* (`+dmg`, `pierce += 1`, `+5% armor`, `+1 shell`, …).
- **Passive items** → in `itemRegistry.luau`: each item's `apply(state, level)` scales an `item*`
  multiplier (Spinach → `itemDmg *= …`, Clover → `itemCrit += …`, Soda → `itemSkillCd *= 1.25`, …).

Same source of truth means the **panel UI and the real combat math read identical numbers** — no
drift, ever.

---

## 4. APPLY — the round trips that change state

**Cards (level-up + boss/elite packs).** Kill → EXP orb → pickup → `Progress.addXp` → on level-up,
`rollCards` builds an `Offer { source, cards }` from `GLOBAL` + the run pets' next upgrade + item
cards; boss/elite deaths drop a **card pack** (3–5) you walk over. The client shows them; the
chosen card's `apply` closure runs against `State`. (A pet card's closure captures its weapon slot,
so it always edits the currently-equipped instance.)

**The economy / loadout.** You own a **collection** (`owned`) and pick **one MAIN** at the menu
(`setMain` → `squad = {id}`). A run *starts* as just the main and **grows in-run**:
- level-up **new-weapon cards**, restricted to **owned** pets not already in the run → `addToRun`;
- **boss/elite pet drops** → pickup = `ownPet` (unlock) + `addToRun` (join this run).

New pets enter the collection via **boss** (`dropBoss`, guaranteed one you don't own), **elite**
(`maybeDropElite`, ~20%), or the **Tix shop** (`BuyPet`, handled in `profile.luau` which owns the
balance). Items are gained/leveled via cards (`addItem` → `recomputeItems`).

Every loadout/upgrade path ends by calling `recomputeItems` / `recomputeDefense` so the derived
State multipliers stay correct — those are the inputs the resolver reads next.

---

## 5. RESOLVE — the stage that makes it clean *(the core idea)*

Two resolver systems run each tick in the **AIStateMachine** phase — *before* movement (horde) and
combat read anything — and write **derived ECS components**:

**Mobs — `std/statuses.luau`.** Combat applies a slow via `Statuses.slow(mobE, factor, untilT)`
(never `world:set(Slow)` directly). `Statuses.tick` expires finished `Slow`s and folds the active
one into a derived **`SpeedMul`** scalar. The horde movement loop reads **only** `SpeedMul` — it
has no idea what a "slow" is; it just multiplies. (This also fixed a real bug: movement used to
reference an unimported `Slow`, so the debuff was a silent no-op.)

**Players — `std/playerBuffs.luau`.** `playerBuffs.tick` folds, into one derived **`PlayerMods`**
component:
- passive **gear defense** (`armor/reflect/regenBonus` + the `hpRegen` stat),
- the **offensive** card-stats × item buffs (`damageMult·itemDmg`, `crit`, `atkSize`, `knock`,
  `haste`, `skillCd`),
- any active **timed buffs** (`Buffs`), aggregated **data-driven** via
  `BUFF_KIND[kind] = {field, op}` (`op ∈ set | add | mul`).

```lua
PlayerMods = { invuln, armor, reflect, regen, walkSpeed,           -- defense / movement
               damage, crit, critDmg, atkSize, knock, haste, skillCd }  -- offense / firing
```

So a timed buff is applied once (`PlayerBuffs.apply(plr, "invuln", 0, now+2.5)` — turtle Shell
Nova), and *every* consumer just reads the resolved field. (jecs detail: the resolvers defer
structural `add`/`remove` out of their query loop, per the library's iteration rule.)

---

## 6. CONSUME — combat reads resolved components + dispatch tables

All in `combat.luau`, every `COMBAT_TICK = 1/30`. **Zero inline `state.<modifier>` reads remain in
the hot paths** — combat gets the player entity from its `characters` query and does
`world:get(e, PlayerMods)`:

- **Firing** (`fireStep`): cadence-gated per weapon (`w.fireCd / mods.haste`), then dispatched by a
  **table** — `KIND_FIRE[w.kind]` (aura / melee / drop / projectile / **bamboo** / **puddle** /
  **orbit**), with an unknown-kind fallback to `projectile`. Each handler reads `mods.damage /
  crit / critDmg / atkSize / knock` and the per-weapon `w.*`.
- **Projectiles** (`bubbleStep`): formula-position bubbles vs the spatial hash; on hit, behavior is
  decomposed into `bubbleBurst` / `bubbleSplit` / `bubbleChain` / `bubbleReturn` (boomerang),
  dispatched by what the bubble *carries*, not re-derived.
- **Ultimates** (`SKILLS[pet]`): keyed by pet id; read `mods.*` for offense (and `State.hp` only
  for the hp *resource*, e.g. bear's heal). Cooldown = `Registry.pets[id].skill.cooldown ·
  mods.skillCd`.
- **Survival** (`damagePlayers`): regen from `mods.regen`; `Humanoid.WalkSpeed` synced to
  `mods.walkSpeed`; contact damage reduced by `mods.armor`, reflected by `mods.reflect`, negated by
  `mods.invuln`. The **UFO** drain (`ufo.luau`) reads the same `PlayerMods`, so the turtle shield
  protects against every damage source consistently.
- **Movement** (`horde.luau`): mob speed × `SpeedMul`.
- **Pickups** (`exp` / `healthdrops` / `tixdrops`): radius × `state.pickupRange · itemPickup`.

Combat **never** hardcodes a number an upgrade can change, and never re-derives a modifier — it
reads the resolved component or the per-weapon instance.

---

## 7. PERSIST — the meta layer (DataStore)

`profile.luau` persists across sessions on `PlayerRemoving` (and loads on join): the **Tix**
balance, the **owned** pet collection, the chosen **main** (`squad`), and **lifetime best-stats**
(best wave / level / time). `PlayerState.reset(plr)` rebuilds a fresh run but carries `tix`,
`owned`, and `squad` over. The **Tix shop** (`BuyPet`) lives in `profile.luau` because that module
owns `addTix` — keeping the balance authority in one place.

---

## 8. REPLICATE → the client mirror

The server **resolves** state into components, then **replicates** the player-facing slices over Blink.
The client applies the *same* single-source discipline: `std/clientState.luau` is the ONE listener for
each player-data event (`Stats, StatSheet, Items, Weapons, MainWeapon, Profile, TixCount, Unlocked`) and
fans out to HUD widgets via `clientState.on<Event>(fn)` (which fires immediately with the cached value, so
a late subscriber is never stale). Widgets — the top-right panel, the health/EXP bars, the skill bar, the
pet/item tabs — **subscribe to the mirror, never to Blink directly**. So no event has more than one client
listener, each value (`hp`, `weapons`, `tix`…) lives in one place, and the `SingleSync`/`ManySync` drop
bug (a second listener silently dropped, load-order dependent → "updates one HUD in Studio, the other
live") becomes *structurally impossible*. It's the resolver pattern again, on the presentation side.

**Co-op loot is per-player, not raced.** Every drop system (`exp`, `healthdrops`, `tixdrops`, `carddrops`,
`petdrops`) spawns a SEPARATE owner-tagged copy of each drop FOR EACH player in the run — sent only to that
owner, collectible only by them. Two players killing a boss each get their own card pack + their own pet
(picked from one *they* don't own); nobody races. A deliberate, friendly co-op design — not a dupe bug.

---

## 9. One-line mental model & recipes

> **Registries** = templates (pet base/trees/skill meta, item apply fns).
> **State** = the live run (player stats + items + gear defense + cloned upgraded pet instances).
> **progression** = registers upgrades, applies the chosen `apply` to State.
> **statuses / playerBuffs** = resolve raw effects + State modifiers → derived ECS components.
> **combat** = reads the *resolved components* (+ per-weapon instances) every tick, via dispatch tables.

**Add a player stat:** field on `State`/`defaults` → register a `GLOBAL` card → (if a combat
modifier) fold it into `PlayerMods` in `playerBuffs` → read `mods.X` in combat.
**Add a passive item:** one row in `itemRegistry` (its `apply`). Done — `recomputeItems` + the
resolver carry it.
**Add a weapon archetype:** one row in `KIND_FIRE` (+ a `kind` on the pet). Unknown-kind fallback
means it's never a silent no-op.
**Add a timed buff:** one row in `BUFF_KIND = {field, op}`; apply it with `PlayerBuffs.apply`.
**Add a pet:** one entry in `petRegistry` (base + tree + skill) and, if it has an ultimate, one
`SKILLS[id]`. UI and combat both read the registry automatically.
