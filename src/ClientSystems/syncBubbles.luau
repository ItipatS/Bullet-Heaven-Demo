-- ClientSystems/syncBubbles.luau
-- Renders bubble projectiles. The server broadcasts each shot once (origin, velocity, t0,
-- life); the client computes pos = origin + velocity*age every frame (same formula the
-- server damages with) and despawns after `life`. Skills (Nova/Barrage) + splits mean
-- hundreds can be live, so all positions are pushed in ONE BulkMoveTo per frame.
--!optimize 2
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))

local folder = Instance.new("Folder")
folder.Name = "Bubbles"
folder.Parent = workspace

local template = Instance.new("Part")
template.Shape = Enum.PartType.Ball
template.Size = Vector3.new(3, 3, 3)
template.Material = Enum.Material.Glass
template.Color = Color3.fromRGB(120, 200, 255)
template.Transparency = 0.3
template.Anchored = true
template.CanCollide = false
template.CanQuery = false
template.CanTouch = false
template.CastShadow = false

type Bubble = {
    part: BasePart,
    ox: number, oy: number, oz: number,
    vx: number, vy: number, vz: number,
    t0: number, life: number,
}
local active: { [number]: Bubble } = {}
local free: { BasePart } = {}

blink.FireBubble.On(function(batch)
    for _, b in batch do
        local part = table.remove(free) or template:Clone()
        local o = b.origin :: Vector3
        local c = b.color :: Vector3
        part.Size = Vector3.new(b.size, b.size, b.size)
        part.Color = Color3.new(c.X, c.Y, c.Z)
        part.Position = o
        part.Parent = folder
        active[b.id] = {
            part = part, ox = o.X, oy = o.Y, oz = o.Z,
            vx = b.velocity.X, vy = b.velocity.Y, vz = b.velocity.Z,
            t0 = b.t0, life = b.life,
        }
    end
end)

-- server retired these early (pierce used up) → despawn now so pierce looks finite
blink.RemoveBubble.On(function(ids)
    for _, id in ids do
        local b = active[id]
        if b then
            b.part.Parent = nil
            free[#free + 1] = b.part
            active[id] = nil
        end
    end
end)

-- Reused scratch arrays for the one-shot BulkMoveTo (no per-frame realloc).
local moveParts: { BasePart } = {}
local moveCfs: { CFrame } = {}

local function step()
    local now = workspace:GetServerTimeNow()
    local w = 0
    for id, b in active do
        local age = now - b.t0
        if age >= b.life then
            b.part.Parent = nil
            free[#free + 1] = b.part
            active[id] = nil -- removing the current key mid-iteration is fine; we never add here
        else
            w += 1
            moveParts[w] = b.part
            moveCfs[w] = CFrame.new(b.ox + b.vx * age, b.oy + b.vy * age, b.oz + b.vz * age)
        end
    end
    -- trim scratch tails from a previous (larger) frame, then move the whole field at once
    for i = #moveParts, w + 1, -1 do moveParts[i] = nil; moveCfs[i] = nil end
    if w > 0 then workspace:BulkMoveTo(moveParts, moveCfs, Enum.BulkMoveMode.FireCFrameChanged) end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
