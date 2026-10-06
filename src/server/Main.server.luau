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
local Basketball = require(script:WaitForChild("Basketball"))
local CourtGames = require(script:WaitForChild("CourtGames"))

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local Net = require(script:WaitForChild("Net"))
local remote = Net.remote
local allow = Net.allow

local Notify = remote("RemoteEvent", "Notify") -- server -> client (title, body)
local StaminaRefill = remote("RemoteEvent", "StaminaRefill") -- server -> client
local PhoneState = remote("RemoteEvent", "PhoneState") -- client -> server (isOpen)
local GetProfile = remote("RemoteFunction", "GetProfile") -- client -> server
local SetSetting = remote("RemoteFunction", "SetSetting") -- client -> server (key, value)
local BallAction = remote("RemoteEvent", "BallAction") -- client -> server (action)
local BallFx = remote("RemoteEvent", "BallFx") -- server -> client (kind, ...)

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
-- Basketball (Phase 2). The client only reports button presses.
---------------------------------------------------------------------------
Basketball.announce = function(players: { Player }, text: string)
	for _, player in players do
		BallFx:FireClient(player, "Callout", text)
	end
end
Basketball.dunkJump = function(player: Player, rim: Vector3)
	BallFx:FireClient(player, "Dunk", rim)
end
Basketball.onTrain = function(player: Player, statName: string, amount: number)
	PlayerData.addStatXP(player, statName, amount)
end

local BALL_ACTIONS = {
	ShootStart = { cooldown = 0.15, fn = Basketball.shootStart },
	ShootRelease = { cooldown = 0.05, fn = Basketball.shootRelease },
	Pass = { cooldown = 0.3, fn = Basketball.pass },
	Steal = { cooldown = 0.3, fn = Basketball.steal },
}
BallAction.OnServerEvent:Connect(function(player: Player, action: any)
	local entry = type(action) == "string" and BALL_ACTIONS[action]
	if entry and allow(player, "Ball" .. action, entry.cooldown) then
		entry.fn(player)
	end
end)

CourtGames.start()

---------------------------------------------------------------------------
-- Phase 3 life systems and Phase 4 social systems. Each builds its own places and remotes.
---------------------------------------------------------------------------
for _, name in { "Jobs", "Gym", "Vehicles", "Apartments", "Shops", "Social", "Messages", "Party", "Crews", "Emotes" } do
	local module = script:FindFirstChild(name)
	if module then
		local ok, err = pcall(function()
			require(module).start(city.city)
		end)
		if not ok then
			warn("[CityGrind] " .. name .. " failed to start:", err)
		end
	end
end

---------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------
-- Shift is Sprint, so turn off Roblox's Shift-to-lock-mouse toggle.
game:GetService("StarterPlayer").EnableMouseLockOption = false

local function onPlayerAdded(player: Player)
	player.DevEnableMouseLock = false
	if player.Character then
		Basketball.tagCharacter(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		Basketball.tagCharacter(character)
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
