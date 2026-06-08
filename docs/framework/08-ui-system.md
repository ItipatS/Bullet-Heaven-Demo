# UI System

The framework provides utilities for managing UI state, registries, and common interactions.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      UI SYSTEM                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  UIStateController                                           │
│  ├── Manages frame open/close state                         │
│  ├── Handles blur effects                                    │
│  └── Coordinates button callbacks                            │
│                                                              │
│  Registry                                                    │
│  ├── Common.luau - Screen references                        │
│  ├── Core.luau - Frames and buttons                         │
│  └── Currencies.luau - Currency displays                    │
│                                                              │
│  Tweens Utility                                              │
│  ├── Hover effects                                          │
│  └── Click effects                                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## UIStateController

Manages opening/closing UI frames with animations and effects.

### Initialization

The controller initializes automatically when the framework starts:

```lua
-- In InternalReplicationHandler.InitializeClient()
local UIStateController = require(script.Parent.UI.UIStateController);
UIStateController.Initialize();
```

### Initialize Method

```lua
function UIStateController.Initialize()
    for _, frame in Registry.Frames do
        -- Find close button in frame
        local closeButton = frame:FindFirstChild('Close', true);
        -- Find open button (same name as frame)
        local openButton = Registry.Buttons[frame.Name];

        -- Set up hover and click effects
        Tweens.SetClick({ closeButton, openButton }, 0.95);
        Tweens.SetHover({ closeButton, openButton }, 1.05);

        -- Connect close button
        closeButton.Activated:Connect(function()
            UIStateController.CloseFrame(frame);
        end)

        -- Connect open button
        if openButton then
            openButton.Activated:Connect(function()
                UIStateController.OpenFrame(frame);
            end)
        end
    end
end
```

### Opening Frames

```lua
function UIStateController.OpenFrame(frame: Frame)
    -- Close any currently open frame
    if UIStateController.CurrentlyOpen then
        UIStateController.CloseFrame(UIStateController.CurrentlyOpen);
    end

    -- Animate open
    frame.Size = UDim2.fromScale(0, 0);
    frame.Visible = true;

    local tween = TweenService:Create(
        frame,
        TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
        { Size = frame:GetAttribute('BaseSize') }
    );
    tween:Play();

    -- Adjust camera FOV
    TweenService:Create(
        workspace.CurrentCamera,
        TweenInfo.new(0.15),
        { FieldOfView = 80 }
    ):Play();

    UIStateController.CurrentlyOpen = frame;

    -- Add blur effect (unless frame is in ignore list)
    if not table.find(BLUR_IGNORES, frame.Name) then
        local blur = Instance.new('BlurEffect');
        blur.Parent = workspace.CurrentCamera;
        blur.Size = 15;
        blur.Name = 'UI_BLUR_' .. frame.Name;
    end
end
```

### Closing Frames

```lua
function UIStateController.CloseFrame(frame: Frame)
    -- Animate close
    local tween = TweenService:Create(
        frame,
        TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
        { Size = UDim2.fromScale(0, 0) }
    );
    tween:Play();

    -- Reset camera FOV
    TweenService:Create(
        workspace.CurrentCamera,
        TweenInfo.new(0.15),
        { FieldOfView = 70 }
    ):Play();

    -- Remove blur effects
    for _, effect in workspace.CurrentCamera:GetChildren() do
        if effect:IsA('BlurEffect') then
            effect:Destroy();
        end
    end

    UIStateController.CurrentlyOpen = nil;
    task.wait(0.15);
    frame.Visible = false;
end
```

### Frame Setup Requirements

For frames to work with UIStateController:

1. **Frame must be in Registry.Frames**
2. **Frame must have `BaseSize` attribute** - The size to animate to
3. **Frame must contain a `Close` button** - Can be nested
4. **Button in Registry.Buttons with same name** - For opening

Example frame structure:
```
Frames/
└── Shop (Frame)
    ├── BaseSize = UDim2.fromScale(0.6, 0.7) [Attribute]
    ├── Close (ImageButton)
    │   └── UIScale
    └── Content (Frame)
```

## UI Registry

### Common.luau

References the main screen GUI:

```lua
local Players = game:GetService('Players');
local player = Players.LocalPlayer;
local gui = player:WaitForChild('PlayerGui');

return {
    Screen = gui:WaitForChild('Screen');  -- Main ScreenGui
}
```

### Core.luau

Builds frame and button registries:

```lua
local Common = require(script.Parent.Common);

local Screen = Common.Screen;
local Frames = Screen.Frames;           -- Container for popup frames
local Buttons = Screen.HUD.TopLeft;     -- Container for open buttons

local Container = {};
local ButtonsContainer = {};

-- Register all frames
for _, frame in Frames:GetChildren() do
    Container[frame.Name] = frame;
end

-- Register all buttons
for _, button in Buttons:GetChildren() do
    ButtonsContainer[button.Name] = button;
end

return {
    Frames = Container;
    Buttons = ButtonsContainer;
};
```

### Custom Registries

Create additional registries for specific UI elements:

```lua
-- Registry/Currencies.luau
local Common = require(script.Parent.Common);
local Screen = Common.Screen;
local CurrencyContainer = Screen.HUD.Currencies;

return {
    Coins = CurrencyContainer.Coins.Amount;
    Gems = CurrencyContainer.Gems.Amount;
    Tickets = CurrencyContainer.Tickets.Amount;
};
```

Usage in controller:

```lua
local Currencies = require(Framework.UI.Registry.Currencies);

function CurrencyController:_UpdateCurrencyUI(currency, amount)
    local label = Currencies[currency];
    if label then
        label.Text = FormatUtils.format_to_long_value(amount);
    end
end
```

