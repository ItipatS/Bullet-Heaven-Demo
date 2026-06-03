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
    fireCd: number,
    dmg: number,
    pierce: number,
    radius: number,
    speed: number,
    life: number,  -- projectile lifetime (range = life*speed)
    shots: number, -- projectiles per fire
    spread: number,-- fan angle (radians) across the shots
    color: Color3, -- projectile colour
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
    -- weapons (max 3)
    weapons: { Weapon },
}

local MAX_WEAPONS = 3

local M = {}
M.MAX_WEAPONS = MAX_WEAPONS

local WEAPON_DEFS: { [string]: () -> Weapon } = {
    axolotl = function(): Weapon
        return {
            id = "axolotl", name = "Axolotl",
            fireCd = 0.6, dmg = 10, pierce = 3, radius = 3.5, speed = 60, life = 1.5,
            shots = 1, spread = 0, color = Color3.fromRGB(120, 200, 255), cd = 0,
        }
    end,
    fox = function(): Weapon
        return {
            id = "fox", name = "Fox",
            fireCd = 0.35, dmg = 6, pierce = 1, radius = 2.4, speed = 78, life = 0.7, -- fast, short range
            shots = 3, spread = math.rad(24), color = Color3.fromRGB(255, 150, 60), cd = 0,
        }
    end,
}

-- ids of every weapon that exists (for "new weapon" drops)
M.ALL_WEAPONS = { "axolotl", "fox" }

function M.makeWeapon(id: string): Weapon?
    local f = WEAPON_DEFS[id]
    return if f then f() else nil
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
        weapons = { M.makeWeapon("axolotl") :: Weapon }, -- start with one; Fox earned via "New Weapon" card
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

-- Wipe to a fresh run (on restart after death).
function M.reset(plr: Player)
    states[plr] = defaults()
end

-- The HUD stats payload (matches Net StatsMsg).
function M.statsMsg(plr: Player): any
    local s = M.get(plr)
    return {
        level = s.level, xp = s.xp, xpNext = s.xpNext,
        hp = math.max(0, math.floor(s.hp)), maxHp = s.maxHp,
    }
end

-- Add a weapon if there's a free slot (returns true). For elite/boss drops.
function M.addWeapon(plr: Player, id: string): boolean
    local s = M.get(plr)
    if #s.weapons >= MAX_WEAPONS then return false end
    local w = M.makeWeapon(id)
    if not w then return false end
    s.weapons[#s.weapons + 1] = w
    return true
end

function M.remove(plr: Player)
    states[plr] = nil
end

return M
