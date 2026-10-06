-- CITY GRIND: vehicle catalog, paint/mod options and the shared arcade physics.
-- Lives in ReplicatedStorage.CityGrind.VehiclesConfig. The server builds the
-- models (server/Vehicles); whoever simulates a vehicle (the driver's client
-- while driving, the server while it is empty) runs VehiclesConfig.step on it.
--
-- Physics model ("raycast car"): one invisible collider box (the Chassis) plus a
-- heavy, low ballast part. Each suspension point casts a ray down; a spring and
-- damper push the chassis up. Drive, braking and sideways grip are forces at the
-- centre of mass, steering is a yaw torque toward a target turn rate, and an
-- AlignOrientation keeps the vehicle upright (and leans two-wheelers into turns).

local Config = require(script.Parent:WaitForChild("Config"))

local VehiclesConfig = {}

-- Budget Wheels lot (CityBuilder: lot 90x70 centred here, showroom at z+24).
VehiclesConfig.LOT_CENTER = Vector3.new(190, 0, 85)
VehiclesConfig.LOT_GPS = Vector3.new(190, 0, 70)
VehiclesConfig.LOT_Y = 0.3 -- top of the lot's asphalt
VehiclesConfig.SHOP_RANGE = 75 -- buying is only allowed this close to the lot
VehiclesConfig.MODS_POS = Vector3.new(157, 0.3, 108) -- Paint & Mods bay on the lot
VehiclesConfig.MODS_RANGE = 30

VehiclesConfig.SPAWN_COOLDOWN = 8
VehiclesConfig.MOD_PRICES = { paint = 150, rim = 250, glow = 400 }

-- Where vehicles may be spawned (inside the city ground, outside interiors).
VehiclesConfig.CITY_MIN = Vector3.new(-292, -20, -222)
VehiclesConfig.CITY_MAX = Vector3.new(292, 60, 222)

-- Speed shown on the speedometer = studs/s * this.
VehiclesConfig.MPH_PER_STUD = 1.1

VehiclesConfig.PAINTS = {
	{ name = "Arctic White", color = Color3.fromRGB(235, 236, 240) },
	{ name = "Midnight Black", color = Color3.fromRGB(28, 28, 32) },
	{ name = "Racing Red", color = Color3.fromRGB(200, 30, 35) },
	{ name = "Ocean Blue", color = Color3.fromRGB(30, 90, 200) },
	{ name = "Lime Green", color = Color3.fromRGB(120, 210, 50) },
	{ name = "Sunset Orange", color = Color3.fromRGB(255, 130, 30) },
	{ name = "Royal Purple", color = Color3.fromRGB(110, 50, 170) },
	{ name = "Gunmetal", color = Color3.fromRGB(95, 100, 110) },
}

VehiclesConfig.RIMS = {
	{ name = "Chrome", color = Color3.fromRGB(200, 205, 215), material = Enum.Material.Metal },
	{ name = "Matte Black", color = Color3.fromRGB(25, 25, 28), material = Enum.Material.SmoothPlastic },
	{ name = "Gold", color = Color3.fromRGB(230, 180, 50), material = Enum.Material.Metal },
	{ name = "White", color = Color3.fromRGB(240, 240, 240), material = Enum.Material.SmoothPlastic },
	{ name = "Red", color = Color3.fromRGB(210, 40, 40), material = Enum.Material.SmoothPlastic },
	{ name = "Blue", color = Color3.fromRGB(40, 120, 230), material = Enum.Material.SmoothPlastic },
}

-- Index 1 is "no underglow".
VehiclesConfig.GLOWS = {
	{ name = "None", color = Color3.fromRGB(40, 40, 45) },
	{ name = "Ice Blue", color = Color3.fromRGB(80, 200, 255) },
	{ name = "Hot Pink", color = Color3.fromRGB(255, 60, 200) },
	{ name = "Toxic Green", color = Color3.fromRGB(80, 255, 90) },
	{ name = "Fire Red", color = Color3.fromRGB(255, 50, 40) },
	{ name = "Violet", color = Color3.fromRGB(150, 70, 255) },
	{ name = "Pure White", color = Color3.fromRGB(255, 255, 255) },
}

