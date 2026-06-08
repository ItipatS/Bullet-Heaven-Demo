-- ClientSystems/mainmenu.luau
-- Start screen. The world is idle until you press PLAY (waves don't spawn server-side until the
-- first Play — see SpawnMob.running), so you're safe at the menu. PLAY fires the Restart event:
-- the server JOINS you into the live round if one is running, else starts a fresh one. The menu
-- also RE-SHOWS when a round ends (RoundOver) so a ghost who was spectating can Play the next one.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

local std   = ReplicatedStorage.std
local blink = require(std:WaitForChild("ClientNet"))
local clientPlay = require(std:WaitForChild("clientPlay"))

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
dim.BackgroundTransparency = 0.4 -- semi-transparent so the orbiting map shows behind the menu
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
title.Text = "WHATEVER HORDE"
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
btn.Position = UDim2.new(0.5, 0, 0.475, 0)
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
best.Position = UDim2.new(0.5, 0, 0.67, 0)
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
controls.Position = UDim2.new(0.5, 0, 0.75, 0)
controls.Size = UDim2.new(0, 700, 0, 30)
controls.BackgroundTransparency = 1
controls.Font = Enum.Font.GothamMedium
controls.TextSize = 18
controls.TextColor3 = Color3.fromRGB(170, 180, 195)
controls.Text = if UserInputService.TouchEnabled and not UserInputService.MouseEnabled
    then "Move: left stick   •   Aim: right stick   •   Skills: on-screen buttons"
    else "Move: WASD   •   Aim: Mouse   •   Skills: Q "
controls.Parent = gui

-- ── Cinematic camera: slow orbit around the MAP MODEL while at the menu ─────────────
-- Frame from a MANUAL AABB of workspace.Map's parts (its GetBoundingBox is degenerate, and the
-- pathfinding waypoints have far outliers that framed it too wide / sky-facing).
local center, orbitR, orbitH = Vector3.new(0, 30, 0), 240, 120
local map = workspace:FindFirstChild("Map") or workspace:WaitForChild("Map", 5)
if map then
    local minv, maxv, n = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9), 0
    for _, d in map:GetDescendants() do
        if d:IsA("BasePart") then
            n += 1
            local p = d.Position
            minv, maxv = minv:Min(p), maxv:Max(p)
        end
    end
    if n > 0 then
        center = (minv + maxv) * 0.5
        local span = math.max(maxv.X - minv.X, maxv.Z - minv.Z)
        orbitR = span * 0.7 + 20  -- close in so the map fills the shot
        orbitH = span * 0.7 + 30  -- high enough for a steep ~45° downward look (map, not sky)
    end
end

local orbiting = false
local started = false
local angle = 0
local orbitConn: RBXScriptConnection? = nil

-- Slow cinematic ORBIT around the map. Heartbeat (not RenderStepped) so it keeps running even when
-- the client isn't actively rendering; re-asserts Scriptable each frame since CurrentCamera can be
-- replaced on spawn.
local function startOrbit()
    if orbitConn then return end
    orbiting = true
    orbitConn = RunService.Heartbeat:Connect(function(dt)
        if not orbiting then return end
        angle += dt * 0.08 -- slow rotation
        local camera = workspace.CurrentCamera
        camera.CameraType = Enum.CameraType.Scriptable
        local eye = center + Vector3.new(math.cos(angle) * orbitR, orbitH, math.sin(angle) * orbitR)
        camera.CFrame = CFrame.lookAt(eye, center)
    end)
end

local function stopOrbit()
    orbiting = false
    if orbitConn then orbitConn:Disconnect(); orbitConn = nil end
end

-- Re-enter the menu (on join, and again when a round ends so a freed ghost can Play the next one).
local function showMenu()
    started = false
    gui.Enabled = true
    startOrbit()
    clientPlay.set("menu") -- loadout panel usable, gameplay HUD hidden
end

local function play()
    if started then return end
    started = true
    gui.Enabled = false
    clientPlay.set("playing") -- show the gameplay HUD + skill button, lock the loadout
    blink.Restart.Fire(1) -- starts a fresh round, OR joins the one in progress (server decides)
    -- KEEP the orbit until the server warps our (parked, anchored) body into the arena — only then
    -- hand the camera over. Otherwise Custom would briefly snap to the lobby body off in the void.
    -- Detect arrival by the root un-anchoring (warp-in) or a fresh body (the post-death reload).
    task.spawn(function()
        local startChar = player.Character
        for _ = 1, 600 do -- ~10s safety cap
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if (hrp and not (hrp :: BasePart).Anchored) or (char and char ~= startChar) then break end
            RunService.Heartbeat:Wait()
        end
        stopOrbit()
        workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
    end)
end

btn.Activated:Connect(play)
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or not gui.Enabled then return end
    if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Space then play() end
end)

-- Round ended on the server → ghosts are freed; come back to the menu so PLAY works again.
blink.RoundOver.On(function() showMenu() end)

startOrbit() -- orbit immediately on join
return 0
