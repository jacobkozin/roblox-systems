--[[
	DataService
	Crash-safe player data for Roblox.

	- Loads with UpdateAsync + a session lock, so two servers can never
	  overwrite each other (prevents item duplication through rejoining or teleporting).
	- Reconciles saved data against TEMPLATE, so adding new fields never breaks old saves.
	- Retries failed DataStore calls with backoff.
	- Autosaves on an interval, saves on leave, and waits for every save on shutdown.

	Usage (server):
		local DataService = require(path.to.DataService)
		DataService.Loaded.Event:Connect(function(player, data) ... end)
		DataService.Increment(player, "Coins", 50)
		local data = DataService.Get(player) -- nil until loaded
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local STORE_NAME = "PlayerData_v1"
local AUTOSAVE_INTERVAL = 120 -- seconds
local MAX_RETRIES = 5
local LOCK_STALE_AFTER = AUTOSAVE_INTERVAL * 3 -- a lock not refreshed this long belongs to a dead server

local TEMPLATE = {
	Coins = 0,
	Inventory = {}, -- [itemId] = true
	ProcessedReceipts = {}, -- recent PurchaseIds, used by ShopService to avoid double grants
}

local store = DataStoreService:GetDataStore(STORE_NAME)
local profiles: { [Player]: { [string]: any } } = {}
local pendingSaves = 0

local DataService = {}
DataService.Loaded = Instance.new("BindableEvent") -- (player, data)

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

-- Fill in any keys that exist in the template but not in the save.
local function reconcile(data, template)
	for key, default in template do
		if data[key] == nil then
			data[key] = deepCopy(default)
		elseif type(default) == "table" and type(data[key]) == "table" and next(default) ~= nil then
			reconcile(data[key], default)
		end
	end
end

local function keyFor(userId: number): string
	return "player_" .. userId
end

local function withRetries(label: string, fn: () -> ()): boolean
	for attempt = 1, MAX_RETRIES do
		local ok, err = pcall(fn)
		if ok then
			return true
		end
		warn(("[DataService] %s failed (attempt %d/%d): %s"):format(label, attempt, MAX_RETRIES, tostring(err)))
		if attempt < MAX_RETRIES then
			task.wait(attempt * 2)
		end
	end
	return false
end

local function replicate(player: Player, data)
	-- Expose top-level numbers as attributes so client UI can read and listen to them.
	for key, value in data do
		if type(value) == "number" then
			player:SetAttribute(key, value)
		end
	end
end

-- Returns the loaded data, or nil if the DataStore could not be reached.
local function load(player: Player)
	local key = keyFor(player.UserId)
	local result

	for attempt = 1, MAX_RETRIES do
		local blocked, stole = false, false
		-- On the last attempt, assume whoever holds the lock is gone and take it.
		local force = attempt == MAX_RETRIES

		local ok, err = pcall(function()
			store:UpdateAsync(key, function(saved)
				saved = saved or deepCopy(TEMPLATE)
				local lock = saved._lock
				local lockedElsewhere = lock ~= nil
					and lock.job ~= game.JobId
					and os.time() - lock.time < LOCK_STALE_AFTER
				if lockedElsewhere and not force then
					blocked = true
					return nil -- cancel the write; another server still owns this data
				end
				blocked, stole = false, lockedElsewhere
				saved._lock = { job = game.JobId, time = os.time() }
				result = saved
				return saved
			end)
		end)

		if ok and not blocked then
			if stole then
				warn("[DataService] took over a stale session lock for", player.Name)
			end
			reconcile(result, TEMPLATE)
			return result
		end

		result = nil
		if not ok then
			warn(("[DataService] load failed (attempt %d): %s"):format(attempt, tostring(err)))
		end
		task.wait(attempt * 2)
	end

	return nil
end

-- Saves `data` for `userId`. When `release` is true, the session lock is cleared.
local function save(userId: number, data, release: boolean): boolean
	pendingSaves += 1
	local ok = withRetries("save " .. userId, function()
		store:UpdateAsync(keyFor(userId), function(saved)
			if saved and saved._lock and saved._lock.job ~= game.JobId then
				return nil -- another server took over; never overwrite its data
			end
			local out = table.clone(data)
			out._lock = if release then nil else { job = game.JobId, time = os.time() }
			return out
		end)
	end)
	pendingSaves -= 1
	return ok
end

local function onPlayerAdded(player: Player)
	local data = load(player)
	if not data then
		player:Kick("We couldn't load your data. Please rejoin in a minute.")
		return
	end
	if player.Parent == nil then
		-- Left while loading: hand the lock straight back.
		save(player.UserId, data, true)
		return
	end
	profiles[player] = data
	replicate(player, data)
	DataService.Loaded:Fire(player, data)
end

local function onPlayerRemoving(player: Player)
	local data = profiles[player]
	if not data then
		return
	end
	profiles[player] = nil -- remove first, so autosave and shutdown don't save it twice
	save(player.UserId, data, true)
end

-- Public API -------------------------------------------------------------

function DataService.Get(player: Player)
	return profiles[player]
end

-- Yields until the player's data is loaded. Returns nil if they leave first.
function DataService.WaitFor(player: Player, timeout: number?)
	local deadline = os.clock() + (timeout or 30)
	while not profiles[player] and player.Parent and os.clock() < deadline do
		task.wait(0.1)
	end
	return profiles[player]
end

function DataService.Set(player: Player, key: string, value: any)
	local data = profiles[player]
	if not data then
		return false
	end
	data[key] = value
	if type(value) == "number" then
		player:SetAttribute(key, value)
	end
	return true
end

function DataService.Increment(player: Player, key: string, amount: number): number?
	local data = profiles[player]
	if not data or type(data[key]) ~= "number" then
		return nil
	end
	data[key] += amount
	player:SetAttribute(key, data[key])
	return data[key]
end

-- Saves right now (yields). Use after anything involving real money, like dev products.
function DataService.SaveNow(player: Player): boolean
	local data = profiles[player]
	if not data then
		return false
	end
	return save(player.UserId, data, false)
end

-- Startup ----------------------------------------------------------------

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player, data in profiles do
			task.spawn(save, player.UserId, data, false)
		end
	end
end)

game:BindToClose(function()
	for player, data in profiles do
		profiles[player] = nil
		task.spawn(save, player.UserId, data, true)
	end
	-- Wait for every in-flight save, including ones started by PlayerRemoving.
	local deadline = os.clock() + 25
	while pendingSaves > 0 and os.clock() < deadline do
		task.wait()
	end
end)

return DataService
