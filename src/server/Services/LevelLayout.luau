--[[
	Coordinates for the hand-authored-in-code layout: a hub room (open
	field grinding + the dungeon portal), a corridor, and a dungeon room.
	Shared by MapService (builds the geometry), EnemyService (field
	spawns), and DungeonService (portal + dungeon wave spawns) so they
	agree on where things are. This replaces floating enemies on a bare
	plane with actual connected rooms - it's still code-built blockout
	geometry, not Studio-authored art.
]]

local LevelLayout = {}

LevelLayout.Hub = {
	Center = Vector3.new(0, 0, 0),
	HalfSize = Vector3.new(40, 0, 40),
	WallHeight = 20,
}

LevelLayout.Corridor = {
	Center = Vector3.new(0, 0, 70),
	HalfSize = Vector3.new(8, 0, 30),
	WallHeight = 12,
}

LevelLayout.DungeonRoom = {
	Center = Vector3.new(0, 0, 160),
	HalfSize = Vector3.new(60, 0, 60),
	WallHeight = 24,
}

LevelLayout.PlayerSpawn = Vector3.new(0, 1, -20)

LevelLayout.DungeonPortal = Vector3.new(0, 4, 38)

-- Kept outside the field spawns' aggro range (see EnemyService) so a fresh
-- spawn isn't immediately swarmed.
LevelLayout.FieldSpawns = {
	{ Kind = "Slime", Position = Vector3.new(15, 5, 5) },
	{ Kind = "Skeleton", Position = Vector3.new(-15, 5, 5) },
	{ Kind = "Slime", Position = Vector3.new(22, 5, -10) },
	{ Kind = "Bandit", Position = Vector3.new(-22, 5, -10) },
	{ Kind = "Skeleton", Position = Vector3.new(0, 5, 25) },
	{ Kind = "DireWolf", Position = Vector3.new(28, 5, 25) },
}

LevelLayout.DungeonEntryPosition = Vector3.new(0, 5, 110)
LevelLayout.DungeonBossPosition = Vector3.new(0, 5, 195)

-- Wave composition and boss rotate on independent day-based cycles (see
-- DungeonService.selectVariant/selectBoss), so the pairing isn't always the
-- same two "flavors of one thing" - 2 wave sets x 2 bosses gives 4
-- distinguishable dungeon days before the combination repeats, not 2.
-- Waves reuse the same spawn positions across variants (each position was
-- tuned to be sensible within DungeonRoom's bounds); only Kind changes.
LevelLayout.DungeonVariants = {
	{
		Name = "Stonebound Depths",
		Waves = {
			{
				{ Kind = "Skeleton", Position = Vector3.new(20, 5, 130) },
				{ Kind = "Skeleton", Position = Vector3.new(-20, 5, 130) },
				{ Kind = "Slime", Position = Vector3.new(0, 5, 122) },
				{ Kind = "Bandit", Position = Vector3.new(12, 5, 118) },
			},
			{
				{ Kind = "Skeleton", Position = Vector3.new(25, 5, 150) },
				{ Kind = "Skeleton", Position = Vector3.new(-25, 5, 150) },
				{ Kind = "Slime", Position = Vector3.new(15, 5, 155) },
				{ Kind = "Slime", Position = Vector3.new(-15, 5, 155) },
				{ Kind = "Bandit", Position = Vector3.new(0, 5, 148) },
			},
			{
				{ Kind = "DireWolf", Position = Vector3.new(15, 5, 172) },
				{ Kind = "DireWolf", Position = Vector3.new(-15, 5, 172) },
				{ Kind = "Warlock", Position = Vector3.new(0, 5, 178) },
			},
		},
	},
	{
		-- An "ambush" flavor: more ranged/kiting enemies (Bandit, Warlock)
		-- instead of Stonebound's melee-heavy trash - a genuinely different
		-- fight, not just a recolor of the same waves.
		Name = "Wilds Incursion",
		Waves = {
			{
				{ Kind = "Bandit", Position = Vector3.new(20, 5, 130) },
				{ Kind = "Bandit", Position = Vector3.new(-20, 5, 130) },
				{ Kind = "Slime", Position = Vector3.new(0, 5, 122) },
				{ Kind = "Skeleton", Position = Vector3.new(12, 5, 118) },
			},
			{
				{ Kind = "DireWolf", Position = Vector3.new(25, 5, 150) },
				{ Kind = "DireWolf", Position = Vector3.new(-25, 5, 150) },
				{ Kind = "Bandit", Position = Vector3.new(15, 5, 155) },
				{ Kind = "Bandit", Position = Vector3.new(-15, 5, 155) },
				{ Kind = "Skeleton", Position = Vector3.new(0, 5, 148) },
			},
			{
				{ Kind = "Warlock", Position = Vector3.new(15, 5, 172) },
				{ Kind = "Warlock", Position = Vector3.new(-15, 5, 172) },
				{ Kind = "DireWolf", Position = Vector3.new(0, 5, 178) },
			},
		},
	},
}

-- Rotates on its own day-based cycle, independent of DungeonVariants above -
-- see DungeonService.selectBoss.
LevelLayout.DungeonBosses = {
	{ Kind = "StoneGolem", Name = "the Stone Golem" },
	{ Kind = "AncientTreant", Name = "the Ancient Treant" },
}

-- The Wilds: a second zone reached via the hub's travel shrine, built far
-- enough away in the same Workspace that it never overlaps the hub/dungeon.
-- See ZoneService for the shrine travel logic.
local WILDS_OFFSET = Vector3.new(600, 0, 0)
LevelLayout.WildsOffset = WILDS_OFFSET

LevelLayout.Wilds = {
	Center = WILDS_OFFSET,
	HalfSize = Vector3.new(70, 0, 70),
	WallHeight = 22,
}

LevelLayout.WildsSpawn = WILDS_OFFSET + Vector3.new(0, 1, -50)
LevelLayout.HubShrinePosition = Vector3.new(-34, 3, -30)
LevelLayout.QuestGiverPosition = Vector3.new(8, 1, -28)
LevelLayout.MerchantPosition = Vector3.new(-8, 1, -28)
LevelLayout.WildsShrinePosition = WILDS_OFFSET + Vector3.new(0, 3, -50)

LevelLayout.WildsFieldSpawns = {
	{ Kind = "DireWolf", Position = WILDS_OFFSET + Vector3.new(20, 5, 0) },
	{ Kind = "DireWolf", Position = WILDS_OFFSET + Vector3.new(-20, 5, 0) },
	{ Kind = "Warlock", Position = WILDS_OFFSET + Vector3.new(30, 5, 20) },
	{ Kind = "Warlock", Position = WILDS_OFFSET + Vector3.new(-30, 5, 20) },
	{ Kind = "Bandit", Position = WILDS_OFFSET + Vector3.new(0, 5, 30) },
	{ Kind = "Bandit", Position = WILDS_OFFSET + Vector3.new(15, 5, 40) },
}

LevelLayout.WildsBossKind = "AncientTreant"
LevelLayout.WildsBossPosition = WILDS_OFFSET + Vector3.new(0, 6, 55)

return LevelLayout
