-- ServerScriptService/systems/SpawnMob.luau
-- WAVE spawner: spawn a whole wave (normals ramped in over a couple seconds + a few elites),
-- let the player clear it, short breather, then the next (bigger, tougher) wave. Exposes
-- resetRun() so a death/restart wipes the field and starts over at wave 1.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink    = require(ServerScriptService.ServerNet)
local std      = ReplicatedStorage.std
local pathData = require(std.PathData)

local world     = require(std.world)
local cts       = require(std.components)
local scheduler = require(std.scheduler)
local phases    = require(std.phases)

local Transform = cts.Transform
local Size      = cts.Size
local Mob       = cts.Mob
local MobType   = cts.MobType
local Speed     = cts.Speed
local PathNode  = cts.PathNode
local Health    = cts.Health
local Elite     = cts.Elite
local Boss      = cts.Boss
local Flying    = cts.Flying

local Waypoints = pathData[1]

-- ── Tunables ──────────────────────────────────────────────────────────────────
local ZOMBIE_TYPE  = "Zombie"
local ZOMBIE_SPEED = 9
local ZOMBIE_HP    = 30
local NORMAL_SIZE  = 1
local ELITE_SIZE   = 2.6
local ELITE_SPEED  = 7
local ELITE_HP_MUL = 12
local BOSS_SIZE    = 5
local BOSS_SPEED   = 5
local BOSS_HP_MUL  = 60       -- boss HP = wave HP × this (a real wall)

local MAX_ZOMBIES   = 3000   -- perf cap (also caps wave size)
local BASE_WAVE     = 25
local WAVE_GROW     = 18      -- +mobs per wave
local HP_GROWTH     = 0.35    -- +HP per wave
local ELITE_FROM    = 2       -- first wave with elites
local BOSS_EVERY    = 5       -- a boss (→ drops a PET) every Nth wave
local BREATHER      = 3.0     -- seconds between waves
local MAX_WAVE_TIME = 90      -- force the next wave if a few stragglers never die
local SPAWN_EVERY   = 0.08
local SPAWN_BATCH   = 25      -- ramp the wave in (no 1-frame dump)

-- ── UFO flying enemy (a random sprinkle, not a replacement) ─────────────────────
local UFO_TYPE        = "UFO"
local UFO_FROM        = 1      -- first wave UFOs appear
local UFO_CHANCE      = 0.06   -- chance a NORMAL spawn is a UFO instead of a zombie
local UFO_HOVER       = 14     -- spawn/hover height above the ground node
local UFO_SPEED       = 10
local UFO_N_SCALE     = 0.5    -- normal (model default-ish)
local UFO_E_SCALE     = 1.0    -- elite  (scaled back up to 1)
local UFO_B_SCALE     = 2.0    -- boss
local UFO_N_HP        = 0.6    -- ×waveHP (squishy flyer — "shouldn't be hard")
local UFO_E_HP        = 0.5    -- ×eliteHP
local UFO_B_HP        = 0.5    -- ×bossHP
local UFO_ELITE_CHANCE = 0.35  -- chance an elite is a UFO elite
local UFO_BOSS_CHANCE  = 0.40  -- chance a boss is a UFO boss

