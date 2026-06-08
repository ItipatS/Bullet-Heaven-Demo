# Replication System

The replication system handles all client-server communication using BridgeNet2 for efficient networking.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                       BRIDGES                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Session Bridge                                              │
│  ├── Components ◄──► Controllers (per-player)               │
│  └── Targeted communication to specific player              │
│                                                              │
│  Global Bridge                                               │
│  ├── Systems ◄──► Interfaces (broadcast)                    │
│  └── Broadcast to all players or specific groups            │
│                                                              │
│  Loader Bridge                                               │
│  ├── Initial data sync on player join                       │
│  └── Handshake confirmation                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Bridge Types

### Session Bridge
- **Purpose**: Per-player Component ↔ Controller communication
- **Direction**: Bidirectional
- **Use case**: Player-specific data like currency, inventory, stats

### Global Bridge
- **Purpose**: System ↔ Interface broadcast communication
- **Direction**: Bidirectional
- **Use case**: Game-wide events like day/night, announcements, world state

### Loader Bridge
- **Purpose**: Initial player data synchronization
- **Direction**: Server → Client → Server (handshake)
- **Use case**: Sending player's saved data on join, confirming ready state

## Replication Registry

Located at `Shared/Framework/ReplicationRegistry.luau`:

```lua
local bridgenet = require(script.Parent.Dependencies.BridgeNet2);

return {
    Session = bridgenet.ReferenceBridge('Session');
    Global = bridgenet.ReferenceBridge('Global');
    Loader = bridgenet.ReferenceBridge('Loader');
};
```

## Payload Structure

All replication uses a standard payload format:

```lua
{
    Identifier = string;  -- Component/Controller/System/Interface name
    Call = string;        -- Method name to invoke
    Args = { any };       -- Arguments to pass
}
```

## Server → Client Communication

### Using Replication Utility

Import the utility:

```lua
local Replication = require(Framework.Utils.Replication);
```

### FireToClient (Session Bridge)

Send to a specific player:

```lua
-- In a Component
function MyComponent:UpdateState()
    Replication.FireToClient('Session', self.player, {
        Identifier = 'MyController';  -- Target controller
        Call = 'OnStateUpdated';      -- Method to call
        Args = { self.state };        -- Arguments
    });
end
```

### FireAllClients (Global Bridge)

Broadcast to all players:

```lua
-- In a System
function MySystem.BroadcastEvent(eventData)
    Replication.FireAllClients('Global', {
        Identifier = 'MyInterface';
        Call = 'OnEvent';
        Args = { eventData };
    });
end
```

### FireAllClients (Session Bridge)

Send same message to all players' controllers:

```lua
-- Notify all players' notification controllers
Replication.FireAllClients('Session', {
    Identifier = 'Notifications';
    Call = 'DisplayNotification';
    Args = { 'Server announcement!', 'Info' };
});
```

## Client → Server Communication

### FireToServer (Session Bridge)

Send to player's component:

```lua
-- In a Controller
local Replication = require(Framework.Utils.Replication);

function MyController:RequestAction(data)
    Replication.FireToServer('Session', {
        Identifier = 'MyComponent';   -- Target component
        Call = 'HandleAction';        -- Must be authorized!
        Args = { data };
    });
end
```

### FireToServer (Global Bridge)

Send to a system:

```lua
-- In an Interface
function MyInterface.NotifySystem(data)
    Replication.FireToServer('Global', {
        Identifier = 'MySystem';
        Call = 'HandleNotification';  -- Must be authorized!
        Args = { data };
    });
end
```

### InvokeServer (Request/Response)

Wait for server response:

```lua
-- In a Controller
function MyController:FetchData()
    local result = Replication.InvokeServer('Session', {
        Identifier = 'MyComponent';
        Call = 'GetData';             -- Must be authorized!
        Args = {};
    });

    if result then
        self.state.data = result;
    end

    return result;
end
```

## Authorization System

The framework validates all client requests against authorized methods.

### Component Authorization

```lua
local MyComponent = Composer.Extend({
    identifier = 'MyComponent';
    dependencies = {};

    replication = {
        enabled = true;                           -- Enable client calls
        authorized = { 'Method1', 'Method2' };    -- Allowed methods
    };

    state = {};
    replica_dependencies = {};
});

-- This CAN be called from client
function MyComponent:Method1(arg)
    -- Validate arg!
    if type(arg) ~= 'string' then return end
    -- Process...
end

-- This CAN be called from client
function MyComponent:Method2()
    return self.state.publicData;
end

-- This CANNOT be called from client (not authorized)
function MyComponent:PrivateMethod()
    -- Only server can call this
end
```

### System Authorization

```lua
MySystem.config = {
    identifier = 'MySystem';
    replication = {
        enabled = true;
        authorized = { 'GetPublicState' };
    };
};

-- Authorized - client can call
function MySystem.GetPublicState()
    return MySystem.publicState;
end

-- Not authorized - only server
function MySystem._ProcessInternal()
    -- Server only
end
```

