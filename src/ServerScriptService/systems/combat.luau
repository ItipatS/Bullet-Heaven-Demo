-- ServerScriptService/systems/combat.luau
-- Server-authoritative combat. Per tick: build the spatial hash once, run every weapon by
-- KIND, step projectiles, resolve stone-drop impacts, process deaths, then player contact
-- damage. All damage is authoritative; hits also apply KNOCKBACK (a Knock impulse the horde
-- decays). Death freezes the player + stops their pets; Restart wipes the run.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local world       = require(std.world)
local cts         = require(std.components)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local Pet         = require(std.pet)
local PlayerState = require(std.playerState)
local Registry    = require(std.petRegistry)
local Exp         = require(script.Parent.exp)
local Progress    = require(script.Parent.progression)
local SpawnHost   = require(script.Parent.SpawnMob)
local PetDrops    = require(script.Parent.petdrops)
local HealthDrops = require(script.Parent.healthdrops)
local TixDrops    = require(script.Parent.tixdrops)
local Profile     = require(script.Parent.profile)

local Transform = cts.Transform
local Mob       = cts.Mob
local Health    = cts.Health
local Character  = cts.Character
local Player     = cts.Player
local Elite      = cts.Elite
local Boss       = cts.Boss
local Knock      = cts.Knock

-- ── Tunables ──────────────────────────────────────────────────────────────────
local Y_TOL2        = 6 * 6
local EXP_PER_KILL  = 2
local ELITE_EXP     = 10
local HASH_CELL     = 8
local COMBAT_TICK   = 1 / 30
local CONTACT_R2    = 4.5 * 4.5
local PER_MOB_DPS   = 5
local MAX_CONTACTS  = 6
local HP_SEND       = 1 / 6
local DROP_DELAY    = 0.8
local SAMPLE        = 16
local DENSE_R2      = 8 * 8
local SPLIT_N       = 3
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
local posCache: { [number]: Vector3 } = {}
local mobSample: { Vector3 } = {}

type Bubble = {
    id: number, ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, t0: number,
    pierce: number, baseDmg: number, critChance: number, critDamage: number,
    r2: number, life: number, split: number, knock: number, color: Vector3, hits: { [number]: boolean },
}
local bubbles: { Bubble } = {}
local nextBubbleId = 0

type Drop = { x: number, y: number, z: number, t: number, r2: number, dmg: number, cc: number, cd: number, knock: number }
local pendingDrops: { Drop } = {}

local aim: { [Player]: Vector3 } = {}
local skillCd: { [Player]: { [number]: number } } = {} -- [plr][slot] = next-allowed server time

local fireBatch: { blink.BubbleFire } = {}
local effectBatch: { blink.EffectMsg } = {}
local dead: { [number]: boolean } = {}
local deathIds: { number } = {}
local hitSet: { [number]: boolean } = {} -- mobs damaged-but-survived this tick (cosmetic flash)
local hitIds: { number } = {}
local HIT_CHUNK = 180 -- keep each unreliable Hit packet under the ~900B cap
local spentBubbles: { number } = {} -- bubble ids retired early (pierce used up) → tell the client

blink.Aim.On(function(plr, dir) aim[plr] = dir end)

