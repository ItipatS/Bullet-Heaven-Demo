-- ServerScriptService/systems/combat.luau
-- Server-authoritative combat (Phase 2/3):
--   • Pet auto-fire — each player's axolotl fires a bubble at the nearest zombie on a CD.
--     Per-player weapon stats come from std.playerState (upgrades change them live).
--   • Bubble sim — bubbles are FORMULA projectiles (origin+velocity*age); the server steps
--     them against a per-tick spatial hash of the horde and applies authoritative damage
--     (piercing up to N). Each bubble carries its firer's dmg/radius/pierce.
--   • Death — zombies at 0 HP are deleted (Death → client releases the pooled part) and
--     hand off to exp.luau to drop EXP orbs.
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
local Exp         = require(script.Parent.exp)
local Progress    = require(script.Parent.progression)

local Transform = cts.Transform
local Mob       = cts.Mob
local Health    = cts.Health
local Character  = cts.Character
local Player     = cts.Player
local Elite      = cts.Elite

-- ── Tunables (tune live) ──────────────────────────────────────────────────────
local BUBBLE_LIFE   = 1.5     -- seconds
local BUBBLE_Y_TOL  = 6       -- flat shots still hit slimes within this vertical gap
local BUBBLE_Y_TOL2 = BUBBLE_Y_TOL * BUBBLE_Y_TOL
local EXP_PER_KILL  = 2
local ELITE_EXP     = 10      -- an elite drops a fat EXP burst on top of its reward card
local HASH_CELL     = 8
local COMBAT_TICK   = 1 / 30
-- player contact damage
local CONTACT_RANGE = 4.5
local CONTACT_R2    = CONTACT_RANGE * CONTACT_RANGE
local CONTACT_YTOL  = 6       -- mobs must be within this height too (no damage through floors/levels)
local CONTACT_YTOL2 = CONTACT_YTOL * CONTACT_YTOL
local PER_MOB_DPS   = 5       -- damage/sec per touching mob...
local MAX_CONTACTS  = 6       -- ...capped so a full swarm = 30 DPS (100 HP → ~3.3s if surrounded)
local HP_SEND       = 1 / 6   -- HUD HP refresh rate

-- ── State ─────────────────────────────────────────────────────────────────────
local hash = SpatialHash.new(HASH_CELL)
local queryOut: { number } = {}

type Bubble = {
    id: number, ox: number, oy: number, oz: number,
    vx: number, vy: number, vz: number, t0: number,
    pierce: number, baseDmg: number, critChance: number, critDamage: number, r2: number, life: number,
    hits: { [number]: boolean },
}
local bubbles: { Bubble } = {}
local nextBubbleId = 0
local aim: { [Player]: Vector3 } = {} -- latest aim dir per player (from the client)

blink.Aim.On(function(plr, dir)
    aim[plr] = dir
end)

local zombies    = world:query(Transform, Health):with(Mob):cached()
local characters = world:query(Character, Player):cached()

-- ── Bubble spawning ──────────────────────────────────────────────────────────────
local fireBatch: { blink.BubbleFire } = {}

local function rotateY(v: Vector3, ang: number): Vector3
    local c, s = math.cos(ang), math.sin(ang)
    return Vector3.new(v.X * c - v.Z * s, v.Y, v.X * s + v.Z * c)
end

local function spawnBubble(now: number, origin: Vector3, dirUnit: Vector3, w: any, state: any)
    local vel = dirUnit * w.speed
    nextBubbleId += 1
    bubbles[#bubbles + 1] = {
        id = nextBubbleId, ox = origin.X, oy = origin.Y, oz = origin.Z,
        vx = vel.X, vy = vel.Y, vz = vel.Z, t0 = now,
        pierce = w.pierce, baseDmg = w.dmg * state.damageMult,
        critChance = state.critChance, critDamage = state.critDamage,
        r2 = w.radius * w.radius, life = w.life, hits = {},
    }
    fireBatch[#fireBatch + 1] = {
        id = nextBubbleId, origin = origin, velocity = vel, t0 = now, life = w.life,
        color = Vector3.new(w.color.R, w.color.G, w.color.B), size = w.radius * 2,
    }
end
local function flushFire()
    if #fireBatch > 0 then blink.FireBubble.FireAll(fireBatch); table.clear(fireBatch) end
end

-- ── Pet skills (Ult: Nova — a ring of bubbles) ───────────────────────────────────
local SKILL_NOVA  = 1
local NOVA_COUNT  = 20
local NOVA_CD     = 8       -- seconds (mirrored client-side for the cooldown UI)
local skillCd: { [Player]: number } = {}

blink.UseSkill.On(function(plr, skillId)
    if skillId ~= SKILL_NOVA then return end
    local now = workspace:GetServerTimeNow()
    if now < (skillCd[plr] or 0) then return end -- authoritative cooldown
    local char = plr.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    skillCd[plr] = now + NOVA_CD
    local state = PlayerState.get(plr)
    local w = state.weapons[1]
    if not w then return end
    local origin = Pet.pos((root :: BasePart).Position)
    for i = 1, NOVA_COUNT do
        local a = (i / NOVA_COUNT) * (2 * math.pi)
        spawnBubble(now, origin, Vector3.new(math.cos(a), 0, math.sin(a)), w, state)
    end
    flushFire()
end)

