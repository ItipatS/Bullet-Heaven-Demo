# Stats: where they live, how they're registered, computed, and upgraded

This maps the whole stat pipeline — **store → register → apply (upgrade) → compute (call)** — for
both the **player** and the **pets**. Three files do almost all of it:

| File | Role |
|---|---|
| `src/std/petRegistry.luau` | **Single source of truth** for pets: base stats, perks, skill meta. Pure data, shared client+server. |
| `src/std/playerState.luau` | **Live per-player state**: global stats + the player's actual weapon instances. The "save game" of a run. |
| `src/ServerScriptService/systems/progression.luau` | **Registers & offers upgrades** (cards), applies the chosen one. |
| `src/ServerScriptService/systems/combat.luau` | **Reads** the stats every tick to do damage / fire / move. |

---

## 1. Two layers of stats

**Player-global stats** — one set per player, affect everything:
`level, xp, xpNext, hp, maxHp, dead, runStart, damageMult, critChance, critDamage,
hpRegen, pickupRange, walkSpeed, tix`.
Stored in the `State` table in `playerState.luau`.

**Pet (weapon) stats** — one `Weapon` instance per owned pet, affect only that pet:
`id, name, kind, fireCd, dmg, pierce, radius, speed, life, shots, spread, split, knock, color, cd`.
Stored in `State.weapons` (≤3 equipped) and `State.bench` (owned-but-unequipped — keeps upgrades
through a swap).

So: `State` holds player stats **and** owns the pet instances.

---

## 2. STORE — where the numbers physically are

```
PlayerState.states[player] = State {           -- one per player (playerState.luau)
  damageMult = 1.0, critChance = 0.05, ...      -- player-global stats
  hpRegen = 0, pickupRange = 1, walkSpeed = 16,
  tix = 0,                                       -- META currency (see §6)
  weapons = {                                    -- equipped pet INSTANCES
    Weapon{ id="axolotl", dmg=10, pierce=3, ... },
    ...
  },
  bench = { mole = Weapon{...}, ... },           -- unequipped, upgrades preserved
}
```

A **pet instance** is created by `Registry.make(id)` (called via `PlayerState.makeWeapon`):
it `table.clone`s the registry's `base` stats and stamps `id/name/kind/cd`. From that moment the
instance is **independent** of the registry — upgrades mutate the *instance*, never the registry,
so a fresh run (`makeWeapon` again) is always clean.

> Registry = the *template*. State.weapons = the *live, upgraded copies*.

---

## 3. REGISTER — where upgrades are declared

Two pools, by scope:

**Player-global upgrades** → `progression.luau` `GLOBAL` table. Each entry is
`{ title, desc, apply = function(s) ... end }` that mutates the `State`:
```lua
{ title = "Power",       apply = function(s) s.damageMult += 0.15 end },
{ title = "Vitality",    apply = function(s) s.maxHp += 25; s.hp = min(s.maxHp, s.hp+25) end },
{ title = "Regeneration",apply = function(s) s.hpRegen += 1 end },
{ title = "Magnetism",   apply = function(s) s.pickupRange += 0.25 end },
{ title = "Fleet Foot",  apply = function(s) s.walkSpeed += 1 end },
-- + Precision, Brutality, Haste
```

**Pet upgrades** → declared **on the pet** in `petRegistry.luau` as `perks`, each
`{ id, title, desc, kind = "stat"|"perk", apply = function(w) ... end }` that mutates a *weapon*:
```lua
axolotl.perks = {
  { title="Sharpen",    kind="stat", apply=function(w) w.dmg += 5 end },
  { title="Pierce",     kind="perk", apply=function(w) w.pierce += 1 end },
  { title="Split Shot", kind="perk", apply=function(w) w.split += 1 end },
  ...
}
```
`kind` only drives the card's category label (pet-stat vs perk). Same source of truth means the
**panel UI and the real combat math read the identical numbers** — no drift.

---

## 4. APPLY — the upgrade (level-up card) round trip

```
kill → EXP orb → walk over it (exp.luau pickupStep)
  → Progress.addXp(plr, n)                         [progression.luau]
      level up? → queue a pick, offerNext(plr)
        → rollCards(state):                        builds candidates =
            GLOBAL (player)  +  per equipped pet: Registry.pets[id].perks
            each candidate carries an `apply` closure + a `ctype`
        → blink.LevelUp.Fire(plr, cards)           [3 cards, kind 0..3]
  CLIENT (syncCards.luau) shows 3 cards → player clicks
  → blink.ChooseCard.Fire(idx)
  → ChooseCard.On(plr, idx):  c = pending[plr][idx]; c.apply(PlayerState.get(plr))
        player card  → mutates State (damageMult, hpRegen, ...)
        pet card     → closure captured the slot: `s.weapons[wi]` and runs perk.apply(weapon)
  → sendWeapons / sendStats  (push refreshed view to the client UI)
```

Key detail: a pet card's `apply` is a **closure over the weapon slot index** (`wi`), so it always
edits the *currently equipped instance* in that slot. Card `kind` on the wire: `0 player stat ·
1 pet stat · 2 pet perk · 3 new pet` (new-pet cards are disabled — pets come from bosses).

Pet drops (`petdrops.luau`) call `PlayerState.unlock(id)` which `makeWeapon`s a fresh instance
into `weapons` or `bench`.

---

## 5. COMPUTE / CALL — where the stats are actually used

All in `combat.luau`, every combat tick (`COMBAT_TICK = 1/30`):

- **Firing** (`fireStep`): for each equipped `w`, respects `w.fireCd`/`w.cd`; dispatches by
  `w.kind` (projectile/aura/drop/melee). Damage = `w.dmg * state.damageMult`, crit roll uses
  `state.critChance`/`state.critDamage`. Projectile shape uses `w.shots`/`w.spread`/`w.pierce`/
  `w.split`/`w.speed`/`w.life`/`w.radius`/`w.knock`.
- **Survival** (`damagePlayers`): `state.hpRegen` heals up to `state.maxHp`; contact damage drains
  `state.hp`; `Humanoid.WalkSpeed` is synced to `state.walkSpeed` each tick.
- **Pickups**: `exp.luau` / `healthdrops.luau` / `tixdrops.luau` scale their pickup radius by
  `state.pickupRange`.
- **Skills** (`SKILLS` table, keyed by pet id): a skill reads the same `w.*` + `state.*` for its
  burst. Cooldown comes from `Registry.pets[id].skill.cooldown`, tracked per `[player][slot]`.

So combat **never** hardcodes a number that an upgrade can change — it always reads `state.X` or
`weapon.X`.

---

## 6. RESET & META currency

`PlayerState.reset(plr)` rebuilds `defaults()` for a new run (fresh stats, fresh axolotl instance
→ all run upgrades wiped). **Exception: `tix`** is carried over (`reset` copies `old.tix`) — it's
the *meta* currency, earned from `tixdrops.luau`, banked via `PlayerState.addTix`. Right now `tix`
lives only in memory; **DataStore persistence is the remaining TODO** (persist `tix`, and later any
permanent meta-upgrades, on `PlayerRemoving` + load on join).

---

## 7. One-line mental model

> **Registry** = templates (base + perks + skill meta).
> **State** = the live run (player stats + cloned, upgraded pet instances).
> **progression** = registers upgrades and applies the chosen `apply` closure to State.
> **combat** = reads State every tick to act.
> Adding a stat = add the field to `State`/`defaults`, register a card (`GLOBAL` or a pet `perk`),
> and read it in `combat`. That's the whole loop.
