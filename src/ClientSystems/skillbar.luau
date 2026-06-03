-- ClientSystems/skillbar.luau
-- Three pet-skill buttons (Q / E / R = equipped slot 1 / 2 / 3). Each shows the equipped pet's
-- skill name (from the registry) and a cooldown readout (overlay fills from the bottom = time
-- left). Press the key or click to use → UseSkill.Fire(slot); the server runs that pet's skill
-- on its registry cooldown (authoritative). Cooldown is predicted locally for the UI.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))
local Registry  = require(std:WaitForChild("petRegistry"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SLOT_KEYS = { Enum.KeyCode.Q, Enum.KeyCode.E, Enum.KeyCode.R }
local KEY_NAME  = { "Q", "E", "R" }
local KEY_TO_SLOT = { [Enum.KeyCode.Q] = 1, [Enum.KeyCode.E] = 2, [Enum.KeyCode.R] = 3 }

local equippedIds: { string } = {}      -- slot → pet id (from Weapons)
local cdUntil: { number } = { 0, 0, 0 } -- slot → predicted cd end (server time)

local gui = Instance.new("ScreenGui")
gui.Name = "SkillBar"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local holder = Instance.new("Frame")
holder.AnchorPoint = Vector2.new(0.5, 1)
holder.Position = UDim2.new(0.5, 0, 1, -52)
holder.Size = UDim2.new(0, 3 * 72 + 2 * 10, 0, 72)
holder.BackgroundTransparency = 1
holder.Parent = gui
local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 10)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = holder

type SlotUi = { btn: TextButton, name: TextLabel, cd: Frame, cdText: TextLabel }
local slots: { SlotUi } = {}

local function skillForSlot(slot: number): { name: string, desc: string, cooldown: number }?
    local id = equippedIds[slot]
    local pet = id and Registry.pets[id]
    return pet and pet.skill or nil
end

local function tryUse(slot: number)
    local sk = skillForSlot(slot)
    if not sk then return end
    local now = workspace:GetServerTimeNow()
    if now < cdUntil[slot] then return end
    cdUntil[slot] = now + sk.cooldown
    blink.UseSkill.Fire(slot)
end

for i = 1, 3 do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 72, 0, 72)
    btn.BackgroundColor3 = Color3.fromRGB(40, 60, 90)
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.LayoutOrder = i
    btn.Parent = holder
    Instance.new("UICorner").Parent = btn

    local nameLbl = Instance.new("TextLabel")
    nameLbl.BackgroundTransparency = 1
    nameLbl.Size = UDim2.new(1, -4, 1, 0)
    nameLbl.Position = UDim2.new(0, 2, 0, 0)
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextSize = 14
    nameLbl.TextWrapped = true
    nameLbl.TextColor3 = Color3.new(1, 1, 1)
    nameLbl.Text = ""
    nameLbl.Parent = btn

    local keyLbl = Instance.new("TextLabel")
    keyLbl.BackgroundTransparency = 1
    keyLbl.Position = UDim2.new(0, 5, 0, 3)
    keyLbl.Size = UDim2.new(0, 22, 0, 18)
    keyLbl.Font = Enum.Font.GothamBold
    keyLbl.TextSize = 14
    keyLbl.TextColor3 = Color3.fromRGB(180, 220, 255)
    keyLbl.Text = KEY_NAME[i]
    keyLbl.TextXAlignment = Enum.TextXAlignment.Left
    keyLbl.Parent = btn

    local cdOverlay = Instance.new("Frame")
    cdOverlay.AnchorPoint = Vector2.new(0, 1)
    cdOverlay.Position = UDim2.new(0, 0, 1, 0)
    cdOverlay.Size = UDim2.new(1, 0, 0, 0)
    cdOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    cdOverlay.BackgroundTransparency = 0.45
    cdOverlay.BorderSizePixel = 0
    cdOverlay.ZIndex = 2
    cdOverlay.Parent = btn
    Instance.new("UICorner").Parent = cdOverlay

    local cdText = Instance.new("TextLabel")
    cdText.BackgroundTransparency = 1
    cdText.Size = UDim2.new(1, 0, 1, 0)
    cdText.ZIndex = 3
    cdText.Font = Enum.Font.GothamBold
    cdText.TextSize = 22
    cdText.TextColor3 = Color3.new(1, 1, 1)
    cdText.Text = ""
    cdText.Parent = btn

    local slot = i
    btn.Activated:Connect(function() tryUse(slot) end)
    slots[i] = { btn = btn, name = nameLbl, cd = cdOverlay, cdText = cdText }
end

local function refresh()
    for i = 1, 3 do
        local ui = slots[i]
        local sk = skillForSlot(i)
        if sk then
            ui.btn.Visible = true
            ui.name.Text = sk.name
        else
            ui.btn.Visible = false
        end
    end
end

blink.Weapons.On(function(ids)
    equippedIds = ids
    refresh()
end)

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    local slot = KEY_TO_SLOT[input.KeyCode]
    if slot then tryUse(slot) end
end)

local function update()
    local now = workspace:GetServerTimeNow()
    for i = 1, 3 do
        local ui = slots[i]
        if not ui.btn.Visible then continue end
        local sk = skillForSlot(i)
        local cd = sk and sk.cooldown or 1
        local rem = cdUntil[i] - now
        if rem > 0 then
            ui.cd.Size = UDim2.new(1, 0, math.clamp(rem / cd, 0, 1), 0)
            ui.cdText.Text = string.format("%.1f", rem)
        else
            ui.cd.Size = UDim2.new(1, 0, 0, 0)
            ui.cdText.Text = ""
        end
    end
end

scheduler.SYSTEM(update, phases.Heartbeat)
return 0
