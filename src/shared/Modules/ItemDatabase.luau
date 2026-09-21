--[[
	The item catalog: one entry per lootable item id. Weapons add to attack
	damage, armor/trinkets add to max health - deliberately simple stats so
	equipping something always feels like a straightforward upgrade.
]]

local ItemDatabase = {}

ItemDatabase.Items = {
	worn_dagger = { Name = "Worn Dagger", Rarity = "Common", Slot = "Weapon", DamageBonus = 1 },
	cloth_scraps = { Name = "Cloth Scraps", Rarity = "Common", Slot = "Armor", HealthBonus = 5 },
	traveler_charm = { Name = "Traveler's Charm", Rarity = "Common", Slot = "Trinket", HealthBonus = 3 },

	iron_sword = { Name = "Iron Sword", Rarity = "Uncommon", Slot = "Weapon", DamageBonus = 3 },
	leather_vest = { Name = "Leather Vest", Rarity = "Uncommon", Slot = "Armor", HealthBonus = 15 },
	swift_boots = { Name = "Swift Boots", Rarity = "Uncommon", Slot = "Trinket", HealthBonus = 10 },

	runed_blade = { Name = "Runed Blade", Rarity = "Rare", Slot = "Weapon", DamageBonus = 6 },
	chainmail_hauberk = { Name = "Chainmail Hauberk", Rarity = "Rare", Slot = "Armor", HealthBonus = 30 },
	ring_of_vigor = { Name = "Ring of Vigor", Rarity = "Rare", Slot = "Trinket", HealthBonus = 20 },

	frostbrand_greatsword = { Name = "Frostbrand Greatsword", Rarity = "Epic", Slot = "Weapon", DamageBonus = 12 },
	dragonscale_plate = { Name = "Dragonscale Plate", Rarity = "Epic", Slot = "Armor", HealthBonus = 60 },
	amulet_of_the_phoenix = { Name = "Amulet of the Phoenix", Rarity = "Epic", Slot = "Trinket", HealthBonus = 40 },

	worldsplitter = { Name = "Worldsplitter", Rarity = "Legendary", Slot = "Weapon", DamageBonus = 25 },
	aegis_of_the_first_king = { Name = "Aegis of the First King", Rarity = "Legendary", Slot = "Armor", HealthBonus = 120 },
	crown_of_eternity = { Name = "Crown of Eternity", Rarity = "Legendary", Slot = "Trinket", HealthBonus = 80 },
}

-- Built once: { [rarity]: { itemId, itemId, ... } }
ItemDatabase.IdsByRarity = {}
for itemId, item in ItemDatabase.Items do
	local list = ItemDatabase.IdsByRarity[item.Rarity]
	if not list then
		list = {}
		ItemDatabase.IdsByRarity[item.Rarity] = list
	end
	table.insert(list, itemId)
end

function ItemDatabase.PickRandomId(rarity: string): string
	local pool = ItemDatabase.IdsByRarity[rarity]
	return pool[math.random(1, #pool)]
end

return ItemDatabase
