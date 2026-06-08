# Data Persistence

The framework uses ProfileService for robust player data persistence with automatic saving, session locking, and data reconciliation.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     DATA FLOW                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Player Joins                                                │
│       │                                                      │
│       ▼                                                      │
│  ProfileService.LoadProfileAsync()                           │
│       │                                                      │
│       ├──► Session locked (prevents duplicate loads)         │
│       │                                                      │
│       ├──► Profile.Reconcile() (merge with Template)         │
│       │                                                      │
│       ▼                                                      │
│  profile.Data available in Components                        │
│       │                                                      │
│       │  [Game Session Active]                               │
│       │                                                      │
│       │  Components modify profile.Data directly             │
│       │                                                      │
│       ▼                                                      │
│  Player Leaves                                               │
│       │                                                      │
│       ▼                                                      │
│  Profile auto-saves and releases lock                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

### Data Settings

Edit `Shared/Framework/Data/Settings.luau`:

```lua
return {
    key = 'MyGameName';   -- DataStore key prefix
    version = 0001;       -- Data version (increment for migrations)
    mock = false;         -- true = use mock DataStore (Studio testing)
}
```

**Important:**
- `key` + `version` form the DataStore key: `MyGameName_0001`
- Changing `version` creates a NEW DataStore (players start fresh)
- Set `mock = true` during development to avoid DataStore calls

### Data Template

Edit `Shared/Framework/Data/Template.luau`:

```lua
return {
    -- Player currencies
    Currencies = {
        Coins = 0;
        Gems = 0;
        Tickets = 0;
    };

    -- Inventory system
    Inventory = {};
    EquippedItems = {};

    -- Player progression
    Stats = {
        Level = 1;
        Experience = 0;
        TotalPlayTime = 0;
    };

    -- Quest progress
    Quests = {
        Active = {};
        Completed = {};
    };

    -- Player settings
    Settings = {
        MusicVolume = 0.5;
        SFXVolume = 0.5;
        ShowTutorial = true;
    };

    -- Timestamps
    Meta = {
        FirstJoin = 0;
        LastJoin = 0;
    };
}
```

**Template Rules:**
- Define ALL data fields with default values
- New fields are auto-added via `Profile:Reconcile()`
- Nested tables are supported
- Avoid `nil` as default (use empty table `{}` instead)

## Data Loading

### Automatic Loading

The framework automatically loads data when a player joins:

```lua
-- In Session.RegisterPlayer()
local profile = Data.AttemptLoadData(player);
playerSession.data = profile; -- Reference to profile.Data
```

### Manual Data Access

```lua
local Data = require(Framework.Data);

-- Get profile object (has metadata methods)
local profile = Data.GetProfile(player);

-- Access data directly
local coins = profile.Data.Currencies.Coins;
```

## Using Data in Components

### Accessing Data

Components receive data reference in constructor:

```lua
local MyComponent = Composer.Extend({
    identifier = 'MyComponent';
    dependencies = {};
    replication = { enabled = true; authorized = {}; };
    state = {};
    replica_dependencies = { 'Currencies' }; -- Sync to client
});

function MyComponent:RunOnRegistrationCompleted()
    -- Access player's saved data
    local coins = self.data.Currencies.Coins;
    local level = self.data.Stats.Level;

    -- Initialize state from data
    self.state.currentCoins = coins;
end
```

### Modifying Data

Modify `self.data` directly - changes are auto-saved:

```lua
function MyComponent:AddCoins(amount: number)
    if type(amount) ~= 'number' or amount <= 0 then return end

    -- Modify saved data directly
    self.data.Currencies.Coins = self.data.Currencies.Coins + amount;

    -- Update replica for client
    self.replica.Currencies.Coins = self.data.Currencies.Coins;

    -- Notify client
    Replication.FireToClient('Session', self.player, {
        Identifier = 'Currency';
        Call = 'UpdateCurrency';
        Args = { 'Coins', self.data.Currencies.Coins };
    });
end
```

### Complex Data Operations

```lua
-- Adding to inventory (array)
function InventoryComponent:AddItem(itemData)
    table.insert(self.data.Inventory, {
        id = itemData.id;
        quantity = itemData.quantity or 1;
        metadata = itemData.metadata or {};
        acquiredAt = os.time();
    });
end

-- Removing from inventory
function InventoryComponent:RemoveItem(index: number)
    if index < 1 or index > #self.data.Inventory then return end
    return table.remove(self.data.Inventory, index);
end

-- Updating nested data
function StatsComponent:AddExperience(amount: number)
    self.data.Stats.Experience = self.data.Stats.Experience + amount;

    -- Check for level up
    local requiredXP = self:_GetRequiredXP(self.data.Stats.Level);
    while self.data.Stats.Experience >= requiredXP do
        self.data.Stats.Level = self.data.Stats.Level + 1;
        self.data.Stats.Experience = self.data.Stats.Experience - requiredXP;
        requiredXP = self:_GetRequiredXP(self.data.Stats.Level);

        self.signals.LevelUp:Fire(self.data.Stats.Level);
    end
end
```

