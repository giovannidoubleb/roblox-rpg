-- CITY GRIND: homes and furniture (spec sections 48, 73, 77, 110).
-- Shared by the server (which owns every rule) and the client (which uses the
-- same numbers to colour the placement preview). The server never accepts a
-- size, price or position rule from a client: it reads this module's tables.
--
-- Units are built relative to an origin whose floor-1 top surface is y = 0.
-- +x east, +z south. The exit door is always in the middle of the south wall.

local ApartmentsConfig = {}

-- Where Maple Court's front door is (the GPS target) and the realty kiosk.
ApartmentsConfig.HOME_GPS = Vector3.new(-100, 3, -58)
ApartmentsConfig.REALTY_POS = Vector3.new(-126, 0, -56)
ApartmentsConfig.OUTSIDE = CFrame.lookAt(Vector3.new(-100, 0, -58), Vector3.new(-100, 0, -50))

ApartmentsConfig.MAX_PER_ITEM = 20 -- how many of one furniture item a player may own

---------------------------------------------------------------------------
-- Home tiers
---------------------------------------------------------------------------
export type Rect = { f: number, x0: number, z0: number, x1: number, z1: number, kind: string?, label: string? }
export type Zone = { f: number, y: number, x0: number, z0: number, x1: number, z1: number }
export type Tier = {
	id: string,
	name: string,
	price: number,
	level: number,
	reputation: number,
	description: string,
	width: number,
	depth: number,
	height: number,
	maxItems: number,
	zones: { Zone },
	blocked: { Rect },
	style: { [string]: any },
}

ApartmentsConfig.TIERS = {
	{
		id = "Studio",
		name = "Studio",
		price = 0,
		level = 1,
		reputation = 0,
		description = "One cosy room at Maple Court. Bed, lamp and a kitchenette. Yours from day one.",
		width = 30,
		depth = 24,
		height = 12,
		maxItems = 12,
		zones = { { f = 1, y = 0, x0 = -15, z0 = -12, x1 = 15, z1 = 12 } },
		blocked = {
			{ f = 1, x0 = -15, z0 = -12, x1 = -5, z1 = -9.5, kind = "kitchen", label = "the kitchenette" },
			{ f = 1, x0 = -4, z0 = 8, x1 = 4, z1 = 12, kind = "door", label = "the doorway" },
		},
		style = {
			floorColor = Color3.fromRGB(176, 136, 98), floorMat = Enum.Material.WoodPlanks,
			wallColor = Color3.fromRGB(226, 214, 192), wallMat = Enum.Material.SmoothPlastic,
			accentColor = Color3.fromRGB(150, 80, 60), accentMat = Enum.Material.Brick,
			north = "window", east = "solid", west = "accent",
			cabinet = Color3.fromRGB(235, 235, 230), counter = Color3.fromRGB(70, 70, 75),
		},
	},
	{
		id = "Apartment",
		name = "Apartment",
		price = 15_000,
		level = 1,
		reputation = 0,
		description = "Living room, separate bedroom and a real kitchen. Room for 22 pieces.",
		width = 44,
		depth = 32,
		height = 12,
		maxItems = 22,
		zones = { { f = 1, y = 0, x0 = -22, z0 = -16, x1 = 22, z1 = 16 } },
		blocked = {
			{ f = 1, x0 = 7.5, z0 = -16, x1 = 8.5, z1 = 4, kind = "wall", label = "a wall" },
			{ f = 1, x0 = -22, z0 = -16, x1 = -8, z1 = -13.5, kind = "kitchen", label = "the kitchen" },
			{ f = 1, x0 = -4, z0 = 12, x1 = 4, z1 = 16, kind = "door", label = "the doorway" },
		},
		style = {
			floorColor = Color3.fromRGB(120, 84, 58), floorMat = Enum.Material.WoodPlanks,
			wallColor = Color3.fromRGB(238, 238, 236), wallMat = Enum.Material.SmoothPlastic,
			accentColor = Color3.fromRGB(40, 120, 130), accentMat = Enum.Material.SmoothPlastic,
			north = "window", east = "window", west = "accent",
			cabinet = Color3.fromRGB(45, 60, 80), counter = Color3.fromRGB(225, 225, 225),
		},
	},
	{
		id = "Luxury",
		name = "Luxury Apartment",
		price = 75_000,
		level = 15,
		reputation = 0,
		description = "Marble floors, floor-to-ceiling windows, kitchen island and a fireplace.",
		width = 56,
		depth = 40,
		height = 14,
		maxItems = 32,
		zones = { { f = 1, y = 0, x0 = -28, z0 = -20, x1 = 28, z1 = 20 } },
		blocked = {
			{ f = 1, x0 = 13.5, z0 = -20, x1 = 14.5, z1 = 2, kind = "wall", label = "a wall" },
			{ f = 1, x0 = -28, z0 = -20, x1 = -8, z1 = -17.5, kind = "kitchen", label = "the kitchen" },
			{ f = 1, x0 = -21, z0 = -8, x1 = -11, z1 = -4, kind = "island", label = "the island" },
			{ f = 1, x0 = -28, z0 = 2, x1 = -25, z1 = 10, kind = "fireplace", label = "the fireplace" },
			{ f = 1, x0 = -4, z0 = 16, x1 = 4, z1 = 20, kind = "door", label = "the doorway" },
		},
		style = {
			floorColor = Color3.fromRGB(232, 230, 226), floorMat = Enum.Material.Marble,
			wallColor = Color3.fromRGB(210, 210, 214), wallMat = Enum.Material.SmoothPlastic,
			accentColor = Color3.fromRGB(55, 55, 62), accentMat = Enum.Material.Slate,
			north = "tall", east = "tall", west = "accent",
			cabinet = Color3.fromRGB(30, 30, 34), counter = Color3.fromRGB(240, 240, 240),
		},
	},
	{
		id = "Penthouse",
		name = "Penthouse",
		price = 300_000,
		level = 35,
		reputation = 1000,
		description = "Top floor. Glass walls with a sky view, hot tub, neon trim. Room for 45 pieces.",
		width = 72,
		depth = 52,
		height = 16,
		maxItems = 45,
		zones = { { f = 1, y = 0, x0 = -36, z0 = -26, x1 = 36, z1 = 26 } },
		blocked = {
			{ f = 1, x0 = 19.5, z0 = -26, x1 = 20.5, z1 = -2, kind = "wall", label = "a wall" },
			{ f = 1, x0 = -36, z0 = 23.5, x1 = -16, z1 = 26, kind = "kitchen", label = "the kitchen" },
			{ f = 1, x0 = -29, z0 = 12, x1 = -19, z1 = 16, kind = "island", label = "the island" },
			{ f = 1, x0 = 24, z0 = 14, x1 = 34, z1 = 24, kind = "hottub", label = "the hot tub" },
			{ f = 1, x0 = -4, z0 = 22, x1 = 4, z1 = 26, kind = "door", label = "the doorway" },
		},
		style = {
			floorColor = Color3.fromRGB(40, 40, 46), floorMat = Enum.Material.Marble,
			wallColor = Color3.fromRGB(30, 30, 36), wallMat = Enum.Material.SmoothPlastic,
			accentColor = Color3.fromRGB(30, 30, 36), accentMat = Enum.Material.SmoothPlastic,
			north = "glass", east = "glass", west = "glass",
			neon = Color3.fromRGB(170, 90, 255),
			cabinet = Color3.fromRGB(240, 240, 244), counter = Color3.fromRGB(25, 25, 28),
		},
	},
	{
		id = "Mansion",
		name = "Mansion",
		price = 1_500_000,
		level = 60,
		reputation = 2500,
		description = "Two floors, indoor pool, your own half-court and a glass atrium. 70 pieces.",
		width = 96,
		depth = 72,
		height = 31, -- outer walls; the upper floor's surface is at y = 17
		maxItems = 70,
		zones = {
			{ f = 1, y = 0, x0 = -48, z0 = -36, x1 = 48, z1 = 36 },
			{ f = 2, y = 17, x0 = -48, z0 = 0.5, x1 = 48, z1 = 36 },
		},
		blocked = {
			{ f = 1, x0 = -46, z0 = -34, x1 = -12, z1 = -8, kind = "pool", label = "the pool" },
			{ f = 1, x0 = 11, z0 = -36, x1 = 48, z1 = -3, kind = "court", label = "the court" },
			{ f = 1, x0 = 21, z0 = 22.5, x1 = 48, z1 = 29.5, kind = "stairs", label = "the stairs" },
			{ f = 1, x0 = -48, z0 = 14, x1 = -45.5, z1 = 34, kind = "kitchen", label = "the kitchen" },
			{ f = 1, x0 = -4, z0 = 32, x1 = 4, z1 = 36, kind = "door", label = "the doorway" },
			{ f = 2, x0 = 21, z0 = 22.5, x1 = 48, z1 = 29.5, kind = "stairwell", label = "the stairwell" },
		},
		style = {
			floorColor = Color3.fromRGB(240, 236, 228), floorMat = Enum.Material.Marble,
			upperColor = Color3.fromRGB(150, 110, 75), upperMat = Enum.Material.WoodPlanks,
			wallColor = Color3.fromRGB(236, 228, 210), wallMat = Enum.Material.SmoothPlastic,
			accentColor = Color3.fromRGB(190, 160, 110), accentMat = Enum.Material.Limestone,
			north = "glass", east = "window", west = "window",
			cabinet = Color3.fromRGB(60, 45, 35), counter = Color3.fromRGB(245, 245, 245),
		},
	},
} :: { Tier }

