-- ClientSystems/skillbar.luau
-- Pet skill button(s) with a cooldown readout. Press the key (or click the button) to use;
-- the dark overlay fills from the bottom = time remaining, with a seconds countdown. Cooldown
-- is predicted locally (server also enforces it authoritatively in combat.luau).
--   • Nova (R): the axolotl fires a full ring of bubbles. (E = Heal is reserved for when the
--     player-HP system exists.)
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std       = ReplicatedStorage.std
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))
local blink     = require(std:WaitForChild("ClientNet"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SKILL_NOVA = 1
local NOVA_CD    = 8 -- mirror combat.luau
local NOVA_KEY   = Enum.KeyCode.R

local cdUntil = 0

local gui = Instance.new("ScreenGui")
gui.Name = "SkillBar"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local btn = Instance.new("TextButton")
btn.AnchorPoint = Vector2.new(0.5, 1)
btn.Position = UDim2.new(0.5, 0, 1, -56)
btn.Size = UDim2.new(0, 72, 0, 72)
btn.BackgroundColor3 = Color3.fromRGB(40, 60, 90)
btn.BorderSizePixel = 0
btn.Text = ""
btn.Parent = gui
Instance.new("UICorner").Parent = btn

local nameLbl = Instance.new("TextLabel")
nameLbl.BackgroundTransparency = 1
nameLbl.Size = UDim2.new(1, 0, 1, 0)
nameLbl.Font = Enum.Font.GothamBold
nameLbl.TextSize = 16
nameLbl.TextColor3 = Color3.new(1, 1, 1)
nameLbl.Text = "Nova"
nameLbl.Parent = btn

local keyLbl = Instance.new("TextLabel")
keyLbl.BackgroundTransparency = 1
keyLbl.Position = UDim2.new(0, 5, 0, 3)
keyLbl.Size = UDim2.new(0, 22, 0, 18)
keyLbl.Font = Enum.Font.GothamBold
keyLbl.TextSize = 14
keyLbl.TextColor3 = Color3.fromRGB(180, 220, 255)
keyLbl.Text = "R"
keyLbl.TextXAlignment = Enum.TextXAlignment.Left
keyLbl.Parent = btn

-- cooldown overlay: fills from the bottom = fraction remaining
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

local function tryUse()
    local now = workspace:GetServerTimeNow()
    if now < cdUntil then return end
    cdUntil = now + NOVA_CD
    blink.UseSkill.Fire(SKILL_NOVA)
end

btn.Activated:Connect(tryUse)
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == NOVA_KEY then tryUse() end
end)

local function update()
    local rem = cdUntil - workspace:GetServerTimeNow()
    if rem > 0 then
        cdOverlay.Size = UDim2.new(1, 0, math.clamp(rem / NOVA_CD, 0, 1), 0)
        cdText.Text = string.format("%.1f", rem)
    else
        cdOverlay.Size = UDim2.new(1, 0, 0, 0)
        cdText.Text = ""
    end
end

scheduler.SYSTEM(update, phases.Heartbeat)
return 0
