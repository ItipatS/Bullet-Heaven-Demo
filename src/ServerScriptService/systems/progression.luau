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
local scheduler   = require(std.scheduler)
local phases      = require(std.phases)

local M = {}

local WEAPON_DESC = {
    axolotl = "Piercing bubbles",
    fox     = "Rapid 3-shot scatter",
}

type Card = { kind: string, title: string, desc: string, weapon: string, apply: (any) -> () }

-- GLOBAL player-stat upgrades
local GLOBAL = {
    { title = "Power",     desc = "+15% overall damage", apply = function(s) s.damageMult += 0.15 end },
    { title = "Precision", desc = "+5% crit chance",     apply = function(s) s.critChance += 0.05 end },
    { title = "Brutality", desc = "+0.5 crit damage",    apply = function(s) s.critDamage += 0.5 end },
    { title = "Haste",     desc = "-10% all fire rate",  apply = function(s) for _, w in s.weapons do w.fireCd = math.max(0.08, w.fireCd * 0.9) end end },
}

-- WEAPON-specific upgrade templates (apply to ONE weapon)
local WEAPON = {
    { title = "Sharpen", desc = "+5 damage",        apply = function(w) w.dmg += 5 end },
    { title = "Pierce",  desc = "+1 pierce",        apply = function(w) w.pierce += 1 end },
    { title = "Enlarge", desc = "+0.8 radius",      apply = function(w) w.radius += 0.8 end },
    { title = "Quicken", desc = "-12% fire cooldown", apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.88) end },
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

local function rollCards(state: any): { Card }
    local cand: { Card } = {}
    for _, g in GLOBAL do
        cand[#cand + 1] = { kind = "global", title = g.title, desc = g.desc, weapon = "", apply = g.apply }
    end
    for i, w in state.weapons do
        local wi = i
        for _, t in WEAPON do
            local tApply = t.apply
            cand[#cand + 1] = {
                kind = "weapon", title = t.title, desc = t.desc, weapon = w.name,
                apply = function(s) local ww = s.weapons[wi]; if ww then tApply(ww) end end,
            }
        end
    end
    -- "New Weapon" offers (a free slot + a weapon you don't own yet)
    if #state.weapons < PlayerState.MAX_WEAPONS then
        local owned = {}
        for _, w in state.weapons do owned[w.id] = true end
        for _, id in PlayerState.ALL_WEAPONS do
            if not owned[id] then
                local proto = PlayerState.makeWeapon(id)
                if proto then
                    local wid = id
                    cand[#cand + 1] = {
                        kind = "new", title = "New Weapon: " .. proto.name,
                        desc = WEAPON_DESC[id] or "A new weapon", weapon = proto.name,
                        apply = function(s)
                            if #s.weapons < PlayerState.MAX_WEAPONS then
                                s.weapons[#s.weapons + 1] = PlayerState.makeWeapon(wid) :: any
                            end
                        end,
                    }
                end
            end
        end
    end
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
    local cards = {}
    for i, c in picks do
        local k = if c.kind == "new" then 2 elseif c.kind == "weapon" then 1 else 0
        cards[i] = { id = i, title = c.title, desc = c.desc, kind = k, weapon = c.weapon }
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

-- clear pending offers on a fresh run (PlayerState is reset by the caller), refresh the HUD
function M.resetPlayer(plr: Player)
    pending[plr] = nil
    pendingCount[plr] = nil
    sendStats(plr)
    sendWeapons(plr)
end

blink.ChooseCard.On(function(plr, idx)
    local offered = pending[plr]
    if not offered then return end
    local c = offered[idx]
    if not c then return end
    c.apply(PlayerState.get(plr))
    pending[plr] = nil
    sendWeapons(plr) -- in case a New Weapon was picked
    offerNext(plr) -- next queued pick, if any
    sendStats(plr)
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
end
scheduler.SYSTEM(onJoin, phases.PlayerAdded)
for _, p in Players:GetPlayers() do onJoin(p) end

return M
