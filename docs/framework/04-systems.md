# Server Systems

Systems are **global server-side modules** that manage game-wide logic. Unlike Components (which are per-player), Systems exist once and affect all players.

## System vs Component

| Aspect | Component | System |
|--------|-----------|--------|
| Instance | One per player | One global |
| Scope | Player-specific | Game-wide |
| Data access | Player's data | Global state |
| Bridge | Session (per-player) | Global (broadcast) |
| Examples | Currency, Inventory | DayNight, Weather, Economy |

## System Lifecycle

```
[Framework.Initialize() on server]
        │
        ▼
[Scans Server/Systems/ directory]
        │
        ▼
require(SystemModule)
        │
        ▼
System.Initialize()           ← Called automatically if exists
        │
        ▼
[Registered in InternalReplicator.Bridges]
        │
        ▼
    [System Active]           ← Handles global logic
```

## Creating a System

### Basic Structure

```lua
--[=[
    @system SystemName
    @description: What this system does
]=]

local SystemName = {};

-- REQUIRED: System configuration
SystemName.config = {
    identifier = 'SystemName';      -- Unique identifier
    replication = {
        enabled = true;             -- Allow client communication
        authorized = {'Method1'};   -- Client-callable methods
    };
};

-- Services and imports
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Replication = require(ReplicatedStorage.Shared.Framework.Utils.Replication);

-- State (global, not per-player)
SystemName.State = {
    value = 0;
    isActive = false;
};

-- OPTIONAL: Called automatically by framework
function SystemName.Initialize()
    -- Setup logic here
end

-- Methods
function SystemName.DoSomething()
    -- System logic
end

return SystemName;
```

### System Config

```lua
SystemName.config = {
    identifier = 'SystemName';   -- Unique name for routing
    replication = {
        enabled = boolean;       -- Allow client calls
        authorized = { string }; -- Method names client can call
    };
};
```

## Initialize Method

The `Initialize()` function is called automatically when the framework starts:

```lua
function SystemName.Initialize()
    -- Good for:
    -- - Setting up event connections
    -- - Starting game loops
    -- - Initializing external services

    -- Example: Start a game loop
    task.spawn(function()
        while true do
            SystemName._Update();
            task.wait(1);
        end
    end)

    -- Example: Connect to other systems
    local OtherSystem = require(script.Parent.OtherSystem);
    OtherSystem.signals.SomeEvent:Connect(function()
        SystemName._HandleEvent();
    end)
end
```

## Broadcasting to All Clients

### Fire to All (one-way)

```lua
function SystemName.NotifyAllPlayers(message: string)
    Replication.FireAllClients('Global', {
        Identifier = 'InterfaceName';  -- Client interface identifier
        Call = 'ShowMessage';          -- Interface method
        Args = {message};              -- Arguments
    });
end
```

### Fire to Specific Player

```lua
function SystemName.NotifyPlayer(player: Player, data: any)
    Replication.FireToClient('Session', player, {
        Identifier = 'ControllerName';
        Call = 'HandleNotification';
        Args = {data};
    });
end
```

## Receiving Client Requests

### Via Global Bridge (Connect - one way)

```lua
-- Client sends:
Replication.FireToServer('Global', {
    Identifier = 'SystemName';
    Call = 'HandleAction';
    Args = {someData};
});

-- System receives via authorized method:
function SystemName.HandleAction(session, someData)
    -- session is the player's session object
    local player = session.player;

    -- Process the action
    print(player.Name, 'sent:', someData);
end
```

### Via Global Bridge (Invoke - request/response)

```lua
-- Client sends:
local result = Replication.InvokeServer('Global', {
    Identifier = 'SystemName';
    Call = 'GetData';
    Args = {};
});

-- System receives and returns:
function SystemName.GetData()
    return {
        value = SystemName.State.value;
        timestamp = os.time();
    };
end
```

## Accessing Player Data

Systems can access player sessions through the Registry:

```lua
local Registry = require(ReplicatedStorage.Shared.Framework.Registry);

function SystemName.GetPlayerComponent(player: Player, componentName: string)
    local session = Registry[player.UserId];
    if not session or type(session) ~= 'table' then
        return nil;
    end

    return session.components[componentName];
end

-- Usage
function SystemName.RewardAllPlayers(amount: number)
    for _, player in game.Players:GetPlayers() do
        local currency = SystemName.GetPlayerComponent(player, 'Currency');
        if currency then
            currency:EditCurrency('Coins', 'Add', amount);
        end
    end
end
```

