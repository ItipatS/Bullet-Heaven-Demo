# Client Controllers

Controllers are **per-player client-side modules** that mirror server Components. They handle UI updates, local state, and can communicate back to their server counterpart.

## Controller Lifecycle

```
[Server fires Loader with replica data]
        │
        ▼
Controller.new(player, replica)  ← Framework instantiates
        │
        ▼
Controller:Compile(dependencies) ← Dependencies injected
        │
        ▼
signals.CompilationCompleted     ← Signal fires
        │
        ▼
RunOnCompilationCompleted()      ← Override for early init
        │
        ▼
Controller:Register(replica)     ← Called with full replica
        │
        ▼
signals.RegistrationCompleted    ← Signal fires
        │
        ▼
RunOnRegistrationCompleted()     ← Override for full init
        │
        ▼
    [Controller Active]          ← Receives server updates
        │
        ▼
Controller:Destroy()             ← Cleanup
```

## Creating a Controller

### Basic Structure

```lua
--[=[
    @controller ControllerName
    @dependencies: Dependency1, Dependency2
    @description: What this controller does
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

-- Imports
local Composer = require(Framework.Main.Controller);

-- Define controller with config
local MyController = Composer.Extend({

    -- REQUIRED: Must match server component identifier
    identifier = 'ControllerName';

    -- REQUIRED: Array of controller identifiers this depends on
    dependencies = {'Dependency1', 'Dependency2'};

    -- OPTIONAL: Initial state (deep copied per instance)
    state = {
        someValue = 0;
        isActive = false;
    };

    -- REQUIRED: Data keys expected from server replica
    replica_dependencies = {'DataKey1', 'DataKey2'};

});

return MyController;
```

### ControllerConfig Type

```lua
type ControllerConfig = {
    identifier: string,              -- Must match component
    dependencies: { string },        -- Controller dependencies
    state: { [string]: any },        -- Initial state template
    replica_dependencies: { string } -- Expected replica keys
}
```

## Controller Properties

After instantiation, each controller instance has:

| Property | Type | Description |
|----------|------|-------------|
| `self.player` | `Player` | LocalPlayer reference |
| `self.state` | `table` | Controller-local state |
| `self.dependencies` | `table` | Injected controller dependencies |
| `self.replica` | `table` | Data received from server |
| `self.config` | `ControllerConfig` | The controller configuration |
| `self.signals` | `table` | Event signals |
| `self._processID` | `string` | Unique GUID for this instance |

## Built-in Signals

Every controller has these signals:

```lua
self.signals.CompilationCompleted  -- Fires after Compile()
self.signals.RegistrationCompleted -- Fires after Register()
```

### Adding Custom Signals

```lua
function MyController:RunOnCompilationCompleted()
    self:AddSignal('UIUpdated');
    self:AddSignal('UserAction');
end

-- Fire from methods
self.signals.UIUpdated:Fire(elementName);

-- Connect from other controllers
self.dependencies.OtherController.signals.UIUpdated:Connect(function(element)
    print('UI updated:', element);
end)
```

## Lifecycle Methods

### RunOnCompilationCompleted

Called after dependencies are injected:

```lua
function MyController:RunOnCompilationCompleted()
    -- Good for:
    -- - Setting up signal connections
    -- - Initializing from replica data
    -- - Connecting to dependency signals

    -- Access replica data
    if self.replica.MyData then
        self.state.value = self.replica.MyData.value;
    end
end
```

### RunOnRegistrationCompleted

Called after full initialization - safe to set up UI:

```lua
function MyController:RunOnRegistrationCompleted()
    -- Good for:
    -- - Setting up UI bindings
    -- - Starting visual effects
    -- - Full initialization

    -- Initialize UI with replica data
    for currency, amount in pairs(self.replica.Currencies or {}) do
        self:_UpdateCurrencyDisplay(currency, amount);
    end
end
```

## Receiving Server Updates

The framework automatically routes server calls to controller methods:

### Server Component (sends update)

```lua
-- In server component
Replication.FireToClient('Session', self.player, {
    Identifier = 'Currency';      -- Controller identifier
    Call = 'UpdateCurrency';      -- Method to call
    Args = {'Coins', 150};        -- Arguments
});
```

### Client Controller (receives update)