local zombies    = world:query(Transform, Health):with(Mob):cached()
local characters = world:query(Character, Player):cached()

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
    local cnt = hash:queryInto(cx, cy, cz, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        if not dead[ze] then
            local p = posCache[ze]
            if p then
                local dx, dz = p.X - cx, p.Z - cz
                local d2 = dx * dx + dz * dz
                if d2 <= r2 and (p.Y - cy) ^ 2 <= Y_TOL2 then
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
    local cnt = hash:queryInto(cx, cy, cz, queryOut)
    for j = 1, cnt do
        local ze = queryOut[j]
        if not dead[ze] then
            local p = posCache[ze]
            if p then
                local dx, dz = p.X - cx, p.Z - cz
                local d2 = dx * dx + dz * dz
                if d2 <= r2 and d2 > 1e-3 and (p.Y - cy) ^ 2 <= Y_TOL2 then
                    local inv = 1 / math.sqrt(d2)
                    if (dx * inv) * ax + (dz * inv) * az >= cosHalf then
                        hurt(ze, rollDmg(dmg, cc, cd), dx * inv * knock, dz * inv * knock)
                    end
                end
            end
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

local function pushBubble(now, ox, oy, oz, vx, vy, vz, dmg, pierce, r2, life, color: Vector3, split, knock, cc, cd)
    nextBubbleId += 1
    bubbles[#bubbles + 1] = {
        id = nextBubbleId, ox = ox, oy = oy, oz = oz, vx = vx, vy = vy, vz = vz, t0 = now,
        pierce = pierce, baseDmg = dmg, critChance = cc, critDamage = cd,
        r2 = r2, life = life, split = split, knock = knock, color = color, hits = {},
    }
    fireBatch[#fireBatch + 1] = {
        id = nextBubbleId, origin = Vector3.new(ox, oy, oz), velocity = Vector3.new(vx, vy, vz),
        t0 = now, life = life, color = color, size = 2 * math.sqrt(r2),
    }
end

local function spawnBubble(now: number, origin: Vector3, dirUnit: Vector3, w: any, state: any)
    local v = dirUnit * w.speed
    local col = Vector3.new(w.color.R, w.color.G, w.color.B)
    pushBubble(now, origin.X, origin.Y, origin.Z, v.X, v.Y, v.Z,
        w.dmg * state.damageMult, w.pierce, w.radius * w.radius, w.life, col, w.split, w.knock,
        state.critChance, state.critDamage)
end

-- ── Pet skills ────────────────────────────────────────────────────────────────────
-- Metadata (name/desc/cooldown) lives in petRegistry; the EFFECT lives here, keyed by pet id.
-- Triggered by the slot key (Q/E/R = equipped slot 1/2/3). Each fn: (now, root, w, state, ax, az).
local NOVA_COUNT = 20
local FAN_COUNT  = 14
local AVA_COUNT  = 5

local SKILLS: { [string]: (number, BasePart, any, any, number, number) -> () } = {
    -- Axolotl "Nova": a full ring of piercing bubbles.
    axolotl = function(now, root, w, state)
        local origin = Pet.pos(root.Position)
        for i = 1, NOVA_COUNT do
            local a = (i / NOVA_COUNT) * (2 * math.pi)
            spawnBubble(now, origin, Vector3.new(math.cos(a), 0, math.sin(a)), w, state)
        end
    end,
    -- Fox "Barrage": a wide burst of fast shots where you aim.
    fox = function(now, root, w, state, ax, az)
        local origin = Pet.pos(root.Position)
        local base = Vector3.new(ax, 0, az)
        for i = 0, FAN_COUNT - 1 do
            local ang = ((i / (FAN_COUNT - 1)) - 0.5) * math.rad(120)
            spawnBubble(now, origin, rotateY(base, ang), w, state)
        end
    end,
    -- Slime "Quake": one big damaging pulse around the player.
    slime = function(now, root, w, state)
        local p = root.Position
        local r = w.radius * 2.0
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 5 * state.damageMult, state.critChance, state.critDamage, w.knock * 3)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO }
    end,
    -- Mole "Avalanche": several staggered stone drops on the crowd.
    mole = function(now, root, w, state)
        for i = 1, AVA_COUNT do
            local tp = densestPoint()
            if tp then
                local jx, jz = math.random() * 16 - 8, math.random() * 16 - 8
                pendingDrops[#pendingDrops + 1] = {
                    x = tp.X + jx, y = tp.Y, z = tp.Z + jz, t = now + DROP_DELAY + i * 0.15,
                    r2 = w.radius * w.radius, dmg = w.dmg * state.damageMult, cc = state.critChance, cd = state.critDamage, knock = w.knock,
                }
                effectBatch[#effectBatch + 1] = { kind = FX_DROP, pos = Vector3.new(tp.X + jx, tp.Y, tp.Z + jz), radius = w.radius, dir = ZERO }
            end
        end
    end,
    -- Bear "Roar": a shockwave — damage + big radial knockback.
    bear = function(now, root, w, state)
        local p = root.Position
        local r = w.radius * 1.3
        aoeDamage(p.X, p.Y, p.Z, r * r, w.dmg * 2.5 * state.damageMult, state.critChance, state.critDamage, w.knock * 2.5)
        effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = p, radius = r, dir = ZERO }
    end,
}

-- slot = equipped weapon index (1/2/3). Runs that pet's skill on its registry cooldown.
blink.UseSkill.On(function(plr, slot)
    local state = PlayerState.get(plr)
    if state.dead then return end
    local w = state.weapons[slot]
    if not w then return end
    local fn = SKILLS[w.id]
    if not fn then return end
    local petDef = Registry.pets[w.id]
    local cd = (petDef and petDef.skill and petDef.skill.cooldown) or 8
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

    fn(now, root :: BasePart, w, state, ax, az)
    if #fireBatch > 0 then blink.FireBubble.FireAll(fireBatch); table.clear(fireBatch) end
    if #effectBatch > 0 then blink.Effect.FireAll(effectBatch); table.clear(effectBatch) end
end)

