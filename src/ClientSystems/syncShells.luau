-- ClientSystems/syncShells.luau
-- Turtle visual: when the local run loadout includes the turtle, render shells orbiting the player.
-- The server damages at rotating points using the synced clock (combat.fireStep "orbit"); we orbit the
-- visual with the SAME clock + speed so the shells line up with where the hits land. Purely cosmetic.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local clientState = require(std:WaitForChild("clientState"))
local Registry  = require(std:WaitForChild("petRegistry"))

local Animals = ReplicatedStorage:WaitForChild("Animals")
local player  = Players.LocalPlayer

local SHELL_COUNT = 3
local ORBIT_R     = 10   -- matches combat orbit base (7 + turtle base radius 3)
local SPIN        = 2.2  -- matches combat fireStep "orbit" baseA = now * 2.2

local folder = Instance.new("Folder")
folder.Name = "TurtleShells"
folder.Parent = workspace

local shells: { BasePart } = {}
local active = false

local function makeShell(): BasePart
    local src = Animals:FindFirstChild(Registry.meshName("turtle"))
    local p: BasePart
    if src and src:IsA("BasePart") then
        p = src:Clone()
        p.Size = src.Size * 0.5
    else
        p = Instance.new("Part")
        p.Shape = Enum.PartType.Ball
        p.Size = Vector3.new(2, 2, 2)
        p.Color = Color3.fromRGB(110, 200, 130)
    end
    p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
    p.Parent = folder
    return p
end

local function setActive(on: boolean)
    if on == active then return end
    active = on
    if on then
        for _ = 1, SHELL_COUNT do shells[#shells + 1] = makeShell() end
    else
        for _, s in shells do s:Destroy() end
        table.clear(shells)
    end
end

clientState.onWeapons(function(ids)
    local hasTurtle = false
    for _, id in ids do if id == "turtle" then hasTurtle = true break end end
    setActive(hasTurtle)
end)

local function step(_dt: number)
    if not active then return end
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local pos = (hrp :: BasePart).Position
    local baseA = workspace:GetServerTimeNow() * SPIN
    for i, s in shells do
        local a = baseA + ((i - 1) / SHELL_COUNT) * (2 * math.pi)
        s.CFrame = CFrame.new(pos.X + math.cos(a) * ORBIT_R, pos.Y, pos.Z + math.sin(a) * ORBIT_R)
            * CFrame.Angles(0, -a, 0)
    end
end

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
