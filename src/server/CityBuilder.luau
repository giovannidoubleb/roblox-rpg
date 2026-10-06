-- CITY GRIND: builds District 1, The Neighborhood.
-- Runs once on the server when Workspace has no "City" model, so a place file
-- that already contains a hand-edited City is left alone.
--
-- Layout (top-down, +x east, +z south):
--   Main road along x (z = 0), cross road along z (x = 0), sidewalks on both.
--   NW: Starter apartments, park + playground    NE: Outdoor court, Iron Box gym, subway
--   SW: Corner Mart, Fresh Cuts barber, Threads  SE: Mama's Kitchen, Budget Wheels lot

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

local CityBuilder = {}

local ROAD_W = 32
local WALK_W = 8
local GROUND_X = 600
local GROUND_Z = 460

local city: Model
local folders: { [string]: Folder } = {}

local function folder(name: string): Folder
	if not folders[name] then
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = city
		folders[name] = f
	end
	return folders[name]
end

type PartProps = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	shape: Enum.PartType?,
	parent: Instance?,
}

local function part(p: PartProps): BasePart
	local b = Instance.new("Part")
	b.Name = p.name or "Part"
	b.Anchored = true
	b.Size = p.size
	b.CFrame = p.cframe
	b.Color = p.color or Color3.fromRGB(160, 160, 160)
	b.Material = p.material or Enum.Material.SmoothPlastic
	b.Transparency = p.transparency or 0
	b.CanCollide = if p.collide == nil then true else p.collide
	if p.shape then
		b.Shape = p.shape
	end
	b.TopSurface = Enum.SurfaceType.Smooth
	b.BottomSurface = Enum.SurfaceType.Smooth
	b.Parent = p.parent or city
	return b
end