## Replica Dependencies

Data keys in `replica_dependencies` are sent to the client:

```lua
local MyComponent = Composer.Extend({
    identifier = 'MyComponent';
    -- ...
    replica_dependencies = { 'Currencies', 'Stats' };
});

function MyComponent:RunOnCompilationCompleted()
    -- self.replica is populated with specified data keys
    -- self.replica.Currencies = self.data.Currencies
    -- self.replica.Stats = self.data.Stats
end
```

On the client:

```lua
local MyController = Composer.Extend({
    identifier = 'MyComponent';
    -- ...
    replica_dependencies = { 'Currencies', 'Stats' };
});

function MyController:RunOnRegistrationCompleted()
    -- self.replica contains server's data
    local coins = self.replica.Currencies.Coins;
    local level = self.replica.Stats.Level;
end
```

## Manual Saving

Data auto-saves when player leaves. For critical operations, save manually:

```lua
local Data = require(Framework.Data);

-- In a component
function MyComponent:OnCriticalAction()
    -- Do important stuff...
    self.data.ImportantValue = newValue;

    -- Force save immediately
    Data.SaveProfile(self.player);
end
```

## Data API Reference

### Data.AttemptLoadData(player)

Loads player profile from DataStore:

```lua
local data = Data.AttemptLoadData(player);
-- Returns profile.Data table or error string
```

### Data.GetProfile(player)

Gets the full profile object:

```lua
local profile = Data.GetProfile(player);
-- Returns ProfileService profile or nil
```

### Data.SaveProfile(player)

Forces immediate save:

```lua
Data.SaveProfile(player);
-- Returns nothing, logs errors
```

## Data Migration

When you need to change data structure:

### Option 1: Increment Version (Fresh Start)

```lua
-- Settings.luau
return {
    key = 'MyGame';
    version = 0002;  -- Was 0001, now players start fresh
    mock = false;
}
```

### Option 2: Use Reconcile (Add Fields)

Just add new fields to Template - `Profile:Reconcile()` merges them:

```lua
-- Template.luau (before)
return {
    Currencies = { Coins = 0 };
}

-- Template.luau (after)
return {
    Currencies = { Coins = 0; Gems = 0 };  -- Gems added
    NewFeature = {};                        -- New table added
}
```

Existing players get new fields with default values on next join.

### Option 3: Manual Migration

Handle in Component initialization:

```lua
function MyComponent:RunOnCompilationCompleted()
    -- Migrate old data format
    if self.data.OldField then
        self.data.NewField = self.data.OldField;
        self.data.OldField = nil;
    end

    -- Add missing nested fields
    if not self.data.Stats.NewStat then
        self.data.Stats.NewStat = 0;
    end
end
```

## Mock Mode

For development without DataStore:

```lua
-- Settings.luau
return {
    key = 'testing';
    version = 0001;
    mock = true;  -- Uses in-memory storage
}
```

**Mock behavior:**
- Data persists during play session
- Data resets when game restarts
- No DataStore API calls
- Useful for rapid iteration

## Error Handling

The framework handles common errors:

```lua
-- In Data.AttemptLoadData
local profile = Store:LoadProfileAsync(`Player_{player.UserId}`);

if profile == nil then
    -- DataStore error or session locked elsewhere
    warn(`Failed to load profile for {player.Name}`);
    return 'Failed to load profile from DataStore';
end

-- Player left during load
if not player:IsDescendantOf(game.Players) then
    profile:Release();
    return 'Player left during data load';
end
```

In Session.RegisterPlayer:

```lua
local success, result = pcall(function()
    return Data.AttemptLoadData(player);
end)

if not success or type(result) ~= 'table' then
    player:Kick('Failed to load your data. Please rejoin.');
    return;
end
```

## Best Practices

1. **Define complete Template** - Include all possible fields
2. **Use appropriate defaults** - `0` for numbers, `{}` for tables, `false` for booleans
3. **Validate before saving** - Ensure data integrity
4. **Don't store Instance references** - Only serializable data
5. **Avoid deep nesting** - Keep data structure flat when possible
6. **Use mock mode in Studio** - Faster development iteration
7. **Increment version carefully** - Players lose data on version change
8. **Handle migration gracefully** - Support old data formats
9. **Keep data minimal** - Only store what's needed
10. **Use replica_dependencies** - Don't send sensitive server data to client
