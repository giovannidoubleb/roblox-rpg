-- CITY GRIND: scene snapshots (sections 30-33). Roblox can't save image files, so a
-- PHOTO is a small JSON-safe table that can be re-rendered in any ViewportFrame:
--
--   {
--     v  = 1,
--     c  = {x, y, z, rx, ry, rz}   camera CFrame (YXZ euler, radians)
--     f  = field of view, k = Lighting.ClockTime, fl = filter id, l = location name, t = os.time()
--     p  = { { u = userId, n = display name, r = root CFrame (6), fc = face texture?, b = { part } } }  people (<= 8)
--     h  = { { r = pivot CFrame (6), b = { part } } }                                                  vehicles (<= 3)
--   }
--   part = { shape, sx, sy, sz, x, y, z, rx, ry, rz, rgb, materialValue, transparency }  (relative to r)
--   shape: 0 block, 1 ball, 2 cylinder (X axis), 3 wedge, 4 corner wedge, 5 head, 6 ellipsoid, 7 cylinder (Y axis)
--
-- The static city is not stored: render() clones the anchored City parts around the
-- saved camera (nearest first, capped). People and vehicles are rebuilt from `p` / `h`.
--
-- Client:  SceneSnapshot.capture(camera, opts) -> (snapshot, request)   request is what the server validates
--          SceneSnapshot.render(viewportFrame, snapshot, opts?)
--          SceneSnapshot.overlay(guiParent, filterId, seed?) / SceneSnapshot.visiblePlayers / visibleVehicles
-- Both:    SceneSnapshot.sanitize(snapshot) -> (snapshot?, reason?)  canonical copy, shape + size checked
--          SceneSnapshot.encodeGroup(model, rootCFrame, maxParts, overrides?, tolerance?) -> (parts, keys)
--          SceneSnapshot.nearestPlace(position) -> string

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MediaConfig = require(script.Parent:WaitForChild("MediaConfig"))

local SceneSnapshot = {}

local IS_CLIENT = RunService:IsClient()

