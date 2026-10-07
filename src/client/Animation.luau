-- CITY GRIND: procedural character poses (Phase 8). Client side.
-- Every client poses EVERY nearby R15 character from replicated state, so all
-- players see the same thing without any animation assets:
--   * PhoneOut (Player attribute)        right arm up holding the phone (the
--                                        server already welds the phone prop
--                                        to the hand), head tilted down
--   * HasBall + the ball's server weld   right hand follows the dribble; ball
--                                        raised over the head = shooting set,
--                                        then a follow-through (or a two-hand
--                                        dunk if they rose high) after release
--   * Humanoid.SeatPart is a VehicleSeat both hands forward on the wheel /
--                                        bars, leaning with the turn
--   * standing still                     subtle breathing and the occasional
--                                        look around
-- Poses are written to Motor6D.Transform in PreSimulation (after the default
-- Animate script's animations were applied this frame) and blended in/out, so
-- walking / running / jumping animations keep working underneath. Nothing is
-- overridden while an emote plays (Player attribute Emote), while gym training
-- poses the rig (Training), or while any server system has moved a shoulder's
-- C0 away from its rest (work carry, waves). R6 avatars are left alone.
-- Graphics "Low" shortens the range and drops idle motion for other players.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local Animation = {}

local JOINTS = { "RightShoulder", "RightElbow", "LeftShoulder", "LeftElbow", "Neck", "Waist" }
local RANGE = { Low = 45, Medium = 90, High = 130 }
local BLEND_IN, BLEND_OUT = 10, 7 -- per second
local DOWN = Vector3.new(0, -1, 0)

-- base: the Transform the Animate script left this frame; written: what we
-- wrote last (if nothing overwrote it, our own value must not compound).
type Joint = { motor: Motor6D, w: number, cur: CFrame, base: CFrame, written: CFrame? }
type Entry = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	joints: { [string]: Joint },
	ball: BasePart?,
	ballWeld: Weld?,
	shootSeenAt: number,
	shootRootY: number,
	stillSince: number,
	lookYaw: number,
	lookTarget: number,
	nextLook: number,
	breathPhase: number,
	posedCheckAt: number,
	posedByServer: boolean,
}

local entries: { [Model]: Entry } = {}
local quality = "High"
local ballFolder: Instance? = nil

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local function readQuality()
	local g = player:GetAttribute("Graphics")
	if g == "Low" or g == "Medium" or g == "High" then
		quality = g
		return
	end
	local level = 10
	pcall(function()
		local v = UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
		if type(v) == "number" and v > 0 then
			level = v -- 0 = Automatic
		end
	end)
	quality = if level <= 3 then "Low" elseif level <= 6 then "Medium" else "High"
end

---------------------------------------------------------------------------
-- Rig helpers
---------------------------------------------------------------------------
local function restC0(motor: Motor6D): CFrame?
	local part0 = motor.Part0
	local att = part0 and part0:FindFirstChild(motor.Name .. "RigAttachment")
	return if att and att:IsA("Attachment") then att.CFrame else nil
end

