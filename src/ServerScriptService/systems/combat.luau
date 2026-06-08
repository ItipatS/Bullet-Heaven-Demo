-- ServerScriptService/systems/combat.luau
-- Server-authoritative combat. Per tick: build the spatial hash once, run every weapon by
-- KIND, step projectiles, resolve stone-drop impacts, process deaths, then player contact
-- damage. All damage is authoritative; hits also apply KNOCKBACK (a Knock impulse the horde
-- decays). Death makes the player a GHOST for the rest of the round (they spectate, can't
-- rejoin); the round ends — wiping the horde + drops — only when the LAST living player falls.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world       = require(std.world)
local cts         = require(std.components)
local ref         = require(std.ref)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local Config      = require(std.config)
local Pet         = require(std.pet)
local Statuses    = require(std.statuses)
local PlayerBuffs = require(std.playerBuffs)
local PlayerState = require(std.playerState)
local Registry    = require(std.petRegistry)
local Exp         = require(script.Parent.exp)
local Progress    = require(script.Parent.progression)
local SpawnHost   = require(script.Parent.SpawnMob)
local PetDrops    = require(script.Parent.petdrops)
local CardDrops   = require(script.Parent.carddrops)
local HealthDrops = require(script.Parent.healthdrops)
local TixDrops    = require(script.Parent.tixdrops)
local Profile     = require(script.Parent.profile)
local Chars       = require(script.Parent.players) -- character lifecycle: warpIn / refreshLobby

local Transform = cts.Transform
local Mob       = cts.Mob
local Health    = cts.Health
local Size      = cts.Size
local Character  = cts.Character
local Player     = cts.Player
local Elite      = cts.Elite
local Boss       = cts.Boss
local Knock      = cts.Knock
local Slot       = cts.Slot
local PlayerMods = cts.PlayerMods

-- Fallback modifier set used by damagePlayers if a player's PlayerMods isn't resolved yet (~never — the
-- resolver runs in AIStateMachine before Combat). Fail CLOSED: no armor / no invuln so the player still
-- takes damage. NEVER fail open to "invincible" — that footgun was masked while Debug.INVINCIBLE was on.
local DEFAULT_MODS = {
    invuln = false, armor = 0, reflect = 0, regen = 0, walkSpeed = 16,
    damage = 0, crit = 0, critDmg = 0, atkSize = 1, knock = 1, haste = 1, skillCd = 1,
}

-- ── Tunables ──────────────────────────────────────────────────────────────────
local Y_TOL2        = 6 * 6
-- Mob collision scales with the mob's visual size: a big boss should be hittable across its whole
-- body, not just a point at its centre. Effective hit radius = attackRadius + (size-1)*R_PER_SIZE,
-- and the vertical tolerance grows with size (and with hover height, so flyers are reachable too).
local R_PER_SIZE    = 1.4
local CONTACT_BASE  = 4.5  -- base player-contact distance, before adding the mob's body radius
local EXP_PER_KILL  = 2
local ELITE_EXP     = 10
local HASH_CELL     = 8
local COMBAT_TICK   = 1 / 30
local PER_MOB_DPS   = 5
local MAX_CONTACTS  = 6
local HP_SEND       = 1 / 6
local DROP_DELAY    = 0.8
local SAMPLE        = 16
local DENSE_R2      = 8 * 8
local SPLIT_N       = 3
local CHAIN_R2      = 18 * 18  -- fox ricochet: max distance to the next bounce target
local SPLIT_SPREAD  = math.rad(60)
local SPLIT_FRAC    = 0.5
local SPLIT_R2      = 2 * 2
local SPLIT_LIFE    = 0.5
local SPLIT_SPEED   = 55
local FX_AURA, FX_MELEE, FX_DROP = 1, 2, 3
local ZERO = Vector3.zero

-- ── State ─────────────────────────────────────────────────────────────────────
local hash = SpatialHash.new(HASH_CELL)
local queryOut: { number } = {}
local aoeOut: { number } = {} -- separate buffer for burst-on-hit (must not clobber queryOut mid-loop)
local posCache: { [number]: Vector3 } = {}
local mobR:     { [number]: number } = {}  -- per-mob XZ hit-radius bonus (scales with Size)
local mobYt:    { [number]: number } = {}  -- per-mob vertical hit tolerance (Size + hover height)
local mobSample: { Vector3 } = {}

type Bubble = {
    id: number, ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, t0: number,
    pierce: number, baseDmg: number, critChance: number, critDamage: number,
    r2: number, br: number, life: number, split: number, knock: number, color: Vector3, hits: { [number]: boolean },
    aoe: number, splitPierce: boolean, -- weapon-level upgrades: burst-on-hit radius / piercing splits
    boomerang: boolean?, chain: number?, returned: boolean?, -- cat (returns) / fox (ricochets)
}
local bubbles: { Bubble } = {}
local nextBubbleId = 0

type Drop = { x: number, y: number, z: number, t: number, r2: number, dmg: number, cc: number, cd: number, knock: number }
local pendingDrops: { Drop } = {}

local aim: { [Player]: Vector3 } = {}
local skillCd: { [Player]: { [number]: number } } = {} -- [plr][slot] = next-allowed server time
-- Players who DIED in the current round → ghosts. Locked out of rejoining until the round ends
-- (the last living player falls); endRoundIfEmpty clears this and broadcasts RoundOver.
local ghosts: { [Player]: boolean } = {}

local fireBatch: { blink.BubbleFire } = {}
local effectBatch: { blink.EffectMsg } = {}
local dead: { [number]: boolean } = {}
local deathIds: { number } = {}
local hitSet: { [number]: boolean } = {} -- mobs damaged-but-survived this tick (cosmetic flash)
local hitIds: { number } = {}
local HIT_CHUNK = 180 -- keep each unreliable Hit packet under the ~900B cap
local spentBubbles: { number } = {} -- bubble ids retired early (pierce used up) → tell the client
local healthBatch: { blink.MobHp } = {} -- elite/boss HP → client health bars (tiny set)