---------------------------------------------------------------------------
-- Numbers and CFrames
---------------------------------------------------------------------------
local function r2(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local function r3(n: number): number
	return math.floor(n * 1000 + 0.5) / 1000
end

local function finite(n: any, limit: number): boolean
	return type(n) == "number" and n == n and n > -limit and n < limit
end

function SceneSnapshot.cfToArr(cf: CFrame, precise: boolean?): { number }
	local p = cf.Position
	local rx, ry, rz = cf:ToEulerAnglesYXZ()
	local ra = if precise then r3 else r2
	return { r2(p.X), r2(p.Y), r2(p.Z), ra(rx), ra(ry), ra(rz) }
end

function SceneSnapshot.arrToCf(a: { number }): CFrame
	return CFrame.new(a[1], a[2], a[3]) * CFrame.fromEulerAnglesYXZ(a[4], a[5], a[6])
end

local function validCf(a: any, limit: number): boolean
	if type(a) ~= "table" or #a ~= 6 then
		return false
	end
	for i = 1, 3 do
		if not finite(a[i], limit) then
			return false
		end
	end
	for i = 4, 6 do
		if not finite(a[i], 7) then
			return false
		end
	end
	return true
end
SceneSnapshot.validCf = validCf

local MATERIALS: { [number]: Enum.Material } = {}
for _, item in Enum.Material:GetEnumItems() do
	MATERIALS[item.Value] = item
end

local function rgb(c: Color3): number
	return math.floor(c.R * 255 + 0.5) * 65536 + math.floor(c.G * 255 + 0.5) * 256 + math.floor(c.B * 255 + 0.5)
end

local function fromRgb(n: number): Color3
	return Color3.fromRGB(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

---------------------------------------------------------------------------
-- Encoding models (characters and vehicles)
---------------------------------------------------------------------------
local BODY_PARTS = {
	Head = true, UpperTorso = true, LowerTorso = true, Torso = true,
	LeftUpperArm = true, LeftLowerArm = true, LeftHand = true, RightUpperArm = true, RightLowerArm = true, RightHand = true,
	LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true, RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
	["Left Arm"] = true, ["Right Arm"] = true, ["Left Leg"] = true, ["Right Leg"] = true,
}

-- Shape code + the size the part visibly occupies.
local function shapeOf(part: BasePart): (number, Vector3)
	local size = part.Size
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	if part.Name == "Head" and (part:IsA("MeshPart") or (mesh and mesh.MeshType == Enum.MeshType.Head) or BODY_PARTS[part.Name]) then
		local s = math.min(size.X, size.Y, size.Z) * (if mesh then mesh.Scale.Y else 1)
		return 5, Vector3.new(s, s, s)
	end
	if mesh then
		local t = mesh.MeshType
		local scaled = size * mesh.Scale
		if t == Enum.MeshType.Sphere then
			return 6, scaled
		elseif t == Enum.MeshType.Cylinder then
			return 7, scaled
		elseif t == Enum.MeshType.Wedge then
			return 3, scaled
		elseif t == Enum.MeshType.Brick then
			return 0, scaled
		elseif t == Enum.MeshType.Head then
			return 5, scaled
		end
		return 6, size -- file meshes (hats, hair): a rounded shape of the same bounds
	end
	if part:IsA("WedgePart") then
		return 3, size
	elseif part:IsA("CornerWedgePart") then
		return 4, size
	elseif part:IsA("Part") then
		if part.Shape == Enum.PartType.Ball then
			return 1, size
		elseif part.Shape == Enum.PartType.Cylinder then
			return 2, size
		end
		return 0, size
	elseif part:IsA("MeshPart") then
		return (if BODY_PARTS[part.Name] then 0 else 6), size
	end
	return 0, size
end

-- Stable key for a part inside a model ("LeftHand", "HairAccessory/Handle").
function SceneSnapshot.partKey(part: Instance, model: Instance): string
	if part.Parent == model or not part.Parent then
		return part.Name
	end
	return (part.Parent :: Instance).Name .. "/" .. part.Name
end

local function encodePart(part: BasePart, rel: CFrame): { number }
	local code, size = shapeOf(part)
	local p = rel.Position
	local rx, ry, rz = rel:ToEulerAnglesYXZ()
	return {
		code,
		r2(math.clamp(size.X, 0.05, 60)), r2(math.clamp(size.Y, 0.05, 60)), r2(math.clamp(size.Z, 0.05, 60)),
		r2(p.X), r2(p.Y), r2(p.Z),
		r2(rx), r2(ry), r2(rz),
		rgb(part.Color),
		part.Material.Value,
		r2(math.clamp(part.Transparency, 0, 1)),
	}
end

-- Encodes the visible parts of a model relative to rootCF (largest parts first).
-- overrides: key -> CFrame relative to rootCF (a pose reported by a client); used
-- only when within `tolerance` studs of where this machine sees that part.
function SceneSnapshot.encodeGroup(model: Instance, rootCF: CFrame, maxParts: number, overrides: { [string]: CFrame }?, tolerance: number?): ({ { number } }, { string })
	local list = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Transparency < 0.95 and d.Size.Magnitude > 0.1 then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a, b)
		local sa, sb = a.Size, b.Size
		return sa.X * sa.Y * sa.Z > sb.X * sb.Y * sb.Z
	end)
	local parts, keys = {}, {}
	for i = 1, math.min(#list, maxParts) do
		local part = list[i]
		local key = SceneSnapshot.partKey(part, model)
		local rel = rootCF:ToObjectSpace(part.CFrame)
		local o = overrides and overrides[key]
		if o and (o.Position - rel.Position).Magnitude <= (tolerance or 0) then
			rel = o
		end
		if rel.Position.Magnitude < 60 then
			table.insert(parts, encodePart(part, rel))
			table.insert(keys, key)
		end
	end
	return parts, keys
end

-- The character's face texture, only when it is a plain content id from its own Decal.
local function faceOf(character: Model): string?
	local head = character:FindFirstChild("Head")
	local face = head and head:FindFirstChildOfClass("Decal")
	if face then
		local tex = face.Texture
		if SceneSnapshot.validFace(tex) then
			return tex
		end
	end
	return nil
end

function SceneSnapshot.validFace(tex: any): boolean
	return type(tex) == "string"
		and #tex <= 100
		and (tex:match("^rbxasset://textures/[%w_/%.%-]+$") ~= nil or tex:match("^rbxassetid://%d+$") ~= nil or tex:match("^https?://www%.roblox%.com/asset/%?id=%d+$") ~= nil)
end

function SceneSnapshot.encodePerson(player: Player, character: Model, rootCF: CFrame, overrides: { [string]: CFrame }?, tolerance: number?)
	local parts = SceneSnapshot.encodeGroup(character, rootCF, MediaConfig.PERSON_PARTS, overrides, tolerance)
	return {
		u = player.UserId,
		n = player.DisplayName:sub(1, 40),
		r = SceneSnapshot.cfToArr(rootCF),
		fc = faceOf(character),
		b = parts,
	}
end

function SceneSnapshot.encodeVehicle(model: Model, pivot: CFrame)
	local parts = SceneSnapshot.encodeGroup(model, pivot, MediaConfig.VEHICLE_PARTS)
	return { r = SceneSnapshot.cfToArr(pivot), b = parts }
end

---------------------------------------------------------------------------
-- Places
---------------------------------------------------------------------------
-- Nearest phone-map destination (City.MapPoints) within 160 studs, or "Neighborhood".
function SceneSnapshot.nearestPlace(position: Vector3): string
	local city = Workspace:FindFirstChild("City")
	local points = city and city:FindFirstChild("MapPoints")
	local best, bestDist = "Neighborhood", 160
	if points then
		for _, p in points:GetChildren() do
			if p:IsA("BasePart") then
				local d = (p.Position - position).Magnitude
				if d < bestDist then
					best, bestDist = p.Name, d
				end
			end
		end
	end
	return best:sub(1, 40)
end

---------------------------------------------------------------------------
-- Validation (server: everything the client sends; client: everything it renders)
---------------------------------------------------------------------------
local function cleanPart(a: any): { number }?
	if type(a) ~= "table" or #a ~= 13 then
		return nil
	end
	local code, mat, col = a[1], a[12], a[11]
	if type(code) ~= "number" or code % 1 ~= 0 or code < 0 or code > 7 then
		return nil
	end
	for i = 2, 4 do
		if not finite(a[i], 60.01) or a[i] <= 0 then
			return nil
		end
	end
	for i = 5, 7 do
		if not finite(a[i], 60) then
			return nil
		end
	end
	for i = 8, 10 do
		if not finite(a[i], 7) then
			return nil
		end
	end
	if type(col) ~= "number" or col % 1 ~= 0 or col < 0 or col > 16777215 then
		return nil
	end
	if type(mat) ~= "number" or not MATERIALS[mat] then
		return nil
	end
	if not finite(a[13], 1.01) or a[13] < 0 then
		return nil
	end
	return { code, a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], col, mat, a[13] }
