-- std/playerState.luau
-- Per-player progression. Two layers:
--   • GLOBAL player stats (level/xp + damageMult, critChance, critDamage) — what level-up
--     cards mostly grant now.
--   • WEAPONS (up to 3 slots, each with its own stats) — the axolotl is weapon #1; new ones
--     drop from elites/bosses. Weapon-specific upgrade cards modify a single weapon.
-- combat reads this; progression/loot write it.
--!strict

export type Weapon = {
    id: string,    -- "axolotl", "fox", ...
    name: string,
    kind: string,  -- "projectile" | "aura" | "drop" | "melee"
    fireCd: number,
    dmg: number,
    pierce: number,
    radius: number,-- projectile size, or AoE/reach radius for aura/drop/melee
    speed: number,
    life: number,  -- projectile lifetime (range = life*speed)
    shots: number, -- projectiles per fire
    spread: number,-- fan (projectile) or cone half-handled angle (melee), radians
    split: number, -- projectile splits into this many bolts on hit (0 = none)
    knock: number, -- knockback impulse on hit
    color: Color3,
    cd: number,    -- runtime: next-allowed-fire server time
}

export type State = {
    level: number,
    xp: number,
    xpNext: number,
    -- survival
    hp: number,
    maxHp: number,
    dead: boolean,
    runStart: number, -- GetServerTimeNow() at run start (for "time survived")
    -- global
    damageMult: number, -- multiplies every weapon's damage
    critChance: number, -- 0..1
    critDamage: number, -- multiplier on a crit
    hpRegen: number,    -- HP regenerated per second
    pickupRange: number,-- multiplier on EXP/Heart pickup radius (1 = base)
    walkSpeed: number,  -- applied to the character's Humanoid.WalkSpeed
    tix: number,        -- META currency; survives a run restart (datastore later)
    -- weapons (max 3 equipped) + bench of owned-but-unequipped (keeps their upgrades)
    weapons: { Weapon },
    bench: { [string]: Weapon },
}

local MAX_WEAPONS = 3

local M = {}
M.MAX_WEAPONS = MAX_WEAPONS

-- Pet definitions (base stats, kind, skill, perks) live in the shared registry — the single
-- source of truth for both the UI and these real stats.
local Registry = require(script.Parent.petRegistry)
M.ALL_WEAPONS = Registry.order

function M.makeWeapon(id: string): Weapon?
    return Registry.make(id) :: Weapon?
end

local states: { [Player]: State } = {}

local function defaults(): State
    return {
        level = 1,
        xp = 0,
        xpNext = 5,
        hp = 100,
        maxHp = 100,
        dead = false,
        runStart = workspace:GetServerTimeNow(),
        damageMult = 1.0,
        critChance = 0.05,
        critDamage = 2.0,
        hpRegen = 0.0,
        pickupRange = 1.0,
        walkSpeed = 16,
        tix = 0,
        weapons = { M.makeWeapon("axolotl") :: Weapon }, -- start with one; others earned via "New Weapon" card
        bench = {},
    }
end

function M.get(plr: Player): State
    local s = states[plr]
    if not s then
        s = defaults()
        states[plr] = s
    end
    return s
end

-- Wipe to a fresh run (on restart after death). Tix is META currency → carried over.
function M.reset(plr: Player)
    local old = states[plr]
    local s = defaults()
    if old then s.tix = old.tix end
    states[plr] = s
end

-- Add to the meta currency balance, returns the new total.
function M.addTix(plr: Player, amount: number): number
    local s = M.get(plr)
    s.tix += amount
    return s.tix
end

-- The HUD stats payload (matches Net StatsMsg).
function M.statsMsg(plr: Player): any
    local s = M.get(plr)
    return {
        level = s.level, xp = s.xp, xpNext = s.xpNext,
        hp = math.max(0, math.floor(s.hp)), maxHp = s.maxHp,
    }
end

-- All owned weapon ids (equipped + benched).
function M.ownedIds(plr: Player): { string }
    local s = M.get(plr)
    local ids = {}
    for _, w in s.weapons do ids[#ids + 1] = w.id end
    for id in s.bench do ids[#ids + 1] = id end
    return ids
end

-- Unlock a weapon (auto-equip if a slot is free, else bench it). Keeps existing instances.
function M.unlock(plr: Player, id: string): boolean
    local s = M.get(plr)
    if s.bench[id] then return false end
    for _, w in s.weapons do if w.id == id then return false end end
    local w = M.makeWeapon(id)
    if not w then return false end
    if #s.weapons < MAX_WEAPONS then
        s.weapons[#s.weapons + 1] = w
    else
        s.bench[id] = w
    end
    return true
end

-- Set the equipped set (≤3, must be owned). Moves instances between equipped/bench so
-- per-weapon upgrades survive a swap.
function M.setEquipped(plr: Player, ids: { string })
    local s = M.get(plr)
    local byId: { [string]: Weapon } = {}
    for _, w in s.weapons do byId[w.id] = w end
    for id, w in s.bench do byId[id] = w end

    local equipped, used = {}, {}
    for _, id in ids do
        if #equipped >= MAX_WEAPONS then break end
        local w = byId[id]
        if w and not used[id] then
            equipped[#equipped + 1] = w
            used[id] = true
        end
    end
    if #equipped == 0 then return end -- never leave the player weaponless

    local bench: { [string]: Weapon } = {}
    for id, w in byId do
        if not used[id] then bench[id] = w end
    end
    s.weapons = equipped
    s.bench = bench
end

function M.remove(plr: Player)
    states[plr] = nil
end

return M
