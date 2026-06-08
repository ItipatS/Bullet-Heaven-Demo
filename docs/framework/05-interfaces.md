# Client Interfaces

Interfaces are **global client-side modules** that handle world interaction and visual effects. Unlike Controllers (which are per-player mirrors of Components), Interfaces manage client-side systems that don't need server counterparts.

## Interface vs Controller

| Aspect | Controller | Interface |
|--------|------------|-----------|
| Mirrors | Server Component | Nothing (standalone) |
| Purpose | Player state/UI | World interaction, effects |
| Data | Receives replica from server | Self-managed or broadcast |
| Bridge | Session (targeted) | Global (broadcast) |
| Examples | Currency, Inventory | Highlights, Particles, Sounds |

## Interface Lifecycle

```
[Client receives data from server Loader]
        │
        ▼
[Controllers loaded and registered]
        │
        ▼
[Framework scans Client/Interfaces/]
        │
        ▼
require(InterfaceModule)
        │
        ▼
Interface.Initialize()        ← Called automatically if exists
        │
        ▼
[Registered in InternalReplicator.Bridges]
        │
        ▼
    [Interface Active]        ← Handles client-side logic
```

## Creating an Interface

### Basic Structure

```lua
--[=[
    @interface InterfaceName
    @description: What this interface does
]=]

local InterfaceName = {};

-- OPTIONAL: Config for receiving Global broadcasts
InterfaceName.config = {
    identifier = 'InterfaceName';  -- For Global bridge routing
};

-- Services
local Players = game:GetService('Players');

-- State
InterfaceName.IsActive = false;

-- OPTIONAL: Called automatically by framework
function InterfaceName.Initialize()
    -- Setup logic
end

-- Methods (can be called via Global broadcast)
function InterfaceName.SomeMethod(arg1, arg2)
    -- Handle broadcast
end

return InterfaceName;
```

### Interface Config

The config is optional but required to receive Global broadcasts:

```lua
InterfaceName.config = {
    identifier = 'InterfaceName';  -- Must match broadcast Identifier
};
```

## Initialize Method

Called automatically after Controllers are ready:

```lua
function InterfaceName.Initialize()
    -- Good for:
    -- - Setting up input handlers
    -- - Creating visual effects
    -- - Connecting to world events

    -- Example: Set up input
    local UserInputService = game:GetService('UserInputService');
    UserInputService.InputBegan:Connect(function(input)
        InterfaceName._HandleInput(input);
    end)

    -- Example: Set up world listeners
    workspace.ChildAdded:Connect(function(child)
        InterfaceName._OnObjectAdded(child);
    end)
end
```

## Receiving Global Broadcasts

### Server System (sends broadcast)

```lua
-- In server system
Replication.FireAllClients('Global', {
    Identifier = 'InterfaceName';  -- Interface identifier
    Call = 'HandleEvent';          -- Interface method
    Args = {arg1, arg2};           -- Arguments
});
```

### Client Interface (receives broadcast)

```lua
-- Interface config must have matching identifier
InterfaceName.config = {
    identifier = 'InterfaceName';
};

-- This method is called automatically
function InterfaceName.HandleEvent(arg1, arg2)
    -- Handle the broadcast
    print('Received:', arg1, arg2);
end
```

## Sending Requests to Server

Interfaces can communicate with server Systems:

### Fire (one-way)

```lua
local Replication = require(Framework.Utils.Replication);

function InterfaceName.NotifyServer(data)
    Replication.FireToServer('Global', {
        Identifier = 'SystemName';
        Call = 'HandleNotification';
        Args = {data};
    });
end
```

### Invoke (request/response)

```lua
function InterfaceName.RequestFromServer()
    local result = Replication.InvokeServer('Global', {
        Identifier = 'SystemName';
        Call = 'GetData';
        Args = {};
    });

    return result;
end
```

## Complete Example: Interactable Highlights