export type Spec = {
	id: string,
	name: string,
	kind: string, -- "Bike" | "Scooter" | "Motorcycle" | "Car" (Player attribute "Driving")
	class: string,
	style: string, -- body builder used by the server
	blurb: string,
	price: number,
	level: number,
	rep: number,
	topSpeed: number, -- studs/s
	reverseSpeed: number,
	accel: number, -- studs/s^2 from standstill
	brake: number, -- studs/s^2
	handling: number, -- max yaw rate, rad/s
	grip: number, -- max sideways acceleration, studs/s^2
	gripRate: number, -- how fast sideways sliding is cancelled (1/s)
	steerAngle: number, -- radians at low speed
	lean: number, -- two-wheeler lean into turns (radians), 0 for cars
	seats: number, -- total seats including the driver
	mass: number, -- ballast mass
	defaultPaint: number,
	-- geometry (studs). Ground-space: y = 0 is the road, -z is the front.
	width: number,
	length: number,
	height: number, -- top of the collider box
	clearance: number, -- bottom of the collider box
	wheelRadius: number,
	wheelWidth: number,
	wheelbase: number,
	track: number, -- distance between left/right suspension points
	travel: number, -- suspension travel
	sag: number, -- compression at rest
	twoWheel: boolean,
}

local function spec(s: { [string]: any }): Spec
	s.reverseSpeed = s.reverseSpeed or math.max(14, s.topSpeed * 0.3)
	s.level = s.level or 1
	s.rep = s.rep or 0
	s.lean = s.lean or 0
	s.clearance = s.clearance or 1
	s.twoWheel = s.twoWheel or false
	return s :: any
end

VehiclesConfig.CATALOG = {
	spec({
		id = "Bike", name = "Pedal Bike", kind = "Bike", class = "Bicycle", style = "bicycle",
		blurb = "Cheap, quiet and fits anywhere. Beats walking.",
		price = 350, topSpeed = 30, accel = 16, brake = 40, handling = 2.4, grip = 75, gripRate = 9,
		steerAngle = 0.7, lean = 0.28, seats = 1, mass = 55, defaultPaint = 5,
		width = 1.2, length = 5.4, height = 3.0, clearance = 1.0, wheelRadius = 1.3, wheelWidth = 0.22,
		wheelbase = 4.0, track = 0.9, travel = 0.6, sag = 0.25, twoWheel = true,
	}),
	spec({
		id = "Scooter", name = "City Scooter", kind = "Scooter", class = "Scooter", style = "scooter",
		blurb = "Zippy little scooter with room for a friend.",
		price = 900, topSpeed = 45, accel = 22, brake = 45, handling = 2.3, grip = 85, gripRate = 9,
		steerAngle = 0.65, lean = 0.26, seats = 2, mass = 70, defaultPaint = 4,
		width = 1.6, length = 5.6, height = 3.0, clearance = 0.9, wheelRadius = 0.9, wheelWidth = 0.5,
		wheelbase = 4.0, track = 1.0, travel = 0.7, sag = 0.3, twoWheel = true,
	}),
	spec({
		id = "Economy", name = "Volt Hatch", kind = "Car", class = "Economy", style = "hatch",
		blurb = "Reliable four-seat hatchback. Your first real car.",
		price = 4500, topSpeed = 70, accel = 26, brake = 55, handling = 1.5, grip = 95, gripRate = 7,
		steerAngle = 0.6, seats = 4, mass = 220, defaultPaint = 1,
		width = 6.4, length = 13, height = 6.0, clearance = 1.0, wheelRadius = 1.25, wheelWidth = 1.0,
		wheelbase = 8.4, track = 5.6, travel = 1.0, sag = 0.45,
	}),
	spec({
		id = "Motorcycle", name = "Viper 600", kind = "Motorcycle", class = "Motorcycle", style = "motorcycle",
		blurb = "Sport bike. Quick off the line and leans into corners.",
		price = 9000, topSpeed = 85, accel = 42, brake = 62, handling = 2.0, grip = 105, gripRate = 8,
		steerAngle = 0.55, lean = 0.34, seats = 2, mass = 110, defaultPaint = 3,
		width = 1.8, length = 7.2, height = 3.2, clearance = 1.0, wheelRadius = 1.25, wheelWidth = 0.6,
		wheelbase = 5.4, track = 1.0, travel = 0.8, sag = 0.33, twoWheel = true,
	}),
	spec({
		id = "SUV", name = "Summit SUV", kind = "Car", class = "SUV", style = "suv",
		blurb = "Big, tall and roomy. Seats five.",
		price = 18000, topSpeed = 75, accel = 30, brake = 55, handling = 1.3, grip = 90, gripRate = 6.5,
		steerAngle = 0.58, seats = 5, mass = 300, defaultPaint = 8,
		width = 7.0, length = 14.5, height = 7.4, clearance = 1.3, wheelRadius = 1.5, wheelWidth = 1.1,
		wheelbase = 9.4, track = 6.0, travel = 1.2, sag = 0.5,
	}),
	spec({
		id = "Sports", name = "Stinger GT", kind = "Car", class = "Sports", style = "coupe",
		blurb = "Low, loud, fast. Turns heads on every block.",
		price = 60000, topSpeed = 110, accel = 50, brake = 75, handling = 1.8, grip = 125, gripRate = 8,
		steerAngle = 0.55, seats = 2, mass = 230, defaultPaint = 3,
		width = 6.6, length = 13.6, height = 5.4, clearance = 1.0, wheelRadius = 1.25, wheelWidth = 1.1,
		wheelbase = 8.6, track = 5.8, travel = 0.8, sag = 0.35,
	}),
	spec({
		id = "Supercar", name = "Apex X1", kind = "Car", class = "Supercar", style = "supercar",
		blurb = "Open-top hypercar. Only City Famous drivers get the keys.",
		price = 350000, level = 30, rep = 2500, topSpeed = 140, accel = 65, brake = 90, handling = 2.0,
		grip = 140, gripRate = 9, steerAngle = 0.52, seats = 2, mass = 240, defaultPaint = 6,
		width = 7.0, length = 14, height = 4.6, clearance = 0.95, wheelRadius = 1.3, wheelWidth = 1.3,
		wheelbase = 9.0, track = 6.0, travel = 0.7, sag = 0.3,
	}),
} :: { Spec }

