# Utilities Reference

The framework includes various utility modules for common operations.

## FormatUtils

Number and string formatting utilities.

### Location
`Shared/Framework/Utils/FormatUtils.luau`

### Number Formatting

#### format_to_short_value
Converts numbers to abbreviated format:

```lua
local FormatUtils = require(Framework.Utils.FormatUtils);

FormatUtils.format_to_short_value(500)      --> "500"
FormatUtils.format_to_short_value(1000)     --> "1.0K"
FormatUtils.format_to_short_value(1500)     --> "1.5K"
FormatUtils.format_to_short_value(1000000)  --> "1.0M"
FormatUtils.format_to_short_value(2500000)  --> "2.5M"
```

Supported suffixes: K, M, B, T, Qa, Qi, Sx, Sp, Oc, No, Dc, Ud, Dd

#### decode_from_short_value
Converts abbreviated format back to numbers:

```lua
FormatUtils.decode_from_short_value("1.5K")  --> 1500
FormatUtils.decode_from_short_value("2.5M")  --> 2500000
FormatUtils.decode_from_short_value("100")   --> 100
```

#### format_to_long_value
Adds comma separators to numbers:

```lua
FormatUtils.format_to_long_value(500)       --> "500"
FormatUtils.format_to_long_value(1000)      --> "1,000"
FormatUtils.format_to_long_value(1000000)   --> "1,000,000"
FormatUtils.format_to_long_value(1234567)   --> "1,234,567"
```

### Time Formatting

#### format_to_HHMMSS
Human-readable duration:

```lua
FormatUtils.format_to_HHMMSS(45)      --> "45s"
FormatUtils.format_to_HHMMSS(90)      --> "1m 30s"
FormatUtils.format_to_HHMMSS(3600)    --> "1h 0m"
FormatUtils.format_to_HHMMSS(3661)    --> "1h 1m"
```

#### format_to_electronic_time
Digital clock format:

```lua
FormatUtils.format_to_electronic_time(45)     --> "00:45"
FormatUtils.format_to_electronic_time(90)     --> "01:30"
FormatUtils.format_to_electronic_time(3600)   --> "01:00:00"
FormatUtils.format_to_electronic_time(3661)   --> "01:01:01"
```

### Table Utilities

#### deep_copy
Creates a deep copy of a table:

```lua
local original = {
    nested = { value = 1 };
    array = { 1, 2, 3 };
}

local copy = FormatUtils.deep_copy(original);
copy.nested.value = 2;

print(original.nested.value) --> 1 (unchanged)
print(copy.nested.value)     --> 2
```

#### total_in_table
Sums all numeric values in a table:

```lua
local scores = { a = 10, b = 20, c = 30 };
FormatUtils.total_in_table(scores) --> 60
```

#### get_dictionary_length
Counts keys in a dictionary:

```lua
local dict = { a = 1, b = 2, c = 3 };
FormatUtils.get_dictionary_length(dict) --> 3
```

#### get_dictionary_key_index
Gets the position of a key:

```lua
local dict = { a = 1, b = 2, c = 3 };
FormatUtils.get_dictionary_key_index('b', dict) --> 2
```

### Color Utilities

#### color_to_hex
Converts Color3 to hex string:

```lua
local red = Color3.fromRGB(255, 0, 0);
FormatUtils.color_to_hex(red) --> "FF0000"

local blue = Color3.fromRGB(0, 128, 255);
FormatUtils.color_to_hex(blue) --> "0080FF"
```

### Movement Utilities

#### get_camera_relative_direction
Determines movement direction relative to camera:

```lua
local direction = FormatUtils.get_camera_relative_direction(
    moveVector,        -- Player's movement input
    workspace.CurrentCamera
)
--> 'Forward', 'Back', 'Left', 'Right', or 'None'
```

### Path Utilities

#### parse_path
Navigates a path string to find an instance:

```lua
local item = FormatUtils.parse_path(workspace, 'Folder/SubFolder/Part');
-- Equivalent to: workspace.Folder.SubFolder.Part
```

---

## Replication Utility

Network communication utilities.

### Location
`Shared/Framework/Utils/Replication.luau`

### Server Methods

#### FireToClient
Send message to specific player:

```lua
local Replication = require(Framework.Utils.Replication);

Replication.FireToClient('Session', player, {
    Identifier = 'Currency';
    Call = 'UpdateCurrency';
    Args = { 'Coins', 100 };
});
```