ApartmentsConfig.TIER_BY_ID = {} :: { [string]: Tier }
for i, tier in ApartmentsConfig.TIERS do
	ApartmentsConfig.TIER_BY_ID[tier.id] = tier;
	(tier :: any).order = i
end

function ApartmentsConfig.floorY(tier: Tier, f: number): number?
	for _, zone in tier.zones do
		if zone.f == f then
			return zone.y
		end
	end
	return nil
end

-- Where a player appears inside a unit (relative to the origin), facing north.
function ApartmentsConfig.spawnOffset(tier: Tier): Vector3
	return Vector3.new(0, 0, tier.depth / 2 - 5)
end

---------------------------------------------------------------------------
-- Part helper (also used by the server's room builder)
---------------------------------------------------------------------------
local SMOOTH = Enum.SurfaceType.Smooth

function ApartmentsConfig.part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, props: { [string]: any }?): BasePart
	local className = if props and props.class then props.class else "Part"
	local p = Instance.new(className) :: any
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = SMOOTH
	p.BottomSurface = SMOOTH
	if props then
		for key, value in props do
			if key ~= "class" then
				p[key] = value
			end
		end
	end
	p.Parent = parent
	return p
end

---------------------------------------------------------------------------
-- Furniture builders. Each builds around (0, 0, 0) = centre of its footprint on
-- the floor, front facing -z, inside its own size box.
---------------------------------------------------------------------------
local V = Vector3.new
local at = CFrame.new
local rgb = Color3.fromRGB
local M = Enum.Material
local CYL = { Shape = Enum.PartType.Cylinder }
local BALL = { Shape = Enum.PartType.Ball }
local UP = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis X -> Y
local FORWARD = CFrame.Angles(0, math.pi / 2, 0) -- cylinder axis X -> Z
local SEAT = { class = "Seat" }

local WOOD = rgb(160, 115, 75)
local DARK_WOOD = rgb(85, 58, 40)
local BLACK = rgb(25, 25, 28)
local WHITE = rgb(236, 236, 232)
local STEEL = rgb(150, 150, 158)
local GOLD = rgb(230, 180, 50)

type Add = (name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, props: { [string]: any }?) -> BasePart

local function legs(add: Add, w: number, d: number, h: number, inset: number, color: Color3, thick: number?)
	local t = thick or 0.3
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			add("Leg", V(t, h, t), at(sx * (w / 2 - inset), h / 2, sz * (d / 2 - inset)), color, M.Wood)
		end
	end
end

local function chair(add: Add, cf: CFrame, color: Color3, cushion: Color3)
	for _, sx in { -0.55, 0.55 } do
		for _, sz in { -0.55, 0.55 } do
			add("Leg", V(0.2, 1.45, 0.2), cf * at(sx, 0.725, sz), color, M.Wood)
		end
	end
	add("Seat", V(1.4, 0.3, 1.4), cf * at(0, 1.6, 0), cushion, M.Fabric, SEAT)
	add("ChairBack", V(1.4, 1.7, 0.2), cf * at(0, 2.6, 0.6), color, M.Wood)