VehiclesConfig.byId = {} :: { [string]: Spec }
for i, s in VehiclesConfig.CATALOG do
	VehiclesConfig.byId[s.id] = s
	;(s :: any).order = i
end

-- Bars on the purchase panel are a fraction of these.
VehiclesConfig.STAT_MAX = { topSpeed = 140, accel = 65, handling = 2.4, brake = 90, grip = 140 }

function VehiclesConfig.groundOffset(s: Spec): number
	return (s.height + s.clearance) / 2 -- chassis centre height above the road
end

function VehiclesConfig.requirementText(s: Spec): string?
	if s.level <= 1 and s.rep <= 0 then
		return nil
	end
	local parts = {}
	if s.level > 1 then
		table.insert(parts, "Level " .. s.level)
	end
	if s.rep > 0 then
		local rankName = s.rep .. " rep"
		for _, rank in Config.REPUTATION_RANKS do
			if rank.min == s.rep then
				rankName = rank.name .. " (" .. s.rep .. " rep)"
			end
		end
		table.insert(parts, rankName)
	end
	return table.concat(parts, " + ")
end

---------------------------------------------------------------------------
-- Physics
---------------------------------------------------------------------------
local DAMPING_RATIO = 0.62
local YAW_GAIN = 9 -- 1/s, how hard yaw chases the target turn rate
local STEER_RATE = 4.5 -- steering input smoothing (full lock in ~0.22 s)
local COAST_DECEL = 3 -- studs/s^2 rolling resistance with a driver aboard
local PARKED_DECEL = 30 -- studs/s^2 when nobody is driving (handbrake)
-- Only part of the springs' pitch/roll torque is applied; the AlignOrientation
-- (solved inside the physics step, so it is stable at any frame rate) does the
-- rest. Full spring torque on a light, narrow body can oscillate at low FPS.
local SUSPENSION_TORQUE_SCALE = 0.35
local EDGE_OFFSET = 0.7 -- extra rays at +-0.7 * radius ahead/behind each wheel
local EDGE_CORRECTION = 1 - math.sqrt(1 - EDGE_OFFSET * EDGE_OFFSET)

export type Sim = {
	model: Model,
	chassis: BasePart,
	spec: Spec,
	force: VectorForce,
	torque: Torque,
	align: AlignOrientation,
	susp: { Attachment },
	params: RaycastParams,
	yawFactor: number,
	steer: number,
	grounded: number,
	flipTime: number,
}

