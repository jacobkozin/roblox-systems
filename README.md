# Roblox Systems

Server systems for Roblox, written in Luau. Each one is a drop-in ModuleScript, with config at the top and comments explaining the decisions.

The main piece is the **SafeSave Kit**: DataService and ShopService together give a game crash-safe saving and correct Robux purchase handling.

| Module | What it does |
|---|---|
| [DataService](src/DataService.luau) | Saves player data with session locking (no duplication through rejoining), fills in new fields on old saves, retries with backoff, autosaves, and waits for every save on shutdown. If another server takes over a player's data, it stops writing instead of overwriting newer data. |
| [ShopService](src/ShopService.luau) | Server-validated coin shop with rate limiting. Developer product receipts are idempotent and saved before the purchase is confirmed. Game pass checks are cached. |
| [RoundService](src/RoundService.luau) | Optional. Waiting → Intermission → InRound → Ending loop with random maps, spawn points, alive tracking, early finish, rewards, and cleanup that still runs if a round errors. |

- **Install:** [docs/INSTALL.md](docs/INSTALL.md) (copy and paste, or Rojo)
- **Test it in Studio:** [docs/TESTING.md](docs/TESTING.md)
- **Changes:** [CHANGELOG.md](CHANGELOG.md)

## Quick start

1. In Studio, turn on **Game Settings → Security → Enable Studio Access to API Services** (DataStores need it).
2. In `ServerScriptService`, add ModuleScripts named `DataService` and `ShopService` and paste each file in. Add `RoundService` too if you want the round loop.
3. Add a **Script** next to them and paste [Main.server.luau](src/Main.server.luau).
4. Edit the `CONFIG` / `CATALOG` / `DEV_PRODUCTS` / `GAME_PASSES` tables at the top of each module.

Full steps, including Rojo, are in [docs/INSTALL.md](docs/INSTALL.md).

## Using it from other scripts

```lua
-- Server
local DataService = require(game.ServerScriptService.DataService)
DataService.Loaded:Connect(function(player, data)
	print(player.Name, "has", data.Coins, "coins")
end)
DataService.Increment(player, "Coins", 50)

local ShopService = require(game.ServerScriptService.ShopService)
if ShopService.HasPass(player, "VIP") then
	-- ...
end
```

```lua
-- Client
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = ReplicatedStorage:WaitForChild("ShopRemotes").Purchase:InvokeServer("SpeedCoil")
print(result.ok, result.reason)

local coins = game.Players.LocalPlayer:GetAttribute("Coins")
local state = ReplicatedStorage:WaitForChild("RoundState")
state:GetAttributeChangedSignal("Timer"):Connect(function()
	print(state:GetAttribute("State"), state:GetAttribute("Timer"))
end)
```

## Design notes

- **Why session locking?** Without it, a player who rejoins quickly can load stale data on the new server while the old one is still saving. That's how item duplication happens. The lock is refreshed on every autosave, and a lock that hasn't been refreshed in 6 minutes is treated as abandoned. If a server finds that another server has taken the lock, it refuses to write and kicks the player, so the newer session's data is never overwritten.
- **Why save before PurchaseGranted?** If the server crashes after confirming but before saving, the player paid Robux and lost the item. Here the receipt ID and the reward save together, and a receipt is only confirmed once that save succeeds. Retries check the receipt list first, so a purchase can't be granted twice.
- **Why not a BindableEvent for `Loaded`?** BindableEvents copy tables. Listeners would get a copy of the data, and changes to it would silently never save. `Loaded` is a small signal that passes the live table.
- **Why attributes instead of RemoteEvents for state?** They replicate automatically and late joiners get the current value for free.

## Testing status

- All files parse as valid Luau and are formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.6.0 (`stylua --check src`).
- Not yet run through the Studio checklist in [docs/TESTING.md](docs/TESTING.md). Tick it off there once it has been.

## License and support

MIT, see [LICENSE](LICENSE). You can use this in commercial games for free.

Paid installation into an existing game, migration from an old save system, and custom changes are available. Contact: jacob.kozin1@gmail.com, Discord `jacity`, or [jacobkozin.github.io](https://jacobkozin.github.io).
