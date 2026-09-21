--[[
	Creates a placeholder ground plane and spawn point at runtime so the
	scaffold is playable with an empty Workspace - no Studio-authored level
	yet. A real level replaces this entirely.
]]

local Workspace = game:GetService("Workspace")

local MapService = {}

function MapService.Init()
	if Workspace:FindFirstChild("Baseplate") then
		return
	end

	local baseplate = Instance.new("Part")
	baseplate.Name = "Baseplate"
	baseplate.Size = Vector3.new(200, 1, 200)
	baseplate.Position = Vector3.new(0, 0, 0)
	baseplate.Anchored = true
	baseplate.Material = Enum.Material.Grass
	baseplate.Color = Color3.fromRGB(60, 120, 60)
	baseplate.Parent = Workspace

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, 1, -15)
	spawn.Anchored = true
	spawn.Transparency = 1
	spawn.Parent = Workspace
end

return MapService
