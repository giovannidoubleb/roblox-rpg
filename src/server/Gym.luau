-- CITY GRIND: Iron Box Gym (sections 56, 69, 110, 120).
-- Builds the gym interior (Places.REGIONS.Gym) and an outside pass kiosk,
-- gates the door (free trial -> day pass / membership), runs every training
-- station and judges every rep on the server.
--
-- Remotes (ReplicatedStorage.CityGrind.Remotes):
--   GymSession     server -> client (kind, payload) "start" | "result" | "stop" | "race" | "offer" | "bought"
--   GymRep         client -> server (pressTime: server clock of the button press)
--   GymLeave       client -> server ()
--   GymBuy         client -> server ("pass" | "member")
--   GymRace        client -> server ("invite" | "accept" | "decline" | "cancel")
--   GymGetProgress RemoteFunction -> stats, stat XP, membership, fatigue, today's challenge
-- Player attributes: Training (station kind or ""), GymMember, GymPassUntil,
-- GymFatigue, GymFatigueAt (mirrors of the saved "gym" section).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local Config = require(shared:WaitForChild("Config"))
local GymConfig = require(shared:WaitForChild("GymConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))

local Gym = {}

local STATIONS = GymConfig.STATIONS
local INTERIOR = GymConfig.INTERIOR

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
PlayerData.registerSection("gym", function()
	return {
		member = false,
		trialUsed = false,
		passUntil = 0, -- unix time the day pass runs out
		fatigue = 0, -- 0-100 at fatigueAt
		fatigueAt = 0,
		challengeDay = 0,
		challengeProgress = 0,
		challengeDone = false,
		totalReps = 0,
		raceWins = 0,
	}
end)

PlayerData.onPublish(function(player: Player, data)
	local g = data.sections and data.sections.gym
	if not g then
		return
	end
	player:SetAttribute("GymMember", g.member)
	player:SetAttribute("GymPassUntil", g.passUntil)
	player:SetAttribute("GymFatigue", g.fatigue)
	player:SetAttribute("GymFatigueAt", g.fatigueAt)
end)

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local GymSession = Net.remote("RemoteEvent", "GymSession")
local GymRep = Net.remote("RemoteEvent", "GymRep")
local GymLeave = Net.remote("RemoteEvent", "GymLeave")
local GymBuy = Net.remote("RemoteEvent", "GymBuy")
local GymRace = Net.remote("RemoteEvent", "GymRace")
local GymGetProgress = Net.remote("RemoteFunction", "GymGetProgress")

---------------------------------------------------------------------------
-- Building helpers
---------------------------------------------------------------------------
local function A(x: number, y: number?, z: number?): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y or 0), math.rad(z or 0))
end

local RUBBER = (function()
	local ok, material = pcall(function()
		return (Enum.Material :: any).Rubber
	end)
	return if ok and material then material else Enum.Material.Fabric
end)()

local STEEL = Color3.fromRGB(170, 172, 178)
local DARK = Color3.fromRGB(32, 32, 38)
local IRON_RED = Color3.fromRGB(230, 60, 45)

type PartProps = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	collide: boolean?,
	shape: Enum.PartType?,
	reflectance: number?,
	parent: Instance?,
}

local function part(p: PartProps): BasePart
	local b = Instance.new("Part")
	b.Name = p.name or "Part"
	b.Anchored = true
	if p.shape then
		b.Shape = p.shape
	end
	b.Size = p.size
	b.CFrame = p.cframe
	b.Color = p.color or Color3.fromRGB(160, 160, 160)
	b.Material = p.material or Enum.Material.SmoothPlastic
	b.Transparency = p.transparency or 0
	b.Reflectance = p.reflectance or 0
	b.CanCollide = if p.collide == nil then true else p.collide
	b.TopSurface = Enum.SurfaceType.Smooth
	b.BottomSurface = Enum.SurfaceType.Smooth
	if p.parent then
		b.Parent = p.parent
	end
	return b
end