#### FireAllClients
Broadcast to all players:

```lua
Replication.FireAllClients('Global', {
    Identifier = 'Notifications';
    Call = 'ShowMessage';
    Args = { 'Hello everyone!' };
});
```

### Client Methods

#### FireToServer
Send message to server:

```lua
Replication.FireToServer('Session', {
    Identifier = 'Shop';
    Call = 'PurchaseItem';
    Args = { 'sword_01' };
});
```

#### InvokeServer
Send and wait for response:

```lua
local result = Replication.InvokeServer('Session', {
    Identifier = 'Inventory';
    Call = 'GetItemDetails';
    Args = { itemId };
});

if result then
    print('Item name:', result.name);
end
```

---

## Tweens Utility

Button animation utilities.

### Location
`Shared/Framework/Utils/Tweens.luau`

### SetHover
Add hover scale effect:

```lua
local Tweens = require(Framework.Utils.Tweens);

-- Buttons need UIScale child
Tweens.SetHover({ button1, button2 }, 1.1);  -- 10% larger on hover
Tweens.SetHover({ button3 }, 1.05, false);   -- Don't overwrite existing
```

### SetClick
Add click scale effect:

```lua
Tweens.SetClick({ button1, button2 }, 0.9);  -- 10% smaller on click
Tweens.SetClick({ button3 }, 0.95, true);    -- Overwrite existing
```

---

## Signal Library

Event/signal system for custom events.

### Location
`Shared/Framework/Dependencies/signal.luau`

### Creating Signals

```lua
local Signal = require(Framework.Dependencies.signal);

local mySignal = Signal.new();
```

### Connecting to Signals

```lua
local connection = mySignal:Connect(function(arg1, arg2)
    print('Signal fired with:', arg1, arg2);
end)
```

### Firing Signals

```lua
mySignal:Fire('hello', 42);
-- Output: "Signal fired with: hello 42"
```

### Disconnecting

```lua
connection:Disconnect();

-- Or disconnect all
mySignal:DisconnectAll();
```

### Once (single use)

```lua
mySignal:Once(function(value)
    print('This only fires once:', value);
end)
```

### Wait (yield until fired)

```lua
local value = mySignal:Wait();
print('Signal fired with:', value);
```

---

## State Management

### BasicState

Simple reactive state container.

```lua
local State = require(Framework.Dependencies.BasicState);

local playerState = State.new({
    Health = 100;
    Mana = 50;
    IsAlive = true;
});

-- Get value
local health = playerState:Get('Health'); --> 100

-- Set value
playerState:Set('Health', 80);

-- Listen for changes
playerState.Changed:Connect(function(oldState, changedKey)
    print('Changed:', changedKey);
    print('Old value:', oldState[changedKey]);
    print('New value:', playerState:Get(changedKey));
end)
```

### FSM (Finite State Machine)

For complex state transitions.

### Location
`Shared/Modules/fsm.luau`

```lua
local FSM = require(ReplicatedStorage.Shared.Modules.fsm);

local stateMachine = FSM.create({
    initial = 'idle';
    events = {
        { name = 'walk',   from = 'idle',    to = 'walking' };
        { name = 'run',    from = 'walking', to = 'running' };
        { name = 'stop',   from = {'walking', 'running'}, to = 'idle' };
        { name = 'jump',   from = '*', to = 'jumping' };  -- From any state
        { name = 'land',   from = 'jumping', to = 'idle' };
    };
    callbacks = {
        on_enter_walking = function(self, event, from, to)
            print('Started walking');
        end;
        on_leave_walking = function(self, event, from, to)
            print('Stopped walking');
        end;
        on_before_jump = function(self, event, from, to)
            print('About to jump from', from);
            -- return false to cancel transition
        end;
    };
});

-- Trigger transitions
stateMachine:walk();   -- idle -> walking
stateMachine:run();    -- walking -> running
stateMachine:stop();   -- running -> idle

-- Check current state
print(stateMachine.current); --> 'idle'

-- Check if transition is valid
print(stateMachine:can('walk')); --> true
print(stateMachine:can('land')); --> false (not in jumping state)
```

### StateManager

Higher-level state machine wrapper.

### Location
`Shared/Modules/StateManager.luau`

