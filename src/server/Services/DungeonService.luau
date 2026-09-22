--[[
	The key-gated "daily dungeon" run: touch the portal in the hub, spend a
	key, and get teleported into a private instance of the dungeon room -
	your own copy, built fresh and torn down when you're done, so concurrent
	runs never collide or aggro each other. Multiple waves of trash clear
	before the boss spawns, closer to the design doc's full mob count than
	a handful of trash. Killing the boss reports the "complete the daily
	dungeon" quest (XP/loot for the kill itself already flow through the
	normal EnemyService/LootService pipeline) and returns you to the hub.

	Two things make a run more than the open-world grind with a boss at the
	end: every wave promotes one random enemy to a Champion (tougher, hits
	harder, guaranteed bonus loot - see EnemyService's Champion option and
	the bonus-loot hook in init.server.luau), and the room periodically
	telegraphs a floor hazard players have to actually reposition out of.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Modules.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local LevelLayout = require(script.Parent.LevelLayout)
local EnemyService = require(script.Parent.EnemyService)
local MapService = require(script.Parent.MapService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local DungeonService = {}

local SPAWN_JITTER = 6
local INSTANCE_BASE = Vector3.new(0, 0, 1200)
local INSTANCE_SLOT_SPACING = 500
local RETURN_DELAY_SECONDS = 3
local HAZARD_MARGIN = 12

-- [Player]: { Slot, Folder, Offset, WaveIndex, RemainingInWave }
local activeRuns: { [Player]: { [string]: any } } = {}

local freeSlots: { number } = {}
local nextSlot = 0

local function acquireSlot(): number
	if #freeSlots > 0 then
		return table.remove(freeSlots) :: number
	end
	nextSlot += 1
	return nextSlot
end

local function releaseSlot(slot: number)
	table.insert(freeSlots, slot)
end

local function jittered(position: Vector3): Vector3
	return position + Vector3.new(math.random(-SPAWN_JITTER, SPAWN_JITTER), 0, math.random(-SPAWN_JITTER, SPAWN_JITTER))
end

local function teleportPlayer(player: Player, position: Vector3)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp.CFrame = CFrame.new(position)
	end
end

local function destroyRunLeftovers(player: Player, runState)
	for _, model in Workspace:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Owner") == player.UserId and model:GetAttribute("DungeonRun") then
			model:Destroy()
		end
	end
	if runState.Folder then
		runState.Folder:Destroy()
	end
	releaseSlot(runState.Slot)
end

-- Deterministic per UTC calendar day - every player sees the same "today's
-- dungeon" and it's not something a run needs to persist, it just falls out
-- of the current date, same as the daily quest pool re-rolling by date.
local function selectVariant()
	local dayIndex = os.date("!*t").yday :: number
	local variants = LevelLayout.DungeonVariants
	return variants[(dayIndex % #variants) + 1]
end

-- Rotates on a slower, independent cycle from selectVariant so the boss
-- isn't always locked to the same wave composition - with 2 of each, that's
-- 4 distinguishable dungeon days (wave x boss) across a 4-day cycle instead
-- of the pairing always moving in lockstep and reading as "two flavors of
-- one thing" after a couple of visits.
local function selectBoss()
	local dayIndex = os.date("!*t").yday :: number
	local bosses = LevelLayout.DungeonBosses
	local cycleStep = dayIndex // #LevelLayout.DungeonVariants
	return bosses[(cycleStep % #bosses) + 1]
end

local function spawnBoss(player: Player, runState)
	local tags = { DungeonRun = true, Owner = player.UserId, IsBoss = true }
	EnemyService.Spawn(runState.Boss.Kind, LevelLayout.DungeonBossPosition + runState.Offset, { Respawn = false, Tags = tags })
	Remotes.Notify:FireClient(player, "The dungeon boss appears: " .. runState.Boss.Name .. "!")
end

local function spawnWave(player: Player, runState, waveIndex: number)
	local wave = runState.Variant.Waves[waveIndex]
	if not wave then
		spawnBoss(player, runState)
		return
	end

	runState.WaveIndex = waveIndex
	runState.RemainingInWave = #wave

	-- One random enemy per wave is promoted to a Champion - a real "this
	-- wave hits different" moment instead of every wave being interchangeable
	-- trash, plus a guaranteed bonus loot roll on top of the normal drop.
	local championIndex = math.random(1, #wave)

	local tags = { DungeonRun = true, Owner = player.UserId }
	for index, spawnPoint in wave do
		EnemyService.Spawn(spawnPoint.Kind, jittered(spawnPoint.Position + runState.Offset), {
			Respawn = false,
			Tags = tags,
			Champion = index == championIndex,
		})
	end

	Remotes.Notify:FireClient(player, string.format("Wave %d/%d incoming! One enemy is a Champion - watch for it.", waveIndex, #runState.Variant.Waves))
end

-- A telegraphed danger zone on the dungeon floor: a translucent red circle
-- brightens over Hazard.TelegraphSeconds, then deals damage to anyone still
-- standing in it. Parented to the run's own instance Folder so it's cleaned
-- up automatically (with everything else) when the run ends.
local function spawnHazard(runState)
	local hazardCfg = Config.Dungeon.Hazard
	local center = LevelLayout.DungeonRoom.Center + runState.Offset
	local half = LevelLayout.DungeonRoom.HalfSize
	local position = Vector3.new(
		center.X + math.random(-(half.X - HAZARD_MARGIN), half.X - HAZARD_MARGIN),
		center.Y + 0.2,
		center.Z + math.random(-(half.Z - HAZARD_MARGIN), half.Z - HAZARD_MARGIN)
	)

	local marker = Instance.new("Part")
	marker.Name = "DungeonHazard"
	marker.Anchored = true
	marker.CanCollide = false
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.2, hazardCfg.Radius * 2, hazardCfg.Radius * 2)
	marker.Orientation = Vector3.new(0, 0, 90)
	marker.CFrame = CFrame.new(position)
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(220, 40, 40)
	marker.Transparency = 0.85
	marker.Parent = runState.Folder

	local tween = TweenService:Create(marker, TweenInfo.new(hazardCfg.TelegraphSeconds, Enum.EasingStyle.Linear), {
		Transparency = 0.3,
	})
	tween:Play()

	task.delay(hazardCfg.TelegraphSeconds, function()
		if not marker.Parent then
			return
		end
		marker.Transparency = 0

		for _, player in Players:GetPlayers() do
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if hrp and humanoid and humanoid.Health > 0 then
				local flatOffset = Vector3.new(hrp.Position.X - position.X, 0, hrp.Position.Z - position.Z)
				if flatOffset.Magnitude <= hazardCfg.Radius then
					PlayerDataService.DamagePlayer(player, hazardCfg.Damage)
				end
			end
		end

		task.delay(0.25, function()
			if marker.Parent then
				marker:Destroy()
			end
		end)
	end)
end

local function runHazardLoop(player: Player, runState)
	local hazardCfg = Config.Dungeon.Hazard
	while activeRuns[player] == runState do
		task.wait(math.random(hazardCfg.MinIntervalSeconds * 10, hazardCfg.MaxIntervalSeconds * 10) / 10)
		if activeRuns[player] ~= runState then
			break
		end
		spawnHazard(runState)
	end
end

local function startRun(player: Player)
	local slot = acquireSlot()
	local offset = INSTANCE_BASE + Vector3.new(slot * INSTANCE_SLOT_SPACING, 0, 0)
	local folder = MapService.BuildDungeonInstance(offset)
	local variant = selectVariant()
	local boss = selectBoss()

	local runState = {
		Slot = slot,
		Folder = folder,
		Offset = offset,
		Variant = variant,
		Boss = boss,
		WaveIndex = 0,
		RemainingInWave = 0,
	}
	activeRuns[player] = runState

	teleportPlayer(player, LevelLayout.DungeonEntryPosition + offset)
	Remotes.Notify:FireClient(
		player,
		string.format(
			"Today's dungeon: %s, defended by %s. Fight through every wave to reach the boss! Watch the floor for danger zones.",
			variant.Name,
			boss.Name
		)
	)
	spawnWave(player, runState, 1)
	task.spawn(runHazardLoop, player, runState)
end

local function onPromptTriggered(prompt: ProximityPrompt, player: Player)
	if prompt.Name ~= "EnterDungeonPrompt" then
		return
	end

	if activeRuns[player] then
		Remotes.Notify:FireClient(player, "You already have a dungeon run in progress.")
		return
	end

	if not PlayerDataService.SpendKey(player) then
		Remotes.Notify:FireClient(player, "No keys left - they regenerate over time.")
		return
	end

	startRun(player)
end

-- Called from the central enemy-died handler in init.server.luau for every
-- enemy death, so it can react specifically to dungeon-run enemies.
function DungeonService.HandleEnemyDied(enemy: Model, tierName: string, killer: Player?)
	if not enemy:GetAttribute("DungeonRun") then
		return
	end

	local ownerId = enemy:GetAttribute("Owner")
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	local runState = owner and activeRuns[owner]
	if not owner or not runState then
		return
	end

	if enemy:GetAttribute("IsBoss") then
		activeRuns[owner] = nil
		PlayerDataService.ReportQuestProgress(owner, "Dungeon")
		if killer then
			Remotes.Notify:FireClient(killer, "Dungeon boss defeated! Heading back to the hub.")
		end

		teleportPlayer(owner, LevelLayout.DungeonPortal + Vector3.new(0, 3, -6))
		task.delay(RETURN_DELAY_SECONDS, function()
			destroyRunLeftovers(owner, runState)
		end)
	else
		runState.RemainingInWave -= 1
		if runState.RemainingInWave <= 0 then
			spawnWave(owner, runState, runState.WaveIndex + 1)
		end
	end
end

local function onPlayerRemoving(player: Player)
	local runState = activeRuns[player]
	activeRuns[player] = nil
	if runState then
		destroyRunLeftovers(player, runState)
	end
end

function DungeonService.Init()
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return DungeonService
