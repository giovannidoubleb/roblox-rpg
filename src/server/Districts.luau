-- CITY GRIND: the rest of the city (spec sections 4-11, 32, 49, 51, 94).
-- Districts.build(cityModel) runs once, right after CityBuilder.build(), and
-- builds Downtown, Industrial, the Beach, Luxury Hills and Old Town around the
-- Neighborhood, the highways between them, a working subway and the moving or
-- interactive bits (ferris wheel, elevators, private court gate, leaderboard,
-- digital billboards, night windows). Layout lives in DistrictsConfig.
--
-- Everything is under City.Districts.<Id> (Folders with DisplayName / Center /
-- Size attributes). Courts are real CityBuilder courts (tag "Court").
-- Tags: "SecretArea" (invisible zones, attribute SecretId + DisplayName),
-- "RaceStart" (start/finish line; checkpoints in Industrial.RaceTrack.Checkpoints
-- with attribute Index). Player attributes: District, SubwayRides, LastSubwayStation.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local DC = require(shared:WaitForChild("DistrictsConfig"))
local CityBuilder = require(script.Parent:WaitForChild("CityBuilder"))
local Net = require(script.Parent:WaitForChild("Net"))
local Places = require(script.Parent:WaitForChild("Places"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local Districts = {}

-- Fires (player, fromStationId, toStationId) after every completed subway ride.
Districts.subwayRide = Instance.new("BindableEvent")

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local ROAD_W = 32
local WALK_W = 8

local H: any -- CityBuilder.helpers, set in build()
local city: Model
local root: Folder
local current: Instance -- default parent for new parts

local C = {
	asphalt = Color3.fromRGB(45, 45, 50),
	lane = Color3.fromRGB(240, 200, 60),
	walk = Color3.fromRGB(175, 175, 170),
	dark = Color3.fromRGB(35, 35, 40),
	metal = Color3.fromRGB(70, 72, 78),
	white = Color3.new(1, 1, 1),
	signBg = Color3.fromRGB(20, 20, 24),
	windowWarm = Color3.fromRGB(255, 214, 140),
	windowCool = Color3.fromRGB(170, 215, 255),
	wood = Color3.fromRGB(130, 90, 55),
	sand = Color3.fromRGB(226, 205, 150),
	mapRoad = Color3.fromRGB(50, 50, 55),
	mapWalk = Color3.fromRGB(170, 170, 165),
	mapBuilding = Color3.fromRGB(200, 190, 175),
}

---------------------------------------------------------------------------
-- Small building blocks
---------------------------------------------------------------------------
type PartSpec = {
	name: string?,
	size: Vector3,
	cf: CFrame,
	color: Color3?,
	mat: Enum.Material?,
	transp: number?,
	collide: boolean?,
	shape: Enum.PartType?,
	parent: Instance?,
	map: Color3?, -- drawn on the phone map in this colour
	layer: number?, -- phone map z-order
}

local function P(s: PartSpec): BasePart
	local b: BasePart = H.part({
		name = s.name,
		size = s.size,
		cframe = s.cf,
		color = s.color,
		material = s.mat,
		transparency = s.transp,
		collide = s.collide,
		shape = s.shape,
		parent = s.parent or current,
	})
	if s.map then
		b:SetAttribute("MapColor", s.map)
		b:SetAttribute("MapLayer", s.layer or 2)
	end
	if s.collide == false then
		b.CanQuery = false
		b.CanTouch = false
	end
	return b
end

-- A vertical cylinder (Roblox cylinders run along X, so turn it upright).
local function cylinder(name: string, base: Vector3, height: number, diameter: number, color: Color3, mat: Enum.Material?, parent: Instance?): BasePart
	return P({
		name = name,
		size = V(height, diameter, diameter),
		cf = CF(base + V(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		color = color,
		mat = mat or M.SmoothPlastic,
		shape = Enum.PartType.Cylinder,
		parent = parent,
	})
end

local function model(name: string, parent: Instance?): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent or current
	return m
end

-- A sloped slab whose TOP surface runs from a to b.
local function ramp(name: string, a: Vector3, b: Vector3, width: number, color: Color3, mat: Enum.Material, thickness: number?, parent: Instance?): BasePart
	local t = thickness or 1
	local mid = (a + b) / 2
	return P({
		name = name,
		size = V(width, t, (b - a).Magnitude + 0.4),
		cf = CFrame.lookAt(mid, b) * CF(0, -t / 2, 0),
		color = color,
		mat = mat,
		parent = parent,
	})
end

-- A board whose Front face (and sign) points along `dir`.
local function signBoard(name: string, pos: Vector3, size: Vector3, dir: Vector3, text: string, textColor: Color3, bg: Color3?, parent: Instance?): (BasePart, SurfaceGui)
	local b = P({ name = name, size = size, cf = CFrame.lookAt(pos, pos + dir), color = C.signBg, parent = parent })
	local gui = H.sign(b, Enum.NormalId.Front, text, textColor, bg)
	return b, gui
end

local function addPrompt(parent: Instance, name: string, action: string, object: string, distance: number?, hold: number?): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = object
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.MaxActivationDistance = distance or 10
	p.HoldDuration = hold or 0
	p.RequiresLineOfSight = false
	p.Parent = parent
	return p
end

local function seat(pos: Vector3, facing: Vector3, color: Color3?, parent: Instance?): Seat
	local s = Instance.new("Seat")
	s.Name = "Seat"
	s.Anchored = true
	s.Size = V(2.4, 0.5, 2.4)
	s.CFrame = CFrame.lookAt(pos, pos + facing)
	s.Color = color or Color3.fromRGB(180, 40, 50)
	s.Material = M.SmoothPlastic
	s.TopSurface = Enum.SurfaceType.Smooth
	s.BottomSurface = Enum.SurfaceType.Smooth
	s.Parent = parent or current
	return s
end

-- Invisible zone that quests/achievements can detect. Never on the map.
local function secretArea(id: string, displayName: string, center: Vector3, size: Vector3)
	local a = P({ name = "SecretArea", size = size, cf = CF(center), transp = 1, collide = false })
	a.CanTouch = true
	a:SetAttribute("SecretId", id)
	a:SetAttribute("DisplayName", displayName)
	CollectionService:AddTag(a, "SecretArea")
end

local function mapPoint(name: string, category: string, pos: Vector3)
	H.mapPoint(name, category, pos + V(0, 3, 0))
end

---------------------------------------------------------------------------
-- Night lighting: lit windows and lamps owned by this module.
-- (SpotLights are collected and switched by Main like the Neighborhood's.)
---------------------------------------------------------------------------
type Glow = { part: BasePart, day: Color3, mat: Enum.Material, transp: number, night: Color3 }
local glows: { Glow } = {}
local nightLights: { Light } = {}

local function glowAtNight(part: BasePart, nightColor: Color3)
	table.insert(glows, { part = part, day = part.Color, mat = part.Material, transp = part.Transparency, night = nightColor })
end

local function pointLight(parent: Instance, range: number, brightness: number, color: Color3, alwaysOn: boolean?): PointLight
	local l = Instance.new("PointLight")
	l.Range = range
	l.Brightness = brightness
	l.Color = color
	l.Shadows = false
	l.Parent = parent
	if not alwaysOn then
		l.Enabled = false
		table.insert(nightLights, l)
	end
	return l
end

local function applyNight(night: boolean)
	for _, g in glows do
		if g.part.Parent then
			g.part.Material = if night then M.Neon else g.mat
			g.part.Color = if night then g.night else g.day
			g.part.Transparency = if night then 0 else g.transp
		end
	end
	for _, l in nightLights do
		l.Enabled = night
	end
end

-- A lantern on a post: glowing globe + PointLight at night.
local function lantern(pos: Vector3, color: Color3?, height: number?)
	local h = height or 10
	local m = model("Lantern")
	P({ name = "Post", size = V(0.5, h, 0.5), cf = CF(pos + V(0, h / 2, 0)), color = C.dark, mat = M.Metal, parent = m })
	local globe = P({ name = "Globe", size = V(1.6, 1.6, 1.6), cf = CF(pos + V(0, h + 0.6, 0)), color = Color3.fromRGB(240, 235, 220), shape = Enum.PartType.Ball, parent = m })
	glowAtNight(globe, color or Color3.fromRGB(255, 220, 160))
	pointLight(globe, 28, 1.6, color or Color3.fromRGB(255, 210, 150))
end

-- A street lamp like the Neighborhood's (SpotLight, switched by Main).
local function streetLamp(pos: Vector3, towardRoad: Vector3)
	local m = model("StreetLamp")
	P({ name = "Pole", size = V(0.6, 16, 0.6), cf = CF(pos + V(0, 8, 0)), color = C.dark, mat = M.Metal, parent = m })
	local headPos = pos + V(0, 16, 0) + towardRoad * 1.2
	local head = P({ name = "Head", size = V(1.6, 0.6, 3), cf = CFrame.lookAt(headPos, headPos + towardRoad), color = Color3.fromRGB(255, 240, 200), parent = m })
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Range = 40
	light.Angle = 110
	light.Brightness = 3
	light.Color = Color3.fromRGB(255, 225, 170)
	light.Parent = head
end

-- A floodlight tower aimed down at a point (SpotLight, switched by Main).
local function floodlight(base: Vector3, height: number, target: Vector3)
	local m = model("Floodlight")
	P({ name = "Mast", size = V(1, height, 1), cf = CF(base + V(0, height / 2, 0)), color = C.metal, mat = M.Metal, parent = m })
	local top = base + V(0, height, 0)
	local head = P({ name = "Head", size = V(5, 3, 1), cf = CFrame.lookAt(top, target), color = Color3.fromRGB(250, 250, 240), parent = m })
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Front
	light.Range = 60
	light.Angle = 70
	light.Brightness = 4
	light.Color = Color3.fromRGB(240, 245, 255)
	light.Parent = head
end

---------------------------------------------------------------------------
-- Ground, roads and sidewalks
---------------------------------------------------------------------------
-- Ground slab over [x0,x1] x [z0,z1] (top at y 0.05) with rectangular holes {x0,x1,z0,z1}.
local function ground(x0: number, x1: number, z0: number, z1: number, color: Color3, mat: Enum.Material, mapColor: Color3, holes: { { number } }?)
	local cuts = { x0, x1 }
	for _, h in (holes or {}) :: { { number } } do
		table.insert(cuts, h[1])
		table.insert(cuts, h[2])
	end
	table.sort(cuts)
	for i = 1, #cuts - 1 do
		local a, b = cuts[i], cuts[i + 1]
		if b - a > 0.01 then
			local mid = (a + b) / 2
			local runs = { { z0, z1 } }
			for _, h in (holes or {}) :: { { number } } do
				if mid > h[1] and mid < h[2] then
					local nextRuns = {}
					for _, r in runs do
						if h[4] <= r[1] or h[3] >= r[2] then
							table.insert(nextRuns, r)
						else
							if h[3] > r[1] then
								table.insert(nextRuns, { r[1], h[3] })
							end
							if h[4] < r[2] then
								table.insert(nextRuns, { h[4], r[2] })
							end
						end
					end
					runs = nextRuns
				end
			end
			for _, r in runs do
				P({ name = "Ground", size = V(b - a, 2, r[2] - r[1]), cf = CF(mid, -0.95, (r[1] + r[2]) / 2), color = color, mat = mat, map = mapColor, layer = 1 })
			end
		end
	end
end

-- [a,b] minus the gaps, as a list of {from, to}.
local function segments(a: number, b: number, gaps: { { number } }?): { { number } }
	local out = { { a, b } }
	for _, g in (gaps or {}) :: { { number } } do
		local nextOut = {}
		for _, s in out do
			if g[2] <= s[1] or g[1] >= s[2] then
				table.insert(nextOut, s)
			else
				if g[1] > s[1] then
					table.insert(nextOut, { s[1], g[1] })
				end
				if g[2] < s[2] then
					table.insert(nextOut, { g[2], s[2] })
				end
			end
		end
		out = nextOut
	end
	return out
end

type RoadOpts = {
	y: number?,
	name: string?,
	color: Color3?,
	mat: Enum.Material?,
	walks: boolean?,
	walkGaps: { { number } }?,
	walkColor: Color3?,
	walkMat: Enum.Material?,
	lamps: boolean?,
	lampEvery: number?,
}

-- A road along the X axis at z, with sidewalks and lamps. axis "z" builds along Z at x = `at`.
local function road(axis: string, from: number, to: number, at: number, o: RoadOpts?)
	local opts: RoadOpts = o or {}
	local y = opts.y or 0
	local alongX = axis == "x"
	local len, mid = to - from, (from + to) / 2
	local function place(along: number, across: number, h: number): Vector3
		return if alongX then V(along, h, at + across) else V(at + across, h, along)
	end
	local function size(along: number, across: number, h: number): Vector3
		return if alongX then V(along, h, across) else V(across, h, along)
	end
	P({ name = opts.name or (if alongX then "MainRoad" else "CrossRoad"), size = size(len, ROAD_W, 0.2), cf = CF(place(mid, 0, y + 0.1)), color = opts.color or C.asphalt, mat = opts.mat or M.Asphalt, map = C.mapRoad, layer = 2 })
	for d = from + 15, to - 10, 30 do
		P({ name = "LaneMark", size = size(8, 0.6, 0.05), cf = CF(place(d, 0, y + 0.23)), color = C.lane, collide = false })
	end
	if opts.walks ~= false then
		for _, side in { -1, 1 } do
			for _, seg in segments(from, to, opts.walkGaps) do
				P({
					name = "Sidewalk",
					size = size(seg[2] - seg[1], WALK_W, 0.5),
					cf = CF(place((seg[1] + seg[2]) / 2, side * (ROAD_W / 2 + WALK_W / 2), y + 0.25)),
					color = opts.walkColor or C.walk,
					mat = opts.walkMat or M.Concrete,
					map = C.mapWalk,
					layer = 2,
				})
			end
		end
	end
	if opts.lamps ~= false then
		local every = opts.lampEvery or 80
		local i = 0
		for d = from + every / 2, to - 10, every do
			i += 1
			local side = if i % 2 == 0 then 1 else -1
			local inGap = false
			for _, g in (opts.walkGaps or {}) :: { { number } } do
				if d > g[1] - 4 and d < g[2] + 4 then
					inGap = true
				end
			end
			if not inGap then
				local pos = place(d, side * (ROAD_W / 2 + WALK_W - 0.6), y)
				streetLamp(pos, if alongX then V(0, 0, -side) else V(-side, 0, 0))
			end
		end
	end
end

-- A flat asphalt lot (vehicles treat "Lot" like a road).
local function lot(x0: number, x1: number, z0: number, z1: number, y: number?, name: string?): BasePart
	return P({ name = name or "Lot", size = V(x1 - x0, 0.3, z1 - z0), cf = CF((x0 + x1) / 2, (y or 0) + 0.15, (z0 + z1) / 2), color = Color3.fromRGB(55, 55, 60), mat = M.Asphalt, map = Color3.fromRGB(60, 60, 66), layer = 2 })
end

---------------------------------------------------------------------------
-- Buildings
---------------------------------------------------------------------------
local FACE_YAW = { S = 0, N = math.pi, E = math.pi / 2, W = -math.pi / 2 }

-- A CityBuilder storefront turned to face N/S/E/W (S = +z).
-- size = (front width, height, depth). category nil = no map point.
local function shop(o: {
	name: string,
	center: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	face: string,
	signText: string,
	signColor: Color3,
	category: string?,
	floorHeight: number?,
}): Model
	local m: Model = H.building({
		name = o.name,
		center = o.center,
		size = o.size,
		color = o.color,
		material = o.material,
		facing = 1,
		signText = o.signText,
		signColor = o.signColor,
		category = o.category or "Landmark",
		floorHeight = o.floorHeight,
	})
	m.Parent = current
	local body = m:FindFirstChild("Body")
	if body then
		body:SetAttribute("MapColor", C.mapBuilding)
		body:SetAttribute("MapLayer", 3)
	end
	local points = city:FindFirstChild("MapPoints")
	local point = points and points:FindFirstChild(o.name) :: BasePart?
	local yaw = FACE_YAW[o.face] or 0
	if yaw ~= 0 then
		local pivot = CF(o.center)
		local rotated = pivot * CFrame.Angles(0, yaw, 0)
		m.WorldPivot = pivot
		m:PivotTo(rotated)
		if point then
			point.CFrame = rotated * pivot:ToObjectSpace(point.CFrame)
		end
	end
	if point and not o.category then
		point:Destroy()
	end
	return m
end

type TowerOpts = {
	name: string,
	center: Vector3,
	w: number,
	d: number,
	h: number,
	color: Color3,
	glass: Color3,
	trim: Color3?,
	lit: number, -- fraction of window strips that light up at night
	nightColor: Color3?,
	mat: Enum.Material?,
	front: Vector3?, -- entrance side (default +z)
	spire: number?,
	flatRoof: boolean?,
}

-- A skyscraper: one body, full-height window strips per face (one part each),
-- floor bands, a lobby, a crown. ~25 parts no matter how tall.
local function tower(o: TowerOpts): Model
	local m = model(o.name)
	local c = o.center
	P({ name = "Body", size = V(o.w, o.h, o.d), cf = CF(c + V(0, o.h / 2, 0)), color = o.color, mat = o.mat or M.Concrete, parent = m, map = C.mapBuilding, layer = 3 })
	local rng = Random.new(math.floor(math.abs(c.X) * 7 + math.abs(c.Z) * 13))
	local stripH = o.h - 16
	for _, face in { V(1, 0, 0), V(-1, 0, 0), V(0, 0, 1), V(0, 0, -1) } do
		local len = if face.X ~= 0 then o.d else o.w
		local depth = if face.X ~= 0 then o.w else o.d
		local along = V(face.Z, 0, -face.X)
		local n = math.max(2, math.floor(len / 12))
		local pitch = len / n
		for i = 1, n do
			local pos = c + face * (depth / 2 + 0.15) + along * (-len / 2 + (i - 0.5) * pitch) + V(0, 12 + stripH / 2, 0)
			local strip = P({ name = "Windows", size = V(pitch - 3, stripH, 0.4), cf = CFrame.lookAt(pos, pos + face), color = o.glass, mat = M.Glass, transp = 0.1, parent = m })
			if rng:NextNumber() < o.lit then
				glowAtNight(strip, o.nightColor or (if rng:NextNumber() < 0.7 then C.windowWarm else C.windowCool))
			end
		end
	end
	local trim = o.trim or Color3.fromRGB(60, 62, 70)
	for y = 34, o.h - 12, 34 do
		P({ name = "Band", size = V(o.w + 0.9, 1.6, o.d + 0.9), cf = CF(c + V(0, y, 0)), color = trim, mat = M.Metal, parent = m })
	end
	P({ name = "Lobby", size = V(o.w + 0.6, 10, o.d + 0.6), cf = CF(c + V(0, 5, 0)), color = Color3.fromRGB(40, 55, 70), mat = M.Glass, transp = 0.25, parent = m })
	local front = o.front or V(0, 0, 1)
	local frontDepth = if front.X ~= 0 then o.w else o.d
	local canopyPos = c + front * (frontDepth / 2 + 3) + V(0, 10.5, 0)
	P({ name = "Canopy", size = V(16, 0.6, 6), cf = CFrame.lookAt(canopyPos, canopyPos + front), color = trim, mat = M.Metal, parent = m })
	local doorPos = c + front * (frontDepth / 2 + 0.35) + V(0, 4.5, 0)
	P({ name = "Door", size = V(8, 9, 0.4), cf = CFrame.lookAt(doorPos, doorPos + front), color = Color3.fromRGB(25, 30, 36), mat = M.Glass, transp = 0.1, parent = m })
	if not o.flatRoof then
		P({ name = "Crown", size = V(o.w + 1.5, 2, o.d + 1.5), cf = CF(c + V(0, o.h + 1, 0)), color = trim, mat = M.Metal, parent = m })
		P({ name = "RoofBox", size = V(o.w * 0.5, 6, o.d * 0.5), cf = CF(c + V(0, o.h + 5, 0)), color = Color3.fromRGB(90, 92, 98), mat = M.Concrete, parent = m })
		if o.spire then
			cylinder("Spire", c + V(0, o.h + 8, 0), o.spire, 1.4, Color3.fromRGB(200, 200, 210), M.Metal, m)
			local beacon = P({ name = "Beacon", size = V(2, 2, 2), cf = CF(c + V(0, o.h + 8 + o.spire + 1, 0)), color = Color3.fromRGB(255, 40, 40), mat = M.Neon, shape = Enum.PartType.Ball, parent = m })
			pointLight(beacon, 30, 2, Color3.fromRGB(255, 60, 60))
		end
	end
	return m
end

---------------------------------------------------------------------------
-- Interactions: elevators (section 49)
---------------------------------------------------------------------------
local function canMove(player: Player): (boolean, string?)
	if not Net.alive(player) then
		return false, nil
	end
	local driving = player:GetAttribute("Driving")
	if type(driving) == "string" and driving ~= "" then
		return false, "Park your vehicle first."
	end
	if (player:GetAttribute("Interior") or "") ~= "" then
		return false, nil
	end
	return true, nil
end

-- Two linked doors: ground floor <-> roof.
local function elevator(name: string, groundDoor: Vector3, groundFace: Vector3, roofDoor: Vector3, roofFace: Vector3)
	local m = model(name .. "Elevator")
	local function door(pos: Vector3, face: Vector3, label: string): BasePart
		local p = pos + V(0, 4.5, 0)
		local d = P({ name = "ElevatorDoor", size = V(6, 9, 0.6), cf = CFrame.lookAt(p, p + face), color = Color3.fromRGB(190, 190, 200), mat = M.Metal, parent = m })
		local framePos = p + V(0, 5.5, 0) + face * 0.1
		local frame = P({ name = "ElevatorSign", size = V(6, 1.6, 0.4), cf = CFrame.lookAt(framePos, framePos + face), color = C.signBg, parent = m })
		H.sign(frame, Enum.NormalId.Front, label, Color3.fromRGB(255, 200, 80))
		return d
	end
	local lower = door(groundDoor, groundFace, "ELEVATOR  ▲ ROOF")
	local upper = door(roofDoor, roofFace, "ELEVATOR  ▼ STREET")
	-- a little booth on the roof so the door isn't floating
	local booth = roofDoor - roofFace * 3.4 + V(0, 5, 0)
	P({ name = "ElevatorBooth", size = V(7, 10, 6), cf = CFrame.lookAt(booth, booth + roofFace), color = Color3.fromRGB(80, 82, 90), mat = M.Concrete, parent = m })
	local up = addPrompt(lower, "RideUp", "Ride up", name .. " elevator", 9)
	local down = addPrompt(upper, "RideDown", "Ride down", name .. " elevator", 9)
	local function ride(player: Player, from: BasePart, to: Vector3, face: Vector3)
		if not Net.allow(player, "Elevator", 1.5) then
			return
		end
		local ok, reason = canMove(player)
		if not ok then
			if reason then
				Net.notify(player, "ELEVATOR", reason)
			end
			return
		end
		if Net.distance(player, from.Position) > 14 then
			return
		end
		local spot = to + face * 5
		Places.teleport(player, CFrame.lookAt(spot, spot + face))
	end
	up.Triggered:Connect(function(player)
		ride(player, lower, roofDoor, roofFace)
	end)
	down.Triggered:Connect(function(player)
		ride(player, upper, groundDoor, groundFace)
	end)
end

---------------------------------------------------------------------------
-- Subway stations (section 11)
---------------------------------------------------------------------------
local stationPrompts: { [string]: ProximityPrompt } = {}

local function buildStation(st: DC.Station)
	local m = model("SubwayEntrance")
	local p = st.entrance
	P({ name = "Base", size = V(14, 1, 12), cf = CF(p + V(0, 0.5, 0)), color = Color3.fromRGB(90, 90, 95), mat = M.Concrete, parent = m })
	local well = P({ name = "Stairwell", size = V(8, 1.1, 8), cf = CF(p + V(0, 0.55, 0)), color = Color3.fromRGB(10, 10, 12), parent = m })
	for _, x in { -5, 5 } do
		P({ name = "Rail", size = V(0.4, 3, 9), cf = CF(p + V(x, 2.5, 0)), color = st.line, mat = M.Metal, parent = m })
	end
	signBoard("Sign", p + V(0, 6, 5.8), V(12, 2.4, 0.4), V(0, 0, 1), "SUBWAY  " .. string.upper(st.name), C.white, st.line, m)
	for _, x in { -5.8, 5.8 } do
		P({ name = "SignPost", size = V(0.4, 6, 0.4), cf = CF(p + V(x, 3, 5.8)), color = C.dark, mat = M.Metal, parent = m })
	end
	local globe = P({ name = "Globe", size = V(1.4, 1.4, 1.4), cf = CF(p + V(0, 7.9, 5.8)), color = st.line, shape = Enum.PartType.Ball, parent = m })
	glowAtNight(globe, st.line)
	stationPrompts[st.id] = addPrompt(well, "TakeSubway", "Take Subway", "Subway · " .. st.name, 10)
	mapPoint("Subway · " .. st.name, "Transit", p + V(0, 0, 9))
end

---------------------------------------------------------------------------
-- Ferris wheel (moving rides, section 8)
---------------------------------------------------------------------------
local WHEEL_RADIUS = 38
local WHEEL_SPEED = math.pi * 2 / 100 -- one turn every 100 s
type Gondola = { parts: { BasePart }, offsets: { CFrame }, phase: number, seat: Seat, seatOffset: CFrame }
local wheel = {
	axle = Vector3.zero,
	parts = {} :: { BasePart },
	offsets = {} :: { CFrame },
	gondolas = {} :: { Gondola },
	angle = 0,
	active = false,
}

local function buildFerrisWheel(axle: Vector3)
	local m = model("FerrisWheel")
	wheel.axle = axle
	local R = WHEEL_RADIUS
	local function wheelPart(spec: any, offset: CFrame)
		spec.parent = m
		spec.collide = false
		spec.cf = CF(axle) * offset
		local part = P(spec)
		table.insert(wheel.parts, part)
		table.insert(wheel.offsets, offset)
	end
	local segs = 20
	local segLen = 2 * math.pi * R / segs + 0.4
	for _, z in { -2.8, 2.8 } do
		for i = 0, segs - 1 do
			local a = i / segs * math.pi * 2
			wheelPart({ name = "Rim", size = V(1, segLen, 1), color = if i % 2 == 0 then Color3.fromRGB(255, 80, 170) else Color3.fromRGB(80, 220, 255), mat = M.Neon }, CF(math.cos(a) * R, math.sin(a) * R, z) * CFrame.Angles(0, 0, a))
		end
		for i = 0, 9 do
			local a = i / 10 * math.pi * 2
			wheelPart({ name = "Spoke", size = V(0.5, R, 0.5), color = C.white, mat = M.Metal }, CF(0, 0, z) * CFrame.Angles(0, 0, a - math.pi / 2) * CF(0, R / 2, 0))
		end
	end
	wheelPart({ name = "Hub", size = V(7, 4, 4), color = Color3.fromRGB(230, 230, 235), mat = M.Metal, shape = Enum.PartType.Cylinder }, CFrame.Angles(0, math.pi / 2, 0))

	-- A-frame legs (static)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local foot = axle + V(sx * 22, -axle.Y, sz * 7)
			local top = axle + V(0, 0, sz * 4.5)
			P({ name = "Leg", size = V(1.4, 1.4, (top - foot).Magnitude), cf = CFrame.lookAt((foot + top) / 2, top), color = C.white, mat = M.Metal, parent = m })
		end
	end
	P({ name = "BoardingDeck", size = V(16, 1, 12), cf = CF(axle.X, 0.5, axle.Z), color = C.wood, mat = M.WoodPlanks, parent = m })

	-- Gondolas hang upright from the rim; each has a real Seat.
	for i = 0, 9 do
		local g: Gondola = { parts = {}, offsets = {}, phase = i / 10 * math.pi * 2, seat = nil :: any, seatOffset = CF(0, -4.1, 0.4) }
		local color = Color3.fromHSV(i / 10, 0.65, 0.95)
		local function gp(spec: any, offset: CFrame)
			spec.parent = m
			spec.collide = false
			spec.cf = CF(axle) * offset
			local part = P(spec)
			table.insert(g.parts, part)
			table.insert(g.offsets, offset)
		end
		gp({ name = "Hanger", size = V(0.3, 1.2, 0.3), color = C.metal, mat = M.Metal }, CF(0, -0.6, 0))
		gp({ name = "Roof", size = V(4.6, 0.4, 3.6), color = color }, CF(0, -1.3, 0))
		gp({ name = "Back", size = V(4.2, 3.6, 0.3), color = color }, CF(0, -3.2, 1.45))
		gp({ name = "Floor", size = V(4.2, 0.3, 3.2), color = Color3.fromRGB(60, 60, 66) }, CF(0, -5.1, 0))
		local s = seat(axle, V(0, 0, -1), Color3.fromRGB(240, 240, 245), m)
		s.Name = "GondolaSeat"
		s.Size = V(3.4, 0.5, 1.6)
		s.CanCollide = false
		g.seat = s
		table.insert(wheel.gondolas, g)
	end
	signBoard("WheelSign", V(axle.X, 3, axle.Z - 10), V(16, 3, 0.4), V(0, 0, -1), "FERRIS WHEEL · WALK INTO A CAR TO RIDE", Color3.fromRGB(255, 120, 200), nil, m)
	pointLight(m:FindFirstChild("Hub") :: BasePart, 40, 2, Color3.fromRGB(255, 120, 220))
end

-- Moves every wheel part and gondola to the wheel's current angle.
local wheelMoveParts: { BasePart } = {}
local wheelMoveCFrames: { CFrame } = {}
local function poseWheel()
	local axleCF = CF(wheel.axle)
	local rot = axleCF * CFrame.Angles(0, 0, wheel.angle)
	local n = 0
	for i, part in wheel.parts do
		n += 1
		wheelMoveParts[n] = part
		wheelMoveCFrames[n] = rot * wheel.offsets[i]
	end
	for _, g in wheel.gondolas do
		local a = wheel.angle + g.phase
		local pivot = CF(wheel.axle + V(math.cos(a) * WHEEL_RADIUS, math.sin(a) * WHEEL_RADIUS, 0))
		for j, part in g.parts do
			n += 1
			wheelMoveParts[n] = part
			wheelMoveCFrames[n] = pivot * g.offsets[j]
		end
		-- the seat moves with a plain CFrame write so seated riders (welded) come along
		g.seat.CFrame = pivot * g.seatOffset
	end
	workspace:BulkMoveTo(wheelMoveParts, wheelMoveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
end

---------------------------------------------------------------------------
-- Downtown (section 6)
---------------------------------------------------------------------------
local leaderboardRows: { [string]: { TextLabel } } = {}
local billboardTitles: { TextLabel } = {}
local billboardBodies: { TextLabel } = {}

local function buildLeaderboard(pos: Vector3, dir: Vector3)
	local m = model("Leaderboard")
	for _, x in { -14, 14 } do
		local right = V(-dir.Z, 0, dir.X)
		P({ name = "Leg", size = V(1, 8, 1), cf = CF(pos + right * x - dir * 0.5 + V(0, 4, 0)), color = C.dark, mat = M.Metal, parent = m })
	end
	local center = pos + V(0, 17, 0)
	local board = P({ name = "Board", size = V(36, 18, 1), cf = CFrame.lookAt(center, center + dir), color = Color3.fromRGB(14, 14, 20), parent = m })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = board
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(14, 14, 22)
	bg.BorderSizePixel = 0
	bg.Parent = gui
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.16, 0)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 200, 60)
	title.Text = "CITY LEADERS · THIS SERVER"
	title.Parent = bg
	local stats = { { "Level", "LEVEL", Color3.fromRGB(90, 170, 255) }, { "Reputation", "REPUTATION", Color3.fromRGB(255, 120, 60) }, { "Fame", "FAME", Color3.fromRGB(255, 90, 200) } }
	for i, stat in stats do
		local col = Instance.new("Frame")
		col.BackgroundColor3 = Color3.fromRGB(28, 28, 40)
		col.BorderSizePixel = 0
		col.Position = UDim2.new((i - 1) / 3, 8, 0.18, 0)
		col.Size = UDim2.new(1 / 3, -16, 0.8, -8)
		col.Parent = bg
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 16)
		corner.Parent = col
		local head = Instance.new("TextLabel")
		head.BackgroundTransparency = 1
		head.Size = UDim2.new(1, 0, 0.16, 0)
		head.Font = Enum.Font.GothamBlack
		head.TextScaled = true
		head.TextColor3 = stat[3]
		head.Text = stat[2]
		head.Parent = col
		local rows = {}
		for r = 1, 5 do
			local row = Instance.new("TextLabel")
			row.BackgroundTransparency = 1
			row.Position = UDim2.new(0, 12, 0.18 + (r - 1) * 0.16, 0)
			row.Size = UDim2.new(1, -24, 0.15, 0)
			row.Font = Enum.Font.GothamBold
			row.TextScaled = true
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.TextColor3 = Color3.fromRGB(235, 235, 245)
			row.Text = ""
			row.Parent = col
			table.insert(rows, row)
		end
		leaderboardRows[stat[1]] = rows
	end
end

local function refreshLeaderboard()
	local players = Players:GetPlayers()
	for stat, rows in leaderboardRows do
		local list = {}
		for _, p in players do
			local v = p:GetAttribute(stat)
			table.insert(list, { name = p.DisplayName, value = if type(v) == "number" then v else 0 })
		end
		table.sort(list, function(a, b)
			if a.value ~= b.value then
				return a.value > b.value
			end
			return a.name < b.name
		end)
		for r, row in rows do
			local e = list[r]
			row.Text = if e then string.format("%d. %s  ·  %d", r, e.name, e.value) else (if r == 1 then "Waiting for players" else "")
		end
	end
end

-- A digital billboard screen (title + body) that cycles real city info.
local function billboard(pos: Vector3, size: Vector3, dir: Vector3, parent: Instance?)
	local board = P({ name = "Billboard", size = size, cf = CFrame.lookAt(pos, pos + dir), color = Color3.fromRGB(10, 10, 14), parent = parent })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.Brightness = 1.5
	gui.Parent = board
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BorderSizePixel = 0
	bg.BackgroundColor3 = Color3.fromRGB(16, 18, 40)
	bg.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromRGB(40, 60, 160), Color3.fromRGB(140, 40, 140))
	grad.Rotation = 30
	grad.Parent = bg
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromScale(0.05, 0.08)
	t.Size = UDim2.fromScale(0.9, 0.4)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = Color3.fromRGB(255, 220, 90)
	t.Text = "CITY GRIND"
	t.Parent = bg
	local b = Instance.new("TextLabel")
	b.BackgroundTransparency = 1
	b.Position = UDim2.fromScale(0.05, 0.52)
	b.Size = UDim2.fromScale(0.9, 0.38)
	b.Font = Enum.Font.GothamBold
	b.TextScaled = true
	b.TextWrapped = true
	b.TextColor3 = C.white
	b.Text = ""
	b.Parent = bg
	table.insert(billboardTitles, t)
	table.insert(billboardBodies, b)
	return board
end

local function clockText(): string
	local t = Lighting.ClockTime
	local h = math.floor(t)
	local mins = math.floor((t - h) * 60)
	local h12 = h % 12
	return string.format("%d:%02d %s", if h12 == 0 then 12 else h12, mins, if h >= 12 then "PM" else "AM")
end

local function billboardMessages(): { { string } }
	local list = {}
	local players = Players:GetPlayers()
	table.insert(list, { "CITY GRIND", string.format("%d %s in the city right now", #players, if #players == 1 then "player" else "players") })
	local total, live = 0, 0
	for _, court in CollectionService:GetTagged("Court") do
		total += 1
		local state = court:GetAttribute("State")
		if state ~= nil and state ~= "Idle" then
			live += 1
		end
	end
	table.insert(list, { "PICKUP GAMES", string.format("%d of %d courts in play · stand on a team pad to join", live, total) })
	table.insert(list, { "SUBWAY", string.format("$%d to any district · entrances in every district", DC.SUBWAY_FARE) })
	local best, bestLevel = nil, -1
	for _, p in players do
		local lv = p:GetAttribute("Level")
		if type(lv) == "number" and lv > bestLevel then
			best, bestLevel = p, lv
		end
	end
	if best then
		table.insert(list, { "TOP PLAYER", string.format("%s · Level %d", best.DisplayName, bestLevel) })
	end
	table.insert(list, { "ROOFTOP COURT", "Summit Tower · take the elevator to the roof" })
	table.insert(list, { "LUXURY HILLS", string.format("Private court: Reputation %d+ or Level %d+", DC.PRIVATE_COURT_REPUTATION, DC.PRIVATE_COURT_LEVEL) })
	table.insert(list, { "RACE TRACK", "Industrial District · grandstand open to everyone" })
	local night = Lighting.ClockTime < 6.3 or Lighting.ClockTime > 17.7
	table.insert(list, { "CITY TIME", clockText() .. (if night then " · the city never sleeps" else " · get your grind on") })
	return list
end

local billboardIndex = 0
local function cycleBillboards()
	local msgs = billboardMessages()
	billboardIndex += 1
	for i, t in billboardTitles do
		local msg = msgs[(billboardIndex + i - 2) % #msgs + 1]
		t.Text = msg[1]
		billboardBodies[i].Text = msg[2]
	end
end

-- Multi-level parking garage cars can drive up (two decks, two ramps).
local function parkingGarage(x0: number, z0: number)
	local m = model("ParkingGarage")
	local concrete = Color3.fromRGB(150, 150, 150)
	local W, D, E = x0, x0 + 14, x0 + 56 -- west strip | deck | east strip
	local z1 = z0 + 110
	local function slab(name: string, ax: number, bx: number, az: number, bz: number, top: number)
		P({ name = name, size = V(bx - ax, 1, bz - az), cf = CF((ax + bx) / 2, top - 0.5, (az + bz) / 2), color = concrete, mat = M.Concrete, parent = m, map = Color3.fromRGB(120, 120, 125), layer = 3 })
	end
	local function wall(ax: number, bx: number, az: number, bz: number, top: number)
		P({ name = "Parapet", size = V(math.max(1, bx - ax), 3, math.max(1, bz - az)), cf = CF((ax + bx) / 2, top + 1.5, (az + bz) / 2), color = Color3.fromRGB(180, 180, 175), mat = M.Concrete, parent = m })
	end
	-- level 1 (y 10) and level 2 (y 20) decks
	slab("Deck", D, E, z0, z1, 10)
	slab("Deck", D, E, z0, z1, 20)
	slab("Landing", E, E + 14, z0, z0 + 20, 10)
	slab("Landing", W, D, z0, z0 + 20, 10)
	slab("Landing", W, D, z1 - 10, z1, 20)
	-- ramp 1: ground -> L1 (east strip, northward); ramp 2: L1 -> L2 (west strip, southward)
	ramp("Ramp", V(E + 7, 0.3, z1 - 10), V(E + 7, 10, z0 + 20), 14, concrete, M.Concrete, 1, m)
	ramp("Ramp", V(W + 7, 10, z0 + 20), V(W + 7, 20, z1 - 10), 14, concrete, M.Concrete, 1, m)
	for _, x in { D + 1, E - 1 } do
		for _, z in { z0 + 2, (z0 + z1) / 2, z1 - 2 } do
			P({ name = "Pillar", size = V(1.5, 20, 1.5), cf = CF(x, 10, z), color = concrete, mat = M.Concrete, parent = m })
		end
	end
	-- parapets
	wall(W, E + 14, z0, z0 + 1, 10)
	wall(D, E, z1 - 1, z1, 10)
	wall(D, D + 1, z0 + 20, z1, 10)
	wall(E - 1, E, z0 + 20, z1, 10)
	wall(E + 13, E + 14, z0, z0 + 20, 10)
	wall(W, W + 1, z0, z0 + 20, 10)
	wall(D, E, z0, z0 + 1, 20)
	wall(W, E, z1 - 1, z1, 20)
	wall(D, D + 1, z0, z1 - 10, 20)
	wall(E - 1, E, z0, z1, 20)
	wall(W, W + 1, z1 - 10, z1, 20)
	signBoard("GarageSign", V(E + 7, 8, z1 + 0.5), V(14, 3, 0.4), V(0, 0, 1), "PARKING  ▲", C.white, Color3.fromRGB(30, 90, 200), m)
	for _, z in { z0 + 30, z1 - 30 } do
		local lamp = P({ name = "DeckLight", size = V(3, 0.3, 3), cf = CF((D + E) / 2, 19.3, z), color = Color3.fromRGB(255, 250, 230), mat = M.Neon, collide = false, parent = m })
		pointLight(lamp, 30, 1.2, Color3.fromRGB(255, 245, 225))
	end
end

-- Indoor-style arena: court + stands (Seats) + open-roof shell + floodlights.
local function arena(c: Vector3)
	local m = model("GrandArena")
	P({ name = "Concourse", size = V(100, 0.2, 112), cf = CF(c + V(0, 0.05, 0)), color = Color3.fromRGB(45, 45, 52), mat = M.Concrete, parent = m, map = Color3.fromRGB(90, 90, 110), layer = 3 })
	local court = H.buildCourt("GrandArena", c, Color3.fromRGB(150, 105, 60), Color3.fromRGB(30, 60, 140))
	court.Parent = current
	local floor = court:FindFirstChild("CourtFloor")
	if floor and floor:IsA("BasePart") then
		floor.Material = M.WoodPlanks
	end
	-- stands on both long sides, three tiers, seats facing the court
	local standColor = Color3.fromRGB(70, 70, 82)
	for _, side in { -1, 1 } do
		for k = 1, 3 do
			local inner = 30 + (k - 1) * 5
			local width = 46 - inner
			P({ name = "Stand", size = V(width, 3 * k, 84), cf = CF(c + V(side * (inner + width / 2), 1.5 * k, 0)), color = standColor, mat = M.Concrete, parent = m })
			for z = -36, 36, 9 do
				seat(c + V(side * (inner + 2.5), 3 * k + 0.25, z), V(-side, 0, 0), if side == 1 then Color3.fromRGB(200, 40, 50) else Color3.fromRGB(40, 90, 200), m)
			end
		end
	end
	-- shell walls with the entrance on the south side
	local wallColor = Color3.fromRGB(205, 205, 215)
	local h = 26
	for _, side in { -1, 1 } do
		P({ name = "ArenaWall", size = V(2, h, 114), cf = CF(c + V(side * 50, h / 2, 0)), color = wallColor, mat = M.Concrete, parent = m, map = Color3.fromRGB(150, 150, 170), layer = 3 })
		P({ name = "ArenaWall", size = V(40, h, 2), cf = CF(c + V(side * 30, h / 2, 56)), color = wallColor, mat = M.Concrete, parent = m })
	end
	P({ name = "ArenaWall", size = V(102, h, 2), cf = CF(c + V(0, h / 2, -56)), color = wallColor, mat = M.Concrete, parent = m })
	P({ name = "Lintel", size = V(20, h - 14, 2), cf = CF(c + V(0, 14 + (h - 14) / 2, 56)), color = wallColor, mat = M.Concrete, parent = m })
	signBoard("ArenaSign", c + V(0, 20, 57.3), V(40, 6, 0.5), V(0, 0, 1), "GRAND ARENA", Color3.fromRGB(255, 200, 60), nil, m)
	-- roof trusses over the open roof
	for _, z in { -30, 30 } do
		P({ name = "Truss", size = V(102, 2, 2.5), cf = CF(c + V(0, h + 1, z)), color = C.metal, mat = M.Metal, parent = m })
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			floodlight(c + V(sx * 47, 0, sz * 52), h + 4, c + V(sx * 8, 0, sz * 14))
		end
	end
	billboard(c + V(-51.3, 18, 0), V(40, 12, 0.6), V(-1, 0, 0), m)
end

local function plaza(x0: number, x1: number, z0: number, z1: number)
	local m = model("DowntownPlaza")
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	P({ name = "Plaza", size = V(x1 - x0, 0.2, z1 - z0), cf = CF(cx, 0.15, cz), color = Color3.fromRGB(196, 186, 170), mat = M.Slate, parent = m, map = Color3.fromRGB(190, 180, 160), layer = 2 })
	-- fountain
	local fc = V(cx, 0, cz + 10)
	cylinder("FountainBasin", fc, 2.4, 26, Color3.fromRGB(210, 210, 215), M.Marble, m)
	local water = cylinder("FountainWater", fc + V(0, 2.4, 0), 0.3, 23, Color3.fromRGB(80, 170, 230), M.Glass, m)
	water.Transparency = 0.25
	water.CanCollide = false
	cylinder("FountainColumn", fc, 9, 3, Color3.fromRGB(220, 220, 225), M.Marble, m)
	local jet = P({ name = "FountainTop", size = V(4, 4, 4), cf = CF(fc + V(0, 9.5, 0)), color = Color3.fromRGB(120, 200, 255), mat = M.Glass, transp = 0.3, shape = Enum.PartType.Ball, parent = m })
	pointLight(jet, 30, 2, Color3.fromRGB(120, 200, 255))
	-- benches around the fountain, trees and lanterns around the edge
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local p = fc + V(math.cos(a) * 22, 0, math.sin(a) * 22)
		H.bench(CFrame.lookAt(p, V(fc.X, p.Y, fc.Z)), m)
	end
	for _, off in { V(-80, 0, -50), V(-80, 0, 50), V(80, 0, -50), V(80, 0, 50), V(-40, 0, 60), V(40, 0, 60) } do
		H.tree(V(cx, 0, cz) + off, m)
	end
	for _, off in { V(-50, 0, -30), V(50, 0, -30), V(-50, 0, 40), V(50, 0, 40) } do
		lantern(V(cx, 0, cz) + off)
	end
	buildLeaderboard(V(cx, 0, z0 + 6), V(0, 0, 1))
	-- big screen on the west side of the plaza
	for _, z in { -10, 10 } do
		P({ name = "ScreenLeg", size = V(1, 10, 1), cf = CF(x0 + 6, 5, cz + z), color = C.dark, mat = M.Metal, parent = m })
	end
	billboard(V(x0 + 6.6, 16, cz), V(28, 14, 0.8), V(1, 0, 0), m)
	mapPoint("Downtown Plaza", "Social", V(cx, 0, z1 - 4))
end

local function buildDowntown()
	-- ground + roads: cross road north from the Neighborhood, avenue along z = -480
	ground(-300, 300, -730, -230, Color3.fromRGB(128, 128, 132), M.Concrete, Color3.fromRGB(110, 110, 116))
	road("z", -730, -230, 0, { walkGaps = { { -504, -456 } }, lampEvery = 70 })
	road("x", -300, 300, -480, { walkGaps = { { -16, 16 } }, lampEvery = 70 })
	-- the cross road's asphalt must not overlap the avenue: cover the junction with the avenue only
	for _, d in current:GetChildren() do
		if d.Name == "CrossRoad" and d:IsA("BasePart") then
			d:Destroy()
		end
	end
	for _, seg in { { -730, -496 }, { -464, -230 } } do
		P({ name = "CrossRoad", size = V(ROAD_W, 0.2, seg[2] - seg[1]), cf = CF(0, 0.1, (seg[1] + seg[2]) / 2), color = C.asphalt, mat = M.Asphalt, map = C.mapRoad, layer = 2 })
	end

	-- SW block: bank, bistro, Lumen Tower, the social plaza
	shop({ name = "City Bank", center = V(-90, 0, -425), size = V(56, 30, 30), color = Color3.fromRGB(225, 220, 205), material = M.Marble, face = "N", signText = "CITY BANK", signColor = Color3.fromRGB(255, 215, 90), category = "Landmark", floorHeight = 15 })
	shop({ name = "Cielo Bistro", center = V(-170, 0, -428), size = V(40, 16, 26), color = Color3.fromRGB(120, 40, 45), face = "N", signText = "CIELO BISTRO", signColor = Color3.fromRGB(255, 230, 190), category = "Landmark" })
	tower({ name = "Lumen Tower", center = V(-255, 0, -425), w = 40, d = 40, h = 80, color = Color3.fromRGB(70, 80, 95), glass = Color3.fromRGB(100, 150, 190), lit = 0.6, front = V(0, 0, -1) })
	plaza(-262, -60, -395, -240)

	-- SE block: arena, diner, Vista Tower with a billboard facing the cross road
	arena(V(190, 0, -343))
	shop({ name = "Skyline Diner", center = V(70, 0, -428), size = V(40, 16, 26), color = Color3.fromRGB(200, 200, 210), material = M.Concrete, face = "N", signText = "SKYLINE DINER", signColor = Color3.fromRGB(255, 90, 90), category = "Landmark" })
	tower({ name = "Vista Tower", center = V(70, 0, -330), w = 44, d = 44, h = 72, color = Color3.fromRGB(180, 180, 190), glass = Color3.fromRGB(90, 140, 200), lit = 0.5, front = V(-1, 0, 0) })
	billboard(V(47.4, 46, -330), V(30, 16, 0.6), V(-1, 0, 0))

	-- NW block: luxury storefronts on the avenue, towers behind
	shop({ name = "Maison Or", center = V(-250, 0, -530), size = V(40, 18, 30), color = Color3.fromRGB(30, 30, 34), material = M.Marble, face = "S", signText = "MAISON OR", signColor = Color3.fromRGB(230, 190, 90), category = "Landmark" })
	shop({ name = "Gem & Co Jewelers", center = V(-195, 0, -530), size = V(36, 18, 30), color = Color3.fromRGB(235, 235, 240), material = M.Marble, face = "S", signText = "GEM & CO", signColor = Color3.fromRGB(80, 200, 230), category = "Landmark" })
	shop({ name = "Velvet Watches", center = V(-145, 0, -530), size = V(36, 18, 30), color = Color3.fromRGB(90, 30, 60), material = M.Concrete, face = "S", signText = "VELVET WATCHES", signColor = Color3.fromRGB(255, 200, 230) })
	shop({ name = "Cafe Lumiere", center = V(-90, 0, -530), size = V(34, 16, 30), color = Color3.fromRGB(240, 225, 200), material = M.Concrete, face = "S", signText = "CAFÉ LUMIÈRE", signColor = Color3.fromRGB(120, 70, 40) })
	tower({ name = "Crown Plaza", center = V(-240, 0, -640), w = 60, d = 60, h = 120, color = Color3.fromRGB(50, 55, 65), glass = Color3.fromRGB(80, 120, 160), lit = 0.55, trim = Color3.fromRGB(190, 160, 90) })
	tower({ name = "Harbor Trust", center = V(-140, 0, -650), w = 50, d = 50, h = 90, color = Color3.fromRGB(200, 195, 185), glass = Color3.fromRGB(110, 160, 190), lit = 0.45 })
	tower({ name = "Nova Tower", center = V(-60, 0, -630), w = 44, d = 44, h = 170, color = Color3.fromRGB(30, 34, 44), glass = Color3.fromRGB(60, 110, 170), lit = 0.7, spire = 30, nightColor = C.windowCool })

	-- NE block: Summit Tower (rooftop court), Apex HQ, Meridian, noodle bar, parking garage
	local summit = V(80, 0, -660)
	tower({ name = "Summit Tower", center = summit, w = 80, d = 104, h = 60, color = Color3.fromRGB(150, 155, 165), glass = Color3.fromRGB(90, 140, 190), lit = 0.6, flatRoof = true })
	local roofY = 60
	local rooftop = H.buildCourt("SummitRooftopCourt", summit + V(0, roofY, 0), Color3.fromRGB(40, 40, 48), Color3.fromRGB(200, 60, 70))
	rooftop.Parent = current
	-- tall glass railing so players and balls stay on the roof
	for _, side in { -1, 1 } do
		P({ name = "RoofGlass", size = V(0.6, 16, 104), cf = CF(summit + V(side * 40, roofY + 8, 0)), color = Color3.fromRGB(180, 220, 255), mat = M.Glass, transp = 0.7 })
		P({ name = "RoofGlass", size = V(80, 16, 0.6), cf = CF(summit + V(0, roofY + 8, side * 52)), color = Color3.fromRGB(180, 220, 255), mat = M.Glass, transp = 0.7 })
	end
	floodlight(summit + V(-38, roofY, -50), 14, summit + V(0, roofY, -20))
	floodlight(summit + V(38, roofY, 50), 14, summit + V(0, roofY, 20))
	elevator("Summit Tower", summit + V(20, 0, 52.2), V(0, 0, 1), summit + V(33, roofY, 48), V(-1, 0, 0))
	mapPoint("Summit Tower Elevator", "Court", summit + V(20, 0, 58))

	tower({ name = "Apex Corp HQ", center = V(170, 0, -670), w = 56, d = 56, h = 140, color = Color3.fromRGB(20, 22, 28), glass = Color3.fromRGB(40, 80, 130), lit = 0.65, spire = 18, nightColor = C.windowCool, front = V(0, 0, 1) })
	tower({ name = "Meridian", center = V(170, 0, -575), w = 50, d = 50, h = 100, color = Color3.fromRGB(210, 205, 195), glass = Color3.fromRGB(110, 170, 200), lit = 0.5 })
	billboard(V(170, 44, -549.4), V(34, 18, 0.6), V(0, 0, 1))
	shop({ name = "Golden Noodle", center = V(75, 0, -560), size = V(40, 16, 26), color = Color3.fromRGB(170, 40, 40), face = "S", signText = "GOLDEN NOODLE", signColor = Color3.fromRGB(255, 215, 90) })
	lot(220, 290, -720, -504)
	parkingGarage(220, -720)
	mapPoint("Downtown Parking", "Transit", V(255, 0, -508))
end

---------------------------------------------------------------------------
-- Underground pieces shared by Industrial and Old Town (secret tunnels)
---------------------------------------------------------------------------
-- A wall along X (axis "x", at z = fixed) or Z, from y0 to y1, with an optional opening.
local function wallWithOpening(axis: string, fixed: number, from: number, to: number, y0: number, y1: number, color: Color3, opening: { number }?)
	local function piece(a: number, b: number, ya: number, yb: number)
		if b - a < 0.05 or yb - ya < 0.05 then
			return
		end
		local mid, my = (a + b) / 2, (ya + yb) / 2
		P({
			name = "Wall",
			size = if axis == "x" then V(b - a, yb - ya, 1) else V(1, yb - ya, b - a),
			cf = if axis == "x" then CF(mid, my, fixed) else CF(fixed, my, mid),
			color = color,
			mat = M.Brick,
		})
	end
	if opening then
		piece(from, opening[1], y0, y1)
		piece(opening[2], to, y0, y1)
		piece(opening[1], opening[2], opening[3], y1)
	else
		piece(from, to, y0, y1)
	end
end

type Openings = { N: { number }?, S: { number }?, E: { number }?, W: { number }? }
local function undergroundRoom(x0: number, x1: number, z0: number, z1: number, floorY: number, ceilY: number, color: Color3, openings: Openings)
	P({ name = "Floor", size = V(x1 - x0 + 2, 1, z1 - z0 + 2), cf = CF((x0 + x1) / 2, floorY - 0.5, (z0 + z1) / 2), color = Color3.fromRGB(70, 66, 60), mat = M.Slate })
	P({ name = "Ceiling", size = V(x1 - x0 + 2, 1, z1 - z0 + 2), cf = CF((x0 + x1) / 2, ceilY + 0.5, (z0 + z1) / 2), color = Color3.fromRGB(50, 48, 46), mat = M.Concrete })
	wallWithOpening("x", z0 - 0.5, x0 - 1, x1 + 1, floorY, ceilY, color, openings.N)
	wallWithOpening("x", z1 + 0.5, x0 - 1, x1 + 1, floorY, ceilY, color, openings.S)
	wallWithOpening("z", x0 - 0.5, z0, z1, floorY, ceilY, color, openings.W)
	wallWithOpening("z", x1 + 0.5, z0, z1, floorY, ceilY, color, openings.E)
end

-- A ramp going down from street level through a hole in the ground.
-- Hole spans x [hx0,hx1]; the ramp runs from zTop (y 0.05) to zBottom (y floorY).
local function downRamp(hx0: number, hx1: number, zTop: number, zBottom: number, floorY: number, color: Color3)
	local cx = (hx0 + hx1) / 2
	local rampW = hx1 - hx0 - 6
	ramp("TunnelRamp", V(cx, 0.05, zTop), V(cx, floorY, zBottom), rampW, Color3.fromRGB(90, 86, 80), M.Concrete, 1)
	local dz = zBottom - zTop
	for _, x in { hx0 + 1.5, hx1 - 1.5 } do
		P({ name = "RampWall", size = V(3, -floorY + 2.05, math.abs(dz)), cf = CF(x, (floorY - 2 + 0.05) / 2, (zTop + zBottom) / 2), color = color, mat = M.Brick })
	end
	-- lintel where the ramp dives under the ground into the room
	P({ name = "Lintel", size = V(hx1 - hx0, 8.05, 1), cf = CF(cx, -3.975, zBottom + (if dz < 0 then 0.5 else -0.5)), color = color, mat = M.Brick })
end

local TUNNEL_Z = -215
local UNDER_FLOOR = -20

local function buildSecretTunnel()
	-- runs under the Neighborhood from Old Town's catacombs to the Industrial underground
	local x0, x1 = -640, 800
	local len = x1 - x0
	local cx = (x0 + x1) / 2
	local wallColor = Color3.fromRGB(85, 75, 70)
	P({ name = "TunnelFloor", size = V(len, 1, 12), cf = CF(cx, UNDER_FLOOR - 0.5, TUNNEL_Z), color = Color3.fromRGB(60, 58, 55), mat = M.Slate })
	P({ name = "TunnelCeiling", size = V(len, 1, 14), cf = CF(cx, UNDER_FLOOR + 12.5, TUNNEL_Z), color = Color3.fromRGB(50, 48, 46), mat = M.Concrete })
	for _, side in { -1, 1 } do
		P({ name = "TunnelWall", size = V(len, 13, 1), cf = CF(cx, UNDER_FLOOR + 6, TUNNEL_Z + side * 6.5), color = wallColor, mat = M.Brick })
	end
	for x = x0 + 120, x1 - 60, 240 do
		local bulb = P({ name = "TunnelLight", size = V(1, 0.6, 1), cf = CF(x, UNDER_FLOOR + 11.6, TUNNEL_Z), color = Color3.fromRGB(255, 200, 120), mat = M.Neon, collide = false })
		pointLight(bulb, 40, 1.4, Color3.fromRGB(255, 190, 120), true)
	end
	secretArea("CityTunnel", "The Old Tunnel", V(cx, UNDER_FLOOR + 6, TUNNEL_Z), V(len, 12, 12))
end

---------------------------------------------------------------------------
-- Industrial (section 7)
---------------------------------------------------------------------------
local function truck(pos: Vector3, dir: Vector3, color: Color3)
	local m = model("Truck")
	local cab = pos + dir * 17 + V(0, 5, 0)
	P({ name = "Cab", size = V(8, 8, 8), cf = CFrame.lookAt(cab, cab + dir), color = color, mat = M.Metal, parent = m })
	local trailer = pos + V(0, 6, 0)
	P({ name = "Trailer", size = V(8.4, 9, 28), cf = CFrame.lookAt(trailer, trailer + dir), color = Color3.fromRGB(225, 225, 230), mat = M.Metal, parent = m })
	for _, d in { -9, 9, 17 } do
		local axle = pos + dir * d + V(0, 1.6, 0)
		P({ name = "Wheels", size = V(9, 3.2, 3.2), cf = CFrame.lookAt(axle, axle + dir), color = C.dark, mat = M.Rubber, shape = Enum.PartType.Cylinder, parent = m })
	end
end

local function container(pos: Vector3, color: Color3, parent: Instance)
	P({ name = "Container", size = V(8, 8.5, 40), cf = CF(pos + V(0, 4.25, 0)), color = color, mat = M.CorrodedMetal, parent = parent, map = Color3.fromRGB(150, 110, 80), layer = 3 })
end

local function raceTrack(center: Vector3, folder: Instance)
	local m = model("RaceTrack", folder)
	local checkpoints = Instance.new("Folder")
	checkpoints.Name = "Checkpoints"
	checkpoints.Parent = m
	local R, W, half = 90, 30, 130 -- curve radius, track width, half straight length
	local trackColor = Color3.fromRGB(38, 38, 42)
	local trackMap = Color3.fromRGB(40, 40, 46)
	local ends = { { x = center.X + half, from = -90, to = 90 }, { x = center.X - half, from = 90, to = 270 } }
	-- infield
	P({ name = "Infield", size = V(half * 2, 0.15, (R - W / 2) * 2), cf = CF(center + V(0, 0.08, 0)), color = Color3.fromRGB(80, 140, 70), mat = M.Grass, parent = m, map = Color3.fromRGB(80, 140, 70), layer = 2 })
	for _, e in ends do
		P({ name = "Infield", size = V(0.15, (R - W / 2) * 2, (R - W / 2) * 2), cf = CF(e.x, 0.08, center.Z) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(80, 140, 70), mat = M.Grass, shape = Enum.PartType.Cylinder, parent = m })
	end
	-- straights
	for _, sz in { -1, 1 } do
		local z = center.Z + sz * R
		P({ name = "TrackStraight", size = V(half * 2, 0.3, W), cf = CF(center.X, 0.15, z), color = trackColor, mat = M.Asphalt, parent = m, map = trackMap, layer = 3 })
		for i = 0, 9 do
			local x = center.X - half + (i + 0.5) * (half * 2 / 10)
			for _, edge in { -1, 1 } do
				P({ name = "Curb", size = V(half * 2 / 10, 0.4, 2), cf = CF(x, 0.2, z + edge * (W / 2 + 1)), color = if i % 2 == 0 then Color3.fromRGB(220, 40, 40) else C.white, parent = m })
			end
		end
	end
	-- curves
	local segs = 12
	for _, e in ends do
		local c = V(e.x, 0, center.Z)
		for i = 0, segs - 1 do
			local a = math.rad(e.from + (i + 0.5) * (e.to - e.from) / segs)
			local radial = V(math.cos(a), 0, math.sin(a))
			local tangent = V(-math.sin(a), 0, math.cos(a))
			local pos = c + radial * R + V(0, 0.15, 0)
			local arc = math.rad(180 / segs) * (R + W / 2) + 1
			P({ name = "TrackCurve", size = V(W, 0.3, arc), cf = CFrame.lookAt(pos, pos + tangent), color = trackColor, mat = M.Asphalt, parent = m, map = trackMap, layer = 3 })
			for _, edge in { -1, 1 } do
				local cp = c + radial * (R + edge * (W / 2 + 1)) + V(0, 0.2, 0)
				local clen = math.rad(180 / segs) * (R + edge * (W / 2 + 1)) + 0.3
				P({ name = "Curb", size = V(2, 0.4, clen), cf = CFrame.lookAt(cp, cp + tangent), color = if i % 2 == 0 then Color3.fromRGB(220, 40, 40) else C.white, parent = m })
			end
		end
	end
	-- start / finish on the south straight (travel direction: +x, counter-clockwise seen from above)
	local south = center.Z + R
	local startPos = V(center.X, 0.32, south)
	local line = P({ name = "StartLine", size = V(4, 0.06, W), cf = CF(startPos), color = C.white, collide = false, parent = m })
	line.CanTouch = true
	line.CanQuery = true
	line:SetAttribute("Forward", V(1, 0, 0))
	line:SetAttribute("TrackWidth", W)
	CollectionService:AddTag(line, "RaceStart")
	local checker = Instance.new("SurfaceGui")
	checker.Face = Enum.NormalId.Top
	checker.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	checker.PixelsPerStud = 10
	checker.Parent = line
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(20, 20)
	grid.CellPadding = UDim2.fromOffset(0, 0)
	grid.Parent = checker
	for i = 0, 29 do
		local sq = Instance.new("Frame")
		sq.BorderSizePixel = 0
		sq.BackgroundColor3 = if (i + math.floor(i / 2)) % 2 == 0 then Color3.new(0, 0, 0) else C.white
		sq.Parent = checker
	end
	for _, edge in { -1, 1 } do
		P({ name = "GantryPost", size = V(1.5, 18, 1.5), cf = CF(center.X, 9, south + edge * (W / 2 + 3)), color = C.metal, mat = M.Metal, parent = m })
	end
	local banner = P({ name = "Gantry", size = V(2, 4, W + 8), cf = CF(center.X, 17, south), color = C.signBg, parent = m })
	H.sign(banner, Enum.NormalId.Left, "START / FINISH", Color3.fromRGB(255, 220, 60))
	H.sign(banner, Enum.NormalId.Right, "START / FINISH", Color3.fromRGB(255, 220, 60))
	-- ordered checkpoints, one lap = 1..6 then the start line
	local eastC, westC = center.X + half, center.X - half
	local cps = {
		{ V(center.X + 100, 0, south), V(1, 0, 0) },
		{ V(eastC + R, 0, center.Z), V(0, 0, -1) },
		{ V(center.X + 60, 0, center.Z - R), V(-1, 0, 0) },
		{ V(center.X - 60, 0, center.Z - R), V(-1, 0, 0) },
		{ V(westC - R, 0, center.Z), V(0, 0, 1) },
		{ V(center.X - 100, 0, south), V(1, 0, 0) },
	}
	for i, cp in cps do
		local pos = cp[1] + V(0, 10, 0)
		local part = P({ name = "Checkpoint" .. i, size = V(W + 4, 20, 4), cf = CFrame.lookAt(pos, pos + cp[2]), transp = 1, collide = false, parent = checkpoints })
		part.CanTouch = true
		part:SetAttribute("Index", i)
	end
	m:SetAttribute("Checkpoints", #cps)
	m:SetAttribute("Center", center)
	-- grandstand with real seats on the outside of the south straight
	local gz = south + W / 2 + 10
	for k = 1, 3 do
		local front = gz + (k - 1) * 6
		local depth = 18 - (k - 1) * 6
		P({ name = "Grandstand", size = V(120, 2.5 * k, depth), cf = CF(center.X, 1.25 * k, front + depth / 2), color = Color3.fromRGB(80, 80, 92), mat = M.Concrete, parent = m, map = Color3.fromRGB(120, 120, 135), layer = 3 })
		for x = -55, 55, 10 do
			seat(V(center.X + x, 2.5 * k + 0.25, front + 2.5), V(0, 0, -1), Color3.fromRGB(240, 180, 30), m)
		end
	end
	P({ name = "GrandstandRoof", size = V(124, 1, 22), cf = CF(center.X, 20, gz + 9), color = C.white, mat = M.Metal, parent = m })
	for _, x in { -60, 60 } do
		P({ name = "RoofPost", size = V(1.2, 20, 1.2), cf = CF(center.X + x, 10, gz + 18), color = C.metal, mat = M.Metal, parent = m })
	end
	signBoard("TrackSign", V(center.X, 24, gz + 0.5), V(40, 5, 0.5), V(0, 0, -1), "CITY SPEEDWAY", Color3.fromRGB(255, 80, 60), nil, m)
	for _, off in { V(-half, 0, -R - W / 2 - 6), V(half, 0, -R - W / 2 - 6), V(-half - R - W / 2 - 6, 0, 0), V(half + R + W / 2 - 6 + 12, 0, 0) } do
		floodlight(center + off, 30, center + off * 0.6)
	end
end

local function buildIndustrial()
	local hole = { 830, 850, -200, -120 }
	ground(300, 900, -730, 230, Color3.fromRGB(122, 120, 112), M.Concrete, Color3.fromRGB(125, 120, 108), { hole })
	road("x", 300, 900, 0, { walkGaps = { { 300, 324 } } })
	-- service road from the main road up to the race paddock
	P({ name = "CrossRoad", size = V(24, 0.2, 406), cf = CF(312, 0.1, -227), color = C.asphalt, mat = M.Asphalt, map = C.mapRoad, layer = 2 })

	-- warehouses + depot + mechanic north of the main road
	for i, x in { 395, 485 } do
		local wh = shop({ name = "Warehouse " .. string.char(64 + i), center = V(x, 0, -75), size = V(70, 24, 60), color = Color3.fromRGB(150, 140, 120), material = M.CorrodedMetal, face = "S", signText = "WAREHOUSE " .. string.char(64 + i), signColor = Color3.fromRGB(255, 200, 80), floorHeight = 24 })
		P({ name = "RollerDoor", size = V(20, 14, 0.4), cf = CF(x + 18, 7, -44.6), color = Color3.fromRGB(110, 110, 115), mat = M.DiamondPlate, parent = wh })
		local lamp = P({ name = "DockLight", size = V(2, 1, 1), cf = CF(x + 18, 16, -44.4), color = Color3.fromRGB(255, 230, 180), collide = false, parent = wh })
		glowAtNight(lamp, Color3.fromRGB(255, 230, 180))
		pointLight(lamp, 24, 1.4, Color3.fromRGB(255, 220, 170))
	end
	lot(540, 660, -150, -40)
	for i = 0, 2 do
		truck(V(565 + i * 35, 0.3, -100), V(0, 0, 1), ({ Color3.fromRGB(200, 50, 40), Color3.fromRGB(40, 90, 200), Color3.fromRGB(230, 170, 30) })[i + 1])
	end
	shop({ name = "Truck Depot", center = V(615, 0, -170), size = V(40, 12, 20), color = Color3.fromRGB(90, 100, 110), material = M.Concrete, face = "S", signText = "TRUCK DEPOT", signColor = Color3.fromRGB(255, 160, 60), category = "Landmark" })
	local garage = shop({ name = "Rusty's Garage", center = V(735, 0, -70), size = V(50, 18, 40), color = Color3.fromRGB(110, 60, 45), material = M.CorrodedMetal, face = "S", signText = "RUSTY'S GARAGE", signColor = Color3.fromRGB(255, 120, 40), category = "Landmark" })
	P({ name = "Bay", size = V(16, 12, 0.4), cf = CF(752, 6, -49.6), color = C.dark, parent = garage })
	P({ name = "Lift", size = V(10, 0.6, 18), cf = CF(752, 3, -40), color = Color3.fromRGB(200, 60, 40), mat = M.Metal, parent = garage })
	P({ name = "Toolbox", size = V(4, 4, 2), cf = CF(722, 2, -48), color = Color3.fromRGB(200, 40, 40), mat = M.Metal, parent = garage })

	-- factory with smokestacks, warehouse C, containers and cranes south of the road
	local factory = shop({ name = "Ironworks Factory", center = V(420, 0, 100), size = V(110, 30, 70), color = Color3.fromRGB(120, 100, 90), material = M.Brick, face = "N", signText = "IRONWORKS", signColor = Color3.fromRGB(255, 140, 40), category = "Landmark", floorHeight = 30 })
	for i = 0, 3 do
		local x = 375 + i * 27
		ramp("Sawtooth", V(x - 13, 30, 100), V(x + 13, 38, 100), 70, Color3.fromRGB(100, 100, 108), M.CorrodedMetal, 1, factory)
	end
	for _, x in { 380, 410 } do
		cylinder("Smokestack", V(x, 0, 150), 72, 9, Color3.fromRGB(150, 70, 60), M.Brick, factory)
		cylinder("StackBand", V(x, 58, 150), 4, 9.4, C.white, M.SmoothPlastic, factory)
		local smoke = Instance.new("Smoke")
		smoke.Color = Color3.fromRGB(170, 170, 175)
		smoke.Opacity = 0.35
		smoke.RiseVelocity = 8
		smoke.Size = 6
		local top = P({ name = "StackTop", size = V(4, 1, 4), cf = CF(x, 72.5, 150), transp = 1, collide = false, parent = factory })
		smoke.Parent = top
		P({ name = "AirLight", size = V(1.2, 1.2, 1.2), cf = CF(x, 73, 150), color = Color3.fromRGB(255, 40, 40), mat = M.Neon, shape = Enum.PartType.Ball, collide = false, parent = factory })
	end
	shop({ name = "Warehouse C", center = V(560, 0, 90), size = V(70, 22, 60), color = Color3.fromRGB(140, 150, 155), material = M.CorrodedMetal, face = "N", signText = "WAREHOUSE C", signColor = Color3.fromRGB(255, 200, 80), floorHeight = 22 })
	local yard = model("ContainerYard")
	local rng = Random.new(42)
	local palette = { Color3.fromRGB(190, 60, 40), Color3.fromRGB(40, 100, 170), Color3.fromRGB(40, 140, 90), Color3.fromRGB(220, 160, 40), Color3.fromRGB(120, 120, 130), Color3.fromRGB(150, 60, 120) }
	for i = 0, 13 do
		for _, z in { 90, 150 } do
			local stack = rng:NextInteger(1, 3)
			for s = 0, stack - 1 do
				container(V(650 + i * 10, s * 8.6, z), palette[rng:NextInteger(1, #palette)], yard)
			end
		end
	end
	-- gantry crane over the yard
	local crane = Color3.fromRGB(240, 190, 30)
	for _, x in { 640, 800 } do
		for _, z in { 62, 178 } do
			P({ name = "CraneLeg", size = V(2, 38, 2), cf = CF(x, 19, z), color = crane, mat = M.Metal, parent = yard })
		end
		P({ name = "CraneRail", size = V(2.5, 3, 120), cf = CF(x, 39, 120), color = crane, mat = M.Metal, parent = yard })
	end
	P({ name = "CraneBridge", size = V(164, 4, 4), cf = CF(720, 42, 120), color = crane, mat = M.Metal, parent = yard })
	P({ name = "CraneTrolley", size = V(8, 4, 8), cf = CF(705, 38.5, 120), color = Color3.fromRGB(60, 60, 66), mat = M.Metal, parent = yard })
	P({ name = "CraneCable", size = V(0.4, 6, 0.4), cf = CF(705, 33.5, 120), color = C.dark, collide = false, parent = yard })
	P({ name = "Spreader", size = V(9, 1, 40), cf = CF(705, 30, 120), color = crane, mat = M.Metal, parent = yard })
	-- tower crane by the factory
	P({ name = "Mast", size = V(3, 80, 3), cf = CF(510, 40, 180), color = crane, mat = M.Metal, parent = yard })
	P({ name = "Jib", size = V(90, 3, 3), cf = CF(545, 81.5, 180), color = crane, mat = M.Metal, parent = yard })
	P({ name = "CounterJib", size = V(24, 3, 3), cf = CF(490, 81.5, 180), color = crane, mat = M.Metal, parent = yard })
	P({ name = "Counterweight", size = V(6, 5, 5), cf = CF(482, 78, 180), color = Color3.fromRGB(110, 110, 115), mat = M.Concrete, parent = yard })
	P({ name = "Cab", size = V(4, 4, 4), cf = CF(513, 77, 180), color = Color3.fromRGB(230, 230, 235), mat = M.Metal, parent = yard })
	mapPoint("Shipping Yard", "Landmark", V(720, 0, 40))

	-- race track in the north half, paddock by the service road
	raceTrack(V(640, 0, -500), current)
	lot(300, 400, -530, -430)
	shop({ name = "Race Control", center = V(355, 0, -565), size = V(50, 14, 30), color = Color3.fromRGB(230, 230, 235), material = M.Concrete, face = "S", signText = "RACE CONTROL", signColor = Color3.fromRGB(255, 60, 60) })
	mapPoint("City Speedway", "Social", V(360, 0, -470))

	-- the underground: a rusty gate, a ramp, a hidden room and the old tunnel west
	downRamp(830, 850, -120, -200, UNDER_FLOOR, Color3.fromRGB(110, 80, 70))
	for _, x in { 829, 851 } do
		P({ name = "GatePost", size = V(1.5, 12, 1.5), cf = CF(x, 6, -119), color = Color3.fromRGB(120, 70, 50), mat = M.CorrodedMetal })
		P({ name = "Railing", size = V(1, 3, 80), cf = CF(x, 1.5, -160), color = Color3.fromRGB(120, 70, 50), mat = M.CorrodedMetal })
	end
	signBoard("GateSign", V(840, 12, -118.6), V(23, 2.5, 0.5), V(0, 0, 1), "NO ENTRY · SERVICE TUNNEL", Color3.fromRGB(255, 200, 60))
	undergroundRoom(800, 880, -280, -200, UNDER_FLOOR, -4, Color3.fromRGB(95, 80, 75), { S = { 833, 847, UNDER_FLOOR + 12 }, W = { TUNNEL_Z - 6, TUNNEL_Z + 6, UNDER_FLOOR + 12 } })
	local den = model("UndergroundDen")
	for i, pos in { V(812, 0, -270), V(818, 0, -268), V(870, 0, -270), V(866, 0, -262) } do
		P({ name = "Crate", size = V(5, 5, 5), cf = CF(pos.X, UNDER_FLOOR + 2.5 + (if i == 2 then 5 else 0), pos.Z), color = Color3.fromRGB(140, 100, 60), mat = M.WoodPlanks, parent = den })
	end
	local couch = seat(V(840, UNDER_FLOOR + 1.6, -272), V(0, 0, 1), Color3.fromRGB(120, 40, 40), den)
	couch.Size = V(10, 1.2, 4)
	P({ name = "CouchBack", size = V(10, 3, 1), cf = CF(840, UNDER_FLOOR + 2.5, -274.5), color = Color3.fromRGB(110, 35, 35), mat = M.Fabric, parent = den })
	signBoard("DenSign", V(840, UNDER_FLOOR + 9, -279.4), V(24, 4, 0.4), V(0, 0, 1), "THE UNDERGROUND", Color3.fromRGB(80, 255, 160), nil, den)
	for _, pos in { V(820, -6, -240), V(860, -6, -240) } do
		local bulb = P({ name = "Bulb", size = V(1, 1, 1), cf = CF(pos), color = Color3.fromRGB(120, 255, 180), mat = M.Neon, shape = Enum.PartType.Ball, collide = false, parent = den })
		pointLight(bulb, 40, 1.2, Color3.fromRGB(140, 255, 190), true)
	end
	secretArea("IndustrialUnderground", "The Underground", V(840, UNDER_FLOOR + 8, -240), V(80, 16, 80))
end

---------------------------------------------------------------------------
-- Beach (section 8)
---------------------------------------------------------------------------
local function palm(pos: Vector3, rng: Random, parent: Instance)
	local h = 17 + rng:NextNumber() * 7
	local lean = rng:NextNumber(-0.12, 0.12)
	local trunkCF = CF(pos) * CFrame.Angles(lean, 0, lean * 0.6) * CF(0, h / 2, 0)
	P({ name = "Trunk", size = V(h, 1.5, 1.5), cf = trunkCF * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(140, 105, 70), mat = M.Wood, shape = Enum.PartType.Cylinder, parent = parent })
	local top = (trunkCF * CF(0, h / 2, 0)).Position
	local spin = rng:NextNumber() * math.pi
	for k = 0, 4 do
		P({ name = "Frond", size = V(11, 0.3, 2.6), cf = CF(top) * CFrame.Angles(0, spin + k * math.pi * 2 / 5, 0) * CF(5, -1, 0) * CFrame.Angles(0, 0, -0.35), color = Color3.fromRGB(60, 150 + rng:NextInteger(0, 30), 60), mat = M.Grass, collide = false, parent = parent })
	end
end

local function buildBeach()
	-- sand, a sloping shore, the sea floor and the ocean surface
	ground(-760, 900, 230, 520, C.sand, M.Sand, Color3.fromRGB(230, 210, 150))
	ramp("Shore", V(70, 0.05, 520), V(70, -8, 562), 1660, Color3.fromRGB(205, 185, 135), M.Sand, 2)
	P({ name = "SeaFloor", size = V(1660, 2, 440), cf = CF(70, -9, 780), color = Color3.fromRGB(180, 160, 115), mat = M.Sand })
	local ocean = P({ name = "Ocean", size = V(2040, 7, 680), cf = CF(70, -4.5, 860), color = Color3.fromRGB(40, 120, 175), mat = M.Glass, transp = 0.3, collide = false, map = Color3.fromRGB(50, 120, 190), layer = 1 })
	ocean.CastShadow = false
	-- the cross road comes down to a beach lot
	road("z", 230, 330, 0, { lampEvery = 50 })
	lot(-60, 60, 330, 372)
	-- boardwalk
	P({ name = "Boardwalk", size = V(1060, 0.6, 18), cf = CF(30, 0.3, 389), color = Color3.fromRGB(165, 125, 85), mat = M.WoodPlanks, map = Color3.fromRGB(160, 120, 80), layer = 2 })
	for x = -440, 500, 120 do
		lantern(V(x, 0.6, 381), Color3.fromRGB(255, 200, 140), 9)
	end
	for _, x in { -320, -240, 60, 200, 280, 360, 440 } do
		H.bench(CF(x, 0.6, 384) * CFrame.Angles(0, math.pi, 0), current)
	end

	-- pier
	local pier = model("CityPier")
	P({ name = "PierDeck", size = V(14, 0.8, 242), cf = CF(150, 0.8, 519), color = Color3.fromRGB(150, 115, 80), mat = M.WoodPlanks, parent = pier, map = Color3.fromRGB(150, 115, 80), layer = 3 })
	P({ name = "PierEnd", size = V(40, 0.8, 30), cf = CF(150, 0.8, 653), color = Color3.fromRGB(150, 115, 80), mat = M.WoodPlanks, parent = pier, map = Color3.fromRGB(150, 115, 80), layer = 3 })
	for z = 430, 630, 40 do
		for _, x in { 143.5, 156.5 } do
			cylinder("Piling", V(x, -9, z), 9.4, 1.4, Color3.fromRGB(100, 75, 55), M.Wood, pier)
		end
	end
	for _, x in { 142.8, 157.2 } do
		P({ name = "Railing", size = V(0.4, 3, 240), cf = CF(x, 2.7, 520), color = Color3.fromRGB(230, 230, 230), parent = pier })
	end
	P({ name = "Railing", size = V(40, 3, 0.4), cf = CF(150, 2.7, 667.8), color = Color3.fromRGB(230, 230, 230), parent = pier })
	for _, x in { -1, 1 } do
		P({ name = "Railing", size = V(0.4, 3, 30), cf = CF(150 + x * 19.8, 2.7, 653), color = Color3.fromRGB(230, 230, 230), parent = pier })
		H.bench(CF(150 + x * 12, 1.2, 662), pier)
	end
	lantern(V(150, 1.2, 645), Color3.fromRGB(255, 210, 150), 9)
	signBoard("PierSign", V(150, 10, 400), V(16, 3, 0.5), V(0, 0, -1), "CITY PIER", Color3.fromRGB(80, 200, 255), nil, pier)
	for _, x in { 142.5, 157.5 } do
		P({ name = "SignPost", size = V(0.6, 10, 0.6), cf = CF(x, 5, 400), color = C.wood, mat = M.Wood, parent = pier })
	end
	mapPoint("City Pier", "Social", V(150, 0, 404))

	-- ferris wheel
	buildFerrisWheel(V(-150, 45, 470))
	mapPoint("Ferris Wheel", "Social", V(-150, 0, 456))

	-- beach court
	local court = H.buildCourt("BeachCourt", V(300, 0, 300), Color3.fromRGB(205, 185, 140), Color3.fromRGB(40, 150, 190))
	court.Parent = current

	-- skate park
	local skate = model("SkatePark")
	local sc = V(-330, 0, 300)
	local concrete = Color3.fromRGB(175, 175, 178)
	P({ name = "SkatePad", size = V(90, 0.3, 60), cf = CF(sc + V(0, 0.15, 0)), color = concrete, mat = M.Concrete, parent = skate, map = Color3.fromRGB(170, 170, 175), layer = 2 })
	for _, sx in { -1, 1 } do
		ramp("QuarterPipe", sc + V(sx * 28, 0.3, 0), sc + V(sx * 44, 8, 0), 50, concrete, M.Concrete, 1, skate)
		P({ name = "Deck", size = V(2, 8, 50), cf = CF(sc + V(sx * 45, 4, 0)), color = concrete, mat = M.Concrete, parent = skate })
		ramp("Kicker", sc + V(sx * 4, 0.3, -18), sc + V(sx * 14, 3, -18), 10, Color3.fromRGB(70, 140, 220), M.Metal, 1, skate)
	end
	P({ name = "FunBox", size = V(8, 3, 14), cf = CF(sc + V(0, 1.5, -18)), color = concrete, mat = M.Concrete, parent = skate })
	P({ name = "Rail", size = V(30, 0.4, 0.4), cf = CF(sc + V(0, 2.2, 14)), color = Color3.fromRGB(220, 220, 225), mat = M.Metal, parent = skate })
	for _, x in { -14, 14 } do
		P({ name = "RailLeg", size = V(0.4, 2, 0.4), cf = CF(sc + V(x, 1, 14)), color = Color3.fromRGB(220, 220, 225), mat = M.Metal, parent = skate })
	end
	signBoard("SkateSign", sc + V(0, 6, 30.5), V(20, 3, 0.4), V(0, 0, 1), "SKATE PARK", Color3.fromRGB(255, 90, 160), nil, skate)
	mapPoint("Skate Park", "Fitness", sc + V(0, 0, 34))

	-- running track (oval)
	local track = model("RunningTrack")
	local tc, half, R, W = V(560, 0, 320), 60, 36, 8
	local tartan = Color3.fromRGB(190, 70, 55)
	P({ name = "TrackInfield", size = V(half * 2, 0.15, (R - W / 2) * 2), cf = CF(tc + V(0, 0.08, 0)), color = Color3.fromRGB(85, 150, 75), mat = M.Grass, parent = track })
	for _, sz in { -1, 1 } do
		P({ name = "TrackLane", size = V(half * 2, 0.25, W), cf = CF(tc + V(0, 0.12, sz * R)), color = tartan, mat = M.Fabric, parent = track, map = tartan, layer = 3 })
	end
	for _, e in { { half, -90, 90 }, { -half, 90, 270 } } do
		local c = tc + V(e[1], 0, 0)
		P({ name = "TrackInfield", size = V(0.15, (R - W / 2) * 2, (R - W / 2) * 2), cf = CF(c + V(0, 0.08, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = Color3.fromRGB(85, 150, 75), mat = M.Grass, shape = Enum.PartType.Cylinder, parent = track })
		for i = 0, 7 do
			local a = math.rad(e[2] + (i + 0.5) * (e[3] - e[2]) / 8)
			local pos = c + V(math.cos(a), 0, math.sin(a)) * R + V(0, 0.12, 0)
			P({ name = "TrackLane", size = V(W, 0.25, math.rad(180 / 8) * (R + W / 2) + 0.6), cf = CFrame.lookAt(pos, pos + V(-math.sin(a), 0, math.cos(a))), color = tartan, mat = M.Fabric, parent = track, map = tartan, layer = 3 })
		end
	end
	mapPoint("Running Track", "Fitness", tc + V(0, 0, R + 8))

	-- Muscle Beach outdoor gym props
	local gym = model("MuscleBeach")
	local gc = V(420, 0, 450)
	P({ name = "GymMat", size = V(34, 0.3, 22), cf = CF(gc + V(0, 0.15, 0)), color = Color3.fromRGB(50, 50, 55), mat = M.Rubber, parent = gym })
	for _, x in { -12, -4 } do
		P({ name = "PullUpPost", size = V(0.6, 10, 0.6), cf = CF(gc + V(x, 5, -6)), color = C.metal, mat = M.Metal, parent = gym })
	end
	P({ name = "PullUpBar", size = V(8.6, 0.4, 0.4), cf = CF(gc + V(-8, 9.8, -6)), color = Color3.fromRGB(200, 200, 205), mat = M.Metal, parent = gym })
	P({ name = "Bench", size = V(2, 1.6, 6), cf = CF(gc + V(6, 0.9, -4)), color = Color3.fromRGB(40, 40, 46), mat = M.Fabric, parent = gym })
	P({ name = "Barbell", size = V(9, 0.3, 0.3), cf = CF(gc + V(6, 3.6, -6)), color = Color3.fromRGB(200, 200, 205), mat = M.Metal, parent = gym })
	for _, x in { -4.2, 4.2 } do
		P({ name = "Plate", size = V(0.6, 2.4, 2.4), cf = CF(gc + V(6 + x, 3.6, -6)), color = C.dark, mat = M.Rubber, shape = Enum.PartType.Cylinder, parent = gym })
	end
	P({ name = "DumbbellRack", size = V(10, 2.5, 2), cf = CF(gc + V(6, 1.25, 7)), color = C.metal, mat = M.Metal, parent = gym })
	for _, x in { -12, -9 } do
		P({ name = "DipBar", size = V(0.4, 0.4, 6), cf = CF(gc + V(x, 4, 6)), color = Color3.fromRGB(200, 200, 205), mat = M.Metal, parent = gym })
		P({ name = "DipPost", size = V(0.5, 4, 0.5), cf = CF(gc + V(x, 2, 6)), color = C.metal, mat = M.Metal, parent = gym })
	end
	signBoard("GymSign", gc + V(0, 4, -11.5), V(16, 2.5, 0.4), V(0, 0, -1), "MUSCLE BEACH", Color3.fromRGB(255, 200, 40), nil, gym)
	mapPoint("Muscle Beach", "Fitness", gc + V(0, 0, -14))

	-- Tiki Shack: a beach bar with stools to sit on
	local tiki = model("TikiShack")
	local tk = V(40, 0, 440)
	P({ name = "Counter", size = V(20, 4, 3), cf = CF(tk + V(0, 2, -5)), color = Color3.fromRGB(140, 95, 55), mat = M.Wood, parent = tiki })
	for _, x in { -9, 9 } do
		for _, z in { -7, 5 } do
			cylinder("Post", tk + V(x, 0, z), 10, 0.8, Color3.fromRGB(120, 85, 50), M.Wood, tiki)
		end
	end
	for _, s in { -1, 1 } do
		P({ name = "Thatch", size = V(24, 0.6, 9.5), cf = CF(tk + V(0, 11.5, -1 + s * 4)) * CFrame.Angles(s * 0.35, 0, 0), color = Color3.fromRGB(205, 175, 95), mat = M.Grass, parent = tiki })
	end
	for x = -6, 6, 4 do
		seat(tk + V(x, 2.2, -9), V(0, 0, 1), Color3.fromRGB(200, 60, 50), tiki)
	end
	local tikiSign = signBoard("TikiSign", tk + V(0, 9, -7.4), V(12, 2, 0.4), V(0, 0, -1), "TIKI SHACK", Color3.fromRGB(255, 220, 90), nil, tiki)
	pointLight(tikiSign, 26, 1.5, Color3.fromRGB(255, 170, 90))
	mapPoint("Tiki Shack", "Food", tk + V(0, 0, -12))

	-- lifeguard tower
	local guard = model("LifeguardTower")
	local lg = V(250, 0, 480)
	for _, x in { -3, 3 } do
		for _, z in { -3, 3 } do
			P({ name = "Leg", size = V(0.6, 8, 0.6), cf = CF(lg + V(x, 4, z)), color = C.white, parent = guard })
		end
	end
	P({ name = "Platform", size = V(8, 0.6, 8), cf = CF(lg + V(0, 8.3, 0)), color = C.white, parent = guard })
	P({ name = "Cabin", size = V(6, 5, 6), cf = CF(lg + V(0, 11, 0)), color = Color3.fromRGB(220, 60, 50), parent = guard })
	P({ name = "Roof", size = V(8, 0.5, 8), cf = CF(lg + V(0, 13.8, 0)), color = C.white, parent = guard })
	ramp("Ladder", lg + V(0, 0.1, -9), lg + V(0, 8.6, -4), 2.5, Color3.fromRGB(200, 200, 200), M.WoodPlanks, 0.5, guard)

	-- umbrellas, towels, a bonfire circle and palms
	local social = model("BeachSocial")
	local rng = Random.new(8)
	local umbrellaColors = { Color3.fromRGB(240, 80, 80), Color3.fromRGB(60, 160, 240), Color3.fromRGB(250, 200, 50), Color3.fromRGB(90, 200, 120) }
	for i = 0, 7 do
		local p = V(-60 + i * 55 + rng:NextNumber(-10, 10), 0, 470 + rng:NextNumber(-25, 25))
		P({ name = "UmbrellaPole", size = V(0.3, 9, 0.3), cf = CF(p + V(0, 4.5, 0)), color = C.white, parent = social })
		P({ name = "Umbrella", size = V(0.5, 10, 10), cf = CF(p + V(0, 9, 0)) * CFrame.Angles(0, 0, math.pi / 2), color = umbrellaColors[i % #umbrellaColors + 1], shape = Enum.PartType.Cylinder, parent = social })
		P({ name = "Towel", size = V(3.4, 0.1, 6.5), cf = CF(p + V(3, 0.1, 2)), color = umbrellaColors[(i + 1) % #umbrellaColors + 1], mat = M.Fabric, collide = false, parent = social })
	end
	local fire = V(-30, 0, 480)
	local pit = cylinder("FirePit", fire, 1, 6, Color3.fromRGB(90, 85, 80), M.Slate, social)
	local flame = Instance.new("Fire")
	flame.Size = 6
	flame.Heat = 8
	flame.Parent = pit
	pointLight(pit, 30, 2, Color3.fromRGB(255, 150, 70), true)
	for i = 0, 3 do
		local a = i / 4 * math.pi * 2 + math.pi / 4
		local p = fire + V(math.cos(a) * 9, 0, math.sin(a) * 9)
		local log = seat(p + V(0, 1, 0), (fire - p) * V(1, 0, 1), Color3.fromRGB(120, 85, 55), social)
		log.Size = V(6, 1.6, 2)
		log.Material = M.Wood
	end
	mapPoint("Beach Bonfire", "Social", fire + V(0, 0, -12))
	local palms = model("Palms")
	for _, p in { V(-260, 0, 410), V(-220, 0, 440), V(-90, 0, 415), V(-60, 0, 505), V(0, 0, 420), V(90, 0, 500), V(110, 0, 415), V(200, 0, 430), V(330, 0, 410), V(360, 0, 500), V(480, 0, 420), V(520, 0, 500), V(-380, 0, 420), V(-430, 0, 480), V(-40, 0, 250), V(40, 0, 250), V(-120, 0, 345), V(120, 0, 345) } do
		palm(p, rng, palms)
	end
end

---------------------------------------------------------------------------
-- Luxury Hills (section 9)
---------------------------------------------------------------------------
local HILL_Y = 14.05

local function mansion(name: string, c: Vector3, face: number, color: Color3, accent: Color3)
	local m = model(name)
	local f = face
	P({ name = "Body", size = V(50, 16, 32), cf = CF(c + V(0, 8, 0)), color = color, mat = M.SmoothPlastic, parent = m, map = Color3.fromRGB(230, 225, 215), layer = 3 })
	P({ name = "Upper", size = V(34, 11, 24), cf = CF(c + V(-5, 21.5, -f * 3)), color = color, mat = M.SmoothPlastic, parent = m })
	P({ name = "Roof", size = V(53, 1, 35), cf = CF(c + V(0, 16.5, 0)), color = accent, mat = M.Slate, parent = m })
	P({ name = "Roof", size = V(37, 1, 27), cf = CF(c + V(-5, 27.5, -f * 3)), color = accent, mat = M.Slate, parent = m })
	P({ name = "Glass", size = V(40, 9, 0.4), cf = CF(c + V(0, 7, f * 16.1)), color = Color3.fromRGB(120, 180, 220), mat = M.Glass, transp = 0.2, parent = m })
	local upperGlass = P({ name = "Glass", size = V(28, 7, 0.4), cf = CF(c + V(-5, 21, f * 9.1)), color = Color3.fromRGB(120, 180, 220), mat = M.Glass, transp = 0.2, parent = m })
	glowAtNight(upperGlass, C.windowWarm)
	P({ name = "Door", size = V(6, 10, 0.4), cf = CF(c + V(0, 5, f * 16.4)), color = Color3.fromRGB(60, 40, 30), mat = M.Wood, parent = m })
	for _, x in { -7, 7 } do
		cylinder("Column", c + V(x, 0, f * 22), 13, 1.8, C.white, M.Marble, m)
	end
	P({ name = "Portico", size = V(18, 1, 9), cf = CF(c + V(0, 13.5, f * 20.5)), color = C.white, mat = M.Marble, parent = m })
	local porch = P({ name = "PorchLight", size = V(1, 1, 1), cf = CF(c + V(0, 12.6, f * 20.5)), color = Color3.fromRGB(255, 230, 180), shape = Enum.PartType.Ball, collide = false, parent = m })
	glowAtNight(porch, Color3.fromRGB(255, 225, 170))
	pointLight(porch, 26, 1.6, Color3.fromRGB(255, 215, 160))
	-- back garden with a pool
	P({ name = "PoolDeck", size = V(34, 0.2, 18), cf = CF(c + V(0, 0.1, -f * 27)), color = Color3.fromRGB(225, 220, 205), mat = M.Slate, parent = m })
	P({ name = "Pool", size = V(26, 0.3, 11), cf = CF(c + V(0, 0.25, -f * 27)), color = Color3.fromRGB(60, 190, 230), mat = M.Glass, transp = 0.15, collide = false, parent = m })
	for _, x in { -27, 27 } do
		P({ name = "Hedge", size = V(2.5, 4, 40), cf = CF(c + V(x, 2, -f * 12)), color = Color3.fromRGB(50, 110, 50), mat = M.LeafyGrass, parent = m })
	end
end

local function supercar(pos: Vector3, yaw: number, color: Color3, parent: Instance)
	local cf = CF(pos) * CFrame.Angles(0, yaw, 0)
	P({ name = "CarBody", size = V(6, 1.6, 13), cf = cf * CF(0, 1.6, 0), color = color, mat = M.Metal, parent = parent })
	P({ name = "CarCabin", size = V(4.6, 1.4, 5), cf = cf * CF(0, 3, 0.6), color = Color3.fromRGB(30, 30, 36), mat = M.Glass, transp = 0.1, parent = parent })
	for _, z in { -4.2, 4.2 } do
		P({ name = "Wheels", size = V(6.4, 2.2, 2.2), cf = cf * CF(0, 1.1, z), color = C.dark, mat = M.Rubber, shape = Enum.PartType.Cylinder, parent = parent })
	end
end

local function buildPrivateCourt(c: Vector3)
	local m = model("PrivateClub")
	local court = H.buildCourt("LuxuryPrivateCourt", c, Color3.fromRGB(30, 30, 36), Color3.fromRGB(170, 130, 60))
	court.Parent = current
	local x0, x1, z0, z1 = c.X - 38, c.X + 38, c.Z - 55, c.Z + 55
	local wallH = 16
	local wallColor = Color3.fromRGB(45, 95, 55)
	local function wall(ax: number, bx: number, az: number, bz: number)
		P({ name = "ClubWall", size = V(math.max(1.5, bx - ax), wallH, math.max(1.5, bz - az)), cf = CF((ax + bx) / 2, c.Y + wallH / 2, (az + bz) / 2), color = wallColor, mat = M.LeafyGrass, parent = m, map = Color3.fromRGB(60, 110, 70), layer = 3 })
	end
	wall(x0, x0 + 1.5, z0, z1)
	wall(x1 - 1.5, x1, z0, z1)
	wall(x0, x1, z1 - 1.5, z1)
	wall(x0, c.X - 5, z0, z0 + 1.5)
	wall(c.X + 5, x1, z0, z0 + 1.5)
	-- gold trim along the top
	P({ name = "Trim", size = V(x1 - x0, 0.6, 1.8), cf = CF(c.X, c.Y + wallH + 0.3, z0 + 0.75), color = Color3.fromRGB(210, 170, 80), mat = M.Metal, parent = m })
	-- the gate: visible bars + an invisible barrier; the prompt checks membership server-side
	local gatePos = V(c.X, c.Y + wallH / 2, z0 + 0.75)
	local barrier = P({ name = "GateBarrier", size = V(10, wallH, 1.5), cf = CF(gatePos), transp = 1, parent = m })
	for i = -2, 2 do
		P({ name = "GateBar", size = V(0.4, wallH - 2, 0.4), cf = CF(gatePos + V(i * 2, -1, 0)), color = Color3.fromRGB(210, 170, 80), mat = M.Metal, collide = false, parent = m })
	end
	signBoard("ClubSign", V(c.X, c.Y + wallH + 3, z0 - 0.2), V(22, 3, 0.4), V(0, 0, -1), "HILLS PRIVATE CLUB · MEMBERS ONLY", Color3.fromRGB(230, 190, 90), nil, m)
	local enter = addPrompt(barrier, "EnterClub", "Enter", "Private Court", 10)
	-- members arrive behind the south baseline, where the court fence has its opening
	local insideSpot = V(c.X, c.Y, z1 - 9)
	local outsideSpot = V(c.X, c.Y, z0 - 8)
	local exitPad = P({ name = "ClubExit", size = V(6, 0.3, 4), cf = CF(c.X, c.Y + 0.15, z1 - 5), color = Color3.fromRGB(210, 170, 80), mat = M.Metal, parent = m })
	local leave = addPrompt(exitPad, "LeaveClub", "Leave", "Private Court", 9)
	P({ name = "Path", size = V(10, 0.2, 31), cf = CF(c.X, c.Y + 0.1, z0 - 15.5), color = Color3.fromRGB(220, 210, 190), mat = M.Slate, parent = m })

	enter.Triggered:Connect(function(player)
		if not Net.allow(player, "ClubGate", 1) or Net.distance(player, barrier.Position) > 16 then
			return
		end
		local ok, reason = canMove(player)
		if not ok then
			if reason then
				Net.notify(player, "PRIVATE COURT", reason)
			end
			return
		end
		local rep = player:GetAttribute("Reputation")
		local level = player:GetAttribute("Level")
		rep = if type(rep) == "number" then rep else 0
		level = if type(level) == "number" then level else 1
		if rep >= DC.PRIVATE_COURT_REPUTATION or level >= DC.PRIVATE_COURT_LEVEL then
			Places.teleport(player, CFrame.lookAt(insideSpot, insideSpot + V(0, 0, -1)))
			Net.notify(player, "WELCOME, MEMBER", "The Hills Private Club court is yours to play.")
		else
			Net.notify(
				player,
				"MEMBERS ONLY",
				string.format("Members need Reputation %d+ or Level %d+. You have Reputation %d and Level %d.", DC.PRIVATE_COURT_REPUTATION, DC.PRIVATE_COURT_LEVEL, rep, level)
			)
		end
	end)
	leave.Triggered:Connect(function(player)
		if not Net.allow(player, "ClubGate", 1) or Net.distance(player, exitPad.Position) > 14 then
			return
		end
		Places.teleport(player, CFrame.lookAt(outsideSpot, outsideSpot + V(0, 0, -1)))
	end)
end

local function buildLuxury()
	ground(-760, -300, -730, -230, Color3.fromRGB(95, 155, 80), M.Grass, Color3.fromRGB(90, 150, 80))
	-- the hill
	local hx0, hx1, hz0, hz1 = -740, -420, -710, -280
	P({ name = "Hill", size = V(hx1 - hx0, HILL_Y - 1, hz1 - hz0), cf = CF((hx0 + hx1) / 2, (HILL_Y - 1) / 2 - 0.5, (hz0 + hz1) / 2), color = Color3.fromRGB(130, 115, 95), mat = M.Rock })
	P({ name = "HillTop", size = V(hx1 - hx0, 1.5, hz1 - hz0), cf = CF((hx0 + hx1) / 2, HILL_Y - 0.75, (hz0 + hz1) / 2), color = Color3.fromRGB(100, 165, 85), mat = M.Grass, map = Color3.fromRGB(110, 170, 95), layer = 2 })
	-- Luxury Drive: from Downtown's avenue, up a ramp, across the hill
	road("x", -360, -300, -480, { lamps = false })
	local hillRamp = ramp("RampRoad", V(-360, 0.2, -480), V(-420, HILL_Y + 0.2, -480), ROAD_W, C.asphalt, M.Asphalt, 1)
	hillRamp:SetAttribute("MapColor", C.mapRoad)
	hillRamp:SetAttribute("MapLayer", 2)
	for _, side in { -1, 1 } do
		ramp("GuardRail", V(-360, 2.4, -480 + side * 16.4), V(-420, HILL_Y + 2.4, -480 + side * 16.4), 0.6, Color3.fromRGB(200, 200, 205), M.Metal, 2)
	end
	road("x", -730, -420, -480, { y = HILL_Y, lampEvery = 75 })

	-- mansions
	mansion("Mansion Aurelia", V(-490, HILL_Y, -590), 1, Color3.fromRGB(245, 242, 235), Color3.fromRGB(60, 60, 70))
	mansion("Mansion Solace", V(-640, HILL_Y, -590), 1, Color3.fromRGB(230, 220, 200), Color3.fromRGB(110, 70, 50))
	mansion("Mansion Vireo", V(-490, HILL_Y, -380), -1, Color3.fromRGB(235, 235, 240), Color3.fromRGB(40, 50, 70))
	for _, d in { { -490, -574, -504 }, { -640, -574, -504 }, { -490, -456, -396 } } do
		P({ name = "Driveway", size = V(10, 0.2, math.abs(d[3] - d[2])), cf = CF(d[1], HILL_Y + 0.1, (d[2] + d[3]) / 2), color = Color3.fromRGB(215, 205, 185), mat = M.Slate })
	end
	local rng = Random.new(11)
	for _, p in { V(-450, HILL_Y, -530), V(-560, HILL_Y, -530), V(-700, HILL_Y, -530), V(-560, HILL_Y, -430), V(-450, HILL_Y, -300), V(-720, HILL_Y, -300), V(-720, HILL_Y, -660), V(-560, HILL_Y, -680) } do
		H.tree(p + V(rng:NextNumber(-4, 4), 0, rng:NextNumber(-4, 4)), current)
	end
	mapPoint("Luxury Hills Estates", "Landmark", V(-560, HILL_Y, -500))

	-- private court (gated)
	buildPrivateCourt(V(-650, HILL_Y, -370))

	-- penthouse towers, the Sky Lounge on top of one, and the supercar showroom
	tower({ name = "Penthouse One", center = V(-360, 0, -620), w = 44, d = 44, h = 130, color = Color3.fromRGB(235, 235, 240), glass = Color3.fromRGB(150, 200, 230), trim = Color3.fromRGB(200, 165, 90), lit = 0.6, front = V(0, 0, 1), spire = 14 })
	local lounge = V(-360, 0, -330)
	local loungeY = 110
	tower({ name = "Penthouse Two", center = lounge, w = 40, d = 40, h = loungeY, color = Color3.fromRGB(30, 30, 36), glass = Color3.fromRGB(120, 160, 200), trim = Color3.fromRGB(200, 165, 90), lit = 0.6, front = V(0, 0, 1), flatRoof = true })
	local sky = model("SkyLounge")
	for _, side in { -1, 1 } do
		P({ name = "LoungeGlass", size = V(0.5, 4, 40), cf = CF(lounge + V(side * 19.75, loungeY + 2, 0)), color = Color3.fromRGB(190, 225, 255), mat = M.Glass, transp = 0.6, parent = sky })
		P({ name = "LoungeGlass", size = V(40, 4, 0.5), cf = CF(lounge + V(0, loungeY + 2, side * 19.75)), color = Color3.fromRGB(190, 225, 255), mat = M.Glass, transp = 0.6, parent = sky })
	end
	P({ name = "LoungeDeck", size = V(39, 0.3, 39), cf = CF(lounge + V(0, loungeY + 0.15, 0)), color = Color3.fromRGB(120, 85, 60), mat = M.WoodPlanks, parent = sky })
	for _, t in { V(-9, 0, -8), V(9, 0, -8), V(-9, 0, 6), V(9, 0, 6) } do
		local tp = lounge + V(0, loungeY + 0.3, 0) + t
		cylinder("TableLeg", tp, 3, 0.6, C.dark, M.Metal, sky)
		cylinder("TableTop", tp + V(0, 3, 0), 0.3, 5, C.white, M.Marble, sky)
		for _, dx in { -3.8, 3.8 } do
			seat(tp + V(dx, 1.6, 0), V(-dx, 0, 0), Color3.fromRGB(200, 170, 110), sky)
		end
	end
	P({ name = "Bar", size = V(18, 3.6, 3), cf = CF(lounge + V(0, loungeY + 2, -16)), color = Color3.fromRGB(30, 30, 34), mat = M.Marble, parent = sky })
	for _, z in { -12, 12 } do
		local string_ = P({ name = "StringLights", size = V(38, 0.3, 0.3), cf = CF(lounge + V(0, loungeY + 7, z)), color = Color3.fromRGB(255, 220, 150), mat = M.Neon, collide = false, parent = sky })
		pointLight(string_, 30, 1.4, Color3.fromRGB(255, 210, 150))
	end
	signBoard("LoungeSign", lounge + V(0, loungeY + 6, -19.6), V(16, 2.5, 0.4), V(0, 0, 1), "SKY LOUNGE", Color3.fromRGB(230, 190, 90), nil, sky)
	elevator("Sky Lounge", lounge + V(10, 0, 20.4), V(0, 0, 1), lounge + V(12, loungeY, 12), V(-1, 0, 0))
	mapPoint("Sky Lounge", "Food", lounge + V(10, 0, 26))

	-- Prestige Motors showroom
	local show = model("PrestigeMotors")
	local sc = V(-360, 0, -545)
	P({ name = "ShowroomFloor", size = V(60, 0.4, 40), cf = CF(sc + V(0, 0.2, 0)), color = Color3.fromRGB(235, 235, 240), mat = M.Marble, parent = show })
	P({ name = "Body", size = V(60, 18, 2), cf = CF(sc + V(0, 9, -19)), color = Color3.fromRGB(25, 25, 30), mat = M.SmoothPlastic, parent = show, map = C.mapBuilding, layer = 3 })
	for _, x in { -29, 29 } do
		P({ name = "SideWall", size = V(2, 18, 40), cf = CF(sc + V(x, 9, 0)), color = Color3.fromRGB(25, 25, 30), parent = show })
	end
	P({ name = "Roof", size = V(62, 1.2, 42), cf = CF(sc + V(0, 18.6, 0)), color = Color3.fromRGB(200, 165, 90), mat = M.Metal, parent = show })
	P({ name = "Glass", size = V(48, 15, 0.4), cf = CF(sc + V(-6, 7.5, 19.8)), color = Color3.fromRGB(170, 210, 240), mat = M.Glass, transp = 0.6, parent = show })
	signBoard("ShowroomSign", sc + V(0, 16, 20.6), V(30, 3, 0.4), V(0, 0, 1), "PRESTIGE MOTORS", Color3.fromRGB(230, 190, 90), nil, show)
	supercar(sc + V(-16, 0.4, 0), 0.5, Color3.fromRGB(220, 30, 30), show)
	supercar(sc + V(0, 0.4, -4), 0, Color3.fromRGB(250, 200, 40), show)
	supercar(sc + V(16, 0.4, 0), -0.5, Color3.fromRGB(30, 30, 34), show)
	local showLight = P({ name = "ShowLight", size = V(40, 0.3, 4), cf = CF(sc + V(0, 17.8, 0)), color = C.white, mat = M.Neon, collide = false, parent = show })
	pointLight(showLight, 40, 1.5, C.white)
	mapPoint("Prestige Motors", "Landmark", sc + V(0, 0, 26))
end

---------------------------------------------------------------------------
-- Old Town (section 10)
---------------------------------------------------------------------------
local OLD = {
	Color3.fromRGB(150, 70, 55),
	Color3.fromRGB(120, 85, 60),
	Color3.fromRGB(175, 120, 80),
	Color3.fromRGB(110, 55, 50),
	Color3.fromRGB(190, 160, 120),
	Color3.fromRGB(95, 70, 60),
}

local function oldBuilding(name: string, x: number, z: number, w: number, h: number, face: string, colorIndex: number, signText: string, signColor: Color3, category: string?)
	local m = shop({ name = name, center = V(x, 0, z), size = V(w, h, 30), color = OLD[colorIndex], material = M.Brick, face = face, signText = signText, signColor = signColor, category = category, floorHeight = 10 })
	-- a cornice along the roof line for the old-town look
	P({ name = "Cornice", size = V(w + 2, 1.4, 31.5), cf = CF(x, h + 1.6, z), color = Color3.fromRGB(215, 200, 175), mat = M.Concrete, parent = m })
	return m
end

local function buildOldTown()
	local hole = { -687, -673, -172, -110 }
	ground(-760, -300, -230, 230, Color3.fromRGB(140, 128, 112), M.Cobblestone, Color3.fromRGB(150, 130, 110), { hole })
	road("x", -760, -300, 0, { color = Color3.fromRGB(95, 88, 82), mat = M.Cobblestone, walkColor = Color3.fromRGB(150, 100, 80), walkMat = M.Brick, lampEvery = 70 })
	-- narrow side streets
	for _, x in { -450, -610 } do
		for _, seg in { { -230, -24 }, { 24, 230 } } do
			P({ name = "Street", size = V(14, 0.2, seg[2] - seg[1]), cf = CF(x, 0.1, (seg[1] + seg[2]) / 2), color = Color3.fromRGB(105, 95, 85), mat = M.Cobblestone, map = Color3.fromRGB(95, 85, 75), layer = 2 })
		end
	end

	-- north side of the main road (fronts face the road, +z)
	oldBuilding("Curio & Relic Antiques", -332, -47, 40, 20, "S", 1, "CURIO & RELIC ANTIQUES", Color3.fromRGB(240, 220, 160), "Landmark")
	oldBuilding("Rosie's Bakery", -420, -47, 30, 16, "S", 5, "ROSIE'S BAKERY", Color3.fromRGB(255, 180, 190))
	oldBuilding("Second Hand Rose", -485, -47, 38, 20, "S", 4, "SECOND HAND ROSE · VINTAGE", Color3.fromRGB(255, 160, 200), "Landmark")
	oldBuilding("Old Town Tailor", -535, -47, 30, 24, "S", 2, "TAILOR", Color3.fromRGB(230, 220, 200))
	oldBuilding("Hotel Bellmont", -580, -47, 36, 30, "S", 3, "HOTEL BELLMONT", Color3.fromRGB(255, 215, 120))
	oldBuilding("Printing House", -650, -47, 36, 20, "S", 6, "PRINTING HOUSE", Color3.fromRGB(230, 230, 230))
	oldBuilding("Old Post Office", -715, -47, 50, 22, "S", 1, "POST OFFICE · 1898", Color3.fromRGB(240, 220, 160))
	shop({ name = "Old Town Hall", center = V(-380, 0, -150), size = V(70, 28, 50), color = Color3.fromRGB(200, 185, 160), material = M.Concrete, face = "S", signText = "OLD TOWN HALL", signColor = Color3.fromRGB(80, 60, 40), category = "Landmark", floorHeight = 14 })

	-- south side (fronts face the road, -z)
	oldBuilding("Moretti's Pizzeria", -335, 47, 40, 16, "N", 4, "MORETTI'S PIZZERIA", Color3.fromRGB(120, 220, 120))
	oldBuilding("Blue Lantern Jazz Club", -410, 47, 40, 20, "N", 6, "BLUE LANTERN JAZZ", Color3.fromRGB(90, 160, 255), "Landmark")
	oldBuilding("Old Town Books", -490, 47, 30, 18, "N", 2, "OLD TOWN BOOKS", Color3.fromRGB(240, 220, 160))
	oldBuilding("Watchmaker", -570, 47, 30, 18, "N", 5, "WATCHMAKER", Color3.fromRGB(80, 60, 40))
	oldBuilding("Grand Theatre", -660, 47, 40, 22, "N", 1, "GRAND THEATRE", Color3.fromRGB(255, 215, 120), "Landmark")
	oldBuilding("Apothecary", -725, 47, 40, 18, "N", 3, "APOTHECARY", Color3.fromRGB(150, 230, 170))
	shop({ name = "Warehouse Lofts", center = V(-690, 0, 160), size = V(60, 24, 50), color = OLD[2], material = M.Brick, face = "N", signText = "WAREHOUSE LOFTS", signColor = Color3.fromRGB(230, 220, 200), floorHeight = 12 })

	-- the old court: cracked, faded, weeds
	local court = H.buildCourt("OldTownCourt", V(-530, 0, 130), Color3.fromRGB(115, 108, 98), Color3.fromRGB(150, 95, 70))
	court.Parent = current
	local cfloor = court:FindFirstChild("CourtFloor")
	if cfloor and cfloor:IsA("BasePart") then
		cfloor.Material = M.Slate
	end
	local paint = court:FindFirstChild("Paint")
	if paint and paint:IsA("BasePart") then
		paint.Transparency = 0.35
	end
	local crng = Random.new(5)
	for _ = 1, 7 do
		local p = V(-530 + crng:NextNumber(-18, 18), 0.5, 130 + crng:NextNumber(-34, 34))
		P({ name = "Crack", size = V(0.3, 0.04, crng:NextNumber(4, 12)), cf = CF(p) * CFrame.Angles(0, crng:NextNumber(0, math.pi), 0), color = Color3.fromRGB(45, 42, 40), collide = false, parent = court })
	end
	for _ = 1, 5 do
		local p = V(-530 + crng:NextNumber(-25, 25), 0.6, 130 + crng:NextNumber(-40, 40))
		P({ name = "Weeds", size = V(1.4, 0.6, 1.4), cf = CF(p), color = Color3.fromRGB(80, 130, 60), mat = M.Grass, collide = false, parent = court })
	end

	-- street lanterns
	for _, p in { V(-450, 0, -100), V(-450, 0, 110), V(-610, 0, -120), V(-610, 0, 120) } do
		lantern(p + V(9, 0, 0), Color3.fromRGB(255, 190, 110))
	end

	-- Clocktower Lofts and its secret rooftop, reached by climbing crates in the alley
	local clock = shop({ name = "Clocktower Lofts", center = V(-380, 0, 150), size = V(40, 30, 40), color = OLD[4], material = M.Brick, face = "N", signText = "CLOCKTOWER LOFTS", signColor = Color3.fromRGB(240, 220, 160), floorHeight = 10 })
	local clockFace = P({ name = "ClockFace", size = V(0.6, 9, 9), cf = CF(-380, 25, 129.6) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(245, 240, 225), shape = Enum.PartType.Cylinder, parent = clock })
	glowAtNight(clockFace, Color3.fromRGB(255, 240, 200))
	local climb = model("AlleyCrates")
	for i = 1, 7 do
		local top = 4 * i
		local z = 168 - (i - 1) * 5
		P({ name = "Crates", size = V(5, top, 5), cf = CF(-356.5, top / 2, z), color = if i % 2 == 0 then Color3.fromRGB(150, 110, 70) else Color3.fromRGB(130, 95, 60), mat = M.WoodPlanks, parent = climb })
	end
	local roof = model("SecretRooftop")
	H.bench(CF(-388, 31, 160) * CFrame.Angles(0, math.pi, 0), roof)
	local fairy = P({ name = "RooftopLights", size = V(30, 0.3, 0.3), cf = CF(-380, 36, 140), color = Color3.fromRGB(255, 220, 150), mat = M.Neon, collide = false, parent = roof })
	pointLight(fairy, 30, 1.2, Color3.fromRGB(255, 210, 150))
	for _, x in { -395, -365 } do
		P({ name = "LightPole", size = V(0.4, 5, 0.4), cf = CF(x, 33.5, 140), color = C.dark, mat = M.Metal, parent = roof })
	end
	signBoard("Plaque", V(-380, 32, 169.2), V(6, 1.6, 0.3), V(0, 0, -1), "YOU FOUND THE CLOCKTOWER ROOF", Color3.fromRGB(255, 220, 120), nil, roof)
	secretArea("OldTownRooftop", "Clocktower Rooftop", V(-380, 38, 150), V(40, 14, 40))

	-- The Forgotten Cellar: an abandoned building with a ramp down to the catacombs
	local cellar = model("ForgottenCellar")
	local bx0, bx1, bz0, bz1, bh = -705, -655, -175, -105, 18
	local brick = Color3.fromRGB(100, 70, 60)
	local function bwall(ax: number, bx: number, az: number, bz: number)
		P({ name = "Wall", size = V(math.max(1, bx - ax), bh, math.max(1, bz - az)), cf = CF((ax + bx) / 2, bh / 2, (az + bz) / 2), color = brick, mat = M.Brick, parent = cellar, map = Color3.fromRGB(150, 120, 100), layer = 3 })
	end
	bwall(bx0, bx1, bz0, bz0 + 1)
	bwall(bx0, bx1, bz1 - 1, bz1)
	bwall(bx0, bx0 + 1, bz0, bz1)
	-- east wall facing the alley, with a gap where a board fell off
	bwall(bx1 - 1, bx1, bz0, -132)
	bwall(bx1 - 1, bx1, -127, bz1)
	P({ name = "Lintel", size = V(1, bh - 7, 5), cf = CF(bx1 - 0.5, 7 + (bh - 7) / 2, -129.5), color = brick, mat = M.Brick, parent = cellar })
	for _, y in { 5.5, 6.5 } do
		P({ name = "Board", size = V(0.4, 0.8, 6), cf = CF(bx1 + 0.2, y, -129.5) * CFrame.Angles(math.rad(y * 6 - 35), 0, 0), color = Color3.fromRGB(110, 85, 60), mat = M.WoodPlanks, collide = false, parent = cellar })
	end
	P({ name = "Roof", size = V(bx1 - bx0 + 2, 1, bz1 - bz0 + 2), cf = CF((bx0 + bx1) / 2, bh + 0.5, (bz0 + bz1) / 2), color = Color3.fromRGB(70, 60, 55), mat = M.Slate, parent = cellar })
	local lamp = P({ name = "Candle", size = V(0.6, 1.2, 0.6), cf = CF(-670, 0.6, -108), color = Color3.fromRGB(255, 200, 120), mat = M.Neon, collide = false, parent = cellar })
	pointLight(lamp, 24, 1, Color3.fromRGB(255, 170, 90), true)
	downRamp(hole[1], hole[2], hole[4], hole[3], UNDER_FLOOR, Color3.fromRGB(90, 65, 55))
	secretArea("OldTownCellar", "The Forgotten Cellar", V((bx0 + bx1) / 2, 8, (bz0 + bz1) / 2), V(bx1 - bx0 - 2, 16, bz1 - bz0 - 2))

	-- catacombs below, joined to the Industrial underground by the old tunnel
	undergroundRoom(-720, -640, -228, -172, UNDER_FLOOR, -4, Color3.fromRGB(110, 90, 75), { S = { -684, -676, UNDER_FLOOR + 12 }, E = { TUNNEL_Z - 6, TUNNEL_Z + 6, UNDER_FLOOR + 12 } })
	local cata = model("Catacombs")
	for _, x in { -705, -690, -670, -655 } do
		P({ name = "Pillar", size = V(3, 16, 3), cf = CF(x, UNDER_FLOOR + 8, -200), color = Color3.fromRGB(150, 135, 115), mat = M.Limestone, parent = cata })
	end
	for _, pos in { V(-710, 0, -220), V(-650, 0, -180), V(-700, 0, -180) } do
		local candle = P({ name = "Candle", size = V(0.5, 1.4, 0.5), cf = CF(pos.X, UNDER_FLOOR + 0.7, pos.Z), color = Color3.fromRGB(255, 210, 140), mat = M.Neon, collide = false, parent = cata })
		pointLight(candle, 26, 1.2, Color3.fromRGB(255, 170, 90), true)
	end
	signBoard("CataSign", V(-680, UNDER_FLOOR + 9, -227.4), V(22, 3, 0.4), V(0, 0, 1), "OLD TOWN CATACOMBS · EST. 1871", Color3.fromRGB(240, 210, 150), nil, cata)
	secretArea("OldTownCatacombs", "Old Town Catacombs", V(-680, UNDER_FLOOR + 8, -200), V(80, 16, 56))
end

---------------------------------------------------------------------------
-- World edges: invisible walls so nobody walks off the map
---------------------------------------------------------------------------
local function buildBounds()
	local f = Instance.new("Folder")
	f.Name = "Bounds"
	f.Parent = root
	local lo, hi = DC.WORLD_MIN, DC.WORLD_MAX
	local h, y = 400, 150
	local cx, cz = (lo.X + hi.X) / 2, (lo.Z + hi.Z) / 2
	local w, d = hi.X - lo.X, hi.Z - lo.Z
	for _, spec in {
		{ V(2, h, d + 4), V(lo.X - 1, y, cz) },
		{ V(2, h, d + 4), V(hi.X + 1, y, cz) },
		{ V(w + 4, h, 2), V(cx, y, lo.Z - 1) },
		{ V(w + 4, h, 2), V(cx, y, hi.Z - 21) },
	} do
		local wall = P({ name = "WorldEdge", size = spec[1], cf = CF(spec[2]), transp = 1, parent = f })
		wall.CanQuery = false
		wall.CastShadow = false
	end
end

---------------------------------------------------------------------------
-- Subway riding (server side)
---------------------------------------------------------------------------
local lastRide: { [Player]: number } = {}
local riding: { [Player]: boolean } = {}

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, result = pcall(require, mod)
	return if ok then result else nil
end

local function rideBlocked(player: Player): string?
	if not Net.alive(player) then
		return "You can't ride right now."
	end
	if riding[player] then
		return "You're already on a train."
	end
	if (player:GetAttribute("Interior") or "") ~= "" then
		return "Head outside first."
	end
	local driving = player:GetAttribute("Driving")
	if type(driving) == "string" and driving ~= "" then
		return "Park your vehicle before taking the subway."
	end
	local event = player:GetAttribute("Event")
	if type(event) == "string" and event ~= "" then
		return "You're signed up for an event right now."
	end
	local training = player:GetAttribute("Training")
	if type(training) == "string" and training ~= "" then
		return "Finish your workout first."
	end
	local CourtGames = lazy("CourtGames")
	if CourtGames and CourtGames.gameOf and CourtGames.gameOf(player) then
		return "Finish your game first."
	end
	return nil
end

local function rootPosition(player: Player): Vector3?
	local character = player.Character
	local r = character and character:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r.Position else nil
end

local function setupSubway()
	local SubwayUI = Net.remote("RemoteEvent", "SubwayUI") -- server -> client ("Open", stationId)
	local SubwayRide = Net.remote("RemoteFunction", "SubwayRide") -- client -> server (destinationId) -> (ok, rideTimeOrMessage)

	for id, prompt in stationPrompts do
		prompt.Triggered:Connect(function(player)
			if not Net.allow(player, "SubwayPrompt", 0.8) then
				return
			end
			local pos = rootPosition(player)
			local st = pos and DC.nearestStation(pos, DC.SUBWAY_RANGE + 4)
			if not st or st.id ~= id then
				return
			end
			local reason = rideBlocked(player)
			if reason then
				Net.notify(player, "SUBWAY", reason)
				return
			end
			SubwayUI:FireClient(player, "Open", id)
		end)
	end

	SubwayRide.OnServerInvoke = function(player: Player, destId: any)
		if not Net.allow(player, "SubwayRide", 1) then
			return false, "Hold on a second."
		end
		if type(destId) ~= "string" then
			return false, "Pick a station."
		end
		local dest = DC.station(destId)
		if not dest then
			return false, "That station doesn't exist."
		end
		local pos = rootPosition(player)
		local from = pos and DC.nearestStation(pos, DC.SUBWAY_RANGE + 4)
		if not from then
			return false, "Stand at a subway entrance to ride."
		end
		if from.id == dest.id then
			return false, "You're already at " .. dest.name .. "."
		end
		local now = os.clock()
		local wait = (lastRide[player] or -math.huge) + DC.SUBWAY_COOLDOWN - now
		if wait > 0 then
			return false, string.format("Next train in %ds.", math.ceil(wait))
		end
		local reason = rideBlocked(player)
		if reason then
			return false, reason
		end
		if not PlayerData.spendCash(player, DC.SUBWAY_FARE, "Subway fare") then
			return false, string.format("The fare is $%d.", DC.SUBWAY_FARE)
		end
		lastRide[player] = now
		riding[player] = true
		task.spawn(function()
			-- teleport while the rider's screen is black
			task.wait(DC.SUBWAY_RIDE_TIME * 0.5)
			if player.Parent and Net.alive(player) then
				local Basketball = lazy("Basketball")
				local ball = Basketball and Basketball.heldBall and Basketball.heldBall(player)
				if ball then
					Basketball.drop(ball)
				end
				Places.teleport(player, dest.exit)
				player:SetAttribute("District", DC.at(dest.exit.Position))
				local rides = player:GetAttribute("SubwayRides")
				player:SetAttribute("SubwayRides", (if type(rides) == "number" then rides else 0) + 1)
				player:SetAttribute("LastSubwayStation", dest.id)
				Districts.subwayRide:Fire(player, from.id, dest.id)
			end
			task.wait(DC.SUBWAY_RIDE_TIME * 0.5)
			riding[player] = nil
		end)
		return true, DC.SUBWAY_RIDE_TIME
	end

	Players.PlayerRemoving:Connect(function(player)
		lastRide[player] = nil
		riding[player] = nil
	end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- District id at a world position ("Neighborhood", "Downtown", ..., or "Outskirts").
function Districts.at(position: Vector3): string
	return DC.at(position)
end

local function makeDistrict(id: string): Folder
	local d = DC.get(id)
	local f = Instance.new("Folder")
	f.Name = id
	if d then
		f:SetAttribute("DisplayName", d.name)
		f:SetAttribute("Center", d.center)
		f:SetAttribute("Size", d.size)
	end
	f.Parent = root
	current = f
	return f
end

function Districts.build(cityModel: Model)
	city = cityModel
	H = CityBuilder.helpers
	root = Instance.new("Folder")
	root.Name = "Districts"
	root.Parent = city

	local steps: { { any } } = {
		{ "Downtown", buildDowntown },
		{ "Industrial", buildIndustrial },
		{ "Beach", buildBeach },
		{ "Luxury", buildLuxury },
		{ "OldTown", buildOldTown },
	}
	for _, step in steps do
		makeDistrict(step[1])
		local ok, err = pcall(step[2])
		if not ok then
			warn("[CityGrind] District " .. step[1] .. " failed:", err)
		end
	end
	-- tunnel under the Neighborhood belongs to no district folder of its own
	current = root
	local tunnelOk, tunnelErr = pcall(buildSecretTunnel)
	if not tunnelOk then
		warn("[CityGrind] Secret tunnel failed:", tunnelErr)
	end
	buildBounds()

	-- subway: the Neighborhood's existing entrance gets a prompt, every other district gets a station
	local transit = city:FindFirstChild("Transit")
	local old = transit and transit:FindFirstChild("SubwayEntrance")
	local well = old and old:FindFirstChild("Stairwell")
	local hood = DC.station("Neighborhood")
	if well and hood then
		local oldPrompt = well:FindFirstChild("TakeSubway")
		if oldPrompt then
			oldPrompt:Destroy() -- left over in a saved City; replaced by a wired one
		end
		stationPrompts.Neighborhood = addPrompt(well, "TakeSubway", "Take Subway", "Subway · " .. hood.name, 10)
		local points = city:FindFirstChild("MapPoints")
		local point = points and points:FindFirstChild("Subway Station")
		if point then
			point.Name = "Subway · " .. hood.name
		end
	end
	for _, st in DC.STATIONS do
		if st.id ~= "Neighborhood" then
			local folder = root:FindFirstChild(st.id)
			current = folder or root
			buildStation(st)
		end
	end
	setupSubway()

	-- moving / ticking parts
	if #wheel.parts > 0 then
		poseWheel()
		local accumulator = 0
		RunService.Heartbeat:Connect(function(dt)
			if not wheel.active then
				return
			end
			wheel.angle = (wheel.angle + dt * WHEEL_SPEED) % (math.pi * 2)
			accumulator += dt
			if accumulator >= 1 / 30 then
				accumulator = 0
				poseWheel()
			end
		end)
	end

	task.spawn(function()
		local tick = 0
		local lastNight: boolean? = nil
		while true do
			-- day / night for windows and lamps owned here
			local night = Lighting.ClockTime < 6.3 or Lighting.ClockTime > 17.7
			if night ~= lastNight then
				lastNight = night
				applyNight(night)
			end
			-- which district each player is in; whether anyone is near the ferris wheel
			local nearWheel = false
			for _, player in Players:GetPlayers() do
				local pos = rootPosition(player)
				if pos then
					if pos.Y < 400 and (player:GetAttribute("Interior") or "") == "" then
						local id = DC.at(pos)
						if player:GetAttribute("District") ~= id then
							player:SetAttribute("District", id)
						end
					end
					if (pos - wheel.axle).Magnitude < 500 then
						nearWheel = true
					end
				end
			end
			wheel.active = nearWheel
			if tick % 5 == 0 then
				pcall(refreshLeaderboard)
			end
			if tick % 4 == 0 then
				pcall(cycleBillboards)
			end
			tick += 1
			task.wait(2)
		end
	end)

	local count = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	print(string.format("[CityGrind] Districts built: %d parts", count))
end

Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("District", "Neighborhood")
	player:SetAttribute("SubwayRides", 0)
	player:SetAttribute("LastSubwayStation", "")
end)
for _, player in Players:GetPlayers() do
	if player:GetAttribute("District") == nil then
		player:SetAttribute("District", "Neighborhood")
	end
end

return Districts
