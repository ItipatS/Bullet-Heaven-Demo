# Server Components

Components are **per-player server-side modules** that manage player-specific game logic. Each player gets their own instance of each component.

## Component Lifecycle

```
Component.new(player, data)     ← Framework instantiates
        │
        ▼
Component:Compile(dependencies) ← Dependencies injected
        │
        ▼
signals.CompilationCompleted    ← Signal fires
        │
        ▼
RunOnCompilationCompleted()     ← Override this for early init
        │
        ▼
Component:Register()            ← Called after client confirms ready
        │
        ▼
signals.RegistrationCompleted   ← Signal fires
        │
        ▼
RunOnRegistrationCompleted()    ← Override this for full init
        │
        ▼
    [Component Active]          ← Normal operation
        │
        ▼
Component:Destroy()             ← Player leaves, cleanup
```

## Creating a Component

### Basic Structure

```lua
--[=[
    @component ComponentName
    @dependencies: Dependency1, Dependency2
    @description: What this component does
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

-- Imports
local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

-- Define component with config
local MyComponent = Composer.Extend({

    -- REQUIRED: Unique identifier (matches controller)
    identifier = 'ComponentName';

    -- REQUIRED: Array of component identifiers this depends on
    dependencies = {'Dependency1', 'Dependency2'};

    -- REQUIRED: Replication settings
    replication = {
        enabled = true;                    -- Allow client communication
        authorized = {'Method1', 'Method2'}; -- Client-callable methods
    };

    -- OPTIONAL: Initial state (deep copied per instance)
    state = {
        someValue = 0;
        someFlag = false;
    };

    -- REQUIRED: Data keys to replicate to client
    replica_dependencies = {'DataKey1', 'DataKey2'};

});

return MyComponent;
```

### ComponentConfig Type

```lua
type ComponentConfig = {
    identifier: string,              -- Unique component name
    dependencies: { string },        -- Component dependencies
    replication: {
        enabled: boolean,            -- Allow client calls
        authorized: { string }       -- Allowed method names
    },
    state: { [string]: any },        -- Initial state template
    replica_dependencies: { string } -- Data keys for client
}
```

## Component Properties

After instantiation, each component instance has:

| Property | Type | Description |
|----------|------|-------------|
| `self.player` | `Player` | The player this component belongs to |
| `self.data` | `table` | Reference to player's saved data |
| `self.state` | `table` | Component-local state (not saved) |
| `self.dependencies` | `table` | Injected component dependencies |
| `self.replica` | `table` | Data subset sent to client |
| `self.config` | `ComponentConfig` | The component configuration |
| `self.signals` | `table` | Event signals (includes built-in) |
| `self._processID` | `string` | Unique GUID for this instance |

## Built-in Signals

Every component has these signals:

```lua
self.signals.CompilationCompleted  -- Fires after Compile()
self.signals.RegistrationCompleted -- Fires after Register()
```

### Adding Custom Signals

```lua
function MyComponent:RunOnCompilationCompleted()
    -- Add custom signals
    self:AddSignal('ValueChanged');
    self:AddSignal('ActionCompleted');
end

-- Later, fire them
self.signals.ValueChanged:Fire(newValue);

-- Or connect to them from another component
self.dependencies.OtherComponent.signals.ValueChanged:Connect(function(value)
    print('Value changed to:', value);
end)
```

## Lifecycle Methods

### RunOnCompilationCompleted

Called after dependencies are injected but before client is ready:

```lua
function MyComponent:RunOnCompilationCompleted()
    -- Good for:
    -- - Setting up signal connections
    -- - Initializing state from data
    -- - Connecting to dependency signals

    -- Access dependencies
    local inventory = self.dependencies.Inventory;

    -- Initialize from saved data
    if self.data.MyData then
        self.state.value = self.data.MyData.value;
    end
end
```

### RunOnRegistrationCompleted

Called after client confirms ready - safe to replicate:

```lua
function MyComponent:RunOnRegistrationCompleted()
    -- Good for:
    -- - Initial replication to client
    -- - Starting gameplay loops
    -- - Anything that needs client to be ready

    -- Safe to replicate now
    Replication.FireToClient('Session', self.player, {
        Identifier = self.config.identifier;
        Call = 'Initialize';
        Args = {self.state};
    });
end
```

## Working with Data

### Reading Data

```lua
-- Access player's saved data directly
local coins = self.data.Currencies.Coins;
local level = self.data.Stats.Level;
```

### Writing Data

```lua
-- Modify data directly (auto-saved on player leave)
self.data.Currencies.Coins = self.data.Currencies.Coins + 100;
self.data.Stats.Experience = self.data.Stats.Experience + 50;
```

### Replica Dependencies

Data keys listed in `replica_dependencies` are automatically sent to the client:

```lua
local MyComponent = Composer.Extend({
    identifier = 'Currency';
    dependencies = {};
    replication = { enabled = true; authorized = {}; };
    state = {};
    replica_dependencies = { 'Currencies' }; -- This data goes to client
});

function MyComponent:RunOnRegistrationCompleted()
    -- self.replica.Currencies is available
    -- Client's controller also has replica.Currencies
    print(self.replica.Currencies.Coins);
end
```

