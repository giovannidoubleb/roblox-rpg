--[[
	Builds the hub, corridor, and dungeon rooms at runtime from parts, plus
	the dungeon entrance portal. Still code-built blockout geometry rather
	than Studio-authored art (no assets exist yet), but it's a connected
	layout instead of enemies floating on a bare plane - see LevelLayout
	for the actual coordinates, shared with EnemyService/DungeonService.
]]

local Workspace = game:GetService("Workspace")

local LevelLayout = require(script.Parent.LevelLayout)

local MapService = {}

local WALL_THICKNESS = 2

local function buildFloor(folder: Instance, name: string, center: Vector3, halfSize: Vector3, color: Color3)
	local floor = Instance.new("Part")
	floor.Name = name .. "Floor"
	floor.Anchored = true
	floor.Size = Vector3.new(halfSize.X * 2, 1, halfSize.Z * 2)
	floor.CFrame = CFrame.new(center.X, center.Y - 0.5, center.Z)
	floor.Color = color
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = folder
end

local function buildWalls(folder: Instance, name: string, center: Vector3, halfSize: Vector3, wallHeight: number, color: Color3, skipSides: { [string]: boolean })
	local wallY = center.Y + wallHeight / 2
	local specs = {
		North = {
			Size = Vector3.new(halfSize.X * 2 + WALL_THICKNESS * 2, wallHeight, WALL_THICKNESS),
			Position = Vector3.new(center.X, wallY, center.Z + halfSize.Z + WALL_THICKNESS / 2),
		},
		South = {
			Size = Vector3.new(halfSize.X * 2 + WALL_THICKNESS * 2, wallHeight, WALL_THICKNESS),
			Position = Vector3.new(center.X, wallY, center.Z - halfSize.Z - WALL_THICKNESS / 2),
		},
		East = {
			Size = Vector3.new(WALL_THICKNESS, wallHeight, halfSize.Z * 2),
			Position = Vector3.new(center.X + halfSize.X + WALL_THICKNESS / 2, wallY, center.Z),
		},
		West = {
			Size = Vector3.new(WALL_THICKNESS, wallHeight, halfSize.Z * 2),
			Position = Vector3.new(center.X - halfSize.X - WALL_THICKNESS / 2, wallY, center.Z),
		},
	}

	for side, spec in specs do
		if not skipSides[side] then
			local wall = Instance.new("Part")
			wall.Name = name .. side .. "Wall"
			wall.Anchored = true
			wall.Size = spec.Size
			wall.CFrame = CFrame.new(spec.Position)
			wall.Color = color
			wall.Material = Enum.Material.Brick
			wall.Parent = folder
		end
	end
end

local function buildPortal(folder: Instance)
	local portal = Instance.new("Part")
	portal.Name = "DungeonPortal"
	portal.Anchored = true
	portal.CanCollide = false
	portal.Size = Vector3.new(6, 8, 1)
	portal.Position = LevelLayout.DungeonPortal
	portal.Color = Color3.fromRGB(120, 60, 200)
	portal.Material = Enum.Material.Neon
	portal.Transparency = 0.4
	portal.Parent = folder

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterDungeonPrompt"
	prompt.ActionText = "Enter Dungeon"
	prompt.ObjectText = "Daily Dungeon (1 key)"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.Parent = portal
end

local function buildShrine(folder: Instance, name: string, position: Vector3, promptName: string, actionText: string, objectText: string)
	local shrine = Instance.new("Part")
	shrine.Name = name
	shrine.Anchored = true
	shrine.CanCollide = true
	shrine.Shape = Enum.PartType.Cylinder
	shrine.Size = Vector3.new(6, 2, 2)
	shrine.Orientation = Vector3.new(0, 0, 90)
	shrine.Position = position
	shrine.Color = Color3.fromRGB(80, 200, 220)
	shrine.Material = Enum.Material.Neon
	shrine.Parent = folder

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = promptName
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.Parent = shrine
end

-- A private, fully-enclosed copy of just the dungeon room, offset far from
-- the hub/wilds/every other instance so concurrent runs never see or aggro
-- each other. DungeonService builds and tears one of these down per run
-- instead of using the always-there room the corridor walks into (that one
-- stays as hub-adjacent scenery).
function MapService.BuildDungeonInstance(offset: Vector3): Folder
	local folder = Instance.new("Folder")
	folder.Name = "DungeonInstance"
	folder.Parent = Workspace

	local center = LevelLayout.DungeonRoom.Center + offset
	buildFloor(folder, "Dungeon", center, LevelLayout.DungeonRoom.HalfSize, Color3.fromRGB(50, 40, 60))
	buildWalls(folder, "Dungeon", center, LevelLayout.DungeonRoom.HalfSize, LevelLayout.DungeonRoom.WallHeight, Color3.fromRGB(70, 60, 80), {})

	return folder
end

function MapService.Init()
	if Workspace:FindFirstChild("Level") then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "Level"
	folder.Parent = Workspace

	buildFloor(folder, "Hub", LevelLayout.Hub.Center, LevelLayout.Hub.HalfSize, Color3.fromRGB(60, 120, 60))
	buildWalls(folder, "Hub", LevelLayout.Hub.Center, LevelLayout.Hub.HalfSize, LevelLayout.Hub.WallHeight, Color3.fromRGB(90, 90, 90), { North = true })

	buildFloor(folder, "Corridor", LevelLayout.Corridor.Center, LevelLayout.Corridor.HalfSize, Color3.fromRGB(100, 100, 100))
	buildWalls(folder, "Corridor", LevelLayout.Corridor.Center, LevelLayout.Corridor.HalfSize, LevelLayout.Corridor.WallHeight, Color3.fromRGB(90, 90, 90), { North = true, South = true })

	buildFloor(folder, "Dungeon", LevelLayout.DungeonRoom.Center, LevelLayout.DungeonRoom.HalfSize, Color3.fromRGB(50, 40, 60))
	buildWalls(folder, "Dungeon", LevelLayout.DungeonRoom.Center, LevelLayout.DungeonRoom.HalfSize, LevelLayout.DungeonRoom.WallHeight, Color3.fromRGB(70, 60, 80), { South = true })

	buildPortal(folder)
	buildShrine(folder, "HubShrine", LevelLayout.HubShrinePosition, "TravelToWildsPrompt", "Travel", "The Wilds")

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = LevelLayout.PlayerSpawn
	spawn.Anchored = true
	spawn.Transparency = 1
	spawn.Parent = folder

	buildFloor(folder, "Wilds", LevelLayout.Wilds.Center, LevelLayout.Wilds.HalfSize, Color3.fromRGB(70, 100, 50))
	buildWalls(folder, "Wilds", LevelLayout.Wilds.Center, LevelLayout.Wilds.HalfSize, LevelLayout.Wilds.WallHeight, Color3.fromRGB(60, 80, 45), {})
	buildShrine(folder, "WildsShrine", LevelLayout.WildsShrinePosition, "TravelToHubPrompt", "Travel", "The Hub")
end

return MapService
