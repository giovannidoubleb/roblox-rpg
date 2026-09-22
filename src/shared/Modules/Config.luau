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

	-- Caps for the Rare+ sustain gear stats (see ItemDatabase). Each stat
	-- only ever comes from one equipped item in one slot, so there's no
	-- stacking to worry about - these just keep a single item's roll sane.
	MaxLifestealPercent = 0.3,
	MaxDamageReductionPercent = 0.4,
	MaxCooldownReductionPercent = 0.4,
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

-- Power baseline by tier. Individual enemy "kinds" below pick a tier for
-- their numbers and layer on a look, and optionally ranged behavior via an
-- AttackRange override. TelegraphSeconds is a wind-up before a basic attack
-- lands - the enemy flashes and the hit is re-checked against range at the
-- end of it, so backing off during the flash actually avoids the hit
-- instead of it being purely cosmetic. Boss-only Slam* fields give every
-- boss a second, harder-hitting radius attack on its own cooldown.
Config.EnemyTiers = {
	Trash = {
		Health = 30,
		Damage = 5,
		AttackRange = 5,
		AttackCooldown = 1.5,
		TelegraphSeconds = 0.3,
		XpReward = 5,
		RespawnSeconds = 8,
		IsBoss = false,
	},
	Elite = {
		Health = 150,
		Damage = 12,
		AttackRange = 6,
		AttackCooldown = 2,
		TelegraphSeconds = 0.45,
		XpReward = 40,
		RespawnSeconds = 45,
		IsBoss = false,
	},
	Boss = {
		Health = 600,
		Damage = 20,
		AttackRange = 8,
		AttackCooldown = 2.5,
		TelegraphSeconds = 0.6,
		XpReward = 150,
		RespawnSeconds = 180,
		IsBoss = true,

		SlamCooldown = 9,
		SlamTelegraphSeconds = 1.2,
		SlamRadius = 12,
		SlamDamage = 30,
	},
}

-- Visual/behavioral flavors built on top of the tiers above - all still
-- code-built parts, no external assets. Ranged kinds get a bigger
-- AttackRange override so they can hang back and lob a bolt instead of
-- needing to close to melee. Behavior = "Kiter" backs away to KiteRange
-- instead of standing and trading hits once a player closes the distance -
-- everything else just chases into range (the default, "Melee" or unset).
Config.EnemyKinds = {
	Slime = { Tier = "Trash", Color = Color3.fromRGB(90, 200, 90), Shape = Enum.PartType.Ball, Ranged = false },
	Skeleton = { Tier = "Trash", Color = Color3.fromRGB(220, 220, 200), Shape = Enum.PartType.Block, Ranged = false },
	Bandit = { Tier = "Trash", Color = Color3.fromRGB(150, 110, 60), Shape = Enum.PartType.Block, Ranged = true, AttackRange = 22 },

	DireWolf = { Tier = "Elite", Color = Color3.fromRGB(80, 80, 100), Shape = Enum.PartType.Block, Ranged = false },
	Warlock = {
		Tier = "Elite",
		Color = Color3.fromRGB(120, 40, 160),
		Shape = Enum.PartType.Block,
		Ranged = true,
		AttackRange = 26,
		Behavior = "Kiter",
		KiteRange = 13,
	},

	StoneGolem = { Tier = "Boss", Color = Color3.fromRGB(120, 115, 100), Shape = Enum.PartType.Block, Ranged = false },
	AncientTreant = { Tier = "Boss", Color = Color3.fromRGB(70, 100, 50), Shape = Enum.PartType.Block, Ranged = true, AttackRange = 24 },
}

