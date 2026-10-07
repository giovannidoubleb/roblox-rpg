-- CITY GRIND: racing tuning (spec sections 58, 62, 98).
-- Lives in ReplicatedStorage.CityGrind.RacingConfig; read by server/Racing and
-- client/Racing. Circuit races and time trials use the City Speedway in
-- Industrial (start line tagged "RaceStart", checkpoints with attribute Index,
-- built by Districts). Street races follow the ROUTES below: ordered points
-- on real roads (the server raycasts every point at startup, snaps it to the
-- road surface and disables a route whose points or segments are blocked).

local RacingConfig = {}

RacingConfig.TRACK_NAME = "City Speedway"
RacingConfig.LAPS = 3 -- circuit races and time trials (same distance, so times compare)
RacingConfig.MIN_RACERS = 2
RacingConfig.MAX_RACERS = 8
RacingConfig.LOBBY_RANGE = 90 -- lobby members must stay this close to the start line
RacingConfig.TRACK_RANGE = 350 -- a time trial can be started this close to the start line
RacingConfig.LOBBY_WAIT = 20 -- seconds from the 2nd racer joining to the grid
RacingConfig.LOBBY_FULL_WAIT = 5 -- once the lobby is full
RacingConfig.COUNTDOWN = 5 -- grid countdown (circuit + street)
RacingConfig.TRIAL_COUNTDOWN = 3
RacingConfig.DNF_AFTER_WINNER = 30 -- circuit: seconds the rest get after the winner finishes
RacingConfig.STREET_DNF_AFTER_WINNER = 20
RacingConfig.CIRCUIT_MAX_SECONDS = 420
RacingConfig.TRIAL_MAX_SECONDS = 300
RacingConfig.OFF_VEHICLE_GRACE = 6 -- seconds out of your car before a DNF

-- Anti-cheat: flat speed between two 10 Hz samples may not exceed
-- topSpeed * SPEED_FACTOR + SPEED_MARGIN (studs/s); STRIKES samples in a row
-- (decaying) disqualify, and a single jump over JUMP_STUDS is a teleport.
RacingConfig.TICK = 0.1
RacingConfig.SPEED_FACTOR = 1.3
RacingConfig.SPEED_MARGIN = 15
RacingConfig.STRIKES = 4
RacingConfig.JUMP_STUDS = 60

-- Street race challenges
RacingConfig.CHALLENGE_RANGE = 150 -- both drivers this close to each other
RacingConfig.CHALLENGE_SECONDS = 15
RacingConfig.CHALLENGE_COOLDOWN = 8

-- Rewards. A race pays full rewards with 5+ starters; fewer starters pay
-- FIELD_BASE + FIELD_STEP per extra racer. After REWARD_CAP rewarded races in
-- an hour, races pay XP only (halved) so alt-farming isn't worth it.
RacingConfig.CIRCUIT_REWARDS = {
	{ cash = 1000, xp = 300, rep = 40 },
	{ cash = 600, xp = 200, rep = 25 },
	{ cash = 400, xp = 140, rep = 15 },
}
RacingConfig.CIRCUIT_REWARD_REST = { cash = 200, xp = 80, rep = 6 }
RacingConfig.STREET_REWARDS = {
	{ cash = 500, xp = 150, rep = 20 },
}
RacingConfig.STREET_REWARD_REST = { cash = 120, xp = 50, rep = 4 }
RacingConfig.TRIAL_XP = 40
RacingConfig.FIELD_BASE = 0.4
RacingConfig.FIELD_STEP = 0.15
RacingConfig.REWARD_CAP = 10

-- Time trial medals for LAPS laps (one-time bonus when first earned).
-- Rough guide: Stinger GT / Apex X1 for gold, Viper 600 for silver, a hatch or SUV for bronze.
RacingConfig.MEDALS = {
	{ id = 3, name = "Gold", icon = "🥇", time = 35, cash = 1500, xp = 500, color = Color3.fromRGB(255, 205, 60) },
	{ id = 2, name = "Silver", icon = "🥈", time = 46, cash = 700, xp = 250, color = Color3.fromRGB(200, 205, 215) },
	{ id = 1, name = "Bronze", icon = "🥉", time = 60, cash = 300, xp = 120, color = Color3.fromRGB(205, 130, 70) },
}

function RacingConfig.medalFor(seconds: number): number
	for _, m in RacingConfig.MEDALS do
		if seconds <= m.time then
			return m.id
		end
	end
	return 0
end

function RacingConfig.medalInfo(id: number): { id: number, name: string, icon: string, time: number, cash: number, xp: number, color: Color3 }?
	for _, m in RacingConfig.MEDALS do
		if m.id == id then
			return m
		end
	end
	return nil
