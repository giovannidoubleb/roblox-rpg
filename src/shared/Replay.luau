-- CITY GRIND: replay clips (spec 23, 24, 34). A clip is compact replay data, never video:
-- per-frame positions of the players, balls and vehicles around a moment, quantized
-- into short strings so one clip stays well under ~25 KB of JSON.
--
-- Server side: Replay.samplePlayer(character) + Replay.encode* build the track strings.
-- Client side: Replay.new(viewportFrame) renders a clip inside a ViewportFrame/WorldModel:
--   local r = Replay.new(viewport); r:load(clip); r:render(t, dt); r:setCamera(mode, fov); r:destroy()
--
-- Clip shape (all JSON-safe):
--   { v = 1, id, kind, tag, title, at, loc, hz, n (frames), dur, o = {x,y,z} origin, ax (side axis
--     angle), ck (clock time), focus (userId),
--     p  = { { u = userId, n = name, c = {"rrggbb" head, torso, arms, legs}, a = 0|1 animated, f = track } },
--     b  = { { f = track } },
--     vh = { { u = driverId, k = kind, c = "rrggbb", s = {w,h,l}, f = track } },
--     e  = { { t = seconds, x = callout text } },
--     edit = {...} (editor parameters, see server CityTok.sanitizeEdit) }
-- Track = fixed-width frames: "1"/"0" visible flag then base-64 digits.
--   player 26 chars: pos 3x3, yaw 2, 14 joint angles x1
--   ball   10 chars: pos 3x3
--   vehicle 16 chars: pos 3x3, rotation XYZ 3x2

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local Replay = {}

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local CHARS: { string } = {}
local VALUES: { [number]: number } = {}
for i = 1, 64 do
	local ch = ALPHABET:sub(i, i)
	CHARS[i - 1] = ch
	VALUES[string.byte(ch)] = i - 1
end

local POS_RES = 0.05
local POS_HALF = 131072 -- 64^3 / 2
local TAU = math.pi * 2

Replay.PLAYER_W = 26
Replay.BALL_W = 10
Replay.VEHICLE_W = 16
Replay.JOINTS = 14

