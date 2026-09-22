--[[
	Server entry point. Boots services and wires the kill -> XP/loot/quest
	pipeline between them.

	Every require/Init below is pcall-isolated: one broken module warns
	loudly instead of silently halting everything after it (which is what
	was leaving players falling through an empty void with no HUD data -
	a single uncaught error anywhere in this file used to stop the whole
	script). A guaranteed safety floor is also built unconditionally so a
	fall-into-the-void can't happen even if a service is still broken.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function safeRequire(path: Instance)
	local ok, result = pcall(require, path)
	if not ok then
		warn(("[Boot] Failed to require %s: %s"):format(path:GetFullName(), tostring(result)))
		return nil
	end
	return result
end

local function safeInit(name: string, service: any)
	if not service then
		warn(("[Boot] Skipping %s.Init() - module failed to load"):format(name))
		return
	end
	local ok, err = pcall(service.Init)
	if not ok then
		warn(("[Boot] %s.Init() errored: %s"):format(name, tostring(err)))
	end
end

-- Guaranteed floor + spawn so a broken MapService can never drop a player
-- into an endless fall. MapService.Init() below builds over/replaces this
-- with the real level once it succeeds.
if not Workspace:FindFirstChild("SafetyFloor") then
	local floor = Instance.new("Part")
	floor.Name = "SafetyFloor"
	floor.Anchored = true
	floor.Size = Vector3.new(500, 1, 500)
	floor.Position = Vector3.new(0, -1, 0)
	floor.Color = Color3.fromRGB(40, 40, 40)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = Workspace

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SafetySpawn"
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, 0.5, -20)
	spawn.Anchored = true
	spawn.Transparency = 1
	spawn.Parent = Workspace
end

local Config = safeRequire(ReplicatedStorage.Shared.Modules.Config)
local Remotes = safeRequire(ReplicatedStorage.Shared.Remotes)

local MapService = safeRequire(script.Services.MapService)
local PlayerDataService = safeRequire(script.Services.PlayerDataService)
local LootService = safeRequire(script.Services.LootService)
local EnemyService = safeRequire(script.Services.EnemyService)
local CombatService = safeRequire(script.Services.CombatService)
local DungeonService = safeRequire(script.Services.DungeonService)
local MonetizationService = safeRequire(script.Services.MonetizationService)
local ZoneService = safeRequire(script.Services.ZoneService)
local NpcService = safeRequire(script.Services.NpcService)
local ProgressionService = safeRequire(script.Services.ProgressionService)
local CraftingService = safeRequire(script.Services.CraftingService)
local CompanionService = safeRequire(script.Services.CompanionService)

safeInit("MapService", MapService)
safeInit("PlayerDataService", PlayerDataService)
safeInit("CombatService", CombatService)
safeInit("DungeonService", DungeonService)
safeInit("MonetizationService", MonetizationService)
safeInit("ZoneService", ZoneService)
safeInit("NpcService", NpcService)
safeInit("ProgressionService", ProgressionService)
safeInit("CraftingService", CraftingService)
safeInit("CompanionService", CompanionService)

if EnemyService then
	EnemyService.SetOnEnemyDied(function(enemy, tierName, killer)
		if killer then
			local tier = Config.EnemyTiers[tierName]
			local isChampion = enemy:GetAttribute("Champion") == true

			local xp = tier.XpReward
			if isChampion then
				xp = math.floor(xp * Config.Dungeon.Champion.XpMultiplier)
			end
			PlayerDataService.AddExperience(killer, xp)
			PlayerDataService.ReportQuestProgress(killer, tierName)

			if tier.IsBoss then
				LootService.AwardBossLoot(killer)
			else
				LootService.AwardKillLoot(killer)
			end

			-- Dungeon Champion: a guaranteed bonus roll on top of the normal
			-- kill drop, on the theory that beating the wave's hardest hit is
			-- worth more than one more identical trash drop.
			if isChampion then
				LootService.AwardKillLoot(killer)
				Remotes.Notify:FireClient(killer, "Champion defeated - bonus loot!")
			end
		end

		if DungeonService then
			DungeonService.HandleEnemyDied(enemy, tierName, killer)
		end
	end)
end

safeInit("EnemyService", EnemyService)
