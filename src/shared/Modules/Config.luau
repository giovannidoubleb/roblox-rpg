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
}

return Config