## Using Signals

Systems can have their own signal system for inter-system communication:

```lua
local Signal = require(ReplicatedStorage.Shared.Framework.Dependencies.signal);

local DayNightCycle = {};

DayNightCycle.signals = {
    DayStarted = Signal.new();
    NightStarted = Signal.new();
    TimeChanged = Signal.new();
};

function DayNightCycle.Initialize()
    task.spawn(function()
        while true do
            task.wait(300); -- 5 minute day
            DayNightCycle.signals.NightStarted:Fire();

            task.wait(180); -- 3 minute night
            DayNightCycle.signals.DayStarted:Fire();
        end
    end)
end

return DayNightCycle;
```

Other systems can listen:

```lua
local DayNightCycle = require(script.Parent.DayNightCycle);

function EnemySpawner.Initialize()
    DayNightCycle.signals.NightStarted:Connect(function()
        EnemySpawner._SpawnNightEnemies();
    end)

    DayNightCycle.signals.DayStarted:Connect(function()
        EnemySpawner._DespawnNightEnemies();
    end)
end
```

## Complete Example: Quota System

```lua
--!nocheck
--!native
--!optimize 2

--[=[
    @system Quota
    @description: Manages daily quota requirements for fishing game
]=]

local Quota = {};

-- System config
Quota.config = {
    identifier = 'Quota';
    replication = {
        enabled = true;
        authorized = { 'GetCurrentState' };
    };
};

-- Services
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Players = game:GetService('Players');

-- Imports
local State = require(ReplicatedStorage.Shared.Framework.Dependencies.BasicState);
local DayNightCycle = require(script.Parent.DayNightCycle);
local Replication = require(ReplicatedStorage.Shared.Framework.Utils.Replication);
local Registry = require(ReplicatedStorage.Shared.Framework.Registry);

-- State container
Quota.State = State.new({
    Current = 0;
    Required = 100;
});

-- Constants
local REQUIRED_QUOTA_INCREMENT = 100;

-- Authorized: Client can request current state
function Quota.GetCurrentState()
    return {
        Current = Quota.State:Get('Current');
        Required = Quota.State:Get('Required');
    };
end

-- Public: Add to current quota
function Quota.AddQuota(amount: number)
    if type(amount) ~= 'number' or amount <= 0 then return end

    local current = Quota.State:Get('Current');
    Quota.State:Set('Current', current + amount);
end

-- Initialize
function Quota.Initialize()
    -- Listen for state changes
    Quota.State.Changed:Connect(function(oldState, changedKey)
        if changedKey == 'Current' then
            -- Broadcast new state to all players
            local currentState = Quota.GetCurrentState();
            for _, player in Players:GetPlayers() do
                Replication.FireToClient('Session', player, {
                    Identifier = 'Quota';
                    Call = 'UpdateState';
                    Args = { currentState };
                });
            end
        end
    end);

    -- Night started - check if quota was met
    DayNightCycle.signals.NightStarted:Connect(function()
        local current = Quota.State:Get('Current');
        local required = Quota.State:Get('Required');

        if current < required then
            -- Quota failed - notify all players
            Replication.FireAllClients('Session', {
                Identifier = 'Notifications';
                Call = 'DisplayNotification';
                Args = {
                    'The kraken is hungry... A sacrifice will be made tonight.',
                    'Failure',
                    { duration = 10 }
                };
            });

            -- Trigger consequence
            Quota._TriggerFailureConsequence();
        else
            -- Quota met - reward players
            Replication.FireAllClients('Session', {
                Identifier = 'Notifications';
                Call = 'DisplayNotification';
                Args = {
                    'Quota met! The kraken sleeps peacefully.',
                    'Success',
                    { duration = 5 }
                };
            });
        end
    end);

    -- Day started - reset quota and increase requirement
    DayNightCycle.signals.DayStarted:Connect(function()
        Quota.State:Set('Current', 0);
        Quota.State:Set('Required',
            Quota.State:Get('Required') + REQUIRED_QUOTA_INCREMENT
        );
    end);
end

-- Private: Handle quota failure
function Quota._TriggerFailureConsequence()
    -- Example: randomly select a player to "sacrifice"
    local players = Players:GetPlayers();
    if #players == 0 then return end

    local victim = players[math.random(1, #players)];
    local character = victim.Character;

    if character then
        local humanoid = character:FindFirstChildOfClass('Humanoid');
        if humanoid then
            humanoid.Health = 0;
        end
    end
end

return Quota;
```

