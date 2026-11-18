--[[
	RoundService
	A complete round loop: Waiting -> Intermission -> InRound -> Ending -> repeat.

	- State and timer are replicated as attributes on ReplicatedStorage.RoundState,
	  so any client UI can show them with GetAttributeChangedSignal.
	- Picks a random map from ServerStorage.Maps, spawns players on map.Spawns parts.
	- Tracks who's still alive, ends early when one (or zero) player is left.
	- Survivors get coins through DataService. Cleans up every connection each round.

	Setup:
		ServerStorage.Maps.<MapName>  (Model)
		  └─ Spawns (Folder of Parts)

	MIT licensed. See LICENSE in the repository root.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataService = require(script.Parent.DataService)

local CONFIG = {
	MinPlayers = 2,
	Intermission = 15,
	RoundLength = 120,
	EndingDelay = 6,
	WinReward = 100,
}

local stateObject = Instance.new("Configuration")
stateObject.Name = "RoundState"
stateObject:SetAttribute("State", "Waiting")
stateObject:SetAttribute("Timer", 0)
stateObject:SetAttribute("Map", "")
stateObject.Parent = ReplicatedStorage

local RoundService = {}
RoundService.RoundEnded = Instance.new("BindableEvent") -- (winners: {Player})

local function setState(state: string, timer: number?)
	stateObject:SetAttribute("State", state)
	stateObject:SetAttribute("Timer", timer or 0)
end

local function countdown(seconds: number, keepGoing: () -> boolean): boolean
	for t = seconds, 1, -1 do
		stateObject:SetAttribute("Timer", t)
		task.wait(1)
		if not keepGoing() then
			return false
		end
	end
	stateObject:SetAttribute("Timer", 0)
	return true
end

local function enoughPlayers(): boolean
	return #Players:GetPlayers() >= CONFIG.MinPlayers
end

local function pickMap(): Model?
	local maps = ServerStorage:FindFirstChild("Maps")
	if not maps or #maps:GetChildren() == 0 then
		warn("[RoundService] put at least one map in ServerStorage.Maps")
		return nil
	end
	local options = maps:GetChildren()
	return options[math.random(#options)]:Clone()
end

local function runRound(map: Model): { Player }
	local alive: { [Player]: boolean } = {}
	local connections: { RBXScriptConnection } = {}

	local function aliveCount(): number
		local n = 0
		for _ in alive do
			n += 1
		end
		return n
	end

	local ok, err = pcall(function()
		local spawnParts: { BasePart } = {}
		local spawns = map:FindFirstChild("Spawns")
		if spawns then
			for _, child in spawns:GetChildren() do
				if child:IsA("BasePart") then
					table.insert(spawnParts, child)
				end
			end
		end
		if #spawnParts == 0 then
			warn("[RoundService] map", map.Name, "has no Spawns folder with Parts in it")
			return
		end

		for i, player in Players:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if character and humanoid and humanoid.Health > 0 then
				local spawnPart = spawnParts[(i - 1) % #spawnParts + 1]
				character:PivotTo(spawnPart.CFrame + Vector3.new(0, 4, 0))
				alive[player] = true
				table.insert(
					connections,
					humanoid.Died:Connect(function()
						alive[player] = nil
					end)
				)
				-- Covers characters removed without dying (reset scripts, LoadCharacter, falling apart).
				table.insert(
					connections,
					player.CharacterRemoving:Connect(function()
						alive[player] = nil
					end)
				)
			end
		end

		table.insert(
			connections,
			Players.PlayerRemoving:Connect(function(player)
				alive[player] = nil
			end)
		)

		setState("InRound", CONFIG.RoundLength)
		local startedWith = aliveCount()
		countdown(CONFIG.RoundLength, function()
			-- Solo testing: keep going while the one player is alive.
			local left = aliveCount()
			return if startedWith > 1 then left > 1 else left > 0
		end)
	end)

	-- Always disconnect, even if the round errored.
	for _, connection in connections do
		connection:Disconnect()
	end

	if not ok then
		warn("[RoundService] round errored:", err)
		return {}
	end

	local winners = {}
	for player in alive do
		if player.Parent then
			table.insert(winners, player)
			DataService.Increment(player, "Coins", CONFIG.WinReward)
		end
	end
	return winners
end

function RoundService.Start()
	task.spawn(function()
		while true do
			setState("Waiting")
			while not enoughPlayers() do
				task.wait(1)
			end

			setState("Intermission", CONFIG.Intermission)
			if not countdown(CONFIG.Intermission, enoughPlayers) then
				continue -- someone left, back to waiting
			end

			local map = pickMap()
			if not map then
				task.wait(5)
				continue
			end
			map.Parent = workspace
			stateObject:SetAttribute("Map", map.Name)

			local winners = runRound(map)

			setState("Ending", CONFIG.EndingDelay)
			RoundService.RoundEnded:Fire(winners)
			task.wait(CONFIG.EndingDelay)

			map:Destroy()
			stateObject:SetAttribute("Map", "")
			for _, player in Players:GetPlayers() do
				task.spawn(player.LoadCharacter, player)
			end
		end
	end)
end

return RoundService
