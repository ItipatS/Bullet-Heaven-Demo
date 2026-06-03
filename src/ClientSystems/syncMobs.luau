-- ClientSystems/syncMobs.luau
-- Client horde rendering — PURE PRESENTATION. The server owns movement + separation and
-- streams authoritative positions (Spawn = initial, UpdateTransformDelta = f16 deltas,
-- UpdateTransformFull = f32 snapshots). The client just interpolates toward the latest target
-- and draws one pooled slime per mob via BulkMoveTo. No recompute, no raycasts, no client-side
-- separation — so what you see matches the server hitboxes, and it scales (Phase 0: 10k apply
-- is cheap).
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
local RENDER_LIFT = 2     -- server pos is ~ground; lift the slime centre
local LERP_RATE   = 14    -- interpolation rate toward the streamed target (smooths 15Hz net)
local UP          = Vector3.new(0, RENDER_LIFT, 0)
local EPS2        = 0.0025

-- ── Cheap single-part slime visual ──────────────────────────────────────────────
local function makeTemplate(): BasePart
    local p = Instance.new("Part")
    p.Name = "Slime"
    p.Shape = Enum.PartType.Ball
    p.Size = Vector3.new(3, 2.4, 3)
    p.Anchored   = true
    p.CanCollide = false
    p.CanQuery   = false
    p.CanTouch   = false
    p.CastShadow = false
    p.Material   = Enum.Material.SmoothPlastic
    p.Color      = Color3.fromRGB(90, 200, 110)
    return p
end

local MobsFolder = Instance.new("Folder")
MobsFolder.Name = "Mobs"
MobsFolder.Parent = workspace

local pool = Pool.new(makeTemplate(), MobsFolder)

-- per-entity streamed target + interpolated render position (ground level)
local target:    { [number]: Vector3 } = {}
local renderPos: { [number]: Vector3 } = {}

-- ── Net ───────────────────────────────────────────────────────────────────────
blink.Spawn.On(function(batch)
    for _, payload in batch do
        if payload.type ~= "Zombie" then continue end
        local e = ref("server-" .. tostring(payload.id))
        if pool:get(e) then continue end
        local pos = payload.pos :: Vector3
        pool:acquire(e, CFrame.new(pos + UP), payload.size) -- size>1 = elite (bigger, red)
        target[e] = pos
        renderPos[e] = pos
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
    end
end)

-- ── Render ──────────────────────────────────────────────────────────────────────
local function move(dt: number)
    local a = math.min(1, LERP_RATE * dt)
    for e, tgt in target do
        local part = pool:get(e)
        if not part then continue end
        local rp = renderPos[e] or tgt
        local nrp = rp:Lerp(tgt, a)
        renderPos[e] = nrp

        local fx, fz = tgt.X - rp.X, tgt.Z - rp.Z -- velocity dir → facing
        local cf: CFrame
        if fx * fx + fz * fz > EPS2 then
            local p = Vector3.new(nrp.X, nrp.Y + RENDER_LIFT, nrp.Z)
            cf = CFrame.lookAt(p, p + Vector3.new(fx, 0, fz))
        else
            cf = CFrame.new(nrp.X, nrp.Y + RENDER_LIFT, nrp.Z) * part.CFrame.Rotation
        end
        pool:setCFrame(e, cf)
    end
    pool:flush()
end

scheduler.SYSTEM(move, phases.Heartbeat)
return 0
