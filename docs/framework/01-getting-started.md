# Getting Started

## Prerequisites

- Roblox Studio
- Wally package manager (via Aftman)
- Basic understanding of Luau

## Project Setup

### 1. Install Dependencies

The framework uses Wally for package management. Install packages:

```bash
wally install
```

This installs:
- `camerashaker` - Camera effects
- `zoneplus` - Zone detection
- `simplepath` - Pathfinding

### 2. Project Structure

Ensure your project follows this structure:

```
game/
├── ReplicatedStorage/
│   └── Shared/
│       └── Framework/     # All framework modules
│
├── ServerScriptService/
│   └── Server/
│       ├── Components/    # Your server components
│       ├── Systems/       # Your global systems
│       └── init.legacy.luau
│
└── StarterPlayer/
    └── StarterPlayerScripts/
        └── Client/
            ├── Controllers/ # Your client controllers
            ├── Interfaces/  # Your global interfaces
            └── init.local.luau
```

### 3. Server Initialization

Create `ServerScriptService/Server/init.legacy.luau`:

```lua
local Framework = require(game.ReplicatedStorage.Shared.Framework);
Framework.Initialize();
```

This single line:
- Initializes server replication handlers
- Sets up PlayerAdded/PlayerRemoving listeners
- Auto-loads all Systems from `Server/Systems/`
- Auto-loads all Components for each player

### 4. Client Initialization

Create `StarterPlayerScripts/Client/init.local.luau`:

```lua
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Framework = require(ReplicatedStorage.Shared.Framework);

Framework.Initialize();
```

This:
- Initializes client replication handlers
- Waits for server to send player data
- Auto-loads all Controllers from `Client/Controllers/`
- Auto-loads all Interfaces from `Client/Interfaces/`

## Creating Your First Component

### Server Component

Create `ServerScriptService/Server/Components/Health.luau`:

```lua
--[=[
    @component Health
    @dependencies: none
    @description: Manages player health state
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

-- Imports
local Composer = require(Framework.Main.Component);
local Replication = require(Framework.Utils.Replication);

-- Define the component
local HealthComponent = Composer.Extend({
    identifier = 'Health';           -- Unique name (must match controller)
    dependencies = {};               -- Other components this depends on

    replication = {
        enabled = true;              -- Allow client communication
        authorized = {'RequestHeal'}; -- Methods client can call
    };

    state = {                        -- Local component state
        maxHealth = 100;
        currentHealth = 100;
    };

    replica_dependencies = {};       -- Data keys to sync to client
});

-- Called after all components are compiled
function HealthComponent:RunOnRegistrationCompleted()
    -- Initialize state from saved data if exists
    if self.data.Health then
        self.state.currentHealth = self.data.Health.current or 100;
        self.state.maxHealth = self.data.Health.max or 100;
    end

    -- Sync initial state to client
    self:_ReplicateHealth();
end

-- Take damage (called by other server systems)
function HealthComponent:TakeDamage(amount: number)
    if type(amount) ~= "number" or amount <= 0 then return end

    self.state.currentHealth = math.max(0, self.state.currentHealth - amount);
    self:_ReplicateHealth();

    if self.state.currentHealth <= 0 then
        self.signals.PlayerDied:Fire();
    end
end

-- Heal (can be called from client if authorized)
function HealthComponent:RequestHeal(amount: number)
    if type(amount) ~= "number" or amount <= 0 then return end

    self.state.currentHealth = math.min(
        self.state.maxHealth,
        self.state.currentHealth + amount
    );
    self:_ReplicateHealth();
end

-- Private: sync to client
function HealthComponent:_ReplicateHealth()
    Replication.FireToClient('Session', self.player, {
        Identifier = 'Health';
        Call = 'UpdateHealth';
        Args = {self.state.currentHealth, self.state.maxHealth};
    });
end

return HealthComponent;
```

### Client Controller

Create `StarterPlayerScripts/Client/Controllers/Health.luau`:

```lua
--[=[
    @controller Health
    @dependencies: none
    @description: Displays health UI
]=]

local Framework = game.ReplicatedStorage.Shared.Framework;

-- Imports
local Composer = require(Framework.Main.Controller);

-- Define the controller
local HealthController = Composer.Extend({
    identifier = 'Health';           -- Must match component identifier
    dependencies = {};

    state = {
        currentHealth = 100;
        maxHealth = 100;
    };

    replica_dependencies = {};
});

function HealthController:RunOnRegistrationCompleted()
    -- Initial UI setup
    self:_UpdateHealthBar();
end

-- Called by server via replication
function HealthController:UpdateHealth(current: number, max: number)
    self.state.currentHealth = current;
    self.state.maxHealth = max;
    self:_UpdateHealthBar();
end

-- Private: update UI
function HealthController:_UpdateHealthBar()
    -- Find your health bar UI element
    local player = game.Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');
    local healthBar = gui:FindFirstChild('HealthBar', true);

    if healthBar then
        local percent = self.state.currentHealth / self.state.maxHealth;
        healthBar.Size = UDim2.fromScale(percent, 1);
    end
end

return HealthController;
```