```lua
-- In client controller
function CurrencyController:UpdateCurrency(currency: string, newValue: number)
    -- Validate (always good practice)
    if type(currency) ~= 'string' then return end
    if type(newValue) ~= 'number' then return end

    -- Update local state
    self.state.currencies[currency] = newValue;

    -- Update UI
    self:_UpdateCurrencyDisplay(currency, newValue);

    -- Fire signal for other controllers
    self.signals.CurrencyChanged:Fire(currency, newValue);
end
```

## Sending Requests to Server

### Fire (one-way, no response)

```lua
local Replication = require(Framework.Utils.Replication);

function MyController:OnButtonClicked()
    Replication.FireToServer('Session', {
        Identifier = 'MyComponent';    -- Server component
        Call = 'HandleAction';         -- Authorized method
        Args = {'someAction', 42};     -- Arguments
    });
end
```

### Invoke (request/response)

```lua
local Replication = require(Framework.Utils.Replication);

function MyController:RequestData()
    -- This waits for server response
    local result = Replication.InvokeServer('Session', {
        Identifier = 'MyComponent';
        Call = 'GetData';              -- Must be authorized
        Args = {};
    });

    if result then
        self.state.data = result;
        self:_UpdateUI();
    end
end
```

## Working with Dependencies

### Declaring Dependencies

```lua
local ShopController = Composer.Extend({
    identifier = 'Shop';
    dependencies = {'Currency', 'Inventory'}; -- Declare dependencies
    state = {};
    replica_dependencies = {};
});
```

### Using Dependencies

```lua
function ShopController:RunOnRegistrationCompleted()
    local currency = self.dependencies.Currency;

    -- Listen to currency changes
    currency.signals.CurrencyChanged:Connect(function(currencyType, amount)
        self:_UpdateAffordability();
    end)
end

function ShopController:_UpdateAffordability()
    local currency = self.dependencies.Currency;
    local coins = currency.state.currencies.Coins or 0;

    -- Update shop UI based on what player can afford
    for _, item in self.shopItems do
        local canAfford = coins >= item.price;
        item.button.Interactable = canAfford;
    end
end
```

## UI Patterns

### Referencing UI Elements

```lua
function MyController:RunOnRegistrationCompleted()
    local player = game.Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');

    -- Store UI references
    self.ui = {
        container = gui:WaitForChild('MyScreen'),
        valueLabel = gui:FindFirstChild('ValueLabel', true),
        actionButton = gui:FindFirstChild('ActionButton', true),
    };

    -- Set up button handlers
    if self.ui.actionButton then
        self.ui.actionButton.Activated:Connect(function()
            self:_OnActionPressed();
        end)
    end
end
```

### Updating UI

```lua
function MyController:_UpdateDisplay(value: number)
    if self.ui and self.ui.valueLabel then
        self.ui.valueLabel.Text = tostring(value);
    end
end
```

## Complete Example: Currency Controller

```lua
--[=[
    @controller Currency
    @dependencies: none
    @description: Displays and manages currency UI
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Controller);
local FormatUtils = require(Framework.Utils.FormatUtils);
local Signal = require(Framework.Dependencies.signal);

local CurrencyController = Composer.Extend({
    identifier = 'Currency';
    dependencies = {};

    state = {
        currencies = {};
    };

    replica_dependencies = { 'Currencies' };
});

function CurrencyController:RunOnCompilationCompleted()
    -- Add custom signal
    self.currency_updated = Signal.new();
end

function CurrencyController:RunOnRegistrationCompleted()
    -- Initialize from replica
    if self.replica.Currencies then
        for currency, amount in pairs(self.replica.Currencies) do
            self.state.currencies[currency] = amount;
            self:_UpdateCurrencyUI(currency, amount);
        end
    end
end

-- Called by server when currency changes
function CurrencyController:UpdateCurrency(currency: string, new_value: number)
    -- Validate
    if type(currency) ~= 'string' then return end
    if type(new_value) ~= 'number' then return end

    -- Update state
    self.state.currencies[currency] = new_value;

    -- Update replica (keep in sync)
    if self.replica.Currencies then
        self.replica.Currencies[currency] = new_value;
    end

    -- Update UI
    self:_UpdateCurrencyUI(currency, new_value);

    -- Fire signal for other controllers
    self.currency_updated:Fire(currency, new_value);
end

-- Public: Get current balance
function CurrencyController:GetBalance(currency: string): number
    return self.state.currencies[currency] or 0;
end

-- Private: Update UI element
function CurrencyController:_UpdateCurrencyUI(currency: string, amount: number)
    local player = game.Players.LocalPlayer;
    local gui = player:FindFirstChild('PlayerGui');
    if not gui then return end

    -- Find currency label (assumes naming convention)
    local label = gui:FindFirstChild(currency .. 'Label', true);
    if not label then return end

    -- Format and display
    local formatted = FormatUtils.format_to_long_value(amount);
    label.Text = formatted;
end

return CurrencyController;
```

