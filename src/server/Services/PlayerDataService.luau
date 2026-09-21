--[[
	Owns each player's persistent RPG data for the session: level/XP,
	health, daily keys, and the boss-kill pity counter. Backed by
	PlayerProfileStore (DataStore + retry + session lock). All writes to
	this data happen on the server; the client only ever receives read-only
	snapshots over PlayerDataUpdated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerProfileStore = require(script.Parent.PlayerProfileStore)

local PlayerDataService = {}

local SAVE_INTERVAL_SECONDS = 120

local profiles: { [Player]: { [string]: any } } = {}

local function defaultData()
	return {
		Level = Config.StartingStats.Level,
		Experience = Config.StartingStats.Experience,
		MaxHealth = Config.StartingStats.MaxHealth,
		Keys = Config.Daily.KeysPerDay,
		LastKeyRegenAt = os.time(),
		BossKillsSincePity = 0,
	}
end

local function applyKeyRegen(data)
	local elapsed = os.time() - data.LastKeyRegenAt
	local regenerated = math.floor(elapsed / Config.Daily.KeyRegenSeconds)
	if regenerated > 0 and data.Keys < Config.Daily.KeysPerDay then
		data.Keys = math.min(Config.Daily.KeysPerDay, data.Keys + regenerated)
		data.LastKeyRegenAt += regenerated * Config.Daily.KeyRegenSeconds
	end
end

local function pushToClient(player: Player)
	local data = profiles[player]
	if data then
		Remotes.PlayerDataUpdated:FireClient(player, data)
	end
end

function PlayerDataService.Get(player: Player)
	return profiles[player]
end

function PlayerDataService.AddExperience(player: Player, amount: number)
	local data = profiles[player]
	if not data or amount <= 0 then
		return
	end

	data.Experience += amount

	while data.Level < Config.Leveling.MaxLevel do
		local xpToNext = Config.GetXpToNextLevel(data.Level)
		if data.Experience < xpToNext then
			break
		end

		data.Experience -= xpToNext
		data.Level += 1
		data.MaxHealth += Config.Leveling.HealthPerLevel
	end

	if data.Level >= Config.Leveling.MaxLevel then
		data.Experience = 0
	end

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MaxHealth ~= data.MaxHealth then
		local delta = data.MaxHealth - humanoid.MaxHealth
		humanoid.MaxHealth = data.MaxHealth
		humanoid.Health = math.min(data.MaxHealth, humanoid.Health + delta)
	end

	pushToClient(player)
end

-- Peeks whether this player's next boss kill is pity-guaranteed, without
-- mutating the counter. Call before rolling the chest so the roll can be
-- forced to Epic+.
function PlayerDataService.PeekPity(player: Player): boolean
	local data = profiles[player]
	return data ~= nil and data.BossKillsSincePity >= Config.Pity.BossKillThreshold
end

-- Advances or resets the pity counter given whether this boss kill's drop
-- was Epic-or-better (naturally or via pity). Call once per boss kill,
-- right after rolling loot.
function PlayerDataService.RegisterBossKill(player: Player, gotEpicOrBetter: boolean): boolean
	local data = profiles[player]
	if not data then
		return false
	end

	local forcedPity = data.BossKillsSincePity >= Config.Pity.BossKillThreshold

	if gotEpicOrBetter or forcedPity then
		data.BossKillsSincePity = 0
	else
		data.BossKillsSincePity += 1
	end

	pushToClient(player)
	return forcedPity
end

function PlayerDataService.SpendKey(player: Player): boolean
	local data = profiles[player]
	if not data or data.Keys <= 0 then
		return false
	end

	data.Keys -= 1
	pushToClient(player)
	return true
end

local function onCharacterAdded(player: Player, character: Model)
	local data = profiles[player]
	if not data then
		return
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = data.MaxHealth
	humanoid.Health = data.MaxHealth

	humanoid.Died:Connect(function()
		Remotes.PlayerDied:FireClient(player)
	end)
end

local function onPlayerAdded(player: Player)
	local data, err = PlayerProfileStore.Load(player.UserId, defaultData())

	if not data then
		warn(string.format("[PlayerDataService] failed to load profile for %s: %s", player.Name, tostring(err)))
		player:Kick("Could not load your save data. Please rejoin in a moment.")
		return
	end

	applyKeyRegen(data)
	profiles[player] = data
	pushToClient(player)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local data = profiles[player]
	if not data then
		return
	end

	PlayerProfileStore.Save(player.UserId, data)
	PlayerProfileStore.ReleaseLock(player.UserId)
	profiles[player] = nil
end

function PlayerDataService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL_SECONDS)
			for player, data in profiles do
				PlayerProfileStore.Save(player.UserId, data)
			end
		end
	end)

	game:BindToClose(function()
		for player, data in profiles do
			PlayerProfileStore.Save(player.UserId, data)
			PlayerProfileStore.ReleaseLock(player.UserId)
		end
	end)
end

return PlayerDataService
