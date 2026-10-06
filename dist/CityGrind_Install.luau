-- CITY GRIND Phase 1 installer. Paste all of this into Studio's Command Bar
-- (View > Command Bar) and press Enter. Re-running it updates the scripts in place.
local function put(parent, className, name, source)
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName ~= className then existing:Destroy() existing = nil end
	local inst = existing or Instance.new(className)
	inst.Name = name
	if source then inst.Source = source end
	inst.Parent = parent
	return inst
end
local RS = game:GetService('ReplicatedStorage')
local SSS = game:GetService('ServerScriptService')
local SP = game:GetService('StarterPlayer')
SP.EnableMouseLockOption = false
local SPS = SP:FindFirstChildOfClass('StarterPlayerScripts')
local folder = put(RS, 'Folder', 'CityGrind', nil)
put(folder, 'ModuleScript', 'Config', [=====[
--!strict
-- CITY GRIND: shared tuning values. Lives in ReplicatedStorage.CityGrind.Config
-- so the server and every client read the same numbers.

local Config = {}

Config.DATASTORE_NAME = "CityGrind_PlayerData_v1"
Config.AUTOSAVE_SECONDS = 120
Config.SESSION_LOCK_SECONDS = 180

Config.STARTING_CASH = 500
Config.MAX_CASH = 1_000_000_000
Config.MAX_LEVEL = 100
Config.MAX_TRANSACTIONS = 25

-- Total XP needed to go from `level` to `level + 1`.
function Config.xpToNext(level: number): number
	return math.floor(100 * level ^ 1.5)
end

Config.REPUTATION_RANKS = {
	{ min = 0, name = "Nobody" },
	{ min = 100, name = "Known" },
	{ min = 500, name = "Respected" },
	{ min = 1000, name = "Local Star" },
	{ min = 2500, name = "City Famous" },
	{ min = 5000, name = "Celebrity" },
	{ min = 10000, name = "Legend" },
}

function Config.reputationRank(rep: number): string
	local name = Config.REPUTATION_RANKS[1].name
	for _, rank in Config.REPUTATION_RANKS do
		if rep >= rank.min then
			name = rank.name
		end
	end
	return name
end

-- Attribute names. Stats are 1-99 like a sports game rating.
Config.STATS = {
	"Strength", "Speed", "Stamina", "Vertical",
	"Shooting", "BallHandling", "Passing", "Defense", "Finishing",
}

-- Movement. Stamina stat (1-99) scales max stamina and recovery.
Config.WALK_SPEED = 14
Config.SPRINT_SPEED = 24
Config.CROUCH_SPEED = 7
Config.SLIDE_SPEED = 34
Config.SLIDE_SECONDS = 0.7
Config.SLIDE_COST = 15
Config.SPRINT_DRAIN_PER_SEC = 12
Config.MIN_SPRINT_STAMINA = 10

function Config.maxStamina(staminaStat: number): number
	return 100 + (staminaStat - 1) * 2 -- 100 at stat 1, ~296 at stat 99
end

function Config.staminaRegen(staminaStat: number): number
	return 14 + staminaStat * 0.25 -- per second
end

-- Neighborhood run route rewards (server validated).
Config.RUN_REWARD_XP = 40
Config.RUN_REWARD_CASH = 25
Config.RUN_STAMINA_STAT_XP = 20 -- progress toward +1 Stamina stat
Config.RUN_COOLDOWN = 45
Config.STAT_XP_PER_POINT = 100

Config.DRINK_PRICE = 5

Config.WALLPAPERS = {
	{ name = "Sunset", top = Color3.fromRGB(255, 120, 80), bottom = Color3.fromRGB(90, 40, 140) },
	{ name = "Court", top = Color3.fromRGB(255, 160, 40), bottom = Color3.fromRGB(150, 60, 20) },
	{ name = "Midnight", top = Color3.fromRGB(30, 40, 90), bottom = Color3.fromRGB(5, 5, 20) },
	{ name = "Ocean", top = Color3.fromRGB(60, 200, 230), bottom = Color3.fromRGB(10, 60, 140) },
	{ name = "Mint", top = Color3.fromRGB(120, 230, 170), bottom = Color3.fromRGB(20, 110, 90) },
}

Config.UI_SCALES = { 0.8, 0.9, 1, 1.1, 1.25 }

return Config
]=====])
local server = put(SSS, 'Script', 'CityGrindServer', [=====[
-- CITY GRIND: server entry point (ServerScriptService.CityGrindServer).
-- Builds the city, owns player data, and validates every remote.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local PlayerData = require(script:WaitForChild("PlayerData"))
local CityBuilder = require(script:WaitForChild("CityBuilder"))

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local remotes = shared:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = shared

local function remote(className: string, name: string): any
	local r = remotes:FindFirstChild(name) or Instance.new(className)
	r.Name = name
	r.Parent = remotes
	return r
end

local Notify = remote("RemoteEvent", "Notify") -- server -> client (title, body)
local StaminaRefill = remote("RemoteEvent", "StaminaRefill") -- server -> client
local PhoneState = remote("RemoteEvent", "PhoneState") -- client -> server (isOpen)
local GetProfile = remote("RemoteFunction", "GetProfile") -- client -> server
local SetSetting = remote("RemoteFunction", "SetSetting") -- client -> server (key, value)

-- Simple per-player cooldowns so no remote can be spammed.
local lastCall: { [Player]: { [string]: number } } = {}
local function allow(player: Player, key: string, cooldown: number): boolean
	local now = os.clock()
	local calls = lastCall[player]
	if not calls then
		calls = {}
		lastCall[player] = calls
	end
	if calls[key] and now - calls[key] < cooldown then
		return false
	end
	calls[key] = now
	return true
end

PlayerData.onNotify.Event:Connect(function(player: Player, title: string, body: string)
	Notify:FireClient(player, title, body)
end)

---------------------------------------------------------------------------
-- City
---------------------------------------------------------------------------
local city = CityBuilder.build()

---------------------------------------------------------------------------
-- Phone: profile, bank and settings data
---------------------------------------------------------------------------
GetProfile.OnServerInvoke = function(player: Player)
	if not allow(player, "GetProfile", 0.5) then
		return nil
	end
	return PlayerData.publicSnapshot(player)
end

SetSetting.OnServerInvoke = function(player: Player, key: any, value: any)
	if not allow(player, "SetSetting", 0.3) then
		return false
	end
	if type(key) ~= "string" then
		return false
	end
	return PlayerData.setSetting(player, key, value)
end

-- Taking the phone out puts a real phone in the character's hand,
-- so other players can see who is on their phone.
local function setPhoneProp(player: Player, isOpen: boolean)
	local character = player.Character
	if not character then
		return
	end
	local existing = character:FindFirstChild("CityPhone")
	if existing then
		existing:Destroy()
	end
	player:SetAttribute("PhoneOut", isOpen)
	if not isOpen then
		return
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end
	local phone = Instance.new("Part")
	phone.Name = "CityPhone"
	phone.Size = Vector3.new(0.45, 0.9, 0.08)
	phone.Color = Color3.fromRGB(20, 20, 24)
	phone.Material = Enum.Material.SmoothPlastic
	phone.CanCollide = false
	phone.CanQuery = false
	phone.CanTouch = false
	phone.Massless = true
	local screen = Instance.new("Part")
	screen.Name = "Screen"
	screen.Size = Vector3.new(0.38, 0.8, 0.02)
	screen.Color = Color3.fromRGB(120, 170, 255)
	screen.Material = Enum.Material.Neon
	screen.CanCollide = false
	screen.CanQuery = false
	screen.CanTouch = false
	screen.Massless = true
	screen.Parent = phone
	local screenWeld = Instance.new("WeldConstraint")
	screen.CFrame = phone.CFrame * CFrame.new(0, 0, -0.05)
	screenWeld.Part0 = phone
	screenWeld.Part1 = screen
	screenWeld.Parent = screen
	local offset = if hand.Name == "RightHand" then CFrame.new(0, -0.25, -0.25) else CFrame.new(0, -1, -0.3)
	phone.CFrame = hand.CFrame * offset * CFrame.Angles(math.rad(-70), 0, 0)
	screen.CFrame = phone.CFrame * CFrame.new(0, 0, -0.05)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = phone
	weld.Parent = phone
	phone.Parent = character
end

PhoneState.OnServerEvent:Connect(function(player: Player, isOpen: any)
	if type(isOpen) ~= "boolean" or not allow(player, "PhoneState", 0.25) then
		return
	end
	setPhoneProp(player, isOpen)
end)

---------------------------------------------------------------------------
-- Vending machine: spend $5, get a full stamina refill
---------------------------------------------------------------------------
if city.vendingPrompt then
	local prompt = city.vendingPrompt
	prompt.Triggered:Connect(function(player: Player)
		if not allow(player, "Vending", 2) then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local machine = prompt.Parent :: BasePart
		if not root or (root.Position - machine.Position).Magnitude > prompt.MaxActivationDistance + 4 then
			return
		end
		if PlayerData.spendCash(player, Config.DRINK_PRICE, "Corner Mart energy drink") then
			StaminaRefill:FireClient(player)
			Notify:FireClient(player, "ENERGY DRINK", "Stamina fully restored.")
		else
			Notify:FireClient(player, "NOT ENOUGH CASH", "You need $" .. Config.DRINK_PRICE .. ".")
		end
	end)
end

---------------------------------------------------------------------------
-- Neighborhood run route (section 57's 5K, scaled to District 1)
-- The server checks the order of checkpoints and the time between them,
-- so a teleporting or speed-hacking client cannot claim the reward.
---------------------------------------------------------------------------
type RunState = { nextIndex: number, startedAt: number, legStartedAt: number }
local runs: { [Player]: RunState } = {}
local runCooldownUntil: { [Player]: number } = {}
local route = CityBuilder.RUN_ROUTE
local MAX_AVG_SPEED = Config.SLIDE_SPEED -- nobody can average faster than a slide

local function legDistance(fromIndex: number, toIndex: number): number
	local a, b = route[fromIndex], route[toIndex]
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function setRunAttributes(player: Player)
	local run = runs[player]
	player:SetAttribute("RunNext", if run then run.nextIndex else 0)
	player:SetAttribute("RunStartedAt", if run then run.startedAt else 0)
end

local function onCheckpoint(player: Player, index: number)
	local now = workspace:GetServerTimeNow()
	local run = runs[player]

	if not run then
		if index ~= 1 then
			return
		end
		if (runCooldownUntil[player] or 0) > now then
			if allow(player, "RunCooldownMsg", 5) then
				local wait = math.ceil(runCooldownUntil[player] - now)
				Notify:FireClient(player, "CATCH YOUR BREATH", "Next run in " .. wait .. "s.")
			end
			return
		end
		runs[player] = { nextIndex = 2, startedAt = now, legStartedAt = now }
		setRunAttributes(player)
		Notify:FireClient(player, "RUN STARTED", "Hit every checkpoint and come back to the start.")
		return
	end

	-- Ignore the start arch while still standing in it, and any out-of-order arch.
	local expected = if run.nextIndex > #route then 1 else run.nextIndex
	if index ~= expected then
		return
	end

	local previous = if expected == 1 then #route else expected - 1
	local minTime = legDistance(previous, expected) / MAX_AVG_SPEED
	if now - run.legStartedAt < minTime then
		runs[player] = nil
		setRunAttributes(player)
		Notify:FireClient(player, "RUN CANCELLED", "That checkpoint was reached impossibly fast.")
		return
	end
	run.legStartedAt = now

	if expected ~= 1 then
		run.nextIndex += 1
		setRunAttributes(player)
		return
	end

	-- Finished the loop.
	local seconds = math.floor((now - run.startedAt) * 10) / 10
	runs[player] = nil
	runCooldownUntil[player] = now + Config.RUN_COOLDOWN
	setRunAttributes(player)
	PlayerData.recordRun(player, seconds)
	PlayerData.addCash(player, Config.RUN_REWARD_CASH, "Neighborhood run")
	PlayerData.addXP(player, Config.RUN_REWARD_XP)
	PlayerData.addStatXP(player, "Stamina", Config.RUN_STAMINA_STAT_XP)
	PlayerData.addStatXP(player, "Speed", math.floor(Config.RUN_STAMINA_STAT_XP / 2))
	PlayerData.addReputation(player, 2)
	Notify:FireClient(
		player,
		"RUN COMPLETE",
		string.format("%.1fs  +$%d  +%d XP  +Stamina", seconds, Config.RUN_REWARD_CASH, Config.RUN_REWARD_XP)
	)
end

for index, trigger in city.runTriggers do
	trigger.Touched:Connect(function(hit: BasePart)
		local character = hit.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		if not player then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root or (root.Position - trigger.Position).Magnitude > 14 then
			return
		end
		onCheckpoint(player, index)
	end)
end

---------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------
-- Shift is Sprint, so turn off Roblox's Shift-to-lock-mouse toggle.
game:GetService("StarterPlayer").EnableMouseLockOption = false

local function onPlayerAdded(player: Player)
	player.DevEnableMouseLock = false
	player.CharacterAdded:Connect(function()
		-- dying or respawning cancels a run in progress
		runs[player] = nil
		setRunAttributes(player)
		player:SetAttribute("PhoneOut", false)
	end)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	runs[player] = nil
	runCooldownUntil[player] = nil
	lastCall[player] = nil
end)

PlayerData.start()

---------------------------------------------------------------------------
-- Day / night (section 67). One full day every 20 minutes.
---------------------------------------------------------------------------
local DAY_LENGTH_SECONDS = 20 * 60
local lampsOn: boolean? = nil
RunService.Heartbeat:Connect(function(dt)
	Lighting.ClockTime = (Lighting.ClockTime + dt * 24 / DAY_LENGTH_SECONDS) % 24
	local night = Lighting.ClockTime < 6.3 or Lighting.ClockTime > 17.7
	if night ~= lampsOn then
		lampsOn = night
		for _, light in city.lamps do
			light.Enabled = night
			local head = light.Parent
			if head and head:IsA("BasePart") then
				head.Material = if night then Enum.Material.Neon else Enum.Material.SmoothPlastic
			end
		end
	end
end)
]=====])
put(server, 'ModuleScript', 'PlayerData', [=====[
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
]=====])
put(server, 'ModuleScript', 'CityBuilder', [=====[
-- CITY GRIND: builds District 1, The Neighborhood.
-- Runs once on the server when Workspace has no "City" model, so a place file
-- that already contains a hand-edited City is left alone.
--
-- Layout (top-down, +x east, +z south):
--   Main road along x (z = 0), cross road along z (x = 0), sidewalks on both.
--   NW: Starter apartments, park + playground    NE: Outdoor court, Iron Box gym, subway
--   SW: Corner Mart, Fresh Cuts barber, Threads  SE: Mama's Kitchen, Budget Wheels lot

local Lighting = game:GetService("Lighting")

local CityBuilder = {}

local ROAD_W = 32
local WALK_W = 8
local GROUND_X = 600
local GROUND_Z = 460

local city: Model
local folders: { [string]: Folder } = {}

local function folder(name: string): Folder
	if not folders[name] then
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = city
		folders[name] = f
	end
	return folders[name]
end

type PartProps = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	shape: Enum.PartType?,
	parent: Instance?,
}

local function part(p: PartProps): BasePart
	local b = Instance.new("Part")
	b.Name = p.name or "Part"
	b.Anchored = true
	b.Size = p.size
	b.CFrame = p.cframe
	b.Color = p.color or Color3.fromRGB(160, 160, 160)
	b.Material = p.material or Enum.Material.SmoothPlastic
	b.Transparency = p.transparency or 0
	b.CanCollide = if p.collide == nil then true else p.collide
	if p.shape then
		b.Shape = p.shape
	end
	b.TopSurface = Enum.SurfaceType.Smooth
	b.BottomSurface = Enum.SurfaceType.Smooth
	b.Parent = p.parent or city
	return b
end

local function sign(target: BasePart, face: Enum.NormalId, text: string, textColor: Color3, bg: Color3?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bg or Color3.new(0, 0, 0)
	label.BackgroundTransparency = if bg then 0 else 1
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui
	return gui
end

-- Marks a spot the phone's Map app can navigate to.
local function mapPoint(name: string, category: string, position: Vector3)
	local p = part({
		name = name,
		size = Vector3.new(1, 1, 1),
		cframe = CFrame.new(position),
		transparency = 1,
		collide = false,
		parent = folder("MapPoints"),
	})
	p.CanQuery = false
	p.CanTouch = false
	p:SetAttribute("Category", category)
end

-- A solid building with floors of windows on the side facing the road.
-- facing = 1 means the front is on the +z side, -1 means -z.
local function building(opts: {
	name: string,
	center: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	facing: number,
	signText: string,
	signColor: Color3,
	category: string,
	floorHeight: number?,
})
	local model = Instance.new("Model")
	model.Name = opts.name
	model.Parent = folder("Buildings")

	local s = opts.size
	local base = opts.center + Vector3.new(0, s.Y / 2, 0)
	part({ name = "Body", size = s, cframe = CFrame.new(base), color = opts.color, material = opts.material or Enum.Material.Brick, parent = model })
	part({
		name = "RoofTrim",
		size = Vector3.new(s.X + 1, 1, s.Z + 1),
		cframe = CFrame.new(base + Vector3.new(0, s.Y / 2 + 0.5, 0)),
		color = Color3.fromRGB(60, 60, 66),
		material = Enum.Material.Concrete,
		parent = model,
	})

	local frontZ = opts.center.Z + opts.facing * (s.Z / 2 + 0.1)
	local floorH = opts.floorHeight or 12
	local floors = math.max(1, math.floor(s.Y / floorH))
	for f = 1, floors do
		local y = opts.center.Y + (f - 1) * floorH
		if f == 1 then
			-- door + shop window on the ground floor
			part({
				name = "Door",
				size = Vector3.new(6, 9, 0.4),
				cframe = CFrame.new(opts.center.X, y + 4.5, frontZ),
				color = Color3.fromRGB(45, 35, 30),
				material = Enum.Material.Wood,
				parent = model,
			})
			local shopWindow = math.min(s.X - 16, 24)
			if shopWindow > 4 then
				for _, side in { -1, 1 } do
					part({
						name = "ShopWindow",
						size = Vector3.new(shopWindow / 2, 6, 0.3),
						cframe = CFrame.new(opts.center.X + side * (3 + shopWindow / 4 + 2), y + 4.5, frontZ),
						color = Color3.fromRGB(150, 200, 230),
						material = Enum.Material.Glass,
						transparency = 0.35,
						parent = model,
					})
				end
			end
		else
			local count = math.floor((s.X - 6) / 8)
			for i = 1, count do
				local x = opts.center.X - (count - 1) * 4 + (i - 1) * 8
				part({
					name = "Window",
					size = Vector3.new(5, 6, 0.3),
					cframe = CFrame.new(x, y + floorH / 2, frontZ),
					color = Color3.fromRGB(140, 190, 225),
					material = Enum.Material.Glass,
					transparency = 0.2,
					parent = model,
				})
			end
		end
	end

	local board = part({
		name = "Sign",
		size = Vector3.new(math.min(s.X - 4, 28), 3.5, 0.6),
		cframe = CFrame.new(opts.center.X, opts.center.Y + 11, frontZ + opts.facing * 0.3),
		color = Color3.fromRGB(20, 20, 24),
		parent = model,
	})
	if opts.facing == 1 then
		-- a part's Front face points -z, so turn the board around to face +z
		board.CFrame *= CFrame.Angles(0, math.pi, 0)
	end
	sign(board, Enum.NormalId.Front, opts.signText, opts.signColor)

	mapPoint(opts.name, opts.category, Vector3.new(opts.center.X, 3, frontZ + opts.facing * 6))
	return model
end

local function tree(position: Vector3, parent: Instance)
	local h = 10 + math.random() * 6
	part({ name = "Trunk", size = Vector3.new(h, 1.6, 1.6), cframe = CFrame.new(position + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(100, 70, 45), material = Enum.Material.Wood, shape = Enum.PartType.Cylinder, parent = parent })
	local r = 9 + math.random() * 4
	part({ name = "Leaves", size = Vector3.new(r, r, r), cframe = CFrame.new(position + Vector3.new(0, h + r * 0.3, 0)), color = Color3.fromRGB(60, 140 + math.random(0, 40), 60), material = Enum.Material.Grass, shape = Enum.PartType.Ball, parent = parent })
end

local function bench(cf: CFrame, parent: Instance)
	local seat = Instance.new("Seat")
	seat.Name = "Bench"
	seat.Anchored = true
	seat.Size = Vector3.new(6, 0.6, 2)
	seat.CFrame = cf * CFrame.new(0, 1.8, 0)
	seat.Color = Color3.fromRGB(130, 90, 55)
	seat.Material = Enum.Material.WoodPlanks
	seat.Parent = parent
	part({ name = "BenchBack", size = Vector3.new(6, 2, 0.4), cframe = cf * CFrame.new(0, 3, 0.9), color = Color3.fromRGB(130, 90, 55), material = Enum.Material.WoodPlanks, parent = parent })
	for _, x in { -2.5, 2.5 } do
		part({ name = "Leg", size = Vector3.new(0.4, 1.6, 1.8), cframe = cf * CFrame.new(x, 0.8, 0), color = Color3.fromRGB(40, 40, 40), material = Enum.Material.Metal, parent = parent })
	end
end

local function hoop(baseline: Vector3, dir: number, parent: Instance)
	-- dir = +1 means the hoop faces +z (it sits at the -z end of the court)
	local pole = baseline + Vector3.new(0, 0, -dir * 3)
	local polePart = part({ name = "HoopPole", size = Vector3.new(0.8, 12, 0.8), cframe = CFrame.new(pole + Vector3.new(0, 6, 0)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = parent })
	part({ name = "HoopArm", size = Vector3.new(0.6, 0.6, 3.5), cframe = CFrame.new(pole + Vector3.new(0, 11.5, dir * 1.75)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = parent })
	local board = pole + Vector3.new(0, 11.5, dir * 3.5)
	part({ name = "Backboard", size = Vector3.new(7, 4.2, 0.3), cframe = CFrame.new(board), color = Color3.new(1, 1, 1), material = Enum.Material.Glass, transparency = 0.3, parent = parent })
	part({ name = "BoardSquare", size = Vector3.new(2.4, 1.8, 0.32), cframe = CFrame.new(board + Vector3.new(0, -0.6, 0)), color = Color3.fromRGB(230, 60, 40), material = Enum.Material.SmoothPlastic, transparency = 0.5, collide = false, parent = parent })
	local rimCenter = board + Vector3.new(0, -1.3, dir * 1.3)
	for i = 0, 11 do
		local a = i / 12 * math.pi * 2
		part({
			name = "Rim",
			size = Vector3.new(0.18, 0.18, 0.5),
			cframe = CFrame.new(rimCenter + Vector3.new(math.cos(a) * 0.95, 0, math.sin(a) * 0.95)) * CFrame.Angles(0, -a, 0),
			color = Color3.fromRGB(240, 90, 20),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	local rimMarker = Instance.new("Attachment")
	rimMarker.Name = "RimCenter"
	rimMarker.Parent = polePart
	rimMarker.WorldPosition = rimCenter
end

local function buildGround()
	local f = folder("Streets")
	part({ name = "Ground", size = Vector3.new(GROUND_X, 2, GROUND_Z), cframe = CFrame.new(0, -0.95, 0), color = Color3.fromRGB(86, 140, 70), material = Enum.Material.Grass, parent = f })
	-- roads
	part({ name = "MainRoad", size = Vector3.new(GROUND_X, 0.2, ROAD_W), cframe = CFrame.new(0, 0.1, 0), color = Color3.fromRGB(45, 45, 50), material = Enum.Material.Asphalt, parent = f })
	for _, side in { -1, 1 } do
		local len = GROUND_Z / 2 - ROAD_W / 2
		part({ name = "CrossRoad", size = Vector3.new(ROAD_W, 0.2, len), cframe = CFrame.new(0, 0.1, side * (ROAD_W / 2 + len / 2)), color = Color3.fromRGB(45, 45, 50), material = Enum.Material.Asphalt, parent = f })
	end
	-- lane dashes
	for x = -GROUND_X / 2 + 10, GROUND_X / 2 - 10, 20 do
		if math.abs(x) > ROAD_W / 2 + 4 then
			part({ name = "LaneMark", size = Vector3.new(8, 0.05, 0.6), cframe = CFrame.new(x, 0.23, 0), color = Color3.fromRGB(240, 200, 60), material = Enum.Material.SmoothPlastic, collide = false, parent = f })
		end
	end
	for z = -GROUND_Z / 2 + 10, GROUND_Z / 2 - 10, 20 do
		if math.abs(z) > ROAD_W / 2 + 4 then
			part({ name = "LaneMark", size = Vector3.new(0.6, 0.05, 8), cframe = CFrame.new(0, 0.23, z), color = Color3.fromRGB(240, 200, 60), material = Enum.Material.SmoothPlastic, collide = false, parent = f })
		end
	end
	-- crosswalk stripes on all four sides of the intersection
	for _, side in { -1, 1 } do
		for i = -6, 6 do
			part({ name = "Crosswalk", size = Vector3.new(1.4, 0.05, 6), cframe = CFrame.new(i * 2.4, 0.23, side * (ROAD_W / 2 + 4)), color = Color3.new(1, 1, 1), collide = false, parent = f })
			part({ name = "Crosswalk", size = Vector3.new(6, 0.05, 1.4), cframe = CFrame.new(side * (ROAD_W / 2 + 4), 0.23, i * 2.4), color = Color3.new(1, 1, 1), collide = false, parent = f })
		end
	end
	-- sidewalks (raised slightly, but low enough to walk onto)
	local walkColor = Color3.fromRGB(175, 175, 170)
	for _, side in { -1, 1 } do
		local edge = side * (ROAD_W / 2 + WALK_W / 2)
		local lenX = GROUND_X / 2 - ROAD_W / 2
		local lenZ = GROUND_Z / 2 - ROAD_W / 2 - WALK_W
		for _, s2 in { -1, 1 } do
			-- along the main road, stopping at the cross road
			part({ name = "Sidewalk", size = Vector3.new(lenX, 0.5, WALK_W), cframe = CFrame.new(s2 * (ROAD_W / 2 + lenX / 2), 0.25, edge), color = walkColor, material = Enum.Material.Concrete, parent = f })
			-- along the cross road, starting after the main road's sidewalk
			part({ name = "Sidewalk", size = Vector3.new(WALK_W, 0.5, lenZ), cframe = CFrame.new(edge, 0.25, s2 * (ROAD_W / 2 + WALK_W + lenZ / 2)), color = walkColor, material = Enum.Material.Concrete, parent = f })
		end
	end
end

local function buildStreetLamps()
	local f = folder("StreetLamps")
	for _, side in { -1, 1 } do
		local z = side * (ROAD_W / 2 + WALK_W - 0.6)
		for x = -GROUND_X / 2 + 40, GROUND_X / 2 - 40, 40 do
			if math.abs(x) > ROAD_W then
				local lamp = Instance.new("Model")
				lamp.Name = "StreetLamp"
				lamp.Parent = f
				part({ name = "Pole", size = Vector3.new(0.6, 16, 0.6), cframe = CFrame.new(x, 8, z), color = Color3.fromRGB(35, 35, 40), material = Enum.Material.Metal, parent = lamp })
				local head = part({ name = "Head", size = Vector3.new(1.6, 0.6, 3), cframe = CFrame.new(x, 16, z - side * 1.2), color = Color3.fromRGB(255, 240, 200), material = Enum.Material.Neon, parent = lamp })
				local light = Instance.new("SpotLight")
				light.Face = Enum.NormalId.Bottom
				light.Range = 40
				light.Angle = 110
				light.Brightness = 3
				light.Color = Color3.fromRGB(255, 225, 170)
				light.Parent = head
			end
		end
	end
end

local function buildCourt()
	local court = Instance.new("Model")
	court.Name = "NeighborhoodCourt"
	court.Parent = folder("Courts")
	local c = Vector3.new(100, 0, -110)
	local w, l = 44, 76
	part({ name = "CourtFloor", size = Vector3.new(w + 8, 0.4, l + 8), cframe = CFrame.new(c + Vector3.new(0, 0.2, 0)), color = Color3.fromRGB(40, 90, 150), material = Enum.Material.Concrete, parent = court })
	part({ name = "Paint", size = Vector3.new(w, 0.05, l), cframe = CFrame.new(c + Vector3.new(0, 0.42, 0)), color = Color3.fromRGB(200, 90, 50), material = Enum.Material.Concrete, collide = false, parent = court })
	local white = Color3.new(1, 1, 1)
	local function line(size: Vector3, offset: Vector3)
		part({ name = "Line", size = size, cframe = CFrame.new(c + offset + Vector3.new(0, 0.47, 0)), color = white, collide = false, parent = court })
	end
	line(Vector3.new(w, 0.04, 0.4), Vector3.new(0, 0, -l / 2))
	line(Vector3.new(w, 0.04, 0.4), Vector3.new(0, 0, l / 2))
	line(Vector3.new(0.4, 0.04, l), Vector3.new(-w / 2, 0, 0))
	line(Vector3.new(0.4, 0.04, l), Vector3.new(w / 2, 0, 0))
	line(Vector3.new(w, 0.04, 0.4), Vector3.new(0, 0, 0))
	for _, dir in { -1, 1 } do
		local endZ = dir * l / 2
		-- the key
		line(Vector3.new(12, 0.04, 0.4), Vector3.new(0, 0, endZ - dir * 15))
		line(Vector3.new(0.4, 0.04, 15), Vector3.new(-6, 0, endZ - dir * 7.5))
		line(Vector3.new(0.4, 0.04, 15), Vector3.new(6, 0, endZ - dir * 7.5))
		-- three point arc
		for i = 0, 20 do
			local a = i / 20 * math.pi
			local r = 19
			line(Vector3.new(1.2, 0.04, 0.4), Vector3.new(math.cos(a) * r, 0, endZ - dir * (4 + math.sin(a) * r)))
		end
		hoop(c + Vector3.new(0, 0, endZ), -dir, court)
	end
	-- center circle
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		line(Vector3.new(1.2, 0.04, 0.4), Vector3.new(math.cos(a) * 6, 0, math.sin(a) * 6))
	end
	-- chain-link fence with a gap on the road side
	local fenceColor = Color3.fromRGB(120, 125, 130)
	for _, side in { -1, 1 } do
		part({ name = "Fence", size = Vector3.new(0.3, 10, l + 8), cframe = CFrame.new(c + Vector3.new(side * (w / 2 + 4), 5, 0)), color = fenceColor, material = Enum.Material.DiamondPlate, transparency = 0.6, parent = court })
	end
	part({ name = "Fence", size = Vector3.new(w + 8, 10, 0.3), cframe = CFrame.new(c + Vector3.new(0, 5, -(l / 2 + 4))), color = fenceColor, material = Enum.Material.DiamondPlate, transparency = 0.6, parent = court })
	for _, side in { -1, 1 } do
		part({ name = "Fence", size = Vector3.new(w / 2 - 4, 10, 0.3), cframe = CFrame.new(c + Vector3.new(side * (w / 4 + 4), 5, l / 2 + 4)), color = fenceColor, material = Enum.Material.DiamondPlate, transparency = 0.6, parent = court })
	end
	-- spectator benches along the west fence (section 51)
	for i = -2, 2 do
		bench(CFrame.new(c + Vector3.new(-(w / 2 + 1.5), 0.4, i * 12)) * CFrame.Angles(0, -math.pi / 2, 0), court)
	end
	mapPoint("Neighborhood Court", "Court", c + Vector3.new(0, 3, l / 2 + 8))
end

local function buildPark()
	local park = Instance.new("Model")
	park.Name = "Park"
	park.Parent = folder("Parks")
	local c = Vector3.new(-200, 0, -120)
	part({ name = "Path", size = Vector3.new(6, 0.2, 140), cframe = CFrame.new(c + Vector3.new(0, 0.1, 30)), color = Color3.fromRGB(190, 170, 130), material = Enum.Material.Sand, parent = park })
	part({ name = "Path", size = Vector3.new(120, 0.2, 6), cframe = CFrame.new(c + Vector3.new(0, 0.1, 0)), color = Color3.fromRGB(190, 170, 130), material = Enum.Material.Sand, parent = park })
	part({ name = "Fountain", size = Vector3.new(3, 14, 14), cframe = CFrame.new(c + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(200, 200, 205), material = Enum.Material.Marble, shape = Enum.PartType.Cylinder, parent = park })
	part({ name = "Water", size = Vector3.new(0.4, 12, 12), cframe = CFrame.new(c + Vector3.new(0, 3.1, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(80, 160, 220), material = Enum.Material.Glass, transparency = 0.3, shape = Enum.PartType.Cylinder, collide = false, parent = park })
	local rng = Random.new(7)
	for _ = 1, 22 do
		local p = c + Vector3.new(rng:NextNumber(-60, 60), 0, rng:NextNumber(-60, 70))
		if math.abs(p.X - c.X) > 8 and math.abs(p.Z - c.Z) > 8 then
			tree(p, park)
		end
	end
	for _, x in { -20, 20 } do
		bench(CFrame.new(c + Vector3.new(x, 0, 5)), park)
		bench(CFrame.new(c + Vector3.new(x, 0, -5)) * CFrame.Angles(0, math.pi, 0), park)
	end
	-- playground
	local pg = c + Vector3.new(35, 0, 40)
	part({ name = "Mulch", size = Vector3.new(30, 0.3, 26), cframe = CFrame.new(pg + Vector3.new(0, 0.15, 0)), color = Color3.fromRGB(120, 80, 50), material = Enum.Material.Ground, parent = park })
	part({ name = "SlideTower", size = Vector3.new(6, 6, 6), cframe = CFrame.new(pg + Vector3.new(-8, 3, 0)), color = Color3.fromRGB(240, 200, 40), material = Enum.Material.Plastic, parent = park })
	part({ name = "Slide", size = Vector3.new(3, 0.4, 11), cframe = CFrame.new(pg + Vector3.new(-8, 3.1, 8.5)) * CFrame.Angles(math.rad(-30), 0, 0), color = Color3.fromRGB(230, 60, 60), material = Enum.Material.Plastic, parent = park })
	part({ name = "SlideStep", size = Vector3.new(3, 3, 3), cframe = CFrame.new(pg + Vector3.new(-8, 1.5, -4.5)), color = Color3.fromRGB(60, 120, 230), material = Enum.Material.Plastic, parent = park })
	part({ name = "SwingBar", size = Vector3.new(14, 0.6, 0.6), cframe = CFrame.new(pg + Vector3.new(7, 9, 0)), color = Color3.fromRGB(60, 120, 230), material = Enum.Material.Metal, parent = park })
	for _, x in { 0.5, 13.5 } do
		part({ name = "SwingPost", size = Vector3.new(0.6, 9, 0.6), cframe = CFrame.new(pg + Vector3.new(x, 4.5, 0)), color = Color3.fromRGB(60, 120, 230), material = Enum.Material.Metal, parent = park })
	end
	for _, x in { 4, 10 } do
		local seat = Instance.new("Seat")
		seat.Name = "Swing"
		seat.Anchored = true
		seat.Size = Vector3.new(2, 0.3, 1.2)
		seat.CFrame = CFrame.new(pg + Vector3.new(x, 2.5, 0))
		seat.Color = Color3.fromRGB(30, 30, 30)
		seat.Parent = park
	end
	mapPoint("City Park", "Park", c + Vector3.new(0, 3, 70))
end

-- Vending machine outside Corner Mart. The server handles the purchase.
local function buildVendingMachine(position: Vector3, facing: number): ProximityPrompt
	local m = Instance.new("Model")
	m.Name = "VendingMachine"
	m.Parent = folder("Interactables")
	local body = part({ name = "Body", size = Vector3.new(4, 7, 3), cframe = CFrame.new(position + Vector3.new(0, 3.5, 0)), color = Color3.fromRGB(200, 30, 40), material = Enum.Material.Metal, parent = m })
	local front = part({ name = "Front", size = Vector3.new(3.2, 4, 0.1), cframe = CFrame.new(position + Vector3.new(0, 4.2, facing * 1.55)), color = Color3.fromRGB(240, 240, 255), material = Enum.Material.Neon, parent = m })
	sign(front, if facing == -1 then Enum.NormalId.Front else Enum.NormalId.Back, "ENERGY\nDRINK\n$5", Color3.fromRGB(200, 30, 40))
	m.PrimaryPart = body
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Buy Energy Drink ($5)"
	prompt.ObjectText = "Vending Machine"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 8
	prompt.HoldDuration = 0.3
	prompt.RequiresLineOfSight = false
	prompt.Parent = body
	return prompt
end

local function buildBusStop(position: Vector3)
	local m = Instance.new("Model")
	m.Name = "BusStop"
	m.Parent = folder("Transit")
	part({ name = "Roof", size = Vector3.new(12, 0.4, 5), cframe = CFrame.new(position + Vector3.new(0, 8, 0)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	part({ name = "Back", size = Vector3.new(12, 7, 0.3), cframe = CFrame.new(position + Vector3.new(0, 4.3, 2.3)), color = Color3.fromRGB(180, 220, 240), material = Enum.Material.Glass, transparency = 0.5, parent = m })
	local post = part({ name = "SignPost", size = Vector3.new(0.4, 10, 0.4), cframe = CFrame.new(position + Vector3.new(-7, 5, -1)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	local plate = part({ name = "SignPlate", size = Vector3.new(3, 2, 0.2), cframe = CFrame.new(post.Position + Vector3.new(0, 4, -0.2)), color = Color3.fromRGB(30, 110, 200), parent = m })
	sign(plate, Enum.NormalId.Front, "BUS", Color3.new(1, 1, 1))
	bench(CFrame.new(position + Vector3.new(0, 0, 1.2)), m)
	mapPoint("Bus Stop", "Transit", position + Vector3.new(0, 3, -4))
end

local function buildSubwayEntrance(position: Vector3)
	local m = Instance.new("Model")
	m.Name = "SubwayEntrance"
	m.Parent = folder("Transit")
	part({ name = "Base", size = Vector3.new(14, 1, 12), cframe = CFrame.new(position + Vector3.new(0, 0.5, 0)), color = Color3.fromRGB(90, 90, 95), material = Enum.Material.Concrete, parent = m })
	part({ name = "Stairwell", size = Vector3.new(8, 1.1, 8), cframe = CFrame.new(position + Vector3.new(0, 0.55, 0)), color = Color3.fromRGB(10, 10, 12), material = Enum.Material.SmoothPlastic, parent = m })
	for _, x in { -5, 5 } do
		part({ name = "Rail", size = Vector3.new(0.4, 3, 9), cframe = CFrame.new(position + Vector3.new(x, 2.5, 0)), color = Color3.fromRGB(30, 140, 70), material = Enum.Material.Metal, parent = m })
	end
	local sTop = part({ name = "Sign", size = Vector3.new(12, 2.4, 0.4), cframe = CFrame.new(position + Vector3.new(0, 6, 5.8)), color = Color3.fromRGB(30, 140, 70), parent = m })
	sTop.CFrame = sTop.CFrame * CFrame.Angles(0, math.pi, 0)
	sign(sTop, Enum.NormalId.Front, "SUBWAY  NEIGHBORHOOD", Color3.new(1, 1, 1))
	for _, x in { -5.8, 5.8 } do
		part({ name = "SignPost", size = Vector3.new(0.4, 6, 0.4), cframe = CFrame.new(position + Vector3.new(x, 3, 5.8)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	end
	mapPoint("Subway Station", "Transit", position + Vector3.new(0, 3, 9))
end

local function buildDealership(center: Vector3)
	local m = Instance.new("Model")
	m.Name = "BudgetWheels"
	m.Parent = folder("Buildings")
	part({ name = "Lot", size = Vector3.new(90, 0.3, 70), cframe = CFrame.new(center + Vector3.new(0, 0.15, 0)), color = Color3.fromRGB(55, 55, 60), material = Enum.Material.Asphalt, parent = m })
	for i = -4, 4 do
		part({ name = "ParkingLine", size = Vector3.new(0.4, 0.05, 14), cframe = CFrame.new(center + Vector3.new(i * 9, 0.32, -6)), color = Color3.new(1, 1, 1), collide = false, parent = m })
	end
	building({
		name = "Budget Wheels",
		center = center + Vector3.new(0, 0, 24),
		size = Vector3.new(36, 14, 18),
		color = Color3.fromRGB(230, 230, 235),
		material = Enum.Material.Concrete,
		facing = -1,
		signText = "BUDGET WHEELS",
		signColor = Color3.fromRGB(255, 200, 40),
		category = "Shop",
	}).Parent = m
	-- pennant string across the lot entrance
	for i = 0, 11 do
		part({
			name = "Pennant",
			size = Vector3.new(1.2, 1.2, 0.1),
			cframe = CFrame.new(center + Vector3.new(-33 + i * 6, 10, -34)) * CFrame.Angles(0, 0, math.rad(45)),
			color = if i % 2 == 0 then Color3.fromRGB(230, 50, 50) else Color3.fromRGB(255, 220, 50),
			collide = false,
			parent = m,
		})
	end
end

-- The Neighborhood run route. Returns checkpoint trigger parts in order.
local RUN_ROUTE = {
	Vector3.new(-40, 0, -20),
	Vector3.new(240, 0, -20),
	Vector3.new(240, 0, 20),
	Vector3.new(-240, 0, 20),
	Vector3.new(-240, 0, -20),
}

local function buildRunRoute(): { BasePart }
	local f = folder("RunRoute")
	local triggers = {}
	for i, pos in RUN_ROUTE do
		local m = Instance.new("Model")
		m.Name = "Checkpoint" .. i
		m.Parent = f
		local alongX = i == 1 or i == 2 or i == 4 or i == 5
		local postOffset = if alongX then Vector3.new(0, 0, 5) else Vector3.new(5, 0, 0)
		local color = if i == 1 then Color3.fromRGB(60, 230, 110) else Color3.fromRGB(255, 170, 40)
		for _, s in { -1, 1 } do
			part({ name = "Post", size = Vector3.new(0.8, 10, 0.8), cframe = CFrame.new(pos + postOffset * s + Vector3.new(0, 5, 0)), color = color, material = Enum.Material.Neon, collide = false, parent = m })
		end
		local bar = part({
			name = "Banner",
			size = if alongX then Vector3.new(0.8, 2, 10.8) else Vector3.new(10.8, 2, 0.8),
			cframe = CFrame.new(pos + Vector3.new(0, 10, 0)),
			color = Color3.fromRGB(25, 25, 30),
			collide = false,
			parent = m,
		})
		local text = if i == 1 then "START / FINISH" else "CHECKPOINT " .. (i - 1)
		for _, face in (if alongX then { Enum.NormalId.Left, Enum.NormalId.Right } else { Enum.NormalId.Front, Enum.NormalId.Back }) do
			sign(bar, face, text, color)
		end
		local trigger = part({
			name = "Trigger",
			size = Vector3.new(12, 12, 12),
			cframe = CFrame.new(pos + Vector3.new(0, 6, 0)),
			transparency = 1,
			collide = false,
			parent = m,
		})
		trigger.CanQuery = false
		trigger:SetAttribute("CheckpointIndex", i)
		table.insert(triggers, trigger)
	end
	mapPoint("Run Route Start", "Fitness", RUN_ROUTE[1] + Vector3.new(0, 3, 0))
	return triggers
end

local function buildLighting()
	Lighting.ClockTime = 9
	Lighting.Brightness = 2.2
	Lighting.Ambient = Color3.fromRGB(70, 70, 80)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 130)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.6
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.3
		atmosphere.Haze = 1.2
		atmosphere.Color = Color3.fromRGB(200, 190, 180)
		atmosphere.Decay = Color3.fromRGB(110, 100, 120)
		atmosphere.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("BloomEffect") then
		local bloom = Instance.new("BloomEffect")
		bloom.Intensity = 0.6
		bloom.Size = 30
		bloom.Threshold = 1.6
		bloom.Parent = Lighting
	end
end

export type CityHandles = {
	city: Model,
	vendingPrompt: ProximityPrompt?,
	runTriggers: { BasePart },
	lamps: { Light },
}

function CityBuilder.build(): CityHandles
	local existing = workspace:FindFirstChild("City")
	if existing and existing:IsA("Model") then
		-- Reuse a City someone already built or edited by hand.
		city = existing
		local triggers = {}
		local runRoute = city:FindFirstChild("RunRoute")
		if runRoute then
			for _, d in runRoute:GetDescendants() do
				if d:IsA("BasePart") and d:GetAttribute("CheckpointIndex") then
					triggers[d:GetAttribute("CheckpointIndex")] = d
				end
			end
		end
		local prompt = city:FindFirstChild("ProximityPrompt", true)
		local lamps = {}
		for _, d in city:GetDescendants() do
			if d:IsA("SpotLight") then
				table.insert(lamps, d)
			end
		end
		return { city = city, vendingPrompt = prompt :: ProximityPrompt?, runTriggers = triggers, lamps = lamps }
	end

	city = Instance.new("Model")
	city.Name = "City"
	city.Parent = workspace
	table.clear(folders)

	buildLighting()
	buildGround()
	buildStreetLamps()

	building({ name = "Starter Apartments", center = Vector3.new(-100, 0, -85), size = Vector3.new(70, 36, 40), color = Color3.fromRGB(170, 95, 70), facing = 1, signText = "MAPLE COURT APTS", signColor = Color3.fromRGB(255, 230, 180), category = "Home" })
	building({ name = "Iron Box Gym", center = Vector3.new(205, 0, -75), size = Vector3.new(60, 24, 40), color = Color3.fromRGB(70, 70, 78), material = Enum.Material.Concrete, facing = 1, signText = "IRON BOX GYM", signColor = Color3.fromRGB(255, 80, 60), category = "Gym" })
	building({ name = "Corner Mart", center = Vector3.new(-70, 0, 62), size = Vector3.new(40, 16, 30), color = Color3.fromRGB(235, 225, 200), material = Enum.Material.Concrete, facing = -1, signText = "CORNER MART", signColor = Color3.fromRGB(60, 200, 90), category = "Shop" })
	building({ name = "Fresh Cuts Barber", center = Vector3.new(-125, 0, 60), size = Vector3.new(30, 14, 26), color = Color3.fromRGB(60, 90, 160), facing = -1, signText = "FRESH CUTS", signColor = Color3.fromRGB(255, 255, 255), category = "Shop" })
	building({ name = "Threads Clothing", center = Vector3.new(-185, 0, 62), size = Vector3.new(44, 18, 30), color = Color3.fromRGB(40, 40, 46), material = Enum.Material.Concrete, facing = -1, signText = "THREADS", signColor = Color3.fromRGB(255, 120, 200), category = "Shop" })
	building({ name = "Mama's Kitchen", center = Vector3.new(70, 0, 62), size = Vector3.new(40, 16, 30), color = Color3.fromRGB(190, 70, 50), facing = -1, signText = "MAMA'S KITCHEN", signColor = Color3.fromRGB(255, 220, 120), category = "Food" })

	buildCourt()
	buildPark()
	buildDealership(Vector3.new(190, 0, 85))
	buildBusStop(Vector3.new(-35, 0, 32))
	buildSubwayEntrance(Vector3.new(40, 0, -45))
	local vendingPrompt = buildVendingMachine(Vector3.new(-45, 0, 44), -1)
	mapPoint("Vending Machine", "Shop", Vector3.new(-45, 3, 40))
	local runTriggers = buildRunRoute()

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ApartmentSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(-100, 0.5, -55) * CFrame.Angles(0, math.pi, 0)
	spawn.Color = Color3.fromRGB(170, 95, 70)
	spawn.Material = Enum.Material.Concrete
	spawn.Duration = 0
	spawn.Parent = city
	-- Everyone starts outside their apartment, not on a template's default spawn.
	for _, d in workspace:GetDescendants() do
		if d:IsA("SpawnLocation") and d ~= spawn then
			d.Enabled = false
		end
	end

	local lamps = {}
	for _, d in city:GetDescendants() do
		if d:IsA("SpotLight") then
			table.insert(lamps, d)
		end
	end

	return { city = city, vendingPrompt = vendingPrompt, runTriggers = runTriggers, lamps = lamps }
end

CityBuilder.RUN_ROUTE = RUN_ROUTE

return CityBuilder
]=====])
local client = put(SPS, 'LocalScript', 'CityGrindClient', [=====[
-- CITY GRIND: client entry point (StarterPlayerScripts.CityGrindClient).

local Players = game:GetService("Players")

local Movement = require(script:WaitForChild("Movement"))
local HUD = require(script:WaitForChild("HUD"))
local Phone = require(script:WaitForChild("Phone"))

local player = Players.LocalPlayer

Movement.start()
HUD.start()
Phone.start()

-- Wait for the server to hand over this player's save before welcoming them.
if not player:GetAttribute("DataLoaded") then
	player:GetAttributeChangedSignal("DataLoaded"):Wait()
end
HUD.push("WELCOME TO THE NEIGHBORHOOD", "Press P for your phone. Run the route by your apartment to earn cash.")
]=====])
put(client, 'ModuleScript', 'UI', [=====[
-- CITY GRIND: tiny helpers for building UI in code.

local UI = {}

UI.FONT = Enum.Font.GothamMedium
UI.FONT_BOLD = Enum.Font.GothamBold
UI.FONT_BLACK = Enum.Font.GothamBlack

UI.colors = {
	panel = Color3.fromRGB(18, 18, 24),
	panelLight = Color3.fromRGB(34, 34, 44),
	text = Color3.fromRGB(240, 240, 245),
	subtext = Color3.fromRGB(160, 160, 175),
	cash = Color3.fromRGB(110, 230, 120),
	xp = Color3.fromRGB(90, 170, 255),
	stamina = Color3.fromRGB(255, 200, 60),
	danger = Color3.fromRGB(255, 90, 90),
	accent = Color3.fromRGB(255, 120, 60),
}

-- UI.new("Frame", { Size = ..., Parent = ... }, { children })
function UI.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
	end
	local parent
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			(inst :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function UI.corner(radius: number): UICorner
	return UI.new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

function UI.padding(px: number): UIPadding
	return UI.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

function UI.stroke(color: Color3, thickness: number, transparency: number?): UIStroke
	return UI.new("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function UI.label(props: { [string]: any }): TextLabel
	local defaults = {
		BackgroundTransparency = 1,
		Font = UI.FONT,
		TextColor3 = UI.colors.text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do
		defaults[k] = v
	end
	return UI.new("TextLabel", defaults)
end

function UI.button(props: { [string]: any }): TextButton
	local defaults = {
		BackgroundColor3 = UI.colors.panelLight,
		Font = UI.FONT_BOLD,
		TextColor3 = UI.colors.text,
		TextSize = 16,
		AutoButtonColor = true,
	}
	for k, v in props do
		defaults[k] = v
	end
	local b = UI.new("TextButton", defaults)
	UI.corner(10).Parent = b
	return b
end

-- A horizontal progress bar. Returns the outer frame and a setter.
function UI.bar(props: { [string]: any }, fillColor: Color3): (Frame, (number) -> ())
	local outer = UI.new("Frame", props)
	if not props.BackgroundColor3 then
		outer.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	end
	UI.corner(6).Parent = outer
	local fill = UI.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor,
		Size = UDim2.fromScale(0, 1),
		Parent = outer,
	}, { UI.corner(6) })
	return outer, function(fraction: number)
		fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	end
end

function UI.formatCash(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return (if n < 0 then "-$" else "$") .. formatted
end

function UI.formatClock(clockTime: number): string
	local hours = math.floor(clockTime)
	local minutes = math.floor((clockTime - hours) * 60)
	local suffix = if hours >= 12 then "PM" else "AM"
	local h12 = hours % 12
	if h12 == 0 then
		h12 = 12
	end
	return string.format("%d:%02d %s", h12, minutes, suffix)
end

function UI.timeAgo(timestamp: number): string
	local diff = math.max(0, os.time() - timestamp)
	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		return math.floor(diff / 60) .. "m ago"
	elseif diff < 86400 then
		return math.floor(diff / 3600) .. "h ago"
	end
	return math.floor(diff / 86400) .. "d ago"
end

return UI
]=====])
put(client, 'ModuleScript', 'Movement', [=====[
-- CITY GRIND: sprint, stamina, crouch and slide (section 12).
-- PC: Shift sprint, C crouch (C while sprinting = slide).
-- Mobile: on-screen Sprint (toggle) and Crouch buttons. Controller: L3 sprint, R3 crouch.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))
local remotes = ReplicatedStorage.CityGrind:WaitForChild("Remotes")

local player = Players.LocalPlayer

local Movement = {}

local stamina = 100
local exhausted = false
local wantSprint = false
local crouching = false
local slidingUntil = 0
local humanoid: Humanoid? = nil
local lastJumpState = false

local function statValue(name: string): number
	return player:GetAttribute(name) or 1
end

function Movement.maxStamina(): number
	return Config.maxStamina(statValue("Stamina"))
end

function Movement.getStamina(): (number, number, boolean)
	return stamina, Movement.maxStamina(), exhausted
end

function Movement.isSprinting(): boolean
	return humanoid ~= nil and humanoid.WalkSpeed >= Config.SPRINT_SPEED - 0.1
end

local function setCameraOffset(y: number)
	if humanoid then
		TweenService:Create(humanoid, TweenInfo.new(0.18), { CameraOffset = Vector3.new(0, y, 0) }):Play()
	end
end

local function setCrouch(on: boolean)
	if crouching == on then
		return
	end
	crouching = on
	setCameraOffset(if on then -1.6 else 0)
end

local function trySlide(): boolean
	if not humanoid or os.clock() < slidingUntil then
		return false
	end
	if humanoid.MoveDirection.Magnitude < 0.1 or humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	if stamina < Config.SLIDE_COST then
		return false
	end
	stamina -= Config.SLIDE_COST
	slidingUntil = os.clock() + Config.SLIDE_SECONDS
	setCameraOffset(-2)
	task.delay(Config.SLIDE_SECONDS, function()
		setCameraOffset(if crouching then -1.6 else 0)
	end)
	return true
end

local function onSprint(_, state: Enum.UserInputState, input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		if state == Enum.UserInputState.Begin then
			wantSprint = not wantSprint -- toggle on mobile
		end
	elseif state == Enum.UserInputState.Begin then
		wantSprint = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		wantSprint = false
	end
	return Enum.ContextActionResult.Pass
end

local function onCrouch(_, state: Enum.UserInputState)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if Movement.isSprinting() and trySlide() then
		return Enum.ContextActionResult.Sink
	end
	setCrouch(not crouching)
	if crouching then
		wantSprint = false
	end
	return Enum.ContextActionResult.Sink
end

local function bindCharacter(character: Model)
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	crouching = false
	slidingUntil = 0
	stamina = Movement.maxStamina()
	exhausted = false
	local h = humanoid :: Humanoid
	h.WalkSpeed = Config.WALK_SPEED
	h.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping and not lastJumpState then
			stamina = math.max(0, stamina - 4)
		end
		lastJumpState = new == Enum.HumanoidStateType.Jumping
	end)
end

function Movement.start()
	ContextActionService:BindAction("CitySprint", onSprint, true, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle("CitySprint", "Sprint")
	ContextActionService:SetPosition("CitySprint", UDim2.new(1, -170, 1, -150))
	ContextActionService:BindAction("CityCrouch", onCrouch, true, Enum.KeyCode.C, Enum.KeyCode.ButtonR3)
	ContextActionService:SetTitle("CityCrouch", "Crouch")
	ContextActionService:SetPosition("CityCrouch", UDim2.new(1, -230, 1, -95))

	remotes:WaitForChild("StaminaRefill").OnClientEvent:Connect(function()
		stamina = Movement.maxStamina()
		exhausted = false
	end)

	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
	player.CharacterAdded:Connect(bindCharacter)

	RunService.Heartbeat:Connect(function(dt)
		local h = humanoid
		if not h or h.Health <= 0 then
			return
		end
		local maxS = Movement.maxStamina()
		local moving = h.MoveDirection.Magnitude > 0.1
		local sliding = os.clock() < slidingUntil
		local canSprint = wantSprint and moving and not crouching and not exhausted and not UserInputService:GetFocusedTextBox()

		local speed
		if sliding then
			speed = Config.SLIDE_SPEED
		elseif canSprint then
			speed = Config.SPRINT_SPEED
			-- Better Speed stat makes sprinting cheaper (movement efficiency).
			local efficiency = 1 - (statValue("Speed") - 1) / 200
			stamina -= Config.SPRINT_DRAIN_PER_SEC * efficiency * dt
			if stamina <= 0 then
				stamina = 0
				exhausted = true
			end
		elseif crouching then
			speed = Config.CROUCH_SPEED
		else
			speed = Config.WALK_SPEED
		end

		if not canSprint and not sliding then
			local regen = Config.staminaRegen(statValue("Stamina"))
			if not moving then
				regen *= 1.5
			end
			stamina = math.min(maxS, stamina + regen * dt)
			if exhausted and stamina >= Config.MIN_SPRINT_STAMINA * 2 then
				exhausted = false
			end
		end
		stamina = math.min(stamina, maxS)
		h.WalkSpeed = speed
	end)
end

return Movement
]=====])
put(client, 'ModuleScript', 'HUD', [=====[
-- CITY GRIND: on-screen HUD. Cash, level/XP, reputation rank, stamina,
-- run tracker and notification toasts. Every number shown here is read from
-- server-owned Player attributes; the client never decides them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UI = require(script.Parent:WaitForChild("UI"))
local Movement = require(script.Parent:WaitForChild("Movement"))
local remotes = ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Remotes")

local player = Players.LocalPlayer
local colors = UI.colors

local HUD = {}

-- Notification store shared with the phone.
HUD.notifications = {} :: { { title: string, body: string, time: number } }
HUD.notificationAdded = Instance.new("BindableEvent")
HUD.unread = 0

local gui: ScreenGui
local toastHolder: Frame
local notifySound: Sound

local function toast(title: string, body: string)
	local card = UI.new("Frame", {
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.08,
		Size = UDim2.new(1, 0, 0, 58),
		Parent = toastHolder,
	}, {
		UI.corner(12),
		UI.stroke(colors.accent, 1.5, 0.3),
		UI.padding(10),
		UI.label({ Text = title, Font = UI.FONT_BLACK, TextSize = 15, TextColor3 = colors.accent, Size = UDim2.new(1, 0, 0, 16) }),
		UI.label({ Text = body, TextSize = 14, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 20), TextTruncate = Enum.TextTruncate.AtEnd }),
	})
	card.Position = UDim2.fromOffset(0, -10)
	task.delay(4, function()
		local fade = TweenService:Create(card, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
		for _, d in card:GetDescendants() do
			if d:IsA("TextLabel") then
				TweenService:Create(d, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
			elseif d:IsA("UIStroke") then
				TweenService:Create(d, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			end
		end
		fade:Play()
		fade.Completed:Wait()
		card:Destroy()
	end)
end

function HUD.push(title: string, body: string)
	table.insert(HUD.notifications, 1, { title = title, body = body, time = os.time() })
	if #HUD.notifications > 50 then
		table.remove(HUD.notifications)
	end
	HUD.unread += 1
	toast(title, body)
	if player:GetAttribute("NotificationSounds") ~= false then
		notifySound:Play()
	end
	HUD.notificationAdded:Fire()
end

function HUD.markRead()
	HUD.unread = 0
	HUD.notificationAdded:Fire()
end

function HUD.setVisible(visible: boolean)
	gui.Enabled = visible
end

local function buildStatsCard()
	local card = UI.new("Frame", {
		Name = "Stats",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(230, 92),
		Parent = gui,
	}, { UI.corner(14), UI.padding(10) })

	local cash = UI.label({ Text = "$0", Font = UI.FONT_BLACK, TextSize = 24, TextColor3 = colors.cash, Size = UDim2.new(1, -60, 0, 26), Parent = card })
	local level = UI.new("TextLabel", {
		BackgroundColor3 = colors.xp,
		Text = "LV 1",
		Font = UI.FONT_BLACK,
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 2),
		Size = UDim2.fromOffset(54, 22),
		Parent = card,
	}, { UI.corner(11) })
	local _, setXP = UI.bar({ Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 8), Parent = card }, colors.xp)
	local xpText = UI.label({ Text = "0 / 100 XP", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 14), Parent = card })
	local rank = UI.label({ Text = "Nobody", Font = UI.FONT_BOLD, TextSize = 14, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 16), Parent = card })

	local shownCash: number? = nil
	local function refresh()
		local newCash = player:GetAttribute("Cash") or 0
		if not player:GetAttribute("DataLoaded") then
			return
		end
		if newCash ~= shownCash then
			if shownCash then
				local diff = newCash - shownCash
				local pop = UI.label({
					Text = (if diff > 0 then "+" else "") .. UI.formatCash(diff),
					Font = UI.FONT_BLACK,
					TextSize = 18,
					TextColor3 = if diff > 0 then colors.cash else colors.danger,
					Position = UDim2.fromOffset(250, 14),
					Size = UDim2.fromOffset(120, 24),
					Parent = gui,
				})
				TweenService:Create(pop, TweenInfo.new(1.2), { Position = UDim2.fromOffset(250, -10), TextTransparency = 1 }):Play()
				task.delay(1.3, pop.Destroy, pop)
			end
			shownCash = newCash
		end
		cash.Text = UI.formatCash(newCash)
		local lv = player:GetAttribute("Level") or 1
		level.Text = "LV " .. lv
		local xp = player:GetAttribute("XP") or 0
		local toNext = player:GetAttribute("XPToNext") or 100
		setXP(if lv >= 100 then 1 else xp / toNext)
		xpText.Text = if lv >= 100 then "MAX LEVEL" else string.format("%d / %d XP", xp, toNext)
		rank.Text = string.format("%s  ·  %d rep", player:GetAttribute("Rank") or "Nobody", player:GetAttribute("Reputation") or 0)
	end
	for _, attr in { "Cash", "Level", "XP", "XPToNext", "Rank", "Reputation", "DataLoaded" } do
		player:GetAttributeChangedSignal(attr):Connect(refresh)
	end
	refresh()
end

local function buildStaminaBar()
	local holder = UI.new("Frame", {
		Name = "Stamina",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(260, 22),
		Parent = gui,
	})
	UI.label({ Text = "STAMINA", Font = UI.FONT_BLACK, TextSize = 11, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 12), Parent = holder })
	local bar, setFill = UI.bar({ Position = UDim2.fromOffset(0, 13), Size = UDim2.new(1, 0, 0, 9), Parent = holder }, colors.stamina)
	local fill = bar:FindFirstChild("Fill") :: Frame
	RunService.RenderStepped:Connect(function()
		local s, maxS, exhausted = Movement.getStamina()
		setFill(s / maxS)
		fill.BackgroundColor3 = if exhausted then colors.danger else colors.stamina
		holder.Visible = s < maxS - 0.5 or Movement.isSprinting()
	end)
end

-- Shows the run timer and highlights the next checkpoint arch.
local function buildRunTracker()
	local panel = UI.new("Frame", {
		Name = "RunTracker",
		BackgroundColor3 = colors.panel,
		BackgroundTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(220, 54),
		Visible = false,
		Parent = gui,
	}, { UI.corner(12), UI.padding(8) })
	local timer = UI.label({ Text = "0.0s", Font = UI.FONT_BLACK, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 22), Parent = panel })
	local nextLabel = UI.label({ Text = "", TextSize = 13, TextColor3 = colors.stamina, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 0, 14), Parent = panel })

	local highlight = Instance.new("Highlight")
	highlight.FillColor = colors.stamina
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.4
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = gui

	local function refresh()
		local nextIndex = player:GetAttribute("RunNext") or 0
		panel.Visible = nextIndex > 0
		local route = workspace:FindFirstChild("City") and workspace.City:FindFirstChild("RunRoute")
		if nextIndex == 0 or not route then
			highlight.Adornee = nil
			return
		end
		local count = #route:GetChildren()
		local target = if nextIndex > count then 1 else nextIndex
		highlight.Adornee = route:FindFirstChild("Checkpoint" .. target)
		nextLabel.Text = if target == 1 then "Head back to the FINISH" else "Next: Checkpoint " .. (target - 1)
	end
	player:GetAttributeChangedSignal("RunNext"):Connect(refresh)
	refresh()

	RunService.RenderStepped:Connect(function()
		if panel.Visible then
			local started = player:GetAttribute("RunStartedAt") or 0
			timer.Text = string.format("%.1fs", workspace:GetServerTimeNow() - started)
		end
	end)
end

local function buildControlsHint()
	if not UserInputService.KeyboardEnabled then
		return
	end
	UI.label({
		Text = "P Phone   ·   Shift Sprint   ·   C Crouch / Slide   ·   E Interact",
		TextSize = 13,
		TextColor3 = colors.subtext,
		TextStrokeTransparency = 0.6,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -10),
		Size = UDim2.fromOffset(500, 16),
		Parent = gui,
	})
end

function HUD.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	notifySound = UI.new("Sound", { SoundId = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Parent = SoundService })

	toastHolder = UI.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 76),
		Size = UDim2.fromOffset(320, 300),
		Parent = gui,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	buildStatsCard()
	buildStaminaBar()
	buildRunTracker()
	buildControlsHint()

	remotes:WaitForChild("Notify").OnClientEvent:Connect(function(title: string, body: string)
		if type(title) == "string" and type(body) == "string" then
			HUD.push(title, body)
		end
	end)
end

return HUD
]=====])
put(client, 'ModuleScript', 'Phone', [=====[
-- CITY GRIND: the phone (sections 15, 16). P / DPad-Up / on-screen button.
-- Taking it out tells the server, which puts a phone in your character's hand.
--
-- Phase 1 ships the apps that fully work today: Profile, Bank, Map (with GPS),
-- Alerts and Settings. Messages, Calls, Camera, CityTok, CityGram and the rest
-- are added to the home screen as each one is built for real (section 118).

local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UI = require(script.Parent:WaitForChild("UI"))
local HUD = require(script.Parent:WaitForChild("HUD"))
local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local remotes = shared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local colors = UI.colors

local Phone = {}

local PHONE_W, PHONE_H = 300, 620
local SCREEN_INSET = 10

local gui: ScreenGui
local phoneFrame: Frame
local uiScale: UIScale
local screen: Frame
local wallpaperGradient: UIGradient
local pages: { [string]: { frame: Frame, open: (() -> ())? } } = {}
local currentPage = "Home"
local isOpen = false
local battery = 100
local badge: TextLabel

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function applyWallpaper()
	local index = player:GetAttribute("Wallpaper") or 1
	local wp = Config.WALLPAPERS[index] or Config.WALLPAPERS[1]
	wallpaperGradient.Color = ColorSequence.new(wp.top, wp.bottom)
end

local function applyScale()
	local camera = Workspace.CurrentCamera
	local viewportH = if camera then camera.ViewportSize.Y else 800
	local fit = math.min(1, (viewportH - 40) / (PHONE_H + 20))
	uiScale.Scale = fit * (player:GetAttribute("UIScale") or 1)
end

local function showPage(name: string)
	for pageName, page in pages do
		page.frame.Visible = pageName == name
	end
	currentPage = name
	local page = pages[name]
	if page and page.open then
		task.spawn(page.open)
	end
end

-- Builds an app page with a header and scrolling content list.
local function appPage(name: string, title: string): (Frame, ScrollingFrame)
	local frame = UI.new("Frame", {
		Name = name,
		BackgroundColor3 = Color3.fromRGB(14, 14, 20),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = screen,
	})
	local header = UI.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 40),
		Parent = frame,
	})
	local back = UI.button({
		Text = "‹ Home",
		TextSize = 15,
		BackgroundTransparency = 1,
		TextColor3 = colors.xp,
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.fromOffset(70, 32),
		Parent = header,
	})
	back.Activated:Connect(function()
		showPage("Home")
	end)
	UI.label({
		Text = title,
		Font = UI.FONT_BLACK,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = header,
	})
	local content = UI.new("ScrollingFrame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 76),
		Size = UDim2.new(1, 0, 1, -104),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		UI.new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 12) }),
	})
	pages[name] = { frame = frame }
	return frame, content
end

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function card(parent: Instance, height: number, order: number): Frame
	return UI.new("Frame", {
		BackgroundColor3 = colors.panelLight,
		Size = UDim2.new(1, -20, 0, height),
		LayoutOrder = order,
		Parent = parent,
	}, { UI.corner(14), UI.padding(12) })
end

local function fetchProfile()
	local ok, result = pcall(function()
		return remotes.GetProfile:InvokeServer()
	end)
	return if ok then result else nil
end

---------------------------------------------------------------------------
-- Profile app
---------------------------------------------------------------------------
local function buildProfile()
	local _, content = appPage("Profile", "Profile")
	pages.Profile.open = function()
		clear(content)
		local data = fetchProfile()
		if not data then
			UI.label({ Text = "Profile is still loading...", TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 30), Parent = content })
			return
		end
		local top = card(content, 120, 1)
		local avatar = UI.new("ImageLabel", { BackgroundColor3 = colors.panel, Size = UDim2.fromOffset(72, 72), Parent = top }, { UI.corner(36) })
		task.spawn(function()
			local ok, image = pcall(function()
				return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
			end)
			if ok then
				avatar.Image = image
			end
		end)
		UI.label({ Text = player.DisplayName:upper(), Font = UI.FONT_BLACK, TextSize = 20, Position = UDim2.fromOffset(84, 2), Size = UDim2.new(1, -84, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd, Parent = top })
		UI.label({ Text = "LEVEL " .. data.level, Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.xp, Position = UDim2.fromOffset(84, 26), Size = UDim2.new(1, -84, 0, 16), Parent = top })
		UI.label({ Text = data.rank:upper(), Font = UI.FONT_BOLD, TextSize = 14, TextColor3 = colors.accent, Position = UDim2.fromOffset(84, 44), Size = UDim2.new(1, -84, 0, 16), Parent = top })
		local _, setXP = UI.bar({ Position = UDim2.fromOffset(0, 82), Size = UDim2.new(1, 0, 0, 8), Parent = top }, colors.xp)
		setXP(data.xp / data.xpToNext)
		UI.label({ Text = string.format("%d / %d XP to level %d", data.xp, data.xpToNext, data.level + 1), TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 92), Size = UDim2.new(1, 0, 0, 14), Parent = top })

		local numbers = card(content, 66, 2)
		local entries = {
			{ "Reputation", tostring(data.reputation) },
			{ "Fame", tostring(data.fame) },
			{ "Runs", tostring(data.runsCompleted) },
			{ "Best Run", if data.bestRunSeconds > 0 then string.format("%.1fs", data.bestRunSeconds) else "—" },
		}
		for i, entry in entries do
			local x = (i - 1) / #entries
			UI.label({ Text = entry[2], Font = UI.FONT_BLACK, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(x, 0), Size = UDim2.new(1 / #entries, 0, 0, 22), Parent = numbers })
			UI.label({ Text = entry[1], TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.new(x, 0, 0, 24), Size = UDim2.new(1 / #entries, 0, 0, 14), Parent = numbers })
		end

		local stats = card(content, 30 + #Config.STATS * 24, 3)
		UI.label({ Text = "ATTRIBUTES", Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 16), Parent = stats })
		for i, stat in Config.STATS do
			local y = 22 + (i - 1) * 24
			local value = data.stats[stat] or 1
			UI.label({ Text = stat:gsub("(%l)(%u)", "%1 %2"), TextSize = 13, Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(100, 18), Parent = stats })
			local _, setStat = UI.bar({ Position = UDim2.fromOffset(104, y + 5), Size = UDim2.new(1, -140, 0, 8), Parent = stats }, colors.accent)
			setStat(value / 99)
			UI.label({ Text = tostring(value), Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, y), Size = UDim2.fromOffset(30, 18), Parent = stats })
		end
	end
end

---------------------------------------------------------------------------
-- Bank app
---------------------------------------------------------------------------
local function buildBank()
	local _, content = appPage("Bank", "City Bank")
	pages.Bank.open = function()
		clear(content)
		local data = fetchProfile()
		if not data then
			return
		end
		local balance = card(content, 86, 1)
		balance.BackgroundColor3 = Color3.fromRGB(20, 70, 50)
		UI.label({ Text = "BALANCE", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = Color3.fromRGB(170, 230, 190), Size = UDim2.new(1, 0, 0, 14), Parent = balance })
		UI.label({ Text = UI.formatCash(data.cash), Font = UI.FONT_BLACK, TextSize = 32, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 36), Parent = balance })

		local income, expenses = 0, 0
		for _, t in data.transactions do
			if t.amount > 0 then
				income += t.amount
			else
				expenses -= t.amount
			end
		end
		local summary = card(content, 54, 2)
		UI.label({ Text = "Income", TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(0.5, 0, 0, 14), Parent = summary })
		UI.label({ Text = UI.formatCash(income), Font = UI.FONT_BOLD, TextSize = 16, TextColor3 = colors.cash, Position = UDim2.fromOffset(0, 14), Size = UDim2.new(0.5, 0, 0, 18), Parent = summary })
		UI.label({ Text = "Expenses", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0.5, 0, 0, 14), Parent = summary })
		UI.label({ Text = UI.formatCash(expenses), Font = UI.FONT_BOLD, TextSize = 16, TextColor3 = colors.danger, Position = UDim2.new(0.5, 0, 0, 14), Size = UDim2.new(0.5, 0, 0, 18), Parent = summary })

		UI.label({ Text = "RECENT TRANSACTIONS", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, -20, 0, 16), LayoutOrder = 3, Parent = content })
		for i, t in data.transactions do
			local row = card(content, 46, 3 + i)
			UI.label({ Text = t.label, Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -80, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
			UI.label({ Text = UI.timeAgo(t.t), TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -80, 0, 14), Parent = row })
			UI.label({
				Text = (if t.amount > 0 then "+" else "") .. UI.formatCash(t.amount),
				Font = UI.FONT_BOLD,
				TextSize = 15,
				TextColor3 = if t.amount > 0 then colors.cash else colors.danger,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 4),
				Size = UDim2.fromOffset(80, 18),
				Parent = row,
			})
		end
	end
end

---------------------------------------------------------------------------
-- Map app with GPS (section 38)
---------------------------------------------------------------------------
local gps: { target: Vector3, name: string, beam: Beam, a0: Attachment, a1: Attachment, marker: BasePart }? = nil

local function clearGPS()
	if gps then
		gps.beam:Destroy()
		gps.a0:Destroy()
		gps.marker:Destroy()
		gps = nil
	end
end

local function setGPS(name: string, target: Vector3)
	clearGPS()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local marker = UI.new("Part", {
		Name = "GPSMarker",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Size = Vector3.one,
		Position = target + Vector3.new(0, 2, 0),
		Parent = Workspace,
	})
	local a1 = UI.new("Attachment", { Parent = marker })
	local a0 = UI.new("Attachment", { Position = Vector3.new(0, -2.5, 0), Parent = root })
	local beam = UI.new("Beam", {
		Attachment0 = a0,
		Attachment1 = a1,
		Color = ColorSequence.new(Color3.fromRGB(80, 200, 255)),
		Transparency = NumberSequence.new(0.2),
		Width0 = 1.2,
		Width1 = 1.2,
		FaceCamera = true,
		LightEmission = 1,
		Segments = 1,
		Parent = marker,
	})
	local billboard = UI.new("BillboardGui", { Size = UDim2.fromOffset(200, 50), StudsOffset = Vector3.new(0, 8, 0), AlwaysOnTop = true, LightInfluence = 0, Parent = marker })
	local label = UI.label({ Name = "Text", Text = name, Font = UI.FONT_BLACK, TextSize = 18, TextStrokeTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = billboard })
	gps = { target = target, name = name, beam = beam, a0 = a0, a1 = a1, marker = marker }
	HUD.push("GPS SET", "Follow the blue line to " .. name .. ".")

	task.spawn(function()
		local myGps = gps
		while gps == myGps do
			local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r then
				if a0.Parent ~= r then
					a0.Parent = r -- respawned
				end
				local dist = (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude
				label.Text = string.format("%s  ·  %dm", name, math.floor(dist / 3.57)) -- ~3.57 studs per metre
				if dist < 14 then
					clearGPS()
					HUD.push("ARRIVED", "You made it to " .. name .. ".")
					return
				end
			end
			task.wait(0.2)
		end
	end)
end

local function buildMap()
	local _, content = appPage("Map", "Map")
	local MAP_W = PHONE_W - 2 * SCREEN_INSET - 20
	local WORLD_X, WORLD_Z = 600, 460
	local scale = MAP_W / WORLD_X
	local MAP_H = math.floor(WORLD_Z * scale)

	local canvas = UI.new("Frame", {
		Name = "Canvas",
		BackgroundColor3 = Color3.fromRGB(70, 120, 60),
		ClipsDescendants = true,
		Size = UDim2.fromOffset(MAP_W, MAP_H),
		LayoutOrder = 1,
		Parent = content,
	}, { UI.corner(12) })

	local function toMap(pos: Vector3): UDim2
		return UDim2.fromOffset((pos.X + WORLD_X / 2) * scale, (pos.Z + WORLD_Z / 2) * scale)
	end

	local function rect(cf: CFrame, size: Vector3, color: Color3, z: number)
		UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color,
			Position = toMap(cf.Position),
			Size = UDim2.fromOffset(math.max(2, size.X * scale), math.max(2, size.Z * scale)),
			ZIndex = z,
			Parent = canvas,
		})
	end

	local arrow = UI.label({
		Text = "▲",
		Font = UI.FONT_BLACK,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(80, 200, 255),
		TextStrokeTransparency = 0,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
		ZIndex = 10,
		Parent = canvas,
	})

	local drawn = false
	local function drawCity()
		local city = Workspace:FindFirstChild("City")
		if drawn or not city then
			return
		end
		drawn = true
		for _, d in city:GetDescendants() do
			if d:IsA("BasePart") then
				if d.Name == "MainRoad" or d.Name == "CrossRoad" then
					rect(d.CFrame, d.Size, Color3.fromRGB(50, 50, 55), 2)
				elseif d.Name == "Sidewalk" then
					rect(d.CFrame, d.Size, Color3.fromRGB(170, 170, 165), 2)
				elseif d.Name == "Body" and d.Parent and d.Parent.Parent and d.Parent.Parent.Name == "Buildings" then
					rect(d.CFrame, d.Size, Color3.fromRGB(200, 190, 175), 3)
				elseif d.Name == "CourtFloor" then
					rect(d.CFrame, d.Size, Color3.fromRGB(40, 90, 150), 3)
				elseif d.Name == "Lot" then
					rect(d.CFrame, d.Size, Color3.fromRGB(60, 60, 66), 2)
				end
			end
		end
	end

	local listStart = 2
	pages.Map.open = function()
		drawCity()
		for _, child in content:GetChildren() do
			if child:IsA("GuiObject") and child ~= canvas then
				child:Destroy()
			end
		end
		for _, child in canvas:GetChildren() do
			if child.Name == "Dot" then
				child:Destroy()
			end
		end
		local city = Workspace:FindFirstChild("City")
		local points = city and city:FindFirstChild("MapPoints")
		if gps then
			local clearRow = UI.button({ Text = "Clear GPS to " .. gps.name, TextSize = 13, BackgroundColor3 = colors.danger, Size = UDim2.new(1, -20, 0, 34), LayoutOrder = listStart, Parent = content })
			clearRow.Activated:Connect(function()
				clearGPS()
				showPage("Map")
			end)
		end
		if not points then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local list = points:GetChildren()
		table.sort(list, function(a, b)
			if not root then
				return a.Name < b.Name
			end
			return (a.Position - root.Position).Magnitude < (b.Position - root.Position).Magnitude
		end)
		for i, point in list do
			local row = card(content, 44, listStart + i)
			UI.label({ Text = point.Name, Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -70, 0, 16), TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
			local dist = if root then math.floor((point.Position - root.Position).Magnitude / 3.57) .. "m" else ""
			UI.label({ Text = (point:GetAttribute("Category") or "Place") .. "  ·  " .. dist, TextSize = 11, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, -70, 0, 14), Parent = row })
			local go = UI.button({ Text = "GPS", TextSize = 13, BackgroundColor3 = Color3.fromRGB(40, 120, 220), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(56, 28), Parent = row })
			go.Activated:Connect(function()
				setGPS(point.Name, point.Position)
				showPage("Map")
			end)
			-- dot on the map
			UI.new("Frame", {
				Name = "Dot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = colors.accent,
				Position = toMap(point.Position),
				Size = UDim2.fromOffset(6, 6),
				ZIndex = 6,
				Parent = canvas,
			}, { UI.corner(3) })
		end
	end

	RunService.RenderStepped:Connect(function()
		if not isOpen or currentPage ~= "Map" then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			arrow.Position = toMap(root.Position)
			local look = root.CFrame.LookVector
			arrow.Rotation = math.deg(math.atan2(look.X, -look.Z))
		end
	end)
end

---------------------------------------------------------------------------
-- Alerts app (section 36)
---------------------------------------------------------------------------
local function buildAlerts()
	local _, content = appPage("Alerts", "Notifications")
	pages.Alerts.open = function()
		HUD.markRead()
		clear(content)
		if #HUD.notifications == 0 then
			UI.label({ Text = "No notifications yet.", TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 40), Parent = content })
			return
		end
		local clearAll = UI.button({ Text = "Clear all", TextSize = 13, Size = UDim2.new(1, -20, 0, 30), LayoutOrder = 0, Parent = content })
		clearAll.Activated:Connect(function()
			table.clear(HUD.notifications)
			showPage("Alerts")
		end)
		for i, n in HUD.notifications do
			local row = card(content, 58, i)
			UI.label({ Text = n.title, Font = UI.FONT_BLACK, TextSize = 13, TextColor3 = colors.accent, Size = UDim2.new(1, -60, 0, 14), Parent = row })
			UI.label({ Text = UI.timeAgo(n.time), TextSize = 11, TextColor3 = colors.subtext, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(60, 14), Parent = row })
			UI.label({ Text = n.body, TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 18), Parent = row })
		end
	end
end

---------------------------------------------------------------------------
-- Settings app (section 43)
---------------------------------------------------------------------------
local function setSetting(key: string, value: any)
	local ok, accepted = pcall(function()
		return remotes.SetSetting:InvokeServer(key, value)
	end)
	if not ok or not accepted then
		HUD.push("SETTINGS", "That change didn't save. Try again in a moment.")
	end
end

local function buildSettings()
	local _, content = appPage("Settings", "Settings")
	pages.Settings.open = function()
		clear(content)

		local wp = card(content, 92, 1)
		UI.label({ Text = "WALLPAPER", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = wp })
		local current = player:GetAttribute("Wallpaper") or 1
		for i, paper in Config.WALLPAPERS do
			local swatch = UI.new("TextButton", {
				Text = "",
				BackgroundColor3 = Color3.new(1, 1, 1),
				Position = UDim2.fromOffset((i - 1) * 48, 22),
				Size = UDim2.fromOffset(40, 44),
				Parent = wp,
			}, {
				UI.corner(10),
				UI.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(paper.top, paper.bottom) }),
			})
			if i == current then
				UI.stroke(Color3.new(1, 1, 1), 2).Parent = swatch
			end
			swatch.Activated:Connect(function()
				setSetting("wallpaper", i)
				task.wait(0.2)
				showPage("Settings")
			end)
		end

		local scaleCard = card(content, 70, 2)
		UI.label({ Text = "PHONE SIZE", Font = UI.FONT_BLACK, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = scaleCard })
		local currentScale = player:GetAttribute("UIScale") or 1
		for i, s in Config.UI_SCALES do
			local b = UI.button({
				Text = math.floor(s * 100) .. "%",
				TextSize = 12,
				BackgroundColor3 = if s == currentScale then colors.xp else colors.panel,
				Position = UDim2.fromOffset((i - 1) * 50, 22),
				Size = UDim2.fromOffset(46, 28),
				Parent = scaleCard,
			})
			b.Activated:Connect(function()
				setSetting("uiScale", s)
				task.wait(0.2)
				showPage("Settings")
			end)
		end

		local soundCard = card(content, 50, 3)
		UI.label({ Text = "Notification sounds", Font = UI.FONT_BOLD, TextSize = 14, Size = UDim2.new(1, -70, 1, 0), Parent = soundCard })
		local soundsOn = player:GetAttribute("NotificationSounds") ~= false
		local toggle = UI.button({
			Text = if soundsOn then "ON" else "OFF",
			TextSize = 13,
			BackgroundColor3 = if soundsOn then Color3.fromRGB(50, 170, 90) else colors.panel,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(56, 28),
			Parent = soundCard,
		})
		toggle.Activated:Connect(function()
			setSetting("notificationSounds", not soundsOn)
			task.wait(0.2)
			showPage("Settings")
		end)

		local about = card(content, 50, 4)
		UI.label({ Text = "CityPhone · " .. player.Name, TextSize = 12, TextColor3 = colors.subtext, Size = UDim2.new(1, 0, 0, 14), Parent = about })
		UI.label({ Text = "Settings are saved to your account.", TextSize = 12, TextColor3 = colors.subtext, Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 14), Parent = about })
	end
end

---------------------------------------------------------------------------
-- Home screen (section 16)
---------------------------------------------------------------------------
local APPS = {
	{ id = "Profile", label = "Profile", icon = "👤", color = Color3.fromRGB(90, 110, 240) },
	{ id = "Bank", label = "Bank", icon = "💵", color = Color3.fromRGB(40, 160, 90) },
	{ id = "Map", label = "Map", icon = "🗺️", color = Color3.fromRGB(240, 150, 40) },
	{ id = "Alerts", label = "Alerts", icon = "🔔", color = Color3.fromRGB(230, 70, 80) },
	{ id = "Settings", label = "Settings", icon = "⚙️", color = Color3.fromRGB(110, 110, 125) },
}

local function buildHome()
	local home = UI.new("Frame", { Name = "Home", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = screen })
	pages.Home = { frame = home }

	local bigClock = UI.label({ Text = "9:00", Font = UI.FONT_BLACK, TextSize = 56, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 60), Parent = home })
	local subtitle = UI.label({ Text = "The Neighborhood", Font = UI.FONT_BOLD, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(0, 120), Size = UDim2.new(1, 0, 0, 18), Parent = home })

	local grid = UI.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 170), Size = UDim2.new(1, -28, 1, -210), Parent = home }, {
		UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(60, 80), CellPadding = UDim2.fromOffset(6, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, app in APPS do
		local cell = UI.new("Frame", { BackgroundTransparency = 1, LayoutOrder = i, Parent = grid })
		local icon = UI.new("TextButton", {
			Name = "Icon",
			Text = app.icon,
			TextSize = 28,
			Font = UI.FONT,
			BackgroundColor3 = app.color,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(56, 56),
			AutoButtonColor = true,
			Parent = cell,
		}, { UI.corner(14) })
		UI.label({ Text = app.label, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.6, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 0, 14), Parent = cell })
		icon.Activated:Connect(function()
			showPage(app.id)
		end)
		if app.id == "Alerts" then
			badge = UI.new("TextLabel", {
				Text = "0",
				Font = UI.FONT_BLACK,
				TextSize = 12,
				TextColor3 = Color3.new(1, 1, 1),
				BackgroundColor3 = Color3.fromRGB(255, 50, 50),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(1, -2, 0, 2),
				Size = UDim2.fromOffset(20, 20),
				Visible = false,
				ZIndex = 3,
				Parent = icon,
			}, { UI.corner(10) })
		end
	end

	RunService.Heartbeat:Connect(function()
		if isOpen and currentPage == "Home" then
			bigClock.Text = UI.formatClock(Lighting.ClockTime):gsub(" [AP]M", "")
			subtitle.Text = "The Neighborhood  ·  " .. (if Lighting.ClockTime >= 6 and Lighting.ClockTime < 18 then "Day" else "Night")
		end
	end)
end

local function buildStatusBar()
	local bar = UI.new("Frame", { Name = "StatusBar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), ZIndex = 20, Parent = screen }, { UI.padding(8) })
	local clock = UI.label({ Text = "9:00 AM", Font = UI.FONT_BOLD, TextSize = 13, Size = UDim2.new(0.4, 0, 1, 0), ZIndex = 20, Parent = bar })
	local right = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.6, 0, 1, 0), ZIndex = 20, Parent = bar })
	local bell = UI.label({ Text = "", Font = UI.FONT_BOLD, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromScale(0.4, 0), Size = UDim2.new(0.2, 0, 1, 0), ZIndex = 20, Parent = bar })

	local function refreshBadge()
		local unread = HUD.unread
		if badge then
			badge.Visible = unread > 0
			badge.Text = if unread > 9 then "9+" else tostring(unread)
		end
		bell.Text = if unread > 0 then "🔔" .. unread else ""
	end
	HUD.notificationAdded.Event:Connect(refreshBadge)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		-- The battery drains while the phone is out and charges while it's away.
		accumulator += dt
		if accumulator >= 1 then
			accumulator -= 1
			battery = if isOpen then math.max(5, battery - 0.08) else math.min(100, battery + 0.5)
		end
		if isOpen then
			clock.Text = UI.formatClock(Lighting.ClockTime)
			right.Text = string.format("▂▄▆█  %d%%", math.floor(battery))
		end
	end)
	refreshBadge()
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------
function Phone.setOpen(open: boolean)
	if open == isOpen then
		return
	end
	isOpen = open
	applyScale()
	phoneFrame.Visible = true
	local target = if open then UDim2.new(1, -24, 0.5, 0) else UDim2.new(1, PHONE_W + 40, 0.5, 0)
	local tween = TweenService:Create(phoneFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = target })
	tween:Play()
	if open then
		showPage(currentPage)
	else
		tween.Completed:Once(function()
			if not isOpen then
				phoneFrame.Visible = false
			end
		end)
	end
	remotes.PhoneState:FireServer(open)
