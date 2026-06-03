-- ServerScriptService/systems/progression.luau
-- XP/leveling + the card picker. Cards are mostly GLOBAL player-stat upgrades (overall
-- damage, crit), with WEAPON-specific upgrades mixed in (tagged with the weapon's name so the
-- UI can show which weapon it boosts). exp.luau calls addXp on pickup; combat.luau calls
-- offerReward when an elite/boss dies (an extra free pick). Exposes addXp + offerReward.
--!strict

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players             = game:GetService("Players")

local blink       = require(ServerScriptService.ServerNet)
local std         = ReplicatedStorage.std
local PlayerState = require(std.playerState)
local Registry    = require(std.petRegistry)
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)

local M = {}

-- ctype = "player" | "petstat" | "perk" | "new"  (drives the card's category label)
type Card = { ctype: string, title: string, desc: string, weapon: string, apply: (any) -> () }

-- GLOBAL player-stat upgrades (pet stats & perks come from the registry per equipped pet)
local GLOBAL = {
    { title = "Power",        desc = "+5% overall damage", apply = function(s) s.damageMult += 0.05 end },
    { title = "Precision",    desc = "+5% crit chance",     apply = function(s) s.critChance += 0.05 end },
    { title = "Brutality",    desc = "+0.5 crit damage",    apply = function(s) s.critDamage += 0.5 end },
    { title = "Haste",        desc = "-10% all fire rate",  apply = function(s) for _, w in s.weapons do w.fireCd = math.max(0.08, w.fireCd * 0.9) end end },
    { title = "Vitality",     desc = "+25 max HP (heals)",  apply = function(s) s.maxHp += 25; s.hp = math.min(s.maxHp, s.hp + 25) end },
    { title = "Regeneration", desc = "+0.25 HP/sec regen",     apply = function(s) s.hpRegen += 0.25 end },
    { title = "Magnetism",    desc = "+25% pickup range",   apply = function(s) s.pickupRange += 0.25 end },
    { title = "Fleet Foot",   desc = "+1 walk speed",       apply = function(s) s.walkSpeed += 1 end },
}

local function xpCurve(level: number): number
    return 5 + (level - 1) * 4
end

local pending: { [Player]: { Card } } = {} -- the 3 cards currently offered (server keeps the apply fns)
local pendingCount: { [Player]: number } = {}

local function sendStats(plr: Player)
    blink.Stats.Fire(plr, PlayerState.statsMsg(plr))
end

local function sendWeapons(plr: Player)
    local ids = {}
    for _, w in PlayerState.get(plr).weapons do ids[#ids + 1] = w.id end
    blink.Weapons.Fire(plr, ids)
end

local function sendUnlocked(plr: Player)
    blink.Unlocked.Fire(plr, PlayerState.ownedIds(plr))
end

local function rollCards(state: any): { Card }
    local cand: { Card } = {}
    -- player-global stats
    for _, g in GLOBAL do
        cand[#cand + 1] = { ctype = "player", title = g.title, desc = g.desc, weapon = "", apply = g.apply }
    end
    -- per equipped pet: its registry perks (kind "stat" → pet-stat card, "perk" → perk card)
    for i, w in state.weapons do
        local wi = i
        local pet = Registry.pets[w.id]
        if pet then
            for _, perk in pet.perks do
                local pApply = perk.apply
                cand[#cand + 1] = {
                    ctype = if perk.kind == "perk" then "perk" else "petstat",
                    title = perk.title, desc = perk.desc, weapon = pet.name,
                    apply = function(s) local ww = s.weapons[wi]; if ww then pApply(ww) end end,
                }
            end
        end
    end
    -- NOTE: new pets are NOT offered as cards — they drop ONLY from bosses (see petdrops.luau).
    local picks: { Card } = {}
    for _ = 1, 3 do
        if #cand == 0 then break end
        local idx = math.random(1, #cand)
        picks[#picks + 1] = cand[idx]
        table.remove(cand, idx)
    end
    return picks
end

local function offerNext(plr: Player)
    if pending[plr] then return end
    if (pendingCount[plr] or 0) <= 0 then return end
    pendingCount[plr] -= 1
    local picks = rollCards(PlayerState.get(plr))
    pending[plr] = picks
    -- wire kind: 0 player stat, 1 pet stat, 2 perk, 3 new pet (drives the card's category tag)
    local KIND = { player = 0, petstat = 1, perk = 2, new = 3 }
    local cards = {}
    for i, c in picks do
        cards[i] = { id = i, title = c.title, desc = c.desc, kind = KIND[c.ctype] or 0, weapon = c.weapon }
    end
    blink.LevelUp.Fire(plr, cards)
end

function M.addXp(plr: Player, amount: number)
    local s = PlayerState.get(plr)
    s.xp += amount
    while s.xp >= s.xpNext do
        s.xp -= s.xpNext
        s.level += 1
        s.xpNext = xpCurve(s.level)
        pendingCount[plr] = (pendingCount[plr] or 0) + 1
    end
    offerNext(plr)
    sendStats(plr)
end

-- elite/boss reward: a free upgrade pick
function M.offerReward(plr: Player)
    pendingCount[plr] = (pendingCount[plr] or 0) + 1
    offerNext(plr)
end

-- push the equipped + owned pet lists to a player (e.g. after a boss-dropped pet unlock)
function M.pushLoadout(plr: Player)
    sendWeapons(plr)
    sendUnlocked(plr)
end

-- clear pending offers on a fresh run (PlayerState is reset by the caller), refresh the HUD
function M.resetPlayer(plr: Player)
    pending[plr] = nil
    pendingCount[plr] = nil
    sendStats(plr)
    sendWeapons(plr)
    sendUnlocked(plr)
end

blink.ChooseCard.On(function(plr, idx)
    local offered = pending[plr]
    if not offered then return end
    local c = offered[idx]
    if not c then return end
    c.apply(PlayerState.get(plr))
    pending[plr] = nil
    sendWeapons(plr) -- a stat/perk may have changed a pet's stats
    sendUnlocked(plr)
    offerNext(plr) -- next queued pick, if any
    sendStats(plr)
end)

blink.SwitchWeapons.On(function(plr, ids)
    PlayerState.setEquipped(plr, ids)
    sendWeapons(plr)  -- equipped changed → pets update
    sendUnlocked(plr)
end)

Players.PlayerRemoving:Connect(function(plr)
    pending[plr] = nil
    pendingCount[plr] = nil
    PlayerState.remove(plr)
end)

-- send initial HUD + weapon list on join
local function onJoin(plr: Player)
    sendStats(plr)
    sendWeapons(plr)
    sendUnlocked(plr)
end
scheduler.SYSTEM(onJoin, phases.PlayerAdded)
for _, p in Players:GetPlayers() do onJoin(p) end

return M