-- ── Auto-fire: every equipped weapon fires from its ring slot in the aim direction ──
local function fireStep(now: number)
    for _e, char, plr in characters do
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local state = PlayerState.get(plr)
        if state.dead then continue end -- no firing while dead

        local dir = aim[plr]
        if not dir then
            local lv = root.CFrame.LookVector
            dir = Vector3.new(lv.X, 0, lv.Z)
        end
        local mag = dir.Magnitude
        if mag < 1e-3 then continue end
        local d = dir / mag

        local n = #state.weapons
        for i = 1, n do
            local w = state.weapons[i]
            if now >= w.cd then
                w.cd = now + w.fireCd
                local origin = Pet.slotPos(root.Position, i - 1, n)
                local shots = w.shots
                if shots <= 1 then
                    spawnBubble(now, origin, d, w, state)
                else
                    for s = 0, shots - 1 do
                        local ang = ((s / (shots - 1)) - 0.5) * w.spread
                        spawnBubble(now, origin, rotateY(d, ang), w, state)
                    end
                end
            end
        end
    end
    flushFire()
end

-- ── Bubble simulation + damage + death ──────────────────────────────────────────
local dead: { [number]: boolean } = {}
local deathIds: { number } = {}

local function bubbleStep(now: number)
    hash:beginFrame()
    for ze, zt in zombies do
        local p = zt.new.Position
        hash:insert(ze, p.X, p.Y, p.Z)
    end
    table.clear(dead)

    local write = 1
    for i = 1, #bubbles do
        local b = bubbles[i]
        local age = now - b.t0
        if age > b.life then continue end -- expired → dropped

        local bx, by, bz = b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age
        local cnt = hash:queryInto(bx, by, bz, queryOut)
        for j = 1, cnt do
            local ze = queryOut[j]
            if not b.hits[ze] and not dead[ze] then
                local zt = world:get(ze, Transform)
                if zt then
                    local p = zt.new.Position
                    local dx, dz = p.X - bx, p.Z - bz
                    local dy = p.Y - by
                    if dx * dx + dz * dz <= b.r2 and dy * dy <= BUBBLE_Y_TOL2 then
                        b.hits[ze] = true
                        b.pierce -= 1
                        local h = world:get(ze, Health)
                        if h then
                            local dmg = b.baseDmg
                            if math.random() < b.critChance then dmg *= b.critDamage end
                            local hp = h.hp - dmg
                            if hp <= 0 then
                                dead[ze] = true
                            else
                                h.hp = hp
                                world:set(ze, Health, h)
                            end
                        end
                        if b.pierce <= 0 then break end
                    end
                end
            end
        end

        if b.pierce > 0 then
            bubbles[write] = b
            write += 1
        end
    end
    for i = #bubbles, write, -1 do bubbles[i] = nil end

    table.clear(deathIds)
    local eliteDied = false
    for ze in dead do
        local zt = world:get(ze, Transform)
        deathIds[#deathIds + 1] = ze
        local isElite = world:get(ze, Elite) ~= nil
        if zt then
            local p = zt.new.Position
            Exp.drop(p.X, p.Z, if isElite then ELITE_EXP else EXP_PER_KILL)
        end
        if isElite then eliteDied = true end
        world:delete(ze)
    end
    if #deathIds > 0 then blink.Death.FireAll(deathIds) end
    if eliteDied then
        for _, plr in Players:GetPlayers() do Progress.offerReward(plr) end -- explicit reward beat
    end
end

-- ── Player contact damage + death (reuses the hash bubbleStep just built) ─────────
local function damagePlayers(dt: number)
    for _e, char, plr in characters do
        local state = PlayerState.get(plr)
        if state.dead then continue end
        local root = (char :: Model).PrimaryPart
        if not root then continue end
        local pos = root.Position
        local cnt = hash:queryInto(pos.X, pos.Y, pos.Z, queryOut)
        local contacts = 0
        for j = 1, cnt do
            local zt = world:get(queryOut[j], Transform)
            if zt then
                local p = zt.new.Position
                local dx, dz = p.X - pos.X, p.Z - pos.Z
                local dy = p.Y - pos.Y
                if dx * dx + dz * dz <= CONTACT_R2 and dy * dy <= CONTACT_YTOL2 then contacts += 1 end
            end
        end
        if contacts > 0 then
            state.hp -= math.min(contacts, MAX_CONTACTS) * PER_MOB_DPS * dt
            if state.hp <= 0 then
                state.hp = 0
                state.dead = true
                blink.GameOver.Fire(plr, { time = workspace:GetServerTimeNow() - state.runStart, level = state.level })
            end
        end
    end
end

blink.Restart.On(function(plr)
    PlayerState.reset(plr)
    Progress.resetPlayer(plr)
end)

-- ── Tick ──────────────────────────────────────────────────────────────────────
local acc = 0
local hpAcc = 0
local function combatWrapper(dt: number)
    acc += dt
    if acc < COMBAT_TICK then return end
    local step = acc
    acc = 0
    local now = workspace:GetServerTimeNow()
    fireStep(now)
    bubbleStep(now)
    damagePlayers(step)

    hpAcc += step
    if hpAcc >= HP_SEND then
        hpAcc = 0
        for _, plr in Players:GetPlayers() do
            blink.Stats.Fire(plr, PlayerState.statsMsg(plr))
        end
    end
end

scheduler.SYSTEM(combatWrapper, phases.Combat)
return 0