end

function Phone.toggle()
	Phone.setOpen(not isOpen)
end

function Phone.start()
	gui = UI.new("ScreenGui", {
		Name = "CityGrindPhone",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
		Parent = player:WaitForChild("PlayerGui"),
	})
	phoneFrame = UI.new("Frame", {
		Name = "Phone",
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, PHONE_W + 40, 0.5, 0),
		Size = UDim2.fromOffset(PHONE_W, PHONE_H),
		Visible = false,
		Parent = gui,
	}, { UI.corner(42), UI.stroke(Color3.fromRGB(70, 70, 80), 2) })
	uiScale = UI.new("UIScale", { Parent = phoneFrame })

	screen = UI.new("Frame", {
		Name = "Screen",
		BackgroundColor3 = Color3.new(1, 1, 1),
		ClipsDescendants = true,
		Position = UDim2.fromOffset(SCREEN_INSET, SCREEN_INSET),
		Size = UDim2.new(1, -2 * SCREEN_INSET, 1, -2 * SCREEN_INSET),
		Parent = phoneFrame,
	}, { UI.corner(34) })
	wallpaperGradient = UI.new("UIGradient", { Rotation = 90, Parent = screen })

	-- notch
	UI.new("Frame", { BackgroundColor3 = Color3.fromRGB(10, 10, 12), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(90, 22), ZIndex = 30, Parent = screen }, { UI.corner(11) })

	buildStatusBar()
	buildHome()
	buildProfile()
	buildBank()
	buildMap()
	buildAlerts()
	buildSettings()
	showPage("Home")

	-- Home indicator: tap to go home, tap again on Home to put the phone away.
	local homeBar = UI.new("TextButton", {
		Name = "HomeBar",
		Text = "",
		BackgroundColor3 = Color3.fromRGB(230, 230, 235),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(110, 6),
		ZIndex = 30,
		Parent = screen,
	}, { UI.corner(3) })
	local hitArea = UI.new("TextButton", { Text = "", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(160, 26), ZIndex = 31, Parent = screen })
	local function onHome()
		if currentPage == "Home" then
			Phone.setOpen(false)
		else
			showPage("Home")
		end
	end
	homeBar.Activated:Connect(onHome)
	hitArea.Activated:Connect(onHome)

	applyWallpaper()
	player:GetAttributeChangedSignal("Wallpaper"):Connect(applyWallpaper)
	player:GetAttributeChangedSignal("UIScale"):Connect(applyScale)
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end
	applyScale()

	ContextActionService:BindAction("CityPhone", function(_, state)
		if state == Enum.UserInputState.Begin then
			Phone.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.P, Enum.KeyCode.DPadUp)
	ContextActionService:SetTitle("CityPhone", "Phone")
	ContextActionService:SetPosition("CityPhone", UDim2.new(1, -110, 1, -200))

	player.CharacterAdded:Connect(function()
		-- the server removed the phone prop with the old character
		if isOpen then
			task.wait(0.5)
			remotes.PhoneState:FireServer(true)
		end
	end)
end

return Phone
]=====])
print('[CityGrind] Installed. Press Play to build the Neighborhood and test.')
