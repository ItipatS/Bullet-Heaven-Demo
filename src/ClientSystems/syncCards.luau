-- ClientSystems/syncCards.luau
-- Progression UI: a small Level + XP-bar HUD (Stats), and the level-up upgrade picker —
-- 3 cards on the right (LevelUp). Clicking one fires ChooseCard(index); the server applies
-- it and (if more level-ups are queued) sends the next set.
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local std       = ReplicatedStorage.std
local blink     = require(std:WaitForChild("ClientNet"))
local phases    = require(std:WaitForChild("phases"))
local scheduler = require(std:WaitForChild("scheduler"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "Progression"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- ── HUD: Level + XP bar (top center) ─────────────────────────────────────────────
local hud = Instance.new("Frame")
hud.AnchorPoint = Vector2.new(0.5, 0)
hud.Position = UDim2.new(0.5, 0, 0, 8)
hud.Size = UDim2.new(0, 320, 0, 26)
hud.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
hud.BackgroundTransparency = 0.35
hud.BorderSizePixel = 0
hud.Parent = gui
Instance.new("UICorner").Parent = hud

local xpFill = Instance.new("Frame")
xpFill.Size = UDim2.new(0, 0, 1, 0)
xpFill.BackgroundColor3 = Color3.fromRGB(120, 220, 140)
xpFill.BorderSizePixel = 0
xpFill.Parent = hud
Instance.new("UICorner").Parent = xpFill

local lvlLabel = Instance.new("TextLabel")
lvlLabel.BackgroundTransparency = 1
lvlLabel.Size = UDim2.new(1, 0, 1, 0)
lvlLabel.Font = Enum.Font.GothamBold
lvlLabel.TextScaled = false
lvlLabel.TextSize = 16
lvlLabel.TextColor3 = Color3.new(1, 1, 1)
lvlLabel.Text = "Lv 1"
lvlLabel.ZIndex = 2
lvlLabel.Parent = hud

-- HP bar (just under the level/XP bar)
local hpBar = Instance.new("Frame")
hpBar.AnchorPoint = Vector2.new(0.5, 0)
hpBar.Position = UDim2.new(0.5, 0, 0, 38)
hpBar.Size = UDim2.new(0, 320, 0, 20)
hpBar.BackgroundColor3 = Color3.fromRGB(45, 22, 22)
hpBar.BackgroundTransparency = 0.3
hpBar.BorderSizePixel = 0
hpBar.Parent = gui
Instance.new("UICorner").Parent = hpBar

local hpFill = Instance.new("Frame")
hpFill.Size = UDim2.new(1, 0, 1, 0)
hpFill.BackgroundColor3 = Color3.fromRGB(230, 70, 70)
hpFill.BorderSizePixel = 0
hpFill.Parent = hpBar
Instance.new("UICorner").Parent = hpFill

local hpLabel = Instance.new("TextLabel")
hpLabel.BackgroundTransparency = 1
hpLabel.Size = UDim2.new(1, 0, 1, 0)
hpLabel.ZIndex = 2
hpLabel.Font = Enum.Font.GothamBold
hpLabel.TextSize = 14
hpLabel.TextColor3 = Color3.new(1, 1, 1)
hpLabel.Text = "100 / 100"
hpLabel.Parent = hpBar

-- ── Enemy count (top-left) ───────────────────────────────────────────────────────
local enemyLabel = Instance.new("TextLabel")
enemyLabel.AnchorPoint = Vector2.new(0, 0)
enemyLabel.Position = UDim2.new(0, 12, 0.5, 8)
enemyLabel.Size = UDim2.new(0, 200, 0, 24)
enemyLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
enemyLabel.BackgroundTransparency = 0.35
enemyLabel.BorderSizePixel = 0
enemyLabel.Font = Enum.Font.GothamBold
enemyLabel.TextSize = 16
enemyLabel.TextColor3 = Color3.fromRGB(255, 160, 160)
enemyLabel.TextXAlignment = Enum.TextXAlignment.Left
enemyLabel.Text = "  Mobs: 0"
enemyLabel.Parent = gui
Instance.new("UICorner").Parent = enemyLabel

-- ── Wave banner (center, fades) ──────────────────────────────────────────────────
local waveBanner = Instance.new("TextLabel")
waveBanner.AnchorPoint = Vector2.new(0.5, 0.5)
waveBanner.Position = UDim2.new(0.5, 0, 0.3, 0)
waveBanner.Size = UDim2.new(0, 420, 0, 64)
waveBanner.BackgroundTransparency = 1
waveBanner.Font = Enum.Font.GothamBlack
waveBanner.TextSize = 46
waveBanner.TextColor3 = Color3.fromRGB(255, 230, 150)
waveBanner.TextStrokeTransparency = 1
waveBanner.TextTransparency = 1
waveBanner.Text = ""
waveBanner.Parent = gui

blink.WaveStart.On(function(wave)
    waveBanner.Text = "WAVE " .. wave
    waveBanner.TextTransparency = 0
    waveBanner.TextStrokeTransparency = 0.3
    TweenService:Create(waveBanner, TweenInfo.new(1.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end)

-- ── Toast (center, just below the wave banner) — e.g. "New pet: Bear!" ─────────────
local toast = Instance.new("TextLabel")
toast.AnchorPoint = Vector2.new(0.5, 0.5)
toast.Position = UDim2.new(0.5, 0, 0.42, 0)
toast.Size = UDim2.new(0, 460, 0, 44)
toast.BackgroundTransparency = 1
toast.Font = Enum.Font.GothamBlack
toast.TextSize = 30
toast.TextColor3 = Color3.fromRGB(150, 255, 175)
toast.TextStrokeTransparency = 1
toast.TextTransparency = 1
toast.Text = ""
toast.Parent = gui

blink.Toast.On(function(msg)
    toast.Text = msg
    toast.TextTransparency = 0
    toast.TextStrokeTransparency = 0.3
    TweenService:Create(toast, TweenInfo.new(2.2), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end)

-- ── Cards: 3 on the right, hidden until a level-up ───────────────────────────────
local cardsHolder = Instance.new("Frame")
cardsHolder.AnchorPoint = Vector2.new(1, 0.5)
cardsHolder.Position = UDim2.new(1, -16, 0.5, 0)
cardsHolder.Size = UDim2.new(0, 240, 0, 360)
cardsHolder.BackgroundTransparency = 1
cardsHolder.Visible = false
cardsHolder.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.Padding = UDim.new(0, 12)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.Parent = cardsHolder

local cards: { TextButton } = {}
for i = 1, 3 do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 100)
    btn.BackgroundColor3 = Color3.fromRGB(34, 36, 48)
    btn.AutoButtonColor = true
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.LayoutOrder = i
    btn.Parent = cardsHolder
    Instance.new("UICorner").Parent = btn

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 10, 0, 8)
    title.Size = UDim2.new(1, -20, 0, 26)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(180, 230, 255)
    title.Text = ""
    title.Parent = btn

    local desc = Instance.new("TextLabel")
    desc.Name = "Desc"
    desc.BackgroundTransparency = 1
    desc.Position = UDim2.new(0, 10, 0, 38)
    desc.Size = UDim2.new(1, -20, 1, -46)
    desc.Font = Enum.Font.Gotham
    desc.TextSize = 14
    desc.TextWrapped = true
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextYAlignment = Enum.TextYAlignment.Top
    desc.TextColor3 = Color3.fromRGB(220, 220, 230)
    desc.Text = ""
    desc.Parent = btn

    local tag = Instance.new("TextLabel")
    tag.Name = "Tag"
    tag.BackgroundTransparency = 1
    tag.AnchorPoint = Vector2.new(1, 0)
    tag.Position = UDim2.new(1, -8, 0, 6)
    tag.Size = UDim2.new(0, 120, 0, 16)
    tag.Font = Enum.Font.GothamBold
    tag.TextSize = 12
    tag.TextXAlignment = Enum.TextXAlignment.Right
    tag.Text = ""
    tag.Parent = btn

    btn.Activated:Connect(function()
        blink.ChooseCard.Fire(i)
        cardsHolder.Visible = false
    end)
    cards[i] = btn
end

-- ── Net ───────────────────────────────────────────────────────────────────────
blink.Stats.On(function(s)
    lvlLabel.Text = string.format("Lv %d   (%d/%d)", s.level, s.xp, s.xpNext)
    local frac = if s.xpNext > 0 then math.clamp(s.xp / s.xpNext, 0, 1) else 0
    xpFill.Size = UDim2.new(frac, 0, 1, 0)
    if s.maxHp and s.maxHp > 0 then
        hpFill.Size = UDim2.new(math.clamp(s.hp / s.maxHp, 0, 1), 0, 1, 0)
        hpLabel.Text = string.format("%d / %d", s.hp, s.maxHp)
    end
end)

blink.LevelUp.On(function(choices)
    for i = 1, 3 do
        local btn = cards[i]
        local c = choices[i]
        if c then
            btn.Visible = true;
            (btn:FindFirstChild("Title") :: TextLabel).Text = c.title;
            (btn:FindFirstChild("Desc") :: TextLabel).Text = c.desc
            -- kind: 0 player stat, 1 pet stat, 2 pet perk, 3 new pet
            local tag = btn:FindFirstChild("Tag") :: TextLabel
            if c.kind == 3 then
                tag.Text = "✦ NEW PET · " .. c.weapon
                tag.TextColor3 = Color3.fromRGB(130, 255, 150)
            elseif c.kind == 2 then
                tag.Text = "◆ PERK · " .. c.weapon
                tag.TextColor3 = Color3.fromRGB(210, 150, 255)
            elseif c.kind == 1 then
                tag.Text = "◈ " .. c.weapon .. " STAT"
                tag.TextColor3 = Color3.fromRGB(140, 200, 255)
            else
                tag.Text = "★ PLAYER STAT"
                tag.TextColor3 = Color3.fromRGB(255, 215, 120)
            end
        else
            btn.Visible = false
        end
    end
    cardsHolder.Visible = true
end)

-- enemy count (cheap; zombies in Mobs + UFOs), refreshed ~3 Hz. Look folders up lazily —
-- WaitForChild at load could deadlock the system loader if this runs first.

local mobsFolder: Instance? = nil
local ufoFolder: Instance? = nil
local acc = 0
local function updateCount(dt: number)
    acc += dt
    if acc < 0.3 then return end
    acc = 0
    mobsFolder = mobsFolder or workspace:FindFirstChild("Mobs")
    ufoFolder = ufoFolder or workspace:FindFirstChild("UFOs")
    local n = (mobsFolder and #mobsFolder:GetChildren() or 0) + (ufoFolder and #ufoFolder:GetChildren() or 0)
    enemyLabel.Text = "  Mobs: " .. n
end
scheduler.SYSTEM(updateCount, phases.Heartbeat)

return 0
