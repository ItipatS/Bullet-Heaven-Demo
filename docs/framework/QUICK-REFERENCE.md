# IGD Framework Quick Reference

## Component Template

```lua
--[=[
    @component ComponentName
    @dependencies: Dep1, Dep2
    @description: Description here
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;
local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

local MyComponent = Composer.Extend({
    identifier = 'ComponentName';          -- Must match controller
    dependencies = {'Dep1', 'Dep2'};       -- Other components
    replication = {
        enabled = true;
        authorized = {'ClientMethod'};     -- Client-callable methods
    };
    state = { value = 0 };                 -- Runtime state
    replica_dependencies = {'DataKey'};    -- Data sent to client
});

function MyComponent:RunOnCompilationCompleted()
    self:AddSignal('CustomSignal');
end

function MyComponent:RunOnRegistrationCompleted()
    -- Safe to replicate here
end

function MyComponent:ClientMethod(arg)
    -- Validate arg!
    if type(arg) ~= 'string' then return end
    -- Process...
end

return MyComponent;
```

## Controller Template

```lua
--[=[
    @controller ControllerName
    @dependencies: Dep1
    @description: Description here
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;
local Composer = require(Framework.Main.Controller);
local Replication = require(Framework.Utils.Replication);

local MyController = Composer.Extend({
    identifier = 'ControllerName';         -- Must match component
    dependencies = {'Dep1'};
    state = { value = 0 };
    replica_dependencies = {'DataKey'};
});

function MyController:RunOnRegistrationCompleted()
    -- Set up UI here
end

function MyController:ServerUpdate(newValue)
    self.state.value = newValue;
    -- Update UI
end

return MyController;
```

## System Template

```lua
--[=[
    @system SystemName
    @description: Description here
]=]

local SystemName = {};

SystemName.config = {
    identifier = 'SystemName';
    replication = {
        enabled = true;
        authorized = {'GetState'};
    };
};

local Replication = require(game.ReplicatedStorage.Shared.Framework.Utils.Replication);

function SystemName.Initialize()
    -- Called automatically on server start
end

function SystemName.GetState()
    return SystemName.state;
end

return SystemName;
```

## Interface Template

```lua
--[=[
    @interface InterfaceName
    @description: Description here
]=]

local InterfaceName = {};

InterfaceName.config = {
    identifier = 'InterfaceName';  -- For Global broadcasts
};

function InterfaceName.Initialize()
    -- Called automatically on client start
end

function InterfaceName.OnBroadcast(data)
    -- Called via Global bridge
end

return InterfaceName;
```

## Replication Cheatsheet

### Server → Client (Session)

```lua
Replication.FireToClient('Session', player, {
    Identifier = 'ControllerName';
    Call = 'MethodName';
    Args = { arg1, arg2 };
});
```

### Server → All Clients (Global)

```lua
Replication.FireAllClients('Global', {
    Identifier = 'InterfaceName';
    Call = 'MethodName';
    Args = { data };
});
```

### Client → Server (Fire)

```lua
Replication.FireToServer('Session', {
    Identifier = 'ComponentName';
    Call = 'AuthorizedMethod';
    Args = { data };
});
```

### Client → Server (Invoke)

```lua
local result = Replication.InvokeServer('Session', {
    Identifier = 'ComponentName';
    Call = 'AuthorizedMethod';
    Args = { data };
});
```

## Data Access

### In Components

```lua
-- Read
local coins = self.data.Currencies.Coins;

-- Write (auto-saves)
self.data.Currencies.Coins = self.data.Currencies.Coins + 100;

-- Manual save
local Data = require(Framework.Data);
Data.SaveProfile(self.player);
```

### Data Template

```lua
-- Shared/Framework/Data/Template.luau
return {
    Currencies = { Coins = 0; Gems = 0 };
    Inventory = {};
    Stats = { Level = 1; Experience = 0 };
};
```

## Signals

```lua
-- Create
self:AddSignal('MySignal');

-- Fire
self.signals.MySignal:Fire(data);

-- Listen
self.dependencies.Other.signals.MySignal:Connect(function(data)
    -- Handle
end)
```

## FormatUtils

```lua
local F = require(Framework.Utils.FormatUtils);

F.format_to_short_value(1500)     --> "1.5K"
F.format_to_long_value(1500)      --> "1,500"
F.format_to_HHMMSS(90)            --> "1m 30s"
F.format_to_electronic_time(90)   --> "01:30"
F.deep_copy(table)                --> deep copy
```

## Lifecycle Order

### Server (per player)
1. `Component.new(player, data)`
2. `Component:Compile(dependencies)`
3. `RunOnCompilationCompleted()`
4. [Client confirms ready]
5. `Component:Register()`
6. `RunOnRegistrationCompleted()`
7. [Player leaves]
8. `Component:Destroy()`

### Client
1. [Receives data from Loader]
2. `Controller.new(player, replica)`
3. `Controller:Compile(dependencies)`
4. `RunOnCompilationCompleted()`
5. `Controller:Register(replica)`
6. `RunOnRegistrationCompleted()`
7. [Interfaces Initialize]

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Identifier mismatch | Component and Controller must have same `identifier` |
| Calling unauthorized method | Add method to `replication.authorized` |
| Not validating client input | Always check types and bounds |
| Modifying state without replicating | Fire update after changing `self.data` |
| Requiring components directly | Use `self.dependencies.ComponentName` |
| Replicating before client ready | Wait for `RunOnRegistrationCompleted` |

## Directory Structure

```
ServerScriptService/Server/
├── Components/          # Per-player server modules
├── Systems/             # Global server modules
└── init.legacy.luau     # Server entry

StarterPlayerScripts/Client/
├── Controllers/         # Per-player client modules
├── Interfaces/          # Global client modules
└── init.local.luau      # Client entry

ReplicatedStorage/Shared/Framework/
├── Main/
│   ├── Component.luau
│   └── Controller.luau
├── Data/
│   ├── init.luau
│   ├── Template.luau
│   └── Settings.luau
├── Utils/
│   ├── Replication.luau
│   ├── FormatUtils.luau
│   └── Tweens.luau
└── UI/
    ├── UIStateController.luau
    └── Registry/
```

## Config Options

### Component Config
```lua
{
    identifier: string,              -- Required, unique name
    dependencies: { string },        -- Required, component names
    replication: {
        enabled: boolean,            -- Required
        authorized: { string }       -- Required, method names
    },
    state: { [string]: any },        -- Optional, initial state
    replica_dependencies: { string } -- Required, data keys for client
}
```

### Data Settings
```lua
-- Shared/Framework/Data/Settings.luau
{
    key = 'GameName';      -- DataStore prefix
    version = 0001;        -- Version number
    mock = true;           -- Use mock in Studio
}
```
