--[[
	Rolls loot for a kill, adds it to the player's inventory, and tells the
	client. Boss kills roll on the chest table (better odds, pity-
	guaranteed Epic+ eventually) instead of the regular per-kill table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemDatabase = require(ReplicatedStorage.Shared.Modules.ItemDatabase)
local LootTable = require(ReplicatedStorage.Shared.Modules.LootTable)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local LootService = {}

local function grantAndNotify(player: Player, loot)
	local instanceId = PlayerDataService.AddInventoryItem(player, loot.ItemId)
	if not instanceId then
		-- Inventory was full; PlayerDataService already sent a Notify toast.
		return
	end

	local item = ItemDatabase.Items[loot.ItemId]
	Remotes.LootReceived:FireClient(player, { Rarity = loot.Rarity, Name = item.Name, ItemId = loot.ItemId })
end

function LootService.AwardKillLoot(player: Player)
	local loot = LootTable.RollKill()
	grantAndNotify(player, loot)
	return loot
end

function LootService.AwardBossLoot(player: Player)
	local pityForced = PlayerDataService.PeekPity(player)
	local loot = LootTable.RollChest(pityForced)
	PlayerDataService.RegisterBossKill(player, LootTable.IsEpicOrBetter(loot.Rarity))
	grantAndNotify(player, loot)
	return loot
end

return LootService