-- ── Ground hazards (puddles / bamboo) + ult beams ────────────────────────────────
-- A hazard is a persistent ground AoE that ticks damage (and optional slow/knock) for its life.
-- Server owns the damage; the client renders the visual from HazardSpawn/HazardRemove.
type Hazard = {
    id: number, x: number, y: number, z: number, r: number, r2: number,
    dmg: number, knock: number, cc: number, cd: number,
    slowFactor: number, slowDur: number, tickEvery: number, nextTick: number, untilT: number,
}
local hazards: { Hazard } = {}
local nextHazardId = 0
local hazardSpawnBatch: { blink.HazardMsg } = {}
local hazardRemoveBatch: { number } = {}
-- unicorn ult beam (owner sweeps it via local aim; server damages from the streamed aim)
type Beam = { untilT: number, dmg: number, slowFactor: number, width: number, length: number }
local beams: { [Player]: Beam } = {}
local BEAM_STEP = 6   -- studs between beam damage samples
local SLOW_TICK = 0.1 -- how often a hazard/beam re-applies its slow (refreshes the expiry)

blink.Aim.On(function(plr, dir) aim[plr] = dir end)

local zombies    = world:query(Transform, Health, Size):with(Mob):cached()
local characters = world:query(Character, Player):cached()
local bossMobs   = world:query(Health):with(Mob, Boss):cached()  -- for the boss/elite health bars
local eliteMobs  = world:query(Health):with(Mob, Elite):cached()

-- Flush a per-tick accumulation batch over the wire: one packet if non-empty, then reset. Only for the
-- plain "FireAll the whole table" sends — the chunked (packet-cap) / filtered sends stay bespoke.
local function flush<T>(event: any, batch: { T })
    if #batch > 0 then event.FireAll(batch); table.clear(batch) end
end

-- ── Damage primitives (kx,kz = knockback impulse) ────────────────────────────────
local function hurt(ze: number, dmg: number, kx: number, kz: number)
    if dead[ze] then return end
    local h = world:get(ze, Health)
    if not h then return end
    local hp = h.hp - dmg
    if hp <= 0 then
        dead[ze] = true
    else
        h.hp = hp
        world:set(ze, Health, h)
        hitSet[ze] = true
        if kx ~= 0 or kz ~= 0 then
            local cur = world:get(ze, Knock)
            world:set(ze, Knock, Vector3.new((if cur then cur.X else 0) + kx, 0, (if cur then cur.Z else 0) + kz))
        end
    end
end

local function rollDmg(dmg: number, cc: number, cd: number): number
    return if math.random() < cc then dmg * cd else dmg
end

