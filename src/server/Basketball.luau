-- CITY GRIND: server-owned basketballs (section 70).
-- Possession, dribbling, shooting, passing, stealing, blocking and scoring all
-- happen here. The client only says "I pressed shoot / released / pass / steal";
-- the server times the release itself and decides every outcome.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("CityGrind"):WaitForChild("Config"))
local B = Config.Ball

local Basketball = {}

export type Hoop = { model: Model, rim: Vector3, radius: number, court: Model?, side: string }
export type Shot = { shooter: Player, points: number, kind: string, perfect: boolean, at: number, contestedBy: Player? }
export type Ball = {
	part: BasePart,
	force: VectorForce,
	holder: Player?,
	weld: Weld?,
	lastHolder: Player?,
	court: Model?, -- the court a free-play ball belongs to
	gameCourt: Model?, -- set while the ball is the game ball of a court
	owner: Player?,
	shot: Shot?,
	shootingSince: number?,
	regrab: { [Player]: number },
	lastPos: Vector3,
	scoreDebounce: number,
	lastActive: number,
}

local balls: { [Ball]: boolean } = {}
local heldBy: { [Player]: Ball } = {}
local hoops: { Hoop } = {}
local stealCooldown: { [Player]: number } = {}
local trainCooldown: { [Player]: { [string]: number } } = {}
-- [Security] Hourly stat-XP budget per stat from court training (two alts passing back and
-- forth could otherwise farm ~5,000 Passing XP an hour with no level softening or fatigue).
-- Keyed by UserId so rejoining doesn't reset it.
local TRAIN_XP_PER_HOUR = 900
local trainBudget: { [number]: { [string]: { start: number, total: number } } } = {}
local rng = Random.new()

local ballFolder = Instance.new("Folder")
ballFolder.Name = "Basketballs"
ballFolder.Parent = workspace

---------------------------------------------------------------------------
-- Collision groups: the ball never collides with characters, so it can't be
-- body-blocked into glitches or used to fling people.
---------------------------------------------------------------------------
local BALL_GROUP, CHARACTER_GROUP = "CityBall", "CityCharacters"
pcall(function()
	PhysicsService:RegisterCollisionGroup(BALL_GROUP)
end)
pcall(function()
	PhysicsService:RegisterCollisionGroup(CHARACTER_GROUP)
end)
PhysicsService:CollisionGroupSetCollidable(BALL_GROUP, CHARACTER_GROUP, false)

function Basketball.tagCharacter(character: Model)
	local function tag(d: Instance)
		if d:IsA("BasePart") then
			d.CollisionGroup = CHARACTER_GROUP
		end
	end
	for _, d in character:GetDescendants() do
		tag(d)
	end
	character.DescendantAdded:Connect(tag)
end

---------------------------------------------------------------------------
-- Tiny signal so listeners get the real ball table (BindableEvents copy tables).
---------------------------------------------------------------------------
local function signal()
	local listeners = {}
	return {
		connect = function(fn)
			table.insert(listeners, fn)
		end,
		fire = function(...)
			for _, fn in listeners do
				task.spawn(fn, ...)
			end
		end,
	}
end

Basketball.scored = signal() -- (ball, hoop, shot?)
Basketball.blocked = signal() -- (ball, blocker, shooter)
Basketball.stolen = signal() -- (ball, stealer, victim)
Basketball.possession = signal() -- (ball, player?)

-- Set by Main: send big on-screen text ("GAME WINNER!") to these players.
Basketball.announce = function(_players: { Player }, _text: string) end
-- Set by Main: tell one client to jump at the rim for a dunk.
Basketball.dunkJump = function(_player: Player, _rim: Vector3) end
-- Set by Main: award training progress toward a stat.
Basketball.onTrain = function(_player: Player, _stat: string, _amount: number) end