-- The daily dungeon's own twist so it isn't just the open-world grind in a
-- box: one random enemy per wave is upgraded to a tougher, better-rewarding
-- Champion, and the room periodically telegraphs a floor hazard players
-- have to step out of. See DungeonService.
Config.Dungeon = {
	Champion = {
		HealthMultiplier = 2.2,
		DamageMultiplier = 1.6,
		XpMultiplier = 1.5,
	},
	Hazard = {
		MinIntervalSeconds = 4,
		MaxIntervalSeconds = 7,
		TelegraphSeconds = 1.5,
		Radius = 8,
		Damage = 15,
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

-- One point per level-up, spent into a handful of permanent combat stats.
-- StatRespecToken refunds every spent point.
Config.SkillTree = {
	PointsPerLevel = 1,
	Stats = { Damage = true, Health = true, CritChance = true },
	DamagePerPoint = 1, -- flat bonus, stacks with weapon DamageBonus
	HealthPerPoint = 5, -- flat bonus, stacks with equipment HealthBonus
	CritChancePerPoint = 0.01, -- +1% crit chance per point
	MaxCritChance = 0.6,
	CritDamageMultiplier = 2,
}

-- Combine copies of a rarity into one guaranteed item of the next rarity up.
-- CraftingRush cuts CraftSeconds; the recipe consumes items of any type at
-- that rarity (not specific items) so any grind pays toward the next tier.
Config.Crafting = {
	CraftSeconds = 30,
	RushedCraftSeconds = 3,
	Recipes = {
		{ Id = "CommonToUncommon", ConsumeRarity = "Common", ConsumeCount = 4, ResultRarity = "Uncommon" },
		{ Id = "UncommonToRare", ConsumeRarity = "Uncommon", ConsumeCount = 4, ResultRarity = "Rare" },
		{ Id = "RareToEpic", ConsumeRarity = "Rare", ConsumeCount = 3, ResultRarity = "Epic" },
		{ Id = "EpicToLegendary", ConsumeRarity = "Epic", ConsumeCount = 3, ResultRarity = "Legendary" },
	},
}

-- Cosmetic follower pets - no combat stats, purely a gem sink and a reason
-- to visit the merchant. CompanionSlotExpansion (pass) raises how many can
-- be active at once.
Config.Companions = {
	BaseSlots = 1,
	ExpansionBonusSlots = 2,
	Available = {
		Sprite = { Name = "Sprite", GemCost = 150, Color = Color3.fromRGB(120, 220, 255), Shape = Enum.PartType.Ball },
		Ember = { Name = "Ember", GemCost = 250, Color = Color3.fromRGB(255, 130, 60), Shape = Enum.PartType.Ball },
		Golem = { Name = "Mini Golem", GemCost = 400, Color = Color3.fromRGB(140, 140, 100), Shape = Enum.PartType.Block },
		Wisp = { Name = "Wisp", GemCost = 600, Color = Color3.fromRGB(200, 120, 255), Shape = Enum.PartType.Ball },
	},
}

-- Palette/material re-skins for the player's character - no external art,
-- just recolors, so they work with zero Studio-authored assets. Mystery
-- Cosmetic Crate grants a random unowned one; the merchant sells specific
-- ones for gems.
Config.Cosmetics = {
	Available = {
		Crimson = { Name = "Crimson", GemCost = 200, Color = Color3.fromRGB(200, 40, 40), Material = Enum.Material.Neon },
		Azure = { Name = "Azure", GemCost = 200, Color = Color3.fromRGB(40, 120, 220), Material = Enum.Material.Neon },
		Gilded = { Name = "Gilded", GemCost = 500, Color = Color3.fromRGB(230, 190, 60), Material = Enum.Material.Metal },
		Shadow = { Name = "Shadow", GemCost = 500, Color = Color3.fromRGB(30, 30, 35), Material = Enum.Material.Slate },
		Prism = { Name = "Prism", GemCost = 900, Color = Color3.fromRGB(200, 255, 240), Material = Enum.Material.Glass },
	},
}

-- A long-running reward track gated by character level rather than a
-- separate XP counter, so ordinary play advances it. SeasonPass (game
-- pass) is required to claim a reached tier's reward.
Config.Season = {
	Tiers = {
		{ Level = 3, Gems = 40 },
		{ Level = 6, Gems = 60 },
		{ Level = 10, Gems = 90 },
		{ Level = 15, Gems = 120 },
		{ Level = 20, Gems = 160 },
		{ Level = 25, Gems = 220 },
		{ Level = 30, Gems = 300 },
		{ Level = 40, Gems = 450 },
		{ Level = 50, Gems = 700 },
	},
}

Config.Zones = {
	Hub = { DisplayName = "Hub" },
	Wilds = { DisplayName = "The Wilds" },
}

-- Robux asset ids from the Roblox Creator Dashboard. These are placeholders
-- (0 = "not created yet") - MonetizationService no-ops anything with id 0.
-- Fill these in once the passes/products exist in the experience's
-- Monetization page, then republish.
Config.Monetization = {
	-- SeasonPass lives here, not in DeveloperProducts: it's a permanent
	-- unlock (reward track access), which is what a Game Pass actually is on
	-- Roblox (UserOwnsGamePassAsync-checked, one-time purchase UI). A
	-- Developer Product is meant for repeatable/consumable buys; using one
	-- for a permanent unlock only worked here because the code re-implements
	-- ownership tracking itself, and it doesn't match how Roblox's own
	-- purchase prompt and refund handling treat that product type.
	GamePasses = {
		FoundersPass = 0,
		BackpackExpansion = 0,
		DoubleXp = 0,
		CompanionSlotExpansion = 0,
		FastTravel = 0,
		AutoSort = 0,
		SeasonPass = 0,
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
	},
	GemPouchAmounts = {
		GemPouchSmall = 100,
		GemPouchMedium = 300,
		GemPouchLarge = 700,
		GemPouchMega = 1600,
	},

	-- Founder's Pass: a one-time gem bonus plus a permanent XP boost for as
	-- long as it's owned.
	FounderBonusGems = 500,
	FounderXpBoost = 1.1,
}

return Config