end

local function bed(add: Add, w: number, d: number, frame: Color3, sheet: Color3, blanket: Color3, headH: number)
	legs(add, w, d, 0.3, 0.3, DARK_WOOD, 0.4)
	add("Frame", V(w, 0.9, d), at(0, 0.75, 0), frame, M.Wood)
	add("Mattress", V(w - 0.3, 0.8, d - 0.4), at(0, 1.6, -0.1), sheet, M.Fabric)
	add("Blanket", V(w - 0.1, 0.25, d * 0.62), at(0, 2.05, -d * 0.17), blanket, M.Fabric)
	local pillows = if w >= 6 then 2 else 1
	for i = 1, pillows do
		local x = if pillows == 1 then 0 else (i - 1.5) * (w / 2)
		add("Pillow", V(if pillows == 1 then 3 else w / 2 - 0.5, 0.5, 1.2), at(x, 2.25, d / 2 - 1.2), WHITE, M.Fabric)
	end
	add("Headboard", V(w, headH, 0.4), at(0, headH / 2, d / 2 - 0.2), frame, M.Wood)
end

local function surfaceGui(target: BasePart, face: Enum.NormalId, ppsu: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppsu
	gui.LightInfluence = 0
	gui.Parent = target
	return gui
end

local function guiLabel(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3, font: Enum.Font?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = pos
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Font = font or Enum.Font.GothamBlack
	label.Parent = parent
	return label
end

export type Item = {
	id: string,
	name: string,
	price: number,
	category: string,
	size: Vector3, -- footprint X, height Y, footprint Z (rotation 0)
	flat: boolean?, -- rugs: only collide with other flat items
	kind: string?, -- "bed" | "tv" | "lamp" (functional furniture)
	seats: number?,
	build: (Add) -> (),
}

ApartmentsConfig.ITEMS = {
	{
		id = "nightstand", name = "Nightstand", price = 50, category = "Bedroom", size = V(1.6, 2, 1.6),
		build = function(add)
			add("Body", V(1.5, 1.75, 1.5), at(0, 0.875, 0), WOOD, M.Wood)
			add("Top", V(1.6, 0.2, 1.6), at(0, 1.85, 0), DARK_WOOD, M.Wood)
			add("Drawer", V(1.2, 0.55, 0.05), at(0, 1.25, -0.77), rgb(185, 140, 95), M.Wood)
			add("Knob", V(0.2, 0.2, 0.15), at(0, 1.25, -0.85), GOLD, M.Metal)
		end,
	},
	{
		id = "plant", name = "Potted Plant", price = 60, category = "Decor", size = V(2, 4.5, 2),
		build = function(add)
			add("Pot", V(1.6, 1.7, 1.7), at(0, 0.8, 0) * UP, rgb(190, 90, 60), M.Slate, CYL)
			add("Soil", V(0.1, 1.5, 1.5), at(0, 1.62, 0) * UP, rgb(70, 50, 35), M.Ground, CYL)
			add("Stem", V(0.25, 1.5, 0.25), at(0, 2.3, 0), rgb(70, 110, 50), M.Wood)
			add("Leaves", V(2, 1.8, 2), at(0, 3.1, 0), rgb(60, 150, 70), M.Grass, BALL)
			add("Leaves", V(1.3, 1.3, 1.3), at(0.3, 3.8, -0.2), rgb(80, 170, 80), M.Grass, BALL)
			add("Leaves", V(1.1, 1.1, 1.1), at(-0.4, 3.7, 0.3), rgb(50, 135, 60), M.Grass, BALL)
		end,
	},
	{
		id = "beanbag", name = "Beanbag", price = 70, category = "Living", size = V(3, 2.4, 3), seats = 1,
		build = function(add)
			add("Bag", V(3, 1.5, 3), at(0, 0.75, 0), rgb(230, 120, 40), M.Fabric, BALL)
			add("BagBack", V(2.6, 1.7, 1.2), at(0, 1.4, 0.85), rgb(220, 110, 35), M.Fabric, BALL)
			add("Seat", V(1.8, 0.2, 1.8), at(0, 1.3, -0.1), rgb(230, 120, 40), M.Fabric, { class = "Seat", Transparency = 1 })
		end,
	},
	{
		id = "floor_lamp", name = "Floor Lamp", price = 80, category = "Decor", size = V(1.5, 6, 1.5), kind = "lamp",
		build = function(add)
			add("Base", V(0.2, 1.3, 1.3), at(0, 0.1, 0) * UP, BLACK, M.Metal, CYL)
			add("Pole", V(0.18, 4.8, 0.18), at(0, 2.6, 0), BLACK, M.Metal)
			local bulb = add("Bulb", V(0.6, 0.6, 0.6), at(0, 5.1, 0), rgb(255, 235, 190), M.Neon, BALL)
			add("Shade", V(1.3, 1.5, 1.5), at(0, 5.35, 0) * UP, rgb(245, 230, 200), M.Fabric, { Shape = Enum.PartType.Cylinder, Transparency = 0.15 })
			local light = Instance.new("PointLight")
			light.Name = "Light"
			light.Range = 18
			light.Brightness = 1.6
			light.Color = rgb(255, 220, 170)
			light.Parent = bulb
		end,
	},
	{
		id = "rug", name = "Area Rug", price = 90, category = "Decor", size = V(8, 0.12, 6), flat = true,
		build = function(add)
			add("Rug", V(8, 0.08, 6), at(0, 0.04, 0), rgb(150, 40, 50), M.Fabric, { CanCollide = false })
			add("Border", V(7, 0.1, 5), at(0, 0.06, 0), rgb(230, 200, 140), M.Fabric, { CanCollide = false })
			add("Field", V(6.4, 0.12, 4.4), at(0, 0.07, 0), rgb(120, 30, 45), M.Fabric, { CanCollide = false })
			add("Medallion", V(0.13, 2.4, 2.4), at(0, 0.07, 0) * UP, rgb(230, 200, 140), M.Fabric, { Shape = Enum.PartType.Cylinder, CanCollide = false })
		end,
	},
	{
		id = "coffee_table", name = "Coffee Table", price = 120, category = "Living", size = V(5, 1.6, 3),
		build = function(add)
			legs(add, 5, 3, 1.3, 0.3, DARK_WOOD)
			add("Top", V(5, 0.3, 3), at(0, 1.45, 0), WOOD, M.Wood)
			add("Shelf", V(4.4, 0.15, 2.4), at(0, 0.4, 0), DARK_WOOD, M.Wood)
			add("Magazine", V(1.2, 0.05, 1.6), at(-1, 1.62, 0.2), rgb(220, 60, 60), M.SmoothPlastic)
		end,
	},
	{
		id = "basic_bed", name = "Basic Bed", price = 150, category = "Bedroom", size = V(5, 3.5, 7), kind = "bed",
		build = function(add)
			bed(add, 5, 7, rgb(140, 100, 70), rgb(225, 230, 240), rgb(70, 110, 170), 3.5)
		end,
	},
	{
		id = "bar_stools", name = "Bar Stools (2)", price = 160, category = "Kitchen", size = V(4, 3.3, 1.8), seats = 2,
		build = function(add)
			for _, x in { -1, 1 } do
				add("Foot", V(0.15, 1.2, 1.2), at(x, 0.075, 0) * UP, BLACK, M.Metal, CYL)
				add("Post", V(0.25, 2.8, 0.25), at(x, 1.5, 0), STEEL, M.Metal)
				add("Footrest", V(1.1, 0.12, 1.1), at(x, 1.1, 0), STEEL, M.Metal)
				add("Seat", V(1.4, 0.35, 1.4), at(x, 3.05, 0), rgb(200, 40, 40), M.Fabric, SEAT)
			end
		end,
	},
	{
		id = "mirror", name = "Standing Mirror", price = 200, category = "Bedroom", size = V(2.5, 6.5, 1),
		build = function(add)
			add("Frame", V(2.5, 6.2, 0.3), at(0, 3.25, 0), GOLD, M.Metal)
			add("Glass", V(2.1, 5.8, 0.06), at(0, 3.25, -0.17), rgb(200, 215, 230), M.Glass, { Reflectance = 0.9 })
			add("Stand", V(0.2, 0.2, 1), at(-1, 0.1, 0.1), GOLD, M.Metal)
			add("Stand", V(0.2, 0.2, 1), at(1, 0.1, 0.1), GOLD, M.Metal)
		end,
	},
	{
		id = "armchair", name = "Armchair", price = 220, category = "Living", size = V(3.5, 3.6, 3.5), seats = 1,
		build = function(add)
			legs(add, 3.4, 3.4, 0.35, 0.3, DARK_WOOD)
			add("Base", V(3.5, 1, 3.5), at(0, 0.85, 0), rgb(70, 100, 80), M.Fabric)
			add("Seat", V(2.4, 0.5, 2.6), at(0, 1.6, -0.35), rgb(85, 120, 95), M.Fabric, SEAT)
			add("Back", V(3.5, 2.3, 0.7), at(0, 2.4, 1.4), rgb(70, 100, 80), M.Fabric)
			add("Arm", V(0.55, 1.1, 3.5), at(-1.475, 1.9, 0), rgb(70, 100, 80), M.Fabric)
			add("Arm", V(0.55, 1.1, 3.5), at(1.475, 1.9, 0), rgb(70, 100, 80), M.Fabric)
		end,
	},
	{
		id = "wall_art", name = "Gallery Canvas", price = 250, category = "Decor", size = V(5, 8, 0.8),
		build = function(add)
			add("Post", V(0.2, 8, 0.2), at(-2.2, 4, 0.2), DARK_WOOD, M.Wood)
			add("Post", V(0.2, 8, 0.2), at(2.2, 4, 0.2), DARK_WOOD, M.Wood)
			add("Foot", V(5, 0.2, 0.8), at(0, 0.1, 0), DARK_WOOD, M.Wood)
			add("Frame", V(5, 3.6, 0.25), at(0, 5.8, 0), BLACK, M.Wood)
			local canvas = add("Canvas", V(4.6, 3.2, 0.06), at(0, 5.8, -0.14), WHITE, M.SmoothPlastic)
			local gui = surfaceGui(canvas, Enum.NormalId.Front, 40)
			local bg = Instance.new("Frame")
			bg.Size = UDim2.fromScale(1, 1)
			bg.BorderSizePixel = 0
			bg.BackgroundColor3 = Color3.new(1, 1, 1)
			bg.Parent = gui
			local grad = Instance.new("UIGradient")
			grad.Color = ColorSequence.new(rgb(255, 110, 80), rgb(80, 40, 160))
			grad.Rotation = 35
			grad.Parent = bg
			local shapes = {
				{ UDim2.fromScale(0.12, 0.2), UDim2.fromScale(0.34, 0.48), rgb(255, 215, 90), 1 },
				{ UDim2.fromScale(0.5, 0.38), UDim2.fromScale(0.36, 0.5), rgb(40, 200, 200), 0 },
				{ UDim2.fromScale(0.36, 0.08), UDim2.fromScale(0.08, 0.84), rgb(20, 20, 30), 0 },
			}
			for _, s in shapes do
				local f = Instance.new("Frame")
				f.Position = s[1]
				f.Size = s[2]
				f.BackgroundColor3 = s[3]
				f.BorderSizePixel = 0
				f.Parent = bg
				if s[4] == 1 then
					local c = Instance.new("UICorner")
					c.CornerRadius = UDim.new(0.5, 0)
					c.Parent = f
				end
			end
		end,
	},
	{
		id = "mini_fridge", name = "Mini Fridge", price = 300, category = "Kitchen", size = V(2, 3, 2),
		build = function(add)
			add("Body", V(2, 3, 1.9), at(0, 1.5, 0.05), WHITE, M.Metal)
			add("Door", V(1.9, 2.9, 0.1), at(0, 1.5, -0.95), rgb(245, 245, 245), M.Metal)
			add("Handle", V(0.12, 1.2, 0.15), at(0.75, 1.8, -1.0), STEEL, M.Metal)
			add("Logo", V(0.6, 0.15, 0.05), at(-0.3, 2.7, -1.0), rgb(60, 140, 230), M.Neon)
		end,
	},
	{
		id = "bookshelf", name = "Bookshelf", price = 350, category = "Living", size = V(5, 7, 1.5),
		build = function(add)
			add("Back", V(5, 7, 0.15), at(0, 3.5, 0.67), DARK_WOOD, M.Wood)
			add("Side", V(0.2, 7, 1.5), at(-2.4, 3.5, 0), DARK_WOOD, M.Wood)
			add("Side", V(0.2, 7, 1.5), at(2.4, 3.5, 0), DARK_WOOD, M.Wood)
			local bookColors = { rgb(200, 50, 50), rgb(50, 90, 170), rgb(230, 190, 60), rgb(60, 150, 90), rgb(240, 240, 235), rgb(120, 60, 140) }
			for shelf = 0, 4 do
				local y = 0.1 + shelf * 1.7
				add("Shelf", V(4.6, 0.2, 1.4), at(0, y, 0), WOOD, M.Wood)
				if shelf < 4 then
					local x = -2.1
					local n = 0
					while x < 1.6 do
						n += 1
						local w = 0.25 + ((shelf * 7 + n * 3) % 4) * 0.07
						local h = 1.0 + ((shelf * 5 + n * 2) % 5) * 0.08
						add("Book", V(w, h, 1), at(x + w / 2, y + 0.1 + h / 2, -0.05), bookColors[(shelf * 3 + n) % #bookColors + 1], M.SmoothPlastic)
						x += w + 0.04
					end
				end
			end
		end,
	},
	{
		id = "speaker", name = "Speaker Tower", price = 350, category = "Tech", size = V(1.8, 4.5, 1.8),
		build = function(add)
			add("Cabinet", V(1.8, 4.5, 1.8), at(0, 2.25, 0), BLACK, M.SmoothPlastic)
			add("Woofer", V(0.2, 1.4, 1.4), at(0, 1.3, -0.9) * FORWARD, rgb(45, 45, 50), M.Metal, CYL)
			add("Tweeter", V(0.2, 0.7, 0.7), at(0, 3.2, -0.9) * FORWARD, rgb(45, 45, 50), M.Metal, CYL)
			add("Glow", V(0.05, 1.6, 1.6), at(0, 1.3, -0.88) * FORWARD, rgb(60, 200, 255), M.Neon, CYL)
		end,
	},
	{
		id = "dumbbell_rack", name = "Dumbbell Rack", price = 450, category = "Fitness", size = V(5, 3, 2),
		build = function(add)
			add("Frame", V(0.3, 2.6, 1.8), at(-2.3, 1.3, 0), BLACK, M.Metal)
			add("Frame", V(0.3, 2.6, 1.8), at(2.3, 1.3, 0), BLACK, M.Metal)
			add("Rail", V(4.6, 0.2, 0.5), at(0, 1.2, -0.4), BLACK, M.Metal)
			add("Rail", V(4.6, 0.2, 0.5), at(0, 2.4, 0.4), BLACK, M.Metal)
			for i = 0, 3 do
				local x = -1.65 + i * 1.1
				for _, row in { { 1.6, -0.4, 0.55 }, { 2.8, 0.4, 0.75 } } do
					local y, z, r = row[1], row[2], row[3] + i * 0.04
					add("Handle", V(0.12, 0.12, 0.7), at(x, y, z), STEEL, M.Metal)
					add("Plate", V(0.25, r, r), at(x, y, z - 0.35) * FORWARD, rgb(40, 40, 44), M.Metal, CYL)
					add("Plate", V(0.25, r, r), at(x, y, z + 0.35) * FORWARD, rgb(40, 40, 44), M.Metal, CYL)
				end
			end
		end,
	},
	{
		id = "mini_hoop", name = "Mini Hoop", price = 500, category = "Fitness", size = V(3, 8, 2),
		build = function(add)
			add("Base", V(3, 0.6, 2), at(0, 0.3, 0), BLACK, M.Plastic)
			add("Pole", V(0.3, 7, 0.3), at(0, 3.8, 0.7), STEEL, M.Metal)
			add("Board", V(2.8, 1.8, 0.15), at(0, 7.0, 0.45), WHITE, M.SmoothPlastic, { Transparency = 0.1 })
			add("Square", V(1, 0.7, 0.16), at(0, 6.8, 0.45), rgb(220, 60, 40), M.SmoothPlastic)
			for i = 0, 9 do
				local a = i / 10 * math.pi * 2
				add("Rim", V(0.12, 0.08, 0.42), CFrame.new(math.cos(a) * 0.55, 6.4, -0.2 + math.sin(a) * 0.55) * CFrame.Angles(0, -a, 0), rgb(255, 100, 30), M.Metal)
			end
			add("Net", V(0.9, 1.0, 1.0), at(0, 5.9, -0.2) * UP, WHITE, M.Fabric, { Shape = Enum.PartType.Cylinder, Transparency = 0.55, CanCollide = false })
			add("Ball", V(1, 1, 1), at(0.9, 1.1, -0.3), rgb(230, 110, 40), M.Plastic, BALL)
		end,
	},
	{
		id = "wardrobe", name = "Wardrobe", price = 550, category = "Bedroom", size = V(5, 7.5, 2),
		build = function(add)
			add("Body", V(5, 7.2, 2), at(0, 3.75, 0), rgb(235, 230, 220), M.Wood)
			add("Top", V(5.1, 0.3, 2.1), at(0, 7.35, 0), DARK_WOOD, M.Wood)
			add("Plinth", V(4.8, 0.3, 1.8), at(0, 0.15, 0), DARK_WOOD, M.Wood)
			add("Door", V(2.4, 6.8, 0.08), at(-1.23, 3.75, -1.02), rgb(245, 240, 232), M.Wood)
			add("Door", V(2.4, 6.8, 0.08), at(1.23, 3.75, -1.02), rgb(245, 240, 232), M.Wood)
			add("Handle", V(0.12, 1, 0.12), at(-0.2, 3.9, -1.1), GOLD, M.Metal)
			add("Handle", V(0.12, 1, 0.12), at(0.2, 3.9, -1.1), GOLD, M.Metal)
		end,
	},
	{
		id = "neon_sign", name = "Neon Sign", price = 600, category = "Decor", size = V(5, 4.6, 1),
		build = function(add)
			add("Post", V(0.2, 2.2, 0.2), at(-1.8, 1.1, 0.2), BLACK, M.Metal)
			add("Post", V(0.2, 2.2, 0.2), at(1.8, 1.1, 0.2), BLACK, M.Metal)
			add("Foot", V(4.4, 0.15, 1), at(0, 0.075, 0), BLACK, M.Metal)
			local board = add("Board", V(4.8, 2.4, 0.2), at(0, 3.4, 0.2), rgb(15, 15, 18), M.SmoothPlastic)
			add("Tube", V(4.6, 0.1, 0.1), at(0, 4.5, 0.05), rgb(255, 60, 200), M.Neon)
			add("Tube", V(4.6, 0.1, 0.1), at(0, 2.3, 0.05), rgb(255, 60, 200), M.Neon)
			local gui = surfaceGui(board, Enum.NormalId.Front, 40)
			local label = guiLabel(gui, "GRIND", UDim2.fromScale(0.9, 0.8), UDim2.fromScale(0.05, 0.1), rgb(255, 120, 230))
			label.TextStrokeColor3 = rgb(255, 0, 170)
			label.TextStrokeTransparency = 0
			local light = Instance.new("PointLight")
			light.Color = rgb(255, 80, 210)
			light.Range = 14
			light.Brightness = 1.5
			light.Parent = board
		end,
	},
	{
		id = "dining_set", name = "Dining Table + 4 Chairs", price = 650, category = "Kitchen", size = V(7, 3.6, 7), seats = 4,
		build = function(add)
			legs(add, 3.8, 2.8, 2.7, 0.3, DARK_WOOD)
			add("Top", V(4, 0.3, 3), at(0, 2.85, 0), WOOD, M.Wood)
			add("Runner", V(0.8, 0.04, 2.6), at(0, 3.02, 0), rgb(230, 230, 220), M.Fabric)
			local cushion = rgb(180, 160, 120)
			chair(add, at(0, 0, 2.6), DARK_WOOD, cushion) -- faces -z (toward the table)
			chair(add, at(0, 0, -2.6) * CFrame.Angles(0, math.pi, 0), DARK_WOOD, cushion)
			chair(add, at(2.7, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), DARK_WOOD, cushion)
			chair(add, at(-2.7, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), DARK_WOOD, cushion)
		end,
	},
	{
		id = "trophy_shelf", name = "Trophy Shelf", price = 750, category = "Decor", size = V(5, 6, 1.5),
		build = function(add)
			add("Back", V(5, 6, 0.15), at(0, 3, 0.67), rgb(30, 30, 40), M.Wood)
			add("Side", V(0.2, 6, 1.5), at(-2.4, 3, 0), rgb(30, 30, 40), M.Wood)
			add("Side", V(0.2, 6, 1.5), at(2.4, 3, 0), rgb(30, 30, 40), M.Wood)
			for shelf = 0, 3 do
				local y = 0.1 + shelf * 1.95
				add("Shelf", V(4.6, 0.2, 1.4), at(0, y, 0), rgb(50, 50, 62), M.Wood)
				if shelf < 3 then
					for i, x in { -1.4, 0, 1.4 } do
						local s = 0.8 + ((shelf + i) % 3) * 0.15
						add("TrophyBase", V(0.6, 0.3, 0.6), at(x, y + 0.25, 0), BLACK, M.Marble)
						add("TrophyStem", V(0.15, 0.5 * s, 0.15), at(x, y + 0.4 + 0.25 * s, 0), GOLD, M.Metal, { Reflectance = 0.3 })
						add("TrophyCup", V(0.7 * s, 0.6 * s, 0.7 * s), at(x, y + 0.65 + 0.6 * s, 0), GOLD, M.Metal, { Shape = Enum.PartType.Ball, Reflectance = 0.3 })
					end
				end
			end
			local light = Instance.new("SpotLight")
			light.Face = Enum.NormalId.Front
			light.Range = 6
			light.Brightness = 1
			light.Parent = add("Strip", V(4.6, 0.1, 0.1), at(0, 5.8, -0.6), rgb(255, 240, 200), M.Neon)
		end,
	},
	{
		id = "tv", name = "TV + Stand", price = 900, category = "Tech", size = V(7, 7, 2.5), kind = "tv",
		build = function(add)
			add("Stand", V(6.4, 1.8, 2.2), at(0, 0.9, 0.1), DARK_WOOD, M.Wood)
			add("StandDoor", V(3, 1.4, 0.05), at(-1.5, 0.9, -1.0), rgb(110, 80, 55), M.Wood)
			add("StandDoor", V(3, 1.4, 0.05), at(1.5, 0.9, -1.0), rgb(110, 80, 55), M.Wood)
			add("Neck", V(0.8, 1.1, 0.4), at(0, 2.35, 0.5), BLACK, M.Metal)
			add("Bezel", V(6.6, 3.9, 0.3), at(0, 4.85, 0.5), BLACK, M.SmoothPlastic)
			local screen = add("Screen", V(6.3, 3.6, 0.06), at(0, 4.85, 0.33), rgb(10, 10, 14), M.SmoothPlastic)
			local gui = surfaceGui(screen, Enum.NormalId.Front, 50)
			gui.Name = "TVGui"
			local bg = Instance.new("Frame")
			bg.Name = "BG"
			bg.Size = UDim2.fromScale(1, 1)
			bg.BorderSizePixel = 0
			bg.BackgroundColor3 = rgb(20, 30, 80)
			bg.Parent = gui
			guiLabel(bg, "CITY GRIND TV", UDim2.fromScale(0.9, 0.24), UDim2.fromScale(0.05, 0.12), rgb(255, 150, 60)).Name = "Title"
			guiLabel(bg, "Neighborhood Hoops · LIVE", UDim2.fromScale(0.9, 0.16), UDim2.fromScale(0.05, 0.48), Color3.new(1, 1, 1), Enum.Font.GothamBold).Name = "Show"
			guiLabel(bg, "CG1", UDim2.fromScale(0.15, 0.1), UDim2.fromScale(0.82, 0.85), rgb(200, 200, 210), Enum.Font.GothamBold).Name = "Channel"
		end,
	},
	{
		id = "couch", name = "Couch", price = 400, category = "Living", size = V(8, 3.5, 3.5), seats = 3,
		build = function(add)
			legs(add, 7.8, 3.3, 0.35, 0.35, DARK_WOOD)
			add("Base", V(8, 1, 3.5), at(0, 0.85, 0), rgb(60, 70, 95), M.Fabric)
			for _, x in { -2.45, 0, 2.45 } do
				add("Seat", V(2.4, 0.5, 2.6), at(x, 1.6, -0.35), rgb(75, 88, 118), M.Fabric, SEAT)
			end
			add("Back", V(8, 2.1, 0.8), at(0, 2.4, 1.35), rgb(60, 70, 95), M.Fabric)
			add("Arm", V(0.6, 1.1, 3.5), at(-3.7, 1.9, 0), rgb(60, 70, 95), M.Fabric)
			add("Arm", V(0.6, 1.1, 3.5), at(3.7, 1.9, 0), rgb(60, 70, 95), M.Fabric)
			add("Pillow", V(1.4, 1.2, 0.4), at(-2.9, 2.4, 0.75), rgb(230, 190, 80), M.Fabric)
		end,
	},
	{
		id = "kitchen_counter", name = "Kitchen Counter", price = 1_200, category = "Kitchen", size = V(8, 3.6, 2.5),
		build = function(add)
			add("Cabinets", V(8, 3.1, 2.4), at(0, 1.55, 0.05), rgb(60, 80, 100), M.Wood)
			add("Countertop", V(8, 0.3, 2.5), at(0, 3.25, 0), rgb(235, 235, 235), M.Marble)
			for i = 0, 3 do
				add("CabinetDoor", V(1.85, 2.4, 0.05), at(-3 + i * 2, 1.5, -1.17), rgb(75, 100, 125), M.Wood)
				add("Handle", V(0.8, 0.1, 0.1), at(-3 + i * 2, 2.5, -1.23), STEEL, M.Metal)
			end
			add("Sink", V(2, 0.1, 1.4), at(-2, 3.42, 0), STEEL, M.Metal)
			add("Faucet", V(0.15, 0.9, 0.15), at(-2, 3.85, 0.9), STEEL, M.Metal)
			add("Spout", V(0.15, 0.15, 0.7), at(-2, 4.25, 0.6), STEEL, M.Metal)
			add("Cooktop", V(2.6, 0.06, 1.8), at(2, 3.43, 0), BLACK, M.Glass)
			for _, offset in { V(-0.6, 0, -0.4), V(0.6, 0, -0.4), V(-0.6, 0, 0.4), V(0.6, 0, 0.4) } do
				add("Burner", V(0.04, 0.6, 0.6), at(2 + offset.X, 3.47, offset.Z) * UP, rgb(80, 30, 30), M.SmoothPlastic, CYL)
			end
		end,
	},
	{
		id = "gaming_desk", name = "Desk + Gaming Setup", price = 1_800, category = "Tech", size = V(6, 5, 3.6), seats = 1,
		build = function(add)
			add("Top", V(6, 0.25, 2.2), at(0, 2.6, 0.7), BLACK, M.SmoothPlastic)
			add("LegPanel", V(0.2, 2.5, 2), at(-2.8, 1.25, 0.7), BLACK, M.Metal)
			add("LegPanel", V(0.2, 2.5, 2), at(2.8, 1.25, 0.7), BLACK, M.Metal)
			add("RGBStrip", V(5.6, 0.06, 0.06), at(0, 2.45, -0.38), rgb(0, 255, 180), M.Neon)
			for i, x in { -1.25, 1.25 } do
				add("MonitorStand", V(0.3, 0.8, 0.3), at(x, 3.1, 1.3), BLACK, M.Metal)
				add("Monitor", V(2.3, 1.4, 0.15), at(x, 3.9, 1.25) * CFrame.Angles(0, (i - 1.5) * -0.35, 0), BLACK, M.SmoothPlastic)
				add("MonitorScreen", V(2.15, 1.25, 0.04), at(x, 3.9, 1.16) * CFrame.Angles(0, (i - 1.5) * -0.35, 0), if i == 1 then rgb(60, 120, 255) else rgb(255, 80, 160), M.Neon)
			end
			add("Keyboard", V(1.6, 0.08, 0.5), at(0, 2.77, 0.2), rgb(40, 40, 46), M.SmoothPlastic)
			add("KeyGlow", V(1.5, 0.02, 0.4), at(0, 2.82, 0.2), rgb(140, 80, 255), M.Neon)
			add("Mouse", V(0.25, 0.1, 0.4), at(1.2, 2.77, 0.2), rgb(40, 40, 46), M.SmoothPlastic)
			add("Tower", V(0.9, 2, 1.8), at(2.3, 3.73, 0.85), rgb(25, 25, 30), M.SmoothPlastic)
			add("TowerGlass", V(0.05, 1.8, 1.6), at(1.84, 3.73, 0.85), rgb(255, 60, 60), M.Neon, { Transparency = 0.3 })
			-- gaming chair facing the desk (+z)
			local cf = at(0, 0, -1.0) * CFrame.Angles(0, math.pi, 0)
			add("ChairBase", V(0.2, 1.6, 1.6), cf * at(0, 0.1, 0) * UP, BLACK, M.Metal, CYL)
			add("ChairPost", V(0.25, 1.2, 0.25), cf * at(0, 0.8, 0), BLACK, M.Metal)
			add("Seat", V(1.7, 0.4, 1.5), cf * at(0, 1.6, 0), rgb(200, 30, 50), M.Fabric, SEAT)
			add("ChairBack", V(1.7, 2.4, 0.3), cf * at(0, 2.9, 0.65), rgb(200, 30, 50), M.Fabric)
			add("ChairStripe", V(0.4, 2.3, 0.31), cf * at(0, 2.9, 0.65), BLACK, M.Fabric)
		end,
	},
	{
		id = "king_bed", name = "King Bed", price = 2_400, category = "Bedroom", size = V(7, 5, 8), kind = "bed",
		build = function(add)
			bed(add, 7, 8, rgb(60, 60, 70), rgb(245, 245, 250), rgb(150, 30, 60), 5)
			add("HeadboardPanel", V(6, 3.4, 0.2), at(0, 3.2, 3.55), rgb(120, 120, 135), M.Fabric)
		end,
	},
	{
		id = "aquarium", name = "Aquarium", price = 5_000, category = "Decor", size = V(6, 5.6, 2),
		build = function(add)
			add("Cabinet", V(6, 2.4, 2), at(0, 1.2, 0), BLACK, M.Wood)
			add("Gravel", V(5.8, 0.3, 1.8), at(0, 2.55, 0), rgb(210, 190, 150), M.Sand)
			add("Water", V(5.8, 2.6, 1.8), at(0, 3.85, 0), rgb(60, 150, 220), M.Glass, { Transparency = 0.55, CanCollide = false })
			add("Tank", V(6, 3, 2), at(0, 3.9, 0), rgb(200, 230, 255), M.Glass, { Transparency = 0.8 })
			add("Lid", V(6, 0.2, 2), at(0, 5.5, 0), BLACK, M.SmoothPlastic)
			add("Weed", V(0.3, 1.8, 0.3), at(-2.2, 3.5, 0.3), rgb(40, 170, 80), M.Grass)
			add("Weed", V(0.3, 1.3, 0.3), at(2.3, 3.25, -0.2), rgb(50, 190, 90), M.Grass)
			add("Rock", V(1, 0.8, 0.8), at(1.4, 3, 0.4), rgb(110, 110, 120), M.Slate, BALL)
			local fishColors = { rgb(255, 140, 30), rgb(255, 230, 60), rgb(80, 200, 255), rgb(255, 80, 120) }
			for i, c in fishColors do
				local y = 3.1 + (i % 3) * 0.6
				local x = -2 + i * 0.85
				add("Fish", V(0.5, 0.3, 0.15), at(x, y, (i % 2) * 0.5 - 0.25), c, M.Neon)
				add("FishTail", V(0.15, 0.25, 0.1), at(x + 0.32, y, (i % 2) * 0.5 - 0.25), c, M.Neon)
			end
			local light = Instance.new("PointLight")
			light.Color = rgb(90, 170, 255)
			light.Range = 12
			light.Brightness = 1.2
			light.Parent = add("TankLight", V(5.6, 0.05, 0.3), at(0, 5.38, 0), rgb(180, 220, 255), M.Neon)
		end,
	},
} :: { Item }

-- keep the catalog cheapest first
table.sort(ApartmentsConfig.ITEMS, function(a, b)
	return a.price < b.price
end)

ApartmentsConfig.ITEM_BY_ID = {} :: { [string]: Item }
for _, item in ApartmentsConfig.ITEMS do
	ApartmentsConfig.ITEM_BY_ID[item.id] = item
end

-- Builds a fresh furniture model. Its PrimaryPart "Hitbox" is the item's size box,
-- so model:PivotTo(ApartmentsConfig.pieceCFrame(...)) places it.
function ApartmentsConfig.buildItem(itemId: string): Model?
	local item = ApartmentsConfig.ITEM_BY_ID[itemId]
	if not item then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = item.id
	local hitbox = ApartmentsConfig.part(model, "Hitbox", item.size, at(0, item.size.Y / 2, 0), WHITE, M.SmoothPlastic, {
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
		CastShadow = false,
	})
	model.PrimaryPart = hitbox
	item.build(function(name, size, cf, color, material, props)
		return ApartmentsConfig.part(model, name, size, cf, color, material, props)
	end)
	return model
end

---------------------------------------------------------------------------
-- Placement rules (the server runs exactly these)
---------------------------------------------------------------------------
export type Placement = { u: number, id: string, x: number, z: number, f: number, r: number }

local EPS = 0.01

function ApartmentsConfig.footprint(item: Item, r: number): (number, number)
	if r == 90 or r == 270 then
		return item.size.Z, item.size.X
	end
	return item.size.X, item.size.Z
end

local function overlaps(ax0: number, az0: number, ax1: number, az1: number, bx0: number, bz0: number, bx1: number, bz1: number): boolean
	return ax0 < bx1 - EPS and ax1 > bx0 + EPS and az0 < bz1 - EPS and az1 > bz0 + EPS
end

-- World CFrame of a placed piece's Hitbox.
function ApartmentsConfig.pieceCFrame(origin: Vector3, tier: Tier, item: Item, x: number, z: number, f: number, r: number): CFrame
	local y = ApartmentsConfig.floorY(tier, f) or 0
	return CFrame.new(origin + Vector3.new(x, y + item.size.Y / 2, z)) * CFrame.Angles(0, math.rad(r), 0)
end

-- Returns (ok, reason). `placements` are the other pieces in this home;
-- `ignoreUid` skips the piece being moved.
function ApartmentsConfig.validatePlacement(tierId: string, itemId: any, x: any, z: any, f: any, r: any, placements: { Placement }, ignoreUid: number?): (boolean, string?)
	local tier = ApartmentsConfig.TIER_BY_ID[tierId]
	local item = type(itemId) == "string" and ApartmentsConfig.ITEM_BY_ID[itemId]
	if not tier or not item then
		return false, "Unknown item."
	end
	if type(x) ~= "number" or type(z) ~= "number" or type(f) ~= "number" or type(r) ~= "number" then
		return false, "Bad position."
	end
	if x ~= x or z ~= z or math.abs(x) > 500 or math.abs(z) > 500 then
		return false, "Bad position."
	end
	if x % 1 ~= 0 or z % 1 ~= 0 or f % 1 ~= 0 then
		return false, "Not on the grid."
	end
	if r % 90 ~= 0 or r < 0 or r >= 360 then
		return false, "Rotation must be a multiple of 90."
	end
	local sx, sz = ApartmentsConfig.footprint(item, r)
	local x0, x1, z0, z1 = x - sx / 2, x + sx / 2, z - sz / 2, z + sz / 2

	local inside = false
	for _, zone in tier.zones do
		if zone.f == f and x0 >= zone.x0 - EPS and x1 <= zone.x1 + EPS and z0 >= zone.z0 - EPS and z1 <= zone.z1 + EPS then
			inside = true
			break
		end
	end
	if not inside then
		return false, "Outside the room."
	end
	for _, b in tier.blocked do
		if b.f == f and overlaps(x0, z0, x1, z1, b.x0, b.z0, b.x1, b.z1) then
			return false, "In the way of " .. (b.label or "something") .. "."
		end
	end
	local flat = item.flat == true
	for _, p in placements do
		if p.u ~= ignoreUid and p.f == f then
			local other = ApartmentsConfig.ITEM_BY_ID[p.id]
			if other and (other.flat == true) == flat then
				local ox, oz = ApartmentsConfig.footprint(other, p.r)
				if overlaps(x0, z0, x1, z1, p.x - ox / 2, p.z - oz / 2, p.x + ox / 2, p.z + oz / 2) then
					return false, "Overlaps your " .. other.name .. "."
				end
			end
		end
	end
	return true, nil
end

return ApartmentsConfig
