-- ClientSystems/syncEffects.luau
-- One-shot AoE visuals for the non-projectile weapons (server applies the damage; this is
-- purely cosmetic): 1=aura pulse ring, 2=melee swing arc, 3=stone drop (falls then flashes).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Debris            = game:GetService("Debris")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))

local DROP_DELAY = 0.8 -- mirror combat.luau

local folder = Instance.new("Folder")
folder.Name = "FX"
folder.Parent = workspace

-- a flat translucent disc (cylinder laid on its side) on the ground at `pos`
local function disc(pos: Vector3, diameter: number, color: Color3): BasePart
    local p = Instance.new("Part")
    p.Shape = Enum.PartType.Cylinder
    p.Size = Vector3.new(0.4, diameter, diameter)
    p.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    p.Material = Enum.Material.Neon
    p.Color = color
    p.Transparency = 0.45
    p.Parent = folder
    return p
end

blink.Effect.On(function(batch)
    for _, e in batch do
        local pos = e.pos :: Vector3
        local r = e.radius

        if e.kind == 1 then -- aura pulse
            local d = disc(pos, r * 2, Color3.fromRGB(120, 255, 150))
            TweenService:Create(d, TweenInfo.new(0.35), { Transparency = 1, Size = Vector3.new(0.4, r * 2.2, r * 2.2) }):Play()
            Debris:AddItem(d, 0.4)

        elseif e.kind == 2 then -- melee swing
            local dir = e.dir :: Vector3
            local center = pos + dir * (r * 0.5) + Vector3.new(0, 2, 0)
            local d = disc(center, r, Color3.fromRGB(255, 130, 130))
            TweenService:Create(d, TweenInfo.new(0.2), { Transparency = 1 }):Play()
            Debris:AddItem(d, 0.25)

        elseif e.kind == 3 then -- stone drop
            local stone = Instance.new("Part")
            stone.Shape = Enum.PartType.Ball
            stone.Size = Vector3.new(r, r, r)
            stone.Color = Color3.fromRGB(120, 100, 80)
            stone.Material = Enum.Material.Slate
            stone.Anchored = true
            stone.CanCollide = false
            stone.CanQuery = false
            stone.CastShadow = false
            stone.CFrame = CFrame.new(pos + Vector3.new(0, 45, 0))
            stone.Parent = folder
            TweenService:Create(stone, TweenInfo.new(DROP_DELAY, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                { CFrame = CFrame.new(pos + Vector3.new(0, r * 0.4, 0)) }):Play()
            Debris:AddItem(stone, DROP_DELAY + 0.3)
            task.delay(DROP_DELAY, function()
                local ring = disc(pos, r * 2, Color3.fromRGB(255, 170, 70))
                TweenService:Create(ring, TweenInfo.new(0.3), { Transparency = 1, Size = Vector3.new(0.4, r * 2.4, r * 2.4) }):Play()
                Debris:AddItem(ring, 0.35)
            end)
        end
    end
end)

return 0
