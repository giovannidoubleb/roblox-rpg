-- CITY GRIND: vehicles (spec sections 11, 72, 77).
-- Budget Wheels lot (190,0,85) shows every model with a sign and a "View" prompt
-- that opens the purchase panel. The Paint & Mods bay on the lot sells paint,
-- rims and underglow. Owned vehicles are saved in the "vehicles" section and
-- spawned/put away from the phone's Garage app.
--
-- Physics: see shared/VehiclesConfig. While someone drives, their client owns
-- the vehicle and runs the simulation; empty vehicles are simulated here until
-- they come to rest, then the chassis is anchored ("parked").
--
-- Player attributes: Driving (vehicle kind while in a driver seat, else ""),
-- VehicleSpawned (id of the spawned vehicle or ""), VehiclesOwned (JSON of the
-- saved owned table, read by the client UI).
-- Vehicle model: tag "CityVehicle", attributes Owner (UserId), VehicleId, Kind,
-- Headlights (bool, driver toggled with H).

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local VC = require(shared:WaitForChild("VehiclesConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))

type Spec = VC.Spec
type Look = { paint: number, rim: number, glow: number }

local Vehicles = {}

PlayerData.registerSection("vehicles", function()
	-- owned[id] = { paint = n, rim = n, glow = n, t = purchase time }
	return { owned = {}, last = "" }
end)

local TAG = "CityVehicle"
local DARK = Color3.fromRGB(32, 32, 36)
local TIRE = Color3.fromRGB(24, 24, 26)
local GLASS = Color3.fromRGB(40, 55, 70)
local CHROME = Color3.fromRGB(195, 200, 210)
local HEAD = Color3.fromRGB(255, 248, 225)
local TAIL = Color3.fromRGB(120, 20, 22)

local function money(n: number): string
	local digits = tostring(math.floor(n))
	local formatted = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return "$" .. formatted
end

---------------------------------------------------------------------------
-- Model builder. Everything is placed in "ground space" (y = 0 is the road,
-- -z is the front), with the chassis centred at (0, groundOffset, 0).
---------------------------------------------------------------------------
type Ctx = { model: Model, chassis: BasePart, display: boolean, spec: Spec }
type PartOpts = {
	class: string?,
	shape: Enum.PartType?,
	tag: string?,
	transparency: number?,
	reflectance: number?,
	weldTo: BasePart?,
}

local function addPart(ctx: Ctx, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, opts: PartOpts?): BasePart
	local o: PartOpts = opts or {}
	local p = Instance.new(o.class or "Part") :: BasePart
	p.Name = name
	if o.shape and p:IsA("Part") then
		p.Shape = o.shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = o.transparency or 0
	p.Reflectance = o.reflectance or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Anchored = ctx.display
	if o.tag then
		p:SetAttribute(o.tag, true)
	end
	local to = o.weldTo or ctx.chassis
	local weld = Instance.new("Weld")
	weld.Part0 = to
	weld.Part1 = p
	weld.C0 = to.CFrame:ToObjectSpace(cf)
	weld.Parent = p
	p.Parent = ctx.model
	return p
end

local function paint(ctx: Ctx, name: string, size: Vector3, cf: CFrame, opts: PartOpts?): BasePart
	local o: PartOpts = opts or {}
	o.tag = "Paint"
	o.reflectance = 0.06
	return addPart(ctx, name, size, cf, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, o)
end

local function wedge(ctx: Ctx, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, opts: PartOpts?): BasePart
	local o: PartOpts = opts or {}
	o.class = "WedgePart"
	return addPart(ctx, name, size, cf, color, material, o)
end

local function glass(ctx: Ctx, name: string, size: Vector3, cf: CFrame, isWedge: boolean?): BasePart
	local o = { transparency = 0.3, reflectance = 0.15, class = if isWedge then "WedgePart" else nil }
	return addPart(ctx, name, size, cf, GLASS, Enum.Material.Glass, o)
end

-- A thin bar between two points.
local function rod(ctx: Ctx, name: string, a: Vector3, b: Vector3, thick: number, color: Color3?, isPaint: boolean?): BasePart
	local cf = CFrame.lookAt((a + b) / 2, b)
	local size = Vector3.new(thick, thick, (b - a).Magnitude)
	if isPaint then
		return paint(ctx, name, size, cf)
	end
	return addPart(ctx, name, size, cf, color or DARK, Enum.Material.Metal)
end

local function headlight(ctx: Ctx, size: Vector3, pos: Vector3)
	local p = addPart(ctx, "Headlight", size, CFrame.new(pos), HEAD, Enum.Material.SmoothPlastic, { tag = "Head" })
	if not ctx.display then
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Front
		light.Range = 55
		light.Angle = 70
		light.Brightness = 4
		light.Color = Color3.fromRGB(255, 244, 220)
		light.Shadows = false
		light.Enabled = false
		light.Parent = p
	end
end

local function taillight(ctx: Ctx, size: Vector3, pos: Vector3)
	addPart(ctx, "Taillight", size, CFrame.new(pos), TAIL, Enum.Material.SmoothPlastic, { tag = "Tail" })
end

local function cylinderZ(ctx: Ctx, name: string, length: number, diameter: number, pos: Vector3, color: Color3, material: Enum.Material?)
	-- a cylinder's axis is its X; turn it to run front-to-back
	return addPart(ctx, name, Vector3.new(length, diameter, diameter), CFrame.new(pos) * CFrame.Angles(0, math.pi / 2, 0), color, material, { shape = Enum.PartType.Cylinder })
end

type Layout = { wheels: { { x: number, z: number, steer: boolean } }, seats: { Vector3 }, seatSize: Vector3 }

local STYLES: { [string]: (Ctx) -> Layout } = {}

STYLES.hatch = function(ctx)
	local s = ctx.spec
	local W, L = s.width, s.length
	local hw, hl = W / 2, L / 2
	paint(ctx, "Body", Vector3.new(W, 1.9, L), CFrame.new(0, 2.15, 0))
	addPart(ctx, "Skirt", Vector3.new(W - 0.3, 0.4, L - 0.4), CFrame.new(0, 1.0, 0), DARK)
	glass(ctx, "Cabin", Vector3.new(W - 0.7, 2.2, 6.0), CFrame.new(0, 4.2, 1.3))
	paint(ctx, "Roof", Vector3.new(W - 0.5, 0.3, 6.4), CFrame.new(0, 5.45, 1.3))
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			paint(ctx, "Pillar", Vector3.new(0.3, 2.2, 0.3), CFrame.new(x * (hw - 0.4), 4.2, 1.3 + z * 2.95))
		end
	end
	glass(ctx, "Windshield", Vector3.new(W - 0.7, 2.2, 1.8), CFrame.new(0, 4.2, -2.6), true)
	glass(ctx, "RearWindow", Vector3.new(W - 0.7, 2.2, 0.8), CFrame.new(0, 4.2, 4.7) * CFrame.Angles(0, math.pi, 0), true)
	addPart(ctx, "Dashboard", Vector3.new(W - 0.8, 0.6, 0.8), CFrame.new(0, 3.3, -1.6), DARK)
	addPart(ctx, "SteeringWheel", Vector3.new(0.15, 1.0, 1.0), CFrame.new(-1.4, 3.35, -0.9) * CFrame.Angles(-0.4, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), DARK, nil, { shape = Enum.PartType.Cylinder })
	for _, z in { -1, 1 } do
		addPart(ctx, "Bumper", Vector3.new(W + 0.1, 0.7, 0.5), CFrame.new(0, 1.45, z * (hl + 0.1)), DARK)
		addPart(ctx, "Plate", Vector3.new(1.4, 0.4, 0.06), CFrame.new(0, 1.95, z * (hl + 0.03)), Color3.fromRGB(235, 235, 220))
	end
	addPart(ctx, "Grille", Vector3.new(2.4, 0.6, 0.12), CFrame.new(0, 2.5, -hl - 0.02), DARK)
	for _, x in { -1, 1 } do
		headlight(ctx, Vector3.new(1.3, 0.5, 0.15), Vector3.new(x * 2.2, 2.55, -hl - 0.04))
		taillight(ctx, Vector3.new(1.1, 0.5, 0.15), Vector3.new(x * 2.3, 2.55, hl + 0.04))
		paint(ctx, "Mirror", Vector3.new(0.5, 0.35, 0.35), CFrame.new(x * (hw + 0.2), 3.6, -1.5))
		addPart(ctx, "Handle", Vector3.new(0.08, 0.15, 0.6), CFrame.new(x * (hw + 0.03), 2.75, -0.2), DARK)
		addPart(ctx, "Handle", Vector3.new(0.08, 0.15, 0.6), CFrame.new(x * (hw + 0.03), 2.75, 2.6), DARK)
	end
	return {
		wheels = {
			{ x = -s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = -s.track / 2, z = s.wheelbase / 2, steer = false },
			{ x = s.track / 2, z = s.wheelbase / 2, steer = false },
		},
		seats = { Vector3.new(-1.4, 1.6, 0.4), Vector3.new(1.4, 1.6, 0.4), Vector3.new(-1.4, 1.7, 3.2), Vector3.new(1.4, 1.7, 3.2) },
		seatSize = Vector3.new(1.8, 0.4, 1.8),
	}
end

STYLES.suv = function(ctx)
	local s = ctx.spec
	local W, L = s.width, s.length
	local hw, hl = W / 2, L / 2
	paint(ctx, "Body", Vector3.new(W, 2.6, L), CFrame.new(0, 2.9, 0))
	addPart(ctx, "Skirt", Vector3.new(W - 0.3, 0.5, L - 0.6), CFrame.new(0, 1.4, 0), DARK)
	glass(ctx, "Cabin", Vector3.new(W - 0.6, 2.5, 8.6), CFrame.new(0, 5.45, 1.5))
	paint(ctx, "Roof", Vector3.new(W - 0.3, 0.35, 9.0), CFrame.new(0, 6.88, 1.5))
	for _, x in { -1, 1 } do
		for _, z in { -2.8, 1.0, 5.75 } do
			paint(ctx, "Pillar", Vector3.new(0.35, 2.5, 0.35), CFrame.new(x * (hw - 0.35), 5.45, z))
		end
		addPart(ctx, "RoofRail", Vector3.new(0.25, 0.25, 8.0), CFrame.new(x * (hw - 0.6), 7.2, 1.5), DARK, Enum.Material.Metal)
	end
	for _, z in { -1.2, 4.2 } do
		addPart(ctx, "RoofBar", Vector3.new(W - 1.0, 0.2, 0.25), CFrame.new(0, 7.2, z), DARK, Enum.Material.Metal)
	end
	glass(ctx, "Windshield", Vector3.new(W - 0.6, 2.5, 1.4), CFrame.new(0, 5.45, -3.5), true)
	addPart(ctx, "Dashboard", Vector3.new(W - 0.8, 0.7, 0.9), CFrame.new(0, 4.4, -2.4), DARK)
	addPart(ctx, "SteeringWheel", Vector3.new(0.15, 1.1, 1.1), CFrame.new(-1.5, 4.25, -1.8) * CFrame.Angles(-0.4, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), DARK, nil, { shape = Enum.PartType.Cylinder })
	addPart(ctx, "Grille", Vector3.new(3.4, 1.2, 0.15), CFrame.new(0, 3.0, -hl - 0.03), CHROME, Enum.Material.Metal)
	for _, z in { -1, 1 } do
		addPart(ctx, "Bumper", Vector3.new(W + 0.2, 0.9, 0.6), CFrame.new(0, 1.7, z * (hl + 0.15)), DARK)
		addPart(ctx, "Plate", Vector3.new(1.4, 0.4, 0.06), CFrame.new(0, 2.45, z * (hl + 0.03)), Color3.fromRGB(235, 235, 220))
	end
	addPart(ctx, "SkidPlate", Vector3.new(3.0, 0.3, 0.8), CFrame.new(0, 1.15, -hl - 0.1), CHROME, Enum.Material.Metal)
	cylinderZ(ctx, "SpareTire", 0.7, 2.6, Vector3.new(0, 3.6, hl + 0.4), TIRE)
	for _, x in { -1, 1 } do
		headlight(ctx, Vector3.new(1.3, 0.6, 0.15), Vector3.new(x * 2.5, 3.55, -hl - 0.04))
		taillight(ctx, Vector3.new(0.6, 1.4, 0.15), Vector3.new(x * (hw - 0.5), 3.5, hl + 0.04))
		paint(ctx, "Mirror", Vector3.new(0.5, 0.45, 0.4), CFrame.new(x * (hw + 0.25), 4.7, -2.4))
	end
	return {
		wheels = {
			{ x = -s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = -s.track / 2, z = s.wheelbase / 2, steer = false },
			{ x = s.track / 2, z = s.wheelbase / 2, steer = false },
		},
		seats = {
			Vector3.new(-1.5, 2.2, -0.7),
			Vector3.new(1.5, 2.2, -0.7),
			Vector3.new(-1.95, 2.3, 2.6),
			Vector3.new(0, 2.3, 2.6),
			Vector3.new(1.95, 2.3, 2.6),
		},
		seatSize = Vector3.new(1.7, 0.4, 1.8),
	}
end

STYLES.coupe = function(ctx)
	local s = ctx.spec
	local W, L = s.width, s.length
	local hw, hl = W / 2, L / 2
	paint(ctx, "Body", Vector3.new(W, 1.5, L), CFrame.new(0, 1.85, 0))
	addPart(ctx, "Skirt", Vector3.new(W - 0.2, 0.3, L - 0.8), CFrame.new(0, 0.95, 0), DARK)
	wedge(ctx, "Nose", Vector3.new(W, 0.55, 3.4), CFrame.new(0, 2.875, -hl + 1.7), Color3.new(1, 1, 1), nil, { tag = "Paint", reflectance = 0.06 })
	glass(ctx, "Cabin", Vector3.new(W - 1.3, 2.2, 4.6), CFrame.new(0, 3.7, 1.2))
	paint(ctx, "Roof", Vector3.new(W - 1.1, 0.25, 4.4), CFrame.new(0, 4.92, 1.3))
	for _, x in { -0.55, 0.55 } do
		addPart(ctx, "Stripe", Vector3.new(0.7, 0.04, 4.4), CFrame.new(x, 5.06, 1.3), Color3.fromRGB(245, 245, 245))
	end
	glass(ctx, "Windshield", Vector3.new(W - 1.3, 2.2, 2.2), CFrame.new(0, 3.7, -2.2), true)
	glass(ctx, "RearWindow", Vector3.new(W - 1.3, 2.2, 2.4), CFrame.new(0, 3.7, 4.7) * CFrame.Angles(0, math.pi, 0), true)
	paint(ctx, "RearDeck", Vector3.new(W, 0.4, 1.0), CFrame.new(0, 2.8, hl - 0.5))
	addPart(ctx, "Dashboard", Vector3.new(W - 1.4, 0.5, 0.7), CFrame.new(0, 3.0, -0.8), DARK)
	addPart(ctx, "SteeringWheel", Vector3.new(0.15, 0.9, 0.9), CFrame.new(-1.3, 3.0, -0.2) * CFrame.Angles(-0.5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), DARK, nil, { shape = Enum.PartType.Cylinder })
	for _, x in { -1, 1 } do
		addPart(ctx, "SpoilerPost", Vector3.new(0.3, 0.7, 0.3), CFrame.new(x * 2.0, 3.35, hl - 0.5), DARK)
		headlight(ctx, Vector3.new(1.5, 0.35, 0.15), Vector3.new(x * 2.3, 2.35, -hl - 0.04))
		taillight(ctx, Vector3.new(1.8, 0.35, 0.15), Vector3.new(x * 2.1, 2.35, hl + 0.04))
		paint(ctx, "Mirror", Vector3.new(0.5, 0.3, 0.4), CFrame.new(x * (hw + 0.2), 3.3, -1.0))
		cylinderZ(ctx, "Exhaust", 0.6, 0.45, Vector3.new(x * 1.4, 1.3, hl + 0.2), CHROME, Enum.Material.Metal)
		addPart(ctx, "SideVent", Vector3.new(0.06, 0.5, 1.4), CFrame.new(x * (hw + 0.02), 2.0, -2.9), DARK)
	end
	addPart(ctx, "Wing", Vector3.new(W - 0.4, 0.15, 1.0), CFrame.new(0, 3.75, hl - 0.45), DARK)
	addPart(ctx, "Splitter", Vector3.new(W, 0.15, 0.5), CFrame.new(0, 1.05, -hl - 0.15), DARK)
	return {
		wheels = {
			{ x = -s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = -s.track / 2, z = s.wheelbase / 2, steer = false },
			{ x = s.track / 2, z = s.wheelbase / 2, steer = false },
		},
		seats = { Vector3.new(-1.3, 1.2, 1.0), Vector3.new(1.3, 1.2, 1.0) },
		seatSize = Vector3.new(1.8, 0.4, 1.8),
	}
end

STYLES.supercar = function(ctx)
	local s = ctx.spec
	local W, L = s.width, s.length
	local hw, hl = W / 2, L / 2
	paint(ctx, "Body", Vector3.new(W, 1.3, L), CFrame.new(0, 1.6, 0))
	wedge(ctx, "Nose", Vector3.new(W, 0.7, 3.8), CFrame.new(0, 2.6, -hl + 1.9), Color3.new(1, 1, 1), nil, { tag = "Paint", reflectance = 0.06 })
	paint(ctx, "EngineCover", Vector3.new(W - 2.0, 0.9, 4.2), CFrame.new(0, 2.7, 4.6))
	addPart(ctx, "EngineGlass", Vector3.new(W - 3.0, 0.1, 2.6), CFrame.new(0, 3.17, 4.6), GLASS, Enum.Material.Glass, { transparency = 0.2 })
	glass(ctx, "Windshield", Vector3.new(W - 1.6, 1.4, 1.6), CFrame.new(0, 2.95, -2.3), true)
	addPart(ctx, "Dashboard", Vector3.new(W - 1.8, 0.5, 0.6), CFrame.new(0, 2.5, -1.2), DARK)
	addPart(ctx, "SteeringWheel", Vector3.new(0.15, 0.9, 0.9), CFrame.new(-1.3, 2.75, -0.6) * CFrame.Angles(-0.5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), DARK, nil, { shape = Enum.PartType.Cylinder })
	addPart(ctx, "RollBar", Vector3.new(W - 2.0, 0.3, 0.3), CFrame.new(0, 3.9, 2.3), DARK, Enum.Material.Metal)
	for _, x in { -1, 1 } do
		paint(ctx, "SidePod", Vector3.new(0.9, 1.0, 5.5), CFrame.new(x * (hw - 0.45), 2.75, 1.6))
		addPart(ctx, "Intake", Vector3.new(0.1, 0.7, 1.8), CFrame.new(x * (hw + 0.01), 2.75, 0.4), DARK)
		addPart(ctx, "RollPost", Vector3.new(0.3, 1.65, 0.3), CFrame.new(x * (hw - 1.15), 3.07, 2.3), DARK, Enum.Material.Metal)
		addPart(ctx, "WingPost", Vector3.new(0.25, 1.0, 0.25), CFrame.new(x * 2.2, 3.6, hl - 0.7), DARK)
		headlight(ctx, Vector3.new(1.7, 0.25, 0.15), Vector3.new(x * 2.4, 2.05, -hl - 0.04))
		for _, dx in { 0.35, 0.95 } do
			cylinderZ(ctx, "Exhaust", 0.5, 0.4, Vector3.new(x * dx, 1.45, hl + 0.2), CHROME, Enum.Material.Metal)
		end
	end
	taillight(ctx, Vector3.new(W - 1.2, 0.2, 0.12), Vector3.new(0, 2.0, hl + 0.04))
	addPart(ctx, "Wing", Vector3.new(W, 0.15, 1.3), CFrame.new(0, 4.15, hl - 0.65), DARK)
	addPart(ctx, "Diffuser", Vector3.new(W - 1, 0.5, 0.4), CFrame.new(0, 1.15, hl + 0.15), DARK)
	addPart(ctx, "Splitter", Vector3.new(W, 0.15, 0.6), CFrame.new(0, 0.95, -hl - 0.2), DARK)
	return {
		wheels = {
			{ x = -s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = s.track / 2, z = -s.wheelbase / 2, steer = true },
			{ x = -s.track / 2, z = s.wheelbase / 2, steer = false },
			{ x = s.track / 2, z = s.wheelbase / 2, steer = false },
		},
		seats = { Vector3.new(-1.3, 1.1, 1.0), Vector3.new(1.3, 1.1, 1.0) },
		seatSize = Vector3.new(1.8, 0.4, 1.8),
	}
end

STYLES.motorcycle = function(ctx)
	local s = ctx.spec
	local hb = s.wheelbase / 2
	local r = s.wheelRadius
	addPart(ctx, "Engine", Vector3.new(1.0, 1.1, 1.7), CFrame.new(0, 1.75, -0.1), DARK, Enum.Material.Metal)
	paint(ctx, "Tank", Vector3.new(1.1, 0.8, 1.8), CFrame.new(0, 2.75, -0.9))
	wedge(ctx, "Fairing", Vector3.new(1.3, 1.1, 1.0), CFrame.new(0, 2.9, -2.0), Color3.new(1, 1, 1), nil, { tag = "Paint", reflectance = 0.06 })
	addPart(ctx, "Windscreen", Vector3.new(1.0, 0.6, 0.1), CFrame.new(0, 3.6, -2.3) * CFrame.Angles(-0.45, 0, 0), GLASS, Enum.Material.Glass, { transparency = 0.35 })
	paint(ctx, "Tail", Vector3.new(0.9, 0.5, 1.6), CFrame.new(0, 2.75, 2.5))
	addPart(ctx, "Handlebar", Vector3.new(2.0, 0.14, 0.14), CFrame.new(0, 3.3, -1.95), DARK, Enum.Material.Metal)
	for _, x in { -0.35, 0.35 } do
		rod(ctx, "Fork", Vector3.new(x, r, -hb), Vector3.new(x, 3.2, -2.0), 0.18, CHROME)
		rod(ctx, "Swingarm", Vector3.new(x, r, hb), Vector3.new(x, 1.6, 0.6), 0.2, DARK)
	end
	cylinderZ(ctx, "Exhaust", 2.2, 0.4, Vector3.new(0.6, 1.5, 1.7), CHROME, Enum.Material.Metal)
	paint(ctx, "FrontFender", Vector3.new(0.7, 0.15, 1.4), CFrame.new(0, r * 2 + 0.2, -hb))
	headlight(ctx, Vector3.new(0.7, 0.5, 0.15), Vector3.new(0, 2.95, -2.55))
	taillight(ctx, Vector3.new(0.6, 0.25, 0.12), Vector3.new(0, 2.75, 3.32))
	return {
		wheels = { { x = 0, z = -hb, steer = true }, { x = 0, z = hb, steer = false } },
		seats = { Vector3.new(0, 2.95, 0.55), Vector3.new(0, 3.15, 1.8) },
		seatSize = Vector3.new(1.0, 0.3, 1.2),
	}
end

STYLES.scooter = function(ctx)
	local s = ctx.spec
	local hb = s.wheelbase / 2
	local r = s.wheelRadius
	paint(ctx, "Deck", Vector3.new(1.1, 0.3, 2.0), CFrame.new(0, 0.95, -0.2))
	paint(ctx, "Shield", Vector3.new(1.3, 2.0, 0.35), CFrame.new(0, 1.9, -1.45) * CFrame.Angles(0.25, 0, 0))
	rod(ctx, "Column", Vector3.new(0, r, -hb), Vector3.new(0, 3.2, -1.65), 0.22, DARK)
	addPart(ctx, "Handlebar", Vector3.new(1.8, 0.14, 0.14), CFrame.new(0, 3.25, -1.65), DARK, Enum.Material.Metal)
	paint(ctx, "RearBody", Vector3.new(1.3, 0.9, 2.3), CFrame.new(0, 1.55, 1.3))
	paint(ctx, "FrontFender", Vector3.new(0.6, 0.15, 1.1), CFrame.new(0, r * 2 + 0.15, -hb))
	headlight(ctx, Vector3.new(0.5, 0.4, 0.12), Vector3.new(0, 2.95, -1.82))
	taillight(ctx, Vector3.new(0.6, 0.3, 0.12), Vector3.new(0, 1.7, 2.48))
	return {
		wheels = { { x = 0, z = -hb, steer = true }, { x = 0, z = hb, steer = false } },
		seats = { Vector3.new(0, 2.3, 0.75), Vector3.new(0, 2.4, 1.95) },
		seatSize = Vector3.new(1.0, 0.3, 1.1),
	}
end

STYLES.bicycle = function(ctx)
	local s = ctx.spec
	local hb = s.wheelbase / 2
	local r = s.wheelRadius
	local rear = Vector3.new(0, r, hb)
	local front = Vector3.new(0, r, -hb)
	local bb = Vector3.new(0, 1.1, 0.1) -- bottom bracket
	local seatTop = Vector3.new(0, 2.6, 0.5)
	local headTop = Vector3.new(0, 2.85, -1.6)
	local headBottom = Vector3.new(0, 2.2, -1.75)
	rod(ctx, "SeatTube", bb, seatTop, 0.2, nil, true)
	rod(ctx, "TopTube", seatTop, headTop, 0.2, nil, true)
	rod(ctx, "DownTube", bb, headBottom, 0.22, nil, true)
	rod(ctx, "ChainStay", bb, rear, 0.15, nil, true)
	rod(ctx, "SeatStay", seatTop, rear, 0.15, nil, true)
	rod(ctx, "Fork", headBottom, front, 0.16, CHROME)
	rod(ctx, "Stem", headTop, Vector3.new(0, 3.15, -1.7), 0.16, CHROME)
	addPart(ctx, "Handlebar", Vector3.new(1.8, 0.14, 0.14), CFrame.new(0, 3.15, -1.7), DARK, Enum.Material.Metal)
	addPart(ctx, "Crank", Vector3.new(0.9, 0.12, 0.12), CFrame.new(bb), DARK, Enum.Material.Metal)
	for _, x in { -0.45, 0.45 } do
		addPart(ctx, "Pedal", Vector3.new(0.35, 0.1, 0.25), CFrame.new(bb + Vector3.new(x, 0, 0)), DARK)
	end
	headlight(ctx, Vector3.new(0.3, 0.3, 0.15), Vector3.new(0, 2.95, -1.92))
	taillight(ctx, Vector3.new(0.3, 0.25, 0.1), Vector3.new(0, 2.45, 1.05))
	return {
		wheels = { { x = 0, z = -hb, steer = true }, { x = 0, z = hb, steer = false } },
		seats = { Vector3.new(0, 2.9, 0.6) },
		seatSize = Vector3.new(0.7, 0.3, 1.0),
	}
end

local function addWheel(ctx: Ctx, x: number, z: number, steer: boolean)
	local s = ctx.spec
	local r, w = s.wheelRadius, s.wheelWidth
	local cf = CFrame.new(x, r, z)
	local wheel = Instance.new("Part")
	wheel.Name = "Wheel"
	wheel.Shape = Enum.PartType.Cylinder -- axis along X = the axle
	wheel.Size = Vector3.new(w, r * 2, r * 2)
	wheel.CFrame = cf
	wheel.Color = TIRE
	wheel.Material = Enum.Material.SmoothPlastic
	wheel.CanCollide = false
	wheel.CanQuery = false
	wheel.CanTouch = false
	wheel.Massless = true
	wheel.Anchored = ctx.display
	wheel.Parent = ctx.model
	local motor = Instance.new("Motor6D")
	motor.Name = "WheelMotor"
	motor.Part0 = ctx.chassis
	motor.Part1 = wheel
	motor.C0 = ctx.chassis.CFrame:ToObjectSpace(cf)
	motor:SetAttribute("Steer", steer)
	motor.Parent = ctx.chassis
	-- rim, two spokes (so spinning is visible) and a hub cap
	local rimScale = if s.twoWheel and w < 0.4 then 1.8 else 1.25
	addPart(ctx, "Rim", Vector3.new(w + 0.06, r * rimScale, r * rimScale), cf, CHROME, Enum.Material.Metal, { shape = Enum.PartType.Cylinder, tag = "Rim", weldTo = wheel })
	addPart(ctx, "Spoke", Vector3.new(w + 0.1, 0.22, r * 1.7), cf, CHROME, Enum.Material.Metal, { tag = "Rim", weldTo = wheel })
	addPart(ctx, "Spoke", Vector3.new(w + 0.1, r * 1.7, 0.22), cf, CHROME, Enum.Material.Metal, { tag = "Rim", weldTo = wheel })
	addPart(ctx, "Hub", Vector3.new(w + 0.14, r * 0.35, r * 0.35), cf, DARK, Enum.Material.Metal, { shape = Enum.PartType.Cylinder, weldTo = wheel })
end

-- Applies saved paint / rim / underglow choices to a built model.
local function applyLook(model: Model, look: Look)
	local paintColor = (VC.PAINTS[look.paint] or VC.PAINTS[1]).color
	local rim = VC.RIMS[look.rim] or VC.RIMS[1]
	local glowIndex = if VC.GLOWS[look.glow] then look.glow else 1
	local glow = VC.GLOWS[glowIndex]
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d:GetAttribute("Paint") then
				d.Color = paintColor
			elseif d:GetAttribute("Rim") then
				d.Color = rim.color
				d.Material = rim.material
			elseif d:GetAttribute("Glow") then
				d.Color = glow.color
				d.Transparency = if glowIndex == 1 then 1 else 0
				local light = d:FindFirstChildOfClass("PointLight")
				if light then
					light.Color = glow.color
					light.Enabled = glowIndex ~= 1
				end
			end
		end
	end
	model:SetAttribute("Paint", look.paint)
	model:SetAttribute("Rim", look.rim)
	model:SetAttribute("Glow", glowIndex)
end

local function buildVehicle(s: Spec, look: Look, display: boolean): Model
	local model = Instance.new("Model")
	model.Name = s.name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local GO = VC.groundOffset(s)

	-- The collider: an invisible box from just above curb height to the roof.
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = Vector3.new(s.width, s.height - s.clearance, s.length)
	chassis.CFrame = CFrame.new(0, GO, 0)
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CanQuery = true
	chassis.CanTouch = true
	chassis.Anchored = true
	chassis.RootPriority = 100
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.05, 0.15, 0, 1, 1)
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.Parent = model
	model.PrimaryPart = chassis

	local ctx: Ctx = { model = model, chassis = chassis, display = display, spec = s }

	-- Low, heavy ballast keeps the centre of mass near the axles.
	local ballastSize = Vector3.new(math.max(s.width - 1, 0.6), 0.6, math.max(s.length - 2, 2))
	local ballast = addPart(ctx, "Ballast", ballastSize, CFrame.new(0, s.clearance + 0.3, 0), DARK, nil, { transparency = 1 })
	ballast.Massless = false
	local volume = ballastSize.X * ballastSize.Y * ballastSize.Z
	ballast.CustomPhysicalProperties = PhysicalProperties.new(math.clamp(s.mass / volume, 0.01, 100), 0.3, 0, 1, 1)

	local layout = STYLES[s.style](ctx)
	for _, w in layout.wheels do
		addWheel(ctx, w.x, w.z, w.steer)
	end

	-- underglow (always built; hidden when the "None" option is chosen)
	local glowWidth = if s.twoWheel then 0.5 else s.width - 1.4
	local glowPart = addPart(ctx, "Underglow", Vector3.new(glowWidth, 0.1, s.length * 0.62), CFrame.new(0, if s.twoWheel then 0.45 else 0.75, 0), Color3.new(1, 1, 1), Enum.Material.Neon, { tag = "Glow", transparency = 1 })
	local glowLight = Instance.new("PointLight")
	glowLight.Range = if s.twoWheel then 8 else 13
	glowLight.Brightness = 2.5
	glowLight.Shadows = false
	glowLight.Enabled = false
	glowLight.Parent = glowPart

	-- seats: the first is the driver's VehicleSeat. Touch-sitting is off (CanTouch
	-- false); players get in through the Drive / Ride prompts so nobody falls
	-- into a seat by bumping a car.
	local seats = {}
	for i = 1, math.min(s.seats, #layout.seats) do
		local top = layout.seats[i]
		local size = layout.seatSize
		local seat = addPart(ctx, if i == 1 then "DriverSeat" else "PassengerSeat", size, CFrame.new(top - Vector3.new(0, size.Y / 2, 0)), Color3.fromRGB(45, 42, 40), Enum.Material.Fabric, { class = if i == 1 then "VehicleSeat" else "Seat" })
		if seat:IsA("VehicleSeat") then
			seat.MaxSpeed = 0
			seat.Torque = 0
			seat.TurnSpeed = 0
			seat.HeadsUpDisplay = false
		end
		if display and (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then
			seat.Disabled = true
		end
		table.insert(seats, seat)
	end

	if not display then
		local center = Instance.new("Attachment")
		center.Name = "Center"
		center.Parent = chassis
		local force = Instance.new("VectorForce")
		force.Name = "DriveForce"
		force.Attachment0 = center
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.ApplyAtCenterOfMass = true
		force.Force = Vector3.zero
		force.Parent = chassis
		local torque = Instance.new("Torque")
		torque.Name = "DriveTorque"
		torque.Attachment0 = center
		torque.RelativeTo = Enum.ActuatorRelativeTo.World
		torque.Torque = Vector3.zero
		torque.Parent = chassis

		-- keeps the chassis' up axis pointing up (its X axis is the chassis' up)
		local uprightAtt = Instance.new("Attachment")
		uprightAtt.Name = "UprightAttachment"
		uprightAtt.CFrame = VC.axisCFrame(Vector3.yAxis)
		uprightAtt.Parent = chassis
		local align = Instance.new("AlignOrientation")
		align.Name = "Upright"
		align.Mode = Enum.OrientationAlignmentMode.OneAttachment
		align.Attachment0 = uprightAtt
		local ok = pcall(function()
			align.AlignType = Enum.AlignType.PrimaryAxisParallel
		end)
		if not ok then
			align.PrimaryAxisOnly = true
		end
		align.CFrame = VC.axisCFrame(Vector3.yAxis)
		local expectedMass = s.mass + 30
		align.MaxTorque = expectedMass * (if s.twoWheel then 500 else 220)
		align.Responsiveness = if s.twoWheel then 30 else 14
		align.Parent = chassis

		-- suspension mount points: wheel centre at rest + the unused travel
		local mountY = s.wheelRadius + (s.travel - s.sag) - GO
		local hx, hz = s.track / 2, s.wheelbase / 2
		for _, p in { Vector3.new(-hx, mountY, -hz), Vector3.new(hx, mountY, -hz), Vector3.new(-hx, mountY, hz), Vector3.new(hx, mountY, hz) } do
			local att = Instance.new("Attachment")
			att.Name = "Susp"
			att.Position = p
			att.Parent = chassis
		end

		-- prompts: Drive on the driver's side, Ride on the other side
		local driverSeat = layout.seats[1]
		local side = if driverSeat.X > 0.1 then 1 else -1
		local driveAtt = Instance.new("Attachment")
		driveAtt.Name = "DrivePromptAttachment"
		driveAtt.Position = Vector3.new(side * (s.width / 2 + 0.6), 2.6 - GO, driverSeat.Z)
		driveAtt.Parent = chassis
		local drive = Instance.new("ProximityPrompt")
		drive.Name = "DrivePrompt"
		drive.ActionText = "Drive"
		drive.ObjectText = s.name
		drive.KeyboardKeyCode = Enum.KeyCode.E
		drive.MaxActivationDistance = 9
		drive.RequiresLineOfSight = false
		drive.Parent = driveAtt
		if #seats > 1 then
			local rideSeat = layout.seats[2]
			local rideAtt = Instance.new("Attachment")
			rideAtt.Name = "RidePromptAttachment"
			rideAtt.Position = Vector3.new(-side * (s.width / 2 + 0.6), 2.6 - GO, rideSeat.Z)
			rideAtt.Parent = chassis
			local ride = Instance.new("ProximityPrompt")
			ride.Name = "RidePrompt"
			ride.ActionText = "Ride"
			ride.ObjectText = s.name
			ride.KeyboardKeyCode = Enum.KeyCode.E
			ride.MaxActivationDistance = 9
			ride.RequiresLineOfSight = false
			ride.Parent = rideAtt
		end
	end

	-- the visual wheels drop/steer around their rest position (read by clients)
	model:SetAttribute("VehicleId", s.id)
	model:SetAttribute("Kind", s.kind)
	applyLook(model, look)
	return model
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
type Active = {
	owner: Player,
	id: string,
	spec: Spec,
	model: Model,
	chassis: BasePart,
	seat: VehicleSeat,
	seats: { Seat | VehicleSeat },
	sim: VC.Sim,
	driver: Player?,
	override: boolean,
	restTime: number,
	overspeed: number,
}

local active: { [Player]: Active } = {}
local byModel: { [Model]: Active } = {}
local lastSpawn: { [Player]: number } = {}
local activeFolder: Folder
local ignoreList: { Instance } = {}

local VehicleUI = Net.remote("RemoteEvent", "VehicleUI") -- server -> client ("Shop", id) / ("Mods")
local VehicleBuy = Net.remote("RemoteFunction", "VehicleBuy") -- (id, paintIndex) -> ok, message
local VehicleMod = Net.remote("RemoteFunction", "VehicleMod") -- (id, "paint"|"rim"|"glow", index) -> ok, message
local VehicleSpawn = Net.remote("RemoteFunction", "VehicleSpawn") -- (id) -> ok, message
local VehicleStore = Net.remote("RemoteFunction", "VehicleStore") -- () -> ok, message
local VehicleLights = Net.remote("RemoteEvent", "VehicleLights") -- () toggles headlights of the car you drive

local function section(player: Player)
	return PlayerData.section(player, "vehicles")
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function setOwner(part: BasePart, player: Player?)
	if part.Anchored or not part:IsDescendantOf(workspace) then
		return
	end
	pcall(function()
		part:SetNetworkOwner(player)
	end)
end

local function eject(seat: Seat | VehicleSeat, humanoid: Humanoid)
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	humanoid.Sit = false
end

-- Server-side sit. Seats have CanTouch off; if a Sit call ever fails to take,
-- touch is opened for a moment as a fallback.
local function sitIn(seat: Seat | VehicleSeat, humanoid: Humanoid)
	seat:Sit(humanoid)
	task.delay(0.35, function()
		if seat.Parent and humanoid.Parent and humanoid.Health > 0 and humanoid.SeatPart == nil and seat.Occupant == nil then
			seat.CanTouch = true
			seat:Sit(humanoid)
			task.delay(1, function()
				if seat.Parent then
					seat.CanTouch = false
				end
			end)
		end
	end)
end

local function clearDriving(v: Active)
	local driver = v.driver
	v.driver = nil
	if driver then
		driver:SetAttribute("Driving", "")
	end
end

local function onDriverSeat(v: Active)
	local humanoid = v.seat.Occupant
	local player = humanoid and Players:GetPlayerFromCharacter(humanoid.Parent)
	if humanoid and player ~= v.owner then
		eject(v.seat, humanoid)
		if player then
			Net.notify(player, "NOT YOUR RIDE", "Only " .. v.owner.DisplayName .. " can drive this. Use Ride to hop in.")
		end
		return
	end
	if player then
		v.driver = player
		player:SetAttribute("Driving", v.spec.kind)
		v.restTime = 0
		v.chassis.Anchored = false
		setOwner(v.chassis, player)
	else
		clearDriving(v)
		setOwner(v.chassis, nil)
		VC.idle(v.sim)
	end
end

local function despawn(player: Player)
	local v = active[player]
	if not v then
		return
	end
	active[player] = nil
	byModel[v.model] = nil
	for _, seat in v.seats do
		local humanoid = seat.Occupant
		if humanoid then
			eject(seat, humanoid)
		end
	end
	clearDriving(v)
	v.model:Destroy()
	if player.Parent then
		player:SetAttribute("VehicleSpawned", "")
	end
end

local function refreshIgnore()
	local list = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	ignoreList = list
	for _, v in active do
		VC.setIgnore(v.sim, list)
	end
end

local function inCity(pos: Vector3): boolean
	local lo, hi = VC.CITY_MIN, VC.CITY_MAX
	return pos.X > lo.X and pos.X < hi.X and pos.Z > lo.Z and pos.Z < hi.Z and pos.Y > lo.Y and pos.Y < hi.Y
end

local ROAD_NAMES = { MainRoad = "x", CrossRoad = "z", Lot = "any" }

-- Finds a clear, ground-level spot near the player. Prefers roads, and lines
-- the vehicle up with the road it lands on.
local function findSpot(player: Player, s: Spec): CFrame?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or not character then
		return nil
	end
	local origin = root.Position
	local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if lookFlat.Magnitude < 0.1 then
		lookFlat = -Vector3.zAxis
	end
	lookFlat = lookFlat.Unit

	-- selene: allow(undefined_variable)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local rayIgnore = table.clone(ignoreList)
	if active[player] then
		table.insert(rayIgnore, active[player].model)
	end
	rayParams.FilterDescendantsInstances = rayIgnore
	rayParams.RespectCanCollide = true
	-- selene: allow(undefined_variable)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { character }
	if active[player] then
		table.insert(exclude, active[player].model) -- it gets replaced anyway
	end
	overlap.FilterDescendantsInstances = exclude
	overlap.RespectCanCollide = true

	local boxBottom, boxTop = 0.9, s.height + 0.4
	local boxSize = Vector3.new(s.width + 1.2, boxTop - boxBottom, s.length + 1.2)
	local best: CFrame? = nil
	local bestScore = math.huge
	for _, ring in { 6, 9, 13, 18, 24, 31, 40 } do
		local d = ring + s.length * 0.3
		for i = 0, 15 do
			local angle = i / 16 * math.pi * 2
			local p = origin + Vector3.new(math.cos(angle) * d, 0, math.sin(angle) * d)
			if not inCity(Vector3.new(p.X, 1, p.Z)) then
				continue
			end
			local hit = workspace:Raycast(Vector3.new(p.X, 80, p.Z), Vector3.new(0, -120, 0), rayParams)
			if not hit or hit.Position.Y > 1.2 or hit.Position.Y < -1 then
				continue -- roof, interior or nothing: only ground level counts
			end
			local road = ROAD_NAMES[hit.Instance.Name]
			local dir = lookFlat
			if road == "x" then
				dir = Vector3.new(if lookFlat.X < 0 then -1 else 1, 0, 0)
			elseif road == "z" then
				dir = Vector3.new(0, 0, if lookFlat.Z < 0 then -1 else 1)
			end
			local ground = hit.Position
			local cf = CFrame.lookAt(ground, ground + dir)
			local boxCF = cf * CFrame.new(0, (boxBottom + boxTop) / 2, 0)
			if #workspace:GetPartBoundsInBox(boxCF, boxSize, overlap) == 0 then
				local score = (ground - origin).Magnitude - (if road then 15 else 0)
				if score < bestScore then
					bestScore = score
					best = cf
				end
			end
		end
		if best and bestScore < ring then
			break -- good enough, no need to look further out
		end
	end
	return best
end

local function spawnVehicle(player: Player, id: string): (boolean, string)
	local s = VC.byId[id]
	local sec = section(player)
	if not s or not sec or not sec.owned[id] then
		return false, "You don't own that vehicle."
	end
	local humanoid = humanoidOf(player)
	if not humanoid or not Net.alive(player) then
		return false, "You can't do that right now."
	end
	if (player:GetAttribute("Interior") or "") ~= "" then
		return false, "Head outside first. Vehicles can only be brought to the street."
	end
	local root = (player.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart
	if not inCity(root.Position) then
		return false, "You need to be out in the city to call a vehicle."
	end
	if humanoid.SeatPart then
		return false, "Hop out of your seat first."
	end
	local now = os.clock()
	local wait = (lastSpawn[player] or -math.huge) + VC.SPAWN_COOLDOWN - now
	if wait > 0 then
		return false, string.format("Your valet needs %ds more.", math.ceil(wait))
	end
	local spot = findSpot(player, s)
	if not spot then
		return false, "No room to park here. Try an open street or parking lot."
	end
	lastSpawn[player] = now
	despawn(player)

	local look = sec.owned[id]
	local model = buildVehicle(s, { paint = look.paint, rim = look.rim, glow = look.glow }, false)
	model.Name = player.Name .. "_" .. s.id
	model:SetAttribute("Owner", player.UserId)
	model:SetAttribute("OwnerName", player.DisplayName)
	model:SetAttribute("Headlights", false)
	model:PivotTo(spot * CFrame.new(0, VC.groundOffset(s) + 0.1, 0))
	model.Parent = activeFolder
	CollectionService:AddTag(model, TAG)

	local chassis = model.PrimaryPart :: BasePart
	local seats = {}
	for _, d in model:GetChildren() do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then
			d.CanTouch = false
			table.insert(seats, d)
		end
	end
	local sim = VC.newSim(model) :: VC.Sim
	local v: Active = {
		owner = player,
		id = id,
		spec = s,
		model = model,
		chassis = chassis,
		seat = model:FindFirstChild("DriverSeat") :: VehicleSeat,
		seats = seats,
		sim = sim,
		driver = nil,
		override = false,
		restTime = 0,
		overspeed = 0,
	}
	VC.setIgnore(sim, ignoreList)
	active[player] = v
	byModel[model] = v

	v.seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if byModel[model] == v then
			onDriverSeat(v)
		end
	end)

	local drive = model:FindFirstChild("DrivePrompt", true) :: ProximityPrompt?
	if drive then
		drive.Triggered:Connect(function(who: Player)
			if who ~= v.owner then
				Net.notify(who, "NOT YOUR RIDE", "Only the owner can drive this.")
				return
			end
			local h = humanoidOf(who)
			if not h or h.SeatPart or v.seat.Occupant or Net.distance(who, chassis.Position) > s.length / 2 + 12 then
				return
			end
			sitIn(v.seat, h)
		end)
	end
	local ride = model:FindFirstChild("RidePrompt", true) :: ProximityPrompt?
	if ride then
		ride.Triggered:Connect(function(who: Player)
			local h = humanoidOf(who)
			if not h or h.SeatPart or Net.distance(who, chassis.Position) > s.length / 2 + 12 then
				return
			end
			for _, seat in seats do
				if seat:IsA("Seat") and seat.Occupant == nil then
					sitIn(seat, h)
					return
				end
			end
			Net.notify(who, "FULL", "Every passenger seat is taken.")
		end)
	end

	sec.last = id
	PlayerData.markChanged(player)
	player:SetAttribute("VehicleSpawned", id)
	return true, s.name .. " is parked nearby. Walk up and press Drive."
end

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local function validIndex(n: any, list: { any }): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n >= 1 and n <= #list
end

VehicleBuy.OnServerInvoke = function(player: Player, id: any, paintIndex: any)
	if not Net.allow(player, "VehicleBuy", 1) then
		return false, "Slow down."
	end
	if type(id) ~= "string" or not VC.byId[id] then
		return false, "Unknown vehicle."
	end
	if not validIndex(paintIndex, VC.PAINTS) then
		paintIndex = VC.byId[id].defaultPaint
	end
	local s = VC.byId[id]
	local sec = section(player)
	local data = PlayerData.get(player)
	if not sec or not data then
		return false, "Your save is still loading."
	end
	if (player:GetAttribute("Interior") or "") ~= "" or Net.distance(player, VC.LOT_CENTER) > VC.SHOP_RANGE then
		return false, "You need to be at Budget Wheels to buy."
	end
	if sec.owned[id] then
		return false, "You already own the " .. s.name .. "."
	end
	if data.level < s.level or data.reputation < s.rep then
		return false, "Locked. Requires " .. (VC.requirementText(s) or "") .. "."
	end
	if not PlayerData.spendCash(player, s.price, "Bought " .. s.name) then
		return false, "You need " .. money(s.price) .. " for the " .. s.name .. "."
	end
	sec.owned[id] = { paint = paintIndex, rim = 1, glow = 1, t = os.time() }
	PlayerData.markChanged(player)
	PlayerData.addXP(player, 25)
	Net.notify(player, "NEW RIDE", "You bought the " .. s.name .. "! Spawn it from the Garage app on your phone.")
	return true, "Purchased"
end

local MOD_LISTS = { paint = VC.PAINTS, rim = VC.RIMS, glow = VC.GLOWS }

VehicleMod.OnServerInvoke = function(player: Player, id: any, modType: any, index: any)
	if not Net.allow(player, "VehicleMod", 0.5) then
		return false, "Slow down."
	end
	if type(id) ~= "string" or type(modType) ~= "string" or not MOD_LISTS[modType] then
		return false, "Invalid request."
	end
	local list = MOD_LISTS[modType]
	if not validIndex(index, list) then
		return false, "Invalid option."
	end
	local sec = section(player)
	local entry = sec and sec.owned[id]
	local s = VC.byId[id]
	if not entry or not s then
		return false, "You don't own that vehicle."
	end
	if (player:GetAttribute("Interior") or "") ~= "" or Net.distance(player, VC.MODS_POS) > VC.MODS_RANGE then
		return false, "Visit the Paint & Mods bay at Budget Wheels."
	end
	if entry[modType] == index then
		return false, "Already fitted."
	end
	local price = VC.MOD_PRICES[modType]
	local label = (if modType == "paint" then "Paint job: " elseif modType == "rim" then "Rims: " else "Underglow: ") .. list[index].name
	if not PlayerData.spendCash(player, price, label .. " (" .. s.name .. ")") then
		return false, "You need $" .. price .. "."
	end
	entry[modType] = index
	PlayerData.markChanged(player)
	local v = active[player]
	if v and v.id == id then
		applyLook(v.model, { paint = entry.paint, rim = entry.rim, glow = entry.glow })
	end
	Net.notify(player, "PAINT & MODS", label .. " fitted to your " .. s.name .. ".")
	return true, "Done"
end

VehicleSpawn.OnServerInvoke = function(player: Player, id: any)
	if not Net.allow(player, "VehicleSpawn", 1) then
		return false, "Slow down."
	end
	if type(id) ~= "string" then
		return false, "Invalid request."
	end
	local ok, message = spawnVehicle(player, id)
	Net.notify(player, "GARAGE", message)
	return ok, message
end

VehicleStore.OnServerInvoke = function(player: Player)
	if not Net.allow(player, "VehicleStore", 1) then
		return false, "Slow down."
	end
	if not active[player] then
		return false, "Nothing is out."
	end
	local name = active[player].spec.name
	despawn(player)
	Net.notify(player, "GARAGE", "Your " .. name .. " was put away.")
	return true, "Stored"
end

VehicleLights.OnServerEvent:Connect(function(player: Player)
	if not Net.allow(player, "VehicleLights", 0.25) then
		return
	end
	local v = active[player]
	if v and v.driver == player then
		v.model:SetAttribute("Headlights", not v.model:GetAttribute("Headlights"))
	end
end)

---------------------------------------------------------------------------
-- Public API (used by Jobs)
---------------------------------------------------------------------------
-- The CityGrind vehicle the player is currently driving, if any.
function Vehicles.drivingVehicle(player: Player): Model?
	local v = active[player]
	if v and v.driver == player and v.model.Parent then
		return v.model
	end
	return nil
end

-- Distinct kinds ("Bike", "Scooter", "Motorcycle", "Car") the player owns.
function Vehicles.ownedKinds(player: Player): { string }
	local sec = section(player)
	local kinds = {}
	if sec then
		for id in sec.owned do
			local s = VC.byId[id]
			if s and not table.find(kinds, s.kind) then
				table.insert(kinds, s.kind)
			end
		end
	end
	return kinds
end

---------------------------------------------------------------------------
-- Showroom and Paint & Mods bay
---------------------------------------------------------------------------
local function worldPart(props: { name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?, collide: boolean?, parent: Instance, shape: Enum.PartType? }): Part
	local p = Instance.new("Part")
	p.Name = props.name
	p.Anchored = true
	p.Size = props.size
	p.CFrame = props.cframe
	p.Color = props.color
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.CanCollide = if props.collide == nil then true else props.collide
	if props.shape then
		p.Shape = props.shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = props.parent
	return p
end

local function textOn(part: BasePart, lines: { { text: string, size: number, color: Color3, font: Enum.Font? } })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = part
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = gui
	for i, line in lines do
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -10, 0, line.size + 4)
		label.Text = line.text
		label.TextSize = line.size
		label.TextColor3 = line.color
		label.Font = line.font or Enum.Font.GothamBold
		label.LayoutOrder = i
		label.Parent = gui
	end
