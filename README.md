# Roblox Systems

Production-style server systems for Roblox, written in Luau. Each one is a drop-in ModuleScript with comments explaining the decisions.

| Module | What it does |
|---|---|
| [DataService](src/DataService.luau) | Saves player data with session locking (no duplication through rejoining), reconciles old saves, retries with backoff, autosaves, and waits for every save on shutdown. |
| [ShopService](src/ShopService.luau) | Server-validated coin shop with rate limiting. Developer product receipts are idempotent and saved before the purchase is confirmed. Cached game pass checks. |
| [RoundService](src/RoundService.luau) | Waiting → Intermission → InRound → Ending loop with random maps, spawn points, alive tracking, early finish, rewards, and clean teardown. |

## Setup

1. In Studio, enable **Game Settings → Security → Enable Studio Access to API Services** (needed for DataStores).
2. In `ServerScriptService`, add three **ModuleScripts** named `DataService`, `ShopService`, `RoundService` and paste each file in.
3. Add a **Script** in the same place and paste [Main.server.luau](src/Main.server.luau).
4. Make `ServerStorage.Maps`, and add a map Model containing a `Spawns` folder of Parts.
5. Put your own developer product and game pass IDs in `ShopService`.

## Reading state from the client

```lua
local state = game.ReplicatedStorage:WaitForChild("RoundState")
state:GetAttributeChangedSignal("Timer"):Connect(function()
	print(state:GetAttribute("State"), state:GetAttribute("Timer"))
end)

local coins = game.Players.LocalPlayer:GetAttribute("Coins")
```

## Design notes

- **Why session locking?** Without it, a player who rejoins quickly can load stale data on the new server while the old one is still saving. That's how item duplication happens. The lock is refreshed on every autosave, and a lock that hasn't been refreshed in 6 minutes is treated as abandoned.
- **Why save before PurchaseGranted?** If the server crashes after confirming but before saving, the player paid Robux and lost the item. Here the receipt ID and the reward save together, so retries are safe.
- **Why attributes instead of RemoteEvents for state?** They replicate automatically and late joiners get the current value for free.
