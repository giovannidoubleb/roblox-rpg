-- CITY GRIND: jobs (sections 40, 68, 77, 110).
-- Six real jobs with shift gameplay, levels 1-25 per job, pay that scales with
-- job level, and unlocks. The server owns every shift: it picks targets,
-- validates each step by distance and timing, and pays per completed step.
--
-- World (all under city.Jobs):
--   Job Center kiosk ........ (-40, 0, -48)  board + terminal, security sign-in, taxi rank
--   Delivery Depot .......... (-140, 0, 170) counter at z 160
--   Mama's takeout counter .. (86, 0, 40)
--   Warehouse ............... (85, 0, 175)   shelves -> truck bay on the east side
--   Construction Site ....... (195, 0, 178)  material piles + a structure that grows
--   Maple Row houses ........ x -286..-182, z 163..177 (delivery addresses)
--   Oak Street houses ....... x 166..254, z -204..-190 (delivery addresses)
--
-- Player attributes: Job (active job id or ""), JobLevel_<id>, JobXP_<id>, JobShifts_<id>.
-- Remotes: JobAction (client -> server: "start", jobId | "quit"),
--          JobState (server -> client: "state", payload | "end", summary | "open").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local JobsConfig = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("JobsConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Places = require(script.Parent:WaitForChild("Places"))

local JOBS = JobsConfig.JOBS
local Jobs = {}

---------------------------------------------------------------------------
-- Saved data: per-job level / XP / shifts / lifetime earnings
---------------------------------------------------------------------------
PlayerData.registerSection("jobs", function()
	local t = {}
	for _, id in JobsConfig.ORDER do
		t[id] = { level = 1, xp = 0, shifts = 0, earned = 0 }
	end
	return t
end)

PlayerData.onPublish(function(player: Player, data: any)
	local jobs = data.sections and data.sections.jobs
	if type(jobs) ~= "table" then
		return
	end
	for _, id in JobsConfig.ORDER do
		local j = jobs[id]
		if type(j) == "table" then
			player:SetAttribute("JobLevel_" .. id, j.level)
			player:SetAttribute("JobXP_" .. id, j.xp)
			player:SetAttribute("JobShifts_" .. id, j.shifts)
		end
	end
end)

local function jobRecord(player: Player, jobId: string): any
	local sec = PlayerData.section(player, "jobs")
	return sec and sec[jobId]
end

-- Adds job XP; returns true when the job levelled up.
local function addJobXP(player: Player, jobId: string, amount: number): boolean
	local rec = jobRecord(player, jobId)
	if not rec or amount <= 0 then
		return false
	end
	local levelled = false
	rec.xp += math.floor(amount)
	while rec.level < JobsConfig.MAX_LEVEL and rec.xp >= JobsConfig.xpToNext(rec.level) do
		rec.xp -= JobsConfig.xpToNext(rec.level)
		rec.level += 1
		levelled = true
		local unlockText = nil
		for _, u in JOBS[jobId].unlocks do
			if u.level == rec.level then
				unlockText = u.text
			end
		end
		Net.notify(player, "JOB LEVEL UP", JOBS[jobId].name .. " is now level " .. rec.level .. (if unlockText then ". Unlocked: " .. unlockText else "."))
	end
	if rec.level >= JobsConfig.MAX_LEVEL then
		rec.xp = 0
	end
	PlayerData.markChanged(player)
	return levelled
end

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local JobAction = Net.remote("RemoteEvent", "JobAction")
local JobState = Net.remote("RemoteEvent", "JobState")

---------------------------------------------------------------------------
-- Geometry helpers
---------------------------------------------------------------------------
local root: Folder
local function now(): number
	return Workspace:GetServerTimeNow()
end

local function part(p: { [string]: any }): BasePart
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
	b.Parent = p.parent or root
	return b
end

local function sign(target: BasePart, face: Enum.NormalId, text: string, textColor: Color3, bg: Color3?): SurfaceGui
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

local function billboard(adornee: BasePart, text: string, color: Color3, offsetY: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 40)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = 160
	gui.LightInfluence = 0
	gui.Parent = adornee
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 18
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = gui
	return label
end

-- ProximityPrompt factory. attrs: JobStart / JobOnly / JobOwner / JobBoard
-- (the client hides prompts that aren't meant for it; the server re-checks everything).
local function prompt(parent: Instance, action: string, object: string, opts: { [string]: any }?): ProximityPrompt
	local o = opts or {}
	local pr = Instance.new("ProximityPrompt")
	pr.ActionText = action
	pr.ObjectText = object
	pr.KeyboardKeyCode = Enum.KeyCode.E
	pr.GamepadKeyCode = Enum.KeyCode.ButtonX
	pr.HoldDuration = o.hold or 0
	pr.MaxActivationDistance = o.distance or 10
	pr.RequiresLineOfSight = false
	for _, key in { "JobStart", "JobOnly", "JobOwner", "JobBoard" } do
		if o[key] ~= nil then
			pr:SetAttribute(key, o[key])
		end
	end
	pr.Parent = parent
	return pr
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local r = character and character:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function flatDistance(player: Player, pos: Vector3): number
	local r = rootOf(player)
	return if r then flat(r.Position, pos) else math.huge
end

-- Height of the walkable surface at a spot: sidewalks are raised 0.5,
-- everything else the jobs use sits on the ground (top at 0.05).
local function groundY(pos: Vector3): number
	local ax, az = math.abs(pos.X), math.abs(pos.Z)
	local onMainWalk = az >= 16 and az <= 24 and ax > 16
	local onCrossWalk = ax >= 16 and ax <= 24 and az > 24
	return if onMainWalk or onCrossWalk then 0.5 else 0.05
end

---------------------------------------------------------------------------
-- Places in the world (filled by build functions)
---------------------------------------------------------------------------
type Address = { name: string, pos: Vector3 }
local ADDRESSES: { Address } = {
	{ name = "Corner Mart", pos = Vector3.new(-80, 0, 40) },
	{ name = "Fresh Cuts Barber", pos = Vector3.new(-135, 0, 40) },
	{ name = "Threads Clothing", pos = Vector3.new(-197, 0, 40) },
	{ name = "Maple Court Apts", pos = Vector3.new(-88, 0, -58) },
	{ name = "Iron Box Gym", pos = Vector3.new(216, 0, -48) },
}

-- Taxi curbs: sidewalk spots next to the road.
local CURBS = {
	{ name = "West End", pos = Vector3.new(-200, 0, 20) },
	{ name = "Threads Corner", pos = Vector3.new(-150, 0, -20) },
	{ name = "Bus Stop", pos = Vector3.new(-60, 0, 20) },
	{ name = "Subway Station", pos = Vector3.new(60, 0, -20) },
	{ name = "Mama's Kitchen", pos = Vector3.new(130, 0, 20) },
	{ name = "Gym Row", pos = Vector3.new(270, 0, -20) },
	{ name = "Court Side", pos = Vector3.new(20, 0, -130) },
	{ name = "North Cross", pos = Vector3.new(-20, 0, -200) },
	{ name = "South Cross", pos = Vector3.new(-20, 0, 110) },
	{ name = "Maple Row", pos = Vector3.new(20, 0, 200) },
	{ name = "Budget Wheels", pos = Vector3.new(200, 0, 20) },
	{ name = "Park Gate", pos = Vector3.new(-270, 0, -20) },
}

-- Security patrol ring, in walking order around the Neighborhood.
local PATROL = {
	Vector3.new(-20, 0, -180),
	Vector3.new(20, 0, -110),
	Vector3.new(100, 0, -20),
	Vector3.new(200, 0, -20),
	Vector3.new(270, 0, 20),
	Vector3.new(130, 0, 36),
	Vector3.new(20, 0, 100),
	Vector3.new(20, 0, 190),
	Vector3.new(-20, 0, 140),
	Vector3.new(-100, 0, 36),
	Vector3.new(-200, 0, 20),
	Vector3.new(-270, 0, -20),
	Vector3.new(-160, 0, -20),
	Vector3.new(-70, 0, -20),
}

-- Places where something suspicious can turn up (behind buildings, alleys).
local SUSPICIOUS = {
	Vector3.new(-110, 0, -114),
	Vector3.new(205, 0, -103),
	Vector3.new(-70, 0, 86),
	Vector3.new(70, 0, 86),
	Vector3.new(-185, 0, 86),
	Vector3.new(140, 0, -60),
	Vector3.new(-125, 0, 84),
	Vector3.new(30, 0, -60),
	Vector3.new(-240, 0, -60),
	Vector3.new(250, 0, 140),
	Vector3.new(-60, 0, 200),
}

local SUSPICIOUS_OUTCOMES = {
	"Just a raccoon in the trash. All clear.",
	"Found an unlocked back door and secured it.",
	"Kids tagging a wall ran off when they saw you.",
	"A lost dog. You called the number on its collar.",
	"Somebody's bike was left out. Logged it.",
	"A flickering light. Reported it to maintenance.",
}

local depotCounter: BasePart
local foodCounter: BasePart
local warehouse = { racks = {} :: { { spot: BasePart, box: BasePart } }, bay = nil :: BasePart?, truckBoxes = {} :: { BasePart }, loaded = 0 }
local site = {
	piles = {} :: { [string]: BasePart },
	pieces = {} :: { { part: BasePart, material: string, built: boolean, reservedBy: Player? } },
	board = nil :: TextLabel?,
	resetting = false,
}
local startPrompts: { [string]: { ProximityPrompt } } = {}

---------------------------------------------------------------------------
-- Shift state
---------------------------------------------------------------------------
local shifts: { [Player]: any } = {}

local VEHICLE_JOBS = { Delivery = true, FoodDelivery = true, Taxi = true }
local FOOT_SPEED = 45 -- studs/s: faster than sprinting or sliding
local VEHICLE_SPEED = 260 -- studs/s: faster than any car

local function maxSpeed(shift: any): number
	return if VEHICLE_JOBS[shift.job] then VEHICLE_SPEED else FOOT_SPEED
end

local vehiclesModule: any = nil
local function vehicles(): any
	if vehiclesModule == nil then
		local m = script.Parent:FindFirstChild("Vehicles")
		if m and m:IsA("ModuleScript") then
			local ok, result = pcall(require, m)
			vehiclesModule = if ok and type(result) == "table" then result else false
		else
			return nil
		end
	end
	return vehiclesModule or nil
end

-- True while the player is in the driver's seat of a car (not a bike/scooter).
local function isDrivingCar(player: Player): boolean
	if not JobsConfig.isCarKind(player:GetAttribute("Driving")) then
		return false
	end
	local V = vehicles()
	if V and type(V.drivingVehicle) == "function" then
		local ok, model = pcall(V.drivingVehicle, player)
		return ok and model ~= nil
	end
	return true
end

local function ownsCar(player: Player): boolean
	if isDrivingCar(player) then
		return true
	end
	if player:GetAttribute("OwnsCar") == true then
		return true
	end
	local V = vehicles()
	if V and type(V.ownedKinds) == "function" then
		local ok, kinds = pcall(V.ownedKinds, player)
		if ok and type(kinds) == "table" then
			for _, kind in kinds do
				if JobsConfig.isCarKind(kind) then
					return true
				end
			end
		end
	end
	return false
end

local function isSeated(player: Player): boolean
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	return (hum ~= nil and hum.SeatPart ~= nil) or (player:GetAttribute("Driving") or "") ~= ""
end

local function publish(shift: any)
	local player: Player = shift.player
	if not player.Parent then
		return
	end
	local def = JOBS[shift.job]
	JobState:FireClient(player, "state", {
		job = shift.job,
		objective = shift.objective,
		progress = shift.done,
		goal = shift.goal,
		word = def.stepWord,
		earned = shift.earned,
		endsAt = shift.endsAt,
		target = shift.target,
		targetName = shift.targetName,
		adornee = shift.adornee,
		ghost = shift.ghost,
		hotUntil = shift.hotUntil,
		combo = shift.combo,
	})
end

local function setObjective(shift: any, text: string, target: Vector3?, targetName: string?)
	shift.objective = text
	shift.target = target
	shift.targetName = targetName
	publish(shift)
end

-- Starts timing a step: it can't be finished faster than travel allows.
local function beginStep(shift: any, from: Vector3?)
	local r = rootOf(shift.player)
	shift.stepFrom = from or (if r then r.Position else Vector3.zero)
	shift.stepAt = now()
end

local function tooFast(shift: any, target: Vector3): boolean
	local needed = math.max(0.8, flat(shift.stepFrom, target) / maxSpeed(shift))
	if now() - shift.stepAt < needed then
		Net.notify(shift.player, "TOO FAST", "That was impossibly quick. Do the job properly.")
		return true
	end
	return false
end

-- Things created for this shift, destroyed when it ends.
local function track(shift: any, inst: Instance): Instance
	table.insert(shift.cleanup, inst)
	return inst
end

local function clearTracked(shift: any, inst: Instance?)
	if not inst then
		return
	end
	local i = table.find(shift.cleanup, inst)
	if i then
		table.remove(shift.cleanup, i)
	end
	inst:Destroy()
end

-- A glowing ground ring only the shift owner sees (client hides it for others).
local function ownerMarker(shift: any, pos: Vector3, label: string, color: Color3): BasePart
	local y = groundY(pos)
	local ring = part({
		name = "JobMarker",
		size = Vector3.new(0.2, 8, 8),
		cframe = CFrame.new(pos.X, y + 0.12, pos.Z) * CFrame.Angles(0, 0, math.pi / 2),
		color = color,
		material = Enum.Material.Neon,
		transparency = 0.35,
		collide = false,
		shape = Enum.PartType.Cylinder,
	})
	ring.CanQuery = false
	ring.CanTouch = false
	ring:SetAttribute("JobOwner", shift.player.UserId)
	billboard(ring, label, color, 6)
	return track(shift, ring) :: BasePart
end

---------------------------------------------------------------------------
-- Carrying: a prop welded in front of the body, arms raised (server-side so
-- everyone sees it)
---------------------------------------------------------------------------
local CARRY = {
	Parcel = { size = Vector3.new(2, 1.5, 1.6), color = Color3.fromRGB(190, 145, 95), material = Enum.Material.Cardboard, twoHands = true },
	Box = { size = Vector3.new(2.2, 1.8, 1.8), color = Color3.fromRGB(175, 130, 80), material = Enum.Material.Cardboard, twoHands = true },
	Food = { size = Vector3.new(1.1, 1.3, 0.8), color = Color3.fromRGB(200, 50, 40), material = Enum.Material.Fabric, twoHands = false },
	Bricks = { size = Vector3.new(2, 1.2, 1.4), color = Color3.fromRGB(165, 70, 50), material = Enum.Material.Brick, twoHands = true },
	Planks = { size = Vector3.new(6, 0.4, 1.2), color = Color3.fromRGB(190, 150, 95), material = Enum.Material.WoodPlanks, twoHands = true },
	Beams = { size = Vector3.new(6, 0.7, 0.7), color = Color3.fromRGB(120, 125, 135), material = Enum.Material.DiamondPlate, twoHands = true },
}

local function dropCarry(shift: any)
	if shift.carry then
		shift.carry:Destroy()
		shift.carry = nil
	end
	for motor, c0 in shift.savedC0 or {} do
		if motor.Parent then
			motor.C0 = c0
		end
	end
	shift.savedC0 = nil
end

local function setCarry(shift: any, kind: string, count: number?)
	dropCarry(shift)
	local character = shift.player.Character
	if not character then
		return
	end
	local spec = CARRY[kind]
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not torso or not torso:IsA("BasePart") then
		return
	end
	local holder = Instance.new("Model")
	holder.Name = "JobCarry"
	local stack = math.clamp(count or 1, 1, 3)
	local function piece(offset: CFrame, base: BasePart)
		local p = Instance.new("Part")
		p.Name = kind
		p.Size = spec.size
		p.Color = spec.color
		p.Material = spec.material
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.CFrame = base.CFrame * offset
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = base
		weld.Part1 = p
		weld.Parent = p
		p.Parent = holder
		return p
	end
	if spec.twoHands then
		for i = 1, stack do
			piece(CFrame.new(0, -0.1 + (i - 1) * spec.size.Y, -(torso.Size.Z / 2 + spec.size.Z / 2 + 0.2)), torso)
		end
		-- raise both arms forward (R15 shoulders keep their rotation in C0)
		local saved = {}
		for _, name in { "RightUpperArm", "LeftUpperArm" } do
			local arm = character:FindFirstChild(name)
			local motor = arm and arm:FindFirstChild(if name == "RightUpperArm" then "RightShoulder" else "LeftShoulder")
			if motor and motor:IsA("Motor6D") then
				saved[motor] = motor.C0
				motor.C0 = motor.C0 * CFrame.Angles(math.rad(70), 0, 0)
			end
		end
		shift.savedC0 = saved
	elseif hand and hand:IsA("BasePart") then
		piece(CFrame.new(0, -(hand.Size.Y / 2 + spec.size.Y / 2 - 0.2), 0), hand)
	end
	holder.Parent = character
	shift.carry = holder
end

---------------------------------------------------------------------------
-- Paying for work
---------------------------------------------------------------------------
local STAT_XP = {
	Warehouse = { Strength = 6 },
	Construction = { Strength = 8 },
	Security = { Stamina = 6, Speed = 3 },
}

local function completeStep(shift: any, amount: number)
	local player = shift.player
	local def = JOBS[shift.job]
	amount = math.max(1, math.floor(amount))
	PlayerData.addCash(player, amount, def.name .. " shift")
	shift.earned += amount
	shift.done += 1
	PlayerData.addXP(player, JobsConfig.PLAYER_XP_PER_STEP)
	if addJobXP(player, shift.job, JobsConfig.JOB_XP_PER_STEP) then
		shift.levelledUp = true
	end
	for stat, n in STAT_XP[shift.job] or {} do
		PlayerData.addStatXP(player, stat, n)
	end
	-- carrying parcels / food on foot is cardio
	if (shift.job == "Delivery" or shift.job == "FoodDelivery") and not isSeated(player) then
		PlayerData.addStatXP(player, "Stamina", 3)
	end
end

local endShift: (Player, string) -> ()

local function finishIfDone(shift: any): boolean
	if shift.done >= shift.goal then
		endShift(shift.player, "complete")
		return true
	end
	return false
end

-- Pick a random entry, avoiding `avoid` and preferring ones at least minDist from `from`.
local function pickFrom<T>(list: { T }, getPos: (T) -> Vector3, from: Vector3, minDist: number, avoid: T?): T
	local good = {}
	for _, item in list do
		if item ~= avoid and flat(getPos(item), from) >= minDist then
			table.insert(good, item)
		end
	end
	if #good == 0 then
		for _, item in list do
			if item ~= avoid then
				table.insert(good, item)
			end
		end
	end
	return good[math.random(#good)]
end

local function addressPos(a: Address): Vector3
	return a.pos
end

---------------------------------------------------------------------------
-- 1. Delivery
---------------------------------------------------------------------------
local function deliveryNextDrop(shift: any)
	local r = rootOf(shift.player)
	local from = if r then r.Position else depotCounter.Position
	local addr = pickFrom(ADDRESSES, addressPos, from, 60, shift.address)
	shift.address = addr
	shift.phase = "drop"
	clearTracked(shift, shift.dropZone)
	local zone = ownerMarker(shift, addr.pos, "📦 " .. addr.name, Color3.fromRGB(255, 190, 80))
	shift.dropZone = zone
	local pr = prompt(zone, "Deliver parcel", addr.name, { hold = 0.5, distance = 12, JobOwner = shift.player.UserId })
	local myShift = shift
	pr.Triggered:Connect(function(player)
		local s = shifts[player]
		if s ~= myShift or s.phase ~= "drop" or s.address ~= addr then
			return
		end
		if flatDistance(player, addr.pos) > 14 or tooFast(s, addr.pos) then
			return
		end
		local dist = flat(s.stepFrom, addr.pos)
		local factor = math.clamp(0.8 + dist / 700, 0.8, 1.35)
		completeStep(s, JobsConfig.stepPay("Delivery", s.level) * factor)
		s.parcels -= 1
		if finishIfDone(s) then
			return
		end
		setCarry(s, "Parcel", s.parcels)
		beginStep(s, addr.pos)
		deliveryNextDrop(s)
	end)
	setObjective(shift, string.format("Deliver a parcel to %s (%d left)", addr.name, shift.parcels), addr.pos, addr.name)
end

local function deliveryStart(shift: any)
	shift.phase = "load"
	shift.parcels = 0
	setObjective(shift, "Load your parcels at the Depot counter", depotCounter.Position, "Depot counter")
end

local function deliveryLoad(player: Player)
	local s = shifts[player]
	if not s or s.job ~= "Delivery" or s.phase ~= "load" or Net.distance(player, depotCounter.Position) > 14 then
		return
	end
	s.parcels = s.goal
	setCarry(s, "Parcel", s.parcels)
	beginStep(s, depotCounter.Position)
	deliveryNextDrop(s)
end

---------------------------------------------------------------------------
-- 2. Food delivery
---------------------------------------------------------------------------
local function foodStart(shift: any)
	shift.phase = "pickup"
	shift.hotUntil = nil
	setObjective(shift, string.format("Pick up order %d at Mama's Kitchen", shift.done + 1), foodCounter.Position, "Mama's Kitchen")
end

local function foodPickup(player: Player)
	local s = shifts[player]
	if not s or s.job ~= "FoodDelivery" or s.phase ~= "pickup" or Net.distance(player, foodCounter.Position) > 14 then
		return
	end
	local addr = pickFrom(ADDRESSES, addressPos, foodCounter.Position, 80, s.address)
	s.address = addr
	s.phase = "deliver"
	local dist = flat(foodCounter.Position, addr.pos)
	s.orderDist = dist
	s.hotSeconds = math.floor(20 + dist / 14)
	s.hotUntil = now() + s.hotSeconds
	s.coldNotified = false
	setCarry(s, "Food")
	beginStep(s, foodCounter.Position)
	clearTracked(s, s.dropZone)
	local zone = ownerMarker(s, addr.pos, "🍔 " .. addr.name, Color3.fromRGB(255, 110, 80))
	s.dropZone = zone
	local pr = prompt(zone, "Hand over order", addr.name, { hold = 0.4, distance = 12, JobOwner = player.UserId })
	local myShift = s
	pr.Triggered:Connect(function(p)
		local cur = shifts[p]
		if cur ~= myShift or cur.phase ~= "deliver" or cur.address ~= addr then
			return
		end
		if flatDistance(p, addr.pos) > 14 or tooFast(cur, addr.pos) then
			return
		end
		local base = JobsConfig.stepPay("FoodDelivery", cur.level) * math.clamp(0.7 + cur.orderDist / 600, 0.7, 1.2)
		local remaining = cur.hotUntil - now()
		local pay, note
		if remaining > 0 then
			local tip = base * 0.45 * (remaining / cur.hotSeconds)
			pay = base + tip
			note = string.format("Hot! Tip $%d", math.floor(tip))
			if not isSeated(p) then
				PlayerData.addStatXP(p, "Speed", 2)
			end
		else
			pay = base * 0.6
			note = "The food went cold: no tip, reduced pay"
		end
		completeStep(cur, pay)
		Net.notify(p, "ORDER DELIVERED", string.format("+$%d. %s", math.floor(pay), note))
		dropCarry(cur)
		clearTracked(cur, cur.dropZone)
		cur.dropZone = nil
		if finishIfDone(cur) then
			return
		end
		foodStart(cur)
	end)
	setObjective(s, "Deliver the order to " .. addr.name .. " while it's hot", addr.pos, addr.name)
end

---------------------------------------------------------------------------
-- 3. Taxi
---------------------------------------------------------------------------
local SKIN = { Color3.fromRGB(255, 220, 180), Color3.fromRGB(230, 180, 140), Color3.fromRGB(180, 120, 80), Color3.fromRGB(120, 80, 50), Color3.fromRGB(80, 55, 40) }
local SHIRT = { Color3.fromRGB(200, 60, 60), Color3.fromRGB(60, 110, 200), Color3.fromRGB(240, 200, 60), Color3.fromRGB(60, 160, 90), Color3.fromRGB(240, 240, 240), Color3.fromRGB(40, 40, 45) }
local PANTS = { Color3.fromRGB(40, 50, 90), Color3.fromRGB(30, 30, 30), Color3.fromRGB(110, 90, 60), Color3.fromRGB(80, 80, 85) }

local function pick<T>(list: { T }): T
	return list[math.random(#list)]
end

-- A simple part-built person, used if the humanoid rig can't be made.
local function fallbackPerson(skin: Color3, shirt: Color3, pants: Color3): Model
	local m = Instance.new("Model")
	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = shirt
	torso.Anchored = true
	torso.Parent = m
	m.PrimaryPart = torso
	local function limb(name: string, size: Vector3, offset: Vector3, color: Color3, shape: Enum.PartType?)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Anchored = true
		if shape then
			p.Shape = shape
		end
		p.CFrame = torso.CFrame + offset
		p.Parent = m
	end
	limb("Head", Vector3.new(1.3, 1.3, 1.3), Vector3.new(0, 1.65, 0), skin, Enum.PartType.Ball)
	limb("LeftArm", Vector3.new(0.9, 2, 0.9), Vector3.new(-1.45, 0, 0), skin)
	limb("RightArm", Vector3.new(0.9, 2, 0.9), Vector3.new(1.45, 0, 0), skin)
	limb("LeftLeg", Vector3.new(0.95, 2, 0.95), Vector3.new(-0.5, -2, 0), pants)
	limb("RightLeg", Vector3.new(0.95, 2, 0.95), Vector3.new(0.5, -2, 0), pants)
	m:SetAttribute("HipOffset", 3)
	return m
end

local function makePassenger(): Model
	local skin, shirt, pants = pick(SKIN), pick(SHIRT), pick(PANTS)
	local ok, model = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		desc.HeadColor = skin
		desc.LeftArmColor = skin
		desc.RightArmColor = skin
		desc.TorsoColor = shirt
		desc.LeftLegColor = pants
		desc.RightLegColor = pants
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	local m: Model
	if ok and typeof(model) == "Instance" and model:IsA("Model") and model:FindFirstChild("HumanoidRootPart") then
		m = model
		local hum = m:FindFirstChildOfClass("Humanoid")
		local hrp = m:FindFirstChild("HumanoidRootPart") :: BasePart
		hrp.Anchored = true
		if hum then
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			m:SetAttribute("HipOffset", hum.HipHeight + hrp.Size.Y / 2)
		else
			m:SetAttribute("HipOffset", 3)
		end
		-- hailing a cab: right arm up
		local arm = m:FindFirstChild("RightUpperArm")
		local shoulder = arm and arm:FindFirstChild("RightShoulder")
		if shoulder and shoulder:IsA("Motor6D") then
			shoulder.C0 = shoulder.C0 * CFrame.Angles(0, 0, math.rad(150))
		end
	else
		m = fallbackPerson(skin, shirt, pants)
	end
	m.Name = "TaxiPassenger"
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
		end
	end
	return m
end

local function placePerson(m: Model, pos: Vector3, faceTo: Vector3)
	local y = groundY(pos) + (m:GetAttribute("HipOffset") or 3)
	local at = Vector3.new(pos.X, y, pos.Z)
	local look = Vector3.new(faceTo.X, y, faceTo.Z)
	if (look - at).Magnitude < 0.1 then
		look = at + Vector3.new(0, 0, -1)
	end
	m:PivotTo(CFrame.lookAt(at, look))
end

local function taxiNextFare(shift: any)
	local r = rootOf(shift.player)
	local from = if r then r.Position else JobsConfig.START.Taxi
	local curb = pickFrom(CURBS, function(c)
		return c.pos
	end, from, 70, shift.dest)
	shift.curb = curb
	shift.phase = "pickup"
	clearTracked(shift, shift.marker)
	shift.marker = ownerMarker(shift, curb.pos, "🙋 Your passenger", Color3.fromRGB(255, 210, 50))
	setObjective(shift, "Drive to your passenger at " .. curb.name, curb.pos, curb.name)
	local myShift = shift
	task.spawn(function()
		local person = makePassenger()
		if shifts[myShift.player] ~= myShift or myShift.curb ~= curb then
			person:Destroy()
			return
		end
		-- face the road: sidewalks along x face z = 0, along z face x = 0
		local face = if math.abs(curb.pos.Z) <= 24 then Vector3.new(curb.pos.X, 0, 0) else Vector3.new(0, 0, curb.pos.Z)
		person.Parent = root
		placePerson(person, curb.pos, face)
		track(myShift, person)
		myShift.passenger = person
	end)
end

local function taxiStart(shift: any)
	taxiNextFare(shift)
	if not isDrivingCar(shift.player) then
		shift.objective = "Get in your car, then pick up your passenger"
		publish(shift)
	end
end

local function taxiTick(shift: any)
	local player = shift.player
	local r = rootOf(player)
	if not r then
		return
	end
	local driving = isDrivingCar(player)
	local speed = r.AssemblyLinearVelocity.Magnitude
	if shift.phase == "pickup" then
		local curb = shift.curb
		local wantText = if driving then "Drive to your passenger at " .. curb.name else "Get in your car, then pick up your passenger"
		if shift.objective ~= wantText then
			setObjective(shift, wantText, curb.pos, curb.name)
		end
		if driving and shift.passenger and flat(r.Position, curb.pos) < 20 then
			if speed > 35 then
				if not shift.slowWarned then
					shift.slowWarned = true
					Net.notify(player, "SLOW DOWN", "Stop next to the passenger so they can get in.")
				end
				return
			end
			shift.slowWarned = false
			-- the passenger gets in
			shift.passenger.Parent = nil
			local V = vehicles()
			if V and type(V.drivingVehicle) == "function" then
				local ok, car = pcall(V.drivingVehicle, player)
				if ok and typeof(car) == "Instance" then
					car:SetAttribute("TaxiPassenger", true)
					shift.car = car
				end
			end
			clearTracked(shift, shift.marker)
			local dest = pickFrom(CURBS, function(c)
				return c.pos
			end, curb.pos, 150, curb)
			shift.dest = dest
			shift.phase = "ride"
			beginStep(shift, curb.pos)
			shift.marker = ownerMarker(shift, dest.pos, "🏁 Drop-off: " .. dest.name, Color3.fromRGB(80, 220, 120))
			Net.notify(player, "PASSENGER ON BOARD", "Take them to " .. dest.name .. ".")
			setObjective(shift, "Drive your passenger to " .. dest.name, dest.pos, dest.name)
		end
	elseif shift.phase == "ride" then
		local dest = shift.dest
		local wantText = if driving then "Drive your passenger to " .. dest.name else "Get back in your car, your passenger is waiting"
		if shift.objective ~= wantText then
			setObjective(shift, wantText, dest.pos, dest.name)
		end
		if driving and flat(r.Position, dest.pos) < 24 and speed < 35 then
			if tooFast(shift, dest.pos) then
				return
			end
			local dist = flat(shift.stepFrom, dest.pos)
			local factor = math.clamp(0.8 + (dist - 150) / 400, 0.8, 1.4)
			local fare = JobsConfig.stepPay("Taxi", shift.level) * factor
			completeStep(shift, fare)
			Net.notify(player, "FARE PAID", string.format("+$%d for a %dm ride.", math.floor(fare), math.floor(dist / 3.57)))
			if shift.car and shift.car.Parent then
				shift.car:SetAttribute("TaxiPassenger", nil)
			end
			-- the passenger steps out and walks off
			local person = shift.passenger
			shift.passenger = nil
			if person then
				local i = table.find(shift.cleanup, person)
				if i then
					table.remove(shift.cleanup, i)
				end
				person.Parent = root
				-- step out onto the sidewalk, facing away from the road
				local away = if math.abs(dest.pos.Z) <= 24 then Vector3.new(0, 0, if dest.pos.Z >= 0 then 1 else -1) else Vector3.new(if dest.pos.X >= 0 then 1 else -1, 0, 0)
				placePerson(person, dest.pos + away * 2, dest.pos + away * 10)
				local anchor = person.PrimaryPart or person:FindFirstChild("HumanoidRootPart")
				if anchor and anchor:IsA("BasePart") then
					billboard(anchor, "Thanks! ⭐⭐⭐⭐⭐", Color3.fromRGB(255, 220, 80), 4)
				end
				task.delay(4, function()
					person:Destroy()
				end)
			end
			clearTracked(shift, shift.marker)
			shift.marker = nil
			if finishIfDone(shift) then
				return
			end
			taxiNextFare(shift)
		end
	end
end

---------------------------------------------------------------------------
-- 4. Warehouse
---------------------------------------------------------------------------
local function warehouseNextBox(shift: any)
	local options = {}
	for i = 1, #warehouse.racks do
		if i ~= shift.rack then
			table.insert(options, i)
		end
	end
	shift.rack = options[math.random(#options)]
	shift.phase = "pick"
	local rack = warehouse.racks[shift.rack]
	shift.adornee = rack.box
	setObjective(shift, "Grab the highlighted box from the shelf", rack.spot.Position, "Shelf " .. shift.rack)
end

local function warehouseStart(shift: any)
	shift.combo = 0
	shift.lastLoadAt = 0
	warehouseNextBox(shift)
end

local function warehouseGrab(player: Player, rackIndex: number)
	local s = shifts[player]
	if not s or s.job ~= "Warehouse" then
		return
	end
	local rack = warehouse.racks[rackIndex]
	if Net.distance(player, rack.spot.Position) > 12 then
		return
	end
	if s.phase ~= "pick" then
		Net.notify(player, "HANDS FULL", "Load the box you're carrying onto the truck first.")
		return
	end
	if s.rack ~= rackIndex then
		Net.notify(player, "WRONG SHELF", "Grab the highlighted box.")
		return
	end
	setCarry(s, "Box")
	s.phase = "load"
	s.adornee = nil
	beginStep(s, rack.spot.Position)
	setObjective(s, "Carry the box to the truck bay and load it", warehouse.bay.Position, "Truck bay")
end

local function truckAddBox()
	warehouse.loaded += 1
	local box = warehouse.truckBoxes[warehouse.loaded]
	if box then
		box.Transparency = 0
	end
	if warehouse.loaded >= #warehouse.truckBoxes then
		-- full truck "leaves" and a fresh one backs in
		warehouse.loaded = 0
		task.delay(2, function()
			for _, b in warehouse.truckBoxes do
				b.Transparency = 1
			end
		end)
	end
end

local function warehouseLoad(player: Player)
	local s = shifts[player]
	local bay = warehouse.bay
	if not s or s.job ~= "Warehouse" or not bay or s.phase ~= "load" then
		return
	end
	if Net.distance(player, bay.Position) > 14 or tooFast(s, bay.Position) then
		return
	end
	local t = now()
	if s.lastLoadAt > 0 and t - s.lastLoadAt <= 14 then
		s.combo = math.min(5, s.combo + 1)
	else
		s.combo = 0
	end
	s.lastLoadAt = t
	local pay = JobsConfig.stepPay("Warehouse", s.level) * (1 + 0.1 * s.combo)
	completeStep(s, pay)
	truckAddBox()
	dropCarry(s)
	if finishIfDone(s) then
		return
	end
	beginStep(s, bay.Position)
	warehouseNextBox(s)
end

---------------------------------------------------------------------------
-- 5. Construction
---------------------------------------------------------------------------
local function updateSiteBoard()
	if site.board then
		local built = 0
		for _, piece in site.pieces do
			if piece.built then
				built += 1
			end
		end
		site.board.Text = if site.resetting then "COMPLETE! NEW BUILD STARTING..." else string.format("BUILD PROGRESS  %d / %d", built, #site.pieces)
	end
end

local function constructionAssign(shift: any)
	shift.phase = "assign"
	shift.piece = nil
	shift.ghost = nil
	clearTracked(shift, shift.spot)
	shift.spot = nil
	if not site.resetting then
		for i, piece in site.pieces do
			if not piece.built and not piece.reservedBy then
				piece.reservedBy = shift.player
				shift.piece = i
				break
			end
		end
	end
	if not shift.piece then
		local waitText = "The crew is clearing the site. Stand by..."
		if shift.objective ~= waitText then
			setObjective(shift, waitText, nil, nil)
		end
		return
	end
	local piece = site.pieces[shift.piece]
	shift.phase = "fetch"
	if shift.carryKind == piece.material then
		-- already holding the right material
		shift.phase = "place"
	end
	if shift.phase == "fetch" then
		shift.ghost = { cframe = piece.part.CFrame, size = piece.part.Size }
		setObjective(shift, "Grab " .. piece.material .. " from the material piles", site.piles[piece.material].Position, piece.material)
	else
		Jobs._showBuildSpot(shift)
	end
end

function Jobs._showBuildSpot(shift: any)
	local piece = site.pieces[shift.piece]
	local p = piece.part.Position
	local spotPos = Vector3.new(p.X, 0, p.Z)
	clearTracked(shift, shift.spot)
	local spot = part({
		name = "BuildSpot",
		size = Vector3.new(2, 4, 2),
		cframe = CFrame.new(spotPos + Vector3.new(0, 2.5, 0)),
		transparency = 1,
		collide = false,
	})
	spot.CanQuery = false
	spot.CanTouch = false
	spot:SetAttribute("JobOwner", shift.player.UserId)
	track(shift, spot)
	shift.spot = spot
	local pr = prompt(spot, "Place " .. piece.material, "Build spot", { hold = 0.8, distance = 12, JobOwner = shift.player.UserId })
	local myShift = shift
	local myPiece = shift.piece
	pr.Triggered:Connect(function(player)
		local s = shifts[player]
		if s ~= myShift or s.phase ~= "place" or s.piece ~= myPiece then
			return
		end
		if flatDistance(player, spotPos) > 14 or tooFast(s, spotPos) then
			return
		end
		local pc = site.pieces[myPiece]
		if pc.built then
			constructionAssign(s)
			return
		end
		pc.built = true
		pc.reservedBy = nil
		pc.part.CanCollide = true
		pc.part.CanQuery = true
		pc.part.Transparency = 0.7
		TweenService:Create(pc.part, TweenInfo.new(0.5), { Transparency = 0 }):Play()
		completeStep(s, JobsConfig.stepPay("Construction", s.level))
		s.carryKind = nil
		dropCarry(s)
		updateSiteBoard()
		-- whole structure done: bonus for everyone on site, then rebuild from scratch
		local allBuilt = true
		for _, other in site.pieces do
			if not other.built then
				allBuilt = false
			end
		end
		if allBuilt and not site.resetting then
			site.resetting = true
			updateSiteBoard()
			for _, other in shifts do
				if other.job == "Construction" then
					local bonus = math.floor(JobsConfig.stepPay("Construction", other.level))
					PlayerData.addCash(other.player, bonus, "Construction shift")
					other.earned += bonus
					Net.notify(other.player, "BUILDING COMPLETE", string.format("The crew finished the build! Bonus +$%d", bonus))
					publish(other)
				end
			end
			task.delay(8, function()
				for _, other in site.pieces do
					other.built = false
					other.part.Transparency = 1
					other.part.CanCollide = false
					other.part.CanQuery = false
				end
				site.resetting = false
				updateSiteBoard()
			end)
		end
		if finishIfDone(s) then
			return
		end
		beginStep(s, spotPos)
		constructionAssign(s)
	end)
	shift.ghost = { cframe = piece.part.CFrame, size = piece.part.Size }
	setObjective(shift, "Place the " .. piece.material .. " at the highlighted spot", spotPos, "Build spot")
end

local function constructionTake(player: Player, material: string)
	local s = shifts[player]
	local pile = site.piles[material]
	if not s or s.job ~= "Construction" or not pile or Net.distance(player, pile.Position) > 12 then
		return
	end
	if s.phase ~= "fetch" and s.phase ~= "place" then
		return
	end
	local piece = site.pieces[s.piece]
	if not piece then
		return
	end
	if piece.material ~= material then
		Net.notify(player, "WRONG MATERIAL", "The highlighted spot needs " .. piece.material .. ".")
		return
	end
	if s.phase == "place" then
		return
	end
	s.carryKind = material
	setCarry(s, material)
	s.phase = "place"
	beginStep(s, pile.Position)
	Jobs._showBuildSpot(s)
end

local function constructionStart(shift: any)
	constructionAssign(shift)
end

---------------------------------------------------------------------------
-- 6. Security
---------------------------------------------------------------------------
local function securityShowCheckpoint(shift: any)
	local pos = shift.route[shift.routeIndex]
	shift.phase = "patrol"
	clearTracked(shift, shift.marker)
	shift.marker = ownerMarker(shift, pos, string.format("🛡️ Checkpoint %d/%d", shift.routeIndex, #shift.route), Color3.fromRGB(110, 150, 255))
	setObjective(shift, string.format("Patrol on foot to checkpoint %d", shift.routeIndex), pos, "Checkpoint " .. shift.routeIndex)
end

local function securityStart(shift: any)
	local route = {}
	local n = #PATROL
	local startIndex = math.random(n)
	local dir = if math.random() < 0.5 then 1 else -1
	-- begin at the patrol point nearest the player when that's close
	local r = rootOf(shift.player)
	if r then
		local best, bestDist = startIndex, math.huge
		for i, p in PATROL do
			local d = flat(p, r.Position)
			if d < bestDist then
				best, bestDist = i, d
			end
		end
		startIndex = best
	end
	local length = 0
	local prev = if r then r.Position else PATROL[startIndex]
	for k = 0, shift.goal - 1 do
		local p = PATROL[((startIndex - 1 + k * dir) % n) + 1]
		table.insert(route, p)
		length += flat(prev, p)
		prev = p
	end
	shift.route = route
	shift.routeIndex = 1
	shift.checks = 0
	-- about walking pace plus some slack; suspicious spots add time when they appear
	shift.endsAt = now() + math.floor(length / 13 + 40)
	securityShowCheckpoint(shift)
end

local function securitySuspicious(shift: any, near: Vector3)
	local best, bestDist = SUSPICIOUS[1], math.huge
	for _, p in SUSPICIOUS do
		local d = flat(p, near)
		if d < bestDist then
			best, bestDist = p, d
		end
	end
	shift.phase = "suspicious"
	shift.suspiciousPos = best
	shift.endsAt += math.floor(20 + bestDist / 13)
	clearTracked(shift, shift.marker)
	shift.marker = ownerMarker(shift, best, "❓ Suspicious activity", Color3.fromRGB(255, 80, 80))
	local y = groundY(best)
	local thing = part({
		name = "Suspicious",
		size = Vector3.new(2.5, 3, 2.5),
		cframe = CFrame.new(best.X, y + 1.5, best.Z),
		color = Color3.fromRGB(25, 25, 30),
		material = Enum.Material.Fabric,
		collide = false,
	})
	thing:SetAttribute("JobOwner", shift.player.UserId)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 60, 60)
	light.Range = 14
	light.Brightness = 2
	light.Parent = thing
	track(shift, thing)
	shift.suspicious = thing
	local pr = prompt(thing, "Investigate", "Suspicious activity", { hold = 2.5, distance = 10, JobOwner = shift.player.UserId })
	local myShift = shift
	pr.Triggered:Connect(function(player)
		local s = shifts[player]
		if s ~= myShift or s.phase ~= "suspicious" or flatDistance(player, best) > 12 or tooFast(s, best) then
			return
		end
		local bonus = math.floor(JobsConfig.stepPay("Security", s.level) * 0.4)
		PlayerData.addCash(player, bonus, "Security shift")
		PlayerData.addXP(player, 6)
		addJobXP(player, "Security", 6)
		s.earned += bonus
		s.checks += 1
		Net.notify(player, "AREA CHECKED", SUSPICIOUS_OUTCOMES[math.random(#SUSPICIOUS_OUTCOMES)] .. string.format(" +$%d", bonus))
		clearTracked(s, s.suspicious)
		s.suspicious = nil
		beginStep(s, best)
		securityShowCheckpoint(s)
	end)
	Net.notify(shift.player, "SUSPICIOUS ACTIVITY", "Something's going on nearby. Go check it out.")
	setObjective(shift, "Check out the suspicious activity (hold to investigate)", best, "Suspicious activity")
end

local function securityTick(shift: any)
	if shift.phase ~= "patrol" then
		return
	end
	local pos = shift.route[shift.routeIndex]
	if flatDistance(shift.player, pos) > 10 then
		return
	end
	if isSeated(shift.player) then
		if not shift.footWarned then
			shift.footWarned = true
			Net.notify(shift.player, "ON FOOT ONLY", "Security patrols are done on foot. Get out of the vehicle.")
		end
		return
	end
	if tooFast(shift, pos) then
		return
	end
	completeStep(shift, JobsConfig.stepPay("Security", shift.level))
	if finishIfDone(shift) then
		return
	end
	beginStep(shift, pos)
	shift.routeIndex += 1
	if shift.routeIndex <= #shift.route and math.random() < 0.35 then
		securitySuspicious(shift, pos)
	else
		securityShowCheckpoint(shift)
	end
end

---------------------------------------------------------------------------
-- Start / end
---------------------------------------------------------------------------
local TIME_LIMITS = {
	Delivery = function(goal)
		return 90 + 55 * goal
	end,
	FoodDelivery = function(goal)
		return 120 + 75 * goal
	end,
	Taxi = function(goal)
		return 120 + 110 * goal
	end,
	Warehouse = function(goal)
		return 45 + 15 * goal
	end,
	Construction = function(goal)
		return 60 + 28 * goal
	end,
	Security = function(goal)
		return 60 + 40 * goal -- replaced by the real route length on start
	end,
}

local STARTERS = {
	Delivery = deliveryStart,
	FoodDelivery = foodStart,
	Taxi = taxiStart,
	Warehouse = warehouseStart,
	Construction = constructionStart,
	Security = securityStart,
}

local function startShift(player: Player, jobId: string)
	local def = JOBS[jobId]
	if not def then
		return
	end
	if shifts[player] then
		Net.notify(player, "ALREADY WORKING", "Finish or quit your current shift first.")
		return
	end
	if not PlayerData.isLoaded(player) or not Net.alive(player) then
		return
	end
	if (player:GetAttribute("Interior") or "") ~= "" then
		Net.notify(player, "STEP OUTSIDE", "Head outside to start a shift.")
		return
	end
	if jobId == "Taxi" and not ownsCar(player) then
		Net.notify(player, "TAXI NEEDS A CAR", "Buy a car at Budget Wheels, then start driving to take fares.")
		return
	end
	if not Net.allow(player, "JobStartShift", 4) then
		Net.notify(player, "ONE MOMENT", "Try starting a shift again in a few seconds.")
		return
	end
	local rec = jobRecord(player, jobId)
	local level = if rec then rec.level else 1
	local goal = JobsConfig.steps(jobId, level)
	local t = now()
	local shift = {
		player = player,
		job = jobId,
		level = level,
		goal = goal,
		done = 0,
		earned = 0,
		startedAt = t,
		endsAt = t + TIME_LIMITS[jobId](goal),
		phase = "",
		objective = "",
		cleanup = {},
		combo = nil,
	}
	beginStep(shift, nil)
	shifts[player] = shift
	player:SetAttribute("Job", jobId)
	Net.notify(player, "SHIFT STARTED", string.format("%s: %d %s. Level %d pay x%.2f.", def.name, goal, def.stepWord, level, JobsConfig.payMult(jobId, level)))
	STARTERS[jobId](shift)
end

endShift = function(player: Player, reason: string)
	local shift = shifts[player]
	if not shift then
		return
	end
	shifts[player] = nil
	dropCarry(shift)
	for _, inst in shift.cleanup do
		inst:Destroy()
	end
	if shift.car and shift.car.Parent then
		shift.car:SetAttribute("TaxiPassenger", nil)
	end
	if shift.job == "Construction" and shift.piece then
		local piece = site.pieces[shift.piece]
		if piece and piece.reservedBy == player then
			piece.reservedBy = nil
		end
	end
	local def = JOBS[shift.job]
	local completed = reason == "complete"
	local bonus = 0
	if completed then
		bonus = JobsConfig.completionBonus(shift.job, shift.level)
		PlayerData.addCash(player, bonus, def.name .. " shift")
		shift.earned += bonus
		PlayerData.addXP(player, JobsConfig.PLAYER_XP_SHIFT_BONUS)
		PlayerData.addReputation(player, JobsConfig.REP_PER_SHIFT + math.floor(shift.level / 8))
		if addJobXP(player, shift.job, JobsConfig.JOB_XP_SHIFT_BONUS) then
			shift.levelledUp = true
		end
	end
	local rec = jobRecord(player, shift.job)
	if rec then
		if completed then
			rec.shifts += 1
		end
		rec.earned += shift.earned
		PlayerData.markChanged(player)
	end
	if player.Parent then
		player:SetAttribute("Job", "")
		local reasons = {
			complete = "Shift complete!",
			quit = "You quit the shift.",
			died = "You were knocked out. Shift over.",
			timeout = "Time's up. Shift over.",
		}
		JobState:FireClient(player, "end", {
			job = shift.job,
			completed = completed,
			reason = reasons[reason] or "Shift over.",
			done = shift.done,
			goal = shift.goal,
			word = def.stepWord,
			earned = shift.earned,
			bonus = bonus,
			level = if rec then rec.level else shift.level,
			levelledUp = shift.levelledUp == true,
		})
	end
end

---------------------------------------------------------------------------
-- World building
---------------------------------------------------------------------------
local function buildJobCenter()
	local JC = JobsConfig.JOB_CENTER
	local m = Instance.new("Model")
	m.Name = "JobCenter"
	m.Parent = root
	local navy = Color3.fromRGB(30, 45, 80)
	part({ name = "Pad", size = Vector3.new(26, 0.4, 16), cframe = CFrame.new(JC + Vector3.new(0, 0.2, -2)), color = Color3.fromRGB(190, 190, 185), material = Enum.Material.Concrete, parent = m })
	part({ name = "BackWall", size = Vector3.new(24, 12, 1), cframe = CFrame.new(JC + Vector3.new(0, 6, -9.5)), color = navy, material = Enum.Material.Concrete, parent = m })
	for _, x in { -12, 12 } do
		part({ name = "Pillar", size = Vector3.new(1, 12, 1), cframe = CFrame.new(JC + Vector3.new(x, 6, 5)), color = navy, material = Enum.Material.Metal, parent = m })
		part({ name = "SideWall", size = Vector3.new(1, 12, 6), cframe = CFrame.new(JC + Vector3.new(x, 6, -6.5)), color = navy, material = Enum.Material.Concrete, parent = m })
	end
	part({ name = "Roof", size = Vector3.new(27, 0.8, 17), cframe = CFrame.new(JC + Vector3.new(0, 12.4, -2)), color = Color3.fromRGB(40, 40, 46), material = Enum.Material.Metal, parent = m })
	local header = part({ name = "Header", size = Vector3.new(22, 2.6, 0.5), cframe = CFrame.new(JC + Vector3.new(0, 14.1, 5.5)) * CFrame.Angles(0, math.pi, 0), color = Color3.fromRGB(20, 20, 24), parent = m })
	sign(header, Enum.NormalId.Front, "JOB CENTER", Color3.fromRGB(90, 200, 255))

	-- the job board lists every job with its starting pay range
	local board = part({ name = "JobBoard", size = Vector3.new(20, 9, 0.4), cframe = CFrame.new(JC + Vector3.new(0, 6.5, -8.8)) * CFrame.Angles(0, math.pi, 0), color = Color3.fromRGB(15, 15, 20), parent = m })
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = board
	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 1)
	list.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 18)
	pad.PaddingRight = UDim.new(0, 18)
	pad.Parent = list
	local function row(text: string, color: Color3, height: number, order: number, font: Enum.Font?)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, height)
		l.Font = font or Enum.Font.GothamBold
		l.TextScaled = true
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextColor3 = color
		l.Text = text
		l.LayoutOrder = order
		l.Parent = list
	end
	row("NOW HIRING", Color3.fromRGB(255, 200, 60), 34, 0, Enum.Font.GothamBlack)
	for i, id in JobsConfig.ORDER do
		local def = JOBS[id]
		local lo, hi = JobsConfig.payRange(id, 1)
		row(string.format("%s  %s   $%d–$%d", def.icon, string.upper(def.name), lo, hi), Color3.new(1, 1, 1), 26, i)
	end
	row("Starting pay per shift. Level up each job to earn more.", Color3.fromRGB(170, 170, 185), 16, 20, Enum.Font.Gotham)
	row("Use the terminal or the Jobs app on your phone to start.", Color3.fromRGB(170, 170, 185), 16, 21, Enum.Font.Gotham)

	-- terminal: opens the Jobs app on the client
	local terminal = part({ name = "Terminal", size = Vector3.new(2.4, 4, 1.4), cframe = CFrame.new(JC + Vector3.new(6, 2.4, 1)), color = Color3.fromRGB(40, 40, 48), material = Enum.Material.Metal, parent = m })
	local screen = part({ name = "Screen", size = Vector3.new(2, 1.4, 0.1), cframe = CFrame.new(JC + Vector3.new(6, 3.6, 1.72)) * CFrame.Angles(0, math.pi, 0), color = Color3.fromRGB(90, 200, 255), material = Enum.Material.Neon, collide = false, parent = m })
	sign(screen, Enum.NormalId.Front, "JOBS", Color3.fromRGB(10, 20, 40))
	prompt(terminal, "Browse jobs", "Job Center", { JobBoard = true, distance = 10 }).Triggered:Connect(function(player)
		if Net.allow(player, "JobBoard", 0.5) and Net.distance(player, terminal.Position) <= 14 then
			JobState:FireClient(player, "open")
		end
	end)

	-- security sign-in desk
	local desk = part({ name = "SecurityDesk", size = Vector3.new(4, 3.4, 2), cframe = CFrame.new(JC + Vector3.new(-6, 2.1, 1)), color = Color3.fromRGB(50, 60, 100), material = Enum.Material.Wood, parent = m })
	billboard(desk, "🛡️ SECURITY", Color3.fromRGB(150, 180, 255), 3)
	table.insert(startPrompts.Security, prompt(desk, "Start security shift", "Security", { JobStart = "Security" }))

	-- taxi rank by the curb
	local post = part({ name = "TaxiPost", size = Vector3.new(0.5, 9, 0.5), cframe = CFrame.new(-28, 4.5, -29), color = Color3.fromRGB(40, 40, 45), material = Enum.Material.Metal, parent = m })
	local plate = part({ name = "TaxiSign", size = Vector3.new(4, 2.2, 0.3), cframe = CFrame.new(-28, 9, -28.8) * CFrame.Angles(0, math.pi, 0), color = Color3.fromRGB(245, 200, 40), parent = m })
	sign(plate, Enum.NormalId.Front, "TAXI", Color3.fromRGB(20, 20, 20))
	table.insert(startPrompts.Taxi, prompt(post, "Start taxi shift", "Taxi rank", { JobStart = "Taxi", distance = 12 }))

	Places.mapPoint(root.Parent, "Job Center", "Jobs", JC + Vector3.new(0, 3, 10))
end

local function house(center: Vector3, facing: number, color: Color3, number: string, street: string)
	local m = Instance.new("Model")
	m.Name = number .. " " .. street
	m.Parent = root
	local size = Vector3.new(18, 12, 14)
	part({ name = "Body", size = size, cframe = CFrame.new(center + Vector3.new(0, 6, 0)), color = color, material = Enum.Material.WoodPlanks, parent = m })
	part({ name = "Roof", size = Vector3.new(20, 1.2, 16), cframe = CFrame.new(center + Vector3.new(0, 12.6, 0)), color = Color3.fromRGB(80, 50, 45), material = Enum.Material.Slate, parent = m })
	part({ name = "Chimney", size = Vector3.new(2, 4, 2), cframe = CFrame.new(center + Vector3.new(5, 14.5, 2)), color = Color3.fromRGB(140, 70, 55), material = Enum.Material.Brick, parent = m })
	local frontZ = center.Z + facing * (size.Z / 2 + 0.1)
	part({ name = "Door", size = Vector3.new(4, 7.5, 0.3), cframe = CFrame.new(center.X, 3.75, frontZ), color = Color3.fromRGB(60, 40, 30), material = Enum.Material.Wood, parent = m })
	for _, x in { -5.5, 5.5 } do
		part({ name = "Window", size = Vector3.new(4, 4, 0.3), cframe = CFrame.new(center.X + x, 6, frontZ), color = Color3.fromRGB(150, 200, 230), material = Enum.Material.Glass, transparency = 0.3, parent = m })
	end
	part({ name = "Porch", size = Vector3.new(7, 0.4, 3), cframe = CFrame.new(center.X, 0.2, frontZ + facing * 1.5), color = Color3.fromRGB(150, 150, 145), material = Enum.Material.Concrete, parent = m })
	-- mailbox with the house number
	local mx = center.X + 6
	local mz = frontZ + facing * 5
	part({ name = "MailPost", size = Vector3.new(0.3, 3.5, 0.3), cframe = CFrame.new(mx, 1.75, mz), color = Color3.fromRGB(60, 60, 60), parent = m })
	local box = part({ name = "Mailbox", size = Vector3.new(1, 1, 1.6), cframe = CFrame.new(mx, 3.9, mz), color = Color3.fromRGB(40, 80, 160), material = Enum.Material.Metal, parent = m })
	billboard(box, number .. " " .. street, Color3.new(1, 1, 1), 1.5).TextSize = 14
	table.insert(ADDRESSES, { name = number .. " " .. street, pos = Vector3.new(center.X, 0, frontZ + facing * 5) })
end

local function buildHouses()
	local colors = { Color3.fromRGB(230, 215, 180), Color3.fromRGB(170, 200, 220), Color3.fromRGB(200, 120, 100), Color3.fromRGB(150, 190, 140) }
	for i, x in { -276, -248, -220, -192 } do
		house(Vector3.new(x, 0, 170), -1, colors[i], tostring(i * 2), "Maple Row")
	end
	for i, x in { 175, 210, 245 } do
		house(Vector3.new(x, 0, -197), 1, colors[i + 1], tostring(9 + i * 2), "Oak Street")
	end
end

local function buildDepot()
	local D = Vector3.new(-140, 0, 170)
	local m = Instance.new("Model")
	m.Name = "DeliveryDepot"
	m.Parent = root
	part({ name = "Slab", size = Vector3.new(34, 0.4, 30), cframe = CFrame.new(D + Vector3.new(0, 0.2, -2)), color = Color3.fromRGB(120, 120, 125), material = Enum.Material.Concrete, parent = m })
	part({ name = "DepotBuilding", size = Vector3.new(30, 14, 14), cframe = CFrame.new(D + Vector3.new(0, 7, 6)), color = Color3.fromRGB(150, 110, 70), material = Enum.Material.CorrugatedSteel, parent = m })
	part({ name = "RollerDoor", size = Vector3.new(12, 10, 0.3), cframe = CFrame.new(D + Vector3.new(0, 5, -1.1)), color = Color3.fromRGB(200, 160, 60), material = Enum.Material.CorrugatedSteel, parent = m })
	local s = part({ name = "Sign", size = Vector3.new(24, 2.6, 0.4), cframe = CFrame.new(D + Vector3.new(0, 12, -1.3)), color = Color3.fromRGB(25, 25, 30), parent = m })
	sign(s, Enum.NormalId.Front, "CITY PARCEL DEPOT", Color3.fromRGB(255, 190, 80))
	depotCounter = part({ name = "Counter", size = Vector3.new(12, 3.4, 3), cframe = CFrame.new(D + Vector3.new(0, 1.9, -8)), color = Color3.fromRGB(90, 70, 50), material = Enum.Material.Wood, parent = m })
	for i = -2, 2 do
		part({ name = "Parcel", size = Vector3.new(1.8, 1.4, 1.6), cframe = CFrame.new(D + Vector3.new(i * 2.2, 4.3, -8)) * CFrame.Angles(0, math.rad(i * 7), 0), color = Color3.fromRGB(190, 145, 95), material = Enum.Material.Cardboard, parent = m })
	end
	-- delivery van (decor)
	local vanC = D + Vector3.new(12, 0, -6)
	part({ name = "VanBody", size = Vector3.new(6, 6, 12), cframe = CFrame.new(vanC + Vector3.new(0, 4, 0)), color = Color3.fromRGB(240, 240, 240), material = Enum.Material.Metal, parent = m })
	for _, wx in { -3, 3 } do
		for _, wz in { -4, 4 } do
			part({ name = "Wheel", size = Vector3.new(0.8, 2.4, 2.4), cframe = CFrame.new(vanC + Vector3.new(wx, 1.2, wz)), color = Color3.fromRGB(25, 25, 25), shape = Enum.PartType.Cylinder, parent = m })
		end
	end
	billboard(depotCounter, "📦 PARCEL PICKUP", Color3.fromRGB(255, 190, 80), 3.5)
	table.insert(startPrompts.Delivery, prompt(depotCounter, "Start delivery shift", "Delivery Depot", { JobStart = "Delivery" }))
	prompt(depotCounter, "Load parcels", "Delivery Depot", { JobOnly = "Delivery", hold = 0.6 }).Triggered:Connect(deliveryLoad)
	Places.mapPoint(root.Parent, "Delivery Depot", "Jobs", JobsConfig.START.Delivery)
end

local function buildFoodCounter()
	local M = Vector3.new(86, 0, 40)
	local m = Instance.new("Model")
	m.Name = "TakeoutCounter"
	m.Parent = root
	foodCounter = part({ name = "Counter", size = Vector3.new(8, 3.4, 2.5), cframe = CFrame.new(M + Vector3.new(0, 1.7, 0)), color = Color3.fromRGB(190, 70, 50), material = Enum.Material.Wood, parent = m })
	part({ name = "Awning", size = Vector3.new(10, 0.4, 5), cframe = CFrame.new(M + Vector3.new(0, 8, 0.2)), color = Color3.fromRGB(240, 220, 200), material = Enum.Material.Fabric, parent = m })
	for _, x in { -4.6, 4.6 } do
		part({ name = "Post", size = Vector3.new(0.4, 8, 0.4), cframe = CFrame.new(M + Vector3.new(x, 4, -2)), color = Color3.fromRGB(50, 50, 55), material = Enum.Material.Metal, parent = m })
	end
	local s = part({ name = "Sign", size = Vector3.new(9, 1.6, 0.3), cframe = CFrame.new(M + Vector3.new(0, 9.1, -2.2)), color = Color3.fromRGB(190, 70, 50), parent = m })
	sign(s, Enum.NormalId.Front, "TAKEOUT · DELIVERY", Color3.fromRGB(255, 230, 150))
	for i = -1, 1 do
		part({ name = "Bag", size = Vector3.new(1, 1.3, 0.8), cframe = CFrame.new(M + Vector3.new(i * 2, 4.05, 0)), color = Color3.fromRGB(200, 50, 40), material = Enum.Material.Fabric, parent = m })
	end
	table.insert(startPrompts.FoodDelivery, prompt(foodCounter, "Start food delivery shift", "Mama's Kitchen", { JobStart = "FoodDelivery" }))
	prompt(foodCounter, "Pick up order", "Mama's Kitchen", { JobOnly = "FoodDelivery", hold = 0.4 }).Triggered:Connect(foodPickup)
end

local function buildWarehouse()
	local W = Vector3.new(85, 0, 175)
	local m = Instance.new("Model")
	m.Name = "Warehouse"
	m.Parent = root
	local wall = Color3.fromRGB(150, 155, 165)
	local function w(size: Vector3, offset: Vector3)
		part({ name = "Wall", size = size, cframe = CFrame.new(W + offset), color = wall, material = Enum.Material.CorrugatedSteel, parent = m })
	end
	part({ name = "Floor", size = Vector3.new(56, 0.4, 40), cframe = CFrame.new(W + Vector3.new(0, 0.2, 0)), color = Color3.fromRGB(110, 110, 115), material = Enum.Material.Concrete, parent = m })
	w(Vector3.new(1, 18, 40), Vector3.new(-28, 9, 0))
	w(Vector3.new(56, 18, 1), Vector3.new(0, 9, 20))
	for _, x in { -18, 18 } do
		w(Vector3.new(20, 18, 1), Vector3.new(x, 9, -20))
	end
	w(Vector3.new(16, 6, 1), Vector3.new(0, 15, -20))
	for _, z in { -13.5, 13.5 } do
		w(Vector3.new(1, 18, 13), Vector3.new(28, 9, z))
	end
	w(Vector3.new(1, 6, 14), Vector3.new(28, 15, 0))
	part({ name = "Roof", size = Vector3.new(58, 1, 42), cframe = CFrame.new(W + Vector3.new(0, 18.5, 0)), color = Color3.fromRGB(70, 70, 76), material = Enum.Material.Metal, parent = m })
	for _, x in { -14, 14 } do
		for _, z in { -9, 9 } do
			local lamp = part({ name = "Lamp", size = Vector3.new(4, 0.3, 4), cframe = CFrame.new(W + Vector3.new(x, 17.8, z)), color = Color3.fromRGB(255, 250, 235), material = Enum.Material.Neon, collide = false, parent = m })
			local light = Instance.new("PointLight")
			light.Range = 28
			light.Brightness = 1.4
			light.Parent = lamp
		end
	end
	local s = part({ name = "Sign", size = Vector3.new(16, 3, 0.4), cframe = CFrame.new(W + Vector3.new(0, 15, -20.8)), color = Color3.fromRGB(25, 25, 30), parent = m })
	sign(s, Enum.NormalId.Front, "WAREHOUSE", Color3.fromRGB(110, 170, 255))
	-- floor stripes towards the bay
	part({ name = "Stripe", size = Vector3.new(30, 0.05, 0.6), cframe = CFrame.new(W + Vector3.new(8, 0.43, -7)), color = Color3.fromRGB(240, 200, 40), collide = false, parent = m })
	part({ name = "Stripe", size = Vector3.new(30, 0.05, 0.6), cframe = CFrame.new(W + Vector3.new(8, 0.43, 7)), color = Color3.fromRGB(240, 200, 40), collide = false, parent = m })

	-- shelving racks: { centre offset, long axis along z? }
	local rackDefs = {
		{ Vector3.new(-25, 0, -12), true },
		{ Vector3.new(-25, 0, 0), true },
		{ Vector3.new(-25, 0, 12), true },
		{ Vector3.new(-12, 0, 17), false },
		{ Vector3.new(2, 0, 17), false },
	}
	local boxColors = { Color3.fromRGB(175, 130, 80), Color3.fromRGB(160, 120, 75), Color3.fromRGB(190, 150, 100) }
	for i, def in rackDefs do
		local c = W + def[1]
		local alongZ = def[2]
		local long = 9
		local rackSize = if alongZ then Vector3.new(3, 0.3, long) else Vector3.new(long, 0.3, 3)
		for _, y in { 1, 4, 7 } do
			part({ name = "Shelf", size = rackSize, cframe = CFrame.new(c + Vector3.new(0, y, 0)), color = Color3.fromRGB(230, 120, 40), material = Enum.Material.Metal, parent = m })
		end
		for _, e in { -1, 1 } do
			local o = if alongZ then Vector3.new(0, 4.5, e * long / 2) else Vector3.new(e * long / 2, 4.5, 0)
			part({ name = "Upright", size = Vector3.new(0.4, 9, 0.4), cframe = CFrame.new(c + o), color = Color3.fromRGB(40, 70, 140), material = Enum.Material.Metal, parent = m })
		end
		-- decorative boxes plus the one the job highlights
		local target: BasePart? = nil
		for k, y in { 1, 4, 7 } do
			for j = -1, 1 do
				local o = if alongZ then Vector3.new(0, y + 1.05, j * 2.8) else Vector3.new(j * 2.8, y + 1.05, 0)
				local b = part({ name = "StockBox", size = Vector3.new(2.2, 1.8, 2.2), cframe = CFrame.new(c + o), color = boxColors[(i + j + k) % 3 + 1], material = Enum.Material.Cardboard, parent = m })
				if k == 2 and j == 0 then
					target = b
				end
			end
		end
		local front = if alongZ then Vector3.new(4, 0, 0) else Vector3.new(0, 0, -4)
		local spot = part({ name = "PickSpot", size = Vector3.new(2, 4, 2), cframe = CFrame.new(c + front + Vector3.new(0, 2.5, 0)), transparency = 1, collide = false, parent = m })
		spot.CanQuery = false
		spot.CanTouch = false
		local rackIndex = i
		prompt(spot, "Grab box", "Shelf " .. i, { JobOnly = "Warehouse", hold = 0.4, distance = 9 }).Triggered:Connect(function(player)
			warehouseGrab(player, rackIndex)
		end)
		billboard(spot, "SHELF " .. i, Color3.fromRGB(200, 200, 210), 4).TextSize = 14
		warehouse.racks[i] = { spot = spot, box = target :: BasePart }
	end

	-- truck bay + truck backed in on the east side
	local bay = part({ name = "TruckBay", size = Vector3.new(8, 0.1, 12), cframe = CFrame.new(W + Vector3.new(23, 0.45, 0)), color = Color3.fromRGB(240, 200, 40), material = Enum.Material.Neon, transparency = 0.4, collide = false, parent = m })
	bay.CanQuery = false
	billboard(bay, "🚚 TRUCK BAY", Color3.fromRGB(255, 220, 80), 5)
	prompt(bay, "Load box", "Truck bay", { JobOnly = "Warehouse", hold = 0.3, distance = 10 }).Triggered:Connect(warehouseLoad)
	warehouse.bay = bay
	local red = Color3.fromRGB(190, 40, 40)
	part({ name = "TrailerFloor", size = Vector3.new(24, 1, 12), cframe = CFrame.new(W + Vector3.new(41, 3, 0)), color = Color3.fromRGB(60, 60, 65), material = Enum.Material.Metal, parent = m })
	for _, z in { -5.75, 5.75 } do
		part({ name = "TrailerSide", size = Vector3.new(24, 9, 0.5), cframe = CFrame.new(W + Vector3.new(41, 8, z)), color = Color3.fromRGB(235, 235, 240), material = Enum.Material.Metal, parent = m })
	end
	part({ name = "TrailerFront", size = Vector3.new(0.5, 9, 12), cframe = CFrame.new(W + Vector3.new(53, 8, 0)), color = Color3.fromRGB(235, 235, 240), material = Enum.Material.Metal, parent = m })
	part({ name = "TrailerRoof", size = Vector3.new(24, 0.5, 12), cframe = CFrame.new(W + Vector3.new(41, 12.75, 0)), color = Color3.fromRGB(235, 235, 240), material = Enum.Material.Metal, parent = m })
	part({ name = "Cab", size = Vector3.new(8, 8, 11), cframe = CFrame.new(W + Vector3.new(58, 5, 0)), color = red, material = Enum.Material.Metal, parent = m })
	part({ name = "Windshield", size = Vector3.new(0.2, 3, 9), cframe = CFrame.new(W + Vector3.new(62.1, 6.5, 0)), color = Color3.fromRGB(120, 170, 210), material = Enum.Material.Glass, transparency = 0.3, parent = m })
	for _, x in { 32, 48, 58 } do
		for _, z in { -5.5, 5.5 } do
			part({ name = "Wheel", size = Vector3.new(1, 3, 3), cframe = CFrame.new(W + Vector3.new(x, 1.5, z)) * CFrame.Angles(0, math.pi / 2, 0), color = Color3.fromRGB(25, 25, 25), shape = Enum.PartType.Cylinder, parent = m })
		end
	end
	-- cargo that fills as boxes are loaded (3 columns x 2 rows x 2 high)
	for layer = 0, 1 do
		for row = 0, 1 do
			for col = 0, 2 do
				local b = part({
					name = "Cargo",
					size = Vector3.new(2.2, 1.8, 2.2),
					cframe = CFrame.new(W + Vector3.new(50 - col * 2.4, 4.4 + layer * 1.9, -1.3 + row * 2.6)),
					color = boxColors[(col + row + layer) % 3 + 1],
					material = Enum.Material.Cardboard,
					transparency = 1,
					collide = false,
					parent = m,
				})
				b.CanQuery = false
				table.insert(warehouse.truckBoxes, b)
			end
		end
	end

	-- time clock by the door
	local clock = part({ name = "TimeClock", size = Vector3.new(2, 3, 1), cframe = CFrame.new(W + Vector3.new(-12, 2.5, -22)), color = Color3.fromRGB(50, 60, 80), material = Enum.Material.Metal, parent = m })
	billboard(clock, "🏭 TIME CLOCK", Color3.fromRGB(110, 170, 255), 3)
	table.insert(startPrompts.Warehouse, prompt(clock, "Start warehouse shift", "Warehouse", { JobStart = "Warehouse" }))
	Places.mapPoint(root.Parent, "Warehouse", "Jobs", JobsConfig.START.Warehouse)
end

local function buildConstruction()
	local C = Vector3.new(195, 0, 178)
	local m = Instance.new("Model")
	m.Name = "ConstructionSite"
	m.Parent = root
	part({ name = "Dirt", size = Vector3.new(70, 0.3, 50), cframe = CFrame.new(C + Vector3.new(0, 0.15, 0)), color = Color3.fromRGB(140, 105, 70), material = Enum.Material.Ground, parent = m })
	local fence = Color3.fromRGB(120, 125, 130)
	local function f(size: Vector3, offset: Vector3)
		part({ name = "Fence", size = size, cframe = CFrame.new(C + offset), color = fence, material = Enum.Material.DiamondPlate, transparency = 0.55, parent = m })
	end
	f(Vector3.new(0.3, 8, 50), Vector3.new(-35, 4, 0))
	f(Vector3.new(0.3, 8, 50), Vector3.new(35, 4, 0))
	f(Vector3.new(70, 8, 0.3), Vector3.new(0, 4, 25))
	f(Vector3.new(7, 8, 0.3), Vector3.new(-31.5, 4, -25))
	f(Vector3.new(47, 8, 0.3), Vector3.new(11.5, 4, -25))
	local s = part({ name = "Sign", size = Vector3.new(20, 3, 0.3), cframe = CFrame.new(C + Vector3.new(11.5, 6.5, -25.3)), color = Color3.fromRGB(240, 170, 30), parent = m })
	sign(s, Enum.NormalId.Front, "CITY CONSTRUCTION · HARD HATS", Color3.fromRGB(20, 20, 20))

	-- site board outside the gate: start prompt + build progress
	local boardPost = part({ name = "SiteBoard", size = Vector3.new(6, 4, 0.4), cframe = CFrame.new(C + Vector3.new(-28, 4, -27)), color = Color3.fromRGB(30, 30, 35), parent = m })
	for _, x in { -2.6, 2.6 } do
		part({ name = "Leg", size = Vector3.new(0.3, 2, 0.3), cframe = CFrame.new(C + Vector3.new(-28 + x, 1, -27)), color = Color3.fromRGB(60, 60, 60), parent = m })
	end
	local gui = sign(boardPost, Enum.NormalId.Front, "BUILD PROGRESS", Color3.fromRGB(255, 190, 60))
	site.board = gui:FindFirstChildOfClass("TextLabel")
	table.insert(startPrompts.Construction, prompt(boardPost, "Start construction shift", "Construction Site", { JobStart = "Construction" }))

	-- material piles
	local pileDefs = {
		Bricks = { offset = Vector3.new(-26, 0, -10), color = Color3.fromRGB(165, 70, 50), material = Enum.Material.Brick, size = Vector3.new(2, 1.2, 1.4) },
		Planks = { offset = Vector3.new(-26, 0, 0), color = Color3.fromRGB(190, 150, 95), material = Enum.Material.WoodPlanks, size = Vector3.new(1.2, 0.4, 6) },
		Beams = { offset = Vector3.new(-26, 0, 10), color = Color3.fromRGB(120, 125, 135), material = Enum.Material.DiamondPlate, size = Vector3.new(0.7, 0.7, 6) },
	}
	for name, def in pileDefs do
		local c = C + def.offset
		local pallet = part({ name = name .. "Pallet", size = Vector3.new(5, 0.6, 6.5), cframe = CFrame.new(c + Vector3.new(0, 0.6, 0)), color = Color3.fromRGB(150, 115, 70), material = Enum.Material.Wood, parent = m })
		for layer = 0, 2 do
			for k = -1, 1 do
				local o = if name == "Bricks" then Vector3.new(k * 1.5, 1.5 + layer * 1.25, (layer % 2) * 0.6 - 0.3) else Vector3.new(k * 1.4, 1.1 + layer * def.size.Y * 1.1, 0)
				part({ name = name, size = def.size, cframe = CFrame.new(c + o), color = def.color, material = def.material, parent = m })
			end
		end
		billboard(pallet, string.upper(name), def.color:Lerp(Color3.new(1, 1, 1), 0.4), 5)
		local material = name
		prompt(pallet, "Take " .. name, "Material pile", { JobOnly = "Construction", hold = 0.4, distance = 9 }).Triggered:Connect(function(player)
			constructionTake(player, material)
		end)
		site.piles[name] = pallet
	end

	-- the structure: pieces appear as the crew places them
	local S = C + Vector3.new(10, 0, 4)
	local structure = Instance.new("Model")
	structure.Name = "Structure"
	structure.Parent = m
	local defs = {
		-- foundation
		{ "Bricks", Vector3.new(20, 1, 2), Vector3.new(0, 0.5, -7) },
		{ "Bricks", Vector3.new(20, 1, 2), Vector3.new(0, 0.5, 7) },
		{ "Bricks", Vector3.new(2, 1, 12), Vector3.new(-9, 0.5, 0) },
		{ "Bricks", Vector3.new(2, 1, 12), Vector3.new(9, 0.5, 0) },
		-- corner posts
		{ "Beams", Vector3.new(1, 11, 1), Vector3.new(-9.5, 6.5, -7.5) },
		{ "Beams", Vector3.new(1, 11, 1), Vector3.new(9.5, 6.5, -7.5) },
		{ "Beams", Vector3.new(1, 11, 1), Vector3.new(-9.5, 6.5, 7.5) },
		{ "Beams", Vector3.new(1, 11, 1), Vector3.new(9.5, 6.5, 7.5) },
		-- walls (front stays open)
		{ "Bricks", Vector3.new(18, 8, 1), Vector3.new(0, 5, 7.5) },
		{ "Bricks", Vector3.new(1, 8, 14), Vector3.new(-9.5, 5, 0) },
		{ "Bricks", Vector3.new(1, 8, 14), Vector3.new(9.5, 5, 0) },
		-- top beams
		{ "Beams", Vector3.new(20, 1, 1), Vector3.new(0, 12.5, -7.5) },
		{ "Beams", Vector3.new(20, 1, 1), Vector3.new(0, 12.5, 7.5) },
		-- roof planks
		{ "Planks", Vector3.new(20, 0.5, 5.4), Vector3.new(0, 13.25, -5.3) },
		{ "Planks", Vector3.new(20, 0.5, 5.4), Vector3.new(0, 13.25, 0) },
		{ "Planks", Vector3.new(20, 0.5, 5.4), Vector3.new(0, 13.25, 5.3) },
	}
	for i, d in defs do
		local spec = pileDefs[d[1]]
		local p = part({ name = "Piece" .. i, size = d[2], cframe = CFrame.new(S + d[3]), color = spec.color, material = spec.material, transparency = 1, collide = false, parent = structure })
		p.CanQuery = false
		p.CanTouch = false
		site.pieces[i] = { part = p, material = d[1], built = false, reservedBy = nil }
	end
	updateSiteBoard()
	Places.mapPoint(root.Parent, "Construction Site", "Jobs", JobsConfig.START.Construction)
end

---------------------------------------------------------------------------
-- Ticking: time limits, taxi pickups, patrol checkpoints, food going cold
---------------------------------------------------------------------------
local function stepShifts()
	local t = now()
	for player, shift in shifts do
		if not player.Parent then
			endShift(player, "left")
		elseif not Net.alive(player) then
			endShift(player, "died")
		elseif t > shift.endsAt then
			endShift(player, "timeout")
		elseif shift.job == "Taxi" then
			taxiTick(shift)
		elseif shift.job == "Security" then
			securityTick(shift)
		elseif shift.job == "Construction" then
			if shift.phase == "assign" then
				constructionAssign(shift)
			end
		elseif shift.job == "FoodDelivery" then
			if shift.phase == "deliver" and shift.hotUntil and t > shift.hotUntil and not shift.coldNotified then
				shift.coldNotified = true
				Net.notify(player, "FOOD GOT COLD", "No tip on this one, but deliver it anyway.")
				publish(shift)
			end
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Jobs.start(city: Instance)
	root = Instance.new("Folder")
	root.Name = "Jobs"
	root.Parent = city
	for _, id in JobsConfig.ORDER do
		startPrompts[id] = {}
	end

	buildHouses()
	buildJobCenter()
	buildDepot()
	buildFoodCounter()
	buildWarehouse()
	buildConstruction()

	for id, list in startPrompts do
		for _, pr in list do
			pr.Triggered:Connect(function(player)
				if Net.distance(player, (pr.Parent :: BasePart).Position) <= 16 then
					startShift(player, id)
				end
			end)
		end
	end

	JobAction.OnServerEvent:Connect(function(player: Player, action: any, jobId: any)
		if not Net.allow(player, "JobAction", 0.5) then
			return
		end
		if action == "start" and type(jobId) == "string" and JOBS[jobId] then
			startShift(player, jobId)
		elseif action == "quit" then
			endShift(player, "quit")
		end
	end)

	local function onPlayer(player: Player)
		player:SetAttribute("Job", "")
		local function hook(character: Model)
			local hum = character:WaitForChild("Humanoid", 10)
			if hum and hum:IsA("Humanoid") then
				hum.Died:Connect(function()
					endShift(player, "died")
				end)
			end
		end
		player.CharacterAdded:Connect(hook)
		player.CharacterRemoving:Connect(function()
			endShift(player, "died")
		end)
		if player.Character then
			task.spawn(hook, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		endShift(player, "left")
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			stepShifts()
		end
	end)
end

return Jobs
