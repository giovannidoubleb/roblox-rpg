-- CITY GRIND: lightweight movement sanity (Phase 9 anti-exploit).
-- Every player's client owns its own character's physics, so the server cannot
-- trust where a character is. Four times a second this module checks each
-- character for:
--   * speed: a token bucket of allowed horizontal distance (sprint/slide speed
--     plus slack, banked for a few seconds so lag bursts never trip it);
--   * fly: sustained hovering/rising far above the ground;
--   * noclip: the root sitting inside an anchored, collidable part.
-- Violations add to a score that decays over time; past a threshold the
-- character is rubber-banded to its last good position. Nobody is ever kicked.
-- Exempt: seated (cars, ferris wheel, benches), driving, Gym exercises,
-- PlatformStand / anchored (emotes, ragdoll), dead, story cinematic, and any
-- window opened by AntiCheat.allowTeleport (server teleports, dunk jumps).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))

local AntiCheat = {}

local TICK = 0.25
-- Fastest legit on-foot speed (a slide) with 20% slack; nothing in the game
-- raises WalkSpeed above Config.SLIDE_SPEED.
local FOOT_SPEED = math.max(Config.SLIDE_SPEED, Config.SPRINT_SPEED) * 1.2
local BUCKET_SECONDS = 4 -- how long a lag burst may bank distance
local BUCKET_SLACK = 24 -- studs (step-ups, seat dismount pops, small pushes)
local BUCKET_CAP = FOOT_SPEED * BUCKET_SECONDS + BUCKET_SLACK
local HOVER_HEIGHT = 11 -- studs from root to ground before "airborne" (a normal jump peaks ~9.5)
local HOVER_LIMIT = 1.5 -- seconds airborne without actually falling
local SCORE_DECAY = 0.6 -- per second
local SCORE_LIMIT = 4
local EXEMPT_RESET_GRACE = 2 -- seconds after leaving an exempt state (car momentum, seat pop)

type State = {
	character: Model?,
	lastPos: Vector3?,
	lastAt: number,
	lastGood: CFrame?,
	bucket: number,
	hover: number,
	inside: number,
	score: number,
	graceUntil: number,
	warned: { [string]: boolean },
}

local states: { [Player]: State } = {}

local function newState(): State
	return {
		character = nil,
		lastPos = nil,
		lastAt = 0,
		lastGood = nil,
		bucket = BUCKET_CAP,
		hover = 0,
		inside = 0,
		score = 0,
		graceUntil = os.clock() + 3,
		warned = {},
	}
end

local function stateOf(player: Player): State
	local s = states[player]
	if not s then
		s = newState()
		states[player] = s
	end
	return s
end

-- Lets the player's character move freely for `seconds` (server-side teleports,
-- scripted launches). Call it BEFORE moving the character.
function AntiCheat.allowTeleport(player: Player, seconds: number?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local s = stateOf(player)
	s.graceUntil = math.max(s.graceUntil, os.clock() + (seconds or 2))
	s.lastPos = nil
	s.bucket = BUCKET_CAP
	s.hover = 0
	s.inside = 0
end

-- For reward checks that read a character's position (claiming a cache, a
-- pickup): false while the player is flagged, or when the character has moved
-- further since the last sample than its speed budget allows (a teleport the
-- 4 Hz loop has not caught yet). True for players the checks do not cover.
function AntiCheat.positionOk(player: Player): boolean
	local s = states[player]
	if not s or not s.lastPos then
		return true
	end
	if s.score >= SCORE_LIMIT * 0.5 then
		return false
	end
	local now = os.clock()
	if now < s.graceUntil then
		return true
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return true
	end
	local pos, last = root.Position, s.lastPos :: Vector3
	local flat = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z).Magnitude
	return flat <= math.max(0, s.bucket) + FOOT_SPEED * (now - s.lastAt) + BUCKET_SLACK
end

local function warnOnce(player: Player, s: State, kind: string, detail: string)
	if not s.warned[kind] then
		s.warned[kind] = true
		warn(string.format("[Security] AntiCheat %s: %s (%s)", kind, player.Name, detail))
	end
end

local function attrSet(player: Player, name: string): boolean
	local v = player:GetAttribute(name)
	return v ~= nil and v ~= false and v ~= ""
end

-- True while something legit (and server-driven) moves or holds the character.
local function exempt(player: Player, humanoid: Humanoid, root: BasePart): boolean
	if humanoid.Health <= 0 or humanoid.SeatPart ~= nil or humanoid.Sit or humanoid.PlatformStand or root.Anchored then
		return true
	end
	if attrSet(player, "Driving") or attrSet(player, "Training") or attrSet(player, "StoryCinematic") then
		return true
	end
	local st = humanoid:GetState()
	if st == Enum.HumanoidStateType.Seated or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown
		or st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Dead then
		return true
	end
	-- welded ONTO something outside the character (a seat weld has the seat as
	-- Part0). Things the player carries (a held ball, a plate) weld the other way
	-- round and are massless, so holding a ball never exempts anyone.
	for _, j in root:GetJoints() do
		if j:IsA("JointInstance") or j:IsA("WeldConstraint") then
			local other = (j :: any).Part0
			if (j :: any).Part1 == root and other and other:IsA("BasePart") and not other.Massless
				and not other:IsDescendantOf(root.Parent :: Instance) then
				return true
			end
		end
	end
	return false
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 24
local ray = RaycastParams.new()
ray.FilterType = Enum.RaycastFilterType.Exclude
ray.RespectCanCollide = true
ray.IgnoreWater = false