-- Rules that depend on whether a game is being played. CourtGames replaces these.
Basketball.policy = {
	canHold = function(_player: Player, _ball: Ball): boolean
		return true
	end,
	targetHoop = function(_player: Player, _ball: Ball): Hoop?
		return nil
	end,
	opponents = function(_player: Player, _ball: Ball): { Player }
		return {}
	end,
	passTargets = function(player: Player, _ball: Ball): { Player }
		local list = {}
		for _, other in Players:GetPlayers() do
			if other ~= player then
				table.insert(list, other)
			end
		end
		return list
	end,
	canSteal = function(_player: Player, _victim: Player, _ball: Ball): boolean
		return true
	end,
}

function Basketball.registerHoop(hoop: Hoop)
	table.insert(hoops, hoop)
end

function Basketball.heldBall(player: Player): Ball?
	return heldBy[player]
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function canAct(player: Player): boolean
	local humanoid = humanoidOf(player)
	return humanoid ~= nil and humanoid.Health > 0 and humanoid.SeatPart == nil and rootOf(player) ~= nil
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function stat(player: Player, name: string): number
	return player:GetAttribute(name) or 1
end

-- Small training rewards, throttled so spamming shots doesn't farm stats.
local function train(player: Player, statName: string, amount: number)
	local now = os.clock()
	local cooldowns = trainCooldown[player]
	if not cooldowns then
		cooldowns = {}
		trainCooldown[player] = cooldowns
	end
	if cooldowns[statName] and now - cooldowns[statName] < 2 then
		return
	end
	cooldowns[statName] = now
	local mine = trainBudget[player.UserId]
	if not mine then
		mine = {}
		trainBudget[player.UserId] = mine
	end
	local b = mine[statName]
	if not b or now - b.start >= 3600 then
		b = { start = now, total = 0 }
		mine[statName] = b
	end
	if b.total >= TRAIN_XP_PER_HOUR then
		return
	end
	b.total += amount
	Basketball.onTrain(player, statName, amount)
end
Basketball.train = train

local function nearestHoop(position: Vector3): (Hoop?, number)
	local best, bestDist = nil, math.huge
	for _, hoop in hoops do
		local d = flat(hoop.rim - position).Magnitude
		if d < bestDist then
			best, bestDist = hoop, d
		end
	end
	return best, bestDist
end

-- Velocity that carries the ball from `from` to `to` in `t` seconds under ball gravity.
local function launchVelocity(from: Vector3, to: Vector3, t: number): Vector3
	return (to - from) / t + Vector3.new(0, 0.5 * B.GRAVITY * t, 0)
end

---------------------------------------------------------------------------
-- Ball lifecycle
---------------------------------------------------------------------------
function Basketball.newBall(position: Vector3): Ball
	local part = Instance.new("Part")
	part.Name = "Basketball"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * B.DIAMETER
	part.Color = Color3.fromRGB(230, 110, 30)
	part.Material = Enum.Material.Rubber
	part.CustomPhysicalProperties = PhysicalProperties.new(0.35, 0.6, 0.78, 1, 1)
	part.CollisionGroup = BALL_GROUP
	part.CFrame = CFrame.new(position)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- two thin dark discs, slightly wider than the ball, read as seams
	for _, rot in { CFrame.Angles(0, 0, 0), CFrame.Angles(0, math.pi / 2, 0) } do
		local seam = Instance.new("Part")
		seam.Name = "Seam"
		seam.Size = Vector3.new(0.05, B.DIAMETER + 0.03, B.DIAMETER + 0.03)
		seam.Color = Color3.fromRGB(30, 20, 15)
		seam.Material = Enum.Material.SmoothPlastic
		seam.CanCollide = false
		seam.CanQuery = false
		seam.CanTouch = false
		seam.Massless = true
		seam.CollisionGroup = BALL_GROUP
		seam.CFrame = part.CFrame * rot
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = seam
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = part
		weld.Part1 = seam
		weld.Parent = seam
		seam.Parent = part
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	local force = Instance.new("VectorForce")
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Parent = part
	part.Parent = ballFolder
	force.Force = Vector3.new(0, part:GetMass() * (workspace.Gravity - B.GRAVITY), 0)
	pcall(part.SetNetworkOwner, part, nil)

	local ball: Ball = {
		part = part,
		force = force,
		regrab = {},
		lastPos = position,
		scoreDebounce = 0,
		lastActive = os.clock(),
	}
	balls[ball] = true
	return ball
