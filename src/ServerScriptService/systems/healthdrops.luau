-- ServerScriptService/systems/healthdrops.luau
-- Heart pickups. A slain mob has a small chance to drop one (combat calls M.maybeDrop). Players
-- walk over it (spatial-hash proximity, radius scaled by the player's pickupRange stat) to heal
-- HEAL_AMOUNT. Static; Y resolved to the floor once at drop. Exposes maybeDrop + clearAll.
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
local PlayerState = require(std.playerState)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local DROP_CHANCE   = 0.03  -- per normal-mob kill
local HEAL_AMOUNT   = 25
local PICKUP_RADIUS = 7     -- base; ×player.pickupRange
local HASH_CELL     = 8
local DROP_TICK     = 1 / 10
local FLOAT_Y       = 2

-- ── State ─────────────────────────────────────────────────────────────────────
type Drop = { id: number, x: number, y: number, z: number }
local drops: { [number]: Drop } = {}
local nextId = 0

local hash = SpatialHash.new(HASH_CELL)
local out: { number } = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace:WaitForChild("Map") }
groundParams.IgnoreWater = true
local function groundY(x: number, z: number): number
    local hit = workspace:Raycast(Vector3.new(x, 1024, z), Vector3.new(0, -4096, 0), groundParams)
    return (hit and hit.Position.Y or 0) + FLOAT_Y
end

-- ── Public: a mob died at (x,z) → maybe drop a heart ──────────────────────────────
local M = {}
function M.maybeDrop(x: number, z: number)
    if math.random() >= DROP_CHANCE then return end
    nextId += 1
    local d: Drop = { id = nextId, x = x, y = groundY(x, z), z = z }
    drops[nextId] = d
    blink.HealthSpawn.FireAll({ { id = d.id, pos = Vector3.new(d.x, d.y, d.z) } })
end

-- ── Pickup tick (proximity, radius scaled by pickupRange) ─────────────────────────
local removeBatch: { number } = {}
local function pickupStep()
    if next(drops) == nil then return end
    hash:beginFrame()
    for id, d in drops do hash:insert(id, d.x, d.y, d.z) end

    for _, plr in Players:GetPlayers() do
        local state = PlayerState.get(plr)
        if state.dead or state.hp >= state.maxHp then continue end -- no need if full
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local rp = (root :: BasePart).Position
        local r = PICKUP_RADIUS * state.pickupRange
        local r2 = r * r
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local d = drops[id]
            if d then
                local dx, dz = d.x - rp.X, d.z - rp.Z
                if dx * dx + dz * dz <= r2 then
                    drops[id] = nil
                    removeBatch[#removeBatch + 1] = id
                    state.hp = math.min(state.maxHp, state.hp + HEAL_AMOUNT)
                end
            end
        end
    end
    if #removeBatch > 0 then blink.HealthRemove.FireAll(removeBatch); table.clear(removeBatch) end
end

-- wipe all heart drops (called on a run restart)
function M.clearAll()
    local ids = {}
    for id in drops do ids[#ids + 1] = id end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.HealthRemove.FireAll(ids) end
end

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < DROP_TICK then return end
    acc = 0
    pickupStep()
end

-- replay active drops to a joining player
local function sendTo(player: Player)
    local batch: { blink.HealthDrop } = {}
    for _id, d in drops do
        batch[#batch + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z) }
    end
    if #batch > 0 then blink.HealthSpawn.Fire(player, batch) end
end

scheduler.SYSTEM(wrapper, phases.Inventory)
scheduler.SYSTEM(sendTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendTo(p) end

return M
