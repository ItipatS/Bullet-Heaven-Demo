-- ClientSystems/mainmenu.luau
-- Simple start screen shown on join. The world is idle until you press PLAY (waves don't spawn
-- server-side until the first Restart — see SpawnMob.running), so you're safe at the menu. PLAY
-- fires the same Restart event the GameOver screen uses → the server starts a fresh run and
-- loads your character. After death the GameOver screen handles replay; this menu is join-only.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "MainMenu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20 -- above the GameOver screen (10)
gui.Enabled = true
gui.Parent = playerGui

local dim = Instance.new("Frame")
dim.Size = UDim2.new(1, 0, 1, 0)
dim.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
dim.BackgroundTransparency = 0.15
dim.BorderSizePixel = 0
dim.Parent = gui

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.new(0.5, 0, 0.32, 0)
title.Size = UDim2.new(0, 700, 0, 80)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.TextSize = 60
title.TextColor3 = Color3.fromRGB(150, 255, 170)
title.TextStrokeTransparency = 0.5
title.Text = "ZOMBIE HORDE"
title.Parent = gui

local subtitle = Instance.new("TextLabel")
subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
subtitle.Position = UDim2.new(0.5, 0, 0.32, 56)
subtitle.Size = UDim2.new(0, 700, 0, 30)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 20
subtitle.TextColor3 = Color3.fromRGB(190, 200, 210)
subtitle.Text = "Survive the waves. Pets fight for you."
subtitle.Parent = gui

local btn = Instance.new("TextButton")
btn.AnchorPoint = Vector2.new(0.5, 0.5)
btn.Position = UDim2.new(0.5, 0, 0.55, 0)
btn.Size = UDim2.new(0, 240, 0, 60)
btn.BackgroundColor3 = Color3.fromRGB(70, 150, 90)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 26
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Text = "▶  PLAY"
btn.Parent = gui
Instance.new("UICorner").Parent = btn

-- persisted best stats (from the DataStore profile)
local best = Instance.new("TextLabel")
best.AnchorPoint = Vector2.new(0.5, 0.5)
best.Position = UDim2.new(0.5, 0, 0.64, 0)
best.Size = UDim2.new(0, 700, 0, 26)
best.BackgroundTransparency = 1
best.Font = Enum.Font.GothamBold
best.TextSize = 18
best.TextColor3 = Color3.fromRGB(255, 215, 110)
best.Text = ""
best.Parent = gui

blink.Profile.On(function(p)
    local m, s = p.bestTime // 60, p.bestTime % 60
    best.Text = string.format(
        "⛁ %d Tix      Best: Wave %d  •  Lv %d  •  %d:%02d  •  %d kills  •  %d runs",
        p.tix, p.bestWave, p.bestLevel, m, s, p.totalKills, p.runs)
end)

local controls = Instance.new("TextLabel")
controls.AnchorPoint = Vector2.new(0.5, 0.5)
controls.Position = UDim2.new(0.5, 0, 0.72, 0)
controls.Size = UDim2.new(0, 700, 0, 30)
controls.BackgroundTransparency = 1
controls.Font = Enum.Font.GothamMedium
controls.TextSize = 18
controls.TextColor3 = Color3.fromRGB(170, 180, 195)
controls.Text = "Move: WASD   •   Aim: Mouse   •   Skills: Q / E / R   •   Pets: B"
controls.Parent = gui

local started = false
local function play()
    if started then return end
    started = true
    gui.Enabled = false
    blink.Restart.Fire(1) -- same path as the GameOver Restart: fresh run + waves begin
end

btn.Activated:Connect(play)
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not gui.Enabled then return end
    if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Space then play() end
end)

return 0
