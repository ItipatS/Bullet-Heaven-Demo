# IGD Framework Documentation

Complete documentation for the IGD Studio game development framework for Roblox.

## Documentation Index

| Document | Description |
|----------|-------------|
| [00-overview.md](./00-overview.md) | Architecture overview, core concepts, data flow |
| [01-getting-started.md](./01-getting-started.md) | Setup, initialization, first component/controller |
| [02-components.md](./02-components.md) | Server-side components (per-player logic) |
| [03-controllers.md](./03-controllers.md) | Client-side controllers (UI and local state) |
| [04-systems.md](./04-systems.md) | Global server systems (game-wide logic) |
| [05-interfaces.md](./05-interfaces.md) | Global client interfaces (world interaction) |
| [06-replication.md](./06-replication.md) | Client-server communication |
| [07-data-persistence.md](./07-data-persistence.md) | Player data saving with ProfileService |
| [08-ui-system.md](./08-ui-system.md) | UI state management and registries |
| [09-utilities.md](./09-utilities.md) | Utility functions reference |
| [10-examples.md](./10-examples.md) | Complete implementation examples |

## Quick Start

1. Read [00-overview.md](./00-overview.md) to understand the architecture
2. Follow [01-getting-started.md](./01-getting-started.md) to set up your project
3. Create your first component using [02-components.md](./02-components.md)
4. Create the matching controller using [03-controllers.md](./03-controllers.md)
5. Reference [10-examples.md](./10-examples.md) for complete implementations

## Core Concepts

### Component-Controller Pattern

```
SERVER                              CLIENT
┌─────────────┐                    ┌─────────────┐
│  Component  │ ◄── Replication ──►│ Controller  │
│  (Currency) │                    │  (Currency) │
└─────────────┘                    └─────────────┘
      │                                   │
      ▼                                   ▼
  Game Logic                         UI Updates
  Data Persistence                   Local State
```

### Module Types

| Type | Location | Scope | Purpose |
|------|----------|-------|---------|
| Component | Server/Components/ | Per-player | Game logic, data |
| Controller | Client/Controllers/ | Per-player | UI, client state |
| System | Server/Systems/ | Global | World state, broadcasts |
| Interface | Client/Interfaces/ | Global | Effects, world interaction |

### Bridges

| Bridge | Direction | Use Case |
|--------|-----------|----------|
| Session | Component ↔ Controller | Player-specific data |
| Global | System ↔ Interface | Broadcasts, world state |
| Loader | Server → Client → Server | Initial data sync |

## File Structure

```
src/
├── Client/
│   ├── Controllers/    # Player controllers
│   ├── Interfaces/     # Global client modules
│   └── init.local.luau
├── Server/
│   ├── Components/     # Player components
│   ├── Systems/        # Global server modules
│   └── init.legacy.luau
└── Shared/
    └── Framework/
        ├── Main/       # Component/Controller base classes
        ├── Data/       # ProfileService wrapper
        ├── UI/         # UI utilities
        ├── Utils/      # Helper functions
        └── Dependencies/
```

## Common Patterns

### Creating a Component

```lua
local MyComponent = Composer.Extend({
    identifier = 'MyComponent';
    dependencies = {};
    replication = { enabled = true; authorized = {} };
    state = {};
    replica_dependencies = {};
});

function MyComponent:RunOnRegistrationCompleted()
    -- Initialize
end

return MyComponent;
```

### Replicating to Client

```lua
Replication.FireToClient('Session', self.player, {
    Identifier = 'MyController';
    Call = 'UpdateValue';
    Args = { newValue };
});
```

### Client Requesting Server

```lua
local result = Replication.InvokeServer('Session', {
    Identifier = 'MyComponent';
    Call = 'DoAction';  -- Must be authorized
    Args = { params };
});
```

## For AI Agents

This documentation is designed to train AI agents to build games using the IGD Framework. Key points:

1. **Always match identifiers** - Component and Controller must have same identifier
2. **Authorize client methods** - Only methods in `authorized` array can be called from client
3. **Validate all client input** - Never trust data from client
4. **Use dependencies** - Access other components via `self.dependencies`
5. **Use signals** - Fire signals for cross-component communication
6. **Keep data/state separate** - `self.data` persists, `self.state` is runtime only
7. **Replicate changes** - Always notify client after server state changes

## Framework Version

- Package: `administrator/igdframework@0.1.0`
- Language: Luau (Roblox)
- Data: ProfileService
- Networking: BridgeNet2
