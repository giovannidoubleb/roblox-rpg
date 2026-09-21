--[[
	Owns each player's in-memory RPG stats for the session and pushes
	updates to their client. Persistence (DataStores) is not wired up yet.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local PlayerDataService = {}

local playerData: { [Player]: { [string]: number } } = {}

local function createStartingData()
	local data = {}
	for key, value in Config.StartingStats do
		data[key] = value
	end
	return data
end

function PlayerDataService.Get(player: Player)
	return playerData[player]
end

local function onPlayerAdded(player: Player)
	local data = createStartingData()
	playerData[player] = data
	Remotes.PlayerDataUpdated:FireClient(player, data)
end

local function onPlayerRemoving(player: Player)
	playerData[player] = nil
end

function PlayerDataService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerDataService
