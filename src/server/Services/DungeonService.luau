--[[
	The key-gated "daily dungeon" run: touch the portal in the hub, spend a
	key, and get teleported into a private instance of the dungeon room -
	your own copy, built fresh and torn down when you're done, so concurrent
	runs never collide or aggro each other. Multiple waves of trash clear
	before the boss spawns, closer to the design doc's full mob count than
	a handful of trash. Killing the boss reports the "complete the daily
	dungeon" quest (XP/loot for the kill itself already flow through the
	normal EnemyService/LootService pipeline) and returns you to the hub.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

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

local function spawnBoss(player: Player, runState)
	local tags = { DungeonRun = true, Owner = player.UserId, IsBoss = true }
	EnemyService.Spawn(LevelLayout.DungeonBossKind, LevelLayout.DungeonBossPosition + runState.Offset, { Respawn = false, Tags = tags })
	Remotes.Notify:FireClient(player, "The dungeon boss appears!")
end

local function spawnWave(player: Player, runState, waveIndex: number)
	local wave = LevelLayout.DungeonWaves[waveIndex]
	if not wave then
		spawnBoss(player, runState)
		return
	end

	runState.WaveIndex = waveIndex
	runState.RemainingInWave = #wave

	local tags = { DungeonRun = true, Owner = player.UserId }
	for _, spawnPoint in wave do
		EnemyService.Spawn(spawnPoint.Kind, jittered(spawnPoint.Position + runState.Offset), { Respawn = false, Tags = tags })
	end

	Remotes.Notify:FireClient(player, string.format("Wave %d/%d incoming!", waveIndex, #LevelLayout.DungeonWaves))
end

local function startRun(player: Player)
	local slot = acquireSlot()
	local offset = INSTANCE_BASE + Vector3.new(slot * INSTANCE_SLOT_SPACING, 0, 0)
	local folder = MapService.BuildDungeonInstance(offset)

	local runState = { Slot = slot, Folder = folder, Offset = offset, WaveIndex = 0, RemainingInWave = 0 }
	activeRuns[player] = runState

	teleportPlayer(player, LevelLayout.DungeonEntryPosition + offset)
	Remotes.Notify:FireClient(player, "Dungeon run started - fight through every wave to reach the boss!")
	spawnWave(player, runState, 1)
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