## Complete Example: Day/Night Cycle System

```lua
--[=[
    @system DayNightCycle
    @description: Manages game time and day/night transitions
]=]

local DayNightCycle = {};

DayNightCycle.config = {
    identifier = 'DayNightCycle';
    replication = {
        enabled = true;
        authorized = { 'GetTimeOfDay', 'GetPhase' };
    };
};

-- Services
local Lighting = game:GetService('Lighting');
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local TweenService = game:GetService('TweenService');

-- Imports
local Signal = require(ReplicatedStorage.Shared.Framework.Dependencies.signal);
local Replication = require(ReplicatedStorage.Shared.Framework.Utils.Replication);

-- Signals
DayNightCycle.signals = {
    DayStarted = Signal.new();
    NightStarted = Signal.new();
    PhaseChanged = Signal.new();
};

-- State
DayNightCycle.CurrentPhase = 'Day';
DayNightCycle.TimeScale = 1; -- 1 = real time, higher = faster

-- Constants
local DAY_LENGTH = 300;   -- 5 minutes
local NIGHT_LENGTH = 180; -- 3 minutes
local SUNRISE_TIME = 6;   -- 6 AM
local SUNSET_TIME = 18;   -- 6 PM

-- Authorized methods
function DayNightCycle.GetTimeOfDay()
    return Lighting.ClockTime;
end

function DayNightCycle.GetPhase()
    return DayNightCycle.CurrentPhase;
end

-- Public: Set time scale
function DayNightCycle.SetTimeScale(scale: number)
    if type(scale) ~= 'number' or scale <= 0 then return end
    DayNightCycle.TimeScale = scale;
end

-- Initialize
function DayNightCycle.Initialize()
    -- Start at dawn
    Lighting.ClockTime = SUNRISE_TIME;
    DayNightCycle.CurrentPhase = 'Day';

    -- Main time loop
    task.spawn(function()
        while true do
            DayNightCycle._RunDayCycle();
            DayNightCycle._RunNightCycle();
        end
    end)
end

-- Private: Run day cycle
function DayNightCycle._RunDayCycle()
    DayNightCycle.CurrentPhase = 'Day';
    DayNightCycle.signals.DayStarted:Fire();
    DayNightCycle.signals.PhaseChanged:Fire('Day');

    -- Broadcast to clients
    Replication.FireAllClients('Global', {
        Identifier = 'TimeDisplay';
        Call = 'OnPhaseChanged';
        Args = { 'Day' };
    });

    -- Animate from sunrise to sunset
    local dayTween = TweenService:Create(
        Lighting,
        TweenInfo.new(DAY_LENGTH / DayNightCycle.TimeScale, Enum.EasingStyle.Linear),
        { ClockTime = SUNSET_TIME }
    );

    dayTween:Play();
    dayTween.Completed:Wait();
end

-- Private: Run night cycle
function DayNightCycle._RunNightCycle()
    DayNightCycle.CurrentPhase = 'Night';
    DayNightCycle.signals.NightStarted:Fire();
    DayNightCycle.signals.PhaseChanged:Fire('Night');

    -- Broadcast to clients
    Replication.FireAllClients('Global', {
        Identifier = 'TimeDisplay';
        Call = 'OnPhaseChanged';
        Args = { 'Night' };
    });

    -- Animate from sunset to sunrise (through midnight)
    local nightTween = TweenService:Create(
        Lighting,
        TweenInfo.new(NIGHT_LENGTH / DayNightCycle.TimeScale, Enum.EasingStyle.Linear),
        { ClockTime = SUNRISE_TIME + 24 } -- Goes through midnight
    );

    nightTween:Play();
    nightTween.Completed:Wait();

    -- Reset to normal time range
    Lighting.ClockTime = SUNRISE_TIME;
end

return DayNightCycle;
```

## Best Practices

1. **Keep systems focused** - One responsibility per system
2. **Use signals for inter-system communication** - Avoid tight coupling
3. **Validate client input** - Even for authorized methods
4. **Consider performance** - Systems affect all players
5. **Document dependencies** - Note which systems depend on others
6. **Use State containers** - Makes reactive updates easier
7. **Handle player join/leave** - Players may join mid-game
