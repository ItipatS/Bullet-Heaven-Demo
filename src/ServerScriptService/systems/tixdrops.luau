-- ServerScriptService/systems/tixdrops.luau
-- Tix currency pickups (the META currency). A drop carries an AMOUNT (its tix value); the client
-- picks which Assets model to render from that amount (≤5 Tix, ≤20 PileofTix, else StackofTix).
-- Players walk over them (proximity, scaled by pickupRange) to bank the amount into the persisted
-- profile (survives a run restart). Exposes drop(x,z,amount), maybeDrop(x,z), clearAll.
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
local Profile     = require(script.Parent.profile)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local DROP_CHANCE   = 0.07  -- per normal-mob kill
local PICKUP_RADIUS = 7     -- base; ×player.pickupRange
local HASH_CELL     = 8
local DROP_TICK     = 1 / 10
local FLOAT_Y       = 2

-- ── State ─────────────────────────────────────────────────────────────────────
type Drop = { id: number, x: number, y: number, z: number, amount: number }
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

-- ── Public ────────────────────────────────────────────────────────────────────
local M = {}
-- drop `amount` tix at (x,z). amount drives both the value and (client-side) the model tier.
function M.drop(x: number, z: number, amount: number)
    if amount <= 0 then return end
    nextId += 1
    local d: Drop = { id = nextId, x = x, y = groundY(x, z), z = z, amount = amount }
    drops[nextId] = d
    blink.TixSpawn.FireAll({ { id = d.id, pos = Vector3.new(d.x, d.y, d.z), amount = amount } })
end

-- normal kill: small chance of a few tix (lands in the Tix tier)
function M.maybeDrop(x: number, z: number)
    if math.random() < DROP_CHANCE then M.drop(x, z, math.random(1, 5)) end
end

-- ── Pickup tick (proximity, radius scaled by pickupRange) ─────────────────────────
local removeBatch: { number } = {}
local function pickupStep()
    if next(drops) == nil then return end
    hash:beginFrame()
    for id, d in drops do hash:insert(id, d.x, d.y, d.z) end

    for _, plr in Players:GetPlayers() do
        local state = PlayerState.get(plr)
        if state.dead then continue end
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local rp = (root :: BasePart).Position
        local r = PICKUP_RADIUS * state.pickupRange
        local r2 = r * r
        local gained = 0
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local d = drops[id]
            if d then
                local dx, dz = d.x - rp.X, d.z - rp.Z
                if dx * dx + dz * dz <= r2 then
                    drops[id] = nil
                    removeBatch[#removeBatch + 1] = id
                    gained += d.amount
                end
            end
        end
        if gained > 0 then
            Profile.addTix(plr, gained) -- updates profile + run mirror + fires TixCount
        end
    end
    if #removeBatch > 0 then blink.TixRemove.FireAll(removeBatch); table.clear(removeBatch) end
end

-- wipe all uncollected tix drops on a run restart (banked tix is kept in PlayerState)
function M.clearAll()
    local ids = {}
    for id in drops do ids[#ids + 1] = id end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.TixRemove.FireAll(ids) end
end

local acc = 0
local function wrapper(dt: number)
    acc += dt
    if acc < DROP_TICK then return end
    acc = 0
    pickupStep()
end

-- replay active drops + send the current balance to a joining player
local function sendTo(player: Player)
    local batch: { blink.TixDrop } = {}
    for _id, d in drops do
        batch[#batch + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z), amount = d.amount }
    end
    if #batch > 0 then blink.TixSpawn.Fire(player, batch) end
    blink.TixCount.Fire(player, PlayerState.get(player).tix)
end

scheduler.SYSTEM(wrapper, phases.Inventory)
scheduler.SYSTEM(sendTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendTo(p) end

return M