local function digits(n: number, width: number): string
	if width == 1 then
		return CHARS[n % 64]
	elseif width == 2 then
		return CHARS[(n // 64) % 64] .. CHARS[n % 64]
	end
	return CHARS[(n // 4096) % 64] .. CHARS[(n // 64) % 64] .. CHARS[n % 64]
end

local function read(s: string, i: number, width: number): number
	local n = 0
	for k = i, i + width - 1 do
		n = n * 64 + (VALUES[string.byte(s, k)] or 0)
	end
	return n
end

local function encPos(v: number): string
	return digits(math.clamp(math.floor(v / POS_RES + 0.5) + POS_HALF, 0, 262143), 3)
end

local function decPos(s: string, i: number): number
	return (read(s, i, 3) - POS_HALF) * POS_RES
end

local function encAngle(a: number, width: number): string
	local steps = if width == 1 then 64 else 4096
	return digits(math.floor(a / TAU * steps + 0.5) % steps, width)
end

local function decAngle(s: string, i: number, width: number): number
	local steps = if width == 1 then 64 else 4096
	local a = read(s, i, width) / steps * TAU
	return if a > math.pi then a - TAU else a
end

local function encVec(v: Vector3, origin: Vector3): string
	local d = v - origin
	return encPos(d.X) .. encPos(d.Y) .. encPos(d.Z)
end

export type PlayerSample = { pos: Vector3, yaw: number, j: { number } }

function Replay.encodePlayerFrame(sample: PlayerSample?, origin: Vector3): string
	if not sample then
		return "0" .. string.rep("A", Replay.PLAYER_W - 1)
	end
	local parts = { "1", encVec(sample.pos, origin), encAngle(sample.yaw, 2) }
	for k = 1, Replay.JOINTS do
		parts[#parts + 1] = encAngle(sample.j[k] or 0, 1)
	end
	return table.concat(parts)
end

function Replay.encodeBallFrame(pos: Vector3?, origin: Vector3): string
	if not pos then
		return "0" .. string.rep("A", Replay.BALL_W - 1)
	end
	return "1" .. encVec(pos, origin)
end

function Replay.encodeVehicleFrame(cf: CFrame?, origin: Vector3): string
	if not cf then
		return "0" .. string.rep("A", Replay.VEHICLE_W - 1)
	end
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	return "1" .. encVec(cf.Position, origin) .. encAngle(rx, 2) .. encAngle(ry, 2) .. encAngle(rz, 2)
end

-- Decoded frames: false when hidden.
function Replay.decodePlayer(track: string, origin: Vector3): { any }
	local out = {}
	local w = Replay.PLAYER_W
	for i = 1, #track - w + 1, w do
		if track:sub(i, i) ~= "1" then
			out[#out + 1] = false
		else
			local j = table.create(Replay.JOINTS, 0)
			for k = 1, Replay.JOINTS do
				j[k] = decAngle(track, i + 11 + k, 1)
			end
			out[#out + 1] = {
				pos = origin + Vector3.new(decPos(track, i + 1), decPos(track, i + 4), decPos(track, i + 7)),
				yaw = decAngle(track, i + 10, 2),
				j = j,
			}
		end
	end
	return out
end

function Replay.decodeBall(track: string, origin: Vector3): { any }
	local out = {}
	local w = Replay.BALL_W
	for i = 1, #track - w + 1, w do
		if track:sub(i, i) ~= "1" then
			out[#out + 1] = false
		else
			out[#out + 1] = origin + Vector3.new(decPos(track, i + 1), decPos(track, i + 4), decPos(track, i + 7))
		end
	end
	return out
end

function Replay.decodeVehicle(track: string, origin: Vector3): { any }
	local out = {}
	local w = Replay.VEHICLE_W
	for i = 1, #track - w + 1, w do
		if track:sub(i, i) ~= "1" then
			out[#out + 1] = false
		else
			local pos = origin + Vector3.new(decPos(track, i + 1), decPos(track, i + 4), decPos(track, i + 7))
			out[#out + 1] = CFrame.new(pos) * CFrame.fromEulerAnglesXYZ(decAngle(track, i + 10, 2), decAngle(track, i + 12, 2), decAngle(track, i + 14, 2))
		end
	end
	return out
end

function Replay.colorHex(c: Color3): string
	return c:ToHex()
end

local function hexColor(hex: any, fallback: Color3): Color3
	if type(hex) == "string" and #hex == 6 then
		local ok, c = pcall(Color3.fromHex, hex)
		if ok then
			return c
		end
	end
	return fallback
end
Replay.hexColor = hexColor

---------------------------------------------------------------------------
-- Sampling a character (server). Joint angles are each limb's rotation
-- relative to its parent segment, so the block figures can replay the pose.
---------------------------------------------------------------------------
local function part(model: Model, ...: string): BasePart?
	for _, name in { ... } do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local function relXZ(a: BasePart?, b: BasePart?): (number, number)
	if not a or not b then
		return 0, 0
	end
	local rx, _, rz = a.CFrame:ToObjectSpace(b.CFrame):ToEulerAnglesXYZ()
	return rx, rz
end

function Replay.samplePlayer(character: Model): PlayerSample?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local cf = root.CFrame
	local look = cf.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local torso = part(character, "UpperTorso", "Torso")
	local hips = part(character, "LowerTorso", "Torso") or root
	local lua = part(character, "LeftUpperArm", "Left Arm")
	local rua = part(character, "RightUpperArm", "Right Arm")
	local lul = part(character, "LeftUpperLeg", "Left Leg")
	local rul = part(character, "RightUpperLeg", "Right Leg")
	local j = table.create(Replay.JOINTS, 0)
	j[1], j[2] = relXZ(torso, lua)
	j[3], j[4] = relXZ(torso, rua)
	j[5], j[6] = relXZ(hips, lul)
	j[7], j[8] = relXZ(hips, rul)
	j[9] = (relXZ(lua, part(character, "LeftLowerArm")))
	j[10] = (relXZ(rua, part(character, "RightLowerArm")))
	j[11] = (relXZ(lul, part(character, "LeftLowerLeg")))
	j[12] = (relXZ(rul, part(character, "RightLowerLeg")))
	local head = part(character, "Head")
	if torso and head then
		local rx, ry = torso.CFrame:ToObjectSpace(head.CFrame):ToEulerAnglesYXZ()
		j[13], j[14] = rx, ry
	end
	return { pos = cf.Position, yaw = yaw, j = j }
end

-- Head / torso / arm / leg colours as hex strings.
function Replay.bodyColors(character: Model?): { string }
	local function hex(...: string): string
		local p = character and part(character, ...)
		return if p then p.Color:ToHex() else "c8a07a"
	end
	return {
		hex("Head"),
		hex("UpperTorso", "Torso"),
		hex("LeftUpperArm", "Left Arm"),
		hex("LeftUpperLeg", "Left Leg"),
	}
end

---------------------------------------------------------------------------
-- Environment: copies of the static City parts around the action.
---------------------------------------------------------------------------
local KEEP_CHILD = { SpecialMesh = true, BlockMesh = true, CylinderMesh = true, Decal = true, Texture = true, SurfaceAppearance = true }
local partCache: { BasePart } = {}
local partCacheAt = -math.huge

local function cityParts(): { BasePart }
	if os.clock() - partCacheAt < 30 then
		return partCache
	end
	partCacheAt = os.clock()
	table.clear(partCache)
	local city = Workspace:FindFirstChild("City")
	if not city then
		return partCache
	end
	for _, d in city:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 0.98 and d.Name ~= "Basketball" then
			local skip = false
			local node = d.Parent
			while node and node ~= city do
				if CollectionService:HasTag(node, "CityVehicle") then
					skip = true
					break
				end
				node = node.Parent
			end
			if not skip then
				partCache[#partCache + 1] = d
			end
		end
	end
	return partCache
end

-- Builds a Model of up to `cap` part copies near any of `anchors`.
function Replay.buildEnvironment(anchors: { Vector3 }, radius: number, cap: number): Model
	local env = Instance.new("Model")
	env.Name = "Environment"
	local candidates = {}
	for _, p in cityParts() do
		if p.Parent then
			local pos = p.Position
			local half = p.Size.Magnitude / 2
			local best = math.huge
			for _, a in anchors do
				local d = (pos - a).Magnitude - half
				if d < best then
					best = d
				end
			end
			if best < radius then
				candidates[#candidates + 1] = { p = p, d = best }
			end
		end
	end
	table.sort(candidates, function(x, y)
		return x.d < y.d
	end)
	for i = 1, math.min(cap, #candidates) do
		local src = candidates[i].p
		local ok, copy = pcall(src.Clone, src)
		if ok and copy then
			for _, child in copy:GetChildren() do
				if not KEEP_CHILD[child.ClassName] then
					child:Destroy()
				end
			end
			copy.Anchored = true
			copy.CanCollide = false
			copy.CanTouch = false
			copy.CanQuery = false
			copy.CastShadow = false
			copy.Parent = env
		end
	end
	return env
end

---------------------------------------------------------------------------
-- Actors
---------------------------------------------------------------------------
local function newPart(name: string, size: Vector3, color: Color3, parent: Instance, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

type Avatar = {
	model: Model,
	parts: { BasePart },
	frames: { any },
	animated: boolean,
	name: string,
	userId: number,
	tag: TextLabel,
}

local function buildAvatar(info: any, origin: Vector3, parent: Instance, overlay: GuiObject): Avatar
	local model = Instance.new("Model")
	model.Name = tostring(info.n or "Player")
	local c = type(info.c) == "table" and info.c or {}
	local skin = hexColor(c[1], Color3.fromRGB(200, 160, 120))
	local shirt = hexColor(c[2], Color3.fromRGB(60, 90, 160))
	local arms = hexColor(c[3], skin)
	local legs = hexColor(c[4], Color3.fromRGB(40, 40, 50))
	local parts = {
		newPart("Torso", Vector3.new(2, 2, 1), shirt, model),
		newPart("Head", Vector3.new(2, 1, 1), skin, model),
		newPart("LUA", Vector3.new(0.95, 1.15, 0.95), arms, model),
		newPart("LLA", Vector3.new(0.9, 1.05, 0.9), arms, model),
		newPart("RUA", Vector3.new(0.95, 1.15, 0.95), arms, model),
		newPart("RLA", Vector3.new(0.9, 1.05, 0.9), arms, model),
		newPart("LUL", Vector3.new(0.98, 1.05, 0.98), legs, model),
		newPart("LLL", Vector3.new(0.95, 1.0, 0.95), legs, model),
		newPart("RUL", Vector3.new(0.98, 1.05, 0.98), legs, model),
		newPart("RLL", Vector3.new(0.95, 1.0, 0.95), legs, model),
	}
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	mesh.Parent = parts[2]
	-- eyes so the facing reads
	for _, x in { -0.22, 0.22 } do
		local eye = newPart("Eye", Vector3.new(0.14, 0.2, 0.05), Color3.fromRGB(20, 20, 25), model)
		eye:SetAttribute("EyeX", x)
		table.insert(parts, eye)
	end
	model.Parent = parent
	local tag = Instance.new("TextLabel")
	tag.Name = "NameTag"
	tag.BackgroundTransparency = 1
	tag.AnchorPoint = Vector2.new(0.5, 1)
	tag.Size = UDim2.fromOffset(140, 16)
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = 12
	tag.TextColor3 = Color3.new(1, 1, 1)
	tag.TextStrokeTransparency = 0.4
	tag.Text = tostring(info.n or "")
	tag.Visible = false
	tag.ZIndex = 3
	tag.Parent = overlay
	local frames = if type(info.f) == "string" then Replay.decodePlayer(info.f, origin) else {}
	return {
		model = model,
		parts = parts,
		frames = frames,
		animated = info.a == 1,
		name = tostring(info.n or ""),
		userId = tonumber(info.u) or 0,
		tag = tag,
	}
end

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % TAU - math.pi
	return a + d * t
end

-- Interpolated sample at fractional frame index; nil when hidden.
local function samplePlayerAt(frames: { any }, f: number): any
	local n = #frames
	if n == 0 then
		return nil
	end
	local i = math.clamp(math.floor(f), 1, n)
	local a = frames[i]
	local b = frames[math.min(i + 1, n)]
	if not a then
		return b or nil
	end
	if not b then
		return a
	end
	local t = math.clamp(f - i, 0, 1)
	local j = table.create(Replay.JOINTS, 0)
	for k = 1, Replay.JOINTS do
		j[k] = lerpAngle(a.j[k], b.j[k], t)
	end
	return { pos = a.pos:Lerp(b.pos, t), yaw = lerpAngle(a.yaw, b.yaw, t), j = j }
end

local function velocityAt(frames: { any }, f: number, hz: number): Vector3
	local n = #frames
	local i = math.clamp(math.floor(f), 1, n)
	local a = frames[math.max(1, i - 1)]
	local b = frames[math.min(n, i + 1)]
	local pa = if type(a) == "table" then a.pos elseif typeof(a) == "Vector3" then a elseif typeof(a) == "CFrame" then a.Position else nil
	local pb = if type(b) == "table" then b.pos elseif typeof(b) == "Vector3" then b elseif typeof(b) == "CFrame" then b.Position else nil
	if not pa or not pb then
		return Vector3.zero
	end
	local span = (math.min(n, i + 1) - math.max(1, i - 1)) / hz
	return if span > 0 then (pb - pa) / span else Vector3.zero
end

local function poseAvatar(av: Avatar, s: any, vel: Vector3, time: number, out: { CFrame })
	local root = CFrame.new(s.pos) * CFrame.Angles(0, s.yaw, 0)
	local j = s.j
	if not av.animated then
		-- No recorded joint motion: walk cycle from speed, tuck when airborne.
		local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
		local amount = math.clamp(speed / 16, 0, 1.1)
		local swing = math.sin(time * (6 + speed * 0.25)) * 0.8 * amount
		j = table.clone(j)
		j[1], j[3], j[5], j[7] = -swing, swing, swing, -swing
		j[11], j[12] = math.max(0, -swing) * 0.9, math.max(0, swing) * 0.9
		if math.abs(vel.Y) > 4 then
			j[1], j[3] = -2.6, -2.6
			j[11], j[12] = 0.8, 0.8
		end
	end
	local function limb(pivot: CFrame, x: number, z: number, upperLen: number, lowerX: number, lowerLen: number): (CFrame, CFrame)
		local upper = pivot * CFrame.fromEulerAnglesXYZ(x, 0, z)
		local joint = upper * CFrame.new(0, -upperLen, 0) * CFrame.fromEulerAnglesXYZ(lowerX, 0, 0)
		return upper * CFrame.new(0, -upperLen / 2, 0), joint * CFrame.new(0, -lowerLen / 2, 0)
	end
	out[1] = root
	local head = root * CFrame.new(0, 1, 0) * CFrame.fromEulerAnglesYXZ(j[13], j[14], 0) * CFrame.new(0, 0.6, 0)
	out[2] = head
	out[3], out[4] = limb(root * CFrame.new(-1.5, 0.95, 0), j[1], j[2], 1.15, j[9], 1.05)
	out[5], out[6] = limb(root * CFrame.new(1.5, 0.95, 0), j[3], j[4], 1.15, j[10], 1.05)
	out[7], out[8] = limb(root * CFrame.new(-0.5, -1, 0), j[5], j[6], 1.05, j[11], 1.0)
	out[9], out[10] = limb(root * CFrame.new(0.5, -1, 0), j[7], j[8], 1.05, j[12], 1.0)
	out[11] = head * CFrame.new(-0.22, 0.12, -0.6)
	out[12] = head * CFrame.new(0.22, 0.12, -0.6)
end

type VehicleActor = { model: Model, body: BasePart, frames: { any }, driver: number, size: Vector3, parts: { BasePart }, offsets: { CFrame } }

local function buildVehicle(info: any, origin: Vector3, parent: Instance): VehicleActor
	local model = Instance.new("Model")
	model.Name = "Vehicle"
	local s = type(info.s) == "table" and info.s or {}
	local w, h, l = tonumber(s[1]) or 6, tonumber(s[2]) or 4, tonumber(s[3]) or 12
	local color = hexColor(info.c, Color3.fromRGB(200, 30, 35))
	local kind = tostring(info.k or "Car")
	local twoWheel = kind == "Bike" or kind == "Scooter" or kind == "Motorcycle"
	local parts, offsets = {}, {}
	local function add(name: string, size: Vector3, offset: CFrame, c: Color3, shape: Enum.PartType?, material: Enum.Material?)
		local p = newPart(name, size, c, model, shape)
		if material then
			p.Material = material
		end
		parts[#parts + 1] = p
		offsets[#offsets + 1] = offset
		return p
	end
	local body
	if twoWheel then
		body = add("Body", Vector3.new(math.min(w, 1.2), h * 0.35, l * 0.7), CFrame.new(0, -h * 0.05, 0), color)
		for _, z in { -l * 0.38, l * 0.38 } do
			add("Wheel", Vector3.new(0.35, h * 0.5, h * 0.5), CFrame.new(0, -h / 2 + h * 0.25, z), Color3.fromRGB(24, 24, 26), Enum.PartType.Cylinder)
		end
	else
		body = add("Body", Vector3.new(w, h * 0.5, l), CFrame.new(0, -h * 0.12, 0), color)
		add("Cabin", Vector3.new(w * 0.86, h * 0.42, l * 0.5), CFrame.new(0, h * 0.33, l * 0.05), Color3.fromRGB(40, 55, 70), nil, Enum.Material.Glass)
		add("Roof", Vector3.new(w * 0.8, h * 0.08, l * 0.42), CFrame.new(0, h * 0.56, l * 0.05), color)
		local r = math.max(0.8, h * 0.28)
		for _, x in { -w / 2, w / 2 } do
			for _, z in { -l * 0.33, l * 0.33 } do
				add("Wheel", Vector3.new(0.8, r * 2, r * 2), CFrame.new(x, -h / 2 + r * 0.6, z), Color3.fromRGB(24, 24, 26), Enum.PartType.Cylinder)
			end
		end
		add("Headlights", Vector3.new(w * 0.8, h * 0.12, 0.1), CFrame.new(0, -h * 0.05, -l / 2 - 0.02), Color3.fromRGB(255, 248, 225), nil, Enum.Material.Neon)
		add("Taillights", Vector3.new(w * 0.8, h * 0.12, 0.1), CFrame.new(0, -h * 0.05, l / 2 + 0.02), Color3.fromRGB(150, 20, 22), nil, Enum.Material.Neon)
	end
	model.Parent = parent
	return {
		model = model,
		body = body,
		frames = if type(info.f) == "string" then Replay.decodeVehicle(info.f, origin) else {},
		driver = tonumber(info.u) or 0,
		size = Vector3.new(w, h, l),
		parts = parts,
		offsets = offsets,
	}
end

local function sampleCFrameAt(frames: { any }, f: number): CFrame?
	local n = #frames
	if n == 0 then
		return nil
	end
	local i = math.clamp(math.floor(f), 1, n)
	local a, b = frames[i], frames[math.min(i + 1, n)]
	if not a then
		return b or nil
	end
	if not b then
		return a
	end
	return a:Lerp(b, math.clamp(f - i, 0, 1))
end

local function sampleVecAt(frames: { any }, f: number): Vector3?
	local n = #frames
	if n == 0 then
		return nil
	end
	local i = math.clamp(math.floor(f), 1, n)
	local a, b = frames[i], frames[math.min(i + 1, n)]
	if not a then
		return b or nil
	end
	if not b then
		return a
	end
	return a:Lerp(b, math.clamp(f - i, 0, 1))
end

---------------------------------------------------------------------------
-- Player object
---------------------------------------------------------------------------
local Player = {}
Player.__index = Player

export type ReplayPlayer = typeof(setmetatable(
	{} :: {
		viewport: ViewportFrame,
		world: WorldModel,
		camera: Camera,
		overlay: Frame,
		callout: TextLabel,
		env: Model?,
		envAnchors: { Vector3 },
		envKind: string,
		dynamic: Folder,
		clip: any,
		hz: number,
		frameCount: number,
		duration: number,
		origin: Vector3,
		avatars: { Avatar },
		balls: { { part: BasePart, frames: { any } } },
		vehicles: { VehicleActor },
		events: { { t: number, x: string } },
		mode: string,
		fov: number,
		camPos: Vector3?,
		camLook: Vector3?,
		chaseDir: Vector3,
		sideDir: Vector3,
		showNames: boolean,
		poseBuffer: { CFrame },
	},
	Player
))

function Replay.new(viewport: ViewportFrame): ReplayPlayer
	local world = Instance.new("WorldModel")
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = 55
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local overlay = Instance.new("Frame")
	overlay.Name = "ReplayOverlay"
	overlay.BackgroundTransparency = 1
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 2
	overlay.Parent = viewport
	local callout = Instance.new("TextLabel")
	callout.Name = "Callout"
	callout.BackgroundTransparency = 1
	callout.AnchorPoint = Vector2.new(0.5, 0.5)
	callout.Position = UDim2.fromScale(0.5, 0.3)
	callout.Size = UDim2.fromScale(0.95, 0.12)
	callout.Font = Enum.Font.GothamBlack
	callout.TextScaled = true
	callout.TextColor3 = Color3.fromRGB(255, 215, 70)
	callout.TextStrokeTransparency = 0.2
	callout.Visible = false
	callout.ZIndex = 4
	callout.Parent = overlay
	local dynamic = Instance.new("Folder")
	dynamic.Name = "Actors"
	dynamic.Parent = world

	local self = setmetatable({
		viewport = viewport,
		world = world,
		camera = camera,
		overlay = overlay,
		callout = callout,
		env = nil,
		envAnchors = {},
		envKind = "",
		dynamic = dynamic,
		clip = nil,
		hz = 12,
		frameCount = 0,
		duration = 0,
		origin = Vector3.zero,
		avatars = {},
		balls = {},
		vehicles = {},
		events = {},
		mode = "broadcast",
		fov = 55,
		camPos = nil,
		camLook = nil,
		chaseDir = Vector3.new(0, 0, -1),
		sideDir = Vector3.new(1, 0, 0),
		showNames = true,
		poseBuffer = table.create(12, CFrame.identity),
	}, Player)
	return self
end

local function lightingFor(viewport: ViewportFrame, clock: number)
	local night = clock < 6.3 or clock > 17.7
	viewport.BackgroundColor3 = if night then Color3.fromRGB(14, 18, 40) else Color3.fromRGB(135, 190, 240)
	viewport.Ambient = if night then Color3.fromRGB(70, 75, 110) else Color3.fromRGB(150, 150, 150)
	viewport.LightColor = if night then Color3.fromRGB(150, 160, 220) else Color3.fromRGB(255, 250, 235)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.3)
end

function Player.clear(self: ReplayPlayer)
	self.dynamic:ClearAllChildren()
	for _, av in self.avatars do
		av.tag:Destroy()
	end
	self.avatars, self.balls, self.vehicles, self.events = {}, {}, {}, {}
	self.callout.Visible = false
end

-- Loads a clip (decodes tracks, builds actors, reuses the environment when the place matches).
function Player.load(self: ReplayPlayer, clip: any)
	self:clear()
	self.clip = clip
	local o = type(clip.o) == "table" and clip.o or { 0, 0, 0 }
	self.origin = Vector3.new(tonumber(o[1]) or 0, tonumber(o[2]) or 0, tonumber(o[3]) or 0)
	self.hz = math.clamp(tonumber(clip.hz) or 12, 1, 60)
	self.frameCount = math.max(1, tonumber(clip.n) or 1)
	self.duration = (self.frameCount - 1) / self.hz
	local ax = tonumber(clip.ax) or 0
	self.sideDir = Vector3.new(math.cos(ax), 0, math.sin(ax))
	lightingFor(self.viewport, tonumber(clip.ck) or 12)

	for _, info in (type(clip.p) == "table" and clip.p or {}) do
		table.insert(self.avatars, buildAvatar(info, self.origin, self.dynamic, self.overlay))
	end
	for _, info in (type(clip.b) == "table" and clip.b or {}) do
		local p = newPart("Ball", Vector3.one * 1.5, Color3.fromRGB(230, 110, 30), self.dynamic, Enum.PartType.Ball)
		p.Material = Enum.Material.SmoothPlastic
		local seam = newPart("Seam", Vector3.new(0.06, 1.55, 1.55), Color3.fromRGB(30, 20, 15), p, Enum.PartType.Cylinder)
		seam.Parent = p
		table.insert(self.balls, { part = p, seam = seam, frames = if type(info.f) == "string" then Replay.decodeBall(info.f, self.origin) else {} })
	end
	for _, info in (type(clip.vh) == "table" and clip.vh or {}) do
		table.insert(self.vehicles, buildVehicle(info, self.origin, self.dynamic))
	end
	for _, e in (type(clip.e) == "table" and clip.e or {}) do
		if type(e) == "table" and tonumber(e.t) and type(e.x) == "string" then
			table.insert(self.events, { t = tonumber(e.t) :: number, x = e.x })
		end
	end

	-- Environment anchors: the star's position once a second (covers a whole drive).
	local anchors = { self.origin }
	local star = self:focusTrack()
	if star then
		for f = 1, self.frameCount, self.hz do
			local s = star.frames[f]
			local pos = if type(s) == "table" then s.pos elseif typeof(s) == "CFrame" then s.Position else nil
			if pos then
				table.insert(anchors, pos)
			end
		end
	end
	local reuse = self.env ~= nil and self.envKind ~= "driving" and clip.kind ~= "driving" and (self.envAnchors[1] - self.origin).Magnitude < 30
	if not reuse then
		if self.env then
			self.env:Destroy()
		end
		local radius = if clip.kind == "driving" then 90 else 150
		local env = Replay.buildEnvironment(anchors, radius, 1200)
		if #env:GetChildren() < 10 then
			local floor = newPart("Floor", Vector3.new(400, 1, 400), Color3.fromRGB(80, 120, 70), env)
			floor.CFrame = CFrame.new(self.origin - Vector3.new(0, 3.55, 0))
		end
		env.Parent = self.world
		self.env = env
		self.envAnchors = anchors
		self.envKind = tostring(clip.kind)
	end
	self.camPos, self.camLook = nil, nil
end

-- The star of the clip: their vehicle in driving clips, else their avatar.
function Player.focusTrack(self: ReplayPlayer): any
	local focus = tonumber(self.clip and self.clip.focus) or 0
	if self.clip and self.clip.kind == "driving" then
		for _, v in self.vehicles do
			if v.driver == focus then
				return v
			end
		end
		if self.vehicles[1] then
			return self.vehicles[1]
		end
	end
	for _, av in self.avatars do
		if av.userId == focus then
			return av
		end
	end
	return self.avatars[1]
end

function Player.setCamera(self: ReplayPlayer, mode: string?, fov: number?)
	if mode and mode ~= self.mode then
		self.mode = mode
		self.camPos, self.camLook = nil, nil
	end
	if fov then
		self.fov = fov
	end
end

-- Screen position (pixels inside the viewport) of a world point, or nil when behind the camera.
function Player.project(self: ReplayPlayer, world: Vector3): Vector2?
	local size = self.viewport.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return nil
	end
	local rel = self.camera.CFrame:PointToObjectSpace(world)
	if rel.Z >= -0.1 then
		return nil
	end
	local tanY = math.tan(math.rad(self.camera.FieldOfView) / 2)
	local aspect = size.X / size.Y
	local nx = (rel.X / -rel.Z) / (tanY * aspect)
	local ny = (rel.Y / -rel.Z) / tanY
	return Vector2.new((nx + 1) / 2 * size.X, (1 - ny) / 2 * size.Y)
end

-- Places every actor at time t (seconds from the clip start) and moves the camera.
-- dt is the real frame time (for camera smoothing); snap jumps the camera.
function Player.render(self: ReplayPlayer, t: number, dt: number, snap: boolean?)
	if not self.clip then
		return
	end
	local f = 1 + math.clamp(t, 0, self.duration) * self.hz
	local focusId = tonumber(self.clip.focus) or 0
	local focusPos: Vector3? = nil
	local focusCF: CFrame? = nil

	local movedParts, movedCFrames = {}, {}
	local out = self.poseBuffer
	for _, av in self.avatars do
		local s = samplePlayerAt(av.frames, f)
		if s then
			poseAvatar(av, s, velocityAt(av.frames, f, self.hz), t, out)
			for k, p in av.parts do
				movedParts[#movedParts + 1] = p
				movedCFrames[#movedCFrames + 1] = out[k]
			end
			if av.model.Parent ~= self.dynamic then
				av.model.Parent = self.dynamic
			end
			if av.userId == focusId then
				focusPos = s.pos
				focusCF = CFrame.new(s.pos) * CFrame.Angles(0, s.yaw, 0)
			end
			if self.showNames then
				local screen = self:project(s.pos + Vector3.new(0, 3.4, 0))
				av.tag.Visible = screen ~= nil
				if screen then
					av.tag.Position = UDim2.fromOffset(screen.X, screen.Y)
				end
			else
				av.tag.Visible = false
			end
		else
			av.model.Parent = nil
			av.tag.Visible = false
		end
	end

	local ballPos: Vector3? = nil
	local bestBall = math.huge
	for _, b in self.balls do
		local pos = sampleVecAt(b.frames, f)
		if pos then
			local spin = CFrame.Angles(t * 9, 0, t * 4)
			movedParts[#movedParts + 1] = b.part
			movedCFrames[#movedCFrames + 1] = CFrame.new(pos) * spin
			movedParts[#movedParts + 1] = b.seam
			movedCFrames[#movedCFrames + 1] = CFrame.new(pos) * spin
			b.part.Transparency = 0
			b.seam.Transparency = 0
			local d = if focusPos then (pos - focusPos).Magnitude else 0
			if d < bestBall then
				bestBall, ballPos = d, pos
			end
		else
			b.part.Transparency = 1
			b.seam.Transparency = 1
		end
	end

	local focusVehicle: CFrame? = nil
	for _, v in self.vehicles do
		local cf = sampleCFrameAt(v.frames, f)
		if cf then
			for k, p in v.parts do
				movedParts[#movedParts + 1] = p
				movedCFrames[#movedCFrames + 1] = cf * v.offsets[k]
			end
			if v.model.Parent ~= self.dynamic then
				v.model.Parent = self.dynamic
			end
			if v.driver == focusId or (not focusVehicle and self.clip.kind == "driving") then
				focusVehicle = cf
			end
		else
			v.model.Parent = nil
		end
	end
	if #movedParts > 0 then
		self.world:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	-- Callouts recorded with the clip.
	local shown = nil
	for _, e in self.events do
		if t >= e.t and t <= e.t + 1.6 then
			shown = e.x
		end
	end
	self.callout.Visible = shown ~= nil
	if shown then
		self.callout.Text = shown
	end

	self:updateCamera(focusPos, focusCF, ballPos, focusVehicle, dt, snap)
end

function Player.updateCamera(self: ReplayPlayer, focusPos: Vector3?, focusCF: CFrame?, ballPos: Vector3?, vehicle: CFrame?, dt: number, snap: boolean?)
	local kind = self.clip.kind
	local mode = self.mode
	local subject = focusPos or ballPos or self.origin
	local desiredPos, desiredLook

	if kind == "driving" and vehicle then
		local fwd = vehicle.LookVector
		local flatFwd = Vector3.new(fwd.X, 0, fwd.Z)
		if flatFwd.Magnitude > 0.1 then
			self.chaseDir = self.chaseDir:Lerp(flatFwd.Unit, math.clamp(dt * 3, 0, 1))
		end
		local dir = if self.chaseDir.Magnitude > 0.01 then self.chaseDir.Unit else Vector3.new(0, 0, -1)
		local right = Vector3.new(-dir.Z, 0, dir.X)
		if mode == "ball" then
			desiredPos = vehicle.Position - dir * 22 + Vector3.new(0, 8, 0)
			desiredLook = vehicle.Position + dir * 10 + Vector3.new(0, 2, 0)
		elseif mode == "player" then
			desiredPos = (vehicle * CFrame.new(0, 2.2, 0.5)).Position
			desiredLook = desiredPos + vehicle.LookVector * 30
		else
			desiredPos = vehicle.Position + right * 42 + Vector3.new(0, 16, 0) - dir * 6
			desiredLook = vehicle.Position + dir * 6
		end
	elseif mode == "ball" and ballPos then
		local toBall = ballPos - (self.camPos or (ballPos + Vector3.new(0, 6, 14)))
		local flatDir = Vector3.new(toBall.X, 0, toBall.Z)
		local dir = if flatDir.Magnitude > 0.5 then flatDir.Unit else Vector3.new(0, 0, -1)
		desiredPos = ballPos - dir * 14 + Vector3.new(0, 6, 0)
		desiredLook = ballPos
	elseif mode == "player" and focusCF then
		desiredPos = (focusCF * CFrame.new(2.4, 3, 9)).Position
		desiredLook = (focusCF * CFrame.new(0, 1.5, -14)).Position
	else
		-- broadcast: from the side, tracking between the star and the ball
		local target = if ballPos and focusPos then focusPos:Lerp(ballPos, 0.5) else subject
		desiredPos = target + self.sideDir * 40 + Vector3.new(0, 15, 0)
		desiredLook = target + Vector3.new(0, 2, 0)
	end

	if snap or not self.camPos or not self.camLook then
		self.camPos, self.camLook = desiredPos, desiredLook
	else
		local alpha = 1 - math.exp(-math.max(dt, 0) * 6)
		self.camPos = (self.camPos :: Vector3):Lerp(desiredPos, alpha)
		self.camLook = (self.camLook :: Vector3):Lerp(desiredLook, alpha)
	end
	local pos, look = self.camPos :: Vector3, self.camLook :: Vector3
	if (look - pos).Magnitude < 0.05 then
		look = pos + Vector3.new(0, 0, -1)
	end
	self.camera.CFrame = CFrame.lookAt(pos, look)
	self.camera.FieldOfView = self.fov
end

function Player.destroy(self: ReplayPlayer)
	self:clear()
	if self.env then
		self.env:Destroy()
		self.env = nil
	end
	self.world:Destroy()
	self.camera:Destroy()
	self.overlay:Destroy()
	self.clip = nil
end

return Replay
