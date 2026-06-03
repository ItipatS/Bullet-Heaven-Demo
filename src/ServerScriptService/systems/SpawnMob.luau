-- ServerScriptService/systems/SpawnMob.luau
-- HYBRID spawner: a continuous baseline of slimes whose HP ramps with run time, PLUS periodic
-- ELITES (tanky, bigger) that drop a reward card on death (see combat.luau). Pure ECS data;
-- horde.luau moves them, syncMobs renders them.
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

local Waypoints = pathData[1]

-- ── Tunables ──────────────────────────────────────────────────────────────────
local ZOMBIE_TYPE  = "Zombie"
local ZOMBIE_SPEED = 9
local ZOMBIE_HP    = 30
local NORMAL_SIZE  = 1
local SPAWN_EVERY  = 0.1
local SPAWN_BATCH  = 20
local MAX_ZOMBIES  = 3000

-- difficulty ramp + elites
local DIFF_EVERY   = 25       -- seconds per difficulty step
local HP_GROWTH    = 0.4      -- +40% base HP per step
local ELITE_EVERY  = 20       -- seconds between elite spawns
local ELITE_HP_MUL = 12
local ELITE_SIZE   = 2.6
local ELITE_SPEED  = 7

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
local function spawnOne(isElite: boolean, hp: number)
    local node = randomNodeID()
    local pos  = Waypoints[node][1] :: Vector3
    local size = if isElite then ELITE_SIZE else NORMAL_SIZE

    local e = world:entity()
    world:add(e, Mob)
    world:set(e, Size, size)
    world:set(e, Speed, if isElite then ELITE_SPEED else ZOMBIE_SPEED)
    world:set(e, MobType, ZOMBIE_TYPE)
    world:set(e, Transform, { new = CFrame.new(pos), old = CFrame.new(pos) })
    world:set(e, PathNode, node)
    world:set(e, Health, { hp = hp, max = hp })
    if isElite then world:add(e, Elite) end

    spawnBatch[#spawnBatch + 1] = { id = e, pos = pos, size = size, type = ZOMBIE_TYPE }
end

-- ── Spawn loop ────────────────────────────────────────────────────────────────
local runClock, spawnAcc, eliteAcc = 0, 0, 0

local function spawnZombies(dt: number)
    runClock += dt
    spawnAcc += dt
    eliteAcc += dt

    local diff = math.floor(runClock / DIFF_EVERY)
    local baseHp = ZOMBIE_HP * (1 + diff * HP_GROWTH)

    if spawnAcc >= SPAWN_EVERY then
        spawnAcc = 0
        local toSpawn = math.min(SPAWN_BATCH, MAX_ZOMBIES - mobCount())
        for _ = 1, toSpawn do
            spawnOne(false, baseHp)
        end
    end

    if eliteAcc >= ELITE_EVERY and mobCount() < MAX_ZOMBIES then
        eliteAcc = 0
        spawnOne(true, baseHp * ELITE_HP_MUL)
    end

    if #spawnBatch > 0 then
        blink.Spawn.FireAll(spawnBatch)
        table.clear(spawnBatch)
    end
end

-- ── Late-joiner replay (just positions + size; horde streams movement) ───────────
local replayQuery = world:query(Transform, Size, MobType):with(Mob):cached()
local function sendAllMobsTo(player: Player)
    local payload: { blink.MobSpawn } = {}
    for e, transform, size, mobType in replayQuery do
        payload[#payload + 1] = { id = e, pos = transform.new.Position, size = size, type = mobType }
    end
    if #payload > 0 then blink.Spawn.Fire(player, payload) end
end

scheduler.SYSTEM(spawnZombies, phases.Heartbeat)
scheduler.SYSTEM(sendAllMobsTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendAllMobsTo(p) end

return {}
