-- ClientSystems/syncMobs.luau
-- Client horde rendering — PURE PRESENTATION. The server owns movement + separation and
-- streams authoritative positions (Spawn = initial, UpdateTransformDelta = f16 deltas,
-- UpdateTransformFull = f32 snapshots). The client interpolates toward the latest target and
-- draws one pooled ZOMBIE RIG per mob via BulkMoveTo (only the anchored root is moved; the
-- jointed limbs follow). No recompute, no raycasts, no client-side separation — what you see
-- matches the server hitboxes. Elites/bosses are the same rig, scaled up (server `size`).
--!optimize 2
--!native
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))

local ref   = require(std:WaitForChild("ref"))
local blink = require(std:WaitForChild("ClientNet"))
local Pool  = require(std:WaitForChild("MobRenderPool"))

-- ── Render constants ──────────────────────────────────────────────────────────
local BASE_LIFT = 3       -- R6 foot→HumanoidRootPart offset; scales with the rig (×size)
local LERP_RATE = 14      -- interpolation rate toward the streamed target (smooths 15Hz net)
local EPS2      = 0.0025
local WALK_FREQ = 9       -- procedural leg-swing rate (no Humanoid/Animator — scales to the horde)
local WALK_AMP  = 0.55    -- leg swing amplitude (radians)

-- ── Zombie rig template (cloned from the Studio rig, stripped + posed for cheap rendering) ──
local function buildTemplate(): Model
    local src = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Zombie") :: Model
    local t = src:Clone()
    -- drop everything non-visual (Humanoid/Animator, scripts, sounds) — we only render a pose
    for _, d in t:GetDescendants() do
        if d:IsA("Humanoid") or d:IsA("BaseScript") or d:IsA("ModuleScript") or d:IsA("Sound") then
            d:Destroy()
        end
    end
    local prim = (t.PrimaryPart or t:FindFirstChild("HumanoidRootPart")) :: BasePart
    t.PrimaryPart = prim
    -- only the root is anchored; limbs stay jointed (Motor6D) so moving the root drags the body
    for _, d in t:GetDescendants() do
        if d:IsA("BasePart") then
            d.CanCollide = false
            d.CanQuery   = false
            d.CanTouch   = false
            d.CastShadow = false
            d.Massless   = true
            d.Anchored   = (d == prim)
        end
    end
    return t
end

local template = buildTemplate()

-- per-part base colours (for restoring after a hit flash)
local templateColors: { [string]: Color3 } = {}
for _, d in template:GetDescendants() do
    if d:IsA("BasePart") then templateColors[d.Name] = d.Color end
end
local DEFAULT_COLOR = Color3.fromRGB(120, 160, 110)
local FLASH_COLOR   = Color3.fromRGB(255, 255, 255)
local FLASH_DUR     = 0.1

local MobsFolder = Instance.new("Folder")
MobsFolder.Name = "Mobs"
MobsFolder.Parent = workspace

local pool = Pool.new(template, MobsFolder)

-- per-entity streamed target + interpolated render position (ground level)
local target:    { [number]: Vector3 } = {}
local renderPos: { [number]: Vector3 } = {}
local mobLift:   { [number]: number } = {}   -- root lift above ground (scales with rig size)
local mobParts:  { [number]: { BasePart } } = {} -- cached rig parts for the hit flash
local mobLegs:   { [number]: { Motor6D } } = {}  -- {leftHip, rightHip} for the walk swing
local mobWalking: { [number]: boolean } = {}
local flashUntil: { [number]: number } = {}

