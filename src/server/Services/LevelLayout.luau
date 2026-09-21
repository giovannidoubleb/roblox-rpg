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

LevelLayout.FieldSpawns = {
	{ Tier = "Trash", Position = Vector3.new(15, 5, 5) },
	{ Tier = "Trash", Position = Vector3.new(-15, 5, 5) },
	{ Tier = "Trash", Position = Vector3.new(22, 5, -10) },
	{ Tier = "Trash", Position = Vector3.new(-22, 5, -10) },
	{ Tier = "Trash", Position = Vector3.new(0, 5, 25) },
	{ Tier = "Elite", Position = Vector3.new(28, 5, 25) },
}

LevelLayout.DungeonBossPosition = Vector3.new(0, 5, 195)

LevelLayout.DungeonTrashPositions = {
	Vector3.new(20, 5, 140),
	Vector3.new(-20, 5, 140),
	Vector3.new(0, 5, 155),
}

return LevelLayout
