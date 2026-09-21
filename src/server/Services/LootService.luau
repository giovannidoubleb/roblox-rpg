--[[
	Rolls loot for a kill and tells the client. Boss kills roll on the
	chest table (better odds, pity-guaranteed Epic+ eventually) instead of
	the regular per-kill table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootTable = require(ReplicatedStorage.Shared.Modules.LootTable)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local LootService = {}

function LootService.AwardKillLoot(player: Player)
	local loot = LootTable.RollKill()
	Remotes.LootReceived:FireClient(player, loot)
	return loot
end

function LootService.AwardBossLoot(player: Player)
	local pityForced = PlayerDataService.PeekPity(player)
	local loot = LootTable.RollChest(pityForced)
	PlayerDataService.RegisterBossKill(player, LootTable.IsEpicOrBetter(loot.Rarity))
	Remotes.LootReceived:FireClient(player, loot)
	return loot
end

return LootService
