-- ClientSystems/weaponpanel.luau
-- Pet loadout panel (toggle with B, or the on-screen "PETS" button). Left column lists every
-- pet you OWN (Unlocked event); the ones EQUIPPED (Weapons event) are highlighted. Click a row
-- to SELECT it — the right pane shows that pet's stats, signature skill, and possible perks,
-- all read straight from the shared petRegistry (the single source of truth). The detail pane's
-- Equip/Unequip button (or a row's number key) changes the loadout via SwitchWeapons; the
-- server validates and echoes the equipped set back (max 3, always keep ≥1).
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local std      = ReplicatedStorage.std
local blink    = require(std:WaitForChild("ClientNet"))
local Registry = require(std:WaitForChild("petRegistry"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local MAX = 3

local gui = Instance.new("ScreenGui")
gui.Name = "WeaponPanel"
gui.ResetOnSpawn = false
gui.Parent = playerGui

-- ── On-screen open button (always visible) ────────────────────────────────────────
local openBtn = Instance.new("TextButton")
openBtn.AnchorPoint = Vector2.new(0, 1)
openBtn.Position = UDim2.new(0, 16, 1, -16)
openBtn.Size = UDim2.new(0, 120, 0, 38)
openBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 60)
openBtn.BorderSizePixel = 0
openBtn.Font = Enum.Font.GothamBold
openBtn.TextSize = 15
openBtn.TextColor3 = Color3.new(1, 1, 1)
openBtn.Text = "🐾 PETS  [B]"
openBtn.Parent = gui
Instance.new("UICorner").Parent = openBtn

-- ── Panel ─────────────────────────────────────────────────────────────────────────
local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0, 0.5)
frame.Position = UDim2.new(0, 16, 0.5, 0)
frame.Size = UDim2.new(0, 520, 0, 360)
frame.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
frame.BackgroundTransparency = 0.05
frame.BorderSizePixel = 0
frame.Visible = false
frame.Parent = gui
Instance.new("UICorner").Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 12, 0, 8)
title.Size = UDim2.new(1, -24, 0, 26)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "PETS  (equip up to 3) — [B] to close"
title.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, -10, 0, 8)
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.BackgroundColor3 = Color3.fromRGB(70, 50, 56)
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 16
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "✕"
closeBtn.Parent = frame
Instance.new("UICorner").Parent = closeBtn

-- left: owned list
local list = Instance.new("Frame")
list.Position = UDim2.new(0, 10, 0, 44)
list.Size = UDim2.new(0, 190, 1, -54)
list.BackgroundTransparency = 1
list.Parent = frame
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = list

-- right: detail pane
local detail = Instance.new("Frame")
detail.Position = UDim2.new(0, 210, 0, 44)
detail.Size = UDim2.new(1, -220, 1, -54)
detail.BackgroundColor3 = Color3.fromRGB(18, 20, 27)
detail.BorderSizePixel = 0
detail.Parent = frame
Instance.new("UICorner").Parent = detail
local dPad = Instance.new("UIPadding")
dPad.PaddingLeft = UDim.new(0, 12)
dPad.PaddingRight = UDim.new(0, 12)
dPad.PaddingTop = UDim.new(0, 10)
dPad.Parent = detail
local dLayout = Instance.new("UIListLayout")
dLayout.Padding = UDim.new(0, 6)
dLayout.Parent = detail

local function dLabel(font: Enum.Font, size: number, color: Color3, order: number): TextLabel
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, 0, 0, size + 4)
    l.AutomaticSize = Enum.AutomaticSize.Y
    l.Font = font
    l.TextSize = size
    l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextColor3 = color
    l.LayoutOrder = order
    l.Text = ""
    l.Parent = detail
    return l
end

local dName  = dLabel(Enum.Font.GothamBold, 22, Color3.fromRGB(200, 235, 255), 1)
local dKind  = dLabel(Enum.Font.GothamMedium, 14, Color3.fromRGB(160, 170, 190), 2)
local dStats = dLabel(Enum.Font.Gotham, 15, Color3.fromRGB(225, 225, 235), 3)
local dSkill = dLabel(Enum.Font.GothamMedium, 14, Color3.fromRGB(255, 220, 140), 4)
local dPerksHdr = dLabel(Enum.Font.GothamBold, 13, Color3.fromRGB(210, 150, 255), 5)
local dPerks = dLabel(Enum.Font.Gotham, 13, Color3.fromRGB(210, 210, 225), 6)

local equipBtn = Instance.new("TextButton")
equipBtn.Size = UDim2.new(1, 0, 0, 38)
equipBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 75)
equipBtn.BorderSizePixel = 0
equipBtn.Font = Enum.Font.GothamBold
equipBtn.TextSize = 16
equipBtn.TextColor3 = Color3.new(1, 1, 1)
equipBtn.LayoutOrder = 10
equipBtn.Text = "Equip"
equipBtn.Parent = detail
Instance.new("UICorner").Parent = equipBtn

-- ── State ─────────────────────────────────────────────────────────────────────────
local owned: { string } = {}
local equipped: { [string]: boolean } = {}
local rows: { [string]: TextButton } = {}
local selected: string? = nil