-- ── Steps ──────────────────────────────────────────────────────────────────────
local function rebuildHash()
    hash:beginFrame()
    table.clear(posCache)
    table.clear(mobSample)
    local n = 0
    for e, transform in zombies do
        local p = transform.new.Position
        posCache[e] = p
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

local function fireStep(now: number)
    for _e, char, plr in characters do
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local state = PlayerState.get(plr)
        if state.dead then continue end

        local dir = aim[plr]
        if not dir then
            local lv = root.CFrame.LookVector
            dir = Vector3.new(lv.X, 0, lv.Z)
        end
        local mag = dir.Magnitude
        if mag < 1e-3 then continue end
        local d = dir / mag
        local pos = root.Position
        local mult, cc, cd = state.damageMult, state.critChance, state.critDamage
        local n = #state.weapons

        for i = 1, n do
            local w = state.weapons[i]
            if now < w.cd then continue end
            w.cd = now + w.fireCd

            if w.kind == "aura" then
                aoeDamage(pos.X, pos.Y, pos.Z, w.radius * w.radius, w.dmg * mult, cc, cd, w.knock)
                effectBatch[#effectBatch + 1] = { kind = FX_AURA, pos = pos, radius = w.radius, dir = ZERO }
            elseif w.kind == "melee" then
                local axz = math.sqrt(d.X * d.X + d.Z * d.Z)
                local ax, az = if axz > 1e-3 then d.X / axz else 0, if axz > 1e-3 then d.Z / axz else 1
                coneDamage(pos.X, pos.Y, pos.Z, ax, az, w.radius * w.radius, math.cos(w.spread * 0.5), w.dmg * mult, cc, cd, w.knock)
                effectBatch[#effectBatch + 1] = { kind = FX_MELEE, pos = pos, radius = w.radius, dir = Vector3.new(ax, 0, az) }
            elseif w.kind == "drop" then
                local tp = densestPoint()
                if tp then
                    pendingDrops[#pendingDrops + 1] = {
                        x = tp.X, y = tp.Y, z = tp.Z, t = now + DROP_DELAY,
                        r2 = w.radius * w.radius, dmg = w.dmg * mult, cc = cc, cd = cd, knock = w.knock,
                    }
                    effectBatch[#effectBatch + 1] = { kind = FX_DROP, pos = tp, radius = w.radius, dir = ZERO }
                end
            else -- projectile
                local origin = Pet.slotPos(pos, i - 1, n)
                local shots = w.shots
                if shots <= 1 then
                    spawnBubble(now, origin, d, w, state)
                else
                    for s = 0, shots - 1 do
                        spawnBubble(now, origin, rotateY(d, ((s / (shots - 1)) - 0.5) * w.spread), w, state)
                    end
                end
            end
        end
    end
end

local function bubbleStep(now: number)
    local write = 1
    for i = 1, #bubbles do
        local b = bubbles[i]
        local age = now - b.t0
        if age > b.life then continue end
        local bx, by, bz = b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age
        local cnt = hash:queryInto(bx, by, bz, queryOut)
        for j = 1, cnt do
            local ze = queryOut[j]
            if not b.hits[ze] and not dead[ze] then
                local p = posCache[ze]
                if p then
                    local dx, dz = p.X - bx, p.Z - bz
                    if dx * dx + dz * dz <= b.r2 and (p.Y - by) ^ 2 <= Y_TOL2 then
                        b.hits[ze] = true
                        b.pierce -= 1
                        local sp = math.sqrt(b.vx * b.vx + b.vz * b.vz)
                        local kx, kz = 0, 0
                        if b.knock > 0 and sp > 1e-3 then kx, kz = b.vx / sp * b.knock, b.vz / sp * b.knock end
                        hurt(ze, rollDmg(b.baseDmg, b.critChance, b.critDamage), kx, kz)
                        if b.split > 0 then
                            local base = if sp > 1e-3 then Vector3.new(b.vx, 0, b.vz).Unit else Vector3.new(0, 0, -1)
                            for s = 0, SPLIT_N - 1 do
                                local cdir = rotateY(base, ((s / (SPLIT_N - 1)) - 0.5) * SPLIT_SPREAD)
                                pushBubble(now, p.X, by, p.Z, cdir.X * SPLIT_SPEED, 0, cdir.Z * SPLIT_SPEED,
                                    b.baseDmg * SPLIT_FRAC, 1, SPLIT_R2, SPLIT_LIFE, b.color, 0, b.knock * 0.5, b.critChance, b.critDamage)
                            end
                            b.split = 0
                        end
                        if b.pierce <= 0 then break end
                    end
                end
            end
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
    local eliteDied = false
    for ze in dead do
        local zt = world:get(ze, Transform)
        deathIds[#deathIds + 1] = ze
        local isBoss  = world:get(ze, Boss) ~= nil
        local isElite = world:get(ze, Elite) ~= nil
        if zt then
            local p = zt.new.Position
            local w = SpawnHost.currentWave()
            if isBoss then
                -- boss ALWAYS drops: 1 pet + a big EXP orb worth wave×5 + wave-scaled tix
                PetDrops.dropBoss(p.X, p.Z)
                Exp.dropBig(p.X, p.Z, w * 5)
                TixDrops.drop(p.X, p.Z, 20 + w * 5) -- >20 → StackofTix
            elseif isElite then
                Exp.drop(p.X, p.Z, w * (ELITE_EXP - 8))
                TixDrops.drop(p.X, p.Z, 4 + w * 2)  -- scales Tix→Pile→Stack with the wave
                HealthDrops.maybeDrop(p.X, p.Z)
            else
                Exp.drop(p.X, p.Z, EXP_PER_KILL)
                HealthDrops.maybeDrop(p.X, p.Z) -- small chance of a heart
                TixDrops.maybeDrop(p.X, p.Z)    -- small chance of a tix
            end
        end
        if isElite then eliteDied = true end
        world:delete(ze)
    end
    if #deathIds > 0 then
        blink.Death.FireAll(deathIds)
        for _, plr in Players:GetPlayers() do Profile.addKills(plr, #deathIds) end -- lifetime kills
    end
    if eliteDied then
        for _, plr in Players:GetPlayers() do Progress.offerReward(plr) end
    end
end

-- End the run. Idempotent (the dead flag guards), so every death source funnels here:
-- contact damage, AND Humanoid.Died (fall / void / anything else).
local function killPlayer(plr: Player)
    local s = PlayerState.get(plr)
    if s.dead then return end
    s.dead = true
    s.hp = 0
    local time = workspace:GetServerTimeNow() - s.runStart
    blink.GameOver.Fire(plr, { time = time, level = s.level })
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
    for _e, char, plr in characters do
        local state = PlayerState.get(plr)
        if state.dead then continue end
        -- passive HP regen (earned via the Regeneration card)
        if state.hpRegen > 0 and state.hp < state.maxHp then
            state.hp = math.min(state.maxHp, state.hp + state.hpRegen * dt)
        end
        -- keep the live Humanoid's walk speed in sync with the stat (upgrades + respawns)
        local hum = (char :: Model):FindFirstChildOfClass("Humanoid")
        if hum and hum.WalkSpeed ~= state.walkSpeed then hum.WalkSpeed = state.walkSpeed end
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local pos = root.Position
        local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, queryOut)
        local contacts = 0
        for j = 1, cnt do
            local p = posCache[queryOut[j]]
            if p then
                local dx, dz = p.X - pos.X, p.Z - pos.Z
                if dx * dx + dz * dz <= CONTACT_R2 and (p.Y - pos.Y) ^ 2 <= Y_TOL2 then contacts += 1 end
            end
        end
        if contacts > 0 then
            state.hp -= math.min(contacts, MAX_CONTACTS) * PER_MOB_DPS * dt
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

blink.Restart.On(function(plr)
    PlayerState.reset(plr)
    Progress.resetPlayer(plr)
    SpawnHost.resetRun()  -- wipe the horde + restart waves
    Exp.clearAll()         -- wipe leftover orbs
    PetDrops.clearAll()    -- wipe leftover pet drops
    HealthDrops.clearAll() -- wipe leftover hearts
    TixDrops.clearAll()    -- wipe leftover tix (banked balance is kept)
    -- LoadCharacter YIELDS; Blink SingleSync handlers must not yield → fresh thread.
    task.spawn(function() plr:LoadCharacter() end)
end)

-- ── Tick ──────────────────────────────────────────────────────────────────────
local acc, hpAcc = 0, 0
local function combatWrapper(dt: number)
    acc += dt
    if acc < COMBAT_TICK then return end
    local step = acc
    acc = 0
    local now = workspace:GetServerTimeNow()

    rebuildHash()
    table.clear(dead)
    table.clear(hitSet)
    fireStep(now)
    bubbleStep(now)
    dropStep(now)
    processDeaths()
    damagePlayers(step)

    if #fireBatch > 0 then blink.FireBubble.FireAll(fireBatch); table.clear(fireBatch) end
    if #effectBatch > 0 then blink.Effect.FireAll(effectBatch); table.clear(effectBatch) end

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

    hpAcc += step
    if hpAcc >= HP_SEND then
        hpAcc = 0
        for _, plr in Players:GetPlayers() do blink.Stats.Fire(plr, PlayerState.statsMsg(plr)) end
    end
end

scheduler.SYSTEM(combatWrapper, phases.Combat)
return 0
