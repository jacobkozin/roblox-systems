-- Bootstraps the services. Place this Script in ServerScriptService,
-- next to the DataService and ShopService ModuleScripts.
-- RoundService is optional: it only starts if that ModuleScript is present.

require(script.Parent.DataService)
require(script.Parent.ShopService)

local roundModule = script.Parent:FindFirstChild("RoundService")
if roundModule then
	require(roundModule).Start()
end