### Authorization Validation

The framework automatically validates:

1. **Bridge exists** - Session or Global must be valid
2. **Session exists** - Player must have active session
3. **Component/System exists** - Target must be loaded
4. **Replication enabled** - `config.replication.enabled = true`
5. **Method authorized** - Method name in `config.replication.authorized`
6. **Method exists** - Target has the method

If any check fails, the request is rejected with a warning.

## Initial Data Loading

### Server Side (Session.RegisterPlayer)

```lua
-- After loading player data and components
ReplicationRegistry.Loader:Fire(
    BridgeNet2.Players({player}),
    { replica = playerSession.data }  -- Send player's data
);
```

### Client Side (InternalReplicationHandler)

```lua
ReplicationRegistry.Loader:Connect(function(data)
    -- data.replica contains player's saved data

    -- Initialize controllers with replica
    for _, controllerModule in controllersDirectory:GetDescendants() do
        local controller = require(controllerModule);
        local instance = controller.new(player, data.replica);
        -- ...
    end

    -- Confirm ready
    ReplicationRegistry.Loader:Fire();
end)
```

### Server Confirmation

```lua
ReplicationRegistry.Loader:Connect(function(player)
    -- Client confirmed ready
    local session = Registry[player.UserId];
    Session.CompleteLoading(session);
end)
```

## Replication Flow Examples

### Example 1: Currency Update

```
[Server: CurrencyComponent]
         │
         │ EditCurrency('Coins', 'Add', 100)
         │
         ├─► self.data.Currencies.Coins += 100
         │
         ├─► Replication.FireToClient('Session', player, {
         │       Identifier = 'Currency',
         │       Call = 'UpdateCurrency',
         │       Args = {'Coins', 167}
         │   })
         │
         └───────────────────────────────────────►
                                                  │
                                    [Client: CurrencyController]
                                                  │
                                    UpdateCurrency('Coins', 167)
                                                  │
                                    self.state.currencies.Coins = 167
                                                  │
                                    Update UI display
```

### Example 2: Client Request

```
[Client: ShopController]
         │
         │ User clicks "Buy Item"
         │
         ├─► Replication.FireToServer('Session', {
         │       Identifier = 'Shop',
         │       Call = 'PurchaseItem',
         │       Args = {'sword_01'}
         │   })
         │
         └───────────────────────────────────────►
                                                  │
                      [Server: InternalReplicationHandler]
                                                  │
                      Check authorization ────────┤
                                                  │
                      [Server: ShopComponent]
                                                  │
                      PurchaseItem('sword_01')
                                                  │
                      Validate, deduct currency,
                      add to inventory
                                                  │
                      Fire updates to controllers
```

### Example 3: Global Broadcast

```
[Server: DayNightSystem]
         │
         │ Night started
         │
         ├─► signals.NightStarted:Fire()
         │
         ├─► Replication.FireAllClients('Global', {
         │       Identifier = 'Atmosphere',
         │       Call = 'OnNightStarted',
         │       Args = {}
         │   })
         │
         └───────────────────────────────────────►
                                                  │
                              [All Clients: AtmosphereInterface]
                                                  │
                              OnNightStarted()
                                                  │
                              Dim lighting,
                              enable fog,
                              play ambient sounds
```

## Replication Utility API

### Server Methods

```lua
-- Send to specific player (Session bridge)
Replication.FireToClient(
    bridge: string,      -- 'Session' or 'Global'
    player: Player,
    payload: {
        Identifier: string,
        Call: string,
        Args: { any }
    }
)

-- Send to all players
Replication.FireAllClients(
    bridge: string,      -- 'Session' or 'Global'
    payload: {
        Identifier: string,
        Call: string,
        Args: { any }
    }
)
```

### Client Methods

```lua
-- Send to server (no response)
Replication.FireToServer(
    bridge: string,      -- 'Session' or 'Global'
    payload: {
        Identifier: string,
        Call: string,
        Args: { any }
    }
)

-- Send to server and wait for response
local result = Replication.InvokeServer(
    bridge: string,      -- 'Session' or 'Global'
    payload: {
        Identifier: string,
        Call: string,
        Args: { any }
    }
) --> returns server method's return value
```

## Best Practices

1. **Always validate client input** - Never trust data from client
2. **Minimize payload size** - Only send what's needed
3. **Use appropriate bridge** - Session for player-specific, Global for broadcasts
4. **Authorize carefully** - Only expose methods that are safe to call
5. **Handle nil gracefully** - Client may disconnect during invoke
6. **Batch updates when possible** - Reduce network calls
7. **Use Fire for fire-and-forget** - Use Invoke only when response needed
8. **Log authorization failures** - Framework logs these, review them