## Tweens Utility

Provides easy button animations.

### SetHover

Adds hover scale effect to buttons:

```lua
local Tweens = require(Framework.Utils.Tweens);

-- Buttons must have UIScale child
Tweens.SetHover(
    { button1, button2, button3 },  -- Array of GuiButtons
    1.05,                            -- Scale on hover (1.05 = 5% larger)
    true                             -- Overwrite existing connections (optional)
);
```

### SetClick

Adds click scale effect to buttons:

```lua
Tweens.SetClick(
    { button1, button2, button3 },  -- Array of GuiButtons
    0.95,                            -- Scale on click (0.95 = 5% smaller)
    true                             -- Overwrite existing connections (optional)
);
```

### Button Requirements

Buttons must have a `UIScale` child for tween effects:

```
MyButton (ImageButton or TextButton)
├── UIScale (UIScale)
│   └── Scale = 1
└── ... other children
```

### Tween Settings

Default tween configurations:

```lua
-- Hover animation
local HOVER_TWEEN = TweenInfo.new(
    0.25,                        -- Duration
    Enum.EasingStyle.Elastic,    -- Style
    Enum.EasingDirection.Out,    -- Direction
    0,                           -- Repeat count
    false,                       -- Reverses
    0                            -- Delay
);

-- Click animation
local CLICK_TWEEN = TweenInfo.new(
    0.1,                         -- Duration
    Enum.EasingStyle.Back,       -- Style
    Enum.EasingDirection.In,     -- Direction
    0,                           -- Repeat count
    true                         -- Reverses (bounces back)
);
```

## UI Patterns in Controllers

### Referencing UI Elements

```lua
function MyController:RunOnRegistrationCompleted()
    local player = game.Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');
    local screen = gui:WaitForChild('Screen');

    -- Cache UI references
    self.ui = {
        frame = screen:FindFirstChild('MyFrame', true);
        label = screen:FindFirstChild('MyLabel', true);
        button = screen:FindFirstChild('MyButton', true);
    };

    -- Set up interactions
    if self.ui.button then
        self.ui.button.Activated:Connect(function()
            self:_OnButtonPressed();
        end)
    end
end
```

### Safe UI Updates

```lua
function MyController:_UpdateDisplay(value)
    -- Always check UI exists
    if not self.ui or not self.ui.label then
        return;
    end

    self.ui.label.Text = tostring(value);
end
```

### Creating Dynamic UI

```lua
function InventoryController:_CreateSlots()
    local template = self.ui.slotTemplate:Clone();
    template.Parent = nil; -- Keep as template

    self.slots = {};

    for i = 1, self.maxSlots do
        local slot = template:Clone();
        slot.Name = 'Slot_' .. i;
        slot.LayoutOrder = i;
        slot.Parent = self.ui.container;

        -- Set up slot
        slot.Activated:Connect(function()
            self:_OnSlotClicked(i);
        end)

        self.slots[i] = slot;
    end
end

function InventoryController:_RefreshSlots()
    for i, slot in ipairs(self.slots) do
        local item = self.state.items[i];

        if item then
            slot.Icon.Image = self:_GetItemIcon(item.id);
            slot.Amount.Text = item.quantity > 1 and item.quantity or '';
            slot.Visible = true;
        else
            slot.Icon.Image = '';
            slot.Amount.Text = '';
            slot.Visible = false;
        end
    end
end
```

## Expected UI Structure

The framework expects this ScreenGui structure:

```
PlayerGui/
└── Screen (ScreenGui)
    ├── HUD (Frame)
    │   ├── TopLeft (Frame)
    │   │   ├── Shop (ImageButton)      -- Opens Shop frame
    │   │   │   └── UIScale
    │   │   ├── Inventory (ImageButton) -- Opens Inventory frame
    │   │   │   └── UIScale
    │   │   └── Settings (ImageButton)  -- Opens Settings frame
    │   │       └── UIScale
    │   │
    │   ├── Currencies (Frame)
    │   │   ├── Coins (Frame)
    │   │   │   └── Amount (TextLabel)
    │   │   └── Gems (Frame)
    │   │       └── Amount (TextLabel)
    │   │
    │   └── Hotbar (Frame)
    │       └── ... slots
    │
    └── Frames (Frame)
        ├── Shop (Frame)
        │   ├── BaseSize = UDim2.fromScale(0.6, 0.7)
        │   ├── Close (ImageButton)
        │   │   └── UIScale
        │   └── Content (Frame)
        │
        ├── Inventory (Frame)
        │   ├── BaseSize = UDim2.fromScale(0.5, 0.6)
        │   ├── Close (ImageButton)
        │   │   └── UIScale
        │   └── Content (Frame)
        │
        └── Settings (Frame)
            ├── BaseSize = UDim2.fromScale(0.4, 0.5)
            ├── Close (ImageButton)
            │   └── UIScale
            └── Content (Frame)
```

## Best Practices

1. **Use registries** - Centralize UI references
2. **Cache UI elements** - Don't search repeatedly with FindFirstChild
3. **Check for nil** - UI might not exist in all contexts
4. **Use UIScale for animations** - More performant than Size tweens
5. **Set BaseSize attribute** - Required for UIStateController
6. **Name frames and buttons consistently** - Frame name = Button name
7. **Keep UI logic in Controllers** - Not Components
8. **Handle dynamic content** - Template and clone pattern
9. **Clean up connections** - Disconnect when destroying UI
10. **Use FormatUtils** - Consistent number/text formatting