end

local function cleanParts(list: any, cap: number): { { number } }?
	if type(list) ~= "table" or #list > cap then
		return nil
	end
	local out = {}
	for i = 1, #list do
		local p = cleanPart(list[i])
		if not p then
			return nil
		end
		out[i] = p
	end
	return out
end

-- Returns a canonical copy containing only known, checked fields.
function SceneSnapshot.sanitize(s: any): (any, string?)
	if type(s) ~= "table" or s.v ~= 1 then
		return nil, "Not a photo."
	end
	if not validCf(s.c, 100000) then
		return nil, "Bad camera."
	end
	if not finite(s.f, 1000) or s.f < MediaConfig.FOV_MIN or s.f > MediaConfig.FOV_MAX then
		return nil, "Bad zoom."
	end
	if not finite(s.k, 24.01) or s.k < 0 then
		return nil, "Bad time."
	end
	if not MediaConfig.isFilter(s.fl) then
		return nil, "Unknown filter."
	end
	if type(s.l) ~= "string" or #s.l > 40 then
		return nil, "Bad location."
	end
	if s.t ~= nil and not finite(s.t, 1e11) then
		return nil, "Bad time."
	end
	local out = { v = 1, c = table.clone(s.c), f = s.f, k = s.k, fl = s.fl, l = s.l, t = s.t, p = {}, h = {} }
	if type(s.p) ~= "table" or #s.p > MediaConfig.MAX_PEOPLE then
		return nil, "Too many people."
	end
	for i = 1, #s.p do
		local e = s.p[i]
		if type(e) ~= "table" or type(e.u) ~= "number" or e.u % 1 ~= 0 or type(e.n) ~= "string" or #e.n > 40 or not validCf(e.r, 100000) then
			return nil, "Bad person."
		end
		if e.fc ~= nil and not SceneSnapshot.validFace(e.fc) then
			return nil, "Bad person."
		end
		local parts = cleanParts(e.b, MediaConfig.PERSON_PARTS)
		if not parts then
			return nil, "Bad person."
		end
		out.p[i] = { u = e.u, n = e.n, r = table.clone(e.r), fc = e.fc, b = parts }
	end
	if type(s.h) ~= "table" or #s.h > MediaConfig.MAX_VEHICLES then
		return nil, "Too many vehicles."
	end
	for i = 1, #s.h do
		local e = s.h[i]
		if type(e) ~= "table" or not validCf(e.r, 100000) then
			return nil, "Bad vehicle."
		end
		local parts = cleanParts(e.b, MediaConfig.VEHICLE_PARTS)
		if not parts then
			return nil, "Bad vehicle."
		end
		out.h[i] = { r = table.clone(e.r), b = parts }
	end
	if SceneSnapshot.bytes(out) > MediaConfig.MAX_SNAPSHOT_BYTES then
		return nil, "Photo is too big."
	end
	return out, nil
