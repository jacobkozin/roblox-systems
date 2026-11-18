--[[
	ShopService
	Server-authoritative shop with correct developer product handling.

	- The client only *asks* to buy. The server checks the item exists, the
	  player can afford it and doesn't already own it, then charges them.
	- Purchase requests are rate limited per player.
	- ProcessReceipt is idempotent: every PurchaseId is recorded and saved
	  BEFORE Roblox is told the purchase was granted, so a crash can never
	  charge someone without giving them the item, or give it twice.
	- Game pass ownership is cached and updates the moment a pass is bought.

	Client usage:
		local result = ReplicatedStorage.ShopRemotes.Purchase:InvokeServer("SpeedCoil")
		-- result = { ok = true } or { ok = false, reason = "NotEnoughCoins" }
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)

-- Config -----------------------------------------------------------------

local CATALOG = {
	SpeedCoil = { Price = 250 },
	GravityCoil = { Price = 400 },
	Sword = { Price = 600 },
}

-- Replace the IDs with your own developer product IDs.
local DEV_PRODUCTS: { [number]: (Player) -> () } = {
	[1111111111] = function(player)
		DataService.Increment(player, "Coins", 1000)
	end,
	[2222222222] = function(player)
		DataService.Increment(player, "Coins", 5000)
	end,
}

-- Replace with your own game pass IDs.
local GAME_PASSES = {
	VIP = 3333333333,
	DoubleCoins = 4444444444,
}

local REQUEST_COOLDOWN = 0.5 -- seconds between purchase requests per player
local RECEIPT_HISTORY = 100 -- how many recent PurchaseIds to remember per player

-- Remotes ----------------------------------------------------------------

local remotes = Instance.new("Folder")
remotes.Name = "ShopRemotes"
local purchaseRemote = Instance.new("RemoteFunction")
purchaseRemote.Name = "Purchase"
purchaseRemote.Parent = remotes
remotes.Parent = ReplicatedStorage

local ShopService = {}
local lastRequest: { [Player]: number } = {}
local passCache: { [Player]: { [number]: boolean } } = {}

-- Coin shop --------------------------------------------------------------

local function purchase(player: Player, itemId: unknown)
	local now = os.clock()
	if now - (lastRequest[player] or 0) < REQUEST_COOLDOWN then
		return { ok = false, reason = "TooFast" }
	end
	lastRequest[player] = now

	-- Never trust the client: validate the type and that the item exists.
	if type(itemId) ~= "string" then
		return { ok = false, reason = "BadRequest" }
	end
	local item = CATALOG[itemId]
	if not item then
		return { ok = false, reason = "UnknownItem" }
	end

	local data = DataService.Get(player)
	if not data then
		return { ok = false, reason = "NotLoaded" }
	end
	if data.Inventory[itemId] then
		return { ok = false, reason = "AlreadyOwned" }
	end
	if data.Coins < item.Price then
		return { ok = false, reason = "NotEnoughCoins" }
	end

	DataService.Increment(player, "Coins", -item.Price)
	data.Inventory[itemId] = true
	return { ok = true }
end

purchaseRemote.OnServerInvoke = purchase

-- Developer products -----------------------------------------------------

MarketplaceService.ProcessReceipt = function(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		-- They left. Roblox will retry the next time they join.
		return Enum.ProductPurchaseDecision.NotYetProcessed
	end

	local data = DataService.WaitFor(player, 15)
	if not data then
		return Enum.ProductPurchaseDecision.NotYetProcessed
	end

	-- Already granted on a previous attempt? Then just confirm it.
	if table.find(data.ProcessedReceipts, receipt.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local grant = DEV_PRODUCTS[receipt.ProductId]
	if not grant then
		warn("[ShopService] no handler for product", receipt.ProductId)
		return Enum.ProductPurchaseDecision.NotYetProcessed
	end

	local ok, err = pcall(grant, player)
	if not ok then
		warn("[ShopService] grant failed:", err)
		return Enum.ProductPurchaseDecision.NotYetProcessed
	end

	table.insert(data.ProcessedReceipts, receipt.PurchaseId)
	while #data.ProcessedReceipts > RECEIPT_HISTORY do
		table.remove(data.ProcessedReceipts, 1)
	end

	-- Only confirm once the grant and the receipt are safely saved.
	if not DataService.SaveNow(player) then
		return Enum.ProductPurchaseDecision.NotYetProcessed
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Game passes ------------------------------------------------------------

function ShopService.HasPass(player: Player, passName: string): boolean
	local passId = GAME_PASSES[passName]
	if not passId then
		return false
	end
	local cache = passCache[player]
	if not cache then
		cache = {}
		passCache[player] = cache
	end
	if cache[passId] == nil then
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, passId)
		if not ok then
			return false -- don't cache failures; try again next time
		end
		cache[passId] = owns
	end
	return cache[passId]
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if purchased then
		passCache[player] = passCache[player] or {}
		passCache[player][passId] = true
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastRequest[player] = nil
	passCache[player] = nil
end)

ShopService.Catalog = CATALOG
return ShopService