## Complete Example: Inventory Controller

```lua
--[=[
    @controller Inventory
    @dependencies: none
    @description: Manages inventory UI and player interactions
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Controller);
local Replication = require(Framework.Utils.Replication);
local Signal = require(Framework.Dependencies.signal);

local InventoryController = Composer.Extend({
    identifier = 'Inventory';
    dependencies = {};

    state = {
        items = {};
        selectedSlot = nil;
    };

    replica_dependencies = { 'Inventory' };
});

function InventoryController:RunOnCompilationCompleted()
    self:AddSignal('SlotSelected');
    self:AddSignal('InventoryChanged');
end

function InventoryController:RunOnRegistrationCompleted()
    -- Initialize from replica
    if self.replica.Inventory then
        self.state.items = self.replica.Inventory;
    end

    -- Set up UI
    self:_CreateInventoryUI();
    self:_RefreshInventoryDisplay();
end

-- Called by server when inventory changes
function InventoryController:SyncInventory(items: {})
    self.state.items = items;
    self.replica.Inventory = items;

    self:_RefreshInventoryDisplay();
    self.signals.InventoryChanged:Fire(items);
end

-- Public: Request to use item
function InventoryController:UseSelectedItem()
    if not self.state.selectedSlot then return end

    Replication.FireToServer('Session', {
        Identifier = 'Inventory';
        Call = 'UseItem';
        Args = {self.state.selectedSlot};
    });
end

-- Public: Request to drop item
function InventoryController:DropSelectedItem()
    if not self.state.selectedSlot then return end

    Replication.FireToServer('Session', {
        Identifier = 'Inventory';
        Call = 'DropItem';
        Args = {self.state.selectedSlot};
    });

    self.state.selectedSlot = nil;
end

-- Private: Create inventory UI
function InventoryController:_CreateInventoryUI()
    local player = game.Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');

    -- Find or create inventory container
    self.inventoryFrame = gui:FindFirstChild('InventoryFrame', true);
    if not self.inventoryFrame then return end

    -- Create slot buttons
    self.slots = {};
    for i = 1, 20 do
        local slot = self.inventoryFrame:FindFirstChild('Slot' .. i);
        if slot then
            self.slots[i] = slot;

            -- Connect click handler
            slot.Activated:Connect(function()
                self:_OnSlotClicked(i);
            end)
        end
    end
end

-- Private: Handle slot click
function InventoryController:_OnSlotClicked(slotIndex: number)
    -- Deselect previous
    if self.state.selectedSlot and self.slots[self.state.selectedSlot] then
        self.slots[self.state.selectedSlot].BorderColor3 = Color3.new(0, 0, 0);
    end

    -- Select new
    self.state.selectedSlot = slotIndex;
    if self.slots[slotIndex] then
        self.slots[slotIndex].BorderColor3 = Color3.new(1, 1, 0);
    end

    self.signals.SlotSelected:Fire(slotIndex, self.state.items[slotIndex]);
end

-- Private: Refresh all slots
function InventoryController:_RefreshInventoryDisplay()
    for i, slot in ipairs(self.slots) do
        local item = self.state.items[i];

        if item then
            slot.Image = self:_GetItemIcon(item.id);
            slot.Visible = true;
        else
            slot.Image = '';
            slot.Visible = false;
        end
    end
end

-- Private: Get item icon
function InventoryController:_GetItemIcon(itemId: string): string
    -- Return asset ID for item icon
    return 'rbxassetid://0'; -- Replace with actual icons
end

return InventoryController;
```

## Best Practices

1. **Match identifiers exactly** - Controller identifier must match Component
2. **Validate server data** - Even trusted sources can have bugs
3. **Use signals for cross-controller communication** - Loose coupling
4. **Cache UI references** - Don't search for elements repeatedly
5. **Handle missing UI gracefully** - UI might not exist in all contexts
6. **Keep visual logic in controllers** - Don't put game logic here
7. **Use dependencies for controller interaction** - Don't require controllers directly