local function nearlyEqual(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < 0.02 and a.LookVector:Dot(b.LookVector) > 0.999 and a.UpVector:Dot(b.UpVector) > 0.999
end

-- Rotation (in the joint's frame) that points a hanging limb (-Y) along `worldDir`.
local function aim(motor: Motor6D, worldDir: Vector3): CFrame
	local part0 = motor.Part0
	if not part0 or worldDir.Magnitude < 1e-3 then
		return CFrame.identity
	end
	local d = (part0.CFrame * motor.C0):VectorToObjectSpace(worldDir.Unit)
	local axis = DOWN:Cross(d)
	local dot = math.clamp(DOWN:Dot(d), -1, 1)
	if axis.Magnitude < 1e-4 then
		return if dot > 0 then CFrame.identity else CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

-- Direction given in the character's own space (x right, y up, -z forward).
local function rootDir(entry: Entry, x: number, y: number, z: number): Vector3
	return entry.root.CFrame:VectorToWorldSpace(Vector3.new(x, y, z))
end

local function bend(degrees: number): CFrame
	return CFrame.Angles(math.rad(degrees), 0, 0)
end

local function track(character: Model, owner: Player)
	if entries[character] then
		return
	end
	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
			return
		end
		if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
			return
		end
		-- wait for the joints to exist (they stream in with the character)
		local joints: { [string]: Joint } = {}
		local deadline = os.clock() + 10
		while os.clock() < deadline and character.Parent do
			for _, name in JOINTS do
				if not joints[name] then
					local m = character:FindFirstChild(name, true)
					if m and m:IsA("Motor6D") then
						joints[name] = { motor = m, w = 0, cur = CFrame.identity, base = CFrame.identity, written = nil }
					end
				end
			end
			local count = 0
			for _ in joints do
				count += 1
			end
			if count == #JOINTS then
				break
			end
			task.wait(0.3)
		end
		if not character.Parent or not joints.RightShoulder or not joints.RightElbow then
			return
		end
		entries[character] = {
			player = owner,
			character = character,
			humanoid = humanoid,
			root = root,
			joints = joints,
			shootSeenAt = -10,
			shootRootY = 0,
			stillSince = os.clock(),
			lookYaw = 0,
			lookTarget = 0,
			nextLook = os.clock() + math.random() * 6,
			breathPhase = math.random() * 6,
			posedCheckAt = 0,
			posedByServer = false,
		}
		character.Destroying:Connect(function()
			entries[character] = nil
		end)
		humanoid.Died:Connect(function()
			entries[character] = nil
		end)
	end)
end

local function hookPlayer(p: Player)
	if p.Character then
		track(p.Character, p)
	end
	p.CharacterAdded:Connect(function(c)
		track(c, p)
	end)
end

---------------------------------------------------------------------------
-- Ball lookup
---------------------------------------------------------------------------
local function findBall(entry: Entry): (BasePart?, Weld?)
	local cached, weld = entry.ball, entry.ballWeld
	if cached and weld and weld.Parent == cached and weld.Part0 == entry.root then
		return cached, weld
	end
	entry.ball, entry.ballWeld = nil, nil
	local folder = ballFolder
	if not folder then
		return nil, nil
	end
	for _, b in folder:GetChildren() do
		if b:IsA("BasePart") then
			local w = b:FindFirstChild("Weld")
			if w and w:IsA("Weld") and w.Part0 == entry.root then
				entry.ball, entry.ballWeld = b, w
				return b, w
			end
		end
	end
	return nil, nil
end

---------------------------------------------------------------------------
-- Poses: return joint name -> target Transform (joint space)
---------------------------------------------------------------------------
type Targets = { [string]: CFrame }

local function phonePose(e: Entry, t: Targets)
	local j = e.joints
	t.RightShoulder = aim(j.RightShoulder.motor, rootDir(e, -0.3, -0.75, -0.55))
	t.RightElbow = bend(95)
	if j.Neck then
		t.Neck = CFrame.Angles(math.rad(-20), math.rad(8), 0)
	end
end

local function dribblePose(e: Entry, t: Targets, ball: BasePart)
	local j = e.joints
	local shoulder = j.RightShoulder.motor
	local part0 = shoulder.Part0
	if not part0 then
		return
	end
	local shoulderPos = (part0.CFrame * shoulder.C0).Position
	local toBall = (ball.Position + Vector3.new(0, ball.Size.Y * 0.45, 0)) - shoulderPos
	t.RightShoulder = aim(shoulder, toBall)
	-- the closer the ball comes up, the more the elbow gives
	t.RightElbow = bend(math.clamp((3.2 - toBall.Magnitude) * 45, 8, 70))
end

local function shootSetPose(e: Entry, t: Targets)
	local j = e.joints
	t.RightShoulder = aim(j.RightShoulder.motor, rootDir(e, 0.12, 0.8, -0.6))
	t.RightElbow = bend(70)
	if j.LeftShoulder and j.LeftElbow then
		t.LeftShoulder = aim(j.LeftShoulder.motor, rootDir(e, -0.25, 0.7, -0.6))
		t.LeftElbow = bend(60)
	end
	if j.Neck then
		t.Neck = CFrame.Angles(math.rad(10), 0, 0)
	end
end

local function releasePose(e: Entry, t: Targets, dunk: boolean)
	local j = e.joints
	if dunk then
		t.RightShoulder = aim(j.RightShoulder.motor, rootDir(e, 0.1, 1, -0.25))
		t.RightElbow = bend(10)
		if j.LeftShoulder and j.LeftElbow then
			t.LeftShoulder = aim(j.LeftShoulder.motor, rootDir(e, -0.1, 1, -0.25))
			t.LeftElbow = bend(10)
		end
	else
		t.RightShoulder = aim(j.RightShoulder.motor, rootDir(e, 0.05, 0.75, -0.65))
		t.RightElbow = bend(8)
		if j.LeftShoulder and j.LeftElbow then
			t.LeftShoulder = aim(j.LeftShoulder.motor, rootDir(e, -0.2, 0.55, -0.8))
			t.LeftElbow = bend(25)
		end
	end
end

local function drivePose(e: Entry, t: Targets, seat: VehicleSeat)
	local j = e.joints
	local steer
	if e.player == player then
		steer = seat.SteerFloat
	else
		steer = math.clamp(-seat.AssemblyAngularVelocity.Y / 1.5, -1, 1)
	end
	-- turning left lifts the right hand and drops the left, like a wheel
	t.RightShoulder = aim(j.RightShoulder.motor, rootDir(e, -0.12, -0.35 - steer * 0.2, -0.93))
	t.RightElbow = bend(30)
	if j.LeftShoulder and j.LeftElbow then
		t.LeftShoulder = aim(j.LeftShoulder.motor, rootDir(e, 0.12, -0.35 + steer * 0.2, -0.93))
		t.LeftElbow = bend(30)
	end
	if j.Neck then
		t.Neck = CFrame.Angles(0, -steer * 0.25, 0)
	end
end

local function blocked(e: Entry, now: number): boolean
	local p = e.player
	local emote = p:GetAttribute("Emote")
	if type(emote) == "string" and emote ~= "" then
		return true
	end
	local training = p:GetAttribute("Training")
	if type(training) == "string" and training ~= "" then
		return true
	end
	if e.humanoid.Health <= 0 then
		return true
	end
	if now >= e.posedCheckAt then
		e.posedCheckAt = now + 0.3
		e.posedByServer = false
		for _, name in { "RightShoulder", "LeftShoulder" } do
			local jt = e.joints[name]
			local rest = jt and restC0(jt.motor)
			if jt and rest and not nearlyEqual(jt.motor.C0, rest) then
				e.posedByServer = true
				break
			end
		end
	end
	return e.posedByServer
end

-- Fills `t` with the active pose; returns true when the rig is "busy" (no idle).
local function choosePose(e: Entry, t: Targets, now: number): boolean
	local seat = e.humanoid.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		drivePose(e, t, seat)
		return true
	end
	if seat then
		return true -- passenger seat / bench: leave the default sit
	end
	if e.player:GetAttribute("HasBall") == true then
		local ball, weld = findBall(e)
		if ball and weld then
			if weld.C0.Y > 1.5 then
				shootSetPose(e, t)
				if now - e.shootSeenAt > 0.3 then
					e.shootRootY = e.root.Position.Y
				end
				e.shootSeenAt = now
			else
				dribblePose(e, t, ball)
			end
			return true
		end
	elseif now - e.shootSeenAt < 0.5 then
		releasePose(e, t, e.root.Position.Y - e.shootRootY > 2.5)
		return true
	end
	if e.player:GetAttribute("PhoneOut") == true then
		phonePose(e, t)
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- Frame step
---------------------------------------------------------------------------
local targets: Targets = {}

local function stepEntry(e: Entry, dt: number, now: number, allowIdle: boolean)
	table.clear(targets)
	local busy = true
	local isBlocked = blocked(e, now)
	if not isBlocked then
		busy = choosePose(e, targets, now)
	end
	local inK = 1 - math.exp(-BLEND_IN * dt)
	local outK = 1 - math.exp(-BLEND_OUT * dt)

	-- idle: breathing + an occasional look around while standing still
	local speed = Vector3.new(e.root.AssemblyLinearVelocity.X, 0, e.root.AssemblyLinearVelocity.Z).Magnitude
	if speed > 0.6 or busy or isBlocked or e.humanoid.SeatPart then
		e.stillSince = now
	end
	local idle = allowIdle and not busy and not isBlocked and now - e.stillSince > 1.5
	if idle then
		if now >= e.nextLook then
			e.nextLook = now + 3 + math.random() * 6
			e.lookTarget = if math.random() < 0.4 then 0 else (math.random() * 2 - 1) * 0.45
		end
	else
		e.lookTarget = 0
	end
	e.lookYaw += (e.lookTarget - e.lookYaw) * math.min(1, dt * 2.5)

	local breath = 0
	if idle then
		e.breathPhase += dt * 1.7
		breath = math.sin(e.breathPhase) * 0.018
	end
	for name, jt in e.joints do
		local motor = jt.motor
		-- what the animator produced this frame (or the clean base if it didn't touch this joint)
		local current = motor.Transform
		if jt.written and current == jt.written then
			current = jt.base
		end
		jt.base = current
		local target = targets[name]
		if target then
			jt.cur = if jt.w < 0.01 then target else jt.cur:Lerp(target, inK)
			jt.w += (1 - jt.w) * inK
		else
			jt.w -= jt.w * outK
			if jt.w < 0.002 then
				jt.w = 0
			end
		end
		local final = if jt.w > 0 then current:Lerp(jt.cur, jt.w) else current
		-- additive idle on top of whatever the Animate script is playing
		if not isBlocked and not target then
			if name == "Neck" and math.abs(e.lookYaw) > 0.002 then
				final *= CFrame.Angles(0, e.lookYaw, 0)
			elseif name == "Waist" and breath ~= 0 then
				final *= CFrame.Angles(breath, 0, 0)
			end
		end
		if final ~= current or jt.written then
			motor.Transform = final
			jt.written = if final ~= current then final else nil
		end
	end
end

-- Hands every joint back to the animator's own value (out of range / removed).
local function release(e: Entry)
	for _, jt in e.joints do
		jt.w = 0
		if jt.written then
			if jt.motor.Transform == jt.written then
				jt.motor.Transform = jt.base
			end
			jt.written = nil
		end
	end
end

local function step(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camPos = cam.CFrame.Position
	local range = RANGE[quality] or 90
	local now = os.clock()
	for character, e in entries do
		if not character.Parent or not e.root.Parent then
			entries[character] = nil
			continue
		end
		local isMe = e.player == player
		if isMe or (e.root.Position - camPos).Magnitude <= range then
			stepEntry(e, dt, now, isMe or quality ~= "Low")
		else
			-- out of range: let go so it eases back in later
			release(e)
		end
	end
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function Animation.start()
	readQuality()
	player:GetAttributeChangedSignal("Graphics"):Connect(readQuality)
	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	task.spawn(function()
		ballFolder = Workspace:WaitForChild("Basketballs", 60)
	end)
	RunService.PreSimulation:Connect(step)
end

return Animation
