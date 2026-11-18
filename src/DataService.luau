--[[
	DataService
	Crash-safe player data for Roblox.

	- Loads with UpdateAsync + a session lock, so two servers can never
	  overwrite each other (prevents item duplication through rejoining or teleporting).
	- Reconciles saved data against CONFIG.Template, so adding new fields never breaks old saves.
	- Retries failed DataStore calls with backoff.
	- Autosaves on an interval, saves on leave, and waits for every save on shutdown.
	- If another server takes the session over, this server stops writing and
	  kicks the player instead of silently overwriting newer data.

	Usage (server):
		local DataService = require(path.to.DataService)
		DataService.Loaded:Connect(function(player, data) ... end)
		DataService.Increment(player, "Coins", 50)
		local data = DataService.Get(player) -- nil until loaded

	MIT licensed. See LICENSE in the repository root.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

-- Config -----------------------------------------------------------------

local CONFIG = {
	-- Changing the store name starts everyone with fresh data. Bump the
	-- version only on purpose.
	StoreName = "PlayerData_v1",
	AutosaveInterval = 120, -- seconds
	MaxRetries = 5,
	-- A lock that hasn't been refreshed for this long belongs to a dead server.
	LockStaleAfter = 120 * 3,
	ShutdownTimeout = 25, -- seconds to wait for saves in BindToClose (Roblox allows 30)

	-- Every new player starts with a copy of this. New keys are added to old
	-- saves automatically. Only use DataStore-safe values (no Instances).
	Template = {
		Coins = 0,
		Inventory = {}, -- [itemId] = true
		ProcessedReceipts = {}, -- recent PurchaseIds, used by ShopService to avoid double grants
	},
}

local store = DataStoreService:GetDataStore(CONFIG.StoreName)
local profiles: { [Player]: { [string]: any } } = {}
-- The data table that currently owns each user's session on this server.
-- Autosaves for a session that has ended are cancelled, so a slow autosave can
-- never re-lock data after the player's final (releasing) save.
local sessions: { [number]: { [string]: any } } = {}
-- UserIds whose releasing save is still in flight on this server. A quick
-- rejoin to the same server waits for it, so it can't load the older copy.
local releasing: { [number]: number } = {}
local pendingSaves = 0

-- Minimal signal. BindableEvents copy tables, which would hand listeners a copy
-- of the player's data instead of the live table, so we don't use one here.
local function newSignal()
	local connections = {}
	local signal = {}

	function signal:Connect(fn: (...any) -> ())
		local connection = { Connected = true }
		function connection.Disconnect()
			connection.Connected = false
			local index = table.find(connections, connection)
			if index then
				table.remove(connections, index)
			end
		end
		connection.Fn = fn
		table.insert(connections, connection)
		return connection
	end

	function signal:Fire(...)
		for _, connection in table.clone(connections) do
			if connection.Connected then
				task.spawn(connection.Fn, ...)
			end
		end
	end

	return signal
end

local DataService = {}
DataService.Loaded = newSignal() -- (player, data) with the live data table
DataService.Config = CONFIG

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

	for attempt = 1, CONFIG.MaxRetries do
		local blocked, stole = false, false
		-- On the last attempt, assume whoever holds the lock is gone and take it.
		-- (The old server's next write will then be refused, see save().)
		local force = attempt == CONFIG.MaxRetries

		local ok, err = pcall(function()
			store:UpdateAsync(key, function(saved)
				saved = saved or deepCopy(CONFIG.Template)
				local lock = saved._lock
				local lockedElsewhere = lock ~= nil
					and lock.job ~= game.JobId
					and os.time() - lock.time < CONFIG.LockStaleAfter
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
				warn("[DataService] took over a session lock from another server for", player.Name)
			end
			reconcile(result, CONFIG.Template)
			return result
		end

		result = nil
		if not ok then
			warn(("[DataService] load failed (attempt %d/%d): %s"):format(attempt, CONFIG.MaxRetries, tostring(err)))
		end
		if attempt < CONFIG.MaxRetries then
			task.wait(attempt * 2)
		end
	end

	return nil
end

-- Saves `data` for `userId`. When `release` is true, the session lock is cleared.
-- Returns true only if the data was actually written. The second value explains
-- a false result: "LockLost" (another server owns the data now),
-- "SessionEnded" (a newer releasing save supersedes this one) or "Error".
local function save(userId: number, data, release: boolean): (boolean, string?)
	pendingSaves += 1
	if release then
		releasing[userId] = (releasing[userId] or 0) + 1
	end
	local key = keyFor(userId)
	local reason: string? = nil

	local function finish()
		pendingSaves -= 1
		if release then
			local count = (releasing[userId] or 1) - 1
			releasing[userId] = if count > 0 then count else nil
		end
	end

	for attempt = 1, CONFIG.MaxRetries do
		reason = nil
		local written = false
		local ok, err = pcall(function()
			store:UpdateAsync(key, function(saved)
				written = false
				if saved and saved._lock and saved._lock.job ~= game.JobId then
					reason = "LockLost"
					return nil -- another server took over; never overwrite its data
				end
				if not release and sessions[userId] ~= data then
					reason = "SessionEnded"
					return nil
				end
				reason = nil
				local out = table.clone(data)
				out._lock = if release then nil else { job = game.JobId, time = os.time() }
				written = true
				return out
			end)
		end)

		if ok then
			finish()
			if written then
				return true, nil
			end
			return false, reason
		end

		reason = "Error"
		warn(
			("[DataService] save %d failed (attempt %d/%d): %s"):format(
				userId,
				attempt,
				CONFIG.MaxRetries,
				tostring(err)
			)
		)
		if attempt < CONFIG.MaxRetries then
			task.wait(attempt * 2)
		end
	end

	finish()
	return false, reason
end

-- Called when a save reports that another server owns this player's data.
local function onLockLost(player: Player)
	if profiles[player] then
		profiles[player] = nil
		sessions[player.UserId] = nil
		warn("[DataService] session lock lost for", player.Name, "- this server will stop saving their data")
		player:Kick("Your data was loaded in another server. Please rejoin.")
	end
end

local function onPlayerAdded(player: Player)
	local waitUntil = os.clock() + 30
	while releasing[player.UserId] and os.clock() < waitUntil do
		task.wait(0.1)
	end
	local data = load(player)
	if not data then
		if player.Parent then
			player:Kick("We couldn't load your data. Please rejoin in a minute.")
		end
		return
	end
	if player.Parent == nil then
		-- Left while loading: hand the lock straight back.
		save(player.UserId, data, true)
		return
	end
	profiles[player] = data
	sessions[player.UserId] = data
	replicate(player, data)
	DataService.Loaded:Fire(player, data)
end

local function onPlayerRemoving(player: Player)
	local data = profiles[player]
	if not data then
		return
	end
	-- Remove first, so autosave and shutdown don't save it twice, and any
	-- in-flight autosave for this session is cancelled.
	profiles[player] = nil
	if sessions[player.UserId] == data then
		sessions[player.UserId] = nil
	end
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

function DataService.Set(player: Player, key: string, value: any): boolean
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
-- Returns true only when the data is confirmed written.
function DataService.SaveNow(player: Player): boolean
	local data = profiles[player]
	if not data then
		return false
	end
	local ok, reason = save(player.UserId, data, false)
	if reason == "LockLost" then
		onLockLost(player)
	end
	return ok
end

-- Startup ----------------------------------------------------------------

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

task.spawn(function()
	while true do
		task.wait(CONFIG.AutosaveInterval)
		for player, data in profiles do
			task.spawn(function()
				local _, reason = save(player.UserId, data, false)
				if reason == "LockLost" then
					onLockLost(player)
				end
			end)
		end
	end
end)

game:BindToClose(function()
	for player, data in profiles do
		profiles[player] = nil
		sessions[player.UserId] = nil
		task.spawn(save, player.UserId, data, true)
	end
	-- Wait for every in-flight save, including ones started by PlayerRemoving.
	local deadline = os.clock() + CONFIG.ShutdownTimeout
	while pendingSaves > 0 and os.clock() < deadline do
		task.wait()
	end
end)

return DataService
