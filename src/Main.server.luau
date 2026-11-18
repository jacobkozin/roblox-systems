-- Bootstraps the services. Place this Script in ServerScriptService,
-- next to the DataService, ShopService and RoundService ModuleScripts.

require(script.Parent.DataService)
require(script.Parent.ShopService)
require(script.Parent.RoundService).Start()
