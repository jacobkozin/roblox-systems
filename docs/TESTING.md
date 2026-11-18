# Studio test checklist

Run this in a **test place** (not a live game), with API Services enabled. Use a throwaway `StoreName` such as `"PlayerData_test1"` so test data never mixes with real data. Watch the Output window the whole time.

Last run: _not yet run_ (fill in the date and Studio version when you do)

## 1. Loading and saving (Play solo)

- [ ] Press Play. No errors in Output. The player has a `Coins` attribute of `0` (Properties of the Player object, Attributes section).
- [ ] In the server command bar: `require(game.ServerScriptService.DataService).Increment(game.Players:GetPlayers()[1], "Coins", 500)`. The attribute changes to 500.
- [ ] Stop and press Play again. `Coins` is still 500.
- [ ] Add a new key to `Template` (e.g. `Gems = 0`), Play again. `Gems` appears and `Coins` is still 500 (reconcile works).

## 2. Shutdown save

- [ ] Add 100 coins, then stop **immediately** (under 2 seconds). Play again: the 100 coins are there (BindToClose waited for the save).

## 3. Coin shop (Play solo, client command bar or a LocalScript; wait a second between calls or you will get TooFast)

```lua
local remote = game.ReplicatedStorage:WaitForChild("ShopRemotes").Purchase
print(remote:InvokeServer("SpeedCoil"))
```

- [ ] With 500 coins: `ok = true`, coins drop by 250, and `Inventory.SpeedCoil` is true on the server.
- [ ] Buy again: `reason = "AlreadyOwned"`.
- [ ] With too few coins: `reason = "NotEnoughCoins"`, coins unchanged.
- [ ] `InvokeServer(123)` gives `BadRequest`. `InvokeServer("Nope")` gives `UnknownItem`.
- [ ] Two calls in the same frame: the second gives `TooFast`.

## 4. Developer products (Studio test purchases are free)

- [ ] Put a real developer product ID from your experience in `DEV_PRODUCTS`. Prompt it from a LocalScript: `game:GetService("MarketplaceService"):PromptProductPurchase(game.Players.LocalPlayer, ID)`.
- [ ] After buying: coins go up once, the receipt's PurchaseId is in `ProcessedReceipts`, and Output shows no warnings.
- [ ] Temporarily make the handler `return false`. Buying shows `grant failed` in Output and no coins are added. Put it back.

## 5. Session lock (needs a published place, two clients)

- [ ] Publish. Join from client A, earn coins, leave and rejoin within a few seconds. Data is the latest (no rollback).
- [ ] Optional: join server 1, then use a second device to join a different server of the same place with the same account. Server 2's load waits on the lock and then takes over. Server 1 kicks the player with "Your data was loaded in another server" on its next save and doesn't overwrite.

## 6. Game passes

- [ ] Set a real pass ID in `GAME_PASSES`. `ShopService.HasPass(player, "VIP")` returns false, then true right after a Studio test purchase of the pass.

## 7. RoundService (only if installed)

- [ ] Add `ServerStorage.Maps.TestMap` (a Model) with a `Spawns` folder holding two Parts. Set `MinPlayers = 1` for solo testing.
- [ ] Play: the state goes Waiting → Intermission → InRound, and you're moved to a spawn.
- [ ] Reset your character: the round ends early, state goes to Ending, and the map is removed.
- [ ] Survive a full round: you get `WinReward` coins.
- [ ] A map with no Parts in `Spawns` shows a warning and the loop carries on.

## Known limits

- DataStore budgets: very large servers with short autosave intervals can hit write limits. Keep `AutosaveInterval` at 60 or more.
- Session lock takeover on the last load attempt (about 20 seconds of waiting) trades a short wait for never locking a player out. Anything the old server hadn't saved yet is lost in that case, and it can't overwrite the new session.
- No built-in migration from other save systems.
