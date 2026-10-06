-- CITY GRIND: server-authoritative player data.
-- The server owns every number. Clients only ever see copies through
-- Player attributes (read-only for them) and the GetProfile remote.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))

local PlayerData = {}

local SERVER_ID = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DATASTORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[CityGrind] DataStore unavailable, progress will NOT save this session:", result)
	end
end

local profiles: { [Player]: any } = {}
local dirty: { [Player]: boolean } = {}
local loadFailed: { [Player]: boolean } = {}

-- Fired as (player, title, body). Main wires this to the Notify remote.
PlayerData.onNotify = Instance.new("BindableEvent")

local function defaultProfile()
	local stats = {}
	for _, stat in Config.STATS do
		stats[stat] = 1
	end
	local statXP = {}
	for _, stat in Config.STATS do
		statXP[stat] = 0
	end
	return {
		version = 1,
		cash = Config.STARTING_CASH,
		xp = 0,
		level = 1,
		reputation = 0,
		fame = 0,
		stats = stats,
		statXP = statXP,
		runsCompleted = 0,
		bestRunSeconds = 0,
		basketball = { games = 0, wins = 0, losses = 0, points = 0, threes = 0, dunks = 0, blocks = 0, steals = 0 },
		transactions = {
			{ t = os.time(), amount = Config.STARTING_CASH, label = "Welcome to the city" },
		},
		settings = { wallpaper = 1, uiScale = 1, notificationSounds = true },
		firstJoin = os.time(),
	}
end

-- Fill in any fields added after a player's data was first saved.
local function reconcile(data: any)
	local template = defaultProfile()
	for key, value in template do
		if data[key] == nil then
			data[key] = value
		elseif type(value) == "table" and type(data[key]) == "table" and key ~= "transactions" then
			for subKey, subValue in value do
				if data[key][subKey] == nil then
					data[key][subKey] = subValue
				end
			end
		end
	end
	return data
end

local function publish(player: Player)
	local data = profiles[player]
	if not data then
		return
	end
	player:SetAttribute("Cash", data.cash)
	player:SetAttribute("XP", data.xp)
	player:SetAttribute("Level", data.level)
	player:SetAttribute("XPToNext", Config.xpToNext(data.level))
	player:SetAttribute("Reputation", data.reputation)
	player:SetAttribute("Rank", Config.reputationRank(data.reputation))
	player:SetAttribute("Fame", data.fame)
	player:SetAttribute("Wallpaper", data.settings.wallpaper)
	player:SetAttribute("UIScale", data.settings.uiScale)
	player:SetAttribute("NotificationSounds", data.settings.notificationSounds)
	for _, stat in Config.STATS do
		player:SetAttribute(stat, data.stats[stat])
	end
	player:SetAttribute("Wins", data.basketball.wins)
	player:SetAttribute("Losses", data.basketball.losses)
	player:SetAttribute("DataLoaded", true)
end

local function retry<T>(attempts: number, fn: () -> T): (boolean, T | string)
	local ok, result
	for attempt = 1, attempts do
		ok, result = pcall(fn)
		if ok then
			return true, result
		end
		task.wait(attempt * 2)
	end
	return false, result
end

function PlayerData.load(player: Player)
	local key = "player_" .. player.UserId
	local data

	if store then
		local lockedElsewhere = false
		for _ = 1, 5 do
			lockedElsewhere = false
			local ok, result = retry(3, function()
				return (store :: DataStore):UpdateAsync(key, function(saved)
					saved = saved or defaultProfile()
					local lock = saved.sessionLock
					if lock and lock.server ~= SERVER_ID and os.time() - lock.time < Config.SESSION_LOCK_SECONDS then
						lockedElsewhere = true
						return nil -- leave the record untouched
					end
					saved.sessionLock = { server = SERVER_ID, time = os.time() }
					return saved
				end)
			end)
			if not ok then
				warn("[CityGrind] Load failed for", player.Name, result)
				loadFailed[player] = true
				player:Kick("City Grind could not load your save. Please rejoin in a minute.")
				return
			end
			if not lockedElsewhere then
				data = result
				break
			end
			task.wait(4) -- previous server is still releasing the save
		end
		if lockedElsewhere then
			loadFailed[player] = true
			player:Kick("Your save is still open on another server. Please rejoin in a minute.")
			return
		end
	else
		data = defaultProfile()
	end

	if not player.Parent then
		return -- left while loading
	end
	data.sessionLock = nil
	profiles[player] = reconcile(data)
	publish(player)
end

function PlayerData.save(player: Player, releaseLock: boolean)
	local data = profiles[player]
	if not data or not store or loadFailed[player] then
		return
	end
	local key = "player_" .. player.UserId
	local ok, err = retry(3, function()
		return (store :: DataStore):UpdateAsync(key, function(saved)
			local lock = saved and saved.sessionLock
			if lock and lock.server ~= SERVER_ID then
				return nil -- another server took over; never overwrite its data
			end
			local copy = table.clone(data)
			copy.sessionLock = if releaseLock then nil else { server = SERVER_ID, time = os.time() }
			return copy
		end)
	end)
	if ok then
		dirty[player] = nil
	else
		warn("[CityGrind] Save failed for", player.Name, err)
	end
end

function PlayerData.release(player: Player)
	PlayerData.save(player, true)
	profiles[player] = nil
	dirty[player] = nil
	loadFailed[player] = nil
end

