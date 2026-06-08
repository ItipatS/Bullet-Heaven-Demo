-- ClientSystems/syncPet.luau
-- Renders one pet per equipped weapon, on a ring around the owner, all rotating to the cursor
-- aim. The local player's weapon list arrives via the Weapons event (each id → its animal
-- mesh); remote players just get a single axolotl. Also streams the local aim to the server.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local Pet       = require(std:WaitForChild("pet"))
local Config    = require(std:WaitForChild("config"))
local AimState  = require(std:WaitForChild("aimState"))
local Registry  = require(std:WaitForChild("petRegistry"))
local clientState = require(std:WaitForChild("clientState"))

local player = Players.LocalPlayer
local mouse  = player:GetMouse()

-- Where does aim come from? Touch → the on-screen stick (aimstick.luau writes AimState);
-- otherwise the mouse cursor. Mirrors the same check aimstick.luau uses to build itself.
local mode = Config.Controls.AIM_STICK
local USE_STICK = mode == "always"
    or (mode == "auto" and UserInputService.TouchEnabled and not UserInputService.MouseEnabled)

local folder = Instance.new("Folder")
folder.Name = "Pets"
folder.Parent = workspace

local Animals = ReplicatedStorage:WaitForChild("Animals")

local function makePart(meshName: string): BasePart
    local src = Animals:FindFirstChild(meshName)
    local p: BasePart
    if src and src:IsA("BasePart") then
        p = src:Clone()
    else
        p = Instance.new("Part")
        p.Shape = Enum.PartType.Ball
        p.Size = Vector3.new(2, 2, 2)
        p.Color = Color3.fromRGB(255, 150, 200)
    end
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.CastShadow = false
    return p
end

-- local player's pets (one per weapon, aligned to localIds)
local localIds: { string } = { "axolotl" }
local localPets: { BasePart } = {}

local function rebuildLocalPets()
    for _, pt in localPets do pt:Destroy() end
    table.clear(localPets)
    for i, id in localIds do
        local pt = makePart(Registry.meshName(id))
        pt.Parent = folder
        localPets[i] = pt
    end
end
rebuildLocalPets()

clientState.onWeapons(function(ids)
    localIds = ids
    rebuildLocalPets()
end)

local otherPets: { [Player]: BasePart } = {}

local BOB_FREQ, BOB_AMP, ROLL_AMP = 12, 0.5, 0.25
local sendAcc, SEND_DT = 0, 0.05

local function step(dt: number)
    local now = workspace:GetServerTimeNow()

    -- local player: aim + one pet per weapon on the ring
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        for _, pt in localPets do if pt.Parent ~= folder then pt.Parent = folder end end -- show on spawn
        local facing
        if USE_STICK then
            facing = AimState.get() -- world-space aim from the mobile thumbstick
        else
            facing = mouse.UnitRay.Direction
            facing = if facing.Magnitude > 1e-3 then facing.Unit else Vector3.new(0, 0, -1)
        end
        sendAcc += dt
        if sendAcc >= SEND_DT then sendAcc = 0; blink.Aim.Fire(facing) end

        local vel = (root :: BasePart).AssemblyLinearVelocity
        local moving = (vel.X * vel.X + vel.Z * vel.Z) > 4
        local bob = if moving then math.sin(now * BOB_FREQ) * BOB_AMP else 0
        local roll = if moving then math.sin(now * BOB_FREQ) * ROLL_AMP else 0

        local n = #localPets
        for i, pt in localPets do
            local pos = Pet.slotPos((root :: BasePart).Position, i - 1, n) + Vector3.new(0, bob, 0)
            pt.CFrame = CFrame.lookAt(pos, pos + facing) * CFrame.Angles(0, 0, roll)
        end
    else
        -- no character (menu / dead): hide local pets so they don't float in the menu camera shot
        for _, pt in localPets do if pt.Parent then pt.Parent = nil end end
    end

    -- remote players: a single pet
    for _, plr in Players:GetPlayers() do
        if plr == player then continue end
        local c = plr.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if not r then continue end
        local pt = otherPets[plr]
        if not pt then pt = makePart("Axolotl"); pt.Parent = folder; otherPets[plr] = pt end
        local lv = (r :: BasePart).CFrame.LookVector
        local f = if lv.Magnitude > 1e-3 then lv.Unit else Vector3.new(0, 0, -1)
        local pos = Pet.pos((r :: BasePart).Position)
        pt.CFrame = CFrame.lookAt(pos, pos + f)
    end
end

Players.PlayerRemoving:Connect(function(plr)
    local pt = otherPets[plr]
    if pt then pt:Destroy(); otherPets[plr] = nil end
end)

scheduler.SYSTEM(step, phases.Heartbeat)
return 0