-- Distance from `origin` straight down (along -up) to where the wheel would touch,
-- or nil when nothing is within `len`. Extra rays just ahead and behind the wheel
-- let it "see" a curb edge early so it rolls up instead of slamming into it.
function VehiclesConfig.groundDistance(origin: Vector3, up: Vector3, look: Vector3, radius: number, len: number, params: RaycastParams, edgeRays: boolean): number?
	local down = -up * len
	local best: number? = nil
	local hit = workspace:Raycast(origin, down, params)
	if hit then
		best = hit.Distance
	end
	if edgeRays then
		local correction = radius * EDGE_CORRECTION
		for _, dir in { 1, -1 } do
			local edgeHit = workspace:Raycast(origin + look * (dir * EDGE_OFFSET * radius), down, params)
			if edgeHit then
				local d = edgeHit.Distance + correction
				if d <= len and (best == nil or d < best) then
					best = d
				end
			end
		end
	end
	return best
end

function VehiclesConfig.newSim(model: Model): Sim?
	local chassis = model.PrimaryPart
	local s = VehiclesConfig.byId[model:GetAttribute("VehicleId") or ""]
	if not chassis or not s then
		return nil
	end
	local force = chassis:FindFirstChild("DriveForce")
	local torque = chassis:FindFirstChild("DriveTorque")
	local align = chassis:FindFirstChild("Upright")
	if not (force and torque and align) then
		return nil
	end
	local susp = {}
	for _, child in chassis:GetChildren() do
		if child:IsA("Attachment") and child.Name == "Susp" then
			table.insert(susp, child)
		end
	end
	if #susp == 0 then
		return nil
	end
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local ballast = model:FindFirstChild("Ballast")
	local bsize = if ballast and ballast:IsA("BasePart") then ballast.Size else chassis.Size
	return {
		model = model,
		chassis = chassis,
		spec = s,
		force = force :: VectorForce,
		torque = torque :: Torque,
		align = align :: AlignOrientation,
		susp = susp,
		params = params,
		-- yaw inertia per unit mass of the (box-shaped) ballast
		yawFactor = (bsize.X * bsize.X + bsize.Z * bsize.Z) / 12,
		steer = 0,
		grounded = 0,
		flipTime = 0,
	}
end

-- Rays ignore the vehicle itself and every character (`ignore`).
function VehiclesConfig.setIgnore(sim: Sim, ignore: { Instance })
	local list = table.clone(ignore)
	table.insert(list, sim.model)
	sim.params.FilterDescendantsInstances = list
end

