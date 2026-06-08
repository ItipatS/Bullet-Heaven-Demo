-- ServerScriptService/systems/petdrops.luau
-- PET pickups — the ONLY way to gain a new pet. A slain boss calls M.dropBoss(x,z); we pick a
-- pet nobody owns yet (so it's meaningful), resolve its floor Y once, and replicate it as a
-- floating world model. Players walk over it (spatial-hash proximity, same as EXP) to collect:
-- the pet unlocks (auto-equip or bench) and a Toast announces it. Exposes dropBoss + clearAll.
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
local Registry    = require(std.petRegistry)
local PlayerState = require(std.playerState)
local Progress    = require(script.Parent.progression)

-- ── Tunables ──────────────────────────────────────────────────────────────────
local PICKUP_RADIUS = 7
local PICKUP_R2     = PICKUP_RADIUS * PICKUP_RADIUS
local HASH_CELL     = 8
local DROP_TICK     = 1 / 10
local DUP_XP        = 40   -- consolation XP if you already own the dropped pet
local FLOAT_Y       = 3    -- centre height above the floor (client floats it further)

-- ── State ─────────────────────────────────────────────────────────────────────
type Drop = { id: number, x: number, y: number, z: number, pet: string }
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

-- ── Pet choice: prefer one nobody owns yet ────────────────────────────────────────
local function pickPet(): string
    local ownedByAll: { [string]: boolean } = {}
    for _, plr in Players:GetPlayers() do
        for _, id in PlayerState.ownedIds(plr) do ownedByAll[id] = true end
    end
    local fresh: { string } = {}
    for _, id in Registry.order do
        if not ownedByAll[id] then fresh[#fresh + 1] = id end
    end
    if #fresh > 0 then return fresh[math.random(1, #fresh)] end
    return Registry.order[math.random(1, #Registry.order)] -- everyone owns everything → dup
end

-- ── Net out ─────────────────────────────────────────────────────────────────────
local function emitSpawn(d: Drop)
    blink.PetDropSpawn.FireAll({ { id = d.id, pos = Vector3.new(d.x, d.y, d.z), pet = d.pet } })
end

-- ── Public ────────────────────────────────────────────────────────────────────────
local ELITE_PET_CHANCE = 0.2 -- an elite UNCOMMONLY drops a pet
local M = {}

-- drop a pet pickup at (x,z) — prefers one nobody owns yet (a meaningful unlock)
function M.dropBoss(x: number, z: number)
    nextId += 1
    local d: Drop = { id = nextId, x = x, y = groundY(x, z), z = z, pet = pickPet() }
    drops[nextId] = d
    emitSpawn(d)
end

-- elite death: an uncommon chance to drop a pet
function M.maybeDropElite(x: number, z: number)
    if math.random() < ELITE_PET_CHANCE then M.dropBoss(x, z) end
end

-- ── Pickup tick (proximity) ───────────────────────────────────────────────────────
local removeBatch: { number } = {}
local function pickupStep()
    if next(drops) == nil then return end
    hash:beginFrame()
    for id, d in drops do hash:insert(id, d.x, d.y, d.z) end

    for _, plr in Players:GetPlayers() do
        local state = PlayerState.get(plr)
        if not state.playing then continue end
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then continue end
        local rp = (root :: BasePart).Position
        local cnt = hash:queryInto(rp.X, rp.Y, rp.Z, out)
        for j = 1, cnt do
            local id = out[j]
            local d = drops[id]
            if d then
                local dx, dz = d.x - rp.X, d.z - rp.Z
                if dx * dx + dz * dz <= PICKUP_R2 then
                    drops[id] = nil
                    removeBatch[#removeBatch + 1] = id
                    local pet = Registry.pets[d.pet]
                    local name = (pet and pet.name) or d.pet
                    -- pickup UNLOCKS the pet in the collection (pet tab) AND adds it to the current run
                    local isNew = PlayerState.ownPet(plr, d.pet)
                    local added = PlayerState.addToRun(plr, d.pet)
                    if isNew then
                        blink.Toast.Fire(plr, "New pet: " .. name .. "!  ★ unlocked + joined")
                    elseif added then
                        blink.Toast.Fire(plr, name .. " joined your run!")
                    else
                        Progress.addXp(plr, DUP_XP) -- already in the run → consolation XP
                        blink.Toast.Fire(plr, name .. " — +" .. DUP_XP .. " XP")
                    end
                    if isNew or added then Progress.pushLoadout(plr) end
                end
            end
        end
    end
    if #removeBatch > 0 then blink.PetDropRemove.FireAll(removeBatch); table.clear(removeBatch) end
end

-- wipe all pet drops (called on a run restart)
function M.clearAll()
    local ids = {}
    for id in drops do ids[#ids + 1] = id end
    for _, id in ids do drops[id] = nil end
    if #ids > 0 then blink.PetDropRemove.FireAll(ids) end
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
    local batch: { blink.PetDrop } = {}
    for _id, d in drops do
        batch[#batch + 1] = { id = d.id, pos = Vector3.new(d.x, d.y, d.z), pet = d.pet }
    end
    if #batch > 0 then blink.PetDropSpawn.Fire(player, batch) end
end

scheduler.SYSTEM(wrapper, phases.Inventory)
scheduler.SYSTEM(sendTo, phases.PlayerAdded)
for _, p in Players:GetPlayers() do sendTo(p) end

return M
