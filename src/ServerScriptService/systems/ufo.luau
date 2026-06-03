-- ServerScriptService/systems/ufo.luau
-- UFO flying enemies — server-authoritative, NO pathfinding (they have no PathNode, so horde.luau
-- skips them). Each UFO hovers above the nearest player's ground level and keeps a STANDOFF range
-- (long-range attacker). Not agile (capped speed). Attacks:
--   • normal      → laser BOLTS (formula projectiles) fired at the player on a cooldown
--   • elite/boss  → a continuous BEAM whose endpoint slowly follows the player (dodgeable)
-- UFOs are normal mobs otherwise (Transform+Health+Mob), so player weapons hit them and combat's
-- processDeaths handles their death/rewards. Player damage drops PlayerState.hp; combat kills at 0.
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
local PlayerState = require(std.playerState)

local Transform = cts.Transform
local Health    = cts.Health
local Speed     = cts.Speed
local Mob       = cts.Mob
local Flying    = cts.Flying
local Elite     = cts.Elite
local Boss      = cts.Boss
local Character  = cts.Character
local Player     = cts.Player

-- ── Tunables ──────────────────────────────────────────────────────────────────
local TICK        = 1 / 20
local HOVER       = 14      -- height above the player's ground level
local STANDOFF    = 34      -- preferred hover distance (XZ)
local NEAR_FRAC   = 0.75    -- back off if closer than STANDOFF*this
local Y_LERP      = 3
local CHUNK       = 50      -- entries per unreliable packet (UfoPos/UfoBeam)
-- normal laser bolt
local FIRE_CD     = 1.8
local BOLT_SPEED  = 70
local BOLT_LIFE   = 2.5
local BOLT_DMG    = 7
local BOLT_HIT_R2 = 4 * 4
-- elite/boss beam
local BEAM_FOLLOW = 2.5      -- endpoint lerp rate toward the player (low = slow/dodgeable)
local BEAM_HIT_R2 = 6 * 6
local BEAM_DPS    = 10
local BOSS_BEAM_MUL = 1.8

local ufos       = world:query(Transform, Speed, Health):with(Mob, Flying):cached()
local characters = world:query(Character):with(Player):cached()

-- ── State ─────────────────────────────────────────────────────────────────────
local fireCdAt:  { [number]: number } = {}
local beamTarget: { [number]: Vector3 } = {}

type Bolt = { ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, t0: number, dmg: number }
local bolts: { Bolt } = {}

local pPos: { Vector3 } = {}
local moveBatch: { blink.UfoPos } = {}
local beamBatch: { blink.UfoBeamMsg } = {}
local boltBatch: { blink.UfoBolt } = {}
local seen: { [number]: boolean } = {}