local function equippedCount(): number
    local n = 0
    for _ in equipped do n += 1 end
    return n
end

local function statLines(id: string): string
    local p = Registry.pets[id]
    if not p then return "" end
    local b = p.base
    local lines = {
        string.format("Damage: %d", b.dmg),
        string.format("Cooldown: %.2fs", b.fireCd),
    }
    if p.kind == "projectile" then
        lines[#lines + 1] = string.format("Pierce: %d", b.pierce)
        if b.shots > 1 then lines[#lines + 1] = string.format("Shots: %d", b.shots) end
    else
        lines[#lines + 1] = string.format("Radius/Reach: %.0f", b.radius)
    end
    lines[#lines + 1] = string.format("Knockback: %d", b.knock)
    return table.concat(lines, "   ")
end

local function perksText(id: string): string
    local p = Registry.pets[id]
    if not p then return "" end
    local out = {}
    for _, perk in p.perks do
        out[#out + 1] = "• " .. perk.title .. " — " .. perk.desc
    end
    return table.concat(out, "\n")
end

local function refreshEquipBtn()
    local id = selected
    if not id then
        equipBtn.Visible = false
        return
    end
    equipBtn.Visible = true
    local eq = equipped[id] == true
    if eq then
        equipBtn.Text = "Unequip"
        equipBtn.BackgroundColor3 = Color3.fromRGB(110, 70, 70)
        equipBtn.Active = equippedCount() > 1 -- keep ≥1
        equipBtn.AutoButtonColor = equipBtn.Active
        equipBtn.TextTransparency = if equipBtn.Active then 0 else 0.5
    else
        equipBtn.Text = if equippedCount() < MAX then "Equip" else "Loadout full (swap)"
        equipBtn.BackgroundColor3 = Color3.fromRGB(60, 120, 75)
        equipBtn.Active = equippedCount() < MAX
        equipBtn.AutoButtonColor = equipBtn.Active
        equipBtn.TextTransparency = if equipBtn.Active then 0 else 0.5
    end
end

local refresh -- fwd decl

local function select(id: string)
    selected = id
    local p = Registry.pets[id]
    if p then
        dName.Text = p.name
        dKind.Text = p.kind:upper() .. " · " .. (p.blurb or "")
        dStats.Text = statLines(id)
        dSkill.Text = if p.skill then ("★ Skill — " .. p.skill.name .. ": " .. p.skill.desc) else "★ Skill — none"
        dPerksHdr.Text = "Possible perks"
        dPerks.Text = perksText(id)
    end
    refresh() -- sets row TEXT (names) + colors + equip button — the bit that was missing → blank rows
end

function refresh()
    for id, btn in rows do
        local eq = equipped[id] == true
        local nm = (Registry.pets[id] and Registry.pets[id].name) or id
        btn.Text = (if eq then "● " else "○ ") .. nm
        btn.BackgroundColor3 = if id == selected then Color3.fromRGB(70, 80, 110)
            elseif eq then Color3.fromRGB(50, 95, 62)
            else Color3.fromRGB(45, 48, 60)
    end
    refreshEquipBtn()
end

local function toggle(id: string)
    local set: { [string]: boolean } = {}
    for k in equipped do set[k] = true end
    if set[id] then
        if equippedCount() <= 1 then return end -- never go weaponless
        set[id] = nil
    elseif equippedCount() < MAX then
        set[id] = true
    else
        return -- full
    end
    local ids = {}
    for k in set do ids[#ids + 1] = k end
    if #ids == 0 then return end
    blink.SwitchWeapons.Fire(ids) -- server validates + echoes Weapons back
end

equipBtn.Activated:Connect(function()
    if selected and equipBtn.Active then toggle(selected) end
end)

local function rebuild()
    for _, btn in rows do btn:Destroy() end
    table.clear(rows)
    for i, id in owned do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 34)
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamMedium
        btn.TextSize = 15
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.LayoutOrder = i
        btn.Parent = list
        Instance.new("UICorner").Parent = btn
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 10)
        pad.Parent = btn
        btn.Activated:Connect(function() select(id) end)
        rows[id] = btn
    end
    if not (selected and rows[selected]) then selected = owned[1] end
    if selected then select(selected) else refresh() end
end

blink.Unlocked.On(function(ids)
    owned = ids
    rebuild()
end)
blink.Weapons.On(function(ids)
    equipped = {}
    for _, id in ids do equipped[id] = true end
    refresh()
end)

-- ── Open/close + number keys ──────────────────────────────────────────────────────
local function setOpen(open: boolean)
    frame.Visible = open
    openBtn.Text = if open then "🐾 PETS  [B]" else "🐾 PETS  [B]"
end
openBtn.Activated:Connect(function() setOpen(not frame.Visible) end)
closeBtn.Activated:Connect(function() setOpen(false) end)

local NUMS = {
    [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
    [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
}
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.B then
        setOpen(not frame.Visible)
    elseif frame.Visible then
        local n = NUMS[input.KeyCode]
        if n and owned[n] then select(owned[n]); toggle(owned[n]) end
    end
end)

return 0
