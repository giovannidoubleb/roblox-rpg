-- CITY GRIND: doors and interiors.
-- Interiors are built high above the city (Places.REGIONS) and connected to a
-- building's front door with a ProximityPrompt. The player attribute "Interior"
-- holds the interior's name while they are inside ("" outside).

local Players = game:GetService("Players")

local Net = require(script.Parent:WaitForChild("Net"))

local Places = {}

-- Reserved space for each interior. Each region is a 240 x 240 stud square
-- whose floor sits at the region's Y. Keep builds inside their square.
Places.REGIONS = {
	Gym = Vector3.new(0, 600, 0),
	Threads = Vector3.new(300, 600, 0),
	Barber = Vector3.new(600, 600, 0),
	CornerMart = Vector3.new(900, 600, 0),
	Kitchen = Vector3.new(1200, 600, 0),
	Dealership = Vector3.new(1500, 600, 0),
	JobCenter = Vector3.new(1800, 600, 0),
}

-- Apartment units: one per server slot, each in its own 240 x 240 square.
function Places.apartmentSlot(slot: number): Vector3
	return Vector3.new(0, 1200, slot * 300)
end

-- Moves a player's character, standing upright at `cf`.
function Places.teleport(player: Player, cf: CFrame)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return
	end
	if humanoid.SeatPart then
		humanoid.Sit = false
		task.wait()
	end
	character:PivotTo(cf + Vector3.new(0, 3, 0))
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

-- The front door part of a building made by CityBuilder.building().
function Places.buildingDoor(city: Instance, buildingName: string): BasePart?
	local buildings = city:FindFirstChild("Buildings")
	local model = buildings and buildings:FindFirstChild(buildingName, true)
	local door = model and model:FindFirstChild("Door")
	return if door and door:IsA("BasePart") then door else nil
end

export type DoorOptions = {
	name: string, -- interior name, e.g. "Gym"
	door: BasePart, -- the outside door the prompt goes on
	inside: CFrame, -- where players appear inside
	exitAt: Vector3, -- where the exit door/prompt sits inside
	outside: CFrame?, -- where players appear when leaving (default: in front of the door)
	actionText: string?,
	canEnter: ((Player) -> (boolean, string?))?, -- optional gate, returns (ok, reason)
	onEnter: ((Player) -> ())?,
	onExit: ((Player) -> ())?,
	parent: Instance,
}

-- Wires a two-way door. Returns the exit door part built inside.
function Places.door(opts: DoorOptions): BasePart
	local enterPrompt = Instance.new("ProximityPrompt")
	enterPrompt.Name = "Enter" .. opts.name
	enterPrompt.ActionText = opts.actionText or "Enter"
	enterPrompt.ObjectText = opts.name
	enterPrompt.KeyboardKeyCode = Enum.KeyCode.E
	enterPrompt.MaxActivationDistance = 10
	enterPrompt.RequiresLineOfSight = false
	enterPrompt.Parent = opts.door

	-- default exit spot: 6 studs out from the door's face, facing away from it
	local outside = opts.outside
	if not outside then
		local door = opts.door
		local look = door.CFrame.LookVector
		local front = door.Position + look * 6
		local behind = door.Position - look * 6
		-- whichever side is further from the building's centre (door's parent model) is "out"
		local model = door.Parent
		local center = if model and model:IsA("Model") then model:GetPivot().Position else door.Position
		local spot = if (front - center).Magnitude > (behind - center).Magnitude then front else behind
		outside = CFrame.lookAt(Vector3.new(spot.X, door.Position.Y - door.Size.Y / 2, spot.Z), Vector3.new(spot.X, door.Position.Y - door.Size.Y / 2, spot.Z) + (spot - door.Position) * Vector3.new(1, 0, 1))
	end

	local exitDoor = Instance.new("Part")
	exitDoor.Name = "ExitDoor"
	exitDoor.Anchored = true
	exitDoor.Size = Vector3.new(6, 9, 0.4)
	exitDoor.CFrame = CFrame.new(opts.exitAt + Vector3.new(0, 4.5, 0))
	exitDoor.Color = Color3.fromRGB(45, 35, 30)
	exitDoor.Material = Enum.Material.Wood
	exitDoor.Parent = opts.parent
	local exitPrompt = Instance.new("ProximityPrompt")
	exitPrompt.Name = "Exit"
	exitPrompt.ActionText = "Leave"
	exitPrompt.ObjectText = opts.name
	exitPrompt.KeyboardKeyCode = Enum.KeyCode.E
	exitPrompt.MaxActivationDistance = 10
	exitPrompt.RequiresLineOfSight = false
	exitPrompt.Parent = exitDoor

	enterPrompt.Triggered:Connect(function(player)
		if (player:GetAttribute("Interior") or "") ~= "" then
			return
		end
		if opts.canEnter then
			local ok, reason = opts.canEnter(player)
			if not ok then
				if reason then
					Net.notify(player, opts.name:upper(), reason)
				end
				return
			end
		end
		player:SetAttribute("Interior", opts.name)
		Places.teleport(player, opts.inside)
		if opts.onEnter then
			opts.onEnter(player)
		end
	end)
	exitPrompt.Triggered:Connect(function(player)
		if player:GetAttribute("Interior") ~= opts.name then
			return
		end
		Places.leave(player, outside :: CFrame)
		if opts.onExit then
			opts.onExit(player)
		end
	end)
	return exitDoor
