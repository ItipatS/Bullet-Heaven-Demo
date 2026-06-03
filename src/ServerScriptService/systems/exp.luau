-- ServerScriptService/systems/exp.luau
-- EXP orbs: drop, spatial-hash PICKUP, and 5→1 tier MERGING (keeps the orb count low so the
-- client doesn't choke on thousands of parts). Tiers: 1 green(1) → 2 blue(5) → 3 orange(25)
-- → 4 purple(125). Exposes M.drop() for combat to call on a kill.
--!optimize 2
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink = require(ServerScriptService.ServerNet)
local std   = ReplicatedStorage.std

local scheduler   = require(std.scheduler)
local phases      = require(std.phases)
local SpatialHash = require(std.spatialhash)
local Progress    = require(script.Parent.progression)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local PICKUP_RADIUS = 7
local PICKUP_R2     = PICKUP_RADIUS * PICKUP_RADIUS
local MERGE_RADIUS  = 4
local MERGE_R2      = MERGE_RADIUS * MERGE_RADIUS
local MERGE_COUNT   = 5
local MAX_TIER      = 4
local HASH_CELL     = 8
local EXP_TICK      = 1 / 10
local TIER_VALUE    = { 1, 5, 25, 125 }

-- ── State ─────────────────────────────────────────────────────────────────────
type Orb = { id: number, x: number, y: number, z: number, tier: number }
local orbs: { [number]: Orb } = {}
local nextOrbId = 0

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace:WaitForChild("Map") }
groundParams.IgnoreWater = true
local function groundY(x: number, z: number): number?
    local hit = workspace:Raycast(Vector3.new(x, 1024, z), Vector3.new(0, -4096, 0), groundParams)
    return hit and hit.Position.Y or nil
end

-- ── Batched net out ─────────────────────────────────────────────────────────────
local spawnBatch: { blink.ExpSpawn } = {}
local removeBatch: { number } = {}
local function emitSpawn(o: Orb)
    spawnBatch[#spawnBatch + 1] = { id = o.id, pos = Vector3.new(o.x, o.y, o.z), tier = o.tier }
end
local function emitRemove(id: number)
    removeBatch[#removeBatch + 1] = id
end
local function flush()
    if #spawnBatch > 0 then blink.SpawnExp.FireAll(spawnBatch); table.clear(spawnBatch) end
    if #removeBatch > 0 then blink.RemoveExp.FireAll(removeBatch); table.clear(removeBatch) end
end

-- ── Public: drop `count` tier-1 orbs around (x,z) ────────────────────────────────
local M = {}
function M.drop(x: number, z: number, count: number)
    for _ = 1, count do
        nextOrbId += 1
        local ox = x + (math.random() * 3 - 1.5)
        local oz = z + (math.random() * 3 - 1.5)
        local oy = (groundY(ox, oz) or 0) + 1
        local o: Orb = { id = nextOrbId, x = ox, y = oy, z = oz, tier = 1 }
        orbs[nextOrbId] = o
        emitSpawn(o)
    end
    flush()
end

-- ── Pickup + merge tick ──────────────────────────────────────────────────────────
local function rebuildHash()
    hash:beginFrame()
    for id, o in orbs do
        hash:insert(id, o.x, o.y, o.z)
    end
end

local function pickupStep()
    rebuildHash()
    local xpByPlayer: { [Player]: number } = {}
    for _, plr in Players:GetPlayers() do
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local rp = (root :: BasePart).Position
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local o = orbs[id]
            if o then
                local dx, dz = o.x - rp.X, o.z - rp.Z
                if dx * dx + dz * dz <= PICKUP_R2 then -- XZ proximity (forgiving on height)
                    xpByPlayer[plr] = (xpByPlayer[plr] or 0) + (TIER_VALUE[o.tier] or 1)
                    orbs[id] = nil
                    emitRemove(id)
                end
            end
        end
    end
    for plr, xp in xpByPlayer do
        Progress.addXp(plr, xp)
    end
end

local group: { number } = {}
local function mergeStep()
    rebuildHash() -- fresh after pickup removed some
    local consumed: { [number]: boolean } = {}
    type Grp = { ids: { number }, tier: number }
    local groups: { Grp } = {}

    -- PHASE 1: find merge groups WITHOUT mutating `orbs` (unsafe to edit mid-iteration)
    for id, o in orbs do
        if consumed[id] or o.tier >= MAX_TIER then continue end
        local cnt = hash:queryInto(o.x, o.y, o.z, out)
        table.clear(group)
        group[1] = id
        for j = 1, cnt do
            if #group >= MERGE_COUNT then break end
            local cid = out[j]
            local c = orbs[cid]
            if c and cid ~= id and not consumed[cid] and c.tier == o.tier then
                local dx, dz = c.x - o.x, c.z - o.z
                if dx * dx + dz * dz <= MERGE_R2 then
                    group[#group + 1] = cid
                end
            end
        end
        if #group >= MERGE_COUNT then
            local ids = table.clone(group)
            for _, gid in ids do consumed[gid] = true end
            groups[#groups + 1] = { ids = ids, tier = o.tier }
        end
    end

    -- PHASE 2: apply (mutate `orbs` now that iteration is done)
    for _, grp in groups do
        local cx, cy, cz, n = 0, 0, 0, #grp.ids
        for _, gid in grp.ids do
            local g = orbs[gid]
            if g then
                cx += g.x; cy += g.y; cz += g.z
                orbs[gid] = nil
                emitRemove(gid)
            end
        end
        nextOrbId += 1
        local no: Orb = { id = nextOrbId, x = cx / n, y = cy / n, z = cz / n, tier = grp.tier + 1 }
        orbs[no.id] = no
        emitSpawn(no)
    end
end

local acc = 0
local function expWrapper(dt: number)
    acc += dt
    if acc < EXP_TICK then return end
    acc = 0
    pickupStep()
    mergeStep()
    flush()
end

-- replay orbs to a joining player
local function sendOrbsTo(player: Player)
    local batch: { blink.ExpSpawn } = {}
    for _id, o in orbs do
        batch[#batch + 1] = { id = o.id, pos = Vector3.new(o.x, o.y, o.z), tier = o.tier }
    end
    if #batch > 0 then blink.SpawnExp.Fire(player, batch) end
end

scheduler.SYSTEM(expWrapper, phases.Inventory)
scheduler.SYSTEM(sendOrbsTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendOrbsTo(p) end

return M