end

local function detach(ball: Ball)
	local holder = ball.holder
	if ball.weld then
		ball.weld:Destroy()
		ball.weld = nil
	end
	if holder then
		heldBy[holder] = nil
		if holder.Parent then
			holder:SetAttribute("HasBall", false)
		end
		ball.lastHolder = holder
	end
	ball.holder = nil
	ball.shootingSince = nil
	ball.part.Massless = false
	ball.part.CanCollide = true
	ball.force.Enabled = true
	pcall(ball.part.SetNetworkOwner, ball.part, nil)
end

function Basketball.give(ball: Ball, player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	if heldBy[player] and heldBy[player] ~= ball then
		return
	end
	detach(ball)
	ball.part.CanCollide = false
	ball.part.Massless = true
	ball.force.Enabled = false
	ball.part.CFrame = root.CFrame * CFrame.new(1.1, -1.5, -1.3)
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = ball.part
	weld.C0 = CFrame.new(1.1, -1.5, -1.3)
	weld.Parent = ball.part
	ball.weld = weld
	ball.holder = player
	ball.lastHolder = player
	ball.shot = nil
	ball.lastActive = os.clock()
	heldBy[player] = ball
	player:SetAttribute("HasBall", true)
	Basketball.possession.fire(ball, player)
end

function Basketball.drop(ball: Ball)
	local holder = ball.holder
	local root = holder and rootOf(holder)
	detach(ball)
	if root then
		ball.part.CFrame = CFrame.new(root.Position + root.CFrame.LookVector * 2)
	end
	ball.part.AssemblyLinearVelocity = Vector3.zero
	Basketball.possession.fire(ball, nil)
end

function Basketball.destroy(ball: Ball)
	if not balls[ball] then
		return
	end
	detach(ball)
	balls[ball] = nil
	ball.part:Destroy()
end

function Basketball.moveTo(ball: Ball, position: Vector3)
	detach(ball)
	ball.part.CFrame = CFrame.new(position)
	ball.part.AssemblyLinearVelocity = Vector3.zero
	ball.part.AssemblyAngularVelocity = Vector3.zero
	ball.lastPos = position
end

local function launch(ball: Ball, from: Vector3, velocity: Vector3, spin: Vector3?)
	detach(ball)
	ball.part.CFrame = CFrame.new(from)
	ball.part.AssemblyLinearVelocity = velocity
	ball.part.AssemblyAngularVelocity = spin or Vector3.zero
	ball.lastPos = from
	ball.lastActive = os.clock()
end

function Basketball.balls(): { [Ball]: boolean }
	return balls
end

---------------------------------------------------------------------------
-- Shooting
---------------------------------------------------------------------------
function Basketball.shootStart(player: Player)
	local ball = heldBy[player]
	if not ball or ball.shootingSince or not canAct(player) then
		return
	end
	ball.shootingSince = os.clock()
end

local function nearestOpponent(player: Player, ball: Ball, position: Vector3): (Player?, number)
	local best, bestDist = nil, math.huge
	for _, other in Basketball.policy.opponents(player, ball) do
		local r = rootOf(other)
		if r and canAct(other) then
			local d = flat(r.Position - position).Magnitude
			if d < bestDist then
				best, bestDist = other, d
			end
		end
	end
	return best, bestDist
end

local function shoot(player: Player, ball: Ball, held: number)
	local root = rootOf(player)
	local humanoid = humanoidOf(player)
	if not root or not humanoid then
		return
	end
	local hoop = Basketball.policy.targetHoop(player, ball)
	local dist
	if hoop then
		dist = flat(hoop.rim - root.Position).Magnitude
	else
		hoop, dist = nearestHoop(root.Position)
	end
	local look = flat(root.CFrame.LookVector)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
	local from = root.Position + Vector3.new(0, 2.6, 0) + look * 0.8

	if not hoop or dist > B.MAX_SHOT_RANGE then
		-- Nowhere to shoot: just toss it forward.
		launch(ball, from, launchVelocity(from, from + look * 20 + Vector3.new(0, -2, 0), 0.9))
		ball.regrab[player] = os.clock() + B.REGRAB_COOLDOWN
		return
	end

	local offBy = math.abs(held - B.PERFECT_RELEASE)
	local timing = math.clamp(1 - offBy / B.RELEASE_WINDOW, 0, 1)
	local perfect = offBy <= B.PERFECT_TOLERANCE
	local moving = flat(root.AssemblyLinearVelocity).Magnitude
	local airborne = humanoid.FloorMaterial == Enum.Material.Air

	local kind
	if dist <= B.DUNK_RANGE and (moving > 16 or airborne) then
		kind = "dunk"
	elseif dist <= 7 then
		kind = "layup"
	elseif dist <= B.THREE_POINT_RANGE then
		kind = "mid"
	elseif dist <= 26 then
		kind = "three"
	else
		kind = "deep"
	end
	local points = if dist > B.THREE_POINT_RANGE + 0.3 then 3 else 2

	local defender, defenderDist = nearestOpponent(player, ball, root.Position)

	-- Block: a jumping defender right on the shooter can swat it.
	if defender and defenderDist <= B.BLOCK_RANGE then
		local defHumanoid = humanoidOf(defender)
		if defHumanoid and defHumanoid.FloorMaterial == Enum.Material.Air then
			local chance = 0.3 + (stat(defender, "Vertical") + stat(defender, "Defense")) * 0.002 - stat(player, "Vertical") * 0.001
			if rng:NextNumber() < math.clamp(chance, 0.1, 0.65) then
				local away = flat(root.Position - hoop.rim)
				away = if away.Magnitude > 0.01 then away.Unit else -look
				local side = Vector3.new(-away.Z, 0, away.X) * rng:NextNumber(-12, 12)
				launch(ball, from + Vector3.new(0, 1, 0), away * 28 + side + Vector3.new(0, 18, 0))
				ball.regrab[player] = os.clock() + B.REGRAB_COOLDOWN
				train(defender, "Defense", 6)
				train(defender, "Vertical", 4)
				Basketball.blocked.fire(ball, defender, player)
				return
			end
		end
	end

	local base
	if kind == "dunk" then
		base = 0.9
	elseif kind == "layup" then
		base = 0.72
	elseif kind == "mid" then
		base = 0.52 - (dist - 7) * 0.008
	elseif kind == "three" then
		base = 0.36 - (dist - B.THREE_POINT_RANGE) * 0.01
	else
		base = math.max(0.04, 0.22 - (dist - 26) * 0.012)
	end
	local close = kind == "dunk" or kind == "layup"
	local statBonus = if close
		then (stat(player, "Finishing") - 1) * 0.0025 + (stat(player, "Vertical") - 1) * 0.001
		else (stat(player, "Shooting") - 1) * 0.003
	local timingFactor = if kind == "dunk" then 1 elseif kind == "layup" then 0.6 + 0.4 * timing else 0.3 + 0.7 * timing
	local contest = 1
	if defender and defenderDist < B.CONTEST_RANGE then
		local closeness = defenderDist / B.CONTEST_RANGE
		contest = if kind == "dunk" then 0.85 + 0.15 * closeness else 0.55 + 0.45 * closeness
	end
	local perfectBonus = if perfect and not close then 0.1 else 0
	local chance = math.clamp((base + statBonus) * timingFactor * contest + perfectBonus, 0.02, 0.97)
	local make = rng:NextNumber() < chance

	ball.shot = {
		shooter = player,
		points = points,
		kind = kind,
		perfect = perfect and make,
		at = os.clock(),
		contestedBy = if defender and defenderDist < B.CONTEST_RANGE then defender else nil,
	}
	ball.regrab[player] = os.clock() + B.REGRAB_COOLDOWN

	if kind == "dunk" and make then
		Basketball.dunkJump(player, hoop.rim)
		detach(ball)
		ball.part.CFrame = CFrame.new(hoop.rim + Vector3.new(0, 1.8, 0))
		ball.lastPos = ball.part.Position
		-- hang above the rim for the jump, then slam it through
		ball.part.Anchored = true
		task.delay(0.28, function()
			if balls[ball] then
				ball.part.Anchored = false
				-- unanchoring drops the manual owner; keep the free ball on the server
				pcall(ball.part.SetNetworkOwner, ball.part, nil)
				ball.lastPos = ball.part.Position
				ball.part.AssemblyLinearVelocity = Vector3.new(0, -45, 0)
			end
		end)
		return
	end

	local target = hoop.rim + Vector3.new(0, 0.05, 0)
	if not make then
		-- Clank it off the rim, or airball a badly timed shot.
		local angle = rng:NextNumber(0, math.pi * 2)
		local miss = if timing < 0.15 and not close then rng:NextNumber(2.6, 3.6) else rng:NextNumber(1.1, 1.7)
		target += Vector3.new(math.cos(angle) * miss, 0.2, math.sin(angle) * miss)
	end
	local flight = if close then 0.6 else 0.7 + dist * 0.012
	launch(ball, from, launchVelocity(from, target, flight), root.CFrame.RightVector * -8)
end

function Basketball.shootRelease(player: Player)
	local ball = heldBy[player]
	if not ball or not ball.shootingSince or not canAct(player) then
		return
	end
	local held = os.clock() - ball.shootingSince
	ball.shootingSince = nil
	shoot(player, ball, held)
end

---------------------------------------------------------------------------
-- Passing and stealing
---------------------------------------------------------------------------
function Basketball.pass(player: Player)
	local ball = heldBy[player]
	local root = rootOf(player)
	if not ball or not root or ball.shootingSince then
		return
	end
	local look = flat(root.CFrame.LookVector).Unit
	local best, bestScore = nil, math.huge
	for _, other in Basketball.policy.passTargets(player, ball) do
		local r = rootOf(other)
		if r and canAct(other) and not heldBy[other] then
			local offset = flat(r.Position - root.Position)
			local d = offset.Magnitude
			if d > 2 and d < B.PASS_RANGE then
				local facing = look:Dot(offset.Unit)
				if facing > 0.2 then
					local score = d * (2 - facing)
					if score < bestScore then
						best, bestScore = other, score
					end
				end
			end
		end
	end
	local from = root.Position + Vector3.new(0, 1, 0) + look * 1.4
	local target
	if best then
		local r = rootOf(best) :: BasePart
		local d = flat(r.Position - root.Position).Magnitude
		local t = math.clamp(d / 75, 0.2, 0.8)
		target = r.Position + flat(r.AssemblyLinearVelocity) * t + Vector3.new(0, 0.5, 0)
		launch(ball, from, launchVelocity(from, target, t))
		train(player, "Passing", 3)
	else
		target = root.Position + look * 25 + Vector3.new(0, -1, 0)
		launch(ball, from, launchVelocity(from, target, 0.5))
	end
	ball.regrab[player] = os.clock() + 0.4
end

function Basketball.steal(player: Player)
	local root = rootOf(player)
	if not root or heldBy[player] or not canAct(player) then
		return
	end
	local now = os.clock()
	if (stealCooldown[player] or 0) > now then
		return
	end
	stealCooldown[player] = now + B.STEAL_COOLDOWN
	for victim, ball in heldBy do
		local r = rootOf(victim)
		if victim ~= player and r and flat(r.Position - root.Position).Magnitude <= B.STEAL_RANGE then
			if Basketball.policy.canSteal(player, victim, ball) and Basketball.policy.canHold(player, ball) then
				local chance = 0.25 + (stat(player, "Defense") - stat(victim, "BallHandling")) * 0.004
				if ball.shootingSince then
					chance += 0.1 -- caught mid-shot
				end
				train(player, "Defense", 3)
				if rng:NextNumber() < math.clamp(chance, 0.08, 0.6) then
					Basketball.give(ball, player)
					Basketball.stolen.fire(ball, player, victim)
				else
					train(victim, "BallHandling", 3)
				end
				return
			end
		end
	end
end

---------------------------------------------------------------------------
-- Every frame: dribble animation, pickups and scoring
---------------------------------------------------------------------------
local function canPickUp(player: Player, ball: Ball, now: number): boolean
	if heldBy[player] or not canAct(player) then
		return false
	end
	if (ball.regrab[player] or 0) > now then
		return false
	end
	return Basketball.policy.canHold(player, ball)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for ball in balls do
		local holder = ball.holder
		if holder then
			if not holder.Parent or not canAct(holder) then
				Basketball.drop(ball)
			elseif ball.weld then
				if ball.shootingSince then
					ball.weld.C0 = CFrame.new(0, 2.5, -0.9)
					if now - ball.shootingSince > 1.6 then
						Basketball.shootRelease(holder) -- held far too long
					end
				else
					local bounce = math.abs(math.sin(now * 8.5)) * 1.7
					ball.weld.C0 = CFrame.new(1.1, -2.1 + bounce, -1.3)
				end
				if (now - ball.lastActive) > 0.5 then
					ball.lastActive = now
					train(holder, "BallHandling", 1)
				end
			end
			continue
		end

		local part = ball.part
		local pos = part.Position

		-- [Security] a free ball is always simulated by the server: a client that
		-- owned it could fly it through any rim (anchoring/unanchoring resets owners)
		if not part.Anchored then
			local okOwner, owner = pcall(part.GetNetworkOwner, part)
			if okOwner and owner ~= nil then
				pcall(part.SetNetworkOwner, part, nil)
			end
		end

		-- Scoring: the ball's centre passes down through the rim.
		if now > ball.scoreDebounce then
			for _, hoop in hoops do
				local rimY = hoop.rim.Y
				if ball.lastPos.Y >= rimY and pos.Y < rimY then
					local mid = (ball.lastPos + pos) / 2
					if flat(mid - hoop.rim).Magnitude < hoop.radius - 0.35 then
						ball.scoreDebounce = now + 1
						local shot = ball.shot
						if shot and now - shot.at > 4 then
							shot = nil
						end
						ball.shot = nil
						Basketball.scored.fire(ball, hoop, shot)
						break
					end
				end
			end
		end
		ball.lastPos = pos

		-- Pickups: closest eligible player within reach.
		if not part.Anchored then
			local best, bestDist = nil, math.huge
			for _, player in Players:GetPlayers() do
				local r = rootOf(player)
				if r then
					local offset = pos - r.Position
					local horizontal = flat(offset).Magnitude
					if horizontal < B.PICKUP_RANGE and offset.Y > -4 and offset.Y < 4.5 and horizontal < bestDist then
						if canPickUp(player, ball, now) then
							best, bestDist = player, horizontal
						end
					end
				end
			end
			if best then
				Basketball.give(ball, best)
			elseif part.AssemblyLinearVelocity.Magnitude > 2 then
				ball.lastActive = now
			end
		end

		-- Fell out of the world.
		if pos.Y < -30 then
			if ball.court then
				local center = ball.court:GetAttribute("CourtCenter")
				Basketball.moveTo(ball, center + Vector3.new(0, 4, 0))
			else
				Basketball.destroy(ball)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local ball = heldBy[player]
	if ball then
		Basketball.drop(ball)
	end
	for b in balls do
		b.regrab[player] = nil
		if b.owner == player and not b.gameCourt then
			Basketball.destroy(b)
		end
	end
	stealCooldown[player] = nil
	trainCooldown[player] = nil
end)

return Basketball
