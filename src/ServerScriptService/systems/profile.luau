-- ServerScriptService/systems/profile.luau
-- DataStore persistence for the META profile: the player's Tix balance + lifetime/best stats
-- (bestWave, bestLevel, bestTime, totalKills, runs). NOT the in-run stats — those are ephemeral
-- (playerState.reset wipes them every run). Tix is routed through here so it's always current at
-- save time (no dependency on PlayerState during PlayerRemoving, which may clear first).
--
-- Load on join (async, own thread), autosave every 60s, save on leave + BindToClose. All
-- DataStore calls YIELD and are pcall-wrapped — if a load FAILS we never save (so a transient
-- read error can't clobber real data with defaults). Exposes get/addTix/addKills/recordRun.
--
-- NOTE: requires "Enable Studio Access to API Services" (Game Settings → Security) to work in
-- Studio; otherwise it degrades to in-memory (loads defaults, never saves).
--!strict

local DataStoreService     = game:GetService("DataStoreService")
local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local ServerScriptService  = game:GetService("ServerScriptService")

local blink       = require(ServerScriptService.ServerNet)
local PlayerState = require(ReplicatedStorage.std.playerState)
local Registry    = require(ReplicatedStorage.std.petRegistry) -- pet prices for the Tix shop
local Progress    = require(script.Parent.progression) -- to push the loaded collection to the client

local STORE = DataStoreService:GetDataStore("PlayerProfile_v1")
local AUTOSAVE = 60

type Profile = {
    tix: number, bestWave: number, bestLevel: number,
    bestTime: number, totalKills: number, runs: number,
    pets: { [string]: boolean }, -- owned pet COLLECTION (pet tab); starts with the 3 starters
    squad: { string },           -- the chosen run squad (ordered, slot1 = main), picked at the menu
}
local DEFAULT: Profile = { tix = 0, bestWave = 0, bestLevel = 1, bestTime = 0, totalKills = 0, runs = 0,
    pets = { axolotl = true, fox = true, slime = true }, squad = { "axolotl" } }
local STARTERS = { "axolotl", "fox", "slime" } -- granted to a brand-new profile

local profiles: { [Player]: Profile } = {}
local canSave:  { [Player]: boolean } = {} -- only true once a load SUCCEEDS (don't clobber on read fail)

local function keyFor(plr: Player): string
    return "u_" .. plr.UserId
end

local M = {}

function M.get(plr: Player): Profile?
    return profiles[plr]
end

local function sendProfile(plr: Player)
    local p = profiles[plr]
    if not p then return end
    blink.Profile.Fire(plr, {
        tix = math.floor(p.tix), bestWave = p.bestWave, bestLevel = p.bestLevel,
        bestTime = math.floor(p.bestTime), totalKills = p.totalKills, runs = p.runs,
    })
end

-- ── load / save ─────────────────────────────────────────────────────────────────
local function load(plr: Player)
    local data
    local ok = pcall(function() data = STORE:GetAsync(keyFor(plr)) end)
    local p = table.clone(DEFAULT)
    p.pets = { axolotl = true, fox = true, slime = true } -- fresh copy (table.clone is shallow)
    p.squad = { "axolotl" }
    if ok and type(data) == "table" then
        for k in DEFAULT do
            if type(data[k]) == "number" then p[k] = data[k] end
        end
        if type(data.pets) == "table" then
            p.pets = {}
            for id, v in data.pets do if v == true then p.pets[id] = true end end
            for _, id in STARTERS do p.pets[id] = true end -- always grant the starters
        end
        if type(data.squad) == "table" then
            p.squad = {}
            for _, id in data.squad do if type(id) == "string" then p.squad[#p.squad + 1] = id end end
        elseif type(data.starter) == "string" then
            p.squad = { data.starter } -- migrate old single-starter profiles
        end
    end
    if #p.squad == 0 then p.squad = { "axolotl" } end
    profiles[plr] = p
    canSave[plr] = ok
    -- seed the live state: balance + owned COLLECTION + chosen squad, then push to the client
    local s = PlayerState.get(plr)
    s.tix = p.tix
    s.owned = p.pets -- share the ref so drop/shop unlocks land straight in the persisted table
    PlayerState.setSquad(plr, p.squad) -- validate (owned/cap) + build the run loadout
    blink.TixCount.Fire(plr, math.floor(p.tix))
    sendProfile(plr)
    Progress.pushLoadout(plr) -- send the collection (Unlocked) + squad (Weapons/Main)
end

local function save(plr: Player)
    local p = profiles[plr]
    if not p or not canSave[plr] then return end -- never overwrite real data after a failed load
    local s = PlayerState.get(plr)
    p.pets = s.owned    -- snapshot the live collection (drop/shop unlocks)
    p.squad = s.squad   -- and the chosen squad
    pcall(function()
        STORE:UpdateAsync(keyFor(plr), function()
            return p -- p.tix is kept current by M.addTix, so this is safe even mid-leave
        end)
    end)
end

-- ── mutations (route all tix + stat changes here) ─────────────────────────────────
function M.addTix(plr: Player, amount: number): number
    local p = profiles[plr]
    local total
    if p then
        p.tix += amount
        total = p.tix
    else
        total = PlayerState.addTix(plr, amount) -- profile not loaded yet (rare)
    end
    PlayerState.get(plr).tix = total -- keep the in-run mirror in sync
    blink.TixCount.Fire(plr, math.floor(total))
    return total
end

function M.addKills(plr: Player, n: number)
    local p = profiles[plr]
    if p then p.totalKills += n end
end

-- Tix shop (menu): buy a locked pet. Validates balance, deducts (persisted), unlocks the collection.
blink.BuyPet.On(function(plr, petId)
    if PlayerState.get(plr).playing then return end -- shop is menu-only
    local pet = Registry.pets[petId]
    if not pet then return end
    local s = PlayerState.get(plr)
    if s.owned[petId] then return end -- already owned
    local price = pet.price or 0
    if price <= 0 or s.tix < price then return end -- not for sale / can't afford
    M.addTix(plr, -price) -- deduct (updates profile + mirror + fires TixCount)
    PlayerState.ownPet(plr, petId) -- s.owned shares the persisted p.pets ref
    Progress.pushLoadout(plr) -- resend Unlocked (the pet tab refreshes)
    blink.Toast.Fire(plr, "Unlocked " .. pet.name .. "!")
end)

function M.recordRun(plr: Player, wave: number, level: number, time: number)
    local p = profiles[plr]
    if not p then return end
    p.runs += 1
    p.bestWave = math.max(p.bestWave, wave)
    p.bestLevel = math.max(p.bestLevel, level)
    p.bestTime = math.max(p.bestTime, time)
    sendProfile(plr)
    task.spawn(save, plr) -- persist the run result promptly (own thread; SetAsync yields)
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(plr) task.spawn(load, plr) end)
for _, plr in Players:GetPlayers() do task.spawn(load, plr) end

Players.PlayerRemoving:Connect(function(plr)
    save(plr)
    profiles[plr] = nil
    canSave[plr] = nil
end)

task.spawn(function()
    while true do
        task.wait(AUTOSAVE)
        for _, plr in Players:GetPlayers() do save(plr) end
    end
end)

game:BindToClose(function()
    for _, plr in Players:GetPlayers() do task.spawn(save, plr) end
    task.wait(2) -- give the writes a moment to flush
end)

return M