local function aoeDamage(cx, cy, cz, r2, dmg, cc, cd, knock)
    local baseR = math.sqrt(r2)
    local cnt = hash:queryInto(cx, cy, cz, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        if not dead[ze] then
            local p = posCache[ze]
            if p then
                local dx, dz = p.X - cx, p.Z - cz
                local d2 = dx * dx + dz * dz
                local reach = baseR + (mobR[ze] or 0)
                local yt = mobYt[ze] or 6
                if d2 <= reach * reach and (p.Y - cy) ^ 2 <= yt * yt then
                    local kx, kz = 0, 0
                    if knock > 0 and d2 > 1e-3 then
                        local inv = knock / math.sqrt(d2); kx, kz = dx * inv, dz * inv
                    end
                    hurt(ze, rollDmg(dmg, cc, cd), kx, kz)
                end
            end
        end
    end
end

local function coneDamage(cx, cy, cz, ax, az, r2, cosHalf, dmg, cc, cd, knock)
    local baseR = math.sqrt(r2)
    local cnt = hash:queryInto(cx, cy, cz, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        if not dead[ze] then
            local p = posCache[ze]
            if p then
                local dx, dz = p.X - cx, p.Z - cz
                local d2 = dx * dx + dz * dz
                local reach = baseR + (mobR[ze] or 0)
                if d2 <= reach * reach and d2 > 1e-3 and (p.Y - cy) ^ 2 <= (mobYt[ze] or 6) ^ 2 then
                    local inv = 1 / math.sqrt(d2)
                    if (dx * inv) * ax + (dz * inv) * az >= cosHalf then
                        hurt(ze, rollDmg(dmg, cc, cd), dx * inv * knock, dz * inv * knock)
                    end
                end
            end
        end
    end
end

-- apply a Slow (factor<1) to every mob within r2 of (x,z); refreshes expiry to now+dur. Effects are
-- owned by std/statuses — we only hand it the raw (entity, factor, untilT); it derives the SpeedMul
-- that movement reads. (No-op for factor>=1 so callers can pass a neutral slow unconditionally.)
local function applySlow(x: number, y: number, z: number, r2: number, factor: number, dur: number, now: number)
    if factor >= 1 then return end
    local cnt = hash:queryInto(x, y, z, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        local p = posCache[ze]
        if p and not dead[ze] then
            local dx, dz = p.X - x, p.Z - z
            if dx * dx + dz * dz <= r2 then
                Statuses.slow(ze, factor, now + dur)
            end
        end
    end
end

-- spawn a persistent ground hazard (puddle/bamboo): ticks dmg (+knock/slow) for `life`s. kind drives
-- the client visual (1 puddle, 2 bamboo, 3 giant bamboo).
local function spawnHazard(kind: number, x: number, y: number, z: number, r: number, dmg: number,
                           knock: number, cc: number, cd: number, slowFactor: number,
                           tickEvery: number, life: number)
    nextHazardId += 1
    local now = workspace:GetServerTimeNow()
    hazards[#hazards + 1] = {
        id = nextHazardId, x = x, y = y, z = z, r = r, r2 = r * r,
        dmg = dmg, knock = knock, cc = cc, cd = cd,
        slowFactor = slowFactor, slowDur = tickEvery + 0.2, tickEvery = tickEvery,
        nextTick = now, untilT = now + life,
    }
    hazardSpawnBatch[#hazardSpawnBatch + 1] =
        { id = nextHazardId, kind = kind, pos = Vector3.new(x, y, z), radius = r, life = life }
end

local function hazardStep(now: number)
    local write = 1
    for i = 1, #hazards do
        local hz = hazards[i]
        if now >= hz.nextTick then
            hz.nextTick = now + hz.tickEvery
            aoeDamage(hz.x, hz.y, hz.z, hz.r2, hz.dmg, hz.cc, hz.cd, hz.knock)
            applySlow(hz.x, hz.y, hz.z, hz.r2, hz.slowFactor, hz.slowDur, now)
        end
        if now < hz.untilT then
            hazards[write] = hz; write += 1
        else
            hazardRemoveBatch[#hazardRemoveBatch + 1] = hz.id
        end
    end
    for i = #hazards, write, -1 do hazards[i] = nil end
end

-- unicorn ult: a sweeping beam. The owner renders it from local aim (UltBeam); the server damages
-- along the streamed aim each tick. `dmg` is a DPS (scaled by dt per tick).
local function startBeam(plr: Player, life: number, dmg: number, slowFactor: number, width: number, length: number)
    local now = workspace:GetServerTimeNow()
    beams[plr] = { untilT = now + life, dmg = dmg, slowFactor = slowFactor, width = width, length = length }
    blink.UltBeam.Fire(plr, { active = 1, life = life, width = width, length = length })
end

local function beamStep(now: number, dt: number)
    for plr, bm in beams do
        if now >= bm.untilT or not PlayerState.get(plr).playing then beams[plr] = nil; continue end
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local mods = world:get(ref(plr.UserId), PlayerMods)
        if not mods then continue end
        local pos = (root :: BasePart).Position
        local ax, az = 0, 1
        local dir = aim[plr]
        if dir then
            local m = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
            if m > 1e-3 then ax, az = dir.X / m, dir.Z / m end
        end
        local r2 = bm.width * bm.width
        local cc, cd = mods.crit, mods.critDmg
        local tick = bm.dmg * dt -- DPS → per-tick
        for s = 1, math.floor(bm.length / BEAM_STEP) do
            local d = s * BEAM_STEP
            local sx, sz = pos.X + ax * d, pos.Z + az * d
            aoeDamage(sx, pos.Y, sz, r2, tick, cc, cd, 0)
            applySlow(sx, pos.Y, sz, r2, bm.slowFactor, SLOW_TICK + 0.2, now)
        end
    end
end

local function densestPoint(): Vector3?
    local best: Vector3?, bestN = nil, -1
    for _, p in mobSample do
        local cnt = hash:queryInto(p.X, p.Y, p.Z, queryOut)
        local c = 0
        for j = 1, cnt do
            local q = posCache[queryOut[j]]
            if q then
                local dx, dz = q.X - p.X, q.Z - p.Z
                if dx * dx + dz * dz <= DENSE_R2 then c += 1 end
            end
        end
        if c > bestN then bestN = c; best = p end
    end
    return best
end

-- ── Bubbles ──────────────────────────────────────────────────────────────────
local function rotateY(v: Vector3, ang: number): Vector3
    local c, s = math.cos(ang), math.sin(ang)
    return Vector3.new(v.X * c - v.Z * s, v.Y, v.X * s + v.Z * c)
end

local function pushBubble(now, ox, oy, oz, vx, vy, vz, dmg, pierce, r2, life, color: Vector3, split, knock, cc, cd, aoe, splitPierce)
    nextBubbleId += 1
    bubbles[#bubbles + 1] = {
        id = nextBubbleId, ox = ox, oy = oy, oz = oz, vx = vx, vy = vy, vz = vz, t0 = now,
        pierce = pierce, baseDmg = dmg, critChance = cc, critDamage = cd,
        r2 = r2, br = math.sqrt(r2), life = life, split = split, knock = knock, color = color, hits = {},
        aoe = aoe or 0, splitPierce = splitPierce or false,
    }
    fireBatch[#fireBatch + 1] = {
        id = nextBubbleId, origin = Vector3.new(ox, oy, oz), velocity = Vector3.new(vx, vy, vz),
        t0 = now, life = life, color = color, size = 2 * math.sqrt(r2),
    }
end

-- `mods` is the player's resolved PlayerMods (offensive modifiers already folded: damage/crit/atkSize/knock).
local function spawnBubble(now: number, origin: Vector3, dirUnit: Vector3, w: any, mods: any)
    local v = dirUnit * w.speed
    local col = Vector3.new(w.color.R, w.color.G, w.color.B)
    local radius = w.radius * mods.atkSize -- item attack-size buff (Milk) folded into mods.atkSize
    pushBubble(now, origin.X, origin.Y, origin.Z, v.X, v.Y, v.Z,
        w.dmg * mods.damage, w.pierce, radius * radius, w.life, col,
        w.split, w.knock * mods.knock,
        mods.crit, mods.critDmg,
        w.aoeRadius * mods.atkSize, w.splitPierce)
    local b = bubbles[#bubbles] -- tag the just-pushed bubble with archetype behavior
    b.boomerang = w.boomerang or false
    b.chain = w.chain or 0
    b.returned = false
end

-- ── Pet skills (ULTS) ───────────────────────────────────────────────────────────────
-- Metadata (name/desc/cooldown) lives in petRegistry; the EFFECT lives here, keyed by pet id.
-- Each fn: (plr, now, root, w, state, ax, az). Most ignore plr (only beam/invuln need it).
local NOVA_COUNT = 20
local FAN_COUNT  = 14
local AVA_COUNT  = 5

-- fn: (plr, now, root, w, state, mods, ax, az). `mods` = resolved PlayerMods (offensive stats already
-- folded); `state` is only for the hp RESOURCE (bear's heal) — never re-read offensive stats off it.
local SKILLS: { [string]: (Player, number, BasePart, any, any, any, number, number) -> () } = {
    -- Axolotl "Nova": a full ring of piercing bubbles.
    axolotl = function(_plr, now, root, w, _state, mods)
        local origin = Pet.pos(root.Position)
        local count = NOVA_COUNT + (w.skillBubbles or 0) -- weapon-level upgrades scale the skill
        local times = 1 + (w.skillRepeat or 0)
        for _ = 1, times do
            for i = 1, count do
                local a = (i / count) * (2 * math.pi)
                spawnBubble(now, origin, Vector3.new(math.cos(a), 0, math.sin(a)), w, mods)
            end
        end
    end,
    -- Fox "Barrage": a wide burst of fast (ricocheting) shots where you aim.
    fox = function(_plr, now, root, w, _state, mods, ax, az)
        local origin = Pet.pos(root.Position)
        local base = Vector3.new(ax, 0, az)
        local count = FAN_COUNT + (w.skillBubbles or 0)
        local times = 1 + (w.skillRepeat or 0)
        for _ = 1, times do
            for i = 0, count - 1 do
                local ang = ((i / math.max(1, count - 1)) - 0.5) * math.rad(120)
                spawnBubble(now, origin, rotateY(base, ang), w, mods)
            end
        end
    end,
    -- Slime "Quake": one big damaging pulse around the player.
    slime = function(_plr, _now, root, w, _state, mods)
        local p = root.Position
        local r = w.radius * 2.0 * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 5 * mods.damage, mods.crit, mods.critDmg, w.knock * 3 * mods.knock)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO }
    end,
    -- Mole "Avalanche": several staggered stone drops on the crowd.
    mole = function(_plr, now, root, w, _state, mods)
        for i = 1, AVA_COUNT do
            local tp = densestPoint()
            if tp then
                local jx, jz = math.random() * 16 - 8, math.random() * 16 - 8
                local r = w.radius * mods.atkSize
                pendingDrops[#pendingDrops + 1] = {
                    x = tp.X + jx, y = tp.Y, z = tp.Z + jz, t = now + DROP_DELAY + i * 0.15,
                    r2 = r * r, dmg = w.dmg * mods.damage, cc = mods.crit, cd = mods.critDmg, knock = w.knock * mods.knock,
                }
                effectBatch[#effectBatch + 1] = { kind = FX_DROP, pos = Vector3.new(tp.X + jx, tp.Y, tp.Z + jz), radius = r, dir = ZERO }
            end
        end
    end,
    -- Bear "Roar": radial knockback shockwave + a HEAL burst (bruiser sustain).
    bear = function(_plr, _now, root, w, state, mods)
        local p = root.Position
        local r = w.radius * 1.3 * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 2.5 * mods.damage, mods.crit, mods.critDmg, w.knock * 2.8 * mods.knock)
        state.hp = math.min(state.maxHp, state.hp + state.maxHp * 0.25) -- heal 25% max HP (hp resource stays on state)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO }
    end,
    -- Panda "Giant Bamboo": one huge bamboo erupts ahead — big knockback + damage.
    panda = function(_plr, _now, root, w, _state, mods, ax, az)
        local p = root.Position
        local bx, bz = p.X + ax * 14, p.Z + az * 14
        spawnHazard(3, bx, p.Y, bz, (w.radius + 6) * mods.atkSize,
            w.dmg * 3 * mods.damage, (w.knock + 30) * mods.knock, mods.crit, mods.critDmg, 1, 0.25, 2.5)
    end,
    -- Unicorn "Taste the Rainbow": a slow sweeping rainbow beam that tracks aim (Final Spark).
    unicorn = function(plr, _now, _root, w, _state, mods)
        local life = 3.5 + (w.skillBubbles or 0) * 1.5 -- tree extends the beam
        local dps = (w.dot * 3 + 30) * mods.damage
        startBeam(plr, life, dps, math.max(0.4, w.slowFactor), 4, 80)
    end,
    -- Cat "Nine Lives": a storm of boomerangs flung outward in a ring.
    cat = function(_plr, now, root, w, _state, mods)
        local origin = Pet.pos(root.Position)
        for i = 1, 12 do
            local a = (i / 12) * (2 * math.pi)
            spawnBubble(now, origin, Vector3.new(math.cos(a), 0, math.sin(a)), w, mods)
        end
    end,
    -- Turtle "Shell Nova": brief invulnerability + a huge radial shove (and a damage pulse).
    turtle = function(plr, now, root, w, _state, mods)
        local p = root.Position
        local r = (w.radius + 16) * mods.atkSize
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 4 * mods.damage, mods.crit, mods.critDmg, (w.knock + 30) * mods.knock)
        PlayerBuffs.apply(plr, "invuln", 0, now + 2.5) -- timed buff → resolved into PlayerMods (combat + ufo read it)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO }
    end,
}

-- cow/elephant reuse a matching archetype ult (they weren't reworked)
SKILLS.cow      = SKILLS.slime   -- pulse
SKILLS.elephant = SKILLS.mole    -- staggered drops

-- slot = equipped weapon index (1/2/3). Runs that pet's skill on its registry cooldown.
blink.UseSkill.On(function(plr, slot)
    local state = PlayerState.get(plr)
    if not state.playing then return end
    if slot ~= state.main then return end -- only the player's MAIN weapon has a usable skill
    local w = state.weapons[slot]
    if not w then return end
    local fn = SKILLS[w.id]
    if not fn then return end
    local mods = world:get(ref(plr.UserId), PlayerMods)
    if not mods then return end -- resolver hasn't written this player yet (first frame of play)
    local petDef = Registry.pets[w.id]
    local cd = ((petDef and petDef.skill and petDef.skill.cooldown) or 8) * mods.skillCd -- Soda slows skills
    local now = workspace:GetServerTimeNow()
    local slots = skillCd[plr]
    if not slots then slots = {}; skillCd[plr] = slots end
    if now < (slots[slot] or 0) then return end
    local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    if not root then return end
    slots[slot] = now + cd

    -- aim XZ (cursor aim if streamed, else facing)
    local ax, az = 0, 1
    local dir = aim[plr]
    if dir then
        local m = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
        if m > 1e-3 then ax, az = dir.X / m, dir.Z / m end
    else
        local lv = (root :: BasePart).CFrame.LookVector
        local m = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
        if m > 1e-3 then ax, az = lv.X / m, lv.Z / m end
    end

    fn(plr, now, root :: BasePart, w, state, mods, ax, az)
    flush(blink.FireBubble, fireBatch)
    flush(blink.Effect, effectBatch)
end)

-- ── Steps ──────────────────────────────────────────────────────────────────────
local function rebuildHash()
    hash:beginFrame()
    table.clear(posCache)
    table.clear(mobR)
    table.clear(mobYt)
    table.clear(mobSample)
    local n = 0
    for e, transform, _health, size in zombies do
        local p = transform.new.Position
        posCache[e] = p
        mobR[e] = (size - 1) * R_PER_SIZE -- 0 for normals → unchanged feel; big for elites/bosses
        -- vertical reach: grows with size (tall boss column) AND covers hover height (flyers at p.Y
        -- so a ground-level shot still connects). Ground mobs sit near p.Y≈0 so this stays ~6.
        mobYt[e] = math.max(6 + (size - 1) * 3, p.Y + 6)
        hash:insert(e, p.X, p.Y, p.Z)
        n += 1
        if #mobSample < SAMPLE then
            mobSample[#mobSample + 1] = p
        else
            local r = math.random(1, n)
            if r <= SAMPLE then mobSample[r] = p end
        end
    end
end

-- Weapon-kind firing — TABLE-DRIVEN dispatch (mirrors SKILLS), keyed by w.kind. Each handler:
--   (now, pos, d, w, mods, i, n) — pos = player root, d = aim unit dir, i/n = weapon slot index / count.
-- Offensive stats come straight off `mods` (resolved PlayerMods). Add a weapon kind = add ONE row; an
-- unknown/legacy kind falls back to `projectile` below — never a silent no-op (CLAUDE.md allowlist gotcha).
local KIND_FIRE: { [string]: (number, Vector3, Vector3, any, any, number, number) -> () } = {
    aura = function(_now, pos, _d, w, mods)
        local r = w.radius * mods.atkSize
        aoeDamage(pos.X, pos.Y, pos.Z, r * r, w.dmg * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = pos, radius = r, dir = ZERO }
    end,
    melee = function(_now, pos, d, w, mods)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local r = w.radius * mods.atkSize
        coneDamage(pos.X, pos.Y, pos.Z, ax, az, r * r, math.cos(w.spread * 0.5), w.dmg * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock)
        effectBatch[#effectBatch + 1] = { kind = FX_MELEE, pos = pos, radius = r, dir = Vector3.new(ax, 0, az) }
    end,
    drop = function(now, pos, _d, w, mods)
        for s = 1, w.shots do -- weapon level → multiple stones (jittered around dense spots)
            local tp = densestPoint()
            if tp then
                local jx, jz = 0, 0
                if s > 1 then jx, jz = math.random() * 16 - 8, math.random() * 16 - 8 end
                local dx, dz = tp.X + jx, tp.Z + jz
                local r = w.radius * mods.atkSize
                pendingDrops[#pendingDrops + 1] = {
                    x = dx, y = tp.Y, z = dz, t = now + DROP_DELAY + (s - 1) * 0.1,
                    r2 = r * r, dmg = w.dmg * mods.damage, cc = mods.crit, cd = mods.critDmg, knock = w.knock * mods.knock,
                }
                effectBatch[#effectBatch + 1] = { kind = FX_DROP, pos = Vector3.new(dx, tp.Y, dz), radius = r, dir = ZERO }
            end
        end
    end,
    -- panda: summon `shots` bamboo from the ground in an interference (zig-zag lattice) ahead of aim;
    -- each is a thin, knockback hazard that lingers w.life (zone-control), ticking knock+damage every 0.4s
    bamboo = function(_now, pos, d, w, mods)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local px, pz = -az, ax -- perpendicular
        for s = 0, w.shots - 1 do
            local along = 10 + s * 5
            local side = (if s % 2 == 0 then 1 else -1) * (3 + (s // 2) * 4)
            local bx = pos.X + ax * along + px * side
            local bz = pos.Z + az * along + pz * side
            spawnHazard(2, bx, pos.Y, bz, w.radius * mods.atkSize, w.dmg * mods.damage, w.knock * mods.knock, mods.crit, mods.critDmg, 1, 0.4, w.life)
        end
    end,
    -- unicorn: lob a rainbow puddle out along aim — a DoT + slow zone for `life`s
    puddle = function(_now, pos, d, w, mods)
        local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
        local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
        local bx, bz = pos.X + ax * 22, pos.Z + az * 22
        spawnHazard(1, bx, pos.Y, bz, w.radius * mods.atkSize, w.dot * mods.damage, 0, mods.crit, mods.critDmg, w.slowFactor, 0.4, w.life)
    end,
    -- turtle: shells circle the player (synced clock so the client visual aligns), hit + knock
    orbit = function(now, pos, _d, w, mods)
        local count = math.max(1, w.shots)
        local baseA = now * 2.2
        local orbitR = 7 + w.radius
        local r = w.radius * mods.atkSize
        for s = 0, count - 1 do
            local a = baseA + (s / count) * (2 * math.pi)
            local sx, sz = pos.X + math.cos(a) * orbitR, pos.Z + math.sin(a) * orbitR
            aoeDamage(sx, pos.Y, sz, r * r, w.dmg * mods.damage, mods.crit, mods.critDmg, w.knock * mods.knock)
        end
    end,
    projectile = function(now, pos, d, w, mods, i, n)
        local origin = Pet.slotPos(pos, i - 1, n)
        local shots = w.shots
        if shots <= 1 then
            spawnBubble(now, origin, d, w, mods)
        else
            for s = 0, shots - 1 do
                spawnBubble(now, origin, rotateY(d, ((s / (shots - 1)) - 0.5) * w.spread), w, mods)
            end
        end
    end,
}

local function fireStep(now: number)
    for e, char, plr in characters do
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local state = PlayerState.get(plr)
        if not state.playing then continue end
        -- offensive modifiers (card stats × item buffs × any timed offense buff) are resolved into
        -- PlayerMods by the playerBuffs system — read them, never re-derive inline. `state` still owns
        -- the run loadout (weapons) + hp/playing, which aren't modifiers.
        local mods = world:get(e, PlayerMods)
        if not mods then continue end

        local dir = aim[plr]
        if not dir then
            local lv = root.CFrame.LookVector
            dir = Vector3.new(lv.X, 0, lv.Z)
        end
        local mag = dir.Magnitude
        if mag < 1e-3 then continue end
        local d = dir / mag
        local pos = root.Position
        local haste = mods.haste -- fire-rate gate (w.fireCd / haste)
        local n = #state.weapons

        for i = 1, n do
            local w = state.weapons[i]
            if now < w.cd then continue end
            w.cd = now + w.fireCd / haste
            local fire = KIND_FIRE[w.kind] or KIND_FIRE.projectile -- unknown/legacy kind → projectile
            fire(now, pos, d, w, mods, i, n)
        end
    end
end

-- ── On-hit behaviors (each a self-contained weapon-level effect; called from bubbleStep on a hit) ──
-- All AoE scans below use aoeOut, NOT queryOut, so they can't corrupt the caller's in-progress neighbour
-- loop. (cx,cy,cz) is the impact centre (mob XZ at the bubble's height). `ze` is the mob just struck.

-- boomerang (cat): at half-life, launch a return bolt back toward the throw origin (the second pass).
local function bubbleReturn(b: Bubble, now: number, bx: number, by: number, bz: number)
    b.returned = true
    local rdx, rdz = b.ox - bx, b.oz - bz
    local rm = math.sqrt(rdx * rdx + rdz * rdz)
    if rm <= 1e-3 then return end
    local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
    if sp < 1e-3 then sp = 60 end
    pushBubble(now, bx, by, bz, rdx / rm * sp, 0, rdz / rm * sp, b.baseDmg, b.pierce, b.r2,
        b.life * 0.5, b.color, 0, b.knock, b.critChance, b.critDamage, b.aoe, b.splitPierce)
end

-- weapon-level "burst on hit": a small AoE (half damage) around the impact.
local function bubbleBurst(b: Bubble, ze: number, cx: number, cy: number, cz: number)
    local ar2 = b.aoe * b.aoe
    local admg = b.baseDmg * 0.5
    local ac = hash:queryInto(cx, cy, cz, aoeOut)
    for jj = 1, ac do
        local ze2 = aoeOut[jj]
        if ze2 ~= ze and not dead[ze2] then
            local q = posCache[ze2]
            if q then
                local ddx, ddz = q.X - cx, q.Z - cz
                if ddx * ddx + ddz * ddz <= ar2 and (q.Y - cy) ^ 2 <= Y_TOL2 then
                    hurt(ze2, rollDmg(admg, b.critChance, b.critDamage), 0, 0)
                end
            end
        end
    end
end

-- split: a fan of SPLIT_N short-lived bolts from the impact, along the bubble's heading (`sp` = its speed).
local function bubbleSplit(b: Bubble, now: number, cx: number, cy: number, cz: number, sp: number)
    local base = if sp > 1e-3 then Vector3.new(b.vx, 0, b.vz).Unit else Vector3.new(0, 0, -1)
    local splitPierce = if b.splitPierce then 2 else 1
    for s = 0, SPLIT_N - 1 do
        local cdir = rotateY(base, ((s / (SPLIT_N - 1)) - 0.5) * SPLIT_SPREAD)
        pushBubble(now, cx, cy, cz, cdir.X * SPLIT_SPEED, 0, cdir.Z * SPLIT_SPEED,
            b.baseDmg * SPLIT_FRAC, splitPierce, SPLIT_R2, SPLIT_LIFE, b.color, 0, b.knock * 0.5, b.critChance, b.critDamage, 0, false)
    end
end

-- chain (fox): ricochet a bolt to the nearest un-hit, living mob within CHAIN_R2 of the impact. The new
-- bolt inherits `b.hits` semantics via a fresh set but carries chain-1, so the ricochet count is bounded.
local function bubbleChain(b: Bubble, now: number, ze: number, cx: number, cy: number, cz: number, bchain: number)
    local best: Vector3?, bd2 = nil, CHAIN_R2
    local cnt = hash:queryInto(cx, cy, cz, aoeOut)
    for jj = 1, cnt do
        local ze2 = aoeOut[jj]
        if ze2 ~= ze and not dead[ze2] and not b.hits[ze2] then
            local q = posCache[ze2]
            if q then
                local ddx, ddz = q.X - cx, q.Z - cz
                local d2 = ddx * ddx + ddz * ddz
                if d2 < bd2 then bd2 = d2; best = q end
            end
        end
    end
    if not best then return end
    local dirx, dirz = best.X - cx, best.Z - cz
    local m = math.sqrt(dirx * dirx + dirz * dirz)
    if m <= 1e-3 then return end
    local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
    if sp < 1e-3 then sp = 70 end
    pushBubble(now, cx, cy, cz, dirx / m * sp, 0, dirz / m * sp, b.baseDmg, 1,
        b.r2, b.life, b.color, 0, b.knock, b.critChance, b.critDamage, b.aoe, b.splitPierce)
    bubbles[#bubbles].chain = bchain - 1
end

local function bubbleStep(now: number)
    local write = 1
    for i = 1, #bubbles do
        local b = bubbles[i]
        local age = now - b.t0
        if age > b.life then continue end
        local bx, by, bz = b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age

        if b.boomerang and not b.returned and age >= b.life * 0.5 then
            bubbleReturn(b, now, bx, by, bz)
        end

        local cnt = hash:queryInto(bx, by, bz, queryOut)
        for j = 1, cnt do
            local ze = queryOut[j]
            if b.hits[ze] or dead[ze] then continue end
            local p = posCache[ze]
            if not p then continue end
            local dx, dz = p.X - bx, p.Z - bz
            local reach = b.br + (mobR[ze] or 0) -- + mob body radius so big bosses are hittable
            if dx * dx + dz * dz > reach * reach or (p.Y - by) ^ 2 > (mobYt[ze] or 6) ^ 2 then continue end

            -- HIT: damage + knockback, then any weapon-level on-hit effects (burst / split / chain).
            b.hits[ze] = true
            b.pierce -= 1
            local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
            local kx, kz = 0, 0
            if b.knock > 0 and sp > 1e-3 then kx, kz = b.vx / sp * b.knock, b.vz / sp * b.knock end
            hurt(ze, rollDmg(b.baseDmg, b.critChance, b.critDamage), kx, kz)

            if b.aoe > 0 then bubbleBurst(b, ze, p.X, by, p.Z) end
            if b.split > 0 then bubbleSplit(b, now, p.X, by, p.Z, sp); b.split = 0 end
            local bchain = b.chain or 0
            if bchain > 0 then b.chain = 0; bubbleChain(b, now, ze, p.X, by, p.Z, bchain) end

            if b.pierce <= 0 then break end
        end

        if b.pierce > 0 then
            bubbles[write] = b
            write += 1
        else
            spentBubbles[#spentBubbles + 1] = b.id -- pierce used up → client despawns it now
        end
    end
    for i = #bubbles, write, -1 do bubbles[i] = nil end
end

local function dropStep(now: number)
    local write = 1
    for i = 1, #pendingDrops do
        local dp = pendingDrops[i]
        if now >= dp.t then
            aoeDamage(dp.x, dp.y, dp.z, dp.r2, dp.dmg, dp.cc, dp.cd, dp.knock)
        else
            pendingDrops[write] = dp
            write += 1
        end
    end
    for i = #pendingDrops, write, -1 do pendingDrops[i] = nil end
end

local function processDeaths()
    table.clear(deathIds)
    for ze in dead do
        local zt = world:get(ze, Transform)
        deathIds[#deathIds + 1] = ze
        -- Boss/Elite are value-less TAGS (world:add) → world:get returns nil even when present.
        -- MUST use world:has, or every boss/elite is misread as a normal mob (no card/big-EXP drop).
        local isBoss  = world:has(ze, Boss)
        local isElite = world:has(ze, Elite)
        if zt then
            local p = zt.new.Position
            local w = SpawnHost.currentWave()
            if isBoss then
                -- boss ALWAYS drops: a CARD PACK + a guaranteed-new PET + a big EXP orb + tix
                CardDrops.drop(p.X, p.Z)
                PetDrops.dropBoss(p.X, p.Z) -- guaranteed pet (prefers one you don't own)
                Exp.dropBig(p.X, p.Z, w * 5)
                TixDrops.drop(p.X, p.Z, 20 + w * 5) -- >20 → StackofTix
            elseif isElite then
                CardDrops.drop(p.X, p.Z)        -- elites also drop a card pack
                PetDrops.maybeDropElite(p.X, p.Z) -- ...and an uncommon pet
                Exp.drop(p.X, p.Z, w * (ELITE_EXP - 8))
                TixDrops.drop(p.X, p.Z, 4 + w * 2)  -- scales Tix→Pile→Stack with the wave
                HealthDrops.maybeDrop(p.X, p.Z)
            else
                Exp.drop(p.X, p.Z, EXP_PER_KILL)
                HealthDrops.maybeDrop(p.X, p.Z) -- small chance of a heart
                TixDrops.maybeDrop(p.X, p.Z)    -- small chance of a tix
            end
        end
        local slot = world:get(ze, Slot)
        if slot then SpawnHost.freeSlot(slot) end -- recycle the dense replication slot (zombies)
        world:delete(ze)
    end
    if #deathIds > 0 then
        blink.Death.FireAll(deathIds)
        for _, plr in Players:GetPlayers() do Profile.addKills(plr, #deathIds) end -- lifetime kills
    end
    -- (elites/bosses no longer grant a free pick — they DROP a card pack you walk over; carddrops.luau)
end

-- End the run. Idempotent (the dead flag guards), so every death source funnels here:
-- contact damage, AND Humanoid.Died (fall / void / anything else).
local function killPlayer(plr: Player)
    local s = PlayerState.get(plr)
    if s.dead then return end
    s.dead = true
    s.playing = false -- out of the arena → no longer fired/targeted; the dead body just lies there
    s.hp = 0
    ghosts[plr] = true -- a ghost for the rest of this round — can't rejoin until it ends
    local time = workspace:GetServerTimeNow() - s.runStart
    blink.GameOver.Fire(plr, { time = time, level = s.level }) -- client → spectate mode
    Profile.recordRun(plr, SpawnHost.currentWave(), s.level, time) -- persist best stats + runs
end

-- Hook Humanoid.Died for a character so external deaths also end the run. CharacterAutoLoads is
-- off (players.luau) — the dead body stays put until Restart calls LoadCharacter, so a death
-- can't silently reset the character out from under the GameOver screen.
local function hookChar(plr: Player, char: Model)
    task.spawn(function()
        local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
        if hum then (hum :: Humanoid).Died:Connect(function() killPlayer(plr) end) end
    end)
end
local function watchPlayer(plr: Player)
    plr.CharacterAdded:Connect(function(c) hookChar(plr, c) end)
    if plr.Character then hookChar(plr, plr.Character) end
end
Players.PlayerAdded:Connect(watchPlayer)
for _, plr in Players:GetPlayers() do watchPlayer(plr) end

local function damagePlayers(dt: number)
    for e, char, plr in characters do
        local state = PlayerState.get(plr)
        if not state.playing then continue end
        -- ALL combat modifiers (passive gear defense + active timed buffs) are resolved by the
        -- playerBuffs system into PlayerMods — read them here, never re-derive inline. Fall back to a
        -- no-armor/no-invuln default if it's somehow unresolved, so a hiccup can never read as invincible.
        local mods = world:get(e, PlayerMods) or DEFAULT_MODS
        -- regen: Regeneration card + bear regenBonus + any timed regen buff (all folded into mods.regen)
        if mods.regen > 0 and state.hp < state.maxHp then
            state.hp = math.min(state.maxHp, state.hp + mods.regen * dt)
        end
        -- keep the live Humanoid's walk speed in sync (base stat × any active speed buff)
        local hum = (char :: Model):FindFirstChildOfClass("Humanoid")
        if hum and hum.WalkSpeed ~= mods.walkSpeed then hum.WalkSpeed = mods.walkSpeed end
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local pos = root.Position
        local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, queryOut)
        local contacts = 0
        local reflectDmg = PER_MOB_DPS * mods.reflect * dt -- thorns: damage back per contacting mob
        for j = 1, cnt do
            local qe = queryOut[j]
            local p = posCache[qe]
            if p then
                local dx, dz = p.X - pos.X, p.Z - pos.Z
                local reach = CONTACT_BASE + (mobR[qe] or 0) -- big bosses touch you at their edge
                if dx * dx + dz * dz <= reach * reach and (p.Y - pos.Y) ^ 2 <= (mobYt[qe] or 6) ^ 2 then
                    contacts += 1
                    if reflectDmg > 0 then hurt(qe, reflectDmg, 0, 0) end -- turtle thorns
                end
            end
        end
        if contacts > 0 and not Config.Debug.INVINCIBLE and not mods.invuln then
            -- armor reduces incoming contact damage (turtle); Shell Nova grants brief invuln
            state.hp -= math.min(contacts, MAX_CONTACTS) * PER_MOB_DPS * dt * (1 - mods.armor)
        end
        -- death check covers EVERY damage source (contact + UFO bolts/beam drained hp elsewhere)
        if state.hp <= 0 then
            state.hp = 0
            local hum = (char :: Model):FindFirstChildOfClass("Humanoid")
            if hum then hum.Health = 0 end -- kill the body (also fires Humanoid.Died)
            killPlayer(plr)                -- immediate GameOver (Died is a no-op after this)
        end
    end
end

-- PLAY. Round-tracked (NOT a per-player horde reset):
--   • A ghost (died THIS round) is ignored — they stay spectating until the round ends.
--   • If a round is live, this player JOINS it as-is (e.g. straight into wave 50) — fresh
--     character + own progression, shared horde untouched. Covers new joiners AND reconnects.
--   • If no round is live, this Play STARTS one: wipe any leftovers + spawn wave 1.
blink.Restart.On(function(plr)
    if ghosts[plr] then return end -- dead this round → locked out until RoundOver frees you
    if not SpawnHost.isRunning() then
        SpawnHost.resetRun()   -- begin a fresh round (horde + wave 1)
        Exp.clearAll()         -- wipe any leftover orbs
        PetDrops.clearAll()    -- ... pet drops
        CardDrops.clearAll()   -- ... card packs
        HealthDrops.clearAll() -- ... hearts
        TixDrops.clearAll()    -- ... tix (banked balance is kept)
    end
    PlayerState.reset(plr)
    Progress.resetPlayer(plr)
    PlayerState.get(plr).playing = true -- BEFORE warpIn so the spawn handler won't re-park them
    Chars.warpIn(plr) -- warp the parked lobby body into the arena (no cold LoadCharacter hitch)
end)

-- Leaving cleans up per-player combat state (and frees the ghost slot for the leak's sake).
Players.PlayerRemoving:Connect(function(plr)
    ghosts[plr] = nil
    aim[plr] = nil
    skillCd[plr] = nil
    beams[plr] = nil
end)

-- ── Round lifecycle ─────────────────────────────────────────────────────────────
-- A round lives only while at least one player is alive in the arena. The instant the last
-- one falls (death) OR disconnects, the round is OVER: wipe the horde + every ground drop and
-- stop spawning, so an empty/all-dead server doesn't grind on a ghost horde and the next Play
-- starts clean at wave 1. A player who joins/restarts while someone is still alive JOINS the
-- run in progress instead (handled in the Restart handler above). Polled from the combat tick
-- (outside every query) so the field-wipe never deletes mobs mid-iteration.
local function noOneFighting(): boolean
    for _, plr in Players:GetPlayers() do
        if PlayerState.get(plr).playing then return false end
    end
    return true
end

local function endRoundIfEmpty()
    if SpawnHost.isRunning() and noOneFighting() then
        SpawnHost.endRun()     -- wipe the horde + stop waves (running → false)
        Exp.clearAll()         -- and every leftover ground drop (banked Tix is kept)
        PetDrops.clearAll()
        CardDrops.clearAll()
        HealthDrops.clearAll()
        TixDrops.clearAll()
        -- wipe live hazards + beams so the next round starts clean
        local hids = {}
        for _, hz in hazards do hids[#hids + 1] = hz.id end
        table.clear(hazards); table.clear(beams)
        if #hids > 0 then blink.HazardRemove.FireAll(hids) end
        table.clear(ghosts)        -- everyone is freed → eligible to Play the next round
        blink.RoundOver.FireAll(1) -- clients: exit spectate, back to the menu/Play
        -- re-park a fresh lobby body for anyone whose body died this round → next Play warps in
        -- cleanly (and the dead bodies are cleared off the field). Invisible: camera is the menu.
        for _, plr in Players:GetPlayers() do
            PlayerState.get(plr).playing = false
            Chars.refreshLobby(plr)
        end
    end
end

-- ── Tick ──────────────────────────────────────────────────────────────────────
local acc, hpAcc = 0, 0
local function combatWrapper(dt: number)
    acc += dt
    if acc < COMBAT_TICK then return end
    local step = acc
    acc = 0
    endRoundIfEmpty() -- before any query: tear down a finished round (all players dead/gone)
    local now = workspace:GetServerTimeNow()

    rebuildHash()
    table.clear(dead)
    table.clear(hitSet)
    fireStep(now)
    bubbleStep(now)
    dropStep(now)
    hazardStep(now)      -- puddles + bamboo tick damage/slow
    beamStep(now, step)  -- unicorn ult sweeping beam
    processDeaths()
    damagePlayers(step)

    flush(blink.FireBubble, fireBatch)
    flush(blink.Effect, effectBatch)
    flush(blink.HazardSpawn, hazardSpawnBatch)
    flush(blink.HazardRemove, hazardRemoveBatch)

    -- bubbles that used up their pierce this tick → client despawns them (pierce reads finite)
    if #spentBubbles > 0 then
        for i = 1, #spentBubbles, HIT_CHUNK do
            local chunk = table.move(spentBubbles, i, math.min(i + HIT_CHUNK - 1, #spentBubbles), 1, {})
            blink.RemoveBubble.FireAll(chunk)
        end
        table.clear(spentBubbles)
    end

    -- hit-flash: mobs that took damage but survived (deaths already go via Death)
    table.clear(hitIds)
    for ze in hitSet do
        if not dead[ze] then
            hitIds[#hitIds + 1] = ze
            if #hitIds >= HIT_CHUNK then blink.Hit.FireAll(hitIds); table.clear(hitIds) end
        end
    end
    if #hitIds > 0 then blink.Hit.FireAll(hitIds) end

    -- elite/boss HP → client health bars (the set is tiny; dead ones are already deleted above)
    table.clear(healthBatch)
    for e, h in bossMobs do
        healthBatch[#healthBatch + 1] = { id = e, hp = math.max(0, math.floor(h.hp)), max = math.max(1, math.floor(h.max)) }
    end
    for e, h in eliteMobs do
        healthBatch[#healthBatch + 1] = { id = e, hp = math.max(0, math.floor(h.hp)), max = math.max(1, math.floor(h.max)) }
    end
    if #healthBatch > 0 then blink.MobHealth.FireAll(healthBatch) end

    hpAcc += step
    if hpAcc >= HP_SEND then
        hpAcc = 0
        for _, plr in Players:GetPlayers() do blink.Stats.Fire(plr, PlayerState.statsMsg(plr)) end
    end
end

scheduler.SYSTEM(combatWrapper, phases.Combat)
return 0