## Working with Dependencies

### Declaring Dependencies

```lua
local MyComponent = Composer.Extend({
    identifier = 'Shop';
    dependencies = {'Currency', 'Inventory'}; -- Declare dependencies
    -- ...
});
```

### Using Dependencies

```lua
function MyComponent:PurchaseItem(itemId: string, price: number)
    local currency = self.dependencies.Currency;
    local inventory = self.dependencies.Inventory;

    -- Check if player can afford
    if currency:GetBalance('Coins') < price then
        return false, 'Insufficient funds';
    end

    -- Deduct currency
    currency:EditCurrency('Coins', 'Deduct', price);

    -- Add to inventory
    inventory:AddItem(itemId);

    return true, 'Purchase successful';
end
```

## Replicating to Client

### Fire and Forget (one-way)

```lua
function MyComponent:UpdateSomething()
    -- Update server state
    self.state.value = 42;

    -- Notify client
    Replication.FireToClient('Session', self.player, {
        Identifier = self.config.identifier; -- 'MyComponent'
        Call = 'OnValueUpdated';             -- Controller method
        Args = {self.state.value};           -- Arguments
    });
end
```

### Authorized Client Calls

When client calls an authorized method:

```lua
local MyComponent = Composer.Extend({
    identifier = 'Combat';
    dependencies = {};
    replication = {
        enabled = true;
        authorized = {'RequestAttack'}; -- Client can call this
    };
    -- ...
});

-- This method can be called from client
function MyComponent:RequestAttack(targetId: string)
    -- Validate input (always validate client input!)
    if type(targetId) ~= 'string' then return end

    -- Perform server-authoritative logic
    local target = workspace:FindFirstChild(targetId);
    if not target then return end

    -- Process attack...
end
```

## Complete Example: Inventory Component

```lua
--[=[
    @component Inventory
    @dependencies: none
    @description: Manages player inventory with persistence
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

local InventoryComponent = Composer.Extend({
    identifier = 'Inventory';
    dependencies = {};

    replication = {
        enabled = true;
        authorized = {'DropItem', 'UseItem'};
    };

    state = {
        maxSlots = 20;
    };

    replica_dependencies = {'Inventory'};
});

function InventoryComponent:RunOnCompilationCompleted()
    self:AddSignal('ItemAdded');
    self:AddSignal('ItemRemoved');

    -- Initialize inventory if doesn't exist
    if not self.data.Inventory then
        self.data.Inventory = {};
    end
end

function InventoryComponent:RunOnRegistrationCompleted()
    -- Sync full inventory to client
    self:_ReplicateInventory();
end

-- Public: Add item to inventory
function InventoryComponent:AddItem(itemId: string, quantity: number?)
    if type(itemId) ~= 'string' then return false end
    quantity = quantity or 1;

    -- Check capacity
    local currentCount = #self.data.Inventory;
    if currentCount >= self.state.maxSlots then
        return false, 'Inventory full';
    end

    -- Add item
    table.insert(self.data.Inventory, {
        id = itemId;
        quantity = quantity;
        addedAt = os.time();
    });

    -- Fire signal for other components
    self.signals.ItemAdded:Fire(itemId, quantity);

    -- Replicate to client
    self:_ReplicateInventory();

    return true;
end

-- Public: Remove item from inventory
function InventoryComponent:RemoveItem(slotIndex: number)
    if type(slotIndex) ~= 'number' then return false end
    if slotIndex < 1 or slotIndex > #self.data.Inventory then
        return false;
    end

    local item = table.remove(self.data.Inventory, slotIndex);
    self.signals.ItemRemoved:Fire(item.id, item.quantity);
    self:_ReplicateInventory();

    return true, item;
end

-- Authorized: Client requests to drop item
function InventoryComponent:DropItem(slotIndex: number)
    if type(slotIndex) ~= 'number' then return end

    local success, item = self:RemoveItem(slotIndex);
    if success and item then
        -- Spawn item in world
        self:_SpawnDroppedItem(item);
    end
end

-- Authorized: Client requests to use item
function InventoryComponent:UseItem(slotIndex: number)
    if type(slotIndex) ~= 'number' then return end

    local item = self.data.Inventory[slotIndex];
    if not item then return end

    -- Item use logic here...
    print(self.player.Name, 'used item:', item.id);
end

-- Private: Sync inventory to client
function InventoryComponent:_ReplicateInventory()
    self.replica.Inventory = self.data.Inventory;

    Replication.FireToClient('Session', self.player, {
        Identifier = 'Inventory';
        Call = 'SyncInventory';
        Args = {self.data.Inventory};
    });
end

-- Private: Spawn dropped item
function InventoryComponent:_SpawnDroppedItem(item)
    local character = self.player.Character;
    if not character then return end

    -- Create dropped item at player position...
end

return InventoryComponent;
```

## Best Practices

1. **Always validate client input** - Never trust data from authorized calls
2. **Use signals for cross-component communication** - Loose coupling
3. **Keep state vs data clear** - `state` is runtime only, `data` persists
4. **Replicate after state changes** - Keep client in sync
5. **Use dependencies for component interaction** - Don't require components directly
6. **Document your components** - Use the JSDoc-style header comments
