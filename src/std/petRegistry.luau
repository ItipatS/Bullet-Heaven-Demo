-- std/petRegistry.luau
-- SINGLE SOURCE OF TRUTH for every pet/weapon, used by BOTH the UI (panel, cards) and the
-- real combat stats. Per pet: base stats, kind, a signature skill, and the perks it can roll.
--   make(id) -> a fresh weapon INSTANCE (base stats copied + runtime cd) for PlayerState.
-- Upgrades mutate the instance, never the registry — so a fresh run / new instance is clean.
--!strict

local R = {}

-- perk: { id, title, desc, kind = "stat" | "perk", apply(w) }
-- skill: { name, desc, cooldown } — metadata only; the ACTUAL effect lives in combat.luau's
--        SKILLS table keyed by pet id (data here, behavior there). Triggered by the slot key
--        (Q/E/R = equipped slot 1/2/3). Every pet has one.

R.pets = {
    axolotl = {
        id = "axolotl", name = "Axolotl", kind = "projectile", blurb = "Piercing bubbles",
        base = { fireCd = 0.6, dmg = 10, pierce = 3, radius = 2.4, speed = 60, life = 1.5, shots = 1, spread = 0, split = 0, knock = 6, color = Color3.fromRGB(120, 200, 255) },
        skill = { name = "Nova", desc = "Fire a full ring of bubbles", cooldown = 8 },
        perks = {
            { id = "dmg", title = "Sharpen", desc = "+5 damage", kind = "stat", apply = function(w) w.dmg += 5 end },
            { id = "cd", title = "Quicken", desc = "-12% cooldown", kind = "stat", apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.88) end },
            { id = "pierce", title = "Pierce", desc = "+1 pierce", kind = "perk", apply = function(w) w.pierce += 1 end },
            { id = "split", title = "Split Shot", desc = "bolts split on hit", kind = "perk", apply = function(w) w.split += 1 end },
        },
    },
    fox = {
        id = "fox", name = "Fox", kind = "projectile", blurb = "Rapid 3-shot scatter",
        base = { fireCd = 0.35, dmg = 6, pierce = 1, radius = 2.4, speed = 78, life = 0.7, shots = 3, spread = math.rad(24), split = 0, knock = 2, color = Color3.fromRGB(255, 150, 60) },
        skill = { name = "Barrage", desc = "Wide burst of fast shots where you aim", cooldown = 6 },
        perks = {
            { id = "dmg", title = "Sharpen", desc = "+5 damage", kind = "stat", apply = function(w) w.dmg += 5 end },
            { id = "cd", title = "Quicken", desc = "-12% cooldown", kind = "stat", apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.88) end },
            { id = "pierce", title = "Pierce", desc = "+1 pierce", kind = "perk", apply = function(w) w.pierce += 1 end },
            { id = "split", title = "Split Shot", desc = "bolts split on hit", kind = "perk", apply = function(w) w.split += 1 end },
        },
    },
    slime = {
        id = "slime", name = "Slime", kind = "aura", blurb = "Damages everything around you",
        base = { fireCd = 0.4, dmg = 5, pierce = 0, radius = 11, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 3, color = Color3.fromRGB(120, 255, 150) },
        skill = { name = "Quake", desc = "A big damaging pulse around you", cooldown = 7 },
        perks = {
            { id = "dmg", title = "Caustic", desc = "+4 damage", kind = "stat", apply = function(w) w.dmg += 4 end },
            { id = "radius", title = "Spread", desc = "+1.5 radius", kind = "stat", apply = function(w) w.radius += 1.5 end },
            { id = "cd", title = "Pulse", desc = "-12% tick time", kind = "stat", apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.88) end },
        },
    },
    mole = {
        id = "mole", name = "Mole", kind = "drop", blurb = "Drops a stone on the densest crowd",
        base = { fireCd = 2.5, dmg = 30, pierce = 0, radius = 9, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 24, color = Color3.fromRGB(180, 140, 90) },
        skill = { name = "Avalanche", desc = "Several stones crash on the crowd", cooldown = 10 },
        perks = {
            { id = "dmg", title = "Boulder", desc = "+12 damage", kind = "stat", apply = function(w) w.dmg += 12 end },
            { id = "radius", title = "Crater", desc = "+1.5 radius", kind = "stat", apply = function(w) w.radius += 1.5 end },
            { id = "cd", title = "Dig Fast", desc = "-12% cooldown", kind = "stat", apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.88) end },
        },
    },
    bear = {
        id = "bear", name = "Bear", kind = "melee", blurb = "Cone swing where you aim",
        base = { fireCd = 1.1, dmg = 20, pierce = 0, radius = 15, speed = 0, life = 0, shots = 1, spread = math.rad(100), split = 0, knock = 20, color = Color3.fromRGB(255, 120, 120) },
        skill = { name = "Roar", desc = "Shockwave: damage + big knockback", cooldown = 8 },
        perks = {
            { id = "dmg", title = "Maul", desc = "+8 damage", kind = "stat", apply = function(w) w.dmg += 8 end },
            { id = "radius", title = "Long Arms", desc = "+2 reach", kind = "stat", apply = function(w) w.radius += 2 end },
            { id = "cd", title = "Frenzy", desc = "-12% cooldown", kind = "stat", apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.88) end },
        },
    },
}

R.order = { "axolotl", "fox", "slime", "mole", "bear" }

-- a fresh weapon instance (base stats copied + identity + runtime cd)
function R.make(id: string)
    local p = R.pets[id]
    if not p then return nil end
    local w = table.clone(p.base)
    w.id = id
    w.name = p.name
    w.kind = p.kind
    w.cd = 0
    return w
end

return R