```lua
--[=[
    @interface InteractableHighlights
    @description: Visual highlighting for interactable objects
]=]

local InteractableHighlights = {};
InteractableHighlights.Highlights = {};

-- Services
local CollectionService = game:GetService('CollectionService');
local TweenService = game:GetService('TweenService');

-- Initialize
function InteractableHighlights.Initialize()
    -- Set up existing interactables
    InteractableHighlights._SetupExistingInteractables();

    -- Listen for new interactables
    InteractableHighlights._SetupInteractableListeners();
end

-- Private: Process existing tagged objects
function InteractableHighlights._SetupExistingInteractables()
    local existingInteractables = CollectionService:GetTagged('Interactable');

    for _, object in ipairs(existingInteractables) do
        InteractableHighlights._RegisterInteractable(object);
    end
end

-- Private: Listen for tag changes
function InteractableHighlights._SetupInteractableListeners()
    CollectionService:GetInstanceAddedSignal('Interactable'):Connect(function(object)
        InteractableHighlights._RegisterInteractable(object);
    end)

    CollectionService:GetInstanceRemovedSignal('Interactable'):Connect(function(object)
        InteractableHighlights._UnregisterInteractable(object);
    end)
end

-- Private: Register an interactable object
function InteractableHighlights._RegisterInteractable(object: BasePart)
    if not object then return end
    if InteractableHighlights.Highlights[object] then return end

    -- Create highlight effect
    local highlight = Instance.new('Highlight');
    highlight.FillTransparency = 1;
    highlight.OutlineTransparency = 1;
    highlight.Parent = object;
    highlight.DepthMode = Enum.HighlightDepthMode.Occluded;
    highlight.OutlineColor = Color3.fromRGB(255, 255, 255);
    highlight.FillColor = Color3.fromRGB(255, 255, 255);

    -- Store data
    InteractableHighlights.Highlights[object] = {
        Highlight = highlight;
        Connections = {};
    };

    -- Find and connect to ProximityPrompt
    local function trySetupPrompt()
        local proximityPrompt = nil;

        for _, descendant in ipairs(object:GetDescendants()) do
            if descendant:IsA('ProximityPrompt') then
                proximityPrompt = descendant;
                break;
            end
        end

        if proximityPrompt then
            InteractableHighlights._SetupPromptConnections(
                object, highlight, proximityPrompt
            );
            return true;
        end

        return false;
    end

    -- Try immediately, or wait for prompt to be added
    if not trySetupPrompt() then
        local connection;
        connection = object.DescendantAdded:Connect(function(descendant)
            if descendant:IsA('ProximityPrompt') then
                if trySetupPrompt() then
                    connection:Disconnect();
                end
            end
        end)

        table.insert(
            InteractableHighlights.Highlights[object].Connections,
            connection
        );
    end
end

-- Private: Set up prompt show/hide connections
function InteractableHighlights._SetupPromptConnections(
    object: BasePart,
    highlight: Highlight,
    proximityPrompt: ProximityPrompt
)
    local connections = InteractableHighlights.Highlights[object]
        and InteractableHighlights.Highlights[object].Connections
        or {};

    -- Show highlight when prompt appears
    local shownConnection = proximityPrompt.PromptShown:Connect(function()
        local tween = TweenService:Create(
            highlight,
            TweenInfo.new(0.5),
            { FillTransparency = 0.75, OutlineTransparency = 0 }
        );
        tween:Play();
    end)

    -- Hide highlight when prompt hides
    local hiddenConnection = proximityPrompt.PromptHidden:Connect(function()
        local tween = TweenService:Create(
            highlight,
            TweenInfo.new(0.5),
            { FillTransparency = 1, OutlineTransparency = 1 }
        );
        tween:Play();
    end)

    table.insert(connections, shownConnection);
    table.insert(connections, hiddenConnection);

    InteractableHighlights.Highlights[object] = {
        Highlight = highlight;
        Connections = connections;
    };
end

-- Private: Cleanup interactable
function InteractableHighlights._UnregisterInteractable(object: Instance)
    local highlightData = InteractableHighlights.Highlights[object];
    if not highlightData then return end

    -- Destroy highlight
    if highlightData.Highlight then
        highlightData.Highlight:Destroy();
    end

    -- Disconnect all connections
    for _, connection in ipairs(highlightData.Connections) do
        connection:Disconnect();
    end

    InteractableHighlights.Highlights[object] = nil;
end

return InteractableHighlights;
```

## Complete Example: Notifications Interface