local function sign(target: BasePart, face: Enum.NormalId, text: string, textColor: Color3, bg: Color3?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bg or Color3.new(0, 0, 0)
	label.BackgroundTransparency = if bg then 0 else 1
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui
	return gui
end

-- Marks a spot the phone's Map app can navigate to.
local function mapPoint(name: string, category: string, position: Vector3)
	local p = part({
		name = name,
		size = Vector3.new(1, 1, 1),
		cframe = CFrame.new(position),
		transparency = 1,
		collide = false,
		parent = folder("MapPoints"),
	})
	p.CanQuery = false
	p.CanTouch = false
	p:SetAttribute("Category", category)
end

-- A solid building with floors of windows on the side facing the road.
-- facing = 1 means the front is on the +z side, -1 means -z.
local function building(opts: {
	name: string,
	center: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	facing: number,
	signText: string,
	signColor: Color3,
	category: string,
	floorHeight: number?,
})
	local model = Instance.new("Model")
	model.Name = opts.name
	model.Parent = folder("Buildings")

	local s = opts.size
	local base = opts.center + Vector3.new(0, s.Y / 2, 0)
	part({ name = "Body", size = s, cframe = CFrame.new(base), color = opts.color, material = opts.material or Enum.Material.Brick, parent = model })
	part({
		name = "RoofTrim",
		size = Vector3.new(s.X + 1, 1, s.Z + 1),
		cframe = CFrame.new(base + Vector3.new(0, s.Y / 2 + 0.5, 0)),
		color = Color3.fromRGB(60, 60, 66),
		material = Enum.Material.Concrete,
		parent = model,
	})

	local frontZ = opts.center.Z + opts.facing * (s.Z / 2 + 0.1)
	local floorH = opts.floorHeight or 12
	local floors = math.max(1, math.floor(s.Y / floorH))
	for f = 1, floors do
		local y = opts.center.Y + (f - 1) * floorH
		if f == 1 then
			-- door + shop window on the ground floor
			part({
				name = "Door",
				size = Vector3.new(6, 9, 0.4),
				cframe = CFrame.new(opts.center.X, y + 4.5, frontZ),
				color = Color3.fromRGB(45, 35, 30),
				material = Enum.Material.Wood,
				parent = model,
			})
			local shopWindow = math.min(s.X - 16, 24)
			if shopWindow > 4 then
				for _, side in { -1, 1 } do
					part({
						name = "ShopWindow",
						size = Vector3.new(shopWindow / 2, 6, 0.3),
						cframe = CFrame.new(opts.center.X + side * (3 + shopWindow / 4 + 2), y + 4.5, frontZ),
						color = Color3.fromRGB(150, 200, 230),
						material = Enum.Material.Glass,
						transparency = 0.35,
						parent = model,
					})
				end
			end
		else
			local count = math.floor((s.X - 6) / 8)
			for i = 1, count do
				local x = opts.center.X - (count - 1) * 4 + (i - 1) * 8
				part({
					name = "Window",
					size = Vector3.new(5, 6, 0.3),
					cframe = CFrame.new(x, y + floorH / 2, frontZ),
					color = Color3.fromRGB(140, 190, 225),
					material = Enum.Material.Glass,
					transparency = 0.2,
					parent = model,
				})
			end
		end
	end

	local board = part({
		name = "Sign",
		size = Vector3.new(math.min(s.X - 4, 28), 3.5, 0.6),
		cframe = CFrame.new(opts.center.X, opts.center.Y + 11, frontZ + opts.facing * 0.3),
		color = Color3.fromRGB(20, 20, 24),
		parent = model,
	})
	if opts.facing == 1 then
		-- a part's Front face points -z, so turn the board around to face +z
		board.CFrame *= CFrame.Angles(0, math.pi, 0)
	end
	sign(board, Enum.NormalId.Front, opts.signText, opts.signColor)

	mapPoint(opts.name, opts.category, Vector3.new(opts.center.X, 3, frontZ + opts.facing * 6))
	return model
end

local function tree(position: Vector3, parent: Instance)
	local h = 10 + math.random() * 6
	part({ name = "Trunk", size = Vector3.new(h, 1.6, 1.6), cframe = CFrame.new(position + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(100, 70, 45), material = Enum.Material.Wood, shape = Enum.PartType.Cylinder, parent = parent })
	local r = 9 + math.random() * 4
	part({ name = "Leaves", size = Vector3.new(r, r, r), cframe = CFrame.new(position + Vector3.new(0, h + r * 0.3, 0)), color = Color3.fromRGB(60, 140 + math.random(0, 40), 60), material = Enum.Material.Grass, shape = Enum.PartType.Ball, parent = parent })
end

local function bench(cf: CFrame, parent: Instance)
	local seat = Instance.new("Seat")
	seat.Name = "Bench"
	seat.Anchored = true
	seat.Size = Vector3.new(6, 0.6, 2)
	seat.CFrame = cf * CFrame.new(0, 1.8, 0)
	seat.Color = Color3.fromRGB(130, 90, 55)
	seat.Material = Enum.Material.WoodPlanks
	seat.Parent = parent
	part({ name = "BenchBack", size = Vector3.new(6, 2, 0.4), cframe = cf * CFrame.new(0, 3, 0.9), color = Color3.fromRGB(130, 90, 55), material = Enum.Material.WoodPlanks, parent = parent })
	for _, x in { -2.5, 2.5 } do
		part({ name = "Leg", size = Vector3.new(0.4, 1.6, 1.8), cframe = cf * CFrame.new(x, 0.8, 0), color = Color3.fromRGB(40, 40, 40), material = Enum.Material.Metal, parent = parent })
	end
end

-- A streetball hoop. dir = +1 means it faces +z (it sits at the -z end of the court).
-- The rim is sized for a 1.5-stud ball, and its centre is marked by a RimCenter attachment.
local RIM_RADIUS = 1.45
local function hoop(name: string, baseline: Vector3, dir: number, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	local pole = baseline + Vector3.new(0, 0, -dir * 3)
	local polePart = part({ name = "HoopPole", size = Vector3.new(0.8, 12, 0.8), cframe = CFrame.new(pole + Vector3.new(0, 6, 0)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	part({ name = "HoopArm", size = Vector3.new(0.6, 0.6, 3.5), cframe = CFrame.new(pole + Vector3.new(0, 11.5, dir * 1.75)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	local board = pole + Vector3.new(0, 11.5, dir * 3.5)
	part({ name = "Backboard", size = Vector3.new(7, 4.2, 0.3), cframe = CFrame.new(board), color = Color3.new(1, 1, 1), material = Enum.Material.Glass, transparency = 0.3, parent = m })
	part({ name = "BoardSquare", size = Vector3.new(2.4, 1.8, 0.32), cframe = CFrame.new(board + Vector3.new(0, -0.6, 0)), color = Color3.fromRGB(230, 60, 40), material = Enum.Material.SmoothPlastic, transparency = 0.5, collide = false, parent = m })
	local rimCenter = board + Vector3.new(0, -1.3, dir * (RIM_RADIUS + 0.45))
	local segments = 16
	for i = 0, segments - 1 do
		local a = i / segments * math.pi * 2
		part({
			name = "Rim",
			size = Vector3.new(0.18, 0.18, 2 * math.pi * RIM_RADIUS / segments + 0.05),
			cframe = CFrame.new(rimCenter + Vector3.new(math.cos(a) * RIM_RADIUS, 0, math.sin(a) * RIM_RADIUS)) * CFrame.Angles(0, -a, 0),
			color = Color3.fromRGB(240, 90, 20),
			material = Enum.Material.Metal,
			parent = m,
		})
	end
	-- a simple net: thin strands that don't block the ball
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local top = rimCenter + Vector3.new(math.cos(a) * RIM_RADIUS * 0.95, -0.1, math.sin(a) * RIM_RADIUS * 0.95)
		local bottom = rimCenter + Vector3.new(math.cos(a) * RIM_RADIUS * 0.55, -1.6, math.sin(a) * RIM_RADIUS * 0.55)
		local strand = part({ name = "Net", size = Vector3.new(0.06, 0.06, (top - bottom).Magnitude), cframe = CFrame.lookAt((top + bottom) / 2, bottom), color = Color3.new(1, 1, 1), collide = false, parent = m })
		strand.CanQuery = false
		strand.CanTouch = false
	end
	local rimMarker = Instance.new("Attachment")
	rimMarker.Name = "RimCenter"
	rimMarker.Parent = polePart
	rimMarker.WorldPosition = rimCenter
	m:SetAttribute("RimRadius", RIM_RADIUS)
	return m
end

local function buildGround()
	local f = folder("Streets")
	part({ name = "Ground", size = Vector3.new(GROUND_X, 2, GROUND_Z), cframe = CFrame.new(0, -0.95, 0), color = Color3.fromRGB(86, 140, 70), material = Enum.Material.Grass, parent = f })
	-- roads
	part({ name = "MainRoad", size = Vector3.new(GROUND_X, 0.2, ROAD_W), cframe = CFrame.new(0, 0.1, 0), color = Color3.fromRGB(45, 45, 50), material = Enum.Material.Asphalt, parent = f })
	for _, side in { -1, 1 } do
		local len = GROUND_Z / 2 - ROAD_W / 2
		part({ name = "CrossRoad", size = Vector3.new(ROAD_W, 0.2, len), cframe = CFrame.new(0, 0.1, side * (ROAD_W / 2 + len / 2)), color = Color3.fromRGB(45, 45, 50), material = Enum.Material.Asphalt, parent = f })
	end
	-- lane dashes
	for x = -GROUND_X / 2 + 10, GROUND_X / 2 - 10, 20 do
		if math.abs(x) > ROAD_W / 2 + 4 then
			part({ name = "LaneMark", size = Vector3.new(8, 0.05, 0.6), cframe = CFrame.new(x, 0.23, 0), color = Color3.fromRGB(240, 200, 60), material = Enum.Material.SmoothPlastic, collide = false, parent = f })
		end
	end
	for z = -GROUND_Z / 2 + 10, GROUND_Z / 2 - 10, 20 do
		if math.abs(z) > ROAD_W / 2 + 4 then
			part({ name = "LaneMark", size = Vector3.new(0.6, 0.05, 8), cframe = CFrame.new(0, 0.23, z), color = Color3.fromRGB(240, 200, 60), material = Enum.Material.SmoothPlastic, collide = false, parent = f })
		end
	end
	-- crosswalk stripes on all four sides of the intersection
	for _, side in { -1, 1 } do
		for i = -6, 6 do
			part({ name = "Crosswalk", size = Vector3.new(1.4, 0.05, 6), cframe = CFrame.new(i * 2.4, 0.23, side * (ROAD_W / 2 + 4)), color = Color3.new(1, 1, 1), collide = false, parent = f })
			part({ name = "Crosswalk", size = Vector3.new(6, 0.05, 1.4), cframe = CFrame.new(side * (ROAD_W / 2 + 4), 0.23, i * 2.4), color = Color3.new(1, 1, 1), collide = false, parent = f })
		end
	end
	-- sidewalks (raised slightly, but low enough to walk onto)
	local walkColor = Color3.fromRGB(175, 175, 170)
	for _, side in { -1, 1 } do
		local edge = side * (ROAD_W / 2 + WALK_W / 2)
		local lenX = GROUND_X / 2 - ROAD_W / 2
		local lenZ = GROUND_Z / 2 - ROAD_W / 2 - WALK_W
		for _, s2 in { -1, 1 } do
			-- along the main road, stopping at the cross road
			part({ name = "Sidewalk", size = Vector3.new(lenX, 0.5, WALK_W), cframe = CFrame.new(s2 * (ROAD_W / 2 + lenX / 2), 0.25, edge), color = walkColor, material = Enum.Material.Concrete, parent = f })
			-- along the cross road, starting after the main road's sidewalk
			part({ name = "Sidewalk", size = Vector3.new(WALK_W, 0.5, lenZ), cframe = CFrame.new(edge, 0.25, s2 * (ROAD_W / 2 + WALK_W + lenZ / 2)), color = walkColor, material = Enum.Material.Concrete, parent = f })
		end
	end
end

local function buildStreetLamps()
	local f = folder("StreetLamps")
	for _, side in { -1, 1 } do
		local z = side * (ROAD_W / 2 + WALK_W - 0.6)
		for x = -GROUND_X / 2 + 40, GROUND_X / 2 - 40, 40 do
			if math.abs(x) > ROAD_W then
				local lamp = Instance.new("Model")
				lamp.Name = "StreetLamp"
				lamp.Parent = f
				part({ name = "Pole", size = Vector3.new(0.6, 16, 0.6), cframe = CFrame.new(x, 8, z), color = Color3.fromRGB(35, 35, 40), material = Enum.Material.Metal, parent = lamp })
				local head = part({ name = "Head", size = Vector3.new(1.6, 0.6, 3), cframe = CFrame.new(x, 16, z - side * 1.2), color = Color3.fromRGB(255, 240, 200), material = Enum.Material.Neon, parent = lamp })
				local light = Instance.new("SpotLight")
				light.Face = Enum.NormalId.Bottom
				light.Range = 40
				light.Angle = 110
				light.Brightness = 3
				light.Color = Color3.fromRGB(255, 225, 170)
				light.Parent = head
			end
		end
	end
end

-- A full outdoor court with two hoops, team pads, a ball rack and a scoreboard.
-- The CourtGames server module finds courts by their "Court" tag.
local COURT_W, COURT_L = 44, 76
local function buildCourt(name: string, c: Vector3, floorColor: Color3, paintColor: Color3): Model
	local court = Instance.new("Model")
	court.Name = name
	court.Parent = folder("Courts")
	local w, l = COURT_W, COURT_L
	court:SetAttribute("CourtCenter", c)
	court:SetAttribute("CourtSize", Vector3.new(w, 0, l))
	court:SetAttribute("DisplayName", (name:gsub("(%l)(%u)", "%1 %2")))
	CollectionService:AddTag(court, "Court")

	part({ name = "CourtFloor", size = Vector3.new(w + 8, 0.4, l + 8), cframe = CFrame.new(c + Vector3.new(0, 0.2, 0)), color = floorColor, material = Enum.Material.Concrete, parent = court })
	part({ name = "Paint", size = Vector3.new(w, 0.05, l), cframe = CFrame.new(c + Vector3.new(0, 0.42, 0)), color = paintColor, material = Enum.Material.Concrete, collide = false, parent = court })
	local white = Color3.new(1, 1, 1)
	local function line(size: Vector3, offset: Vector3, angle: number?)
		part({ name = "Line", size = size, cframe = CFrame.new(c + offset + Vector3.new(0, 0.47, 0)) * CFrame.Angles(0, angle or 0, 0), color = white, collide = false, parent = court })
	end
	line(Vector3.new(w, 0.04, 0.4), Vector3.new(0, 0, -l / 2))
	line(Vector3.new(w, 0.04, 0.4), Vector3.new(0, 0, l / 2))
	line(Vector3.new(0.4, 0.04, l), Vector3.new(-w / 2, 0, 0))
	line(Vector3.new(0.4, 0.04, l), Vector3.new(w / 2, 0, 0))
	line(Vector3.new(w, 0.04, 0.4), Vector3.new(0, 0, 0))
	for _, dir in { -1, 1 } do
		local endZ = dir * l / 2
		-- the key
		line(Vector3.new(12, 0.04, 0.4), Vector3.new(0, 0, endZ - dir * 15))
		line(Vector3.new(0.4, 0.04, 15), Vector3.new(-6, 0, endZ - dir * 7.5))
		line(Vector3.new(0.4, 0.04, 15), Vector3.new(6, 0, endZ - dir * 7.5))
		-- three point arc, centred on the rim (2.4 studs in from the baseline)
		local r = 19
		for i = 0, 24 do
			local a = i / 24 * math.pi
			line(Vector3.new(0.4, 0.04, 2.6), Vector3.new(math.cos(a) * r, 0, endZ - dir * (2.4 + math.sin(a) * r)), a * dir)
		end
		hoop(if dir == -1 then "HoopNorth" else "HoopSouth", c + Vector3.new(0, 0, endZ), -dir, court)
	end
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		line(Vector3.new(0.4, 0.04, 2.5), Vector3.new(math.cos(a) * 6, 0, math.sin(a) * 6), -a)
	end
	-- chain-link fence with a gap on the south side
	local fenceColor = Color3.fromRGB(120, 125, 130)
	for _, side in { -1, 1 } do
		part({ name = "Fence", size = Vector3.new(0.3, 10, l + 8), cframe = CFrame.new(c + Vector3.new(side * (w / 2 + 4), 5, 0)), color = fenceColor, material = Enum.Material.DiamondPlate, transparency = 0.6, parent = court })
	end
	part({ name = "Fence", size = Vector3.new(w + 8, 10, 0.3), cframe = CFrame.new(c + Vector3.new(0, 5, -(l / 2 + 4))), color = fenceColor, material = Enum.Material.DiamondPlate, transparency = 0.6, parent = court })
	for _, side in { -1, 1 } do
		part({ name = "Fence", size = Vector3.new(w / 2 - 4, 10, 0.3), cframe = CFrame.new(c + Vector3.new(side * (w / 4 + 4), 5, l / 2 + 4)), color = fenceColor, material = Enum.Material.DiamondPlate, transparency = 0.6, parent = court })
	end
	-- spectator benches along the west fence (section 51)
	for i = -2, 2 do
		bench(CFrame.new(c + Vector3.new(-(w / 2 + 1.5), 0.4, i * 12)) * CFrame.Angles(0, -math.pi / 2, 0), court)
	end

	-- team pads behind the south baseline: stand on one to join that team
	for _, pad in { { "HomePad", -9, Color3.fromRGB(50, 120, 255), "HOME" }, { "AwayPad", 9, Color3.fromRGB(255, 70, 70), "AWAY" } } do
		local p = part({ name = pad[1], size = Vector3.new(8, 0.3, 2.6), cframe = CFrame.new(c + Vector3.new(pad[2], 0.55, l / 2 + 1.6)), color = pad[3], material = Enum.Material.Neon, collide = false, parent = court })
		p.CanQuery = false
		local labelPart = part({ name = pad[1] .. "Label", size = Vector3.new(8, 1.6, 0.2), cframe = CFrame.new(c + Vector3.new(pad[2], 1.6, l / 2 + 3.1)), color = Color3.fromRGB(20, 20, 24), collide = false, parent = court })
		labelPart.CFrame *= CFrame.Angles(0, math.pi, 0) -- face the road
		sign(labelPart, Enum.NormalId.Front, pad[4] .. " - stand here to play", pad[3])
	end

	-- ball rack for free play
	local rack = part({ name = "BallRack", size = Vector3.new(5, 2.5, 1.6), cframe = CFrame.new(c + Vector3.new(-(w / 2 + 1.5), 1.65, l / 2 - 4)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = court })
	for i = -1, 1 do
		part({ name = "RackBall", size = Vector3.new(1.4, 1.4, 1.4), cframe = CFrame.new(rack.Position + Vector3.new(0, 1.9, i * 1.5)), color = Color3.fromRGB(230, 110, 30), material = Enum.Material.Rubber, shape = Enum.PartType.Ball, collide = false, parent = court })
	end
	local rackPrompt = Instance.new("ProximityPrompt")
	rackPrompt.Name = "GrabBall"
	rackPrompt.ActionText = "Grab a ball"
	rackPrompt.ObjectText = "Ball Rack"
	rackPrompt.MaxActivationDistance = 9
	rackPrompt.RequiresLineOfSight = false
	rackPrompt.Parent = rack

	-- scoreboard on the north fence, facing the court
	local board = part({ name = "Scoreboard", size = Vector3.new(16, 6, 0.4), cframe = CFrame.new(c + Vector3.new(0, 13, -(l / 2 + 4))) * CFrame.Angles(0, math.pi, 0), color = Color3.fromRGB(15, 15, 18), parent = court })
	for _, x in { -7, 7 } do
		part({ name = "ScoreboardPost", size = Vector3.new(0.5, 10, 0.5), cframe = CFrame.new(c + Vector3.new(x, 5, -(l / 2 + 4.4))), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = court })
	end
	local gui = sign(board, Enum.NormalId.Front, "OPEN COURT", Color3.fromRGB(255, 200, 60))
	gui.Name = "ScoreboardGui"

	mapPoint(court:GetAttribute("DisplayName"), "Court", c + Vector3.new(0, 3, l / 2 + 8))
	return court
end

local function buildPark()
	local park = Instance.new("Model")
	park.Name = "Park"
	park.Parent = folder("Parks")
	local c = Vector3.new(-200, 0, -120)
	part({ name = "Path", size = Vector3.new(6, 0.2, 140), cframe = CFrame.new(c + Vector3.new(0, 0.1, 30)), color = Color3.fromRGB(190, 170, 130), material = Enum.Material.Sand, parent = park })
	part({ name = "Path", size = Vector3.new(120, 0.2, 6), cframe = CFrame.new(c + Vector3.new(0, 0.1, 0)), color = Color3.fromRGB(190, 170, 130), material = Enum.Material.Sand, parent = park })
	part({ name = "Fountain", size = Vector3.new(3, 14, 14), cframe = CFrame.new(c + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(200, 200, 205), material = Enum.Material.Marble, shape = Enum.PartType.Cylinder, parent = park })
	part({ name = "Water", size = Vector3.new(0.4, 12, 12), cframe = CFrame.new(c + Vector3.new(0, 3.1, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(80, 160, 220), material = Enum.Material.Glass, transparency = 0.3, shape = Enum.PartType.Cylinder, collide = false, parent = park })
	local rng = Random.new(7)
	for _ = 1, 22 do
		local p = c + Vector3.new(rng:NextNumber(-60, 60), 0, rng:NextNumber(-60, 70))
		if math.abs(p.X - c.X) > 8 and math.abs(p.Z - c.Z) > 8 then
			tree(p, park)
		end
	end
	for _, x in { -20, 20 } do
		bench(CFrame.new(c + Vector3.new(x, 0, 5)), park)
		bench(CFrame.new(c + Vector3.new(x, 0, -5)) * CFrame.Angles(0, math.pi, 0), park)
	end
	-- playground
	local pg = c + Vector3.new(35, 0, 40)
	part({ name = "Mulch", size = Vector3.new(30, 0.3, 26), cframe = CFrame.new(pg + Vector3.new(0, 0.15, 0)), color = Color3.fromRGB(120, 80, 50), material = Enum.Material.Ground, parent = park })
	part({ name = "SlideTower", size = Vector3.new(6, 6, 6), cframe = CFrame.new(pg + Vector3.new(-8, 3, 0)), color = Color3.fromRGB(240, 200, 40), material = Enum.Material.Plastic, parent = park })
	part({ name = "Slide", size = Vector3.new(3, 0.4, 11), cframe = CFrame.new(pg + Vector3.new(-8, 3.1, 8.5)) * CFrame.Angles(math.rad(-30), 0, 0), color = Color3.fromRGB(230, 60, 60), material = Enum.Material.Plastic, parent = park })
	part({ name = "SlideStep", size = Vector3.new(3, 3, 3), cframe = CFrame.new(pg + Vector3.new(-8, 1.5, -4.5)), color = Color3.fromRGB(60, 120, 230), material = Enum.Material.Plastic, parent = park })
	part({ name = "SwingBar", size = Vector3.new(14, 0.6, 0.6), cframe = CFrame.new(pg + Vector3.new(7, 9, 0)), color = Color3.fromRGB(60, 120, 230), material = Enum.Material.Metal, parent = park })
	for _, x in { 0.5, 13.5 } do
		part({ name = "SwingPost", size = Vector3.new(0.6, 9, 0.6), cframe = CFrame.new(pg + Vector3.new(x, 4.5, 0)), color = Color3.fromRGB(60, 120, 230), material = Enum.Material.Metal, parent = park })
	end
	for _, x in { 4, 10 } do
		local seat = Instance.new("Seat")
		seat.Name = "Swing"
		seat.Anchored = true
		seat.Size = Vector3.new(2, 0.3, 1.2)
		seat.CFrame = CFrame.new(pg + Vector3.new(x, 2.5, 0))
		seat.Color = Color3.fromRGB(30, 30, 30)
		seat.Parent = park
	end
	mapPoint("City Park", "Park", c + Vector3.new(0, 3, 70))
end

-- Vending machine outside Corner Mart. The server handles the purchase.
local function buildVendingMachine(position: Vector3, facing: number): ProximityPrompt
	local m = Instance.new("Model")
	m.Name = "VendingMachine"
	m.Parent = folder("Interactables")
	local body = part({ name = "Body", size = Vector3.new(4, 7, 3), cframe = CFrame.new(position + Vector3.new(0, 3.5, 0)), color = Color3.fromRGB(200, 30, 40), material = Enum.Material.Metal, parent = m })
	local front = part({ name = "Front", size = Vector3.new(3.2, 4, 0.1), cframe = CFrame.new(position + Vector3.new(0, 4.2, facing * 1.55)), color = Color3.fromRGB(240, 240, 255), material = Enum.Material.Neon, parent = m })
	sign(front, if facing == -1 then Enum.NormalId.Front else Enum.NormalId.Back, "ENERGY\nDRINK\n$5", Color3.fromRGB(200, 30, 40))
	m.PrimaryPart = body
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Buy Energy Drink ($5)"
	prompt.ObjectText = "Vending Machine"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 8
	prompt.HoldDuration = 0.3
	prompt.RequiresLineOfSight = false
	prompt.Parent = body
	return prompt
end

local function buildBusStop(position: Vector3)
	local m = Instance.new("Model")
	m.Name = "BusStop"
	m.Parent = folder("Transit")
	part({ name = "Roof", size = Vector3.new(12, 0.4, 5), cframe = CFrame.new(position + Vector3.new(0, 8, 0)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	part({ name = "Back", size = Vector3.new(12, 7, 0.3), cframe = CFrame.new(position + Vector3.new(0, 4.3, 2.3)), color = Color3.fromRGB(180, 220, 240), material = Enum.Material.Glass, transparency = 0.5, parent = m })
	local post = part({ name = "SignPost", size = Vector3.new(0.4, 10, 0.4), cframe = CFrame.new(position + Vector3.new(-7, 5, -1)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	local plate = part({ name = "SignPlate", size = Vector3.new(3, 2, 0.2), cframe = CFrame.new(post.Position + Vector3.new(0, 4, -0.2)), color = Color3.fromRGB(30, 110, 200), parent = m })
	sign(plate, Enum.NormalId.Front, "BUS", Color3.new(1, 1, 1))
	bench(CFrame.new(position + Vector3.new(0, 0, 1.2)), m)
	mapPoint("Bus Stop", "Transit", position + Vector3.new(0, 3, -4))
end

local function buildSubwayEntrance(position: Vector3)
	local m = Instance.new("Model")
	m.Name = "SubwayEntrance"
	m.Parent = folder("Transit")
	part({ name = "Base", size = Vector3.new(14, 1, 12), cframe = CFrame.new(position + Vector3.new(0, 0.5, 0)), color = Color3.fromRGB(90, 90, 95), material = Enum.Material.Concrete, parent = m })
	part({ name = "Stairwell", size = Vector3.new(8, 1.1, 8), cframe = CFrame.new(position + Vector3.new(0, 0.55, 0)), color = Color3.fromRGB(10, 10, 12), material = Enum.Material.SmoothPlastic, parent = m })
	for _, x in { -5, 5 } do
		part({ name = "Rail", size = Vector3.new(0.4, 3, 9), cframe = CFrame.new(position + Vector3.new(x, 2.5, 0)), color = Color3.fromRGB(30, 140, 70), material = Enum.Material.Metal, parent = m })
	end
	local sTop = part({ name = "Sign", size = Vector3.new(12, 2.4, 0.4), cframe = CFrame.new(position + Vector3.new(0, 6, 5.8)), color = Color3.fromRGB(30, 140, 70), parent = m })
	sTop.CFrame = sTop.CFrame * CFrame.Angles(0, math.pi, 0)
	sign(sTop, Enum.NormalId.Front, "SUBWAY  NEIGHBORHOOD", Color3.new(1, 1, 1))
	for _, x in { -5.8, 5.8 } do
		part({ name = "SignPost", size = Vector3.new(0.4, 6, 0.4), cframe = CFrame.new(position + Vector3.new(x, 3, 5.8)), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	end
	mapPoint("Subway Station", "Transit", position + Vector3.new(0, 3, 9))
end

local function buildDealership(center: Vector3)
	local m = Instance.new("Model")
	m.Name = "BudgetWheels"
	m.Parent = folder("Buildings")
	part({ name = "Lot", size = Vector3.new(90, 0.3, 70), cframe = CFrame.new(center + Vector3.new(0, 0.15, 0)), color = Color3.fromRGB(55, 55, 60), material = Enum.Material.Asphalt, parent = m })
	for i = -4, 4 do
		part({ name = "ParkingLine", size = Vector3.new(0.4, 0.05, 14), cframe = CFrame.new(center + Vector3.new(i * 9, 0.32, -6)), color = Color3.new(1, 1, 1), collide = false, parent = m })
	end
	building({
		name = "Budget Wheels",
		center = center + Vector3.new(0, 0, 24),
		size = Vector3.new(36, 14, 18),
		color = Color3.fromRGB(230, 230, 235),
		material = Enum.Material.Concrete,
		facing = -1,
		signText = "BUDGET WHEELS",
		signColor = Color3.fromRGB(255, 200, 40),
		category = "Shop",
	}).Parent = m
	-- pennant string across the lot entrance
	for i = 0, 11 do
		part({
			name = "Pennant",
			size = Vector3.new(1.2, 1.2, 0.1),
			cframe = CFrame.new(center + Vector3.new(-33 + i * 6, 10, -34)) * CFrame.Angles(0, 0, math.rad(45)),
			color = if i % 2 == 0 then Color3.fromRGB(230, 50, 50) else Color3.fromRGB(255, 220, 50),
			collide = false,
			parent = m,
		})
	end
end

-- The Neighborhood run route. Returns checkpoint trigger parts in order.
local RUN_ROUTE = {
	Vector3.new(-40, 0, -20),
	Vector3.new(240, 0, -20),
	Vector3.new(240, 0, 20),
	Vector3.new(-240, 0, 20),
	Vector3.new(-240, 0, -20),
}

local function buildRunRoute(): { BasePart }
	local f = folder("RunRoute")
	local triggers = {}
	for i, pos in RUN_ROUTE do
		local m = Instance.new("Model")
		m.Name = "Checkpoint" .. i
		m.Parent = f
		local alongX = i == 1 or i == 2 or i == 4 or i == 5
		local postOffset = if alongX then Vector3.new(0, 0, 5) else Vector3.new(5, 0, 0)
		local color = if i == 1 then Color3.fromRGB(60, 230, 110) else Color3.fromRGB(255, 170, 40)
		for _, s in { -1, 1 } do
			part({ name = "Post", size = Vector3.new(0.8, 10, 0.8), cframe = CFrame.new(pos + postOffset * s + Vector3.new(0, 5, 0)), color = color, material = Enum.Material.Neon, collide = false, parent = m })
		end
		local bar = part({
			name = "Banner",
			size = if alongX then Vector3.new(0.8, 2, 10.8) else Vector3.new(10.8, 2, 0.8),
			cframe = CFrame.new(pos + Vector3.new(0, 10, 0)),
			color = Color3.fromRGB(25, 25, 30),
			collide = false,
			parent = m,
		})
		local text = if i == 1 then "START / FINISH" else "CHECKPOINT " .. (i - 1)
		for _, face in (if alongX then { Enum.NormalId.Left, Enum.NormalId.Right } else { Enum.NormalId.Front, Enum.NormalId.Back }) do
			sign(bar, face, text, color)
		end
		local trigger = part({
			name = "Trigger",
			size = Vector3.new(12, 12, 12),
			cframe = CFrame.new(pos + Vector3.new(0, 6, 0)),
			transparency = 1,
			collide = false,
			parent = m,
		})
		trigger.CanQuery = false
		trigger:SetAttribute("CheckpointIndex", i)
		table.insert(triggers, trigger)
	end
	mapPoint("Run Route Start", "Fitness", RUN_ROUTE[1] + Vector3.new(0, 3, 0))
	return triggers
end

local function buildLighting()
	Lighting.ClockTime = 9
	Lighting.Brightness = 2.2
	Lighting.Ambient = Color3.fromRGB(70, 70, 80)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 130)
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.6
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.3
		atmosphere.Haze = 1.2
		atmosphere.Color = Color3.fromRGB(200, 190, 180)
		atmosphere.Decay = Color3.fromRGB(110, 100, 120)
		atmosphere.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("BloomEffect") then
		local bloom = Instance.new("BloomEffect")
		bloom.Intensity = 0.6
		bloom.Size = 30
		bloom.Threshold = 1.6
		bloom.Parent = Lighting
	end
end

export type CityHandles = {
	city: Model,
	vendingPrompt: ProximityPrompt?,
	runTriggers: { BasePart },
	lamps: { Light },
}

function CityBuilder.build(): CityHandles
	local existing = workspace:FindFirstChild("City")
	if existing and existing:IsA("Model") then
		-- Reuse a City someone already built or edited by hand.
		city = existing
		local triggers = {}
		local runRoute = city:FindFirstChild("RunRoute")
		if runRoute then
			for _, d in runRoute:GetDescendants() do
				if d:IsA("BasePart") and d:GetAttribute("CheckpointIndex") then
					triggers[d:GetAttribute("CheckpointIndex")] = d
				end
			end
		end
		local prompt = city:FindFirstChild("ProximityPrompt", true)
		local lamps = {}
		for _, d in city:GetDescendants() do
			if d:IsA("SpotLight") then
				table.insert(lamps, d)
			end
		end
		return { city = city, vendingPrompt = prompt :: ProximityPrompt?, runTriggers = triggers, lamps = lamps }
	end

	city = Instance.new("Model")
	city.Name = "City"
	city.Parent = workspace
	table.clear(folders)

	buildLighting()
	buildGround()
	buildStreetLamps()

	building({ name = "Starter Apartments", center = Vector3.new(-100, 0, -85), size = Vector3.new(70, 36, 40), color = Color3.fromRGB(170, 95, 70), facing = 1, signText = "MAPLE COURT APTS", signColor = Color3.fromRGB(255, 230, 180), category = "Home" })
	building({ name = "Iron Box Gym", center = Vector3.new(205, 0, -75), size = Vector3.new(60, 24, 40), color = Color3.fromRGB(70, 70, 78), material = Enum.Material.Concrete, facing = 1, signText = "IRON BOX GYM", signColor = Color3.fromRGB(255, 80, 60), category = "Gym" })
	building({ name = "Corner Mart", center = Vector3.new(-70, 0, 62), size = Vector3.new(40, 16, 30), color = Color3.fromRGB(235, 225, 200), material = Enum.Material.Concrete, facing = -1, signText = "CORNER MART", signColor = Color3.fromRGB(60, 200, 90), category = "Shop" })
	building({ name = "Fresh Cuts Barber", center = Vector3.new(-125, 0, 60), size = Vector3.new(30, 14, 26), color = Color3.fromRGB(60, 90, 160), facing = -1, signText = "FRESH CUTS", signColor = Color3.fromRGB(255, 255, 255), category = "Shop" })
	building({ name = "Threads Clothing", center = Vector3.new(-185, 0, 62), size = Vector3.new(44, 18, 30), color = Color3.fromRGB(40, 40, 46), material = Enum.Material.Concrete, facing = -1, signText = "THREADS", signColor = Color3.fromRGB(255, 120, 200), category = "Shop" })
	building({ name = "Mama's Kitchen", center = Vector3.new(70, 0, 62), size = Vector3.new(40, 16, 30), color = Color3.fromRGB(190, 70, 50), facing = -1, signText = "MAMA'S KITCHEN", signColor = Color3.fromRGB(255, 220, 120), category = "Food" })

	buildCourt("NeighborhoodCourt", Vector3.new(100, 0, -110), Color3.fromRGB(40, 90, 150), Color3.fromRGB(200, 90, 50))
	buildPark()
	buildDealership(Vector3.new(190, 0, 85))
	buildBusStop(Vector3.new(-35, 0, 32))
	buildSubwayEntrance(Vector3.new(40, 0, -45))
	local vendingPrompt = buildVendingMachine(Vector3.new(-45, 0, 44), -1)
	mapPoint("Vending Machine", "Shop", Vector3.new(-45, 3, 40))
	local runTriggers = buildRunRoute()

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ApartmentSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(-100, 0.5, -55) * CFrame.Angles(0, math.pi, 0)
	spawn.Color = Color3.fromRGB(170, 95, 70)
	spawn.Material = Enum.Material.Concrete
	spawn.Duration = 0
	spawn.Parent = city
	-- Everyone starts outside their apartment, not on a template's default spawn.
	for _, d in workspace:GetDescendants() do
		if d:IsA("SpawnLocation") and d ~= spawn then
			d.Enabled = false
		end
	end

	local lamps = {}
	for _, d in city:GetDescendants() do
		if d:IsA("SpotLight") then
			table.insert(lamps, d)
		end
	end

	return { city = city, vendingPrompt = vendingPrompt, runTriggers = runTriggers, lamps = lamps }
end

CityBuilder.RUN_ROUTE = RUN_ROUTE

return CityBuilder