end

function SceneSnapshot.bytes(s: any): number
	local ok, json = pcall(HttpService.JSONEncode, HttpService, s)
	return if ok then #json else math.huge
end

-- Drops vehicle then people parts until the JSON fits the size limit.
function SceneSnapshot.shrink(s: any)
	while SceneSnapshot.bytes(s) > MediaConfig.MAX_SNAPSHOT_BYTES do
		local biggest, list = 0, nil
		for _, group in s.h do
			if #group.b > biggest then
				biggest, list = #group.b, group.b
			end
		end
		if not list or biggest <= 8 then
			for _, group in s.p do
				if #group.b > biggest then
					biggest, list = #group.b, group.b
				end
			end
		end
		if not list or biggest == 0 then
			break
		end
		table.remove(list) -- smallest part (lists are sorted largest first)
	end
end

---------------------------------------------------------------------------
-- Filters (colour transform shared by live camera + renders)
---------------------------------------------------------------------------
function SceneSnapshot.filterColor(c: Color3, f: any): Color3
	if f.id == "None" then
		return c
	end
	local r, g, b = c.R, c.G, c.B
	local l = 0.299 * r + 0.587 * g + 0.114 * b
	local s = 1 + f.saturation
	r, g, b = l + (r - l) * s, l + (g - l) * s, l + (b - l) * s
	local k = 1 + f.contrast
	r, g, b = (r - 0.5) * k + 0.5 + f.brightness, (g - 0.5) * k + 0.5 + f.brightness, (b - 0.5) * k + 0.5 + f.brightness
	r, g, b = r * f.tint.R, g * f.tint.G, b * f.tint.B
	return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
end

-- Vignette / colour wash / grain frames over a picture (live lens or rendered photo).
function SceneSnapshot.overlay(parent: GuiObject, filterId: string, seed: number?)
	for _, child in parent:GetChildren() do
		if child.Name == "CGOverlay" then
			child:Destroy()
		end
	end
	local f = MediaConfig.filter(filterId)
	local holder = Instance.new("Frame")
	holder.Name = "CGOverlay"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 5
	holder.ClipsDescendants = true
	if f.overlay then
		local wash = Instance.new("Frame")
		wash.BorderSizePixel = 0
		wash.BackgroundColor3 = f.overlay
		wash.BackgroundTransparency = f.overlayAlpha or 0.9
		wash.Size = UDim2.fromScale(1, 1)
		wash.ZIndex = 5
		wash.Parent = holder
	end
	if f.vignette > 0 then
		local edges = {
			{ UDim2.fromScale(0, 0), UDim2.fromScale(0.32, 1), 0 },
			{ UDim2.fromScale(0.68, 0), UDim2.fromScale(0.32, 1), 180 },
			{ UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.32), 90 },
			{ UDim2.fromScale(0, 0.68), UDim2.fromScale(1, 0.32), 270 },
		}
		for _, e in edges do
			local edge = Instance.new("Frame")
			edge.BorderSizePixel = 0
			edge.BackgroundColor3 = Color3.new(0, 0, 0)
			edge.BackgroundTransparency = 0
			edge.Position = e[1]
			edge.Size = e[2]
			edge.ZIndex = 6
			local grad = Instance.new("UIGradient")
			grad.Rotation = e[3]
