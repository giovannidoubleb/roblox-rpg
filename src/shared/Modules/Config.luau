--[[
	Central tunable RPG constants shared by server and client. Numbers here
	come from the "Core RPG Loop Design" doc: XP curve, level cap, loot
	rarity tables, pity threshold, and the daily key gate.
]]

local Config = {}

Config.Leveling = {
	MaxLevel = 50,
	BaseXp = 50,
	Exponent = 1.5,
	HealthPerLevel = 10,
}

function Config.GetXpToNextLevel(level: number): number
	return math.floor(Config.Leveling.BaseXp * (level ^ Config.Leveling.Exponent))
end

Config.StartingStats = {
	Level = 1,
	Experience = 0,
	MaxHealth = 100,
}

Config.Combat = {
	BasicAttack = {
		Damage = 10,
		Cooldown = 0.75,
		Range = 8,
	},

	-- 2-3 active skills per the design doc; Cleave hits everything in a
	-- frontal arc, Power Strike is a single-target burst.
	Skills = {
		Cleave = {
			Damage = 8,
			Cooldown = 6,
			Range = 9,
		},
		PowerStrike = {
			Damage = 28,
			Cooldown = 10,
			Range = 8,
		},
	},

	-- Meter fills from basic attacks; at MeterMax the player can trigger a
	-- radius nova around themselves (no facing requirement).
	Ultimate = {
		Damage = 55,
		Radius = 16,
		MeterPerBasicAttack = 12,
		MeterMax = 100,
	},
}

-- Order matters: rarity roll tables below are cumulative in this order.
Config.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- Every trash/elite kill rolls on this table (always drops something).
Config.KillDropRates = {
	Common = 0.55,
	Uncommon = 0.28,
	Rare = 0.12,
	Epic = 0.045,
	Legendary = 0.005,
}

-- Boss/end-of-run chest roll: a separate, better-weighted roll that never
-- lands below Uncommon.
Config.ChestDropRates = {
	Uncommon = 0.40,
	Rare = 0.35,
	Epic = 0.20,
	Legendary = 0.05,
}

Config.Pity = {
	-- Boss kills since the player's last Epic-or-better drop before one is
	-- guaranteed.
	BossKillThreshold = 15,
}

Config.EnemyTiers = {
	Trash = {
		Health = 30,
		Damage = 5,
		AttackRange = 5,
		AttackCooldown = 1.5,
		XpReward = 5,
		RespawnSeconds = 8,
		IsBoss = false,
	},
	Elite = {
		Health = 150,
		Damage = 12,
		AttackRange = 6,
		AttackCooldown = 2,
		XpReward = 40,
		RespawnSeconds = 45,
		IsBoss = false,
	},
	Boss = {
		Health = 600,
		Damage = 20,
		AttackRange = 8,
		AttackCooldown = 2.5,
		XpReward = 150,
		RespawnSeconds = 180,
		IsBoss = true,
	},
}

Config.Daily = {
	KeysPerDay = 3,
	KeyRegenSeconds = 8 * 60 * 60,

	QuestCount = 3,
	-- One claim per calendar day; a claim on the day right after the last
	-- one continues the streak, anything later resets it. "Grace" here
	-- just means the reset check is by calendar day, not a hard deadline.
	StreakRewardGems = { 50, 60, 70, 80, 90, 100, 200 },

	QuestPool = {
		{ Id = "KillTrash10", Description = "Defeat 10 trash mobs", Tier = "Trash", Target = 10, XpReward = 300, GemReward = 20 },
		{ Id = "KillTrash20", Description = "Defeat 20 trash mobs", Tier = "Trash", Target = 20, XpReward = 350, GemReward = 25 },
		{ Id = "KillElite1", Description = "Defeat 1 elite", Tier = "Elite", Target = 1, XpReward = 400, GemReward = 30 },
		{ Id = "KillElite2", Description = "Defeat 2 elites", Tier = "Elite", Target = 2, XpReward = 450, GemReward = 35 },
		{ Id = "KillAny15", Description = "Defeat 15 enemies of any kind", Tier = "Any", Target = 15, XpReward = 300, GemReward = 20 },
		{ Id = "CompleteDungeon1", Description = "Complete the daily dungeon", Tier = "Dungeon", Target = 1, XpReward = 500, GemReward = 50 },
	},
}

Config.Inventory = {
	BaseSlots = 20,
	-- Matches the Backpack Expansion Game Pass in the monetization plan.
	BackpackExpansionBonusSlots = 20,
}

-- Robux asset ids from the Roblox Creator Dashboard. These are placeholders
-- (0 = "not created yet") - MonetizationService no-ops anything with id 0.
-- Fill these in once the passes/products exist in the experience's
-- Monetization page, then republish.
Config.Monetization = {
	GamePasses = {
		FoundersPass = 0,
		BackpackExpansion = 0,
		DoubleXp = 0,
		CompanionSlotExpansion = 0,
		FastTravel = 0,
		AutoSort = 0,
	},
	DeveloperProducts = {
		GemPouchSmall = 0,
		GemPouchMedium = 0,
		GemPouchLarge = 0,
		GemPouchMega = 0,
		StatRespecToken = 0,
		InstantReviveToken = 0,
		MysteryCosmeticCrate = 0,
		CharacterRenameToken = 0,
		ZoneSkipKey = 0,
		CraftingRush = 0,
		SeasonPass = 0,
	},
	GemPouchAmounts = {
		GemPouchSmall = 100,
		GemPouchMedium = 300,
		GemPouchLarge = 700,
		GemPouchMega = 1600,
	},
}

return Config
