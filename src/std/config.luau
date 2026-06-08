-- std/config.luau
-- Central gameplay config. ONE place to tweak the knobs — debug toggles, the wave/spawn
-- tunables, and the mobile control scheme. Lives in ReplicatedStorage.std so the SERVER
-- (SpawnMob/combat/ufo) and the CLIENT (aimstick/syncPet) read the exact same values.
--
-- NOTE: the PUBLIC SHOWCASE build intentionally ships these Debug flags ON (not leftover debug) so
-- anyone sees ~1000 server-authoritative mobs + a steady FPS overlay the moment they join — the whole
-- point is "1000 mobs doesn't make the engine die." Flip them OFF for a normal ramped, losable game.
--!strict

local Config = {}

-- ── Debug / showcase toggles ────────────────────────────────────────────────────
-- These change gameplay. ON (current) = the public showcase: instant scale + invincible so a viewer
-- can stand in the horde and watch the FPS hold. OFF = a normal ramped, losable run.
Config.Debug = {
    -- Spawn STRESS_COUNT mobs on the very first wave (fast fill) instead of the normal
    -- ramp, so you can stress the renderer/perf immediately. Later waves spawn normally.
    STRESS_TEST  = true,
    STRESS_COUNT = 1000,

    -- The local player takes NO damage (contact + UFO bolts/beam). Lets you stand in the
    -- horde to test scale without dying. Server-authoritative, so it must live here.
    INVINCIBLE   = true,

    -- On-screen FPS / frame-time / ping overlay (top-left). Mobile has no built-in FPS
    -- display (Shift+F5 is PC-only), so this is how you read perf on a real phone.
    SHOW_FPS     = true,
}

-- ── Wave / spawn tunables (read by SpawnMob.luau) ───────────────────────────────
Config.Spawn = {
    ZOMBIE_TYPE  = "Zombie",
    ZOMBIE_SPEED = 9,
    ZOMBIE_HP    = 30,
    NORMAL_SIZE  = 1,
    ELITE_SIZE   = 2.6,
    ELITE_SPEED  = 7,
    ELITE_HP_MUL = 12,
    BOSS_SIZE    = 5,
    BOSS_SPEED   = 5,
    BOSS_HP_MUL  = 20,      -- boss HP = wave HP × this (a real wall)

    MAX_ZOMBIES  = 1000,    -- perf cap + design sweet spot (density vs map; load is projectiles now)
    BASE_WAVE    = 25,
    WAVE_GROW    = 18,      -- +mobs per wave
    HP_GROWTH    = 0.35,    -- +HP per wave
    ELITE_FROM   = 2,       -- first wave with elites
    BOSS_EVERY   = 1,       -- a boss (→ drops a PET) every Nth wave
    BREATHER     = 3.0,     -- seconds between waves
    MAX_WAVE_TIME = 90,     -- force the next wave if a few stragglers never die
    SPAWN_EVERY  = 0.08,
    SPAWN_BATCH  = 25,      -- ramp the wave in (no 1-frame dump)
    STRESS_BATCH = 200,     -- fast fill used while Debug.STRESS_TEST fills the first wave

    -- UFO flying enemy (a random sprinkle, not a replacement)
    UFO_TYPE        = "UFO",
    UFO_FROM        = 1,     -- first wave UFOs appear
    UFO_CHANCE      = 0.06,  -- chance a NORMAL spawn is a UFO instead of a zombie
    UFO_HOVER       = 14,    -- spawn/hover height above the ground node
    UFO_SPEED       = 10,
    UFO_N_SCALE     = 0.5,   -- normal (model default-ish)
    UFO_E_SCALE     = 1.0,   -- elite  (scaled back up to 1)
    UFO_B_SCALE     = 2.0,   -- boss
    UFO_N_HP        = 0.6,   -- ×waveHP (squishy flyer — "shouldn't be hard")
    UFO_E_HP        = 0.5,   -- ×eliteHP
    UFO_B_HP        = 0.5,   -- ×bossHP
    UFO_ELITE_CHANCE = 0.35, -- chance an elite is a UFO elite
    UFO_BOSS_CHANCE  = 0.40, -- chance a boss is a UFO boss
}

-- ── Mob replication (dense-slot + i8 deltas) — read by horde.luau + syncMobs.luau ─
-- Positions stream WITHOUT a per-mob id: deltas are written in SLOT order (the client maps
-- slot→entity from the Spawn payload). Each axis is an i8 in STEP-sized fixed-point steps.
Config.Net = {
    STEP        = 0.02,   -- studs per i8 unit → ±127*STEP = ±2.54 studs of motion per net tick
    CHUNK       = 256,    -- slots per unreliable packet (256*3 = 768 B, under the ~900 B cap)
    WARP_THRESH = 25,     -- a per-axis jump bigger than this can't fit i8 → send an absolute
    NET_TICK    = 1 / 15, -- delta send rate
    FULL_EVERY  = 2.5,    -- seconds between absolute f32 snapshots (clears drift + slot churn)
}

-- ── Controls (read by the client: aimstick.luau + syncPet.luau) ─────────────────
Config.Controls = {
    -- When to show the on-screen AIM thumbstick (separate from the movement stick).
    --   "auto"   → only on touch devices (no physical mouse)
    --   "always" → always show it (handy to test in Studio on PC)
    --   "never"  → never; aim follows the mouse/camera
    AIM_STICK = "auto",

    AIM_STICK_RADIUS  = 64,   -- px, outer ring radius
    AIM_STICK_KNOB    = 28,   -- px, inner knob radius
    AIM_STICK_MARGIN  = 90,   -- px, distance from the bottom-right corner to the ring centre
    AIM_STICK_DEADZONE = 0.15, -- fraction of the radius ignored as slop
}

return Config
