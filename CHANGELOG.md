# Changelog

## 1.1.0 (2026-11-18)

Fixes from a code review:

- **DataService:** a save cancelled because another server owned the lock used to count as a success. `SaveNow` could return true without writing, which let ShopService confirm a Robux purchase that was never saved. Saves now return true only when data is actually written. On a lost lock, the server stops saving and kicks the player.
- **DataService:** an autosave still in flight when a player left could finish after the final save and lock their data again, which delayed their next join. Autosaves for a session that has ended are now cancelled inside the write.
- **DataService:** a quick rejoin to the same server now waits for that player's final save before loading.
- **DataService:** `Loaded` was a BindableEvent, which copies tables, so listeners got a copy of the data and their changes never saved. It is now a small signal that passes the live table. Use `DataService.Loaded:Connect(fn)`. `.Event` is gone.
- **DataService:** settings moved into one `CONFIG` table. No pointless wait after the last failed load attempt.
- **ShopService:** a receipt already recorded in memory, but whose save had failed, used to be confirmed without saving again. It is now saved again first.
- **ShopService:** handlers in `DEV_PRODUCTS` now have to return `true`. Before, a handler that silently did nothing (e.g. Increment on a missing key) still counted as granted.
- **ShopService:** the same receipt can't be processed twice at the same time, and an error inside ProcessReceipt returns NotYetProcessed.
- **RoundService:** connections are disconnected even when a round errors. Non-Part children of `Spawns` are ignored. Players whose character is removed without dying no longer count as alive.
- **Main:** RoundService is optional.
- Added LICENSE (MIT), install guide, Studio test checklist, Rojo project file, and StyLua config.

## 1.0.0 (2026-11-18)

- First version: DataService, ShopService, RoundService.
