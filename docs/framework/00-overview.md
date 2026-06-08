# IGD Framework Overview

## What is IGD Framework?

IGD Framework is a Roblox game development framework built in Luau that provides a structured, component-based architecture for building games. It handles the complexities of client-server communication, player data persistence, and modular game logic organization.

## Core Architecture

The framework follows a **Component-Controller** pattern inspired by ECS (Entity-Component-System) architectures:

```
┌─────────────────────────────────────────────────────────────────┐
│                         SERVER                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │  Component  │    │  Component  │    │   System    │         │
│  │  (Currency) │    │ (Inventory) │    │   (Quota)   │         │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘         │
│         │                  │                  │                 │
│         └────────────┬─────┴──────────────────┘                 │
│                      │                                          │
│              ┌───────▼───────┐                                  │
│              │    Session    │  ◄── Per-player state container  │
│              │   Registry    │                                  │
│              └───────┬───────┘                                  │
└──────────────────────┼──────────────────────────────────────────┘
                       │
            ┌──────────▼──────────┐
            │   BridgeNet2        │  ◄── Network replication
            │   (Session/Global)  │
            └──────────┬──────────┘
                       │
┌──────────────────────┼──────────────────────────────────────────┐
│                      │           CLIENT                          │
│              ┌───────▼───────┐                                  │
│              │    Loader     │  ◄── Initial data sync           │
│              └───────┬───────┘                                  │
│                      │                                          │
│         ┌────────────┴─────┬──────────────────┐                 │
│         │                  │                  │                 │
│  ┌──────▼──────┐    ┌──────▼──────┐    ┌──────▼──────┐         │
│  │ Controller  │    │ Controller  │    │  Interface  │         │
│  │ (Currency)  │    │  (Hotbar)   │    │ (Highlights)│         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

## Key Concepts

### Components (Server)
- **Per-player** server-side modules
- Manage player-specific game logic and state
- Have access to player data and can modify it
- Replicate changes to corresponding Controllers on the client
- Examples: Currency, Inventory, Progression, Quests

### Controllers (Client)
- **Per-player** client-side modules (mirror Components)
- Handle UI updates and local state
- Receive replicated data from server Components
- Can send authorized requests back to Components
- Examples: CurrencyController, HotbarController, QuestController

### Systems (Server)
- **Global** server-side modules
- Affect all players or the game world
- Run independently of player sessions
- Examples: DayNightCycle, Quota, Weather, Economy

### Interfaces (Client)
- **Global** client-side modules
- Handle world interaction and visual effects
- Respond to global broadcasts from Systems
- Examples: InteractableHighlights, Notifications, WorldEffects

## Data Flow

### Player Join Sequence

```
1. Player joins game
   │
2. CharacterAppearanceLoaded fires
   │
3. Session.RegisterPlayer() called
   │
4. ProfileService loads player data from DataStore
   │
5. All Components instantiated with player + data
   │
6. Components compiled (dependencies injected)
   │
7. Session stored in Registry[UserId]
   │
8. ReplicationRegistry.Loader fires to client with replica data
   │
9. Client receives data, instantiates all Controllers
   │
10. Controllers compiled (dependencies injected)
    │
11. Client fires Loader back to confirm ready
    │
12. Server calls Session.CompleteLoading()
    │
13. All Components' Register() method called
    │
14. Client loads Interfaces
    │
15. Game ready for player
```

### Replication Flow

```
Server Component                          Client Controller
      │                                          │
      │  EditCurrency('Coins', 'Add', 100)      │
      │                                          │
      ├──► Update self.data.Currencies          │
      │                                          │
      ├──► Update self.replica.Currencies       │
      │                                          │
      ├──► Replication.FireToClient('Session',  │
      │        player, {                         │
      │          Identifier = 'Currency',        │
      │          Call = 'UpdateCurrency',        │
      │          Args = {'Coins', 167}           │
      │        })                                │
      │                                          │
      │    ──────────────────────────────────►   │
      │                                          │
      │                      UpdateCurrency('Coins', 167)
      │                                          │
      │                      Update self.state.currencies
      │                                          │
      │                      Update UI display
      │                                          │
```

## Directory Structure

```
src/
├── Client/
│   ├── Controllers/       # Client-side component mirrors
│   │   └── Currency.luau
│   ├── Interfaces/        # Global client systems
│   │   └── InteractableHighlights.luau
│   └── init.local.luau    # Client entry point
│
├── Server/
│   ├── Components/        # Per-player server logic
│   │   └── Currency.luau
│   ├── Systems/           # Global server logic
│   │   └── Quota.luau
│   └── init.legacy.luau   # Server entry point
│
└── Shared/
    └── Framework/
        ├── init.luau                    # Framework entry
        ├── Session.luau                 # Player session management
        ├── Registry.luau                # Active sessions store
        ├── ReplicationRegistry.luau     # Network bridges
        ├── InternalReplicationHandler.luau
        ├── Types.luau                   # Type definitions
        │
        ├── Main/
        │   ├── Component.luau           # Base Component class
        │   └── Controller.luau          # Base Controller class
        │
        ├── Data/
        │   ├── init.luau                # Data loading wrapper
        │   ├── Template.luau            # Player data schema
        │   ├── Settings.luau            # DataStore config
        │   └── ProfileService.luau      # DataStore service
        │
        ├── UI/
        │   ├── UIStateController.luau   # Frame management
        │   └── Registry/                # UI element references
        │
        ├── Utils/
        │   ├── Replication.luau         # Network utilities
        │   ├── FormatUtils.luau         # Number/string formatting
        │   └── Tweens.luau              # Animation utilities
        │
        └── Dependencies/
            ├── BridgeNet2/              # Networking library
            └── signal.luau              # Event system
```

## Dependencies

### External (via Wally)
- `camerashaker` - Camera shake effects
- `zoneplus` - Zone detection system
- `simplepath` - Pathfinding utilities

### Internal
- **BridgeNet2** - High-performance networking
- **ProfileService** - DataStore wrapper
- **Signal** - Custom event/signal system
- **BasicState** - State container

## Framework Philosophy

1. **Separation of Concerns**: Server handles authoritative game logic; client handles presentation
2. **Type Safety**: Extensive use of Luau type annotations
3. **Error Resilience**: Comprehensive pcall wrapping and error logging
4. **Modular Design**: Easy to add/remove components without affecting others
5. **Automatic Lifecycle**: Framework handles initialization, compilation, and cleanup
6. **Secure Replication**: Authorization system prevents unauthorized client calls
