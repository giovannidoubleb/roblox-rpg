--[[
	The key-gated "daily dungeon" run: touch the portal in the hub, spend a
	key, and a trash-then-boss wave spawns in the dungeon room. Killing the
	boss reports the "complete the daily dungeon" quest (XP/loot for the
	kill itself already flow through the normal EnemyService/LootService
	pipeline).

	Simplification versus the design doc: this is one boss + a few trash,
	not a full 15-25 mob run, and the dungeon room is shared rather than a
	private instance per player (enemies are tagged with an Owner so
	kills/completion still attribute correctly). Real instancing would need
	reserved servers/TeleportService - a bigger feature for later.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local LevelLayout = require(script.Parent.LevelLayout)
local EnemyService = require(script.Parent.EnemyService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local DungeonService = {}

local SPAWN_JITTER = 6
local activeRuns: { [Player]: boolean } = {}

local function jittered(position: Vector3): Vector3
	return position + Vector3.new(math.random(-SPAWN_JITTER, SPAWN_JITTER), 0, math.random(-SPAWN_JITTER, SPAWN_JITTER))
end

local function startRun(player: Player)
	activeRuns[player] = true

	local tags = { DungeonRun = true, Owner = player.UserId }

	for _, position in LevelLayout.DungeonTrashPositions do
		EnemyService.Spawn("Trash", jittered(position), { Respawn = false, Tags = tags })
	end

	EnemyService.Spawn("Boss", LevelLayout.DungeonBossPosition, { Respawn = false, Tags = tags })

	Remotes.Notify:FireClient(player, "Dungeon run started - fight through to the boss!")
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
-- enemy death, so it can react specifically to a dungeon boss going down.
function DungeonService.HandleEnemyDied(enemy: Model, tierName: string, killer: Player?)
	if tierName ~= "Boss" or not enemy:GetAttribute("DungeonRun") then
		return
	end

	local ownerId = enemy:GetAttribute("Owner")
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	if owner then
		activeRuns[owner] = nil
		PlayerDataService.ReportQuestProgress(owner, "Dungeon")
	end

	-- Clear out any trash from this run the player left unkilled so the
	-- room doesn't accumulate corpses run after run.
	for _, model in Workspace:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Owner") == ownerId and model:GetAttribute("DungeonRun") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				model:Destroy()
			end
		end
	end

	if killer then
		Remotes.Notify:FireClient(killer, "Dungeon boss defeated!")
	end
end

local function onPlayerRemoving(player: Player)
	activeRuns[player] = nil
end

function DungeonService.Init()
	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return DungeonService