end

local function buildShowroom(root: Folder)
	local showroom = Instance.new("Folder")
	showroom.Name = "Showroom"
	showroom.Parent = root
	local lotY = VC.LOT_Y
	for i, s in VC.CATALOG do
		local x = VC.LOT_CENTER.X - 31.5 + (i - 1) * 9
		local z = VC.LOT_CENTER.Z - 6
		local model = buildVehicle(s, { paint = s.defaultPaint, rim = 1, glow = 1 }, true)
		model.Name = "Display_" .. s.id
		model:PivotTo(CFrame.new(x, lotY + VC.groundOffset(s), z))
		model.Parent = showroom

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ViewPrompt"
		prompt.ActionText = "View"
		prompt.ObjectText = s.name .. "  ·  " .. money(s.price)
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance = math.max(10, s.length / 2 + 4)
		prompt.RequiresLineOfSight = false
		prompt.Parent = model.PrimaryPart
		prompt.Triggered:Connect(function(player: Player)
			if Net.allow(player, "VehicleView", 0.4) and Net.distance(player, (model.PrimaryPart :: BasePart).Position) < 25 then
				VehicleUI:FireClient(player, "Shop", s.id)
			end
		end)

		-- price sign in front of each car
		local signZ = z - 9.4
		local board = worldPart({ name = "PriceSign", size = Vector3.new(6.6, 2.4, 0.25), cframe = CFrame.new(x, lotY + 1.9, signZ), color = Color3.fromRGB(20, 20, 26), parent = showroom })
		for _, dx in { -2.9, 2.9 } do
			worldPart({ name = "SignLeg", size = Vector3.new(0.2, 0.8, 0.2), cframe = CFrame.new(x + dx, lotY + 0.4, signZ), color = Color3.fromRGB(60, 60, 66), material = Enum.Material.Metal, parent = showroom })
		end
		local lines = {
			{ text = s.name:upper(), size = 28, color = Color3.fromRGB(255, 255, 255), font = Enum.Font.GothamBlack },
			{ text = money(s.price), size = 26, color = Color3.fromRGB(110, 230, 120), font = Enum.Font.GothamBlack },
			{ text = string.format("%d MPH  ·  %d seat%s  ·  %s", math.floor(s.topSpeed * VC.MPH_PER_STUD), s.seats, if s.seats == 1 then "" else "s", s.class), size = 16, color = Color3.fromRGB(190, 190, 200) },
		}
		local req = VC.requirementText(s)
		if req then
			table.insert(lines, { text = "REQUIRES " .. req:upper(), size = 14, color = Color3.fromRGB(255, 170, 60) })
		end
		textOn(board, lines)
	end

	-- Paint & Mods bay: a canopy with a kiosk on the west side of the lot.
	local bay = Instance.new("Model")
	bay.Name = "PaintAndMods"
	bay.Parent = root
	local c = VC.MODS_POS
	worldPart({ name = "BayFloor", size = Vector3.new(18, 0.06, 16), cframe = CFrame.new(c.X, c.Y + 0.03, c.Z), color = Color3.fromRGB(40, 70, 120), material = Enum.Material.Concrete, collide = false, parent = bay })
	for _, dx in { -8.5, 8.5 } do
		for _, dz in { -7.5, 7.5 } do
			worldPart({ name = "Post", size = Vector3.new(0.6, 11, 0.6), cframe = CFrame.new(c.X + dx, c.Y + 5.5, c.Z + dz), color = Color3.fromRGB(50, 50, 56), material = Enum.Material.Metal, parent = bay })
		end
	end
	worldPart({ name = "Canopy", size = Vector3.new(19, 0.6, 17), cframe = CFrame.new(c.X, c.Y + 11.3, c.Z), color = Color3.fromRGB(230, 230, 235), material = Enum.Material.Metal, parent = bay })
	local board = worldPart({ name = "BaySign", size = Vector3.new(13, 2.4, 0.3), cframe = CFrame.new(c.X, c.Y + 9.6, c.Z - 8.6), color = Color3.fromRGB(20, 20, 26), parent = bay })
	textOn(board, {
		{ text = "PAINT & MODS", size = 56, color = Color3.fromRGB(255, 120, 200), font = Enum.Font.GothamBlack },
		{ text = "Paint $150  ·  Rims $250  ·  Underglow $400", size = 26, color = Color3.fromRGB(230, 230, 235) },
	})
	local lamp = worldPart({ name = "BayLight", size = Vector3.new(8, 0.2, 2), cframe = CFrame.new(c.X, c.Y + 10.9, c.Z), color = Color3.fromRGB(255, 250, 235), material = Enum.Material.Neon, collide = false, parent = bay })
	local light = Instance.new("PointLight")
	light.Range = 22
	light.Brightness = 1.4
	light.Parent = lamp
	-- paint cans on a shelf at the back
	worldPart({ name = "Shelf", size = Vector3.new(10, 3, 1.2), cframe = CFrame.new(c.X, c.Y + 1.5, c.Z + 7.2), color = Color3.fromRGB(70, 60, 50), material = Enum.Material.Wood, parent = bay })
	for i, p in VC.PAINTS do
		worldPart({ name = "PaintCan", size = Vector3.new(0.9, 0.8, 0.8), cframe = CFrame.new(c.X - 4.4 + (i - 1) * 1.25, c.Y + 3.45, c.Z + 7.2) * CFrame.Angles(0, 0, math.pi / 2), color = p.color, shape = Enum.PartType.Cylinder, parent = bay })
	end
	local kiosk = worldPart({ name = "Kiosk", size = Vector3.new(2.6, 4, 1.4), cframe = CFrame.new(c.X - 6, c.Y + 2, c.Z - 6), color = Color3.fromRGB(30, 30, 36), material = Enum.Material.Metal, parent = bay })
	worldPart({ name = "KioskScreen", size = Vector3.new(2.1, 1.4, 0.1), cframe = CFrame.new(c.X - 6, c.Y + 3.1, c.Z - 6.72), color = Color3.fromRGB(255, 120, 200), material = Enum.Material.Neon, collide = false, parent = bay })
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ModsPrompt"
	prompt.ActionText = "Customize"
	prompt.ObjectText = "Paint & Mods"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = kiosk
	prompt.Triggered:Connect(function(player: Player)
		if Net.allow(player, "VehicleModsOpen", 0.4) and Net.distance(player, kiosk.Position) < 20 then
			VehicleUI:FireClient(player, "Mods")
		end
	end)