end

-- Street race routes. Points are road-centre / lane positions (y is snapped to
-- the road by the server). Right-hand lanes: 8 studs off the road centre line.
-- Roads: main road z = 0 (x -760..900), cross road x = 0 (z -730..330),
-- Downtown avenue z = -480 (x -360..300) up the ramp to Luxury Drive
-- (x -730..-420, y 14), Industrial service road x = 312 (z -430..-24) from the
-- race paddock lot (x 300..400, z -530..-430).
local V = Vector3.new
RacingConfig.ROUTES = {
	{
		id = "main_street",
		name = "Main Street Sprint",
		blurb = "Old Town cobbles to the Industrial docks, flat out along the main road.",
		points = { V(-700, 0, 8), V(-500, 0, 8), V(-300, 0, 8), V(-100, 0, 8), V(100, 0, 8), V(300, 0, 8), V(500, 0, 8), V(760, 0, 8) },
	},
	{
		id = "crosstown",
		name = "Crosstown Drag",
		blurb = "From the beach straight up the cross road, through the Neighborhood, into Downtown.",
		points = { V(8, 0, 300), V(8, 0, 150), V(8, 0, 0), V(8, 0, -150), V(8, 0, -300), V(8, 0, -480), V(8, 0, -600) },
	},
	{
		id = "hill_climb",
		name = "Hillside Climb",
		blurb = "West down Downtown's avenue, up the ramp and along Luxury Drive.",
		points = { V(250, 0, -488), V(100, 0, -488), V(-100, 0, -488), V(-300, 0, -488), V(-365, 0, -488), V(-425, 14, -488), V(-520, 14, -488), V(-620, 14, -488) },
	},
	{
		id = "industrial_loop",
		name = "Industrial Loop",
		blurb = "Avenue to the paddock, down the service road, back through the Neighborhood.",
		points = { V(40, 0, -472), V(180, 0, -472), V(312, 0, -478), V(312, 0, -380), V(312, 0, -200), V(312, 0, 0), V(150, 0, -8), V(0, 0, 0), V(8, 0, -150), V(8, 0, -300), V(8, 0, -440) },
	},
}

RacingConfig.ROUTE_BY_ID = {} :: { [string]: any }
for _, r in RacingConfig.ROUTES do
	RacingConfig.ROUTE_BY_ID[r.id] = r
	local len = 0
	for i = 2, #r.points do
		len += (r.points[i] - r.points[i - 1]).Magnitude
	end
	r.length = len
end

RacingConfig.STREET_GATE_HALF_WIDTH = 20 -- road is 32 wide; a little slack
RacingConfig.STREET_PROXIMITY = 14 -- also counts if you pass this close to a point

function RacingConfig.formatTime(seconds: number?): string
	if not seconds or seconds <= 0 then
		return "--:--.--"
	end
	local m = math.floor(seconds / 60)
	local s = seconds - m * 60
	return string.format("%d:%05.2f", m, s)
end

function RacingConfig.ordinal(n: number): string
	local suffix = "th"
	local mod100 = n % 100
	if mod100 < 11 or mod100 > 13 then
		local mod10 = n % 10
		suffix = if mod10 == 1 then "st" elseif mod10 == 2 then "nd" elseif mod10 == 3 then "rd" else "th"
	end
	return tostring(n) .. suffix
end

-- A checkpoint arch (half ring of neon segments) spanning the road, centred on
-- `ground` (road surface), facing `forward`. Used by the server for street
-- route rings and by the client for its local next-checkpoint highlight.
function RacingConfig.buildArch(ground: Vector3, forward: Vector3, halfWidth: number, color: Color3, transparency: number, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "CheckpointArch"
	local f = Vector3.new(forward.X, 0, forward.Z)
	f = if f.Magnitude > 1e-3 then f.Unit else Vector3.xAxis
	local right = f:Cross(Vector3.yAxis).Unit
	local segments = 12
	local r = halfWidth
	local segLen = math.pi * r / segments + 0.6
	for i = 0, segments - 1 do
		local a = (i + 0.5) / segments * math.pi
		local pos = ground + right * (math.cos(a) * r) + Vector3.yAxis * (math.sin(a) * r * 0.75)
		local tangent = (-right * math.sin(a) + Vector3.yAxis * math.cos(a) * 0.75).Unit
		local p = Instance.new("Part")
		p.Name = "Segment"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Transparency = transparency
		p.Size = Vector3.new(0.9, segLen, 0.9)
		p.CFrame = CFrame.fromMatrix(pos, f, tangent)
		p.Parent = model
	end
	model.Parent = parent
	return model
end

return RacingConfig