## Creating Your First System

Create `ServerScriptService/Server/Systems/GameTimer.luau`:

```lua
--[=[
    @system GameTimer
    @description: Manages round timing
]=]

local GameTimer = {};

-- System config (required)
GameTimer.config = {
    identifier = 'GameTimer';
    replication = {
        enabled = true;
        authorized = {'GetTimeRemaining'}; -- Methods client can invoke
    };
};

-- Imports
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local Replication = require(ReplicatedStorage.Shared.Framework.Utils.Replication);

-- State
local timeRemaining = 300; -- 5 minutes

-- Authorized client method
function GameTimer.GetTimeRemaining()
    return timeRemaining;
end

-- Called automatically when framework initializes
function GameTimer.Initialize()
    -- Start the timer
    task.spawn(function()
        while timeRemaining > 0 do
            task.wait(1);
            timeRemaining = timeRemaining - 1;

            -- Broadcast to all clients every 10 seconds
            if timeRemaining % 10 == 0 then
                Replication.FireAllClients('Global', {
                    Identifier = 'Timer';
                    Call = 'UpdateTime';
                    Args = {timeRemaining};
                });
            end
        end

        -- Timer ended
        Replication.FireAllClients('Global', {
            Identifier = 'Timer';
            Call = 'TimeUp';
            Args = {};
        });
    end)
end

return GameTimer;
```

## Creating Your First Interface

Create `StarterPlayerScripts/Client/Interfaces/TimerDisplay.luau`:

```lua
--[=[
    @interface TimerDisplay
    @description: Shows game timer on screen
]=]

local TimerDisplay = {};

-- Optional config for receiving Global broadcasts
TimerDisplay.config = {
    identifier = 'Timer';
};

-- Called automatically when client initializes
function TimerDisplay.Initialize()
    -- Create UI (or reference existing)
    local player = game.Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');

    -- Create a simple timer label
    local screenGui = Instance.new('ScreenGui');
    screenGui.Name = 'TimerGui';
    screenGui.Parent = gui;

    local label = Instance.new('TextLabel');
    label.Name = 'TimerLabel';
    label.Size = UDim2.fromOffset(200, 50);
    label.Position = UDim2.fromScale(0.5, 0.05);
    label.AnchorPoint = Vector2.new(0.5, 0);
    label.Text = '5:00';
    label.Parent = screenGui;

    TimerDisplay.Label = label;
end

-- Called via Global broadcast
function TimerDisplay.UpdateTime(seconds: number)
    local minutes = math.floor(seconds / 60);
    local secs = seconds % 60;
    TimerDisplay.Label.Text = string.format('%d:%02d', minutes, secs);
end

-- Called via Global broadcast
function TimerDisplay.TimeUp()
    TimerDisplay.Label.Text = 'TIME UP!';
    TimerDisplay.Label.TextColor3 = Color3.fromRGB(255, 0, 0);
end

return TimerDisplay;
```

## Data Persistence Setup

### 1. Configure Data Settings

Edit `Shared/Framework/Data/Settings.luau`:

```lua
return {
    key = 'MyGame';      -- DataStore key prefix
    version = 0001;      -- Increment when data schema changes
    mock = false;        -- Set true for Studio testing without DataStore
}
```

### 2. Define Data Template

Edit `Shared/Framework/Data/Template.luau`:

```lua
return {
    -- Player currencies
    Currencies = {
        Coins = 0;
        Gems = 0;
    };

    -- Inventory data
    Inventory = {};

    -- Player stats
    Stats = {
        Level = 1;
        Experience = 0;
    };

    -- Settings
    Settings = {
        MusicVolume = 0.5;
        SFXVolume = 0.5;
    };
}
```

This template defines the default data structure for new players. ProfileService automatically reconciles existing player data with this template when loaded.

## Testing Your Setup

1. Start a test server in Studio (F5 or Server/Client view)
2. Watch the Output for framework logs:
   - `[Session:RegisterPlayer] Starting registration for PlayerName`
   - `[Session:RegisterPlayer] All components compiled for PlayerName`
   - `[InternalReplicationHandler:Loader] Received loader callback from client`

3. If you see errors, check:
   - File locations match expected paths
   - `identifier` in component matches controller
   - All dependencies exist and are spelled correctly

## Next Steps

- Read [02-components.md](./02-components.md) for detailed component documentation
- Read [03-controllers.md](./03-controllers.md) for controller patterns
- Read [06-replication.md](./06-replication.md) for network communication details