local function characterList(): { Instance }
	local list = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

-- Something unanchored moving fast right next to the player (a car bumping
-- them, the roof of a moving car) can legitimately carry or fling them.
local function nearMovingAssembly(character: Model, pos: Vector3): boolean
	overlap.FilterDescendantsInstances = { character }
	for _, part in workspace:GetPartBoundsInRadius(pos, 14, overlap) do
		if not part.Anchored and part.AssemblyLinearVelocity.Magnitude > 15 then
			return true
		end
	end
	return false
end

-- The root's centre is inside an anchored part it should collide with.
local function insideSolid(chars: { Instance }, root: BasePart): boolean
	overlap.FilterDescendantsInstances = chars
	for _, part in workspace:GetPartBoundsInBox(root.CFrame, Vector3.new(0.4, 0.8, 0.4), overlap) do
		if part.Anchored and part.CanCollide and part.Transparency < 1.01 and root:CanCollideWith(part) then
			local size = part.Size
			if size.X >= 1 and size.Y >= 1 and size.Z >= 1 and (part:IsA("Part") and part.Shape == Enum.PartType.Block) then
				-- block parts only: their bounding box is their real shape
				local localPos = part.CFrame:PointToObjectSpace(root.Position)
				if math.abs(localPos.X) < size.X / 2 - 0.1 and math.abs(localPos.Y) < size.Y / 2 - 0.1 and math.abs(localPos.Z) < size.Z / 2 - 0.1 then
					return true
				end
			end
		end
	end
	return false
end

local function rubberBand(player: Player, s: State, character: Model, root: BasePart, why: string)
	warnOnce(player, s, why, string.format("score %.1f", s.score))
	s.score = 1
	s.bucket = BUCKET_CAP * 0.5
	s.hover = 0
	s.inside = 0
	local target = s.lastGood
	if target then
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(target)
		s.lastPos = target.Position
	else
		s.lastPos = root.Position
	end
end

local function check(player: Player, s: State, dt: number, now: number, chars: { Instance })
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") then
		s.lastPos = nil
		return
	end
	if s.character ~= character then
		-- new spawn: start clean
		s.character = character
		s.lastGood = nil
		s.lastPos = nil
		s.graceUntil = math.max(s.graceUntil, now + 3)
	end
	s.score = math.max(0, s.score - SCORE_DECAY * dt)
	local pos = root.Position
	s.lastAt = now

	if now < s.graceUntil or exempt(player, humanoid, root) then
		if now >= s.graceUntil then
			s.graceUntil = now + EXEMPT_RESET_GRACE
		end
		s.lastPos = pos
		s.bucket = BUCKET_CAP
		s.hover = 0
		s.inside = 0
		return
	end

	local last = s.lastPos
	s.lastPos = pos
	if not last then
		return
	end

	-- 1) horizontal speed (token bucket)
	s.bucket = math.min(BUCKET_CAP, s.bucket + FOOT_SPEED * dt)
	local flat = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z).Magnitude
	s.bucket -= flat
	local speedBad = false
	if s.bucket < 0 then
		if nearMovingAssembly(character, pos) then
			s.bucket = BUCKET_CAP * 0.5
			s.graceUntil = now + EXEMPT_RESET_GRACE
		else
			s.score += 2 + (-s.bucket) / 20
			s.bucket = 0
			speedBad = true
		end
	end

	-- 2) fly: airborne high above the ground and not falling
	-- a 3x3 block cast so standing on a ledge with the root past the edge still counts
	ray.FilterDescendantsInstances = chars
	local grounded = workspace:Blockcast(CFrame.new(pos), Vector3.new(3, 1, 3), Vector3.new(0, -HOVER_HEIGHT, 0), ray) ~= nil
	local flyBad = false
	if not grounded and pos.Y - last.Y > -2 then
		s.hover += dt
		if s.hover > HOVER_LIMIT then
			if nearMovingAssembly(character, pos) then
				s.hover = 0
			else
				s.score += 1.25
				flyBad = true
			end
		end
	else
		s.hover = 0
	end

	-- 3) noclip: centre of the root inside solid anchored geometry
	local noclipBad = false
	-- (skipped in the interiors high above the city, where players place furniture)
	if pos.Y < 400 and insideSolid(chars, root) then
		s.inside += 1
		if s.inside >= 3 then
			s.score += 1.5
			noclipBad = true
		end
	else
		s.inside = 0
	end

	if s.score >= SCORE_LIMIT then
		rubberBand(player, s, character, root, if speedBad then "speed" elseif flyBad then "fly" elseif noclipBad then "noclip" else "movement")
		return
	end

	-- remember a safe spot: standing on something, clean, budget healthy
	if grounded and not speedBad and not flyBad and not noclipBad and s.inside == 0 and s.bucket > BUCKET_CAP * 0.4 and s.score < 1 then
		s.lastGood = root.CFrame
	end
end

local started = false
function AntiCheat.start(_city: Instance?)
	if started then
		return
	end
	started = true
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	task.spawn(function()
		local lastTime = os.clock()
		while true do
			task.wait(TICK)
			local now = os.clock()
			local dt = math.min(now - lastTime, 1)
			lastTime = now
			local chars = characterList()
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(check, player, stateOf(player), dt, now, chars)
				if not ok then
					warn("[CityGrind] AntiCheat check failed:", err)
				end
			end
		end
	end)
end

return AntiCheat
