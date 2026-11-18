# Installing the SafeSave Kit

The kit is DataService (saving) and ShopService (coin shop, developer products, game passes). RoundService is optional and separate.

## Requirements

- A published place (DataStores need a universe ID). For testing in Studio, turn on **Game Settings → Security → Enable Studio Access to API Services**.
- No third-party dependencies. Only Roblox services: DataStoreService, MarketplaceService, Players, ReplicatedStorage (and ServerStorage for RoundService).

## Folder layout

```
ServerScriptService
├─ DataService    (ModuleScript)  src/DataService.luau
├─ ShopService    (ModuleScript)  src/ShopService.luau   requires DataService
├─ RoundService   (ModuleScript)  src/RoundService.luau  optional, requires DataService
└─ Main           (Script)        src/Main.server.luau   starts everything

Created at runtime:
ReplicatedStorage.ShopRemotes.Purchase   (RemoteFunction)
ReplicatedStorage.RoundState             (Configuration with State/Timer/Map attributes, only with RoundService)
Player attributes for every top-level number in the save (e.g. Coins)
```

The modules find each other through `script.Parent`, so keep them in the same folder. They can live in a subfolder of ServerScriptService as long as they stay together.

## Option A: copy and paste (no tools)

1. In `ServerScriptService`, insert a **ModuleScript**, rename it `DataService`, and paste in `src/DataService.luau`.
2. Do the same for `ShopService` (and `RoundService` if you want it).
3. Insert a **Script** named `Main` in the same place and paste in `src/Main.server.luau`.
4. Configure (next section), then run the checklist in [TESTING.md](TESTING.md).

## Option B: Rojo

`default.project.json` maps `src/` to `ServerScriptService.Systems`.

```
rojo serve
```

Then connect from the Rojo Studio plugin. `Main.server.luau` becomes a Script named `Main`, and the other files become ModuleScripts.

## Configuration

**DataService** (`CONFIG` at the top):

| Setting | Default | Notes |
|---|---|---|
| `StoreName` | `"PlayerData_v1"` | Changing it starts everyone with fresh data. Only change it on purpose. |
| `AutosaveInterval` | `120` | Seconds. Keep it at 60 or more to stay inside DataStore limits. |
| `MaxRetries` | `5` | For loads and saves. On the last load attempt, a lock held by another server is taken over. |
| `LockStaleAfter` | `360` | Seconds before a lock is treated as abandoned. Keep it above `AutosaveInterval`. |
| `ShutdownTimeout` | `25` | Seconds BindToClose waits for saves (Roblox allows 30). |
| `Template` | Coins, Inventory, ProcessedReceipts | Default data. New keys are added to old saves automatically. Keep `ProcessedReceipts` if you use ShopService. |

**ShopService**:

- `CATALOG`: coin-priced items, `ItemId = { Price = n }`. Bought items go into `data.Inventory[ItemId] = true`.
- `DEV_PRODUCTS`: `[productId] = function(player) ... return true end`. Return `true` only once the reward has been applied. Returning false or nil, or erroring, tells Roblox to retry later. Only change the player's data table in here. ShopService saves it before confirming the purchase.
- `GAME_PASSES`: `Name = passId`. Check with `ShopService.HasPass(player, "Name")`.

Only one script in the whole game may set `MarketplaceService.ProcessReceipt`. If the game already has one, merge its products into `DEV_PRODUCTS` and remove the old callback.

## Migrating from an existing save system

The kit does not read old DataStores on its own. If the game already has player data, a small migration step is needed: on first load, read the old key and copy the fields into the new template. That is part of the paid installation service, or you can add it in `load()` yourself.

## Licensing

MIT (see `LICENSE`). Free to use and modify in commercial games. Keep the license notice in the files. Paid support covers installation, migration, and custom changes. The code itself is free.
