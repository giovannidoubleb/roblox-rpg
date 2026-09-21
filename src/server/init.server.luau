--[[
	Server entry point. Boots services and wires the kill -> XP/loot/quest
	pipeline between them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Modules.Config)

local MapService = require(script.Services.MapService)
local PlayerDataService = require(script.Services.PlayerDataService)
local LootService = require(script.Services.LootService)
local EnemyService = require(script.Services.EnemyService)
local CombatService = require(script.Services.CombatService)
local DungeonService = require(script.Services.DungeonService)
local MonetizationService = require(script.Services.MonetizationService)

MapService.Init()
PlayerDataService.Init()
CombatService.Init()
DungeonService.Init()
MonetizationService.Init()

EnemyService.SetOnEnemyDied(function(enemy, tierName, killer)
	if killer then
		local tier = Config.EnemyTiers[tierName]
		PlayerDataService.AddExperience(killer, tier.XpReward)
		PlayerDataService.ReportQuestProgress(killer, tierName)

		if tier.IsBoss then
			LootService.AwardBossLoot(killer)
		else
			LootService.AwardKillLoot(killer)
		end
	end

	DungeonService.HandleEnemyDied(enemy, tierName, killer)
end)

EnemyService.Init()