-- ── Spawn node pool ───────────────────────────────────────────────────────────
local NodeIDs: { number } = {}
for id in Waypoints do NodeIDs[#NodeIDs + 1] = id end
assert(#NodeIDs > 0, "PathData.Waypoints is empty!")
local function randomNodeID(): number
    return NodeIDs[math.random(1, #NodeIDs)]
end

local mobQuery = world:query(Mob):cached()
local function mobCount(): number
    local n = 0
    for _ in mobQuery do n += 1 end
    return n
end

-- ── Spawn one mob ───────────────────────────────────────────────────────────────
local spawnBatch: { blink.MobSpawn } = {}
local function spawnOne(tier: "normal" | "elite" | "boss", hp: number)
    local node = randomNodeID()
    local pos  = Waypoints[node][1] :: Vector3
    local size = if tier == "boss" then BOSS_SIZE elseif tier == "elite" then ELITE_SIZE else NORMAL_SIZE
    local speed = if tier == "boss" then BOSS_SPEED elseif tier == "elite" then ELITE_SPEED else ZOMBIE_SPEED

    local e = world:entity()
    world:add(e, Mob)
    world:set(e, Size, size)
    world:set(e, Speed, speed)
    world:set(e, MobType, ZOMBIE_TYPE)
    world:set(e, Transform, { new = CFrame.new(pos), old = CFrame.new(pos) })
    world:set(e, PathNode, node)
    world:set(e, Health, { hp = hp, max = hp })
    if tier == "elite" then world:add(e, Elite) end
    if tier == "boss" then world:add(e, Boss) end

    spawnBatch[#spawnBatch + 1] = { id = e, pos = pos, size = size, type = ZOMBIE_TYPE }
end
-- a UFO: flying ranged enemy. NO PathNode → horde.luau ignores it; ufo.luau drives it.
local function spawnUfo(tier: "normal" | "elite" | "boss", hp: number)
    local node = randomNodeID()
    local gp   = Waypoints[node][1] :: Vector3
    local pos  = gp + Vector3.new(0, UFO_HOVER, 0)
    local scale = if tier == "boss" then UFO_B_SCALE elseif tier == "elite" then UFO_E_SCALE else UFO_N_SCALE

    local e = world:entity()
    world:add(e, Mob)
    world:add(e, Flying)
    world:set(e, Size, scale)
    world:set(e, Speed, UFO_SPEED)
    world:set(e, MobType, UFO_TYPE)
    world:set(e, Transform, { new = CFrame.new(pos), old = CFrame.new(pos) })
    world:set(e, Health, { hp = hp, max = hp })
    if tier == "elite" then world:add(e, Elite) end
    if tier == "boss" then world:add(e, Boss) end

    spawnBatch[#spawnBatch + 1] = { id = e, pos = pos, size = scale, type = UFO_TYPE }
end

local function flushSpawn()
    if #spawnBatch > 0 then blink.Spawn.FireAll(spawnBatch); table.clear(spawnBatch) end
end

-- ── Wave state machine ──────────────────────────────────────────────────────────
local wave = 0
local running = false -- gated: the run only begins on the first Play / Restart (main menu)
local phase: "spawning" | "fighting" | "breather" = "breather"
local toSpawn, curHp, curEliteHp, curElites = 0, 0, 0, 0
local curBoss = false
local spawnAcc, fightTimer, breatherTimer = 0, 0, 0

local function startWave()
    wave += 1
    local size = math.min(MAX_ZOMBIES, BASE_WAVE + (wave - 1) * WAVE_GROW)
    curHp = ZOMBIE_HP * (1 + (wave - 1) * HP_GROWTH)
    curEliteHp = curHp * ELITE_HP_MUL
    curElites = if wave >= ELITE_FROM then 1 + wave // 4 else 0
    curBoss = (wave % BOSS_EVERY == 0) -- boss wave → drops a pet
    toSpawn = size
    spawnAcc = 0
    phase = "spawning"
    blink.WaveStart.FireAll(wave)
end

local function step(dt: number)
    if not running then return end -- waiting at the main menu
    if phase == "spawning" then
        spawnAcc += dt
        if spawnAcc >= SPAWN_EVERY then
            spawnAcc = 0
            local n = math.min(SPAWN_BATCH, toSpawn)
            for _ = 1, n do
                if wave >= UFO_FROM and math.random() < UFO_CHANCE then
                    spawnUfo("normal", curHp * UFO_N_HP) -- a stray flyer mixed into the horde
                else
                    spawnOne("normal", curHp)
                end
            end
            toSpawn -= n
            if toSpawn <= 0 then
                for _ = 1, curElites do
                    if math.random() < UFO_ELITE_CHANCE then spawnUfo("elite", curEliteHp * UFO_E_HP)
                    else spawnOne("elite", curEliteHp) end
                end
                if curBoss then
                    if math.random() < UFO_BOSS_CHANCE then spawnUfo("boss", curHp * BOSS_HP_MUL * UFO_B_HP)
                    else spawnOne("boss", curHp * BOSS_HP_MUL) end
                end
                phase = "fighting"
                fightTimer = 0
            end
            flushSpawn()
        end
    elseif phase == "fighting" then
        fightTimer += dt
        if mobCount() == 0 or fightTimer >= MAX_WAVE_TIME then
            phase = "breather"
            breatherTimer = BREATHER
        end
    else -- breather
        breatherTimer -= dt
        if breatherTimer <= 0 then startWave() end
    end
end

-- ── Public ────────────────────────────────────────────────────────────────────
local M = {}
function M.currentWave(): number
    return wave
end

-- wipe the field and restart waves (called on player restart)
function M.resetRun()
    local ids = {}
    for e in mobQuery do ids[#ids + 1] = e end
    for _, e in ids do world:delete(e) end
    if #ids > 0 then blink.Death.FireAll(ids) end
    running = true -- Play / Restart begins (or restarts) the run
    wave = 0
    startWave()
end

-- ── Late-joiner replay ──────────────────────────────────────────────────────────
local replayQuery = world:query(Transform, Size, MobType):with(Mob):cached()
local function sendAllMobsTo(player: Player)
    local payload: { blink.MobSpawn } = {}
    for e, transform, size, mobType in replayQuery do
        payload[#payload + 1] = { id = e, pos = transform.new.Position, size = size, type = mobType }
    end
    if #payload > 0 then blink.Spawn.Fire(player, payload) end
    blink.WaveStart.Fire(player, wave)
end

scheduler.SYSTEM(step, phases.Heartbeat)
scheduler.SYSTEM(sendAllMobsTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendAllMobsTo(p) end

-- NOTE: waves do NOT auto-start. The first Play/Restart (main menu → Restart event) calls
-- resetRun(), which sets running=true and starts wave 1.
return M
