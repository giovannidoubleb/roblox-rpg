-- CITY GRIND: racing (spec sections 58, 62, 98).
-- * Circuit races at the City Speedway (Industrial): drive up to the RACE HQ
--   kiosk by the start line, open it (prompt) and join the lobby from your car.
--   2-8 racers; LOBBY_WAIT seconds after the 2nd joins the cars are moved to a
--   staggered grid behind the line, a countdown runs, then RacingConfig.LAPS laps.
-- * Solo time trials on the same track (same distance) with medal times.
-- * Street races: challenge another driver from the player menu (client
--   Social action). They get COUNTDOWN-free 15 s to accept; both cars are moved
--   to the start of a RacingConfig.ROUTES route, whose checkpoint arches exist
--   only while that race is live.
-- Every checkpoint is validated here at 10 Hz from the car's chassis position:
-- the segment between two samples must cross the checkpoint plane (inside its
-- width) in order; crossing a later one first is a "missed checkpoint"; flat
-- speed above the car's top speed * SPEED_FACTOR + SPEED_MARGIN gets strikes,
-- and a jump over JUMP_STUDS is a teleport (both disqualify).
--
-- Public API:
--   Racing.raceFinished: BindableEvent (player, place, timeSeconds, raceKind, raceId)
--       raceKind "circuit" | "street" | "trial"; fired for finishers only.
--   Racing.bestTime(player): number?   best full-distance speedway time (race or trial)
--   Racing.raceOf(player): string?     kind of the race the player is in ("lobby" while queued)
-- Player attributes: Race ("" | "lobby" | "circuit" | "street" | "trial"),
--   RaceBest (seconds, 0 = none), RaceWins (circuit wins).
-- Saved section "racing": see registerSection below.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local RC = require(shared:WaitForChild("RacingConfig"))
local VC = require(shared:WaitForChild("VehiclesConfig"))
local Net = require(script.Parent:WaitForChild("Net"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Vehicles = require(script.Parent:WaitForChild("Vehicles"))

local Racing = {}
Racing.raceFinished = Instance.new("BindableEvent")

PlayerData.registerSection("racing", function()
	return {
		bestRace = 0, -- best LAPS-lap speedway time (circuit race or time trial), seconds
		bestLap = 0,
		bestTrial = 0,
		medal = 0, -- best time trial medal: 0 none, 1 bronze, 2 silver, 3 gold
		races = 0, -- circuit races finished
		wins = 0,
		podiums = 0,
		trials = 0,
		streetRaces = 0,
		streetWins = 0,
		routes = {}, -- [routeId] = best seconds
		recent = {}, -- newest first: { k = kind, n = name, p = place (0 = DNF), of = field, t = seconds, at = os.time() }
	}
end)

local RacingAction = Net.remote("RemoteFunction", "RacingAction") -- (action, ...) -> ok, message, data
local RacingEvent = Net.remote("RemoteEvent", "RacingEvent") -- server -> client (kind, payload)

type CP = { pos: Vector3, f: Vector3, r: Vector3, hw: number, hh: number, radius: number, ground: Vector3 }
type Racer = {
	player: Player,
	name: string,
	userId: number,
	model: Model,
	chassis: BasePart,
	spec: VC.Spec,
	slot: number,
	lap: number,
	next: number,
	dist: number,
	finished: boolean,
	dnf: boolean,
	reason: string?,
	time: number,
	place: number,
	lastPos: Vector3,
	lastT: number,
	strikes: number,
	offSince: number?,
	lastWarn: number,
	lapStart: number,
	bestLap: number,
	reward: { [string]: any }?,
	grid: CFrame?, -- where freezeAt parked the car for the countdown
}
type Race = {
	id: string,
	kind: string,
	name: string,
	routeId: string?,
	laps: number,
	cps: { CP },
	list: { Racer },
	phase: string,
	goT: number,
	starters: number,
	finishers: number,
	deadline: number?,
	maxEnd: number,
	folder: Folder?,
	tick: number,
}

local track: { startPos: Vector3, forward: Vector3, right: Vector3, width: number, cps: { CP } }? = nil
local routeOk: { [string]: boolean } = {}
local routePoints: { [string]: { Vector3 } } = {}
local races: { [string]: Race } = {}
local racerOf: { [Player]: Race } = {}
local circuitRace: Race? = nil
local lobby: { Player } = {}
local lobbyStartAt: number? = nil
local watchers: { [Player]: number } = {}
local challenges: { [string]: { id: string, from: Player, to: Player, routeId: string, expires: number } } = {}
local rewardLog: { [Player]: { number } } = {}
local root: Folder
local liveFolder: Folder
local raceCounter = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function fire(player: Player, kind: string, payload: any)
	if player.Parent then
		RacingEvent:FireClient(player, kind, payload)
	end
end

local function sibling(name: string): any
	local m = script.Parent:FindFirstChild(name)
	if not m then
		return nil
	end
	local ok, mod = pcall(require, m)
	return if ok and type(mod) == "table" then mod else nil
end

local function section(player: Player): any
	return PlayerData.section(player, "racing")
end

local function setRace(player: Player, kind: string)
	if player.Parent then
		player:SetAttribute("Race", kind)
	end
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.xAxis
end

local function unlock(player: Player, id: string)
	local Quests = sibling("Quests")
	if Quests and type(Quests.unlock) == "function" then
		pcall(Quests.unlock, player, id)
	end
end

local function inEvent(player: Player): boolean
	local Events = sibling("Events")
	if Events and type(Events.isInEvent) == "function" then
		local ok, id = pcall(Events.isInEvent, player)
		return ok and id ~= nil
	end
	return false
end

local function exclusions(): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, m in CollectionService:GetTagged("CityVehicle") do
		table.insert(list, m)
	end
	if liveFolder then
		table.insert(list, liveFolder)
	end
	return list
end

local function groundBelow(pos: Vector3, up: number, down: number): RaycastResult?
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclusions()
	params.RespectCanCollide = true
	params.IgnoreWater = true
	return workspace:Raycast(pos + Vector3.new(0, up, 0), Vector3.new(0, -(up + down), 0), params)
end

---------------------------------------------------------------------------
-- Track + routes
---------------------------------------------------------------------------
local function makeCP(ground: Vector3, forward: Vector3, hw: number, radius: number): CP
	local f = flat(forward)
	return { pos = ground + Vector3.new(0, 4, 0), ground = ground, f = f, r = f:Cross(Vector3.yAxis).Unit, hw = hw, hh = 12, radius = radius }
end

local function loadTrack(city: Instance)
	local line: BasePart? = nil
	for _, inst in CollectionService:GetTagged("RaceStart") do
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			line = inst
			break
		end
	end
	if not line then
		warn("[Racing] no RaceStart part found; circuit races and time trials are off")
		return
	end
	local folder = line.Parent and line.Parent:FindFirstChild("Checkpoints")
	if not folder then
		local districts = city:FindFirstChild("Districts")
		local industrial = districts and districts:FindFirstChild("Industrial")
		local rt = industrial and industrial:FindFirstChild("RaceTrack", true)
		folder = rt and rt:FindFirstChild("Checkpoints")
	end
	local parts = {}
	if folder then
		for _, p in folder:GetChildren() do
			if p:IsA("BasePart") and type(p:GetAttribute("Index")) == "number" then
				table.insert(parts, p)
			end
		end
	end
	table.sort(parts, function(a, b)
		return a:GetAttribute("Index") < b:GetAttribute("Index")
	end)
	if #parts == 0 then
		warn("[Racing] the race track has no checkpoints; circuit races are off")
		return
	end
	local fwdAttr = line:GetAttribute("Forward")
	local forward = flat(if typeof(fwdAttr) == "Vector3" then fwdAttr else line.CFrame.LookVector)
	local widthAttr = line:GetAttribute("TrackWidth")
	local width = if type(widthAttr) == "number" then widthAttr else line.Size.Z
	local cps = {}
	for _, p in parts do
		local ground = p.Position - Vector3.new(0, p.Size.Y / 2, 0)
		table.insert(cps, makeCP(ground, p.CFrame.LookVector, p.Size.X / 2, 0))
	end
	local startGround = Vector3.new(line.Position.X, line.Position.Y - line.Size.Y / 2, line.Position.Z)
	table.insert(cps, makeCP(startGround, forward, width / 2 + 3, 0)) -- the start/finish line closes each lap
	track = { startPos = startGround, forward = forward, right = forward:Cross(Vector3.yAxis).Unit, width = width, cps = cps }
end

local ROAD_PARTS = { MainRoad = true, CrossRoad = true, Street = true, RampRoad = true, Lot = true, LaneMark = true, Crosswalk = true }

-- Snaps every route point to the road and checks the way between points is clear.
local function validateRoutes()
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclusions()
	params.RespectCanCollide = true
	params.IgnoreWater = true
	for _, route in RC.ROUTES do
		local ok = true
		local pts = {}
		for i, p in route.points do
			-- cast from just above the expected road height so lamp arms or trees can't catch it
			local hit = groundBelow(p, 6, 12)
			if not hit then
				warn(string.format("[Racing] route %s point %d (%s) has no ground; route disabled", route.id, i, tostring(p)))
				ok = false
				break
			end
			if math.abs(hit.Position.Y - p.Y) > 6 then
				warn(string.format("[Racing] route %s point %d lands on %s at y=%.1f (expected ~%d); route disabled", route.id, i, hit.Instance:GetFullName(), hit.Position.Y, p.Y))
				ok = false
				break
			end
			if not ROAD_PARTS[hit.Instance.Name] then
				warn(string.format("[Racing] route %s point %d is on %s, not a road", route.id, i, hit.Instance.Name))
			end
			table.insert(pts, Vector3.new(p.X, hit.Position.Y, p.Z))
		end
		if ok then
			for i = 2, #pts do
				local a = pts[i - 1] + Vector3.new(0, 3.5, 0)
				local b = pts[i] + Vector3.new(0, 3.5, 0)
				local hit = workspace:Raycast(a, b - a, params)
				if hit then
					warn(string.format("[Racing] route %s is blocked between points %d and %d by %s; route disabled", route.id, i - 1, i, hit.Instance:GetFullName()))
					ok = false
					break
				end
			end
		end
		routeOk[route.id] = ok
		routePoints[route.id] = pts
	end
end

---------------------------------------------------------------------------
-- Checkpoint crossing
---------------------------------------------------------------------------
-- Did the move p0 -> p1 pass through the checkpoint? Returns the fraction of
-- the move at which it happened (for precise timing).
local function crossed(cp: CP, p0: Vector3, p1: Vector3): (boolean, number)
	local d0 = (p0 - cp.pos):Dot(cp.f)
	local d1 = (p1 - cp.pos):Dot(cp.f)
	if d0 < 0 and d1 >= 0 then
		local t = -d0 / (d1 - d0)
		local x = p0 + (p1 - p0) * t
		local rel = x - cp.pos
		if math.abs(rel:Dot(cp.r)) <= cp.hw and math.abs(rel.Y) <= cp.hh then
			return true, t
		end
	end
	if cp.radius > 0 then
		local rel = p1 - cp.pos
		if Vector3.new(rel.X, 0, rel.Z).Magnitude <= cp.radius and math.abs(rel.Y) <= cp.hh then
			return true, 1
		end
	end
	return false, 0
end

---------------------------------------------------------------------------
-- Cars
---------------------------------------------------------------------------
local function freezeAt(r: Racer, groundCF: CFrame)
	local cf = groundCF * CFrame.new(0, VC.groundOffset(r.spec) + 0.3, 0)
	r.grid = groundCF
	r.chassis.Anchored = true
	r.chassis.AssemblyLinearVelocity = Vector3.zero
	r.chassis.AssemblyAngularVelocity = Vector3.zero
	r.model:PivotTo(cf)
end

local function release(r: Racer)
	if r.chassis.Parent and r.chassis.Anchored and Vehicles.drivingVehicle(r.player) == r.model then
		r.chassis.Anchored = false
		pcall(function()
			r.chassis:SetNetworkOwner(r.player)
		end)
	end
end

local function slotClear(groundCF: CFrame, size: Vector3, ignore: { Instance }): boolean
	-- selene: allow(undefined_variable)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = ignore
	overlap.RespectCanCollide = true
	return #workspace:GetPartBoundsInBox(groundCF * CFrame.new(0, size.Y / 2 + 1.2, 0), size, overlap) == 0
end

-- Ground CFrame (facing `forward`) at a spot, snapped to whatever is below.
local function groundCF(pos: Vector3, forward: Vector3): CFrame
	local hit = groundBelow(pos, 25, 25)
	local p = if hit then hit.Position else pos
	return CFrame.lookAt(p, p + forward)
end

local function trackSlot(i: number): CFrame
	local t = track :: any
	local row, col = i // 2, i % 2
	local back = 12 + row * 16 + col * 8
	local lateral = (if col == 0 then -1 else 1) * t.width * 0.22
	return groundCF(t.startPos - t.forward * back + t.right * lateral, t.forward)
end

local function newRacer(player: Player, model: Model, slot: number): Racer?
	local chassis = model.PrimaryPart
	local spec = VC.byId[model:GetAttribute("VehicleId") or ""]
	if not chassis or not spec then
		return nil
	end
	return {
		player = player,
		name = player.DisplayName,
		userId = player.UserId,
		model = model,
		chassis = chassis,
		spec = spec,
		slot = slot,
		lap = 1,
		next = 1,
		dist = 0,
		finished = false,
		dnf = false,
		reason = nil,
		time = 0,
		place = 0,
		lastPos = chassis.Position,
		lastT = now(),
		strikes = 0,
		offSince = nil,
		lastWarn = 0,
		lapStart = 0,
		bestLap = 0,
		reward = nil,
	}
end

---------------------------------------------------------------------------
-- Rewards + saving
---------------------------------------------------------------------------
local function underCap(player: Player): boolean
	local log = rewardLog[player] or {}
	local cutoff = os.time() - 3600
	local kept = {}
	for _, t in log do
		if t > cutoff then
			table.insert(kept, t)
		end
	end
	rewardLog[player] = kept
	if #kept >= RC.REWARD_CAP then
		return false
	end
	table.insert(kept, os.time())
	return true
end

local function submitBoard(player: Player, seconds: number)
	local Leaderboards = sibling("Leaderboards")
	if Leaderboards and type(Leaderboards.submit) == "function" then
		pcall(Leaderboards.submit, "fastestRace", player, math.floor(seconds * 1000 + 0.5) / 1000)
	end
end

local function pushRecent(sec: any, entry: { [string]: any })
	table.insert(sec.recent, 1, entry)
	while #sec.recent > 10 do
		table.remove(sec.recent)
	end
end

-- Pays out and records a finish. Runs once per finisher, at the moment they cross the line.
local function onFinish(race: Race, r: Racer)
	local player = r.player
	local sec = section(player)
	local reward: { [string]: any } = { cash = 0, xp = 0, rep = 0 }
	if not sec or not player.Parent then
		r.reward = reward
		return
	end
	local full = underCap(player)
	if race.kind == "trial" then
		reward.xp = if full then RC.TRIAL_XP else math.floor(RC.TRIAL_XP / 2)
		sec.trials += 1
		local medal = RC.medalFor(r.time)
		reward.medal = medal
		if medal > (sec.medal or 0) then
			for id = (sec.medal or 0) + 1, medal do
				local info = RC.medalInfo(id)
				if info then
					reward.cash += info.cash
					reward.xp += info.xp
				end
			end
			sec.medal = medal
			reward.newMedal = true
			if medal >= 3 then
				unlock(player, "trial_gold")
			end
		end
		if sec.bestTrial == 0 or r.time < sec.bestTrial then
			sec.bestTrial = r.time
		end
	else
		local base = (if race.kind == "circuit" then RC.CIRCUIT_REWARDS else RC.STREET_REWARDS)[r.place]
		base = base or (if race.kind == "circuit" then RC.CIRCUIT_REWARD_REST else RC.STREET_REWARD_REST)
		local scale = if race.starters >= 2 then math.min(1, RC.FIELD_BASE + RC.FIELD_STEP * (race.starters - 1)) else 0
		if full then
			reward.cash = math.floor(base.cash * scale)
			reward.xp = math.floor(base.xp * scale)
			reward.rep = math.floor(base.rep * scale)
		else
			reward.xp = math.floor(base.xp * scale / 2)
			reward.capped = true
		end
		if race.kind == "circuit" then
			sec.races += 1
			if r.place == 1 and race.starters >= 2 then
				sec.wins += 1
				unlock(player, "race_win")
				if sec.wins >= 10 then
					unlock(player, "race_wins_10")
				end
			end
			if r.place <= 3 and race.starters >= 2 then
				sec.podiums += 1
			end
		else
			sec.streetRaces += 1
			if r.place == 1 and race.starters >= 2 then
				sec.streetWins += 1
				unlock(player, "street_king")
			end
			local id = race.routeId or ""
			local best = sec.routes[id]
			if type(best) ~= "number" or r.time < best then
				sec.routes[id] = r.time
				reward.newBest = true
			end
		end
		unlock(player, "race_first")
	end
	-- speedway bests (circuit races and trials run the same distance)
	if race.kind ~= "street" then
		if r.bestLap > 0 and (sec.bestLap == 0 or r.bestLap < sec.bestLap) then
			sec.bestLap = r.bestLap
		end
		if sec.bestRace == 0 or r.time < sec.bestRace then
			sec.bestRace = r.time
			reward.newBest = true
		end
		submitBoard(player, sec.bestRace)
	end
	PlayerData.markChanged(player)
	local label = if race.kind == "trial" then "Time trial" elseif race.kind == "circuit" then RC.TRACK_NAME .. " race (" .. RC.ordinal(r.place) .. ")" else race.name .. " (" .. RC.ordinal(r.place) .. ")"
	if reward.cash > 0 then
		PlayerData.addCash(player, reward.cash, label)
	end
	if reward.xp > 0 then
		PlayerData.addXP(player, reward.xp)
	end
	if reward.rep > 0 then
		PlayerData.addReputation(player, reward.rep)
	end
	r.reward = reward
end

---------------------------------------------------------------------------
-- Race lifecycle
---------------------------------------------------------------------------
local function standings(race: Race): { Racer }
	local list = table.clone(race.list)
	local n = #race.cps
	table.sort(list, function(a, b)
		local ka = if a.finished then 0 elseif a.dnf then 2 else 1
		local kb = if b.finished then 0 elseif b.dnf then 2 else 1
		if ka ~= kb then
			return ka < kb
		end
		if ka == 0 then
			return a.place < b.place
		elseif ka == 2 then
			return a.slot < b.slot
		end
		local pa = (a.lap - 1) * n + a.next
		local pb = (b.lap - 1) * n + b.next
		if pa ~= pb then
			return pa > pb
		end
		if a.dist ~= b.dist then
			return a.dist < b.dist
		end
		return a.slot < b.slot
	end)
	return list
end

local function broadcast(race: Race)
	local order = standings(race)
	local board = {}
	for i, r in order do
		board[i] = { n = r.name, u = r.userId, s = if r.finished then "fin" elseif r.dnf then "dnf" else "", t = r.time }
	end
	for i, r in order do
		fire(r.player, "State", {
			id = race.id,
			phase = race.phase,
			lap = math.min(r.lap, race.laps),
			laps = race.laps,
			next = r.next,
			n = #race.cps,
			pos = i,
			total = #order,
			finished = r.finished,
			dnf = r.dnf,
			time = r.time,
			bestLap = r.bestLap,
			deadline = race.deadline,
			board = board,
		})
	end
end

local function clearRacer(race: Race, r: Racer)
	if racerOf[r.player] == race then
		racerOf[r.player] = nil
		setRace(r.player, "")
	end
end

local function dnf(race: Race, r: Racer, reason: string)
	if r.finished or r.dnf then
		return
	end
	r.dnf = true
	r.reason = reason
	if r.chassis.Parent and r.chassis.Anchored then
		release(r)
	end
	fire(r.player, "Out", { id = race.id, reason = reason })
	clearRacer(race, r)
end

local function endRace(race: Race, note: string?)
	if race.phase == "done" then
		return
	end
	local wasCountdown = race.phase == "countdown"
	race.phase = "done"
	races[race.id] = nil
	if circuitRace == race then
		circuitRace = nil
		if lobbyStartAt then
			lobbyStartAt = math.max(lobbyStartAt, now() + 8)
		end
	end
	for _, r in race.list do
		if not r.finished and not r.dnf then
			r.dnf = true
			r.reason = note or "Did not finish"
		end
		if r.chassis.Parent and r.chassis.Anchored then
			release(r)
		end
		clearRacer(race, r)
	end
	if race.folder then
		race.folder:Destroy()
		race.folder = nil
	end
	local order = standings(race)
	local rows = {}
	for _, r in order do
		table.insert(rows, { name = r.name, userId = r.userId, place = r.place, time = r.time, bestLap = r.bestLap, status = if r.finished then "fin" else "dnf", reason = r.reason, vehicle = r.spec.name })
	end
	for _, r in race.list do
		local player = r.player
		if not player.Parent then
			continue
		end
		local sec = section(player)
		if sec and not wasCountdown then
			pushRecent(sec, { k = race.kind, n = race.name, p = if r.finished then r.place else 0, of = #race.list, t = if r.finished then r.time else 0, at = os.time() })
			PlayerData.markChanged(player)
		end
		fire(player, "Results", {
			id = race.id,
			kind = race.kind,
			name = race.name,
			laps = race.laps,
			note = note,
			rows = rows,
			you = { place = r.place, time = r.time, bestLap = r.bestLap, finished = r.finished, reason = r.reason, reward = r.reward },
			best = sec and sec.bestRace or 0,
			routeBest = if sec and race.routeId then sec.routes[race.routeId] else nil,
		})
	end
end

local function finish(race: Race, r: Racer, time: number)
	race.finishers += 1
	r.finished = true
	r.time = time
	r.place = race.finishers
	if race.finishers == 1 and race.kind ~= "trial" then
		race.deadline = now() + (if race.kind == "street" then RC.STREET_DNF_AFTER_WINNER else RC.DNF_AFTER_WINNER)
		for _, other in race.list do
			if other ~= r and not other.finished and not other.dnf then
				Net.notify(other.player, "WINNER IN", string.format("%s took the win. You have %ds to finish.", r.name, if race.kind == "street" then RC.STREET_DNF_AFTER_WINNER else RC.DNF_AFTER_WINNER))
			end
		end
	end
	onFinish(race, r)
	fire(r.player, "Finished", { id = race.id, place = r.place, time = time, total = #race.list })
	clearRacer(race, r)
	Racing.raceFinished:Fire(r.player, r.place, time, race.kind, race.id)
end

local function advance(race: Race, r: Racer, p0: Vector3, p1: Vector3, t0: number, t1: number)
	local n = #race.cps
	local hit, frac = crossed(race.cps[r.next], p0, p1)
	if hit then
		local tc = t0 + (t1 - t0) * frac
		if r.next == n then
			local lapTime = tc - r.lapStart
			r.lapStart = tc
			if race.laps > 1 and (r.bestLap == 0 or lapTime < r.bestLap) then
				r.bestLap = lapTime
			end
			if r.lap >= race.laps then
				if race.laps == 1 then
					r.bestLap = 0
				end
				finish(race, r, tc - race.goT)
				return
			end
			r.lap += 1
			r.next = 1
			fire(r.player, "Lap", { id = race.id, lap = r.lap, laps = race.laps, lapTime = lapTime, best = r.bestLap })
		else
			r.next += 1
		end
		return
	end
	for j = r.next + 1, n do
		-- the line itself is crossed at the start of the race / of every lap
		if j == n and r.next == 1 and race.kind ~= "street" then
			continue
		end
		if crossed(race.cps[j], p0, p1) then
			if t1 - r.lastWarn > 3 then
				r.lastWarn = t1
				fire(r.player, "Missed", { id = race.id, next = r.next })
			end
			break
		end
	end
end

local function go(race: Race)
	race.phase = "live"
	local t = now()
	local starters = 0
	for _, r in race.list do
		if r.dnf then
			continue
		end
		if not r.player.Parent or Vehicles.drivingVehicle(r.player) ~= r.model then
			dnf(race, r, "You weren't in your vehicle at the start.")
			continue
		end
		starters += 1
		release(r)
		r.lastPos = r.chassis.Position
		r.lastT = t
		r.lapStart = race.goT
	end
	race.starters = starters
	local needed = if race.kind == "trial" then 1 else RC.MIN_RACERS
	if starters < needed then
		race.phase = "countdown" -- cancelled before it really started: nothing is recorded
		endRace(race, "Not enough racers at the start.")
	end
end

local function stepRace(race: Race, t: number)
	if race.phase == "countdown" then
		for _, r in race.list do
			if not r.dnf and not r.player.Parent then
				dnf(race, r, "Left the game")
			elseif not r.dnf and r.grid and r.chassis.Parent and not r.chassis.Anchored then
				-- Vehicles unanchors a car when its driver sits back down: no rolling starts.
				freezeAt(r, r.grid :: CFrame)
			end
		end
		if t >= race.goT then
			go(race)
		end
		race.tick += 1
		if race.tick % 5 == 0 and race.phase == "countdown" then
			broadcast(race)
		end
		return
	end
	if race.phase ~= "live" then
		return
	end
	local n = #race.cps
	for _, r in race.list do
		if r.finished or r.dnf then
			continue
		end
		local player = r.player
		if not player.Parent then
			dnf(race, r, "Left the game")
			continue
		end
		if not r.model.Parent or not r.chassis.Parent then
			dnf(race, r, "Your vehicle is gone.")
			continue
		end
		local pos = r.chassis.Position
		local dt = t - r.lastT
		if dt <= 0 then
			continue
		end
		if Vehicles.drivingVehicle(player) ~= r.model then
			r.offSince = r.offSince or t
			if t - (r.offSince :: number) > RC.OFF_VEHICLE_GRACE then
				dnf(race, r, "You left your vehicle.")
				continue
			end
			r.lastPos = pos
			r.lastT = t
			continue
		end
		r.offSince = nil
		if not r.chassis.Anchored then
			local moved = Vector3.new(pos.X - r.lastPos.X, 0, pos.Z - r.lastPos.Z).Magnitude
			local limit = r.spec.topSpeed * RC.SPEED_FACTOR + RC.SPEED_MARGIN
			if moved > limit * dt + RC.JUMP_STUDS then
				dnf(race, r, "Disqualified: your car jumped across the map.")
				continue
			end
			if moved / dt > limit then
				r.strikes += 1
				if r.strikes >= RC.STRIKES then
					dnf(race, r, "Disqualified: impossible speed.")
					continue
				end
			else
				r.strikes = math.max(0, r.strikes - 0.15)
			end
			advance(race, r, r.lastPos, pos, r.lastT, t)
		end
		r.lastPos = pos
		r.lastT = t
		if not r.finished and r.next <= n then
			local target = race.cps[r.next].pos
			r.dist = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z).Magnitude
		end
	end
	race.tick += 1
	if race.tick % 2 == 0 then
		broadcast(race)
	end
	local active = 0
	for _, r in race.list do
		if not r.finished and not r.dnf then
			active += 1
		end
	end
	if active == 0 then
		endRace(race)
	elseif race.deadline and t >= race.deadline then
		endRace(race, "Out of time")
	elseif t >= race.maxEnd then
		endRace(race, "Time limit reached")
	end
end

local function newRace(kind: string, name: string, laps: number, cps: { CP }, countdown: number, maxSeconds: number): Race
	raceCounter += 1
	local t = now()
	local race: Race = {
		id = string.format("%s-%d-%d", kind, os.time(), raceCounter),
		kind = kind,
		name = name,
		routeId = nil,
		laps = laps,
		cps = cps,
		list = {},
		phase = "countdown",
		goT = t + countdown,
		starters = 0,
		finishers = 0,
		deadline = nil,
		maxEnd = t + countdown + maxSeconds,
		folder = nil,
		tick = 0,
	}
	return race
end

local function announce(race: Race)
	local cps = {}
	for i, cp in race.cps do
		cps[i] = { p = cp.pos, g = cp.ground, f = cp.f, w = cp.hw }
	end
	races[race.id] = race
	for _, r in race.list do
		racerOf[r.player] = race
		setRace(r.player, race.kind)
		fire(r.player, "Race", { id = race.id, kind = race.kind, name = race.name, laps = race.laps, cps = cps, goT = race.goT, total = #race.list })
	end
	broadcast(race)
end

---------------------------------------------------------------------------
-- Lobby (circuit races)
---------------------------------------------------------------------------
local function lobbyInfo(): { [string]: any }
	local names = {}
	for _, p in lobby do
		table.insert(names, p.DisplayName)
	end
	local live = circuitRace
	return {
		names = names,
		count = #lobby,
		min = RC.MIN_RACERS,
		max = RC.MAX_RACERS,
		startAt = lobbyStartAt,
		raceLive = live ~= nil,
		raceCount = if live then #live.list else 0,
		laps = RC.LAPS,
	}
end

-- `left`: players just taken out of the lobby, so their client drops the lobby chip.
local function broadcastLobby(left: { Player }?)
	local info = lobbyInfo()
	local sent: { [Player]: boolean } = {}
	for _, p in lobby do
		info.inLobby = true
		fire(p, "Lobby", info)
		sent[p] = true
	end
	info.inLobby = false
	for _, p in (left or {}) :: { Player } do
		if not sent[p] then
			fire(p, "Lobby", info)
			sent[p] = true
		end
	end
	local t = os.clock()
	for p, expires in watchers do
		if t > expires or not p.Parent then
			watchers[p] = nil
		elseif not sent[p] then
			fire(p, "Lobby", info)
		end
	end
end

local function removeFromLobby(player: Player, reason: string?)
	local i = table.find(lobby, player)
	if not i then
		return
	end
	table.remove(lobby, i)
	if player.Parent and not racerOf[player] then
		setRace(player, "")
	end
	if reason then
		Net.notify(player, "RACE LOBBY", reason)
	end
	if #lobby < RC.MIN_RACERS then
		lobbyStartAt = nil
	end
	broadcastLobby({ player })
end

local function carNear(player: Player, pos: Vector3, range: number): Model?
	local model = Vehicles.drivingVehicle(player)
	local chassis = model and model.PrimaryPart
	if not model or not chassis then
		return nil
	end
	local d = chassis.Position - pos
	if Vector3.new(d.X, 0, d.Z).Magnitude > range or math.abs(d.Y) > 40 then
		return nil
	end
	return model
end

local function busyReason(player: Player): string?
	if racerOf[player] then
		return "You're already in a race."
	end
	if inEvent(player) then
		return "Finish your event first."
	end
	local q = player:GetAttribute("RankedQueue")
	if (type(q) == "string" and q ~= "") or player:GetAttribute("InGame") then
		return "You're queued for (or playing) a basketball game."
	end
	return nil
end

local function cancelTrials(reason: string)
	for _, race in races do
		if race.kind == "trial" then
			for _, r in race.list do
				Net.notify(r.player, "TIME TRIAL", reason)
			end
			endRace(race, reason)
		end
	end
end

local function startCircuit()
	local t = track
	if not t then
		return
	end
	local entrants: { Player } = {}
	while #lobby > 0 and #entrants < RC.MAX_RACERS do
		table.insert(entrants, table.remove(lobby, 1) :: Player)
	end
	lobbyStartAt = if #lobby >= RC.MIN_RACERS then now() + RC.LOBBY_WAIT else nil
	cancelTrials("The track is closing for a race. Try again after it.")
	local race = newRace("circuit", RC.TRACK_NAME, RC.LAPS, t.cps, RC.COUNTDOWN, RC.CIRCUIT_MAX_SECONDS)
	for _, p in entrants do
		local model = p.Parent and carNear(p, t.startPos, RC.LOBBY_RANGE * 2)
		local r = model and newRacer(p, model, #race.list)
		if r then
			table.insert(race.list, r)
		else
			setRace(p, "")
			Net.notify(p, "RACE", "You had to be in your car near the start line, so you missed the grid.")
		end
	end
	if #race.list < RC.MIN_RACERS then
		for _, r in race.list do
			table.insert(lobby, r.player) -- back in the queue
			setRace(r.player, "lobby")
		end
		lobbyStartAt = if #lobby >= RC.MIN_RACERS then now() + RC.LOBBY_WAIT else nil
		broadcastLobby(entrants)
		return
	end
	for _, r in race.list do
		freezeAt(r, trackSlot(r.slot))
	end
	circuitRace = race
	announce(race)
	broadcastLobby(entrants)
end

local function lobbyTick()
	local t = track
	if not t then
		return
	end
	for i = #lobby, 1, -1 do
		local p = lobby[i]
		if not p.Parent then
			table.remove(lobby, i)
		elseif not carNear(p, t.startPos, RC.LOBBY_RANGE) then
			removeFromLobby(p, "You left the start area (or your car), so you were taken out of the lobby.")
		end
	end
	if #lobby < RC.MIN_RACERS then
		if lobbyStartAt then
			lobbyStartAt = nil
			broadcastLobby()
		end
		return
	end
	if lobbyStartAt and now() >= lobbyStartAt and circuitRace == nil then
		startCircuit()
	end
end

local function join(player: Player): (boolean, string)
	local t = track
	if not t then
		return false, "The speedway isn't open."
	end
	if table.find(lobby, player) then
		return false, "You're already in the lobby."
	end
	local busy = busyReason(player)
	if busy then
		return false, busy
	end
	if not Vehicles.drivingVehicle(player) then
		return false, "Get in your vehicle first."
	end
	if not carNear(player, t.startPos, RC.LOBBY_RANGE) then
		return false, "Drive up to the start line at the " .. RC.TRACK_NAME .. " to join."
	end
	if #lobby >= RC.MAX_RACERS then
		return false, "The lobby is full. Catch the next one."
	end
	table.insert(lobby, player)
	setRace(player, "lobby")
	if #lobby >= RC.MIN_RACERS and not lobbyStartAt then
		lobbyStartAt = now() + RC.LOBBY_WAIT
	end
	if #lobby >= RC.MAX_RACERS and lobbyStartAt then
		lobbyStartAt = math.min(lobbyStartAt, now() + RC.LOBBY_FULL_WAIT)
	end
	broadcastLobby()
	if #lobby < RC.MIN_RACERS then
		return true, "You're in! Waiting for one more racer."
	end
	return true, "You're in! The race starts soon."
end

---------------------------------------------------------------------------
-- Time trials
---------------------------------------------------------------------------
local function trial(player: Player): (boolean, string)
	local t = track
	if not t then
		return false, "The speedway isn't open."
	end
	local busy = busyReason(player)
	if busy then
		return false, busy
	end
	if table.find(lobby, player) then
		return false, "Leave the race lobby first."
	end
	if circuitRace then
		return false, "A race is on the track right now. Join the next one or wait for it to finish."
	end
	if not Vehicles.drivingVehicle(player) then
		return false, "Get in your vehicle first."
	end
	local model = carNear(player, t.startPos, RC.TRACK_RANGE)
	if not model then
		return false, "Drive to the " .. RC.TRACK_NAME .. " in Industrial to start a time trial."
	end
	local used: { [number]: boolean } = {}
	for _, race in races do
		if race.kind == "trial" then
			for _, r in race.list do
				used[r.slot] = true
			end
		end
	end
	local slot: number? = nil
	for i = 0, RC.MAX_RACERS - 1 do
		if not used[i] then
			slot = i
			break
		end
	end
	if not slot then
		return false, "The track is packed with time trials. Try again in a minute."
	end
	local race = newRace("trial", RC.TRACK_NAME .. " Time Trial", RC.LAPS, t.cps, RC.TRIAL_COUNTDOWN, RC.TRIAL_MAX_SECONDS)
	local r = newRacer(player, model, slot)
	if not r then
		return false, "Your vehicle isn't ready."
	end
	table.insert(race.list, r)
	freezeAt(r, trackSlot(slot))
	announce(race)
	return true, "Time trial: " .. RC.LAPS .. " laps. Go on green!"
end

---------------------------------------------------------------------------
-- Street races
---------------------------------------------------------------------------
local function startStreet(a: Player, b: Player, routeId: string): (boolean, string)
	local route = RC.ROUTE_BY_ID[routeId]
	local pts = routePoints[routeId]
	if not route or not pts or not routeOk[routeId] then
		return false, "That route is closed."
	end
	local ma, mb = Vehicles.drivingVehicle(a), Vehicles.drivingVehicle(b)
	if not ma or not mb then
		return false, "Both drivers need to be in their vehicles."
	end
	local cps = {}
	for i = 2, #pts do
		local dirIn = flat(pts[i] - pts[i - 1])
		local f = dirIn
		if i < #pts then
			local dirOut = flat(pts[i + 1] - pts[i])
			local sum = dirIn + dirOut
			f = if sum.Magnitude > 0.1 then sum.Unit else dirOut
		end
		local hw = RC.STREET_GATE_HALF_WIDTH / math.max(0.5, dirIn:Dot(f))
		table.insert(cps, makeCP(pts[i], f, hw, RC.STREET_PROXIMITY))
	end
	local race = newRace("street", route.name, 1, cps, RC.COUNTDOWN, route.length / 12 + 60)
	race.routeId = routeId
	local ra, rb = newRacer(a, ma, 0), newRacer(b, mb, 1)
	if not ra or not rb then
		return false, "A vehicle isn't ready."
	end
	race.list = { ra, rb }
	-- grid: side by side behind the first point; slide back if something is in the way
	local dir = flat(pts[2] - pts[1])
	local right = dir:Cross(Vector3.yAxis).Unit
	local ignore: { Instance } = { liveFolder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	for _, r in race.list do
		table.insert(ignore, r.model)
	end
	for k, r in race.list do
		local lateral = (if k == 1 then -1 else 1) * 6
		local cf = groundCF(pts[1] - dir * 10 + right * lateral, dir)
		for back = 1, 5 do
			local size = Vector3.new(r.spec.width + 1, r.spec.height - 1, r.spec.length + 1)
			if slotClear(cf, size, ignore) then
				break
			end
			cf = groundCF(pts[1] - dir * (10 + back * 14) + right * lateral, dir)
		end
		freezeAt(r, cf)
	end
	-- checkpoint arches, only while this race is live
	local folder = Instance.new("Folder")
	folder.Name = race.id
	folder.Parent = liveFolder
	race.folder = folder
	for i, cp in cps do
		local color = if i == #cps then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(255, 140, 40)
		RC.buildArch(cp.ground, cp.f, math.min(cp.hw, 18), color, 0.35, folder)
	end
	announce(race)
	return true, "Race on!"
end

local function closeChallenge(id: string, note: string?)
	local c = challenges[id]
	if not c then
		return
	end
	challenges[id] = nil
	fire(c.to, "ChallengeClosed", { id = id })
	if note then
		Net.notify(c.from, "STREET RACE", note)
	end
end

local function challenge(from: Player, targetId: any, routeId: any): (boolean, string)
	if type(targetId) ~= "number" or type(routeId) ~= "string" then
		return false, "Invalid request."
	end
	local to = Players:GetPlayerByUserId(targetId)
	if not to or to == from then
		return false, "They're not here."
	end
	local route = RC.ROUTE_BY_ID[routeId]
	if not route or not routeOk[routeId] then
		return false, "That route is closed."
	end
	local busy = busyReason(from) or (if table.find(lobby, from) then "Leave the race lobby first." else nil)
	if busy then
		return false, busy
	end
	if busyReason(to) or table.find(lobby, to) then
		return false, to.DisplayName .. " is busy right now."
	end
	local mine = Vehicles.drivingVehicle(from)
	local theirs = Vehicles.drivingVehicle(to)
	if not mine then
		return false, "Get in your vehicle first."
	end
	if not theirs then
		return false, to.DisplayName .. " isn't driving."
	end
	local pa, pb = (mine.PrimaryPart :: BasePart).Position, (theirs.PrimaryPart :: BasePart).Position
	if (pa - pb).Magnitude > RC.CHALLENGE_RANGE then
		return false, "Pull up next to them first."
	end
	local Social = sibling("Social")
	if Social and type(Social.allows) == "function" then
		local ok, allowed, reason = pcall(Social.allows, from, to, "invite")
		if not ok or not allowed then
			return false, (if ok then reason else nil) or "You can't challenge this player."
		end
	end
	if not Net.allow(from, "RaceChallenge", RC.CHALLENGE_COOLDOWN) then
		return false, "Give it a few seconds."
	end
	for id, c in challenges do
		if c.from == from or c.to == from then
			closeChallenge(id)
		end
	end
	raceCounter += 1
	local id = string.format("c%d-%d", os.time(), raceCounter)
	local expires = now() + RC.CHALLENGE_SECONDS
	challenges[id] = { id = id, from = from, to = to, routeId = routeId, expires = expires }
	fire(to, "Challenge", { id = id, from = from.DisplayName, fromId = from.UserId, route = route.name, routeId = routeId, length = route.length, expires = expires })
	return true, "Challenge sent to " .. to.DisplayName .. "."
end

local function respond(player: Player, id: any, accept: any): (boolean, string)
	if type(id) ~= "string" then
		return false, "Invalid request."
	end
	local c = challenges[id]
	if not c or c.to ~= player then
		return false, "That challenge isn't open anymore."
	end
	challenges[id] = nil
	local from = c.from
	if accept ~= true then
		if from.Parent then
			Net.notify(from, "STREET RACE", player.DisplayName .. " passed on your challenge.")
		end
		return true, "Declined."
	end
	if now() > c.expires then
		return false, "That challenge expired."
	end
	if not from.Parent then
		return false, "They left."
	end
	local busy = busyReason(player) or busyReason(from)
	if busy or table.find(lobby, player) or table.find(lobby, from) then
		return false, "One of you is busy right now."
	end
	local ma, mb = Vehicles.drivingVehicle(from), Vehicles.drivingVehicle(player)
	if not ma or not mb then
		return false, "Both drivers need to be in their vehicles."
	end
	if ((ma.PrimaryPart :: BasePart).Position - (mb.PrimaryPart :: BasePart).Position).Magnitude > RC.CHALLENGE_RANGE * 2 then
		return false, "You drove too far apart."
	end
	local ok, message = startStreet(from, player, c.routeId)
	if not ok then
		Net.notify(from, "STREET RACE", message)
	end
	return ok, message
end

---------------------------------------------------------------------------
-- Info for the panel / phone app
---------------------------------------------------------------------------
local function infoFor(player: Player): { [string]: any }
	local sec = section(player)
	local stats = {}
	local recent = {}
	if sec then
		for _, k in { "bestRace", "bestLap", "bestTrial", "medal", "races", "wins", "podiums", "trials", "streetRaces", "streetWins" } do
			stats[k] = sec[k]
		end
		recent = table.clone(sec.recent)
	end
	local routes = {}
	for _, route in RC.ROUTES do
		local pts = routePoints[route.id]
		table.insert(routes, {
			id = route.id,
			ok = routeOk[route.id] == true,
			best = if sec and type(sec.routes[route.id]) == "number" then sec.routes[route.id] else 0,
			start = if pts and pts[1] then pts[1] else route.points[1],
		})
	end
	local info = lobbyInfo()
	info.inLobby = table.find(lobby, player) ~= nil
	return {
		track = if track then { pos = track.startPos, name = RC.TRACK_NAME } else nil,
		lobby = info,
		racing = if racerOf[player] then racerOf[player].kind else nil,
		stats = stats,
		recent = recent,
		routes = routes,
		loaded = sec ~= nil,
	}
end

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
RacingAction.OnServerInvoke = function(player: Player, action: any, a: any, b: any)
	if type(action) ~= "string" then
		return false, "Invalid request."
	end
	if action == "info" then
		if not Net.allow(player, "RacingInfo", 0.5) then
			return false, "Slow down."
		end
		return true, "", infoFor(player)
	end
	if not Net.allow(player, "RacingAction", 0.4) then
		return false, "Slow down."
	end
	if not PlayerData.isLoaded(player) then
		return false, "Your save is still loading."
	end
	if action == "join" then
		local ok, message = join(player)
		return ok, message
	elseif action == "leave" then
		if not table.find(lobby, player) then
			return false, "You're not in the lobby."
		end
		removeFromLobby(player)
		return true, "You left the lobby."
	elseif action == "trial" then
		local ok, message = trial(player)
		return ok, message
	elseif action == "quit" then
		local race = racerOf[player]
		if not race then
			return false, "You're not racing."
		end
		for _, r in race.list do
			if r.player == player then
				if race.kind == "trial" then
					endRace(race, "Abandoned")
				else
					dnf(race, r, "You quit the race.")
				end
			end
		end
		return true, "You quit."
	elseif action == "challenge" then
		local ok, message = challenge(player, a, b)
		return ok, message
	elseif action == "respond" then
		local ok, message = respond(player, a, b)
		return ok, message
	end
	return false, "Unknown action."
end

---------------------------------------------------------------------------
-- RACE HQ kiosk by the start line
---------------------------------------------------------------------------
local function buildKiosk()
	local t = track
	if not t then
		return
	end
	local model = Instance.new("Model")
	model.Name = "RaceHQ"
	model.Parent = root
	local spot = t.startPos - t.forward * 22 - t.right * (t.width / 2 + 7)
	local base = groundCF(spot, t.right)
	local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	part("Pad", Vector3.new(10, 0.3, 8), base * CFrame.new(0, 0.15, 0), Color3.fromRGB(40, 40, 46), Enum.Material.Concrete)
	local booth = part("Booth", Vector3.new(4, 5, 3), base * CFrame.new(0, 2.8, 0), Color3.fromRGB(30, 30, 36), Enum.Material.Metal)
	part("Stripe", Vector3.new(4.1, 0.4, 3.1), base * CFrame.new(0, 4.6, 0), Color3.fromRGB(255, 60, 60), Enum.Material.Neon)
	for _, x in { -3.5, 3.5 } do
		part("Pole", Vector3.new(0.5, 12, 0.5), base * CFrame.new(x, 6, 0), Color3.fromRGB(70, 72, 78), Enum.Material.Metal)
	end
	local sign = part("Sign", Vector3.new(9, 3, 0.4), base * CFrame.new(0, 11, 0), Color3.fromRGB(20, 20, 24))
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0
		gui.Parent = sign
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0.62)
		label.Text = "RACE HQ"
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 220, 60)
		label.Parent = gui
		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.fromScale(0, 0.6)
		sub.Size = UDim2.fromScale(1, 0.36)
		sub.Text = "Races · Time trials"
		sub.Font = Enum.Font.GothamBold
		sub.TextScaled = true
		sub.TextColor3 = Color3.fromRGB(230, 230, 235)
		sub.Parent = gui
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RacePrompt"
	prompt.ActionText = "Race"
	prompt.ObjectText = RC.TRACK_NAME
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 42
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.Parent = booth
	prompt.Triggered:Connect(function(player: Player)
		if not Net.allow(player, "RacingPanel", 0.5) then
			return
		end
		if Net.distance(player, booth.Position) > 60 then
			return
		end
		watchers[player] = os.clock() + 120
		fire(player, "Panel", infoFor(player))
	end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Racing.bestTime(player: Player): number?
	local sec = section(player)
	if sec and type(sec.bestRace) == "number" and sec.bestRace > 0 then
		return sec.bestRace
	end
	return nil
end

function Racing.raceOf(player: Player): string?
	local race = racerOf[player]
	if race then
		return race.kind
	end
	if table.find(lobby, player) then
		return "lobby"
	end
	return nil
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Racing.start(city: Instance)
	local old = city:FindFirstChild("Racing")
	if old then
		old:Destroy()
	end
	root = Instance.new("Folder")
	root.Name = "Racing"
	root.Parent = city
	liveFolder = Instance.new("Folder")
	liveFolder.Name = "Live"
	liveFolder.Parent = root

	loadTrack(city)
	validateRoutes()
	buildKiosk()

	PlayerData.onPublish(function(player: Player, data: any)
		local sec = data.sections and data.sections.racing
		if sec then
			if player:GetAttribute("RaceBest") ~= sec.bestRace then
				player:SetAttribute("RaceBest", sec.bestRace)
			end
			if player:GetAttribute("RaceWins") ~= sec.wins then
				player:SetAttribute("RaceWins", sec.wins)
			end
		end
	end)
	PlayerData.onLoaded(function(player: Player)
		local sec = section(player)
		if sec and sec.bestRace > 0 then
			submitBoard(player, sec.bestRace)
		end
	end)

	local function onPlayer(player: Player)
		player:SetAttribute("Race", "")
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local i = table.find(lobby, player)
		if i then
			table.remove(lobby, i)
			if #lobby < RC.MIN_RACERS then
				lobbyStartAt = nil
			end
			broadcastLobby()
		end
		for id, c in challenges do
			if c.from == player or c.to == player then
				closeChallenge(id, if c.to == player then c.to.DisplayName .. " left." else nil)
			end
		end
		watchers[player] = nil
		rewardLog[player] = nil
		-- racerOf is cleared when the race notices (next tick)
	end)

	task.spawn(function()
		local lobbyClock = 0
		while true do
			task.wait(RC.TICK)
			local t = now()
			for _, race in races do
				local ok, err = pcall(stepRace, race, t)
				if not ok then
					warn("[Racing] race step failed:", err)
					pcall(endRace, race, "Race cancelled")
				end
			end
			for id, c in challenges do
				if t > c.expires then
					closeChallenge(id, c.to.DisplayName .. " didn't answer your challenge.")
				end
			end
			lobbyClock += RC.TICK
			if lobbyClock >= 0.5 then
				lobbyClock = 0
				local ok, err = pcall(lobbyTick)
				if not ok then
					warn("[Racing] lobby tick failed:", err)
				end
			end
		end
	end)
end

return Racing