-- ── Net ───────────────────────────────────────────────────────────────────────
blink.Spawn.On(function(batch)
    for _, payload in batch do
        if payload.type ~= "Zombie" then continue end
        local e = ref("server-" .. tostring(payload.id))
        if pool:get(e) then continue end
        local pos  = payload.pos :: Vector3
        local size = payload.size
        local lift = BASE_LIFT * size
        local model = pool:acquire(e, CFrame.new(pos + Vector3.new(0, lift, 0)), size)
        target[e] = pos
        renderPos[e] = pos
        mobLift[e] = lift
        local parts: { BasePart } = {}
        local legs: { Motor6D } = {}
        for _, d in model:GetDescendants() do
            if d:IsA("BasePart") then
                parts[#parts + 1] = d
            elseif d:IsA("Motor6D") and d.Part1 then
                if d.Part1.Name == "Left Leg" then legs[1] = d
                elseif d.Part1.Name == "Right Leg" then legs[2] = d end
            end
        end
        mobParts[e] = parts
        if legs[1] and legs[2] then mobLegs[e] = legs end
    end
end)

blink.UpdateTransformDelta.On(function(batch)
    for _, t in batch do
        local e = ref("server-" .. tostring(t.id))
        local cur = target[e]
        if cur then target[e] = cur + (t.dp :: Vector3) end
    end
end)

blink.UpdateTransformFull.On(function(batch)
    for _, t in batch do
        local e = ref("server-" .. tostring(t.id))
        target[e] = t.dp :: Vector3
        if not renderPos[e] then renderPos[e] = t.dp :: Vector3 end
    end
end)

blink.Death.On(function(ids)
    for _, id in ids do
        local e = ref("server-" .. tostring(id))
        if pool:get(e) then pool:release(e) end
        target[e] = nil
        renderPos[e] = nil
        mobLift[e] = nil
        mobParts[e] = nil
        mobLegs[e] = nil
        mobWalking[e] = nil
        flashUntil[e] = nil
    end
end)

blink.Hit.On(function(ids)
    local now = os.clock()
    for _, id in ids do
        local e = ref("server-" .. tostring(id))
        local parts = mobParts[e]
        if parts then
            for _, p in parts do p.Color = FLASH_COLOR end
            flashUntil[e] = now + FLASH_DUR
        end
    end
end)

-- ── Render ──────────────────────────────────────────────────────────────────────
local function move(dt: number)
    local a = math.min(1, LERP_RATE * dt)

    -- restore colour on flashes that have expired
    local now = os.clock()
    for e, until_ in flashUntil do
        if now >= until_ then
            local parts = mobParts[e]
            if parts then
                for _, p in parts do p.Color = templateColors[p.Name] or DEFAULT_COLOR end
            end
            flashUntil[e] = nil
        end
    end

    for e, tgt in target do
        local part = pool:get(e)
        if not part then continue end
        local rp = renderPos[e] or tgt
        local nrp = rp:Lerp(tgt, a)
        renderPos[e] = nrp
        local lift = mobLift[e] or BASE_LIFT

        local fx, fz = tgt.X - rp.X, tgt.Z - rp.Z -- velocity dir → facing
        local moving = fx * fx + fz * fz > EPS2
        local cf: CFrame
        if moving then
            local p = Vector3.new(nrp.X, nrp.Y + lift, nrp.Z)
            cf = CFrame.lookAt(p, p + Vector3.new(fx, 0, fz))
        else
            cf = CFrame.new(nrp.X, nrp.Y + lift, nrp.Z) * part.CFrame.Rotation
        end
        pool:setCFrame(e, cf)

        -- procedural walk: swing the hips while moving, rest to neutral when stopped
        local legs = mobLegs[e]
        if legs then
            if moving then
                -- hip C0 has a -90° Y twist → local Z is the front/back swing axis. The two hips
                -- are MIRRORED, so the SAME signed rotation swings them in opposite world
                -- directions (i.e. alternating stride); opposite signs would move them together.
                local s = math.sin(now * WALK_FREQ + e * 0.7) * WALK_AMP
                legs[1].Transform = CFrame.Angles(0, 0, s)
                legs[2].Transform = CFrame.Angles(0, 0, s)
                mobWalking[e] = true
            elseif mobWalking[e] then
                legs[1].Transform = CFrame.identity
                legs[2].Transform = CFrame.identity
                mobWalking[e] = false
            end
        end
    end
    pool:flush()
end

scheduler.SYSTEM(move, phases.Heartbeat)
return 0