```lua
--[=[
    @interface Notifications
    @description: Displays notification messages to the player
]=]

local Notifications = {};

-- Config for receiving Global broadcasts
Notifications.config = {
    identifier = 'Notifications';
};

-- Services
local Players = game:GetService('Players');
local TweenService = game:GetService('TweenService');

-- State
Notifications.Queue = {};
Notifications.IsDisplaying = false;

-- UI References
local NotificationFrame = nil;
local NotificationLabel = nil;

-- Initialize
function Notifications.Initialize()
    Notifications._CreateUI();
end

-- Called via Global broadcast from server
function Notifications.DisplayNotification(
    message: string,
    notificationType: string,
    options: {}?
)
    options = options or {};

    -- Add to queue
    table.insert(Notifications.Queue, {
        message = message;
        type = notificationType;
        duration = options.duration or 3;
    });

    -- Start processing if not already
    if not Notifications.IsDisplaying then
        Notifications._ProcessQueue();
    end
end

-- Private: Create notification UI
function Notifications._CreateUI()
    local player = Players.LocalPlayer;
    local gui = player:WaitForChild('PlayerGui');

    -- Create ScreenGui
    local screenGui = Instance.new('ScreenGui');
    screenGui.Name = 'NotificationGui';
    screenGui.ResetOnSpawn = false;
    screenGui.Parent = gui;

    -- Create notification frame
    NotificationFrame = Instance.new('Frame');
    NotificationFrame.Name = 'NotificationFrame';
    NotificationFrame.Size = UDim2.fromScale(0.4, 0.1);
    NotificationFrame.Position = UDim2.fromScale(0.5, -0.15);
    NotificationFrame.AnchorPoint = Vector2.new(0.5, 0);
    NotificationFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30);
    NotificationFrame.BackgroundTransparency = 0.2;
    NotificationFrame.Parent = screenGui;

    -- Add corner radius
    local corner = Instance.new('UICorner');
    corner.CornerRadius = UDim.new(0, 8);
    corner.Parent = NotificationFrame;

    -- Create label
    NotificationLabel = Instance.new('TextLabel');
    NotificationLabel.Name = 'Message';
    NotificationLabel.Size = UDim2.fromScale(0.9, 0.8);
    NotificationLabel.Position = UDim2.fromScale(0.5, 0.5);
    NotificationLabel.AnchorPoint = Vector2.new(0.5, 0.5);
    NotificationLabel.BackgroundTransparency = 1;
    NotificationLabel.TextColor3 = Color3.fromRGB(255, 255, 255);
    NotificationLabel.TextScaled = true;
    NotificationLabel.Font = Enum.Font.GothamBold;
    NotificationLabel.Parent = NotificationFrame;
end

-- Private: Process notification queue
function Notifications._ProcessQueue()
    if #Notifications.Queue == 0 then
        Notifications.IsDisplaying = false;
        return;
    end

    Notifications.IsDisplaying = true;
    local notification = table.remove(Notifications.Queue, 1);

    -- Set content
    NotificationLabel.Text = notification.message;

    -- Set color based on type
    local colors = {
        Success = Color3.fromRGB(50, 200, 100);
        Failure = Color3.fromRGB(200, 50, 50);
        Info = Color3.fromRGB(50, 150, 200);
        Warning = Color3.fromRGB(200, 150, 50);
    };

    NotificationFrame.BackgroundColor3 =
        colors[notification.type] or colors.Info;

    -- Animate in
    local slideIn = TweenService:Create(
        NotificationFrame,
        TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { Position = UDim2.fromScale(0.5, 0.05) }
    );
    slideIn:Play();
    slideIn.Completed:Wait();

    -- Wait for duration
    task.wait(notification.duration);

    -- Animate out
    local slideOut = TweenService:Create(
        NotificationFrame,
        TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
        { Position = UDim2.fromScale(0.5, -0.15) }
    );
    slideOut:Play();
    slideOut.Completed:Wait();

    -- Process next
    Notifications._ProcessQueue();
end

return Notifications;
```

## Complete Example: Sound Effects Interface

```lua
--[=[
    @interface SFX
    @description: Manages sound effect playback
]=]

local SFX = {};

-- Config for receiving Global broadcasts
SFX.config = {
    identifier = 'SFX';
};

-- Services
local SoundService = game:GetService('SoundService');
local ReplicatedStorage = game:GetService('ReplicatedStorage');

-- State
SFX.Sounds = {};
SFX.Volume = 1;

-- Initialize
function SFX.Initialize()
    -- Load sound assets
    local soundsFolder = ReplicatedStorage:FindFirstChild('Sounds');
    if soundsFolder then
        for _, sound in soundsFolder:GetChildren() do
            if sound:IsA('Sound') then
                SFX.Sounds[sound.Name] = sound:Clone();
                SFX.Sounds[sound.Name].Parent = SoundService;
            end
        end
    end
end

-- Called via Global broadcast
function SFX.Play(soundName: string, options: {}?)
    options = options or {};

    local sound = SFX.Sounds[soundName];
    if not sound then
        warn('[SFX] Sound not found:', soundName);
        return;
    end

    -- Clone for overlapping plays
    local playSound = sound:Clone();
    playSound.Volume = (options.volume or 1) * SFX.Volume;
    playSound.PlaybackSpeed = options.speed or 1;
    playSound.Parent = SoundService;

    playSound:Play();

    -- Cleanup after playing
    playSound.Ended:Connect(function()
        playSound:Destroy();
    end)
end

-- Called via Global broadcast
function SFX.PlayAtPosition(soundName: string, position: Vector3, options: {}?)
    options = options or {};

    local sound = SFX.Sounds[soundName];
    if not sound then return end

    -- Create part for 3D sound
    local part = Instance.new('Part');
    part.Anchored = true;
    part.CanCollide = false;
    part.Transparency = 1;
    part.Position = position;
    part.Parent = workspace;

    local playSound = sound:Clone();
    playSound.Volume = (options.volume or 1) * SFX.Volume;
    playSound.RollOffMode = Enum.RollOffMode.Linear;
    playSound.RollOffMaxDistance = options.maxDistance or 100;
    playSound.Parent = part;

    playSound:Play();

    playSound.Ended:Connect(function()
        part:Destroy();
    end)
end

-- Public: Set master volume
function SFX.SetVolume(volume: number)
    SFX.Volume = math.clamp(volume, 0, 1);
end

return SFX;
```

## Best Practices

1. **Keep interfaces focused** - One visual/interaction system per interface
2. **Clean up resources** - Disconnect connections, destroy instances
3. **Handle missing UI gracefully** - UI might not exist immediately
4. **Use CollectionService for world objects** - Tag-based detection
5. **Queue visual effects** - Prevent overwhelming the player
6. **Consider performance** - Interfaces run every frame for some effects
7. **Don't store game state** - That belongs in Controllers/Components
