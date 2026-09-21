--[[
	Rolls a rarity off the kill or chest tables in Config, and picks an item
	id of that rarity from ItemDatabase.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Modules.Config)
local ItemDatabase = require(ReplicatedStorage.Shared.Modules.ItemDatabase)

local LootTable = {}

local function rollRarity(rates: { [string]: number }): string
	local roll = math.random()
	local cumulative = 0
	for _, rarity in Config.RarityOrder do
		local rate = rates[rarity]
		if rate then
			cumulative += rate
			if roll <= cumulative then
				return rarity
			end
		end
	end

	-- Floating point rounding safety net: fall back to the lowest tier this
	-- table defines.
	for _, rarity in Config.RarityOrder do
		if rates[rarity] then
			return rarity
		end
	end

	error("rollRarity: rates table has no entries")
end

function LootTable.RollKill()
	local rarity = rollRarity(Config.KillDropRates)
	return { Rarity = rarity, ItemId = ItemDatabase.PickRandomId(rarity) }
end

-- pityForced: true when the pity counter is forcing an Epic+ result.
function LootTable.RollChest(pityForced: boolean)
	local rarity
	if pityForced then
		rarity = math.random() <= (Config.ChestDropRates.Legendary / (Config.ChestDropRates.Epic + Config.ChestDropRates.Legendary))
				and "Legendary"
			or "Epic"
	else
		rarity = rollRarity(Config.ChestDropRates)
	end
	return { Rarity = rarity, ItemId = ItemDatabase.PickRandomId(rarity) }
end

function LootTable.IsEpicOrBetter(rarity: string): boolean
	return rarity == "Epic" or rarity == "Legendary"
end

return LootTable
