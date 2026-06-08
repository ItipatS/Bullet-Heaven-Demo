-- std/petRegistry.luau
-- SINGLE SOURCE OF TRUTH for every pet/weapon, used by BOTH the UI (panel, cards) and the
-- real combat stats. Per pet: base stats, kind, a signature skill, and a LEVEL TREE.
--   make(id)            -> a fresh weapon INSTANCE (level 1, base stats + behavior flags off)
--   applyLevelUp(w)     -> bump w.level and apply that level's FIXED behavioral upgrade
--   nextDesc(w)         -> the description of w's next level (for the level-up card), or nil if maxed
-- Trees mutate the instance, never the registry — a fresh run / new instance is clean.
--!strict

local R = {}

-- tree entry: [targetLevel] = { desc, apply(w) }. Level 1 is the base; reaching level L applies
-- tree[L]. Each step changes WHAT THE WEAPON DOES (a fixed upgrade), not a stat roll.
local MAX_LEVEL = 10

R.pets = {
    axolotl = {
        id = "axolotl", name = "Axolotl", kind = "projectile", blurb = "Piercing bubbles",
        price = 0, -- starter
        base = { fireCd = 0.6, dmg = 10, pierce = 3, radius = 2.4, speed = 60, life = 1.5, shots = 1, spread = 0, split = 0, knock = 6, color = Color3.fromRGB(120, 200, 255) },
        skill = { name = "Nova", desc = "Fire a full ring of bubbles", cooldown = 8 },
        tree = {
            [2]  = { desc = "Bubbles split on hit",          apply = function(w) w.split += 1 end },
            [3]  = { desc = "+2 pierce",                      apply = function(w) w.pierce += 2 end },
            [4]  = { desc = "Nova: +8 bubbles",               apply = function(w) w.skillBubbles += 8 end },
            [5]  = { desc = "Bubbles burst (small AoE) on hit", apply = function(w) w.aoeRadius = 4 end },
            [6]  = { desc = "Twin stream (+1 shot)",          apply = function(w) w.shots += 1 end },
            [7]  = { desc = "Split bolts also pierce",        apply = function(w) w.splitPierce = true end },
            [8]  = { desc = "Nova fires twice",               apply = function(w) w.skillRepeat += 1 end },
            [9]  = { desc = "Bigger burst radius",            apply = function(w) w.aoeRadius += 2 end },
            [10] = { desc = "Capstone: +1 shot, +12 dmg",     apply = function(w) w.shots += 1; w.dmg += 12 end },
        },
    },
    fox = {
        id = "fox", name = "Fox", kind = "projectile", blurb = "Darts that ricochet between foes",
        price = 0, -- starter
        base = { fireCd = 0.4, dmg = 7, pierce = 1, radius = 2.2, speed = 82, life = 0.8, shots = 1, spread = math.rad(10), split = 0, knock = 2, color = Color3.fromRGB(255, 150, 60), chain = 2 },
        skill = { name = "Barrage", desc = "Wide burst of fast shots where you aim", cooldown = 6 },
        tree = {
            [2]  = { desc = "+1 ricochet",               apply = function(w) w.chain += 1 end },
            [3]  = { desc = "+4 damage",                 apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Barrage: +6 shots",         apply = function(w) w.skillBubbles += 6 end },
            [5]  = { desc = "+1 ricochet",               apply = function(w) w.chain += 1 end },
            [6]  = { desc = "Twin dart (+1 shot)",       apply = function(w) w.shots += 1 end },
            [7]  = { desc = "+15% fire rate",            apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [8]  = { desc = "Bounces burst (AoE)",       apply = function(w) w.aoeRadius = 3 end },
            [9]  = { desc = "+2 ricochet",               apply = function(w) w.chain += 2 end },
            [10] = { desc = "Capstone: +1 shot, +8 dmg", apply = function(w) w.shots += 1; w.dmg += 8 end },
        },
    },
    slime = {
        id = "slime", name = "Slime", kind = "aura", blurb = "Damages everything around you",
        price = 0, -- starter
        base = { fireCd = 0.4, dmg = 5, pierce = 0, radius = 11, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 3, color = Color3.fromRGB(120, 255, 150) },
        skill = { name = "Quake", desc = "A big damaging pulse around you", cooldown = 7 },
        tree = {
            [2]  = { desc = "+2 radius",                  apply = function(w) w.radius += 2 end },
            [3]  = { desc = "+4 damage",                  apply = function(w) w.dmg += 4 end },
            [4]  = { desc = "Faster ticks (+rate)",       apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [5]  = { desc = "+2 radius",                  apply = function(w) w.radius += 2 end },
            [6]  = { desc = "+5 damage",                  apply = function(w) w.dmg += 5 end },
            [7]  = { desc = "Pushes enemies out",         apply = function(w) w.knock += 4 end },
            [8]  = { desc = "Faster ticks (+rate)",       apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [9]  = { desc = "+3 radius",                  apply = function(w) w.radius += 3 end },
            [10] = { desc = "Capstone: +8 dmg, +3 radius", apply = function(w) w.dmg += 8; w.radius += 3 end },
        },
    },
    mole = {
        id = "mole", name = "Mole", kind = "drop", blurb = "Drops stones on the densest crowd",
        price = 400,
        base = { fireCd = 2.5, dmg = 30, pierce = 0, radius = 9, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 24, color = Color3.fromRGB(180, 140, 90) },
        skill = { name = "Avalanche", desc = "Several stones crash on the crowd", cooldown = 10 },
        tree = {
            [2]  = { desc = "+12 damage",                  apply = function(w) w.dmg += 12 end },
            [3]  = { desc = "+2 radius",                   apply = function(w) w.radius += 2 end },
            [4]  = { desc = "Drops 2 stones",              apply = function(w) w.shots += 1 end },
            [5]  = { desc = "Digs faster (+rate)",         apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [6]  = { desc = "+15 damage",                  apply = function(w) w.dmg += 15 end },
            [7]  = { desc = "Drops 3 stones",              apply = function(w) w.shots += 1 end },
            [8]  = { desc = "+2 radius",                   apply = function(w) w.radius += 2 end },
            [9]  = { desc = "+knockback",                  apply = function(w) w.knock += 12 end },
            [10] = { desc = "Capstone: +2 stones, +20 dmg", apply = function(w) w.shots += 2; w.dmg += 20 end },
        },
    },
    bear = {
        id = "bear", name = "Bear", kind = "melee", blurb = "Bruiser: heavy cone + HP sustain",
        price = 500,
        base = { fireCd = 1.1, dmg = 22, pierce = 0, radius = 15, speed = 0, life = 0, shots = 1, spread = math.rad(100), split = 0, knock = 20, color = Color3.fromRGB(255, 120, 120), regenBonus = 1.0 },
        skill = { name = "Roar", desc = "Shockwave: knockback + heal burst", cooldown = 8 },
        tree = {
            [2]  = { desc = "+8 damage",                    apply = function(w) w.dmg += 8 end },
            [3]  = { desc = "+1 HP/sec sustain",            apply = function(w) w.regenBonus += 1 end },
            [4]  = { desc = "Wider cone",                   apply = function(w) w.spread += math.rad(20) end },
            [5]  = { desc = "+knockback",                   apply = function(w) w.knock += 10 end },
            [6]  = { desc = "+12 damage",                   apply = function(w) w.dmg += 12 end },
            [7]  = { desc = "+1 HP/sec sustain",            apply = function(w) w.regenBonus += 1 end },
            [8]  = { desc = "Swings faster (+rate)",        apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [9]  = { desc = "+3 reach",                     apply = function(w) w.radius += 3 end },
            [10] = { desc = "Capstone: 360° maul, +16 dmg", apply = function(w) w.spread = math.pi * 2; w.dmg += 16 end },
        },
    },

    -- ── New weapons (in-run finds; not starters) ───────────────────────────────────
    unicorn = {
        id = "unicorn", name = "Unicorn", kind = "puddle", blurb = "Rainbow puddles: damage-over-time + slow",
        price = 900,
        base = { fireCd = 2.2, dmg = 0, pierce = 0, radius = 11, speed = 0, life = 4.0, shots = 1, spread = 0, split = 0, knock = 0, color = Color3.fromRGB(220, 150, 255), dot = 6, slowFactor = 0.6 },
        skill = { name = "Taste the Rainbow", desc = "A slow rainbow beam that sweeps where you aim", cooldown = 12 },
        tree = {
            [2] = { desc = "+2 DoT per tick",               apply = function(w) w.dot += 2 end },
            [3] = { desc = "+2 puddle radius",              apply = function(w) w.radius += 2 end },
            [4] = { desc = "Stronger slow",                 apply = function(w) w.slowFactor = math.max(0.3, w.slowFactor - 0.1) end },
            [5] = { desc = "+1.5s puddle",                  apply = function(w) w.life += 1.5 end },
            [6] = { desc = "+3 DoT per tick",               apply = function(w) w.dot += 3 end },
            [7] = { desc = "Faster cast (+rate)",           apply = function(w) w.fireCd = math.max(0.8, w.fireCd * 0.85) end },
            [8] = { desc = "+3 puddle radius",              apply = function(w) w.radius += 3 end },
            [9] = { desc = "Beam lasts longer",             apply = function(w) w.skillBubbles += 1 end }, -- combat reads skillBubbles to extend the beam
            [10] = { desc = "Capstone: +5 DoT, +2 radius",  apply = function(w) w.dot += 5; w.radius += 2 end },
        },
    },
    cat = {
        id = "cat", name = "Cat", kind = "projectile", blurb = "Clawed boomerang — hits out and back",
        price = 600,
        base = { fireCd = 0.7, dmg = 9, pierce = 3, radius = 2.4, speed = 70, life = 1.2, shots = 1, spread = 0, split = 0, knock = 4, color = Color3.fromRGB(255, 180, 120), boomerang = true },
        skill = { name = "Nine Lives", desc = "A storm of boomerangs around you", cooldown = 8 },
        tree = {
            [2] = { desc = "+1 pierce",                     apply = function(w) w.pierce += 1 end },
            [3] = { desc = "+4 damage",                     apply = function(w) w.dmg += 4 end },
            [4] = { desc = "Twin boomerang (+1 shot)",      apply = function(w) w.shots += 1 end },
            [5] = { desc = "Longer flight",                 apply = function(w) w.life += 0.4 end },
            [6] = { desc = "+2 pierce",                     apply = function(w) w.pierce += 2 end },
            [7] = { desc = "Faster throw (+rate)",          apply = function(w) w.fireCd = math.max(0.25, w.fireCd * 0.85) end },
            [8] = { desc = "Boomerangs burst (AoE)",        apply = function(w) w.aoeRadius = 3 end },
            [9] = { desc = "+6 damage",                     apply = function(w) w.dmg += 6 end },
            [10] = { desc = "Capstone: +1 shot, +8 dmg",    apply = function(w) w.shots += 1; w.dmg += 8 end },
        },
    },
    panda = {
        id = "panda", name = "Panda", kind = "bamboo", blurb = "Summons lasting bamboo from the ground (knockback)",
        price = 700,
        -- slow placement, but each bamboo patch LINGERS (life) — a zone-control playstyle
        base = { fireCd = 2.2, dmg = 8, pierce = 0, radius = 3, speed = 0, life = 3.5, shots = 3, spread = 0, split = 0, knock = 10, color = Color3.fromRGB(230, 230, 235) },
        skill = { name = "Giant Bamboo", desc = "One huge bamboo erupts — big knockback + damage", cooldown = 9 },
        tree = {
            [2] = { desc = "+4 bamboo damage",              apply = function(w) w.dmg += 4 end },
            [3] = { desc = "+1 bamboo",                     apply = function(w) w.shots += 1 end },
            [4] = { desc = "+knockback",                    apply = function(w) w.knock += 6 end },
            [5] = { desc = "Faster summon (+rate)",         apply = function(w) w.fireCd = math.max(0.4, w.fireCd * 0.85) end },
            [6] = { desc = "+1 bamboo",                     apply = function(w) w.shots += 1 end },
            [7] = { desc = "+1 radius",                     apply = function(w) w.radius += 1 end },
            [8] = { desc = "+6 bamboo damage",              apply = function(w) w.dmg += 6 end },
            [9] = { desc = "+2 bamboo",                     apply = function(w) w.shots += 2 end },
            [10] = { desc = "Capstone: +2 bamboo, +8 dmg",  apply = function(w) w.shots += 2; w.dmg += 8 end },
        },
    },
    turtle = {
        id = "turtle", name = "Turtle", kind = "orbit", blurb = "Orbiting shells + armor + thorns",
        price = 1000,
        base = { fireCd = 0.15, dmg = 5, pierce = 0, radius = 3, speed = 0, life = 0, shots = 3, spread = 0, split = 0, knock = 8, color = Color3.fromRGB(120, 200, 140), armor = 0.15, reflect = 0.2 },
        skill = { name = "Shell Nova", desc = "Briefly invulnerable + a huge radial shove", cooldown = 12 },
        tree = {
            [2] = { desc = "+1 shell",                      apply = function(w) w.shots += 1 end },
            [3] = { desc = "+5% armor",                     apply = function(w) w.armor += 0.05 end },
            [4] = { desc = "+3 shell damage",               apply = function(w) w.dmg += 3 end },
            [5] = { desc = "+10% thorns",                   apply = function(w) w.reflect += 0.1 end },
            [6] = { desc = "+1 shell",                      apply = function(w) w.shots += 1 end },
            [7] = { desc = "+5% armor",                     apply = function(w) w.armor += 0.05 end },
            [8] = { desc = "+knockback",                    apply = function(w) w.knock += 6 end },
            [9] = { desc = "+1 radius",                     apply = function(w) w.radius += 1 end },
            [10] = { desc = "Capstone: +1 shell, +10% thorns", apply = function(w) w.shots += 1; w.reflect += 0.1 end },
        },
    },
    cow = {
        id = "cow", name = "Cow", kind = "aura", blurb = "A churning damage aura",
        price = 500,
        base = { fireCd = 0.45, dmg = 6, pierce = 0, radius = 12, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 3, color = Color3.fromRGB(245, 240, 220) },
        skill = { name = "Stampede", desc = "A big damaging pulse around you", cooldown = 7 },
        tree = {
            [2] = { desc = "+2 radius",                     apply = function(w) w.radius += 2 end },
            [3] = { desc = "+4 damage",                     apply = function(w) w.dmg += 4 end },
            [4] = { desc = "Faster ticks (+rate)",          apply = function(w) w.fireCd = math.max(0.08, w.fireCd * 0.85) end },
            [5] = { desc = "+3 radius",                     apply = function(w) w.radius += 3 end },
            [6] = { desc = "Pushes enemies out",            apply = function(w) w.knock += 5 end },
            [7] = { desc = "Capstone: +8 dmg, +3 radius",   apply = function(w) w.dmg += 8; w.radius += 3 end },
        },
    },
    elephant = {
        id = "elephant", name = "Elephant", kind = "drop", blurb = "Stomps craters on the crowd",
        price = 800,
        base = { fireCd = 2.6, dmg = 34, pierce = 0, radius = 10, speed = 0, life = 0, shots = 1, spread = 0, split = 0, knock = 26, color = Color3.fromRGB(150, 160, 175) },
        skill = { name = "Earthshaker", desc = "A barrage of stomps on the crowd", cooldown = 10 },
        tree = {
            [2] = { desc = "+14 damage",                    apply = function(w) w.dmg += 14 end },
            [3] = { desc = "+2 radius",                     apply = function(w) w.radius += 2 end },
            [4] = { desc = "Stomps twice",                  apply = function(w) w.shots += 1 end },
            [5] = { desc = "Stomps faster (+rate)",         apply = function(w) w.fireCd = math.max(0.2, w.fireCd * 0.85) end },
            [6] = { desc = "+18 damage",                    apply = function(w) w.dmg += 18 end },
            [7] = { desc = "Capstone: +2 stomps, +24 dmg",  apply = function(w) w.shots += 2; w.dmg += 24 end },
        },
    },
}

R.order = { "axolotl", "fox", "slime", "mole", "bear", "unicorn", "cat", "panda", "cow", "elephant", "turtle" }

-- a pet's max level = the highest level defined in its tree (sparse trees don't create no-op cards)
function R.maxLevel(id: string): number
    local p = R.pets[id]
    if not p then return 1 end
    local m = 1
    for lvl in p.tree do if lvl > m then m = lvl end end
    return m
end

-- the Animals MeshPart name for a pet id (ids are the lowercase asset name → just capitalize)
function R.meshName(id: string): string
    return id:sub(1, 1):upper() .. id:sub(2)
end

-- a fresh weapon instance (base stats copied + identity + runtime cd + level/behavior defaults)
function R.make(id: string)
    local p = R.pets[id]
    if not p then return nil end
    local w = table.clone(p.base)
    w.id = id
    w.name = p.name
    w.kind = p.kind
    w.cd = 0
    w.level = 1
    w.maxLevel = R.maxLevel(id)
    w.aoeRadius = 0
    w.splitPierce = false
    w.skillBubbles = 0
    w.skillRepeat = 0
    -- archetype flags (revamp) — base may override below via the pet's `base`; trees scale them
    w.boomerang = p.base.boomerang or false
    w.chain = p.base.chain or 0
    w.dot = p.base.dot or 0
    w.slowFactor = p.base.slowFactor or 1
    w.armor = p.base.armor or 0
    w.reflect = p.base.reflect or 0
    w.regenBonus = p.base.regenBonus or 0
    return w
end

-- bump a weapon to its next level and apply that level's fixed upgrade (no-op if maxed)
function R.applyLevelUp(w: any)
    local p = R.pets[w.id]
    if not p then return end
    local next = w.level + 1
    local up = p.tree[next]
    if not up then return end -- maxed
    w.level = next
    up.apply(w)
end

-- description of a weapon's NEXT level (for the level-up card), or nil if maxed
function R.nextDesc(w: any): string?
    local p = R.pets[w.id]
    if not p then return nil end
    local up = p.tree[w.level + 1]
    return up and up.desc or nil
end

return R
