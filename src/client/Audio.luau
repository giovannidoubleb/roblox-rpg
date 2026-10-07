-- CITY GRIND: game audio (Phase 8). Client only; every sound is local.
-- All sounds are built-in client files (see shared/AudioConfig) played through
-- three SoundGroups in SoundService — "Music", "SFX", "Ambient" — whose volumes
-- follow the Phone Settings attributes VolMusic / VolSFX / VolAmbient live.
-- (The Music app scales its own group by VolMusic itself.)
--
--   * Roblox's default character sounds (RbxCharacterSounds) are routed into
--     SFX. Material-aware footsteps are only added if those defaults are
--     missing, so steps never double.
--   * Basketballs (Workspace.Basketballs): dribble thumps, floor/board bounces,
--     rim clangs, swish + net when the ball drops through a rim — all derived
--     from the replicated ball physics, so everyone nearby hears them.
--   * Crowd: on courts with a game running (or after a dunk) score changes,
--     dunks and big callouts get a synthesized cheer + claps; rim-outs get an
--     "ooh".
--   * Vehicles: one looping engine per occupied car nearby (max 6), pitch by
--     speed. Bicycles are silent.
--   * Subway ride rumble, phone open/close swoosh and button clicks, a sparse
--     ambient bed per district, rain loop and thunder (synced to the World
--     module's lightning flash) from Workspace attribute Weather.
--
-- API: Audio.play(role, position?, volumeMul?, pitchMul?) -> boolean
--      Audio.group(name) -> SoundGroup?

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("CityGrind")
local AC = require(shared:WaitForChild("AudioConfig"))
local DC = require(shared:WaitForChild("DistrictsConfig"))
local VC = require(shared:WaitForChild("VehiclesConfig"))

local player = Players.LocalPlayer
local rng = Random.new()

local Audio = {}

type Sample = AC.Sample
type Voice = { sound: Sound, att: Attachment? }

local groups: { [string]: SoundGroup } = {}
local chosen: { [string]: Sample } = {} -- role -> sample that loaded
local ready = false

---------------------------------------------------------------------------
-- Sound groups + settings
---------------------------------------------------------------------------
local function settingVolume(attr: string, default: number): number
	local v = player:GetAttribute(attr)
	return if type(v) == "number" and v == v then math.clamp(v, 0, 1) else default
end

local function inCall(): boolean
	local v = player:GetAttribute("InCall")
	return type(v) == "number" and v ~= 0
end

local function applyVolumes()
	local duck = if inCall() then 0.4 else 1
	if groups.Music then
		groups.Music.Volume = settingVolume("VolMusic", AC.DEFAULT_VOLUME.Music)
	end
	if groups.SFX then
		groups.SFX.Volume = settingVolume("VolSFX", AC.DEFAULT_VOLUME.SFX)
	end
	if groups.Ambient then
		groups.Ambient.Volume = settingVolume("VolAmbient", AC.DEFAULT_VOLUME.Ambient) * duck
	end
end

local function makeGroups()
	for _, name in { "Music", "SFX", "Ambient" } do
		local existing = SoundService:FindFirstChild(name)
		if existing and existing:IsA("SoundGroup") then
			groups[name] = existing
		else
			local g = Instance.new("SoundGroup")
			g.Name = name
			g.Parent = SoundService
			groups[name] = g
		end
	end
	applyVolumes()
	for _, attr in { "VolMusic", "VolSFX", "VolAmbient", "InCall" } do
		player:GetAttributeChangedSignal(attr):Connect(applyVolumes)
	end
end

function Audio.group(name: string): SoundGroup?
	return groups[name]
end

---------------------------------------------------------------------------
-- Probe: which built-in files load on this client
---------------------------------------------------------------------------
local function probeAll()
	local probes: { [string]: Sound } = {}
	local list = {}
	for _, role in AC.ROLES do
		for _, sample in role.list do
			if not probes[sample.id] then
				local s = Instance.new("Sound")
				s.Name = "AudioProbe"
				s.SoundId = sample.id
				s.Volume = 0
				s.Parent = SoundService
				probes[sample.id] = s
				table.insert(list, s)
			end
		end
	end
	pcall(function()
		ContentProvider:PreloadAsync(list)
	end)
	local deadline = os.clock() + 5
	while os.clock() < deadline do
		local pending = false
		for _, s in list do
			if not s.IsLoaded then
				pending = true
				break
			end
		end
		if not pending then
			break
		end
		task.wait(0.2)
	end
	for roleName, role in AC.ROLES do
		for _, sample in role.list do
			local s = probes[sample.id]
			if s and s.IsLoaded and s.TimeLength > 0 then
				chosen[roleName] = sample
				break
			end
		end
	end
	for _, s in list do
		s:Destroy()
	end
	ready = true
end

local function groupOf(role: string): SoundGroup?
	local r = AC.ROLES[role]
	return r and groups[r.group]
end

---------------------------------------------------------------------------
-- Voice pools: 3D one-shots (attachments under Terrain) and 2D one-shots
---------------------------------------------------------------------------
local pool3D: { Voice } = {}
local pool2D: { Voice } = {}
local next3D, next2D = 1, 1

local function buildPools()
	local terrain = Workspace.Terrain
	for i = 1, AC.ONESHOT_POOL do
		local att = Instance.new("Attachment")
		att.Name = "CityAudio" .. i
		att.Parent = terrain
		local s = Instance.new("Sound")
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = 10
		s.RollOffMaxDistance = 160
		s.Parent = att
		pool3D[i] = { sound = s, att = att }
	end
	for i = 1, 8 do
		local s = Instance.new("Sound")
		s.Name = "CityAudio2D" .. i
		s.Parent = SoundService
		pool2D[i] = { sound = s }
	end
end

-- Plays a one-shot of `role`. With a position it is 3D, otherwise 2D.
function Audio.play(role: string, position: Vector3?, volumeMul: number?, pitchMul: number?): boolean
	local sample = chosen[role]
	if not sample or #pool3D == 0 then
		return false
	end
	local voice
	if position then
		voice = pool3D[next3D]
		next3D = next3D % #pool3D + 1
		local att = voice.att :: Attachment
		att.Position = position -- Terrain sits at the origin
	else
		voice = pool2D[next2D]
		next2D = next2D % #pool2D + 1
	end
	local s = voice.sound
	s:Stop()
	s.SoundId = sample.id
	s.SoundGroup = groupOf(role)
	s.PlaybackSpeed = sample.speed * (pitchMul or 1)
	s.Volume = math.clamp(sample.volume * (volumeMul or 1), 0, 3)
	s.TimePosition = 0
	s:Play()
	return true
end

-- A looping Sound for `role` parented to `parent` (stopped, volume 0), or nil.
local function makeLoop(role: string, parent: Instance, name: string): Sound?
	local sample = chosen[role]
	if not sample then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = sample.id
	s.Looped = true
	s.Volume = 0
	s.PlaybackSpeed = sample.speed
	s.SoundGroup = groupOf(role)
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 12
	s.RollOffMaxDistance = 150
	s.Parent = parent
	return s
end

local function camPos(): Vector3
	local cam = Workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function myRoot(): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * math.min(1, dt * rate)
end

---------------------------------------------------------------------------
-- Character sounds: route Roblox defaults into SFX; fallback footsteps
---------------------------------------------------------------------------
local DEFAULT_NAMES = {
	Running = true, Jumping = true, Landing = true, FreeFalling = true, GettingUp = true,
	Climbing = true, Swimming = true, Splash = true, Died = true,
}
local customSteps = false
local stepAcc = 0

local function routeCharacterSounds(character: Model)
	task.spawn(function()
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root then
			return
		end
		local function route(d: Instance)
			if d:IsA("Sound") and DEFAULT_NAMES[d.Name] then
				d.SoundGroup = groups.SFX
			end
		end
		for _, d in root:GetChildren() do
			route(d)
		end
		root.ChildAdded:Connect(route)
	end)
end

local function checkDefaultFootsteps(character: Model)
	customSteps = false
	task.delay(4, function()
		if player.Character ~= character then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		local running = root and root:FindFirstChild("Running")
		-- Roblox's RbxCharacterSounds makes a "Running" sound in the root.
		customSteps = not (running and running:IsA("Sound"))
	end)
end

local function stepFootsteps(dt: number)
	if not customSteps then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = myRoot()
	if not humanoid or not root or humanoid.SeatPart or humanoid.FloorMaterial == Enum.Material.Air then
		stepAcc = 0
		return
	end
	local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	if speed < 2 or humanoid.MoveDirection.Magnitude < 0.1 then
		stepAcc = 0.6
		return
	end
	stepAcc += dt * (1.2 + speed / 9)
	if stepAcc >= 1 then
		stepAcc -= 1
		local m = AC.MATERIAL_STEP[humanoid.FloorMaterial] or { speed = 1, volume = 0.8 }
		Audio.play("footstep", root.Position - Vector3.new(0, 2.5, 0), m.volume * math.clamp(speed / 16, 0.5, 1.2), m.speed * rng:NextNumber(0.92, 1.08))
	end
end

---------------------------------------------------------------------------
-- Courts, hoops and the crowd
---------------------------------------------------------------------------
type Hoop = { rim: Vector3, radius: number, court: Model? }
type Court = { model: Model, center: Vector3, home: number, away: number }

local hoops: { Hoop } = {}
-- callout words worth a crowd reaction ("YOUR TURN!", "GO!" etc. are not)
local BIG_CALLOUTS = { "WIN", "CLUTCH", "POSTER", "PERFECT", "DOWNTOWN", "MONEY", "SERVES" }
local courts: { [Model]: Court } = {}
local lastCheer = 0

local function courtLive(model: Model?): boolean
	if not model then
		return false
	end
	local state = model:GetAttribute("State")
	return state == "Playing" or model:GetAttribute("Event") ~= nil
end

local crowdAtt: Attachment? = nil
local crowdVoices: { Sound } = {}
local crowdLevel, crowdTarget, crowdHoldUntil = 0, 0, 0

local function cheer(position: Vector3, intensity: number)
	local now = os.clock()
	if now - lastCheer < 1.2 or (position - camPos()).Magnitude > AC.CROWD_RANGE then
		return
	end
	lastCheer = now
	if crowdAtt then
		crowdAtt.Position = position
		for i, s in crowdVoices do
			s.PlaybackSpeed = (chosen.crowdRoar :: Sample).speed * (0.85 + i * 0.12) * rng:NextNumber(0.95, 1.05)
			if not s.IsPlaying then
				s.TimePosition = rng:NextNumber(0, math.max(0, s.TimeLength - 3))
				s:Play()
			end
		end
		crowdTarget = math.clamp(intensity, 0.3, 1.4)
		crowdHoldUntil = now + 0.5 + intensity * 0.9
	end
	-- claps: scattered short snaps around the court
	local claps = math.floor(6 + intensity * 10)
	for _ = 1, claps do
		task.delay(0.1 + rng:NextNumber(0, 1.4 + intensity), function()
			local offset = Vector3.new(rng:NextNumber(-22, 22), 2, rng:NextNumber(-30, 30))
			Audio.play("net", position + offset, 0.6, rng:NextNumber(0.55, 0.95))
		end)
	end
end

local function ooh(position: Vector3)
	local now = os.clock()
	if now - lastCheer < 1.2 or (position - camPos()).Magnitude > AC.CROWD_RANGE then
		return
	end
	lastCheer = now
	for i, pitch in { 0.72, 0.82, 0.95 } do
		task.delay((i - 1) * 0.06, function()
			Audio.play("crowdOoh", position + Vector3.new(rng:NextNumber(-12, 12), 3, rng:NextNumber(-12, 12)), 0.9, pitch)
		end)
	end
end

local function stepCrowd(dt: number)
	if #crowdVoices == 0 then
		return
	end
	if os.clock() > crowdHoldUntil then
		crowdTarget = 0
	end
	crowdLevel = approach(crowdLevel, crowdTarget, if crowdTarget > crowdLevel then 6 else 1.2, dt)
	local base = (chosen.crowdRoar :: Sample).volume
	for _, s in crowdVoices do
		s.Volume = base * crowdLevel
		if crowdLevel < 0.01 and crowdTarget == 0 and s.IsPlaying then
			s:Stop()
		end
	end
end

local function addCourt(model: Instance)
	if not model:IsA("Model") or courts[model] then
		return
	end
	local center = model:GetAttribute("CourtCenter")
	local court: Court = {
		model = model,
		center = if typeof(center) == "Vector3" then center else model:GetPivot().Position,
		home = tonumber(model:GetAttribute("HomeScore")) or 0,
		away = tonumber(model:GetAttribute("AwayScore")) or 0,
	}
	courts[model] = court
	local found = 0
	local function scanHoops()
		for _, side in { "North", "South" } do
			local hoopModel = model:FindFirstChild("Hoop" .. side)
			local marker = hoopModel and hoopModel:FindFirstChild("RimCenter", true)
			if marker and marker:IsA("Attachment") then
				found += 1
				table.insert(hoops, { rim = marker.WorldPosition, radius = tonumber((hoopModel :: Instance):GetAttribute("RimRadius")) or 1.45, court = model })
			end
		end
	end
	scanHoops()
	if found == 0 then
		task.delay(3, scanHoops) -- parts still replicating
	end
	local function onScore()
		local home = tonumber(model:GetAttribute("HomeScore")) or 0
		local away = tonumber(model:GetAttribute("AwayScore")) or 0
		local delta = math.max(home - court.home, away - court.away)
		court.home, court.away = home, away
		if delta > 0 and courtLive(model) then
			cheer(court.center, if delta >= 3 then 1.2 else 0.7)
		end
	end
	model:GetAttributeChangedSignal("HomeScore"):Connect(onScore)
	model:GetAttributeChangedSignal("AwayScore"):Connect(onScore)
end

---------------------------------------------------------------------------
-- Basketballs
---------------------------------------------------------------------------
type BallState = { lastVel: Vector3, lastPos: Vector3, lastRel: number, relDir: number, lastHit: number, rimAt: number, rimHoop: Hoop?, scoredAt: number }
local ballState: { [BasePart]: BallState } = {}
local ballFolder: Instance? = nil

local function nearestHoop(pos: Vector3): (Hoop?, number)
	local best, bestD = nil, math.huge
	for _, h in hoops do
		local d = (h.rim - pos).Magnitude
		if d < bestD then
			best, bestD = h, d
		end
	end
	return best, bestD
end

local function anyoneDunking(hoop: Hoop): boolean
	for _, p in Players:GetPlayers() do
		local c = p.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		if r and r:IsA("BasePart") then
			local off = r.Position - hoop.rim
			if Vector3.new(off.X, 0, off.Z).Magnitude < 4 and off.Y > -5.5 then
				return true
			end
		end
	end
	return false
end

local function stepBall(part: BasePart, st: BallState, now: number)
	local pos = part.Position
	local weld = part:FindFirstChild("Weld")
	if weld and weld:IsA("Weld") and weld.Part0 then
		-- held: the server bobs the weld C0; a turn at the bottom is a dribble
		local rel = weld.C0.Y
		if rel > st.lastRel + 0.03 then
			if st.relDir < 0 and rel < -1.2 then
				Audio.play("bounce", pos - Vector3.new(0, 0.7, 0), 0.55, rng:NextNumber(0.95, 1.05))
			end
			st.relDir = 1
		elseif rel < st.lastRel - 0.03 then
			st.relDir = -1
		end
		st.lastRel = rel
		st.lastPos = pos
		st.lastVel = Vector3.zero
		return
	end
	st.relDir = 0
	local vel = part.AssemblyLinearVelocity
	local hoop, hoopDist = nearestHoop(pos)

	-- impacts: a sudden change of velocity
	local change = (vel - st.lastVel).Magnitude
	if change > 7 and now - st.lastHit > 0.08 and st.lastVel.Magnitude > 4 then
		st.lastHit = now
		local strength = math.clamp(change / 30, 0.25, 1.2)
		local onRim = false
		if hoop and hoopDist < 4 then
			local off = pos - hoop.rim
			local h = Vector3.new(off.X, 0, off.Z).Magnitude
			local ringDist = math.sqrt((h - hoop.radius) ^ 2 + off.Y ^ 2)
			onRim = ringDist < 1.25
		end
		if onRim and hoop then
			Audio.play("rim", pos, strength, rng:NextNumber(0.92, 1.1))
			Audio.play("rimRing", pos, strength, rng:NextNumber(0.95, 1.05))
			st.rimAt = now
			st.rimHoop = hoop
		else
			Audio.play("bounce", pos, strength, rng:NextNumber(0.9, 1.1))
		end
	end

	-- through the rim, top to bottom
	if hoop and hoopDist < 4 and now - st.scoredAt > 1 then
		local rimY = hoop.rim.Y
		if st.lastPos.Y >= rimY and pos.Y < rimY then
			local mid = (st.lastPos + pos) / 2
			local off = mid - hoop.rim
			if Vector3.new(off.X, 0, off.Z).Magnitude < hoop.radius - 0.35 then
				st.scoredAt = now
				st.rimHoop = nil
				if now - st.rimAt > 0.8 then
					Audio.play("swish", hoop.rim, 1, rng:NextNumber(0.95, 1.05))
				end
				Audio.play("net", hoop.rim - Vector3.new(0, 0.8, 0), 1, rng:NextNumber(0.95, 1.1))
				if anyoneDunking(hoop) then
					cheer(if hoop.court and courts[hoop.court] then courts[hoop.court].center else hoop.rim, 1.3)
				end
			end
		end
	end

	-- rim-out: it hit the rim, then fell well below without going in
	local rimHoop = st.rimHoop
	if rimHoop and pos.Y < rimHoop.rim.Y - 3 then
		st.rimHoop = nil
		if now - st.scoredAt > 1.5 and now - st.rimAt < 2.5 and courtLive(rimHoop.court) then
			local c = rimHoop.court and courts[rimHoop.court]
			ooh(if c then c.center else rimHoop.rim)
		end
	end

	st.lastVel = vel
	st.lastPos = pos
end

local function stepBalls()
	local folder = ballFolder
	if not folder then
		return
	end
	local now = os.clock()
	local cam = camPos()
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			local st = ballState[child]
			if not st then
				st = { lastVel = Vector3.zero, lastPos = child.Position, lastRel = 0, relDir = 0, lastHit = 0, rimAt = -10, scoredAt = -10 }
				ballState[child] = st
				child.Destroying:Connect(function()
					ballState[child] = nil
				end)
			end
			if (child.Position - cam).Magnitude <= AC.BALL_RANGE then
				stepBall(child, st, now)
			else
				st.lastPos = child.Position
				st.lastVel = child.AssemblyLinearVelocity
			end
		end
	end
end

---------------------------------------------------------------------------
-- Vehicles: engine loops on the nearest occupied cars
---------------------------------------------------------------------------
type Engine = { model: Model, seat: VehicleSeat, sound: Sound, top: number, electric: boolean }
local engines: { [Model]: Engine } = {}
local engineScan = 0

local function scanEngines()
	if not chosen.engine then
		return
	end
	local cam = camPos()
	local candidates = {}
	for _, model in CollectionService:GetTagged("CityVehicle") do
		if model:IsA("Model") then
			local seat = model:FindFirstChild("DriverSeat")
			if seat and seat:IsA("VehicleSeat") and seat.Occupant then
				local spec = VC.byId[model:GetAttribute("VehicleId") or ""]
				if not (spec and spec.style == "bicycle") then
					local d = (seat.Position - cam).Magnitude
					if d <= AC.ENGINE_RANGE then
						table.insert(candidates, { model = model, seat = seat, d = d, spec = spec })
					end
				end
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.d < b.d
	end)
	local keep: { [Model]: boolean } = {}
	for i = 1, math.min(#candidates, AC.MAX_ENGINES) do
		local c = candidates[i]
		keep[c.model] = true
		if not engines[c.model] then
			local sound = makeLoop("engine", c.seat, "CityEngine")
			if sound then
				sound.Volume = 0
				sound:Play()
				engines[c.model] = {
					model = c.model,
					seat = c.seat,
					sound = sound,
					top = if c.spec then c.spec.topSpeed else 60,
					electric = c.spec ~= nil and c.spec.style == "scooter",
				}
			end
		end
	end
	for model, e in engines do
		if not keep[model] or not e.sound.Parent then
			e.sound:Destroy()
			engines[model] = nil
		end
	end
end

local function stepEngines(dt: number)
	local sample = chosen.engine
	if not sample then
		return
	end
	local mySeat = nil
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		mySeat = humanoid.SeatPart
	end
	for _, e in engines do
		local speed = e.seat.AssemblyLinearVelocity.Magnitude
		local k = math.clamp(speed / math.max(10, e.top), 0, 1.2)
		local throttle = if mySeat == e.seat then math.abs(e.seat.ThrottleFloat) else 0
		local pitch = sample.speed * (0.75 + k * 1.15 + throttle * 0.12) * (if e.electric then 1.8 else 1)
		local vol = sample.volume * (0.55 + k * 0.6 + throttle * 0.15) * (if e.electric then 0.4 else 1) * (if mySeat == e.seat then 1 else 0.8)
		e.sound.PlaybackSpeed = approach(e.sound.PlaybackSpeed, pitch, 6, dt)
		e.sound.Volume = approach(e.sound.Volume, vol, 4, dt)
	end
end

---------------------------------------------------------------------------
-- Ambience: district bed, one-shots, rain, thunder, subway
---------------------------------------------------------------------------
local beds: { [string]: Sound } = {}
local bedTargets: { [string]: number } = {}
local district = "Neighborhood"
local nextOneShot = 0
local rainLoop: Sound? = nil
local rainLevel = 0
local rumbleLoop: Sound? = nil
local riding = false
local nextClack = 0
local weatherGrade: ColorCorrectionEffect? = nil
local lastGrade = 0
local thunderFallbackAt = 0

local function indoors(): boolean
	local v = player:GetAttribute("Interior")
	return type(v) == "string" and v ~= ""
end

local function updateDistrict()
	local root = myRoot()
	district = DC.at(if root then root.Position else camPos())
	local spec = AC.DISTRICTS[district] or AC.DISTRICTS.Outskirts
	for role in bedTargets do
		bedTargets[role] = 0
	end
	if not beds[spec.bed] then
		local s = makeLoop(spec.bed, SoundService, "CityAmbience_" .. spec.bed)
		if s then
			s:Play()
			beds[spec.bed] = s
		end
	end
	if beds[spec.bed] then
		bedTargets[spec.bed] = spec.gain * (if indoors() then 0.15 else 1)
	end
end

local function thunder(distanceK: number)
	-- crack + long low body; distant strikes are softer and duller
	Audio.play("thunder", nil, 0.6 + 0.4 * (1 - distanceK), 1 - distanceK * 0.25)
	task.delay(0.15, function()
		Audio.play("thunderBody", nil, 0.9 - distanceK * 0.3, rng:NextNumber(0.85, 1.05))
	end)
end

local function stepAmbience(dt: number)
	local now = os.clock()
	local inside = indoors()
	-- beds crossfade
	for role, s in beds do
		local sample = chosen[role]
		local target = (bedTargets[role] or 0) * (if sample then sample.volume else 0)
		s.Volume = approach(s.Volume, target, 0.8, dt)
	end
	-- one-shots near the player
	if now >= nextOneShot then
		local spec = AC.DISTRICTS[district]
		local shots = spec and spec.oneShots or {}
		if #shots > 0 then
			local shot = shots[rng:NextInteger(1, #shots)]
			nextOneShot = now + rng:NextNumber(shot.min, shot.max)
			local root = myRoot()
			if root and not inside then
				local a = rng:NextNumber(0, math.pi * 2)
				local r = rng:NextNumber(35, 80)
				Audio.play(shot.role, root.Position + Vector3.new(math.cos(a) * r, 4, math.sin(a) * r), 1, rng:NextNumber(0.85, 1.15))
			end
		else
			nextOneShot = now + 20
		end
	end
	-- rain
	local weather = Workspace:GetAttribute("Weather")
	if rainLoop then
		local target = if weather == "Storm" then 1 elseif weather == "Rain" then 0.65 else 0
		if inside then
			target *= 0.25
		end
		rainLevel = approach(rainLevel, target, 0.6, dt)
		local sample = chosen.rain :: Sample
		rainLoop.Volume = sample.volume * rainLevel
		if rainLevel > 0.01 and not rainLoop.IsPlaying then
			rainLoop:Play()
		elseif rainLevel <= 0.01 and rainLoop.IsPlaying then
			rainLoop:Stop()
		end
	end
	-- thunder: follow the World module's lightning flash (Lighting.CityGrindWeather)
	if weather == "Storm" then
		local grade = weatherGrade
		if not grade or not grade.Parent then
			local g = Lighting:FindFirstChild("CityGrindWeather")
			grade = if g and g:IsA("ColorCorrectionEffect") then g else nil
			weatherGrade = grade
		end
		if grade then
			local b = grade.Brightness
			if b - lastGrade > 0.12 then
				local k = rng:NextNumber(0, 1)
				task.delay(0.3 + k * 2.2, thunder, k)
			end
			lastGrade = b
		elseif now >= thunderFallbackAt then
			thunderFallbackAt = now + rng:NextNumber(9, 22)
			thunder(rng:NextNumber(0.2, 1))
		end
	end
	-- subway ride
	if rumbleLoop then
		local target = if riding then (chosen.rumble :: Sample).volume else 0
		rumbleLoop.Volume = approach(rumbleLoop.Volume, target, 3, dt)
		if riding and not rumbleLoop.IsPlaying then
			rumbleLoop:Play()
		elseif not riding and rumbleLoop.Volume < 0.01 and rumbleLoop.IsPlaying then
			rumbleLoop:Stop()
		end
		if riding and now >= nextClack then
			nextClack = now + rng:NextNumber(0.45, 0.6)
			Audio.play("thump", nil, 0.5, rng:NextNumber(0.9, 1.15))
			task.delay(0.12, Audio.play, "thump", nil, 0.4, rng:NextNumber(0.9, 1.15))
		end
	end
end

local function watchSubway()
	local playerGui = player:WaitForChild("PlayerGui")
	local function hook(gui: Instance)
		if gui.Name ~= "CityGrindSubway" then
			return
		end
		local ride = gui:WaitForChild("Ride", 10)
		if ride and ride:IsA("GuiObject") then
			riding = ride.Visible
			ride:GetPropertyChangedSignal("Visible"):Connect(function()
				riding = ride.Visible
			end)
		end
	end
	for _, g in playerGui:GetChildren() do
		task.spawn(hook, g)
	end
	playerGui.ChildAdded:Connect(hook)
end

---------------------------------------------------------------------------
-- Phone UI sounds
---------------------------------------------------------------------------
local lastClick = 0
local function click()
	local now = os.clock()
	if now - lastClick > 0.05 then
		lastClick = now
		Audio.play("click", nil, 1, rng:NextNumber(0.97, 1.03))
	end
end

local function watchPhone()
	local playerGui = player:WaitForChild("PlayerGui")
	local function hook(gui: Instance)
		if gui.Name ~= "CityGrindPhone" then
			return
		end
		local function onDesc(d: Instance)
			if d:IsA("GuiButton") then
				d.Activated:Connect(click)
			end
		end
		for _, d in gui:GetDescendants() do
			onDesc(d)
		end
		gui.DescendantAdded:Connect(onDesc)
	end
	for _, g in playerGui:GetChildren() do
		hook(g)
	end
	playerGui.ChildAdded:Connect(hook)
	player:GetAttributeChangedSignal("PhoneOut"):Connect(function()
		local out = player:GetAttribute("PhoneOut") == true
		Audio.play("phoneSwoosh", nil, 1, if out then 1.1 else 0.85)
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Audio.start()
	makeGroups()
	buildPools()

	for _, p in Players:GetPlayers() do
		if p.Character then
			routeCharacterSounds(p.Character)
		end
		p.CharacterAdded:Connect(routeCharacterSounds)
	end
	Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(routeCharacterSounds)
	end)
	if player.Character then
		checkDefaultFootsteps(player.Character)
	end
	player.CharacterAdded:Connect(checkDefaultFootsteps)

	task.spawn(function()
		probeAll()
		-- crowd voices (looped roar, swelled on a cheer)
		if chosen.crowdRoar then
			local att = Instance.new("Attachment")
			att.Name = "CityCrowd"
			att.Parent = Workspace.Terrain
			crowdAtt = att
			for i = 1, 3 do
				local s = makeLoop("crowdRoar", att, "Crowd" .. i)
				if s then
					s.RollOffMaxDistance = AC.CROWD_RANGE + 40
					s.RollOffMinDistance = 30
					table.insert(crowdVoices, s)
				end
			end
		end
		rainLoop = makeLoop("rain", SoundService, "CityRain")
		rumbleLoop = makeLoop("rumble", SoundService, "CitySubwayRumble")
		updateDistrict()
		nextOneShot = os.clock() + 8
	end)

	task.spawn(function()
		ballFolder = Workspace:WaitForChild("Basketballs", 60)
	end)
	for _, model in CollectionService:GetTagged("Court") do
		addCourt(model)
	end
	CollectionService:GetInstanceAddedSignal("Court"):Connect(addCourt)

	-- big callouts ("GAME WINNER!", etc.) reach the players in that game
	task.spawn(function()
		local remotes = shared:WaitForChild("Remotes")
		local fx = remotes:WaitForChild("BallFx", 30)
		if fx and fx:IsA("RemoteEvent") then
			fx.OnClientEvent:Connect(function(kind: any, arg: any)
				if kind ~= "Callout" or type(arg) ~= "string" then
					return
				end
				local big = nil
				for _, word in BIG_CALLOUTS do
					if arg:find(word, 1, true) then
						big = word
						break
					end
				end
				local root = myRoot()
				if big and root then
					lastCheer = 0 -- a callout outranks the score cheer that just played
					cheer(root.Position + Vector3.new(0, 4, 0), if big == "WIN" or big == "POSTER" then 1.4 else 1)
				end
			end)
		end
	end)

	task.spawn(watchSubway)
	task.spawn(watchPhone)

	local slow = 0
	RunService.Heartbeat:Connect(function(dt)
		if not ready then
			return
		end
		stepFootsteps(dt)
		stepBalls()
		stepCrowd(dt)
		stepEngines(dt)
		stepAmbience(dt)
		engineScan -= dt
		if engineScan <= 0 then
			engineScan = 0.5
			scanEngines()
		end
		slow -= dt
		if slow <= 0 then
			slow = 1.5
			updateDistrict()
		end
	end)
end

return Audio