```lua
local StateManager = require(ReplicatedStorage.Shared.Modules.StateManager);

local combatStates = StateManager.new();

-- Add states dynamically
combatStates:AddState('idle', {
    enter = function() print('Entered idle'); end;
    exit = function() print('Exited idle'); end;
    update = function(dt) end;
});

combatStates:AddState('attacking', {
    enter = function() print('Started attack'); end;
    exit = function() print('Finished attack'); end;
});

-- Transition
combatStates:SetState('attacking');

-- Enable/disable states
combatStates:DisableState('attacking');  -- Can't enter
combatStates:EnableState('attacking');   -- Can enter again

-- Remove state
combatStates:RemoveState('attacking');
```

---

## Spring Animation

Physics-based spring animations.

### Location
`Shared/Modules/Spring.luau`

```lua
local Spring = require(ReplicatedStorage.Shared.Modules.Spring);

-- Create spring with target value
local positionSpring = Spring.new(Vector3.new(0, 0, 0));

-- Configure spring
positionSpring.Speed = 10;    -- Higher = faster
positionSpring.Damper = 0.5;  -- Higher = less bouncy (0-1)

-- Set target
positionSpring:SetTarget(Vector3.new(10, 5, 0));

-- Update every frame
RunService.Heartbeat:Connect(function(dt)
    positionSpring:Update(dt);

    -- Get current value
    local position = positionSpring:GetValue();
    part.Position = position;
end)

-- Impulse (sudden force)
positionSpring:Impulse(Vector3.new(0, 50, 0));
```

---

## Lootplan

Weighted random selection for loot tables.

### Location
`Shared/Framework/Utils/Lootplan.luau`

```lua
local Lootplan = require(Framework.Utils.Lootplan);

-- Create loot table
local fishLoot = Lootplan.new({
    { item = 'common_fish',    weight = 100 };
    { item = 'uncommon_fish',  weight = 50 };
    { item = 'rare_fish',      weight = 10 };
    { item = 'legendary_fish', weight = 1 };
});

-- Roll for loot
local result = fishLoot:Roll();
print('Caught:', result.item);

-- Roll multiple
local results = fishLoot:RollMultiple(3);
for _, loot in results do
    print('Caught:', loot.item);
end
```

---

## AnimationContainer

Animation management for characters/viewmodels.

### Location
`Shared/Framework/Utils/AnimationContainer.luau`

```lua
local AnimationContainer = require(Framework.Utils.AnimationContainer);

-- Create container for animator
local animations = AnimationContainer.new(humanoid.Animator);

-- Load animations
animations:Load('idle', idleAnimation);
animations:Load('walk', walkAnimation);
animations:Load('run', runAnimation);

-- Play animation
animations:Play('idle');

-- Play with options
animations:Play('walk', {
    FadeTime = 0.2;
    Weight = 1;
    Speed = 1;
});

-- Stop animation
animations:Stop('walk', 0.2);  -- Fade out time

-- Stop all
animations:StopAll(0.1);

-- Get animation track
local track = animations:Get('idle');
print('Is playing:', track.IsPlaying);
```

---

## SFX Utility

Sound effect playback.

### Location
`Shared/Framework/Utils/SFX.luau`

```lua
local SFX = require(Framework.Utils.SFX);

-- Play sound
SFX.Play('click');

-- Play with options
SFX.Play('explosion', {
    Volume = 0.8;
    PlaybackSpeed = 1.2;
});

-- Play at position (3D sound)
SFX.PlayAtPosition('footstep', character.HumanoidRootPart.Position, {
    MaxDistance = 50;
});
```

---

## Utility Patterns

### Chaining Operations

```lua
-- Format currency for display
function formatCurrency(amount, style)
    if style == 'short' then
        return FormatUtils.format_to_short_value(amount);
    else
        return FormatUtils.format_to_long_value(amount);
    end
end
```

### Debouncing

```lua
local debounce = false;

function handleAction()
    if debounce then return end
    debounce = true;

    -- Do action...

    task.delay(0.5, function()
        debounce = false;
    end)
end
```

### Throttling

```lua
local lastCall = 0;
local THROTTLE_TIME = 0.1;

function handleInput()
    local now = tick();
    if now - lastCall < THROTTLE_TIME then return end
    lastCall = now;

    -- Handle input...
end
```

### Safe Table Access

```lua
function safeGet(tbl, ...)
    local value = tbl;
    for _, key in {...} do
        if type(value) ~= 'table' then
            return nil;
        end
        value = value[key];
    end
    return value;
end

-- Usage
local coins = safeGet(playerData, 'Currencies', 'Coins') or 0;
```