end

-- Puts a player back outside and clears their interior.
function Places.leave(player: Player, outside: CFrame)
	player:SetAttribute("Interior", "")
	Places.teleport(player, outside)
end

-- Respawning always puts you back outside.
local function track(player: Player)
	player:SetAttribute("Interior", "")
	player.CharacterAdded:Connect(function()
		player:SetAttribute("Interior", "")
	end)
end
Players.PlayerAdded:Connect(track)
for _, player in Players:GetPlayers() do
	track(player)
end

-- A plain box room (floor, 4 walls, ceiling with lights) centred on `origin`.
-- Returns the model. Size is the inside dimensions.
function Places.room(name: string, origin: Vector3, size: Vector3, opts: { floorColor: Color3?, floorMaterial: Enum.Material?, wallColor: Color3?, parent: Instance }): Model
	local m = Instance.new("Model")
	m.Name = name
	local function p(pname: string, psize: Vector3, cf: CFrame, color: Color3, material: Enum.Material)
		local b = Instance.new("Part")
		b.Name = pname
		b.Anchored = true
		b.Size = psize
		b.CFrame = cf
		b.Color = color
		b.Material = material
		b.TopSurface = Enum.SurfaceType.Smooth
		b.BottomSurface = Enum.SurfaceType.Smooth
		b.Parent = m
		return b
	end
	local wall = opts.wallColor or Color3.fromRGB(225, 222, 215)
	p("Floor", Vector3.new(size.X + 2, 1, size.Z + 2), CFrame.new(origin - Vector3.new(0, 0.5, 0)), opts.floorColor or Color3.fromRGB(150, 120, 90), opts.floorMaterial or Enum.Material.WoodPlanks)
	p("Ceiling", Vector3.new(size.X + 2, 1, size.Z + 2), CFrame.new(origin + Vector3.new(0, size.Y + 0.5, 0)), Color3.fromRGB(240, 240, 240), Enum.Material.SmoothPlastic)
	p("Wall", Vector3.new(1, size.Y, size.Z + 2), CFrame.new(origin + Vector3.new(size.X / 2 + 0.5, size.Y / 2, 0)), wall, Enum.Material.SmoothPlastic)
	p("Wall", Vector3.new(1, size.Y, size.Z + 2), CFrame.new(origin + Vector3.new(-size.X / 2 - 0.5, size.Y / 2, 0)), wall, Enum.Material.SmoothPlastic)
	p("Wall", Vector3.new(size.X, size.Y, 1), CFrame.new(origin + Vector3.new(0, size.Y / 2, size.Z / 2 + 0.5)), wall, Enum.Material.SmoothPlastic)
	p("Wall", Vector3.new(size.X, size.Y, 1), CFrame.new(origin + Vector3.new(0, size.Y / 2, -size.Z / 2 - 0.5)), wall, Enum.Material.SmoothPlastic)
	-- ceiling lights in a grid
	local nx = math.max(1, math.floor(size.X / 24))
	local nz = math.max(1, math.floor(size.Z / 24))
	for i = 1, nx do
		for j = 1, nz do
			local x = -size.X / 2 + (i - 0.5) * size.X / nx
			local z = -size.Z / 2 + (j - 0.5) * size.Z / nz
			local lamp = p("CeilingLight", Vector3.new(4, 0.2, 4), CFrame.new(origin + Vector3.new(x, size.Y - 0.1, z)), Color3.fromRGB(255, 250, 235), Enum.Material.Neon)
			lamp.CanCollide = false
			local light = Instance.new("PointLight")
			light.Range = 26
			light.Brightness = 1.2
			light.Color = Color3.fromRGB(255, 244, 225)
			light.Parent = lamp
		end
	end
	m.Parent = opts.parent
	return m
end

return Places
