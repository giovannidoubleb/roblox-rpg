--[[
	Server entry point. Boots services and wires the kill -> XP/loot
	pipeline between them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Modules.Config)

local MapService = require(script.Services.MapService)
local PlayerDataService = require(script.Services.PlayerDataService)
local LootService = require(script.Services.LootService)
local EnemyService = require(script.Services.EnemyService)
local CombatService = require(script.Services.CombatService)

MapService.Init()
PlayerDataService.Init()
CombatService.Init()

EnemyService.SetOnEnemyDied(function(_enemy, tierName, killer)
	if not killer then
		return
	end

	local tier = Config.EnemyTiers[tierName]
	PlayerDataService.AddExperience(killer, tier.XpReward)

	if tier.IsBoss then
		LootService.AwardBossLoot(killer)
	else
		LootService.AwardKillLoot(killer)
	end
end)

EnemyService.Init()