-- selene: allow(undefined_variable)
			grad.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1 - f.vignette * 0.85),
				NumberSequenceKeypoint.new(1, 1),
			})
			grad.Parent = edge
			edge.Parent = holder
		end
	end
	if f.grain then
		local rng = Random.new(seed or 7)
		for _ = 1, 70 do
			local dot = Instance.new("Frame")
			dot.BorderSizePixel = 0
			dot.BackgroundColor3 = if rng:NextNumber() < 0.5 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
			dot.BackgroundTransparency = rng:NextNumber(0.55, 0.85)
			dot.Position = UDim2.fromScale(rng:NextNumber(), rng:NextNumber())
			dot.Size = UDim2.fromOffset(rng:NextInteger(1, 2), rng:NextInteger(1, 2))
			dot.ZIndex = 7
			dot.Parent = holder
		end
	end
	holder.Parent = parent
end

---------------------------------------------------------------------------
-- Lighting from time of day
---------------------------------------------------------------------------
local function lerp(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

function SceneSnapshot.lighting(clock: number): (Color3, Color3, Vector3, Color3)
	local theta = (clock - 6) / 12 * math.pi
	local dayness = math.sin(theta) -- 1 at noon, 0 at 6:00 / 18:00, negative at night
	if dayness > -0.05 then
		local d = math.max(dayness, 0)
		local sunDir = Vector3.new(math.cos(theta), math.max(math.sin(theta), 0.08), 0.35).Unit
		local ambient = lerp(Color3.fromRGB(80, 70, 85), Color3.fromRGB(150, 150, 160), d)
		local light = lerp(Color3.fromRGB(255, 165, 110), Color3.fromRGB(255, 250, 240), d * 1.6)
		local sky = lerp(Color3.fromRGB(240, 150, 110), Color3.fromRGB(130, 185, 240), d * 1.8)
		return ambient, light, -sunDir, sky
	end
	return Color3.fromRGB(45, 48, 72), Color3.fromRGB(95, 105, 160), Vector3.new(-0.3, -1, -0.4).Unit, Color3.fromRGB(14, 17, 34)
end

---------------------------------------------------------------------------
-- Client: what is in frame
---------------------------------------------------------------------------
local function onScreen(camera: Camera, pos: Vector3): boolean
	local v, visible = camera:WorldToViewportPoint(pos)
	return visible and v.Z > 0
end

local function vehicleFolder(): Instance?
	local city = Workspace:FindFirstChild("City")
	local vehicles = city and city:FindFirstChild("Vehicles")
	return vehicles and vehicles:FindFirstChild("Active")
end
SceneSnapshot.vehicleFolder = vehicleFolder

local function clearLine(camera: Camera, target: Vector3, ignore: { Instance }): boolean
	-- selene: allow(undefined_variable)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local origin = camera.CFrame.Position
	local hit = Workspace:Raycast(origin, target - origin, params)
	return hit == nil or (hit.Position - origin).Magnitude >= (target - origin).Magnitude - 1.5
end

local function ignoreList(): { Instance }
	local ignore = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local folder = vehicleFolder()
	if folder then
		table.insert(ignore, folder)
	end
	return ignore
end

-- Players whose head or body is on screen and not hidden behind a wall (nearest first).
function SceneSnapshot.visiblePlayers(camera: Camera, includeSelf: boolean): { Player }
	local camPos = camera.CFrame.Position
	local ignore = ignoreList()
	local found = {}
	for _, p in Players:GetPlayers() do
		if p == Players.LocalPlayer and not includeSelf then
			continue
		end
		local character = p.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local head = character and character:FindFirstChild("Head")
		if not root or not root:IsA("BasePart") then
			continue
		end
		local dist = (root.Position - camPos).Magnitude
		if dist > MediaConfig.SUBJECT_RANGE then
			continue
		end
		local points = { root.Position }
		if head and head:IsA("BasePart") then
			table.insert(points, head.Position)
		end
		for _, pos in points do
			if onScreen(camera, pos) and clearLine(camera, pos, ignore) then
				table.insert(found, { player = p, dist = dist })
				break
			end
		end
	end
	table.sort(found, function(a, b)
		return a.dist < b.dist
	end)
	local out = {}
	for i = 1, math.min(#found, MediaConfig.MAX_PEOPLE) do
		out[i] = found[i].player
	end
	return out
end

function SceneSnapshot.visibleVehicles(camera: Camera): { Model }
	local folder = vehicleFolder()
	if not folder then
		return {}
	end
	local camPos = camera.CFrame.Position
	local found = {}
	for _, m in folder:GetChildren() do
		if m:IsA("Model") then
			local pos = m:GetPivot().Position
			local dist = (pos - camPos).Magnitude
			if dist <= MediaConfig.SUBJECT_RANGE and onScreen(camera, pos) then
				table.insert(found, { model = m, dist = dist })
			end
		end
	end
	table.sort(found, function(a, b)
		return a.dist < b.dist
	end)
	local out = {}
	for i = 1, math.min(#found, MediaConfig.MAX_VEHICLES) do
		out[i] = found[i].model
	end
	return out
end

-- Builds a snapshot of what `camera` sees right now, plus the request the server
-- re-checks and re-encodes (the server never stores client geometry, only poses).
-- opts: { filter: string?, includeSelf: boolean? }
function SceneSnapshot.capture(camera: Camera, opts: { filter: string?, includeSelf: boolean? }?): (any, any)
	assert(IS_CLIENT, "SceneSnapshot.capture runs on the client")
	local o = opts or {}
	local filterId = if MediaConfig.isFilter(o.filter) then o.filter :: string else "None"
	local camCF = camera.CFrame
	local local_ = Players.LocalPlayer
	local interior = local_:GetAttribute("Interior")
	local snap = {
		v = 1,
		c = SceneSnapshot.cfToArr(camCF, true),
		f = r2(math.clamp(camera.FieldOfView, MediaConfig.FOV_MIN, MediaConfig.FOV_MAX)),
		k = r2(game:GetService("Lighting").ClockTime),
		fl = filterId,
		l = if type(interior) == "string" and interior ~= "" then interior:sub(1, 40) else SceneSnapshot.nearestPlace(camCF.Position),
		t = os.time(),
		p = {},
		h = {},
	}
	local request = { c = snap.c, f = snap.f, fl = filterId, p = {}, h = {} }
	for _, p in SceneSnapshot.visiblePlayers(camera, o.includeSelf ~= false) do
		local character = p.Character :: Model
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
		local rootCF = root.CFrame
		local person = SceneSnapshot.encodePerson(p, character, rootCF)
		table.insert(snap.p, person)
		-- poses for the server: key -> CFrame relative to the root
		local poses = {}
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") and d ~= root then
				poses[SceneSnapshot.partKey(d, character)] = SceneSnapshot.cfToArr(rootCF:ToObjectSpace(d.CFrame))
			end
		end
		table.insert(request.p, { u = p.UserId, r = person.r, k = poses })
	end
	for _, m in SceneSnapshot.visibleVehicles(camera) do
		local pivot = m:GetPivot()
		table.insert(snap.h, SceneSnapshot.encodeVehicle(m, pivot))
		table.insert(request.h, { m = m, r = SceneSnapshot.cfToArr(pivot) })
	end
	SceneSnapshot.shrink(snap)
	return snap, request
end

---------------------------------------------------------------------------
-- Client: rendering
---------------------------------------------------------------------------
type StaticEntry = { part: BasePart, pos: Vector3, radius: number }
local staticCache: { StaticEntry }? = nil
local staticCacheTime = -math.huge
local SKIP_FOLDERS = { MapPoints = true, Active = true }

local function collectStatic(): { StaticEntry }
	if staticCache and os.clock() - staticCacheTime < 30 then
		return staticCache
	end
	local list: { StaticEntry } = {}
	local city = Workspace:FindFirstChild("City")
	local function walk(node: Instance)
		for _, child in node:GetChildren() do
			if SKIP_FOLDERS[child.Name] then
				continue
			end
			if child:IsA("BasePart") then
				if child.Anchored and child.Transparency < 0.9 then
					local size = child.Size
					table.insert(list, { part = child, pos = child.Position, radius = size.Magnitude / 2 })
				end
			end
			if #child:GetChildren() > 0 and not child:IsA("GuiBase") then
				walk(child)
			end
		end
	end
	if city then
		walk(city)
	end
	staticCache = list
	staticCacheTime = os.clock()
	return list
end

local KEEP_CHILD = { SpecialMesh = true, BlockMesh = true, CylinderMesh = true, Decal = true, Texture = true, SurfaceAppearance = true }

local function cloneStatic(src: BasePart): BasePart?
	local ok, c = pcall(function()
		return src:Clone()
	end)
	if not ok or not c then
		local p = Instance.new("Part")
		p.Size = src.Size
		p.CFrame = src.CFrame
		p.Color = src.Color
		p.Material = src.Material
		p.Transparency = src.Transparency
		return p
	end
	for _, child in c:GetChildren() do
		if not KEEP_CHILD[child.ClassName] then
			child:Destroy()
		end
	end
	return c
end

local function buildPart(a: { number }, base: CFrame, filter: any): BasePart
	local code = a[1]
	local part: BasePart
	if code == 3 then
		part = Instance.new("WedgePart")
	elseif code == 4 then
		part = Instance.new("CornerWedgePart")
	else
		local p = Instance.new("Part")
		if code == 1 then
			p.Shape = Enum.PartType.Ball
		elseif code == 2 then
			p.Shape = Enum.PartType.Cylinder
		end
		part = p
	end
	part.Size = Vector3.new(a[2], a[3], a[4])
	part.CFrame = base * SceneSnapshot.arrToCf({ a[5], a[6], a[7], a[8], a[9], a[10] })
	part.Color = SceneSnapshot.filterColor(fromRgb(a[11]), filter)
	part.Material = MATERIALS[a[12]] or Enum.Material.SmoothPlastic
	part.Transparency = a[13]
	part.Anchored = true
	part.CastShadow = false
	if code == 5 or code == 6 or code == 7 then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = if code == 5 then Enum.MeshType.Head elseif code == 6 then Enum.MeshType.Sphere else Enum.MeshType.Cylinder
		mesh.Parent = part
	end
	return part
end

-- Draws `snap` inside `viewport`. opts.maxParts caps the static city parts.
function SceneSnapshot.render(viewport: ViewportFrame, snap: any, opts: { maxParts: number?, seed: number? }?)
	assert(IS_CLIENT, "SceneSnapshot.render runs on the client")
	for _, child in viewport:GetChildren() do
		if not child:IsA("UICorner") and not child:IsA("UIStroke") and not child:IsA("UIAspectRatioConstraint") then
			child:Destroy()
		end
	end
	local s = SceneSnapshot.sanitize(snap)
	if not s then
		return
	end
	local o = opts or {}
	local filter = MediaConfig.filter(s.fl)
	local camCF = SceneSnapshot.arrToCf(s.c)
	local camera = Instance.new("Camera")
	camera.CFrame = camCF
	camera.FieldOfView = s.f
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local ambient, light, dir, sky = SceneSnapshot.lighting(s.k)
	viewport.Ambient = SceneSnapshot.filterColor(ambient, filter)
	viewport.LightColor = light
	viewport.LightDirection = dir
	viewport.BackgroundColor3 = SceneSnapshot.filterColor(sky, filter)
	viewport.BackgroundTransparency = 0

	local world = Instance.new("Model")
	world.Name = "Scene"

	-- static city around the look area, nearest first
	local camPos, look = camCF.Position, camCF.LookVector
	local focus = camPos + look * 45
	local radius = MediaConfig.RENDER_RADIUS
	local picks = {}
	for _, e in collectStatic() do
		if not e.part.Parent then
			continue
		end
		local toPart = e.pos - camPos
		if toPart:Dot(look) < -e.radius - 6 then
			continue -- behind the camera
		end
		local d = (e.pos - focus).Magnitude - e.radius
		if d > radius then
			continue
		end
		if e.radius < 0.5 and d > 40 then
			continue -- tiny detail far away
		end
		table.insert(picks, { e = e, score = d })
	end
	table.sort(picks, function(a, b)
		return a.score < b.score
	end)
	local cap = math.min(#picks, o.maxParts or MediaConfig.RENDER_PARTS)
	for i = 1, cap do
		local c = cloneStatic(picks[i].e.part)
		if c then
			if filter.id ~= "None" then
				c.Color = SceneSnapshot.filterColor(c.Color, filter)
			end
			c.Parent = world
		end
	end

	-- people and vehicles
	for _, person in s.p do
		local base = SceneSnapshot.arrToCf(person.r)
		for _, a in person.b do
			local part = buildPart(a, base, filter)
			if a[1] == 5 then
				local face = Instance.new("Decal")
				face.Name = "face"
				face.Face = Enum.NormalId.Front
				face.Texture = person.fc or "rbxasset://textures/face.png"
				face.Parent = part
			end
			part.Parent = world
		end
	end
	for _, vehicle in s.h do
		local base = SceneSnapshot.arrToCf(vehicle.r)
		for _, a in vehicle.b do
			buildPart(a, base, filter).Parent = world
		end
	end
	world.Parent = viewport
	SceneSnapshot.overlay(viewport, s.fl, o.seed)
end

return SceneSnapshot