local function gatherPlayers()
    table.clear(pPos)
    for _e, char in characters do
        local root = (char :: Model).PrimaryPart
        if root then pPos[#pPos + 1] = root.Position end
    end
end

local function nearestPlayer(x: number, z: number): (Vector3?, number)
    local best: Vector3?, bd2 = nil, math.huge
    for _, pp in pPos do
        local dx, dz = pp.X - x, pp.Z - z
        local d2 = dx * dx + dz * dz
        if d2 < bd2 then bd2 = d2; best = pp end
    end
    return best, bd2
end

-- damage the first live player within r2 (3D) of `pt`; returns true if one was hit
local function damageAt(pt: Vector3, r2: number, dmg: number): boolean
    for _, plr in Players:GetPlayers() do
        local s = PlayerState.get(plr)
        if s.dead then continue end
        local c = plr.Character
        local root = c and c:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local d = (root :: BasePart).Position - pt
        if d.X * d.X + d.Y * d.Y + d.Z * d.Z <= r2 then
            s.hp = math.max(0, s.hp - dmg) -- combat.damagePlayers kills when hp hits 0
            return true
        end
    end
    return false
end

local function boltStep(now: number)
    local write = 1
    for i = 1, #bolts do
        local b = bolts[i]
        local age = now - b.t0
        if age > BOLT_LIFE then continue end
        local pt = Vector3.new(b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age)
        if not damageAt(pt, BOLT_HIT_R2, b.dmg) then
            bolts[write] = b
            write += 1
        end
    end
    for i = #bolts, write, -1 do bolts[i] = nil end
end

local function fireChunked(ev: any, arr: { any })
    for i = 1, #arr, CHUNK do
        ev.FireAll(table.move(arr, i, math.min(i + CHUNK - 1, #arr), 1, {}))
    end
end

local function tick(dt: number)
    gatherPlayers()
    local now = workspace:GetServerTimeNow()
    table.clear(moveBatch)
    table.clear(beamBatch)
    table.clear(seen)

    if #pPos > 0 then
        for e, transform, speed in ufos do
            seen[e] = true
            local pos = transform.new.Position
            local target = nearestPlayer(pos.X, pos.Z)
            if not target then continue end

            -- XZ: hold the STANDOFF ring (approach if far, back off if too close)
            local dx, dz = target.X - pos.X, target.Z - pos.Z
            local dist = math.sqrt(dx * dx + dz * dz)
            local move = if dist > STANDOFF then 1 elseif dist < STANDOFF * NEAR_FRAC then -1 else 0
            local nx, nz = pos.X, pos.Z
            if move ~= 0 and dist > 1e-3 then
                nx = pos.X + (dx / dist) * move * speed * dt
                nz = pos.Z + (dz / dist) * move * speed * dt
            end
            -- Y: ease toward the player's level + hover
            local ny = pos.Y + ((target.Y + HOVER) - pos.Y) * math.min(1, Y_LERP * dt)
            local npos = Vector3.new(nx, ny, nz)
            transform.new = CFrame.new(nx, ny, nz) -- combat hash + this stream read it
            moveBatch[#moveBatch + 1] = { id = e, pos = npos }

            if world:get(e, Elite) ~= nil or world:get(e, Boss) ~= nil then
                -- BEAM: endpoint lags toward the player → slow, dodgeable
                local aimPt = target + Vector3.new(0, 3, 0)
                local bt = (beamTarget[e] or npos):Lerp(aimPt, math.min(1, BEAM_FOLLOW * dt))
                beamTarget[e] = bt
                beamBatch[#beamBatch + 1] = { id = e, target = bt }
                local dps = if world:get(e, Boss) ~= nil then BEAM_DPS * BOSS_BEAM_MUL else BEAM_DPS
                damageAt(bt, BEAM_HIT_R2, dps * dt)
            else
                -- BOLT: fire at the player's torso on a cooldown
                if now >= (fireCdAt[e] or 0) then
                    fireCdAt[e] = now + FIRE_CD
                    local aim = (target + Vector3.new(0, 3, 0)) - npos
                    local am = aim.Magnitude
                    if am > 1e-3 then
                        local v = aim / am * BOLT_SPEED
                        bolts[#bolts + 1] = { ox = npos.X, oy = npos.Y, oz = npos.Z, vx = v.X, vy = v.Y, vz = v.Z, t0 = now, dmg = BOLT_DMG }
                        boltBatch[#boltBatch + 1] = { origin = npos, vel = v, t0 = now, life = BOLT_LIFE }
                    end
                end
            end
        end
    end

    boltStep(now)

    -- drop per-UFO state for ones that died (no longer in the query)
    for e in fireCdAt do if not seen[e] then fireCdAt[e] = nil end end
    for e in beamTarget do if not seen[e] then beamTarget[e] = nil end end

    if #moveBatch > 0 then fireChunked(blink.UfoMove, moveBatch) end
    if #beamBatch > 0 then fireChunked(blink.UfoBeam, beamBatch) end
    if #boltBatch > 0 then blink.UfoFire.FireAll(boltBatch); table.clear(boltBatch) end
end

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < TICK then return end
    local step = acc
    acc = 0
    tick(step)
end

scheduler.SYSTEM(wrapper, phases.AIMovement)
return 0