end

---------------------------------------------------------------------------
-- Simulation of empty vehicles, parking, and speed sanity
---------------------------------------------------------------------------
local function physicsStep(dt: number)
	for _, v in active do
		local chassis = v.chassis
		if chassis.Anchored or not chassis.Parent then
			continue
		end
		if v.driver == nil or v.override then
			VC.step(v.sim, dt, 0, 0, false)
			local still = chassis.AssemblyLinearVelocity.Magnitude < 0.5 and chassis.AssemblyAngularVelocity.Magnitude < 0.3
			if still and v.sim.grounded == #v.sim.susp and chassis.CFrame.UpVector.Y > 0.9 then
				v.restTime += dt
			else
				v.restTime = 0
			end
			if v.driver == nil and v.restTime > 1.2 then
				-- parked: anchoring costs nothing to simulate or replicate
				VC.idle(v.sim)
				chassis.AssemblyLinearVelocity = Vector3.zero
				chassis.AssemblyAngularVelocity = Vector3.zero
				chassis.Anchored = true
				v.restTime = 0
			end
		end
	end
end

local function sanityStep(dt: number)
	for owner, v in active do
		local chassis = v.chassis
		if not chassis.Parent then
			despawn(owner)
			continue
		end
		local pos = chassis.Position
		local wlo, whi = VC.WORLD_MIN, VC.WORLD_MAX
		if pos.Y < wlo.Y or pos.Y > whi.Y or pos.X < wlo.X or pos.X > whi.X or pos.Z < wlo.Z or pos.Z > whi.Z or (pos.Z > 525 and pos.Y < -6) then
			despawn(owner)
			Net.notify(owner, "GARAGE", "Your vehicle was towed back to the garage.")
			continue
		end
		if v.driver and not v.override and not chassis.Anchored then
			local vel = chassis.AssemblyLinearVelocity
			local flat = Vector3.new(vel.X, 0, vel.Z).Magnitude
			if flat > v.spec.topSpeed * 1.5 + 8 or math.abs(vel.Y) > 160 then
				v.overspeed += dt
			else
				v.overspeed = math.max(0, v.overspeed - dt * 0.5)
			end
			if v.overspeed > 2 then
				-- the driver's client owns the physics; take it back and stop the car
				v.overspeed = 0
				v.override = true
				setOwner(chassis, nil)
				chassis.AssemblyLinearVelocity = Vector3.zero
				chassis.AssemblyAngularVelocity = Vector3.zero
				Net.notify(v.driver, "SLOW DOWN", "Your vehicle was moving impossibly fast and was stopped.")
				task.delay(1.5, function()
					if byModel[v.model] == v then
						v.override = false
						if v.driver and not chassis.Anchored then
							setOwner(chassis, v.driver)
						end
					end
				end)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Vehicles.start(city: Instance)
	local old = city:FindFirstChild("Vehicles")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "Vehicles"
	root.Parent = city
	activeFolder = Instance.new("Folder")
	activeFolder.Name = "Active"
	activeFolder.Parent = root
	buildShowroom(root)
	Places.mapPoint(city, "Paint & Mods", "Shop", VC.MODS_POS + Vector3.new(0, 3, -10))

	PlayerData.onPublish(function(player: Player, data: any)
		local sec = data.sections and data.sections.vehicles
		if sec then
			local ok, json = pcall(HttpService.JSONEncode, HttpService, sec.owned)
			if ok and player:GetAttribute("VehiclesOwned") ~= json then
				player:SetAttribute("VehiclesOwned", json)
			end
		end
	end)

	local function onPlayer(player: Player)
		player:SetAttribute("Driving", "")
		player:SetAttribute("VehicleSpawned", "")
		player.CharacterRemoving:Connect(function()
			local v = active[player]
			if v and v.driver == player then
				clearDriving(v)
				setOwner(v.chassis, nil)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		despawn(player)
		lastSpawn[player] = nil
	end)

	RunService.PreSimulation:Connect(physicsStep)
	RunService.Heartbeat:Connect(sanityStep)
	task.spawn(function()
		while true do
			refreshIgnore()
			task.wait(1)
		end
	end)
end

return Vehicles