-- A SurfaceGui with one big text label on the Front face of `target`.
local function sign(target: BasePart, text: string, textColor: Color3, bg: Color3?, font: Enum.Font?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bg or Color3.new(0, 0, 0)
	label.BackgroundTransparency = if bg then 0 else 1
	label.BorderSizePixel = 0
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.TextWrapped = true
	label.Font = font or Enum.Font.GothamBlack
	label.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.PaddingTop = UDim.new(0.06, 0)
	pad.PaddingBottom = UDim.new(0.06, 0)
	pad.Parent = label
	return label
end

-- Poster hung at `pos`, its face looking along `facing`.
local function poster(parent: Instance, pos: Vector3, facing: Vector3, size: Vector2, text: string, textColor: Color3, bg: Color3)
	local p = part({
		name = "Poster",
		size = Vector3.new(size.X, size.Y, 0.15),
		cframe = CFrame.lookAt(pos, pos + facing),
		color = bg,
		collide = false,
		parent = parent,
	})
	sign(p, text, textColor, bg)
	return p
end

-- Barbell with plates, bar along the CFrame's X axis. First part is the bar.
local function barbellParts(cf: CFrame, length: number, parent: Instance?): { BasePart }
	local parts = {}
	table.insert(parts, part({ name = "Bar", size = Vector3.new(length, 0.22, 0.22), cframe = cf, shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, collide = false, parent = parent }))
	for _, side in { -1, 1 } do
		local edge = length / 2 - 0.55
		table.insert(parts, part({ name = "Plate", size = Vector3.new(0.3, 1.9, 1.9), cframe = cf * CFrame.new(side * edge, 0, 0), shape = Enum.PartType.Cylinder, color = DARK, material = Enum.Material.Metal, collide = false, parent = parent }))
		table.insert(parts, part({ name = "Plate", size = Vector3.new(0.26, 1.4, 1.4), cframe = cf * CFrame.new(side * (edge - 0.3), 0, 0), shape = Enum.PartType.Cylinder, color = IRON_RED, material = Enum.Material.Metal, collide = false, parent = parent }))
		table.insert(parts, part({ name = "Collar", size = Vector3.new(0.2, 0.45, 0.45), cframe = cf * CFrame.new(side * (edge - 0.55), 0, 0), shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, collide = false, parent = parent }))
	end
	return parts
end

-- Dumbbell with the handle along the CFrame's X axis. First part is the handle.
local function dumbbellParts(cf: CFrame, parent: Instance?): { BasePart }
	local parts = {}
	table.insert(parts, part({ name = "Handle", size = Vector3.new(1, 0.2, 0.2), cframe = cf, shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, collide = false, parent = parent }))
	for _, side in { -1, 1 } do
		table.insert(parts, part({ name = "Weight", size = Vector3.new(0.32, 0.65, 0.65), cframe = cf * CFrame.new(side * 0.5, 0, 0), shape = Enum.PartType.Cylinder, color = DARK, material = Enum.Material.Metal, collide = false, parent = parent }))
	end
	return parts
end

-- Cable machine handle (a short bar with a grip attachment).
local function handleParts(cf: CFrame, parent: Instance?): { BasePart }
	local grip = part({ name = "Handle", size = Vector3.new(0.7, 0.18, 0.18), cframe = cf, shape = Enum.PartType.Cylinder, color = DARK, material = Enum.Material.Metal, collide = false, parent = parent })
	local att = Instance.new("Attachment")
	att.Name = "Cable"
	att.Parent = grip
	return { grip }
end

-- Turns built parts into a prop welded to `part0` at offset `c0`.
local function attachProp(parts: { BasePart }, part0: BasePart, c0: CFrame, holder: Instance): Weld
	local main = parts[1]
	local origin = main.CFrame
	local target = part0.CFrame * c0
	local model = Instance.new("Model")
	model.Name = "GymProp"
	for _, p in parts do
		p.CFrame = target * origin:ToObjectSpace(p.CFrame)
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Parent = model
	end
	for i = 2, #parts do
		local wc = Instance.new("WeldConstraint")
		wc.Part0 = main
		wc.Part1 = parts[i]
		wc.Parent = parts[i]
	end
	local weld = Instance.new("Weld")
	weld.Part0 = part0
	weld.Part1 = main
	weld.C0 = c0
	weld.Parent = main
	model.Parent = holder
	return weld
end

---------------------------------------------------------------------------
-- Poses (R15). Every value is an offset applied to the joint's original C0.
-- Sign conventions: +X on a shoulder/hip swings the limb forward, +X on an
-- elbow folds the forearm forward, -X on a knee bends it, -X on Waist leans
-- forward. Right arm out to the side is +Z, left is -Z.
---------------------------------------------------------------------------
local JOINT_NAMES = {
	"Waist", "Neck",
	"LeftShoulder", "RightShoulder", "LeftElbow", "RightElbow",
	"LeftHip", "RightHip", "LeftKnee", "RightKnee", "LeftAnkle", "RightAnkle",
}

type Pose = {
	base: { [string]: CFrame },
	loop: { period: number, joints: { [string]: { CFrame } } }?,
	rep: { time: number, joints: { [string]: CFrame }, root: Vector3?, bar: CFrame? }?,
	barRest: CFrame?,
}

local POSES: { [string]: Pose } = {
	Treadmill = {
		base = { Waist = A(-6), LeftElbow = A(85), RightElbow = A(85) },
		loop = {
			period = 0.34,
			joints = {
				LeftHip = { A(32), A(-28) },
				RightHip = { A(-28), A(32) },
				LeftKnee = { A(-15), A(-80) },
				RightKnee = { A(-80), A(-15) },
				LeftShoulder = { A(-30), A(35) },
				RightShoulder = { A(35), A(-30) },
			},
		},
	},
	Bike = {
		base = {
			Waist = A(-22),
			LeftShoulder = A(62), RightShoulder = A(62),
			LeftElbow = A(25), RightElbow = A(25),
		},
		loop = {
			period = 0.42,
			joints = {
				LeftHip = { A(105), A(62) },
				RightHip = { A(62), A(105) },
				LeftKnee = { A(-115), A(-55) },
				RightKnee = { A(-55), A(-115) },
			},
		},
	},
	Bench = { -- lying on the back: "forward" points at the ceiling
		base = { LeftShoulder = A(40), RightShoulder = A(40), LeftElbow = A(110), RightElbow = A(110) },
		rep = {
			time = 0.32,
			joints = { LeftShoulder = A(90), RightShoulder = A(90), LeftElbow = A(0), RightElbow = A(0) },
			bar = CFrame.new(0, 0.5, -2.5),
		},
		barRest = CFrame.new(0, 0.6, -1.4),
	},
	Dumbbells = {
		base = { LeftShoulder = A(0, 0, -8), RightShoulder = A(0, 0, 8), LeftElbow = A(10), RightElbow = A(10) },
		rep = {
			time = 0.3,
			joints = { LeftShoulder = A(12, 0, -8), RightShoulder = A(12, 0, 8), LeftElbow = A(140), RightElbow = A(140) },
		},
	},
	Squat = { -- upper arms out to the sides, forearms back to hold the bar on the traps
		base = { LeftShoulder = A(0, 0, -85), RightShoulder = A(0, 0, 85), LeftElbow = A(-85), RightElbow = A(-85) },
		rep = {
			time = 0.33,
			root = Vector3.new(0, -1.15, 0),
			joints = {
				Waist = A(-25),
				LeftHip = A(80), RightHip = A(80),
				LeftKnee = A(-100), RightKnee = A(-100),
				LeftAnkle = A(20), RightAnkle = A(20),
			},
		},
	},
	PullUp = { -- hanging with a wide grip; the body rises on each rep
		base = {
			LeftShoulder = A(0, 0, -165), RightShoulder = A(0, 0, 165),
			LeftHip = A(15), RightHip = A(15),
			LeftKnee = A(-45), RightKnee = A(-45),
		},
		rep = {
			time = 0.33,
			root = Vector3.new(0, 0.85, 0),
			joints = {
				LeftShoulder = A(0, 0, -100), RightShoulder = A(0, 0, 100),
				LeftElbow = A(0, 0, -80), RightElbow = A(0, 0, 80),
			},
		},
	},
	Cable = { -- chest fly: arms wide, then together in front
		base = { LeftShoulder = A(90, 0, -75), RightShoulder = A(90, 0, 75), LeftElbow = A(15), RightElbow = A(15) },
		rep = {
			time = 0.32,
			joints = { LeftShoulder = A(90, 0, -8), RightShoulder = A(90, 0, 8), LeftElbow = A(5), RightElbow = A(5) },
		},
	},
	Abs = { -- lying on the back, knees up, arms overhead
		base = {
			LeftShoulder = A(170), RightShoulder = A(170),
			LeftHip = A(45), RightHip = A(45),
			LeftKnee = A(-90), RightKnee = A(-90),
		},
		rep = {
			time = 0.3,
			joints = { Waist = A(-50), Neck = A(-20), LeftShoulder = A(110), RightShoulder = A(110) },
		},
	},
}

---------------------------------------------------------------------------
-- Stations
---------------------------------------------------------------------------
type Station = {
	kind: string,
	index: number,
	cf: CFrame, -- floor point, facing the way the user faces
	model: Model,
	prompt: ProximityPrompt,
	user: Player?,
	hidden: { BasePart }, -- rack equipment hidden while the user holds it
	stripes: { BasePart }?,
	crank: { BasePart }?,
	pulleys: { Attachment }?,
	phase: number,
}

type Session = {
	player: Player,
	station: Station,
	kind: string,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	posed: boolean,
	joints: { [string]: Motor6D },
	orig: { [Motor6D]: CFrame },
	rootCF: CFrame,
	exitCF: CFrame,
	loopTweens: { Tween },
	repTweens: { Tween },
	props: { Instance },
	barWeld: Weld?,
	start: number,
	seed: number,
	goodReps: number,
	lastPress: number,
	lastGood: number,
	repTimes: { number },
	conns: { RBXScriptConnection },
}

local stations: { Station } = {}
local treadmills: { Station } = {}
local sessions: { [Player]: Session } = {}
local animatedStations: { [Station]: boolean } = {}
local trialVisit: { [Player]: boolean } = {}

local BELT_LEN = 5.4
local BELT_STRIPES = 7
local BELT_Y = 0.72
local CRANK_HUB = CFrame.new(0, 1.35, -0.55)

-- Where the user stands when they leave, relative to the station.
local EXIT_OFFSET = {
	Treadmill = Vector3.new(0, 0, 4.6),
	Bike = Vector3.new(0, 0, 4),
	Bench = Vector3.new(2.9, 0, 0),
	Squat = Vector3.new(0, 0, 4.5),
	PullUp = Vector3.new(0, 0, 3.5),
	Dumbbells = Vector3.new(0, 0, 3),
	Cable = Vector3.new(0, 0, 3.5),
	Abs = Vector3.new(2.4, 0, 0),
}

local function newStation(kind: string, cf: CFrame, parent: Instance): Station
	local model = Instance.new("Model")
	model.Name = kind .. #stations + 1
	model.Parent = parent
	local anchor = part({
		name = "PromptAnchor",
		size = Vector3.new(1, 1, 1),
		cframe = cf * CFrame.new(0, 2.5, 0),
		transparency = 1,
		collide = false,
		parent = model,
	})
	anchor.CanQuery = false
	anchor.CanTouch = false
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Train"
	prompt.ActionText = "Train"
	prompt.ObjectText = STATIONS[kind].label
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	local station: Station = { kind = kind, index = 0, cf = cf, model = model, prompt = prompt, user = nil, hidden = {}, phase = 0 }
	table.insert(stations, station)
	return station
end

local function buildTreadmill(cf: CFrame, parent: Instance): Station
	local st = newStation("Treadmill", cf, parent)
	local m = st.model
	part({ name = "Deck", size = Vector3.new(3.2, 0.6, 6.2), cframe = cf * CFrame.new(0, 0.3, 0), color = DARK, material = Enum.Material.Metal, parent = m })
	part({ name = "Belt", size = Vector3.new(2.6, 0.1, BELT_LEN + 0.2), cframe = cf * CFrame.new(0, 0.65, 0), color = Color3.fromRGB(18, 18, 20), material = RUBBER, parent = m })
	local stripes = {}
	for i = 1, BELT_STRIPES do
		local z = -BELT_LEN / 2 + (i - 0.5) * BELT_LEN / BELT_STRIPES
		table.insert(stripes, part({ name = "Stripe", size = Vector3.new(2.4, 0.04, 0.16), cframe = cf * CFrame.new(0, BELT_Y, z), color = Color3.fromRGB(80, 80, 88), collide = false, parent = m }))
	end
	st.stripes = stripes
	part({ name = "FrontHood", size = Vector3.new(3.2, 0.95, 0.9), cframe = cf * CFrame.new(0, 0.48, -3.3), color = Color3.fromRGB(50, 50, 58), material = Enum.Material.Metal, parent = m })
	part({ name = "Roller", size = Vector3.new(3.2, 0.6, 0.6), cframe = cf * CFrame.new(0, 0.32, 3.1), shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, parent = m })
	for _, side in { -1, 1 } do
		part({ name = "Post", size = Vector3.new(0.25, 3.6, 0.25), cframe = cf * CFrame.new(side * 1.45, 2.6, -3.2), color = STEEL, material = Enum.Material.Metal, parent = m })
		part({ name = "Rail", size = Vector3.new(0.2, 0.2, 2.4), cframe = cf * CFrame.new(side * 1.45, 4.0, -2.1), color = DARK, material = Enum.Material.Metal, collide = false, parent = m })
	end
	local console = part({ name = "Console", size = Vector3.new(3.2, 1.3, 0.4), cframe = cf * CFrame.new(0, 4.6, -3.3) * A(-25), color = DARK, material = Enum.Material.Metal, parent = m })
	local screen = part({ name = "Screen", size = Vector3.new(1.6, 0.6, 0.05), cframe = console.CFrame * CFrame.new(0, 0, -0.22) * CFrame.Angles(0, math.pi, 0), color = Color3.fromRGB(20, 40, 30), material = Enum.Material.Neon, collide = false, parent = m })
	sign(screen, "IRON BOX RUN", Color3.fromRGB(120, 255, 160), Color3.fromRGB(10, 25, 15), Enum.Font.Code)
	return st
end

local function buildBike(cf: CFrame, parent: Instance): Station
	local st = newStation("Bike", cf, parent)
	local m = st.model
	part({ name = "Base", size = Vector3.new(2, 0.3, 4.6), cframe = cf * CFrame.new(0, 0.15, 0), color = DARK, material = Enum.Material.Metal, parent = m })
	part({ name = "SeatPost", size = Vector3.new(0.35, 2.3, 0.35), cframe = cf * CFrame.new(0, 1.3, 0.9) * A(-12), color = STEEL, material = Enum.Material.Metal, parent = m })
	part({ name = "Seat", size = Vector3.new(1.3, 0.3, 1.5), cframe = cf * CFrame.new(0, 2.45, 1.0), color = Color3.fromRGB(25, 25, 28), material = Enum.Material.Leather, parent = m })
	part({ name = "Stem", size = Vector3.new(0.35, 3.3, 0.35), cframe = cf * CFrame.new(0, 1.9, -1.7) * A(15), color = STEEL, material = Enum.Material.Metal, parent = m })
	part({ name = "Handlebar", size = Vector3.new(2.2, 0.22, 0.22), cframe = cf * CFrame.new(0, 3.55, -2.05), shape = Enum.PartType.Cylinder, color = DARK, material = Enum.Material.Metal, collide = false, parent = m })
	part({ name = "Flywheel", size = Vector3.new(0.35, 1.9, 1.9), cframe = cf * CFrame.new(0, 1.15, -1.55), shape = Enum.PartType.Cylinder, color = IRON_RED, material = Enum.Material.Metal, parent = m })
	local screen = part({ name = "Screen", size = Vector3.new(1, 0.6, 0.15), cframe = cf * CFrame.new(0, 3.95, -2.1) * A(-30), color = Color3.fromRGB(20, 40, 30), material = Enum.Material.Neon, collide = false, parent = m })
	screen.CFrame *= CFrame.Angles(0, math.pi, 0)
	sign(screen, "RPM", Color3.fromRGB(120, 255, 160), Color3.fromRGB(10, 25, 15), Enum.Font.Code)
	local hub = cf * CRANK_HUB
	part({ name = "Hub", size = Vector3.new(0.9, 0.5, 0.5), cframe = hub, shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, collide = false, parent = m })
	local crank = {}
	for _ = 1, 2 do
		table.insert(crank, part({ name = "CrankArm", size = Vector3.new(0.12, 0.15, 0.7), cframe = hub, color = STEEL, material = Enum.Material.Metal, collide = false, parent = m }))
		table.insert(crank, part({ name = "Pedal", size = Vector3.new(0.5, 0.1, 0.3), cframe = hub, color = DARK, collide = false, parent = m }))
	end
	st.crank = crank
	return st
end

local function buildBench(cf: CFrame, parent: Instance): Station
	local st = newStation("Bench", cf, parent)
	local m = st.model
	part({ name = "Pad", size = Vector3.new(1.8, 0.45, 6), cframe = cf * CFrame.new(0, 1.62, -0.3), color = Color3.fromRGB(28, 28, 32), material = Enum.Material.Leather, parent = m })
	part({ name = "Frame", size = Vector3.new(1.2, 0.2, 6), cframe = cf * CFrame.new(0, 1.3, -0.3), color = STEEL, material = Enum.Material.Metal, parent = m })
	for _, z in { -2.8, 2.2 } do
		part({ name = "Leg", size = Vector3.new(1.6, 1.3, 0.3), cframe = cf * CFrame.new(0, 0.65, z), color = STEEL, material = Enum.Material.Metal, parent = m })
	end
	for _, side in { -1, 1 } do
		part({ name = "Upright", size = Vector3.new(0.3, 4.7, 0.3), cframe = cf * CFrame.new(side * 1.9, 2.35, 0.9), color = DARK, material = Enum.Material.Metal, parent = m })
		part({ name = "Hook", size = Vector3.new(0.3, 0.3, 0.6), cframe = cf * CFrame.new(side * 1.9, 4.3, 0.65), color = IRON_RED, material = Enum.Material.Metal, parent = m })
		part({ name = "Foot", size = Vector3.new(0.6, 0.2, 2), cframe = cf * CFrame.new(side * 1.9, 0.1, 0.9), color = DARK, material = Enum.Material.Metal, parent = m })
	end
	st.hidden = barbellParts(cf * CFrame.new(0, 4.55, 0.55), 6.6, m)
	return st
end

local function buildSquatRack(cf: CFrame, parent: Instance): Station
	local st = newStation("Squat", cf, parent)
	local m = st.model
	part({ name = "Platform", size = Vector3.new(6, 0.2, 6), cframe = cf * CFrame.new(0, 0.1, 0), color = Color3.fromRGB(120, 85, 55), material = Enum.Material.WoodPlanks, parent = m })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part({ name = "Upright", size = Vector3.new(0.35, 8.4, 0.35), cframe = cf * CFrame.new(sx * 2.6, 4.4, sz * 2.2), color = DARK, material = Enum.Material.Metal, parent = m })
		end
		part({ name = "TopRail", size = Vector3.new(0.3, 0.3, 4.7), cframe = cf * CFrame.new(sx * 2.6, 8.5, 0), color = DARK, material = Enum.Material.Metal, parent = m })
		part({ name = "Hook", size = Vector3.new(0.3, 0.3, 0.6), cframe = cf * CFrame.new(sx * 2.6, 5.2, 0.55), color = IRON_RED, material = Enum.Material.Metal, parent = m })
		part({ name = "Safety", size = Vector3.new(0.25, 0.25, 4.7), cframe = cf * CFrame.new(sx * 2.6, 2.6, 0), color = STEEL, material = Enum.Material.Metal, collide = false, parent = m })
	end
	part({ name = "Crossbar", size = Vector3.new(5.5, 0.3, 0.3), cframe = cf * CFrame.new(0, 8.5, 2.2), color = DARK, material = Enum.Material.Metal, parent = m })
	st.hidden = barbellParts(cf * CFrame.new(0, 5.45, 0.55), 6.8, m)
	return st
end

local function buildPullUp(cf: CFrame, parent: Instance): Station
	local st = newStation("PullUp", cf, parent)
	local m = st.model
	for _, side in { -1, 1 } do
		part({ name = "Upright", size = Vector3.new(0.4, 10, 0.4), cframe = cf * CFrame.new(side * 2.4, 5, 0), color = DARK, material = Enum.Material.Metal, parent = m })
		part({ name = "Foot", size = Vector3.new(0.8, 0.2, 3), cframe = cf * CFrame.new(side * 2.4, 0.1, 0), color = DARK, material = Enum.Material.Metal, parent = m })
	end
	part({ name = "Bar", size = Vector3.new(5.2, 0.28, 0.28), cframe = cf * CFrame.new(0, 9.5, 0), shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, parent = m })
	part({ name = "Mat", size = Vector3.new(4.4, 0.1, 3), cframe = cf * CFrame.new(0, 0.05, 0), color = Color3.fromRGB(45, 45, 52), material = RUBBER, collide = false, parent = m })
	return st
end

local function buildDumbbellSpot(cf: CFrame, parent: Instance): Station
	local st = newStation("Dumbbells", cf, parent)
	local m = st.model
	part({ name = "Rack", size = Vector3.new(3.2, 1.6, 1.2), cframe = cf * CFrame.new(0, 0.8, -2.6), color = DARK, material = Enum.Material.Metal, parent = m })
	local hidden = {}
	for _, side in { -1, 1 } do
		for _, p in dumbbellParts(cf * CFrame.new(side * 0.8, 1.95, -2.6), m) do
			table.insert(hidden, p)
		end
	end
	st.hidden = hidden
	part({ name = "Mat", size = Vector3.new(3.4, 0.1, 3.4), cframe = cf * CFrame.new(0, 0.05, 0), color = Color3.fromRGB(45, 45, 52), material = RUBBER, collide = false, parent = m })
	return st
end

local function buildCable(cf: CFrame, parent: Instance): Station
	local st = newStation("Cable", cf, parent)
	local m = st.model
	local pulleys = {}
	for _, side in { -1, 1 } do
		part({ name = "Tower", size = Vector3.new(1.1, 9, 1.1), cframe = cf * CFrame.new(side * 3.8, 4.5, 0.8), color = DARK, material = Enum.Material.Metal, parent = m })
		part({ name = "Stack", size = Vector3.new(0.8, 2.6, 0.6), cframe = cf * CFrame.new(side * 3.8, 1.4, 1.5), color = IRON_RED, material = Enum.Material.Metal, parent = m })
		local pulley = part({ name = "Pulley", size = Vector3.new(0.3, 0.7, 0.7), cframe = cf * CFrame.new(side * 3.15, 5.2, 0.8), shape = Enum.PartType.Cylinder, color = STEEL, material = Enum.Material.Metal, collide = false, parent = m })
		local att = Instance.new("Attachment")
		att.Name = "Cable"
		att.Parent = pulley
		table.insert(pulleys, att) -- [1] = left (-x), [2] = right (+x)
	end
	part({ name = "TopBeam", size = Vector3.new(8.7, 0.6, 1.1), cframe = cf * CFrame.new(0, 9.2, 0.8), color = DARK, material = Enum.Material.Metal, parent = m })
	st.pulleys = pulleys
	-- the handles hang on the pulleys when nobody is training
	local hidden = {}
	for i, side in { -1, 1 } do
		for _, p in handleParts(cf * CFrame.new(side * 3.15, 4.6, 0.8), m) do
			table.insert(hidden, p)
			local beam = Instance.new("Beam")
			beam.Attachment0 = pulleys[i]
			beam.Attachment1 = p:FindFirstChild("Cable") :: Attachment
			beam.Width0 = 0.07
			beam.Width1 = 0.07
			beam.FaceCamera = true
			beam.Segments = 1
			beam.Color = ColorSequence.new(Color3.fromRGB(30, 30, 30))
			beam.Parent = p
		end
	end
	st.hidden = hidden
	return st
end

local function buildAbMat(cf: CFrame, parent: Instance): Station
	local st = newStation("Abs", cf, parent)
	part({ name = "Mat", size = Vector3.new(3, 0.2, 7), cframe = cf * CFrame.new(0, 0.1, -0.4), color = Color3.fromRGB(40, 110, 200), material = RUBBER, parent = st.model })
	return st
end

---------------------------------------------------------------------------
-- Interior
---------------------------------------------------------------------------
local origin: Vector3
local doorPart: BasePart? = nil
local deskPos: Vector3
local gpsTarget = Vector3.new(205, 1, -49)
local insideCF: CFrame
local boardLabels: { title: TextLabel, body: TextLabel, reward: TextLabel, timer: TextLabel }? = nil

local function L(x: number, y: number, z: number): Vector3
	return origin + Vector3.new(x, y, z)
end

local function at(x: number, z: number): CFrame
	return CFrame.new(L(x, 0, z))
end

local function buildInterior(folder: Folder)
	Places.room("IronBoxInterior", origin, Vector3.new(140, 22, 90), {
		floorColor = Color3.fromRGB(34, 34, 40),
		floorMaterial = RUBBER,
		wallColor = Color3.fromRGB(62, 62, 72),
		parent = folder,
	})
	local decor = Instance.new("Model")
	decor.Name = "Decor"
	decor.Parent = folder

	-- red accent stripe around the walls and colored strip lights
	for _, w in {
		{ Vector3.new(140, 1, 0.2), L(0, 3.5, -44.9) },
		{ Vector3.new(140, 1, 0.2), L(0, 3.5, 44.9) },
		{ Vector3.new(0.2, 1, 90), L(-69.9, 3.5, 0) },
		{ Vector3.new(0.2, 1, 90), L(69.9, 3.5, 0) },
	} do
		part({ name = "Stripe", size = w[1], cframe = CFrame.new(w[2]), color = IRON_RED, material = Enum.Material.SmoothPlastic, collide = false, parent = decor })
	end
	for _, x in { -46, 0, 46 } do
		local strip = part({ name = "LightStrip", size = Vector3.new(30, 0.2, 0.6), cframe = CFrame.new(L(x, 21.8, 0)), color = Color3.fromRGB(255, 90, 70), material = Enum.Material.Neon, collide = false, parent = decor })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 120, 100)
		light.Range = 18
		light.Brightness = 0.6
		light.Parent = strip
	end

	-- lighter rubber zones under the free weights
	part({ name = "WeightZone", size = Vector3.new(70, 0.06, 18), cframe = CFrame.new(L(-30, 0.03, -12)), color = Color3.fromRGB(48, 48, 56), material = RUBBER, collide = false, parent = decor })
	part({ name = "WeightZone", size = Vector3.new(40, 0.06, 18), cframe = CFrame.new(L(48, 0.03, -12)), color = Color3.fromRGB(48, 48, 56), material = RUBBER, collide = false, parent = decor })
	part({ name = "CardioZone", size = Vector3.new(96, 0.06, 10), cframe = CFrame.new(L(-20, 0.03, -36)), color = Color3.fromRGB(40, 44, 58), material = RUBBER, collide = false, parent = decor })

	-- mirrors on the north wall (the cardio row faces them)
	for _, mx in { -40, 25 } do
		part({ name = "Mirror", size = Vector3.new(48, 10, 0.2), cframe = CFrame.new(L(mx, 7.5, -44.85)), color = Color3.fromRGB(200, 215, 225), material = Enum.Material.Glass, reflectance = 0.65, transparency = 0.05, collide = false, parent = decor })
		part({ name = "MirrorFrame", size = Vector3.new(48.6, 10.6, 0.1), cframe = CFrame.new(L(mx, 7.5, -44.95)), color = DARK, collide = false, parent = decor })
	end

	-- posters (SurfaceGui text)
	local white = Color3.fromRGB(245, 245, 245)
	poster(decor, L(-40, 16.5, -44.8), Vector3.zAxis, Vector2.new(26, 4), "IRON BOX GYM", IRON_RED, Color3.fromRGB(18, 18, 22))
	poster(decor, L(25, 16.5, -44.8), Vector3.zAxis, Vector2.new(22, 4), "NO DAYS OFF", white, IRON_RED)
	poster(decor, L(-69.8, 10, -20), Vector3.xAxis, Vector2.new(20, 4), "TRAIN · EAT · SLEEP · REPEAT", white, Color3.fromRGB(30, 30, 36))
	poster(decor, L(-69.8, 10, 14), Vector3.xAxis, Vector2.new(16, 6), "PERFECT REPS\nBIGGER GAINS", Color3.fromRGB(255, 210, 70), Color3.fromRGB(30, 30, 36))
	poster(decor, L(69.8, 10, -20), -Vector3.xAxis, Vector2.new(18, 6), "TIRED MUSCLES\nDON'T GROW.\nREST UP.", white, Color3.fromRGB(40, 60, 120))
	poster(decor, L(69.8, 10, 14), -Vector3.xAxis, Vector2.new(18, 5), "RISE TO THE TOP", IRON_RED, Color3.fromRGB(18, 18, 22))
	poster(decor, L(0, 14, 44.8), -Vector3.zAxis, Vector2.new(30, 5), "IRON BOX GYM · EST. THE NEIGHBORHOOD", white, Color3.fromRGB(18, 18, 22))

	-- zone signs hanging from the ceiling
	for _, z in {
		{ L(-42, 14, -30), "CARDIO" },
		{ L(-30, 14, -6), "BENCH & SQUAT" },
		{ L(48, 14, -6), "PULL-UPS" },
		{ L(-40, 14, 18), "FREE WEIGHTS" },
		{ L(-8, 14, 18), "CORE" },
		{ L(45, 14, -30), "CABLES" },
	} do
		local p = part({ name = "ZoneSign", size = Vector3.new(12, 2.2, 0.3), cframe = CFrame.lookAt(z[1], z[1] + Vector3.zAxis), color = Color3.fromRGB(18, 18, 22), collide = false, parent = decor })
		sign(p, z[2], Color3.fromRGB(255, 255, 255), Color3.fromRGB(18, 18, 22))
		part({ name = "Wire", size = Vector3.new(0.08, 6.8, 0.08), cframe = CFrame.new(z[1] + Vector3.new(0, 4.5, 0)), color = DARK, collide = false, parent = decor })
	end

	-- dumbbell wall rack (decor) behind the dumbbell spots
	part({ name = "DumbbellWallRack", size = Vector3.new(34, 2.6, 2), cframe = CFrame.new(L(-48, 1.3, 20)), color = DARK, material = Enum.Material.Metal, parent = decor })
	for i = 0, 13 do
		dumbbellParts(CFrame.new(L(-63 + i * 2.3, 2.95, 20)) * CFrame.Angles(0, math.pi / 2, 0), decor)
	end

	-- lockers, water cooler and a bench by the entrance
	for i = 0, 7 do
		local locker = part({ name = "Locker", size = Vector3.new(2.4, 7, 2), cframe = CFrame.new(L(46 + i * 2.6, 3.5, 43.8)), color = if i % 2 == 0 then Color3.fromRGB(60, 90, 140) else Color3.fromRGB(55, 82, 128), material = Enum.Material.Metal, parent = decor })
		part({ name = "Vent", size = Vector3.new(1.4, 0.4, 0.05), cframe = locker.CFrame * CFrame.new(0, 2.6, -1.02), color = DARK, collide = false, parent = decor })
	end
	part({ name = "LockerBench", size = Vector3.new(18, 1.2, 1.6), cframe = CFrame.new(L(55, 0.6, 38)), color = Color3.fromRGB(120, 85, 55), material = Enum.Material.WoodPlanks, parent = decor })
	part({ name = "CoolerBase", size = Vector3.new(1.6, 3, 1.6), cframe = CFrame.new(L(40, 1.5, 43.5)), color = Color3.fromRGB(230, 230, 235), parent = decor })
	part({ name = "CoolerJug", size = Vector3.new(1.3, 1.8, 1.3), cframe = CFrame.new(L(40, 3.9, 43.5)), color = Color3.fromRGB(120, 190, 255), material = Enum.Material.Glass, transparency = 0.3, parent = decor })

	-- plants in the corners
	for _, pos in { L(-66, 0, 41), L(66, 0, -41), L(-66, 0, -41) } do
		part({ name = "Pot", size = Vector3.new(2, 2, 2), cframe = CFrame.new(pos + Vector3.new(0, 1, 0)), color = Color3.fromRGB(70, 70, 76), material = Enum.Material.Concrete, parent = decor })
		part({ name = "Leaves", size = Vector3.new(3, 3, 3), cframe = CFrame.new(pos + Vector3.new(0, 3.2, 0)), color = Color3.fromRGB(60, 140, 70), material = Enum.Material.Grass, shape = Enum.PartType.Ball, collide = false, parent = decor })
	end

	-- front desk
	deskPos = L(-22, 0, 36)
	local desk = Instance.new("Model")
	desk.Name = "FrontDesk"
	desk.Parent = folder
	part({ name = "Counter", size = Vector3.new(12, 3.6, 2.4), cframe = CFrame.new(deskPos + Vector3.new(0, 1.8, 0)), color = Color3.fromRGB(28, 28, 34), material = Enum.Material.Metal, parent = desk })
	part({ name = "Top", size = Vector3.new(12.6, 0.3, 3), cframe = CFrame.new(deskPos + Vector3.new(0, 3.75, 0)), color = Color3.fromRGB(150, 110, 75), material = Enum.Material.Wood, parent = desk })
	local deskFront = part({ name = "Front", size = Vector3.new(10, 2.2, 0.1), cframe = CFrame.lookAt(deskPos + Vector3.new(0, 1.9, -1.26), deskPos + Vector3.new(0, 1.9, -5)), color = IRON_RED, collide = false, parent = desk })
	sign(deskFront, "FRONT DESK", Color3.fromRGB(255, 255, 255), IRON_RED)
	local priceBoard = part({ name = "Prices", size = Vector3.new(12, 5, 0.3), cframe = CFrame.lookAt(L(-22, 8.5, 44.8), L(-22, 8.5, 30)), color = Color3.fromRGB(18, 18, 22), collide = false, parent = desk })
	sign(
		priceBoard,
		string.format("DAY PASS  $%d · %d MIN\nMEMBERSHIP  $%d · FOREVER", GymConfig.DAY_PASS_PRICE, GymConfig.DAY_PASS_SECONDS // 60, GymConfig.MEMBERSHIP_PRICE),
		Color3.fromRGB(255, 220, 90),
		Color3.fromRGB(18, 18, 22)
	)
	local register = part({ name = "Register", size = Vector3.new(1.4, 1, 1), cframe = CFrame.new(deskPos + Vector3.new(3, 4.4, 0)), color = DARK, parent = desk })
	local deskPrompt = Instance.new("ProximityPrompt")
	deskPrompt.Name = "Memberships"
	deskPrompt.ActionText = "Passes & Membership"
	deskPrompt.ObjectText = "Front Desk"
	deskPrompt.KeyboardKeyCode = Enum.KeyCode.E
	deskPrompt.HoldDuration = 0
	deskPrompt.MaxActivationDistance = 9
	deskPrompt.RequiresLineOfSight = false
	deskPrompt.Parent = register
	deskPrompt.Triggered:Connect(function(player)
		if player:GetAttribute("Interior") == INTERIOR and Net.allow(player, "GymDesk", 0.5) then
			GymSession:FireClient(player, "offer", { where = "desk" })
		end
	end)

	-- daily challenge board
	local board = part({ name = "ChallengeBoard", size = Vector3.new(18, 10, 0.4), cframe = CFrame.new(L(24, 7, 44.6)), color = Color3.fromRGB(18, 18, 22), parent = decor })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = board
	local function boardText(y: number, h: number, color: Color3, font: Enum.Font): TextLabel
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromScale(0.05, y)
		label.Size = UDim2.fromScale(0.9, h)
		label.TextScaled = true
		label.TextWrapped = true
		label.Font = font
		label.TextColor3 = color
		label.Text = ""
		label.Parent = gui
		return label
	end
	boardLabels = {
		title = boardText(0.05, 0.16, IRON_RED, Enum.Font.GothamBlack),
		body = boardText(0.27, 0.3, Color3.fromRGB(245, 245, 245), Enum.Font.GothamBold),
		reward = boardText(0.6, 0.15, Color3.fromRGB(110, 230, 120), Enum.Font.GothamBold),
		timer = boardText(0.8, 0.12, Color3.fromRGB(160, 160, 175), Enum.Font.GothamMedium),
	}

	-- equipment
	local equipment = Instance.new("Folder")
	equipment.Name = "Equipment"
	equipment.Parent = folder
	for i, x in { -62, -54, -46, -38, -30, -22 } do
		local st = buildTreadmill(at(x, -36), equipment)
		st.index = i
		table.insert(treadmills, st)
	end
	for _, x in { -8, 0, 8, 16 } do
		buildBike(at(x, -36), equipment)
	end
	for _, x in { 36, 54 } do
		buildCable(at(x, -36), equipment)
	end
	for _, x in { -62, -50, -38, -26 } do
		buildBench(at(x, -12), equipment)
	end
	for _, x in { -8, 6, 20 } do
		buildSquatRack(at(x, -12), equipment)
	end
	for _, x in { 38, 48, 58 } do
		buildPullUp(at(x, -12), equipment)
	end
	for _, x in { -62, -54, -46, -38 } do
		buildDumbbellSpot(at(x, 14), equipment)
	end
	for _, x in { -20, -12, -4, 4 } do
		buildAbMat(at(x, 12), equipment)
	end
end

-- Pass kiosk outside, next to the gym door.
local function buildKiosk(folder: Folder, door: BasePart)
	local look = door.CFrame.LookVector
	-- the door's outward side is the one away from the building centre
	local model = door.Parent
	local center = if model and model:IsA("Model") then model:GetPivot().Position else door.Position
	local out = if ((door.Position + look) - center).Magnitude > ((door.Position - look) - center).Magnitude then look else -look
	local right = out:Cross(Vector3.yAxis).Unit
	local base = Vector3.new(door.Position.X, door.Position.Y - door.Size.Y / 2, door.Position.Z) + out * 3 + right * 6
	local kiosk = Instance.new("Model")
	kiosk.Name = "PassKiosk"
	kiosk.Parent = folder
	local body = part({ name = "Body", size = Vector3.new(2.4, 5, 1.4), cframe = CFrame.lookAt(base + Vector3.new(0, 2.5, 0), base + Vector3.new(0, 2.5, 0) + out), color = Color3.fromRGB(28, 28, 34), material = Enum.Material.Metal, parent = kiosk })
	local screen = part({ name = "Screen", size = Vector3.new(2, 2.6, 0.1), cframe = body.CFrame * CFrame.new(0, 0.7, -0.73), color = Color3.fromRGB(20, 20, 26), collide = false, parent = kiosk })
	sign(screen, string.format("IRON BOX\nDAY PASS $%d\nMEMBER $%d", GymConfig.DAY_PASS_PRICE, GymConfig.MEMBERSHIP_PRICE), Color3.fromRGB(255, 220, 90), Color3.fromRGB(20, 20, 26))
	part({ name = "Topper", size = Vector3.new(2.4, 0.6, 1.4), cframe = body.CFrame * CFrame.new(0, 2.8, 0), color = IRON_RED, material = Enum.Material.Neon, collide = false, parent = kiosk })
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyPass"
	prompt.ActionText = "Buy Pass"
	prompt.ObjectText = "Iron Box Gym"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = body
	prompt.Triggered:Connect(function(player)
		if (player:GetAttribute("Interior") or "") == "" and Net.allow(player, "GymKiosk", 0.5) then
			GymSession:FireClient(player, "offer", { where = "door" })
		end
	end)
	gpsTarget = Vector3.new(door.Position.X, 1, door.Position.Z) + out * 6
end

---------------------------------------------------------------------------
-- Access
---------------------------------------------------------------------------
local function gymSection(player: Player)
	return PlayerData.section(player, "gym")
end

local function hasAccess(player: Player): boolean
	local g = gymSection(player)
	if not g then
		return false
	end
	return g.member or g.passUntil > os.time() or trialVisit[player] == true
end

local function accessText(g): string
	if g.member then
		return "Iron Box member"
	elseif g.passUntil > os.time() then
		return string.format("Day pass: %d min left", math.ceil((g.passUntil - os.time()) / 60))
	elseif not g.trialUsed then
		return "Free trial available"
	end
	return "No pass"
end

local function enterGym(player: Player)
	player:SetAttribute("Interior", INTERIOR)
	Places.teleport(player, insideCF)
end

---------------------------------------------------------------------------
-- Daily challenge
---------------------------------------------------------------------------
local function ensureDay(g): boolean
	local today = GymConfig.day(os.time())
	if g.challengeDay ~= today then
		g.challengeDay = today
		g.challengeProgress = 0
		g.challengeDone = false
		return true
	end
	return false
end

local function challengeInfo(g)
	local today = GymConfig.day(os.time())
	local ch = GymConfig.challengeFor(today)
	local sameDay = g.challengeDay == today
	return {
		text = ch.text,
		station = ch.station,
		stationLabel = STATIONS[ch.station].label,
		target = ch.reps,
		progress = if sameDay then g.challengeProgress else 0,
		done = sameDay and g.challengeDone,
		cash = ch.cash,
		xp = ch.xp,
		resetsIn = (today + 1) * 86400 - os.time(),
	}
end

local function updateBoard()
	local labels = boardLabels
	if not labels then
		return
	end
	local today = GymConfig.day(os.time())
	local ch = GymConfig.challengeFor(today)
	local left = (today + 1) * 86400 - os.time()
	labels.title.Text = "DAILY CHALLENGE"
	labels.body.Text = ch.text .. "\n(" .. STATIONS[ch.station].label .. ")"
	labels.reward.Text = string.format("REWARD  $%d  +  %d XP", ch.cash, ch.xp)
	labels.timer.Text = string.format("New challenge in %dh %02dm · progress in your Fitness app", left // 3600, (left % 3600) // 60)
end

---------------------------------------------------------------------------
-- Stat progress helpers
---------------------------------------------------------------------------
local function progressFor(player: Player, kind: string)
	local data = PlayerData.get(player)
	local list = {}
	if not data then
		return list
	end
	for _, entry in STATIONS[kind].stats do
		local stat = entry[1]
		table.insert(list, { stat = stat, value = data.stats[stat] or 1, xp = data.statXP[stat] or 0 })
	end
	return list
end

---------------------------------------------------------------------------
-- Treadmill races (section 56)
---------------------------------------------------------------------------
type Race = { opponent: Player, count: number }
local races: { [Player]: Race } = {}
local invites: { [Player]: { from: Player, at: number } } = {} -- keyed by the invited player
local outgoing: { [Player]: Player } = {} -- inviter -> invited
local advertised: { [Player]: Player } = {} -- who the "Race" button would challenge
local lastRaceMsg: { [Player]: string } = {}

local function sendRace(player: Player, state: string, info: { [string]: any }?)
	local payload = info or {}
	payload.state = state
	payload.target = GymConfig.RACE_TARGET
	local key = state .. ":" .. tostring(payload.opponent) .. ":" .. tostring(payload.mine) .. ":" .. tostring(payload.theirs)
	if lastRaceMsg[player] == key then
		return
	end
	lastRaceMsg[player] = key
	GymSession:FireClient(player, "race", payload)
end

local function treadmillOf(player: Player): Station?
	local s = sessions[player]
	return if s and s.kind == "Treadmill" then s.station else nil
end

local function busyRacing(player: Player): boolean
	return races[player] ~= nil or invites[player] ~= nil or outgoing[player] ~= nil
end

local function adjacentRunners(st: Station): { Player }
	local list = {}
	for _, other in treadmills do
		if math.abs(other.index - st.index) == 1 and other.user and sessions[other.user] then
			table.insert(list, other.user)
		end
	end
	return list
end

local function refreshRaces()
	for _, st in treadmills do
		local user = st.user
		if user and sessions[user] then
			if not busyRacing(user) then
				local found: Player? = nil
				for _, other in adjacentRunners(st) do
					if not busyRacing(other) then
						found = other
						break
					end
				end
				advertised[user] = found
				if found then
					sendRace(user, "available", { opponent = found.Name })
				else
					sendRace(user, "none")
				end
			end
		end
	end
end

local function clearInvite(invited: Player)
	local inv = invites[invited]
	if inv then
		outgoing[inv.from] = nil
		invites[invited] = nil
	end
end

-- Ends any race / invite involving `player` (left the treadmill, left the game...).
local function cancelRaceFor(player: Player, reason: string)
	local race = races[player]
	if race then
		local opp = race.opponent
		races[player] = nil
		races[opp] = nil
		if opp.Parent then
			Net.notify(opp, "RACE CANCELLED", reason)
			sendRace(opp, "none")
		end
	end
	if invites[player] then
		local from = invites[player].from
		clearInvite(player)
		if from.Parent then
			Net.notify(from, "RACE", player.Name .. " didn't take the race.")
			sendRace(from, "none")
		end
	end
	local target = outgoing[player]
	if target then
		clearInvite(target)
		if target.Parent then
			sendRace(target, "none")
		end
	end
	advertised[player] = nil
	lastRaceMsg[player] = nil
end

local function raceRep(player: Player)
	local race = races[player]
	if not race then
		return
	end
	race.count += 1
	local opp = race.opponent
	local oppRace = races[opp]
	local theirs = if oppRace then oppRace.count else 0
	sendRace(player, "active", { opponent = opp.Name, mine = race.count, theirs = theirs })
	sendRace(opp, "active", { opponent = player.Name, mine = theirs, theirs = race.count })
	if race.count < GymConfig.RACE_TARGET then
		return
	end
	-- winner!
	races[player] = nil
	races[opp] = nil
	local data = PlayerData.get(player)
	if data then
		for _, entry in STATIONS.Treadmill.stats do
			local stat = entry[1]
			local amount = GymConfig.statGain(data.stats[stat] or 1, entry[2], true, 1) * GymConfig.RACE_BONUS_REPS
			PlayerData.addStatXP(player, stat, math.floor(amount * 10 + 0.5) / 10)
		end
		PlayerData.addXP(player, GymConfig.RACE_BONUS_XP)
		local g = gymSection(player)
		if g then
			g.raceWins += 1
			PlayerData.markChanged(player)
		end
	end
	Net.notify(player, "RACE WON", "You beat " .. opp.Name .. "! Bonus Stamina + Speed XP.")
	Net.notify(opp, "RACE LOST", player.Name .. " got to " .. GymConfig.RACE_TARGET .. " first. Run it back!")
	GymSession:FireClient(player, "result", { quality = "race", progress = progressFor(player, "Treadmill") })
	lastRaceMsg[player] = nil
	lastRaceMsg[opp] = nil
	refreshRaces()
end

GymRace.OnServerEvent:Connect(function(player: Player, action: any)
	if type(action) ~= "string" or not Net.allow(player, "GymRace", 0.5) then
		return
	end
	local st = treadmillOf(player)
	if not st then
		return
	end
	if action == "invite" then
		local target = advertised[player]
		if busyRacing(player) or not target or busyRacing(target) then
			return
		end
		local targetSt = treadmillOf(target)
		if not targetSt or math.abs(targetSt.index - st.index) ~= 1 then
			return
		end
		invites[target] = { from = player, at = os.clock() }
		outgoing[player] = target
		sendRace(player, "waiting", { opponent = target.Name })
		sendRace(target, "invite", { opponent = player.Name })
		task.delay(GymConfig.RACE_INVITE_SECONDS, function()
			local inv = invites[target]
			if inv and inv.from == player and os.clock() - inv.at >= GymConfig.RACE_INVITE_SECONDS - 0.1 then
				clearInvite(target)
				if player.Parent then
					Net.notify(player, "RACE", target.Name .. " didn't answer.")
				end
				lastRaceMsg[player] = nil
				lastRaceMsg[target] = nil
				refreshRaces()
			end
		end)
	elseif action == "accept" then
		local inv = invites[player]
		if not inv then
			return
		end
		local from = inv.from
		clearInvite(player)
		local fromSt = treadmillOf(from)
		if not fromSt or math.abs(fromSt.index - st.index) ~= 1 or races[from] or races[player] then
			lastRaceMsg[player] = nil
			refreshRaces()
			return
		end
		races[player] = { opponent = from, count = 0 }
		races[from] = { opponent = player, count = 0 }
		sendRace(player, "active", { opponent = from.Name, mine = 0, theirs = 0 })
		sendRace(from, "active", { opponent = player.Name, mine = 0, theirs = 0 })
		Net.notify(player, "RACE ON", "First to " .. GymConfig.RACE_TARGET .. " good reps wins. GO!")
		Net.notify(from, "RACE ON", "First to " .. GymConfig.RACE_TARGET .. " good reps wins. GO!")
	elseif action == "decline" then
		local inv = invites[player]
		if not inv then
			return
		end
		local from = inv.from
		clearInvite(player)
		if from.Parent then
			Net.notify(from, "RACE", player.Name .. " passed on the race.")
		end
		lastRaceMsg[player] = nil
		lastRaceMsg[from] = nil
		refreshRaces()
	elseif action == "cancel" then
		local target = outgoing[player]
		if target then
			clearInvite(target)
			lastRaceMsg[player] = nil
			lastRaceMsg[target] = nil
			refreshRaces()
		end
	end
end)

---------------------------------------------------------------------------
-- Training sessions
---------------------------------------------------------------------------
local function standHeight(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	return 3
end

local function rootPlacement(kind: string, cf: CFrame, h: number, posed: boolean): CFrame
	if kind == "Treadmill" then
		return cf * CFrame.new(0, BELT_Y + h, 0.3)
	elseif kind == "Squat" then
		return cf * CFrame.new(0, 0.2 + h, 0)
	elseif kind == "Dumbbells" or kind == "Cable" then
		return cf * CFrame.new(0, h, 0)
	elseif not posed then
		-- R6 / unknown rigs stand upright beside lying or seated equipment
		if kind == "PullUp" then
			return cf * CFrame.new(0, h, 0)
		end
		return cf * CFrame.new(EXIT_OFFSET[kind]) * CFrame.new(0, h, 0)
	elseif kind == "Bike" then
		return cf * CFrame.new(0, 3.35, 0.95)
	elseif kind == "Bench" then
		return cf * CFrame.new(0, 2.4, 0) * A(90)
	elseif kind == "Abs" then
		return cf * CFrame.new(0, 0.75, 0) * A(90)
	elseif kind == "PullUp" then
		return cf * CFrame.new(0, 9.5 - 3.4, 0)
	end
	return cf * CFrame.new(0, h, 0)
end

local function findJoints(character: Model): { [string]: Motor6D }
	local wanted = {}
	for _, name in JOINT_NAMES do
		wanted[name] = true
	end
	local joints = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and wanted[d.Name] then
			joints[d.Name] = d
		end
	end
	return joints
end

local function hasLimbJoints(joints: { [string]: Motor6D }): boolean
	for _, name in { "LeftShoulder", "RightShoulder", "LeftElbow", "RightElbow", "LeftHip", "RightHip", "LeftKnee", "RightKnee", "Waist" } do
		if not joints[name] then
			return false
		end
	end
	return true
end

local function poseOffset(pose: Pose, name: string): CFrame
	return pose.base[name] or CFrame.identity
end

local function setBase(s: Session, names: { [string]: any }?)
	local pose = POSES[s.kind]
	for name, motor in s.joints do
		if (names == nil or names[name] ~= nil) and motor.Parent then
			motor.C0 = s.orig[motor] * poseOffset(pose, name)
		end
	end
end

local function holdProps(s: Session)
	local character = s.character
	local pose = POSES[s.kind]
	local upper = character:FindFirstChild("UpperTorso") :: BasePart?
	local lhand = character:FindFirstChild("LeftHand") :: BasePart?
	local rhand = character:FindFirstChild("RightHand") :: BasePart?
	local kind = s.kind
	if kind == "Bench" and upper then
		local parts = barbellParts(CFrame.new(), 6.6, nil)
		s.barWeld = attachProp(parts, upper, pose.barRest or CFrame.new(), character)
		table.insert(s.props, parts[1].Parent :: Instance)
	elseif kind == "Squat" and upper then
		local parts = barbellParts(CFrame.new(), 6.8, nil)
		attachProp(parts, upper, CFrame.new(0, 0.85, 0.65), character)
		table.insert(s.props, parts[1].Parent :: Instance)
	elseif kind == "Dumbbells" and lhand and rhand then
		for _, hand in { lhand, rhand } do
			local parts = dumbbellParts(CFrame.new(), nil)
			attachProp(parts, hand, CFrame.new(0, -0.2, 0), character)
			table.insert(s.props, parts[1].Parent :: Instance)
		end
	elseif kind == "Cable" and lhand and rhand and s.station.pulleys then
		for i, hand in { lhand, rhand } do
			local parts = handleParts(CFrame.new(), nil)
			attachProp(parts, hand, CFrame.new(0, -0.2, 0), character)
			local beam = Instance.new("Beam")
			beam.Attachment0 = s.station.pulleys[i]
			beam.Attachment1 = parts[1]:FindFirstChild("Cable") :: Attachment
			beam.Width0 = 0.07
			beam.Width1 = 0.07
			beam.FaceCamera = true
			beam.Segments = 1
			beam.Color = ColorSequence.new(Color3.fromRGB(30, 30, 30))
			beam.Parent = parts[1]
			table.insert(s.props, parts[1].Parent :: Instance)
		end
	else
		return
	end
	for _, p in s.station.hidden do
		p.Transparency = 1
		for _, d in p:GetChildren() do
			if d:IsA("Beam") then
				d.Enabled = false
			end
		end
	end
end

local function playLoops(s: Session)
	local loop = POSES[s.kind].loop
	if not loop then
		return
	end
	local info = TweenInfo.new(loop.period, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	for name, pair in loop.joints do
		local motor = s.joints[name]
		if motor then
			motor.C0 = s.orig[motor] * pair[1]
			local t = TweenService:Create(motor, info, { C0 = s.orig[motor] * pair[2] })
			t:Play()
			table.insert(s.loopTweens, t)
		end
	end
end

local function playRep(s: Session)
	local rep = POSES[s.kind].rep
	if not s.posed or not rep then
		return
	end
	for _, t in s.repTweens do
		t:Cancel()
	end
	table.clear(s.repTweens)
	setBase(s, rep.joints)
	local info = TweenInfo.new(rep.time, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true)
	local function go(inst: Instance, goal: { [string]: any })
		local t = TweenService:Create(inst, info, goal)
		t:Play()
		table.insert(s.repTweens, t)
	end
	for name, offset in rep.joints do
		local motor = s.joints[name]
		if motor and motor.Parent then
			go(motor, { C0 = s.orig[motor] * offset })
		end
	end
	if rep.root and s.root.Parent then
		s.root.CFrame = s.rootCF
		go(s.root, { CFrame = s.rootCF + rep.root })
	end
	local barRest = POSES[s.kind].barRest
	if rep.bar and s.barWeld and barRest and s.barWeld.Parent then
		s.barWeld.C0 = barRest
		go(s.barWeld, { C0 = rep.bar })
	end
end

local function sendStart(player: Player, s: Session)
	local g = gymSection(player)
	GymSession:FireClient(player, "start", {
		kind = s.kind,
		start = s.start,
		seed = s.seed,
		goodReps = s.goodReps,
		progress = progressFor(player, s.kind),
		challenge = if g then challengeInfo(g) else nil,
		posed = s.posed,
	})
end

local stopSession: (Player, boolean?) -> ()

local function startSession(player: Player, station: Station)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	local joints = if humanoid.RigType == Enum.HumanoidRigType.R15 then findJoints(character) else {}
	local posed = humanoid.RigType == Enum.HumanoidRigType.R15 and hasLimbJoints(joints)
	if not posed then
		joints = {}
	end
	local h = standHeight(humanoid, root)
	local s: Session = {
		player = player,
		station = station,
		kind = station.kind,
		character = character,
		humanoid = humanoid,
		root = root,
		posed = posed,
		joints = joints,
		orig = {},
		rootCF = rootPlacement(station.kind, station.cf, h, posed),
		exitCF = station.cf * CFrame.new(EXIT_OFFSET[station.kind]) * CFrame.new(0, h + 0.2, 0),
		loopTweens = {},
		repTweens = {},
		props = {},
		barWeld = nil,
		start = workspace:GetServerTimeNow(),
		seed = math.random(1, 1_000_000),
		goodReps = 0,
		lastPress = 0,
		lastGood = 0,
		repTimes = {},
		conns = {},
	}
	for _, motor in joints do
		s.orig[motor] = motor.C0
	end
	sessions[player] = s
	station.user = player
	station.prompt.Enabled = false

	if humanoid.SeatPart then
		humanoid.Sit = false
	end
	humanoid.PlatformStand = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.Anchored = true
	root.CFrame = s.rootCF

	if posed then
		setBase(s, nil)
		holdProps(s)
		playLoops(s)
	end
	if station.stripes or station.crank then
		animatedStations[station] = true
	end

	table.insert(s.conns, humanoid.Died:Connect(function()
		stopSession(player, true)
	end))
	table.insert(s.conns, character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			stopSession(player, true)
		end
	end))
	table.insert(s.conns, player:GetAttributeChangedSignal("Interior"):Connect(function()
		if player:GetAttribute("Interior") ~= INTERIOR then
			stopSession(player, true)
		end
	end))

	player:SetAttribute("Training", station.kind)
	sendStart(player, s)
	if station.kind == "Treadmill" then
		lastRaceMsg[player] = nil
		refreshRaces()
	end
end

stopSession = function(player: Player, skipTeleport: boolean?)
	local s = sessions[player]
	if not s then
		return
	end
	sessions[player] = nil
	for _, c in s.conns do
		c:Disconnect()
	end
	for _, t in s.loopTweens do
		t:Cancel()
	end
	for _, t in s.repTweens do
		t:Cancel()
	end
	for motor, c0 in s.orig do
		if motor.Parent then
			motor.C0 = c0
		end
	end
	for _, prop in s.props do
		prop:Destroy()
	end
	for _, p in s.station.hidden do
		p.Transparency = 0
		for _, d in p:GetChildren() do
			if d:IsA("Beam") then
				d.Enabled = true
			end
		end
	end
	local station = s.station
	station.user = nil
	station.prompt.Enabled = true
	animatedStations[station] = nil

	if s.root.Parent then
		if not skipTeleport and s.humanoid.Health > 0 then
			s.root.CFrame = s.exitCF
		end
		s.root.Anchored = false
		s.root.AssemblyLinearVelocity = Vector3.zero
		if player.Parent and s.root:IsDescendantOf(workspace) then
			pcall(function()
				s.root:SetNetworkOwner(player) -- hand physics back to the player's client
			end)
		end
	end
	if s.humanoid.Parent then
		s.humanoid.PlatformStand = false
	end
	if player.Parent then
		player:SetAttribute("Training", "")
		GymSession:FireClient(player, "stop")
	end
	if s.kind == "Treadmill" then
		cancelRaceFor(player, player.Name .. " stepped off the treadmill.")
		refreshRaces()
	end
end

local function tryStart(player: Player, station: Station)
	if not Net.allow(player, "GymStart", 0.8) then
		return
	end
	if sessions[player] or station.user or player:GetAttribute("Interior") ~= INTERIOR then
		return
	end
	if not Net.alive(player) or Net.distance(player, station.cf.Position) > 14 then
		return
	end
	local g = gymSection(player)
	if not g then
		Net.notify(player, "IRON BOX", "Your profile is still loading.")
		return
	end
	if not hasAccess(player) then
		Net.notify(player, "PASS EXPIRED", "Your day pass ran out. Renew at the front desk.")
		GymSession:FireClient(player, "offer", { where = "desk" })
		return
	end
	local humanoid = (player.Character :: Model):FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart then
		return -- sitting in a car or chair
	end
	startSession(player, station)
end

GymLeave.OnServerEvent:Connect(function(player: Player)
	if Net.allow(player, "GymLeave", 0.3) then
		stopSession(player, false)
	end
end)

---------------------------------------------------------------------------
-- Reps
---------------------------------------------------------------------------
GymRep.OnServerEvent:Connect(function(player: Player, pressTime: any)
	if type(pressTime) ~= "number" or pressTime ~= pressTime or not Net.allow(player, "GymRep", 0.15) then
		return
	end
	local s = sessions[player]
	if not s or not Net.alive(player) then
		return
	end
	local g = gymSection(player)
	local data = PlayerData.get(player)
	if not g or not data then
		return
	end

	-- The client reports when it pressed (server clock). Only accept a time
	-- inside a latency window that ends now, and never one before the last press.
	local now = workspace:GetServerTimeNow()
	local window = math.clamp(player:GetNetworkPing() * 2 + 0.15, 0.2, 0.7)
	local t = math.clamp(pressTime, now - window, now)
	if t <= s.lastPress then
		return
	end
	s.lastPress = t

	local def = STATIONS[s.kind]
	local quality = GymConfig.judge(s.kind, t, s.start, s.seed, s.goodReps)
	if quality == "miss" then
		GymSession:FireClient(player, "result", { quality = "miss", goodReps = s.goodReps })
		return
	end

	-- rate limits for good reps
	local clock = os.clock()
	if clock - s.lastGood < GymConfig.MIN_REP_INTERVAL - 0.05 then
		GymSession:FireClient(player, "result", { quality = "tooFast", goodReps = s.goodReps })
		return
	end
	local recent = {}
	for _, rt in s.repTimes do
		if clock - rt < 60 then
			table.insert(recent, rt)
		end
	end
	s.repTimes = recent
	if #recent >= GymConfig.MAX_REPS_PER_MINUTE then
		GymSession:FireClient(player, "result", { quality = "tooFast", goodReps = s.goodReps })
		return
	end
	table.insert(s.repTimes, clock)
	s.lastGood = clock
	s.goodReps += 1

	-- fatigue
	local unix = os.time()
	local fatigue = GymConfig.currentFatigue(g.fatigue, g.fatigueAt, unix)
	local efficiency = GymConfig.efficiency(fatigue)
	g.fatigue = math.min(100, fatigue + GymConfig.FATIGUE_PER_REP)
	g.fatigueAt = unix
	g.totalReps += 1

	-- stat XP
	local perfect = quality == "perfect"
	local gains = {}
	for _, entry in def.stats do
		local stat = entry[1]
		local amount = GymConfig.statGain(data.stats[stat] or 1, entry[2], perfect, efficiency)
		PlayerData.addStatXP(player, stat, amount)
		table.insert(gains, { stat = stat, amount = amount })
	end
	local xp = if perfect then GymConfig.PLAYER_XP_PERFECT else GymConfig.PLAYER_XP_GOOD
	PlayerData.addXP(player, xp)

	-- daily challenge
	ensureDay(g)
	local ch = GymConfig.challengeFor(g.challengeDay)
	if not g.challengeDone and ch.station == s.kind then
		g.challengeProgress += 1
		if g.challengeProgress >= ch.reps then
			g.challengeProgress = ch.reps
			g.challengeDone = true
			PlayerData.addCash(player, ch.cash, "Iron Box daily challenge")
			PlayerData.addXP(player, ch.xp)
			Net.notify(player, "CHALLENGE COMPLETE", string.format("%s  ·  +$%d  +%d XP", ch.text, ch.cash, ch.xp))
		end
	end
	PlayerData.markChanged(player)

	playRep(s)
	GymSession:FireClient(player, "result", {
		quality = quality,
		gains = gains,
		xp = xp,
		goodReps = s.goodReps,
		fatigue = g.fatigue,
		efficiency = efficiency,
		progress = progressFor(player, s.kind),
		challenge = challengeInfo(g),
	})
	if s.kind == "Treadmill" then
		raceRep(player)
	end
end)

---------------------------------------------------------------------------
-- Buying passes
---------------------------------------------------------------------------
GymBuy.OnServerEvent:Connect(function(player: Player, kind: any)
	if (kind ~= "pass" and kind ~= "member") or not Net.allow(player, "GymBuy", 1) then
		return
	end
	local g = gymSection(player)
	if not g then
		return
	end
	local interior = player:GetAttribute("Interior") or ""
	local door = doorPart
	local atDoor = interior == "" and door ~= nil and Net.distance(player, door.Position) <= 18
	local inside = interior == INTERIOR
	if not atDoor and not inside then
		Net.notify(player, "IRON BOX", "Head to the Iron Box Gym to buy a pass.")
		return
	end
	if g.member then
		Net.notify(player, "IRON BOX", "You're already a member. Just walk in!")
		GymSession:FireClient(player, "bought", { member = true })
		if atDoor then
			enterGym(player)
		end
		return
	end
	if kind == "member" then
		if not PlayerData.spendCash(player, GymConfig.MEMBERSHIP_PRICE, "Iron Box membership") then
			Net.notify(player, "NOT ENOUGH CASH", "Membership costs $" .. GymConfig.MEMBERSHIP_PRICE .. ".")
			return
		end
		g.member = true
		Net.notify(player, "WELCOME TO IRON BOX", "You're a member for life. Train any time.")
	else
		if not PlayerData.spendCash(player, GymConfig.DAY_PASS_PRICE, "Iron Box day pass") then
			Net.notify(player, "NOT ENOUGH CASH", "A day pass costs $" .. GymConfig.DAY_PASS_PRICE .. ".")
			return
		end
		g.passUntil = math.max(os.time(), g.passUntil) + GymConfig.DAY_PASS_SECONDS
		Net.notify(player, "DAY PASS", string.format("Good for %d minutes. Go get it!", math.ceil((g.passUntil - os.time()) / 60)))
	end
	PlayerData.markChanged(player)
	GymSession:FireClient(player, "bought", { member = g.member, passUntil = g.passUntil })
	if atDoor then
		enterGym(player)
	end
end)

---------------------------------------------------------------------------
-- Fitness app data
---------------------------------------------------------------------------
GymGetProgress.OnServerInvoke = function(player: Player)
	if not Net.allow(player, "GymGetProgress", 0.3) then
		return nil
	end
	local data = PlayerData.get(player)
	local g = data and data.sections.gym
	if not data or not g then
		return nil
	end
	if ensureDay(g) then
		PlayerData.markChanged(player)
	end
	local now = os.time()
	local fatigue = GymConfig.currentFatigue(g.fatigue, g.fatigueAt, now)
	return {
		stats = table.clone(data.stats),
		statXP = table.clone(data.statXP),
		perPoint = Config.STAT_XP_PER_POINT,
		member = g.member,
		passUntil = g.passUntil,
		passLeft = math.max(0, g.passUntil - now),
		trialUsed = g.trialUsed,
		access = accessText(g),
		fatigue = fatigue,
		efficiency = GymConfig.efficiency(fatigue),
		totalReps = g.totalReps,
		raceWins = g.raceWins,
		challenge = challengeInfo(g),
		gymPosition = gpsTarget,
		training = player:GetAttribute("Training") or "",
	}
end

---------------------------------------------------------------------------
-- Moving equipment (treadmill belts, bike pedals) while in use
---------------------------------------------------------------------------
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < 1 / 20 then
		return
	end
	local step = accumulator
	accumulator = 0
	for st in animatedStations do
		if st.stripes then
			st.phase = (st.phase + step * 7) % BELT_LEN
			local spacing = BELT_LEN / BELT_STRIPES
			for i, stripe in st.stripes do
				local z = ((i - 0.5) * spacing + st.phase) % BELT_LEN - BELT_LEN / 2
				stripe.CFrame = st.cf * CFrame.new(0, BELT_Y, z)
			end
		elseif st.crank then
			st.phase = (st.phase + step * 2 * math.pi / (2 * 0.42)) % (2 * math.pi)
			local hub = st.cf * CRANK_HUB
			for i = 1, 2 do
				local side = if i == 1 then -1 else 1
				local angle = st.phase + (if i == 1 then 0 else math.pi)
				local spin = hub * CFrame.Angles(angle, 0, 0)
				st.crank[i * 2 - 1].CFrame = spin * CFrame.new(side * 0.5, 0, -0.35)
				local pedalPos = (spin * CFrame.new(side * 0.75, 0, -0.7)).Position
				st.crank[i * 2].CFrame = CFrame.new(pedalPos) * hub.Rotation
			end
		end
	end
end)

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Gym.start(city: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Gym"
	folder.Parent = city

	origin = Places.REGIONS.Gym
	insideCF = CFrame.lookAt(L(0, 0, 37), L(0, 0, 20))
	buildInterior(folder)
	for _, st in stations do
		local station = st
		station.prompt.Triggered:Connect(function(player)
			tryStart(player, station)
		end)
	end

	-- door: Places.door with an access gate; build our own door if the building has none
	local door = Places.buildingDoor(city, GymConfig.BUILDING)
	if not door then
		warn("[CityGrind] Iron Box Gym door not found; building a stand-in door")
		door = part({ name = "Door", size = Vector3.new(6, 9, 0.4), cframe = CFrame.new(205, 4.5, -54.9), color = Color3.fromRGB(45, 35, 30), material = Enum.Material.Wood, parent = folder })
	end
	doorPart = door
	local realDoor = door :: BasePart
	buildKiosk(folder, realDoor)
	Places.door({
		name = INTERIOR,
		door = realDoor,
		inside = insideCF,
		exitAt = L(0, 0, 44.3),
		actionText = "Enter Gym",
		parent = folder,
		canEnter = function(player: Player)
			local g = gymSection(player)
			if not g then
				return false, "Your profile is still loading."
			end
			if hasAccess(player) then
				return true
			end
			if not g.trialUsed then
				g.trialUsed = true
				trialVisit[player] = true
				PlayerData.markChanged(player)
				Net.notify(player, "FREE TRIAL", "First visit's on us. After this it's a $" .. GymConfig.DAY_PASS_PRICE .. " day pass or $" .. GymConfig.MEMBERSHIP_PRICE .. " membership.")
				return true
			end
			GymSession:FireClient(player, "offer", { where = "door" })
			return false, nil
		end,
	})

	-- the free trial lasts one visit
	local lastInterior: { [Player]: string } = {}
	local function track(player: Player)
		player:SetAttribute("Training", "")
		lastInterior[player] = player:GetAttribute("Interior") or ""
		player:GetAttributeChangedSignal("Interior"):Connect(function()
			local now = player:GetAttribute("Interior") or ""
			if lastInterior[player] == INTERIOR and now ~= INTERIOR then
				trialVisit[player] = nil
			end
			lastInterior[player] = now
		end)
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		stopSession(player, true)
		cancelRaceFor(player, player.Name .. " left the city.")
		trialVisit[player] = nil
		lastInterior[player] = nil
		lastRaceMsg[player] = nil
	end)

	-- daily challenge board
	task.spawn(function()
		while true do
			updateBoard()
			task.wait(30)
		end
	end)
end

return Gym
