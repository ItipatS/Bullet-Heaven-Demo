-- ClientSystems/gameover.luau
-- Death screen: on GameOver, show time survived + level reached and a Restart button that
-- starts a fresh run (Restart → server resets the player).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "GameOver"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.Enabled = false
gui.Parent = playerGui

local dim = Instance.new("Frame")
dim.Size = UDim2.new(1, 0, 1, 0)
dim.BackgroundColor3 = Color3.new(0, 0, 0)
dim.BackgroundTransparency = 0.4
dim.BorderSizePixel = 0
dim.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.new(0.5, 0, 0.5, 0)
panel.Size = UDim2.new(0, 380, 0, 220)
panel.BackgroundColor3 = Color3.fromRGB(28, 30, 40)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner").Parent = panel

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 0, 0, 20)
title.Size = UDim2.new(1, 0, 0, 42)
title.Font = Enum.Font.GothamBold
title.TextSize = 32
title.TextColor3 = Color3.fromRGB(255, 90, 90)
title.Text = "YOU DIED"
title.Parent = panel

local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.new(0, 0, 0, 78)
info.Size = UDim2.new(1, 0, 0, 50)
info.Font = Enum.Font.Gotham
info.TextSize = 18
info.TextColor3 = Color3.new(1, 1, 1)
info.Text = ""
info.Parent = panel

local btn = Instance.new("TextButton")
btn.Name = "RestartBtn"
btn.AnchorPoint = Vector2.new(0.5, 1)
btn.Position = UDim2.new(0.5, 0, 1, -22)
btn.Size = UDim2.new(0, 200, 0, 46)
btn.BackgroundColor3 = Color3.fromRGB(80, 150, 95)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 20
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Text = "RESTART"
btn.Parent = panel
Instance.new("UICorner").Parent = btn

local function doRestart()
    if not gui.Enabled then return end
    gui.Enabled = false
    blink.Restart.Fire(1)
end

btn.Activated:Connect(doRestart)
UserInputService.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Space then
        doRestart()
    end
end)

blink.GameOver.On(function(msg)
    local t = math.floor(msg.time)
    info.Text = string.format("Survived  %d:%02d      •      Level %d", math.floor(t / 60), t % 60, msg.level)
    gui.Enabled = true
end)

return 0