function PlayerData.get(player: Player)
	return profiles[player]
end

local function markChanged(player: Player)
	dirty[player] = true
	publish(player)
end

local function addTransaction(data, amount: number, label: string)
	table.insert(data.transactions, 1, { t = os.time(), amount = amount, label = label })
	while #data.transactions > Config.MAX_TRANSACTIONS do
		table.remove(data.transactions)
	end
end

function PlayerData.addCash(player: Player, amount: number, label: string): boolean
	local data = profiles[player]
	if not data or amount <= 0 or amount ~= amount then
		return false
	end
	amount = math.floor(amount)
	data.cash = math.min(data.cash + amount, Config.MAX_CASH)
	addTransaction(data, amount, label)
	markChanged(player)
	return true
end

function PlayerData.spendCash(player: Player, amount: number, label: string): boolean
	local data = profiles[player]
	if not data or amount <= 0 or amount ~= amount then
		return false
	end
	amount = math.floor(amount)
	if data.cash < amount then
		return false
	end
	data.cash -= amount
	addTransaction(data, -amount, label)
	markChanged(player)
	return true
end

function PlayerData.addXP(player: Player, amount: number)
	local data = profiles[player]
	if not data or amount <= 0 then
		return
	end
	data.xp += math.floor(amount)
	while data.level < Config.MAX_LEVEL and data.xp >= Config.xpToNext(data.level) do
		data.xp -= Config.xpToNext(data.level)
		data.level += 1
		PlayerData.onNotify:Fire(player, "LEVEL UP", "You reached level " .. data.level .. "!")
	end
	if data.level >= Config.MAX_LEVEL then
		data.xp = 0
	end
	markChanged(player)
end

function PlayerData.addReputation(player: Player, amount: number)
	local data = profiles[player]
	if not data or amount <= 0 then
		return
	end
	local before = Config.reputationRank(data.reputation)
	data.reputation += math.floor(amount)
	local after = Config.reputationRank(data.reputation)
	if after ~= before then
		PlayerData.onNotify:Fire(player, "NEW RANK", "People around the city now call you " .. after .. ".")
	end
	markChanged(player)
end

-- Training progress toward a stat. Every STAT_XP_PER_POINT raises it by 1 (max 99).
function PlayerData.addStatXP(player: Player, stat: string, amount: number)
	local data = profiles[player]
	if not data or data.stats[stat] == nil or amount <= 0 then
		return
	end
	data.statXP[stat] += amount
	while data.statXP[stat] >= Config.STAT_XP_PER_POINT and data.stats[stat] < 99 do
		data.statXP[stat] -= Config.STAT_XP_PER_POINT
		data.stats[stat] += 1
		PlayerData.onNotify:Fire(player, "STAT UP", stat .. " is now " .. data.stats[stat] .. ".")
	end
	markChanged(player)
end

-- Only whitelisted settings with validated values can be written by a client.
local SETTING_VALIDATORS = {
	wallpaper = function(v)
		return type(v) == "number" and v % 1 == 0 and Config.WALLPAPERS[v] ~= nil
	end,
	uiScale = function(v)
		return table.find(Config.UI_SCALES, v) ~= nil
	end,
	notificationSounds = function(v)
		return type(v) == "boolean"
	end,
}

function PlayerData.setSetting(player: Player, key: string, value: any): boolean
	local data = profiles[player]
	local validate = SETTING_VALIDATORS[key]
	if not data or not validate or not validate(value) then
		return false
	end
	data.settings[key] = value
	markChanged(player)
	return true
end

function PlayerData.recordRun(player: Player, seconds: number)
	local data = profiles[player]
	if not data then
		return
	end
	data.runsCompleted += 1
	if data.bestRunSeconds == 0 or seconds < data.bestRunSeconds then
		data.bestRunSeconds = seconds
	end
	markChanged(player)
end

-- Adds to the saved basketball career totals (only known keys, only positive).
function PlayerData.recordBasketball(player: Player, deltas: { [string]: number })
	local data = profiles[player]
	if not data then
		return
	end
	for key, amount in deltas do
		if data.basketball[key] ~= nil and type(amount) == "number" and amount > 0 then
			data.basketball[key] += math.floor(amount)
		end
	end
	markChanged(player)
end

-- What the phone's Profile and Bank apps are allowed to see.
function PlayerData.publicSnapshot(player: Player)
	local data = profiles[player]
	if not data then
		return nil
	end
	return {
		cash = data.cash,
		level = data.level,
		xp = data.xp,
		xpToNext = Config.xpToNext(data.level),
		reputation = data.reputation,
		rank = Config.reputationRank(data.reputation),
		fame = data.fame,
		stats = table.clone(data.stats),
		runsCompleted = data.runsCompleted,
		bestRunSeconds = data.bestRunSeconds,
		basketball = table.clone(data.basketball),
		transactions = table.clone(data.transactions),
		firstJoin = data.firstJoin,
	}
end

function PlayerData.start()
	Players.PlayerAdded:Connect(PlayerData.load)
	for _, player in Players:GetPlayers() do
		task.spawn(PlayerData.load, player)
	end
	Players.PlayerRemoving:Connect(PlayerData.release)

	task.spawn(function()
		while true do
			task.wait(Config.AUTOSAVE_SECONDS)
			for player in dirty do
				task.spawn(PlayerData.save, player, false)
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() and not store then
			return
		end
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				PlayerData.release(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
end

return PlayerData