-- A CFrame whose X axis points along `x` (AlignOrientation's primary axis).
local function axisCFrame(x: Vector3): CFrame
	local ref = if math.abs(x.Y) < 0.9 then Vector3.yAxis else Vector3.zAxis
	local y = ref - x * ref:Dot(x)
	return CFrame.fromMatrix(Vector3.zero, x, y.Unit)
end
VehiclesConfig.axisCFrame = axisCFrame

-- One physics tick. throttle/steer are -1..1 (VehicleSeat.ThrottleFloat/SteerFloat).
function VehiclesConfig.step(sim: Sim, dt: number, throttle: number, steer: number, hasDriver: boolean)
	dt = math.clamp(dt, 1 / 240, 1 / 15)
	local s = sim.spec
	local chassis = sim.chassis
	local cf = chassis.CFrame
	local up, look, right = cf.UpVector, cf.LookVector, cf.RightVector
	local mass = chassis.AssemblyMass
	local com = chassis.AssemblyCenterOfMass
	local vel = chassis.AssemblyLinearVelocity
	local angVel = chassis.AssemblyAngularVelocity
	local g = workspace.Gravity

	local n = #sim.susp
	local travel, sag, radius = s.travel, s.sag, s.wheelRadius
	local rayLen = travel + radius
	local k = g / (n * sag) -- spring per unit mass: rest compression == sag
	local c = 2 * DAMPING_RATIO * math.sqrt(g / sag) / n

	local force = Vector3.zero
	local torque = Vector3.zero
	local grounded = 0
	for _, att in sim.susp do
		local origin = att.WorldPosition
		local dist = VehiclesConfig.groundDistance(origin, up, look, radius, rayLen, sim.params, true)
		if dist then
			grounded += 1
			local compression = rayLen - dist
			local pointVel = vel + angVel:Cross(origin - com)
			local f = k * compression - c * pointVel:Dot(up)
			if compression > travel then
				f += k * 4 * (compression - travel) -- bump stop
			end
			if f > 0 then
				local fv = up * (f * mass)
				force += fv
				torque += (origin - com):Cross(fv) * SUSPENSION_TORQUE_SCALE
			end
		end
	end
	sim.grounded = grounded

	-- smooth digital steering so keyboard players don't twitch
	sim.steer += math.clamp(steer - sim.steer, -dt * STEER_RATE, dt * STEER_RATE)

	local vf = vel:Dot(look)
	local vr = vel:Dot(right)
	local speed = math.abs(vf)
	local yawRate = angVel:Dot(up)
	local inertia = mass * sim.yawFactor

	if grounded > 0 then
		local gf = grounded / n
		local top = s.topSpeed
		local a
		if throttle > 0.05 then
			if vf < -0.5 then
				a = math.min(s.brake * throttle, -vf / dt) -- braking out of reverse
			else
				a = s.accel * throttle * math.max(0, 1 - (vf / top) ^ 2)
			end
		elseif throttle < -0.05 then
			if vf > 0.5 then
				a = -math.min(s.brake * -throttle, vf / dt)
			else
				local back = math.max(-vf, 0) / s.reverseSpeed
				a = -s.accel * 0.6 * -throttle * math.max(0, 1 - back * back)
			end
		else
			local decel = if hasDriver then COAST_DECEL + 0.0025 * vf * vf else PARKED_DECEL
			a = -math.sign(vf) * math.min(decel, speed / dt)
		end
		if vf > top then
			a -= (vf - top) * 1.5
		elseif vf < -s.reverseSpeed - 2 then
			a += (-vf - s.reverseSpeed) * 1.5
		end

		-- tyres cancel sideways sliding up to the grip limit (lets you drift at speed)
		local slideLimit = math.abs(vr) / dt
		local aLat = math.clamp(-vr * s.gripRate, -s.grip, s.grip)
		aLat = math.clamp(aLat, -slideLimit, slideLimit)
		force += (look * a + right * aLat) * (mass * gf)

		-- steering: chase a bicycle-model yaw rate, softened at speed
		local steerAngle = s.steerAngle * (1 - 0.55 * math.min(speed / top, 1))
		local targetYaw = -sim.steer * vf * math.tan(steerAngle) / s.wheelbase
		targetYaw = math.clamp(targetYaw, -s.handling, s.handling)
		torque += up * ((targetYaw - yawRate) * YAW_GAIN * inertia * gf)
	else
		torque += up * (-yawRate * 1.5 * inertia) -- a little air damping
	end

	-- stay upright; two-wheelers lean into the turn
	local targetUp = Vector3.yAxis
	if s.lean > 0 then
		local flatRight = Vector3.new(right.X, 0, right.Z)
		if flatRight.Magnitude > 0.1 then
			local lean = sim.steer * s.lean * math.clamp(vf / 18, 0, 1)
			targetUp = Vector3.yAxis * math.cos(lean) + flatRight.Unit * math.sin(lean)
		end
	end
	sim.align.CFrame = axisCFrame(targetUp)

	-- flipped and stuck: put it back on its wheels
	if up.Y < 0.25 then
		sim.flipTime += dt
	else
		sim.flipTime = 0
	end
	if sim.flipTime > 1.5 and vel.Magnitude < 15 then
		sim.flipTime = 0
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.1 then
			flat = Vector3.new(up.X, 0, up.Z)
		end
		if flat.Magnitude < 0.1 then
			flat = -Vector3.zAxis
		end
		local pos = chassis.Position + Vector3.new(0, 3, 0)
		chassis.CFrame = CFrame.lookAt(pos, pos + flat.Unit)
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
		force = Vector3.zero
		torque = Vector3.zero
	end

	sim.force.Force = force
	sim.torque.Torque = torque
end

-- Zeroes the drive forces (used when a simulator hands the vehicle off).
function VehiclesConfig.idle(sim: Sim)
	sim.force.Force = Vector3.zero
	sim.torque.Torque = Vector3.zero
	sim.align.CFrame = axisCFrame(Vector3.yAxis)
end

return VehiclesConfig
